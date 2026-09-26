import Foundation
import CoreAudio
import AudioToolbox
import os
import KlangCore

private let dbg = Logger(subsystem: "com.klang.debug", category: "safety")

enum AppError: Error { case micDenied, missingDevices, aggregateFailed }

/// Orchestrates the whole chain: device selection, sample-rate negotiation,
/// aggregate lifecycle, default-output switching, and crash recovery.
final class AppController {
    private let dm = DeviceManager()
    private let agg = AggregateDevice()
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let store: ProfileStore

    private var chain: AudioChain?
    private var aggregateID: AudioDeviceID?
    private var savedOutput: AudioDeviceID?
    private(set) var prefs: Prefs

    /// The output device and profile the running chain was built for.
    private(set) var activeDeviceUID: String?
    private var activeDeviceName: String?
    private(set) var activeProfileID: String?

    /// Called (on main) when a safety guard shuts the chain down. String = reason.
    var onSafety: ((String) -> Void)?
    private var watchdog: Timer?

    private var prefsURL: URL { AppPaths.prefsURL(home: home) }
    private var activeStateURL: URL? { activeProfileID.map { store.stateURL(id: $0) } }

    init() {
        store = ProfileStore(home: home)
        prefs = PrefsStore.load(from: AppPaths.prefsURL(home: home))
        _ = try? store.migrateLegacyFullStateIfNeeded()   // adopt a pre-profiles single state
    }

    private func persistPrefs() { try? PrefsStore.save(prefs, to: prefsURL) }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let chain = self.chain else { return }
            klangDbg("diag \(chain.debugLine) def=\(self.dm.defaultOutputDeviceID())")   // TEMP
            if chain.feedbackDetected { self.triggerSafety("Possible audio feedback detected") }
        }
    }

    private func triggerSafety(_ reason: String) {
        guard isActive else { return }
        deactivate()
        onSafety?(reason)
    }

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

    private func isBlackHole(_ id: AudioDeviceID, in list: [AudioDeviceInfo]) -> Bool {
        list.first { $0.id == id }?.name.lowercased().contains("blackhole") ?? false
    }

    /// If a previous run crashed while active, the default output is stranded on
    /// BlackHole with nothing draining it. Restore it.
    func recoverIfNeeded() {
        let list = dm.listDevices()
        let current = dm.defaultOutputDeviceID()
        if CrashRecovery.shouldRestoreDefaultOutput(
            currentDefaultIsBlackHole: isBlackHole(current, in: list),
            engineRunning: isActive),
           let phys = DeviceMatcher.physicalOutput(in: list, excludingUID: nil) {
            dm.setDefaultOutput(phys.id)
        }
    }

    func activate(_ completion: @escaping (Result<Void, Error>) -> Void) {
        PermissionManager.ensureMic { [weak self] granted in
            guard let self = self else { return }
            guard granted else { completion(.failure(AppError.micDenied)); return }

            let list = self.dm.listDevices()
            guard let out = self.resolveTargetOutput(in: list),
                  let bh = DeviceMatcher.blackHole(in: list) else {
                completion(.failure(AppError.missingDevices)); return
            }

            let rate = SampleRateNegotiator.bestCommonRate(
                preferred: 96000, bh.supportedRates, out.supportedRates) ?? 48000
            self.dm.setNominalSampleRate(rate, deviceID: bh.id)
            self.dm.setNominalSampleRate(rate, deviceID: out.id)

            guard let aggID = self.agg.create(AggregateSpec.make(outputUID: out.uid, inputUID: bh.uid)) else {
                completion(.failure(AppError.aggregateFailed)); return
            }
            self.aggregateID = aggID
            self.savedOutput = out.id
            self.activeDeviceUID = out.uid
            self.activeDeviceName = out.name
            self.prefs.inputUID = bh.uid
            self.persistPrefs()

            let profile = self.resolveProfile(forDeviceUID: out.uid)
            self.activeProfileID = profile.id

            let chain = AudioChain(sampleRate: rate)
            chain.start(aggregateID: aggID,
                        initialStateURL: self.store.stateURL(id: profile.id),
                        captureChannelOffset: out.inputChannels) { result in
                switch result {
                case .failure(let e):
                    self.agg.destroy(aggID); self.aggregateID = nil
                    self.activeDeviceUID = nil; self.activeDeviceName = nil; self.activeProfileID = nil
                    completion(.failure(e))
                case .success:
                    self.chain = chain
                    klangDbg("setDefault BlackHole id=\(bh.id) (activate)")   // TEMP
                    self.dm.setDefaultOutput(bh.id)
                    self.startWatchdog()
                    completion(.success(()))
                }
            }
        }
    }

    /// User-chosen target when set and still present; otherwise the current default
    /// output (falling back to the first physical output when the default is BlackHole).
    private func resolveTargetOutput(in list: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        if let uid = prefs.outputUID,
           let chosen = DeviceMatcher.selectableOutputs(in: list).first(where: { $0.uid == uid }) {
            return chosen
        }
        var targetID = dm.defaultOutputDeviceID()
        if isBlackHole(targetID, in: list),
           let phys = DeviceMatcher.physicalOutput(in: list, excludingUID: nil) {
            targetID = phys.id   // never target BlackHole itself
        }
        return list.first { $0.id == targetID }
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
        klangDbg("deactivate() called")   // TEMP
        watchdog?.invalidate()
        watchdog = nil
        if let saved = savedOutput { klangDbg("setDefault saved=\(saved) (deactivate)"); dm.setDefaultOutput(saved) }
        if let url = activeStateURL { chain?.saveState(to: url) }
        chain?.stop()
        chain = nil
        if let id = aggregateID { agg.destroy(id) }
        aggregateID = nil
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
    /// on the new device (deactivate fully first so the safety guard, gated on isActive,
    /// never false-fires on the intermediate default-output writes).
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
        // If something external (a DAW, the user) changes the system default
        // output away from BlackHole while active, shut down to avoid feedback.
        dm.onDefaultOutputChanged { [weak self] in
            guard let self = self else { return }
            let def = self.dm.defaultOutputDeviceID()
            let list = self.dm.listDevices()
            let isBH = self.isBlackHole(def, in: list)
            klangDbg("defaultOutputChanged def=\(def) isBH=\(isBH) isActive=\(self.isActive)")   // TEMP
            guard self.isActive else { return }
            if !isBH {
                self.triggerSafety("System audio output changed (another app took over)")
                handler()
            }
        }
    }
}
