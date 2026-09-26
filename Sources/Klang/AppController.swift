import Foundation
import CoreAudio
import AudioToolbox
import KlangCore

enum AppError: Error { case noOutputDevice, tapFailed, aggregateFailed }

/// Orchestrates the whole chain: device selection, the system-audio tap and aggregate
/// lifecycle, and following the system default output. The default output itself is
/// never changed.
final class AppController {
    private let dm = DeviceManager()
    private let agg = AggregateDevice()
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let store: ProfileStore

    private var chain: AudioChain?
    private var tap: SystemAudioTap?
    private var aggregateID: AudioDeviceID?
    private(set) var prefs: Prefs

    /// The output device and profile the running chain was built for.
    private(set) var activeDeviceUID: String?
    private var activeDeviceName: String?
    private(set) var activeProfileID: String?

    private var prefsURL: URL { AppPaths.prefsURL(home: home) }
    private var activeStateURL: URL? { activeProfileID.map { store.stateURL(id: $0) } }

    init() {
        store = ProfileStore(home: home)
        prefs = PrefsStore.load(from: AppPaths.prefsURL(home: home))
        _ = try? store.migrateLegacyFullStateIfNeeded()   // adopt a pre-profiles single state
    }

    private func persistPrefs() { try? PrefsStore.save(prefs, to: prefsURL) }

    var isActive: Bool { chain?.isRunning ?? false }
    var effectAudioUnit: AudioUnit? { chain?.renderAudioUnit }

    var bypass: Bool {
        get { chain?.bypass ?? false }
        set { chain?.bypass = newValue }
    }

    var activeProfileName: String? {
        activeProfileID.flatMap { id in store.list().first { $0.id == id }?.name }
    }

    var statusText: String {
        guard isActive else { return "Inactive" }
        let dev = activeDeviceName ?? "Output"
        let prof = activeProfileName ?? "—"
        return "\(dev) · \(prof)\(bypass ? " · bypass" : "")"
    }

    private var defaultOutputUID: String? {
        let id = dm.defaultOutputDeviceID()
        return dm.listDevices().first { $0.id == id }?.uid
    }

    func activate(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard let out = DeviceMatcher.resolveTarget(chosenUID: prefs.outputUID,
                                                    defaultUID: defaultOutputUID,
                                                    in: dm.listDevices()) else {
            completion(.failure(AppError.noOutputDevice)); return
        }
        guard let tap = SystemAudioTap() else { completion(.failure(AppError.tapFailed)); return }
        guard let aggID = agg.create(AggregateSpec.make(outputUID: out.uid, tapUUID: tap.uuid)) else {
            tap.destroy()
            completion(.failure(AppError.aggregateFailed)); return
        }
        self.tap = tap
        aggregateID = aggID
        activeDeviceUID = out.uid
        activeDeviceName = out.name

        let profile = resolveProfile(forDeviceUID: out.uid)
        activeProfileID = profile.id

        let chain = AudioChain(sampleRate: dm.nominalSampleRate(aggID) ?? 48000)
        chain.start(aggregateID: aggID, initialStateURL: store.stateURL(id: profile.id)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.teardown()
                completion(.failure(e))
            case .success:
                self.chain = chain
                completion(.success(()))
            }
        }
    }

    /// The profile assigned to this device, else the first existing profile, else a
    /// freshly created "Default".
    private func resolveProfile(forDeviceUID uid: String) -> Profile {
        let all = store.list()
        if let pid = prefs.deviceProfiles[uid], let p = all.first(where: { $0.id == pid }) {
            return p
        }
        if let first = all.first { return first }
        return (try? store.create(name: "Default")) ?? Profile(id: "default", name: "Default")
    }

    func deactivate() {
        if let url = activeStateURL { chain?.saveState(to: url) }
        teardown()
    }

    /// Stop IO first, then drop the aggregate, then the tap (which unmutes the system).
    private func teardown() {
        chain?.stop()
        chain = nil
        if let id = aggregateID { agg.destroy(id) }
        aggregateID = nil
        tap?.destroy()
        tap = nil
        activeDeviceUID = nil
        activeDeviceName = nil
        activeProfileID = nil
    }

    func saveStateNow() { if let url = activeStateURL { chain?.saveState(to: url) } }

    // MARK: - Output device selection

    func selectableOutputs() -> [AudioDeviceInfo] {
        DeviceMatcher.selectableOutputs(in: dm.listDevices())
    }

    /// The device currently targeted: the active device while running, else the saved
    /// user choice (nil means "auto" — follow the system default).
    var targetDeviceUID: String? { isActive ? activeDeviceUID : prefs.outputUID }

    /// Persist the chosen target. Pass nil for "auto". If running, rebuild the aggregate
    /// on the new device.
    func setOutputDevice(_ uid: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        prefs.outputUID = uid
        persistPrefs()
        // Nothing to rebuild if inactive, or if the running device is unchanged
        // (e.g. re-selecting the already-active device, or auto→explicit same device).
        guard isActive, uid != activeDeviceUID else { completion(.success(())); return }
        deactivate()
        activate(completion)
    }

    // MARK: - Profiles

    func profiles() -> [Profile] { store.list() }

    /// Assign an existing profile to the active device and load it into the live effect
    /// (instant, no chain rebuild).
    func selectProfile(id: String) {
        guard isActive, let uid = activeDeviceUID else { return }
        prefs.deviceProfiles[uid] = id
        persistPrefs()
        activeProfileID = id
        chain?.loadState(from: store.stateURL(id: id))
    }

    /// Snapshot the live effect into a new profile and assign it to the active device.
    @discardableResult
    func newProfileFromCurrent(name: String) -> Profile? {
        guard isActive, let uid = activeDeviceUID,
              let profile = try? store.create(name: name) else { return nil }
        chain?.saveState(to: store.stateURL(id: profile.id))
        prefs.deviceProfiles[uid] = profile.id
        persistPrefs()
        activeProfileID = profile.id
        return profile
    }

    func renameProfile(id: String, to name: String) { try? store.rename(id: id, to: name) }

    func deleteProfile(id: String) {
        try? store.delete(id: id)
        prefs.deviceProfiles = prefs.deviceProfiles.filter { $0.value != id }
        persistPrefs()
        if activeProfileID == id, isActive, let uid = activeDeviceUID {
            let fallback = resolveProfile(forDeviceUID: uid)
            activeProfileID = fallback.id
            chain?.loadState(from: store.stateURL(id: fallback.id))
        }
    }

    func observeDeviceChanges(_ handler: @escaping () -> Void) {
        dm.onDevicesChanged { [weak self] in
            guard let self = self else { return }
            if self.isActive {
                let list = self.dm.listDevices()
                let stillThere = self.activeDeviceUID.map { uid in
                    list.contains { $0.uid == uid }
                } ?? true
                if !stillThere { self.deactivate() }
            }
            handler()
        }
        // Automatic target: when the user switches the system default output (AirPods,
        // a DAC…), move the correction to it. The default output is never written by Klang.
        dm.onDefaultOutputChanged { [weak self] in
            guard let self = self, self.isActive, let active = self.activeDeviceUID,
                  DeviceMatcher.followTarget(activeUID: active, chosenUID: self.prefs.outputUID,
                                             defaultUID: self.defaultOutputUID,
                                             in: self.dm.listDevices()) != nil else { return }
            self.deactivate()
            self.activate { _ in handler() }
            handler()
        }
    }
}
