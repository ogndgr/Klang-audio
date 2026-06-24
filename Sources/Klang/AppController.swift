import Foundation
import CoreAudio
import AudioToolbox
import KlangCore

enum AppError: Error { case micDenied, missingDevices, aggregateFailed }

/// Orchestrates the whole chain: device selection, sample-rate negotiation,
/// aggregate lifecycle, default-output switching, and crash recovery.
final class AppController {
    private let dm = DeviceManager()
    private let agg = AggregateDevice()
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var chain: AudioChain?
    private var aggregateID: AudioDeviceID?
    private var savedOutput: AudioDeviceID?
    private(set) var prefs: Prefs

    init() { prefs = PrefsStore.load(from: AppPaths.prefsURL(home: home)) }

    var isActive: Bool { chain?.isRunning ?? false }
    var effectAU: AUAudioUnit? { chain?.effectAU }

    var bypass: Bool {
        get { chain?.bypass ?? false }
        set { chain?.bypass = newValue }
    }

    var statusText: String {
        guard isActive else { return "Pasif" }
        return "BlackHole → DT 990 Pro X · \(bypass ? "bypass" : "EQ")"
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
            var targetID = self.dm.defaultOutputDeviceID()
            if self.isBlackHole(targetID, in: list),
               let phys = DeviceMatcher.physicalOutput(in: list, excludingUID: nil) {
                targetID = phys.id   // never target BlackHole itself
            }
            guard let out = list.first(where: { $0.id == targetID }),
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
            self.prefs.outputUID = out.uid
            self.prefs.inputUID = bh.uid
            try? PrefsStore.save(self.prefs, to: AppPaths.prefsURL(home: self.home))

            let chain = AudioChain(sampleRate: rate)
            chain.start(aggregateID: aggID) { result in
                switch result {
                case .failure(let e):
                    self.agg.destroy(aggID); self.aggregateID = nil
                    completion(.failure(e))
                case .success:
                    self.chain = chain
                    self.dm.setDefaultOutput(bh.id)
                    completion(.success(()))
                }
            }
        }
    }

    func deactivate() {
        if let saved = savedOutput { dm.setDefaultOutput(saved) }
        chain?.saveState(home: home)
        chain?.stop()
        chain = nil
        if let id = aggregateID { agg.destroy(id) }
        aggregateID = nil
    }

    func saveStateNow() { chain?.saveState(home: home) }

    func observeDeviceChanges(_ handler: @escaping () -> Void) {
        dm.onDevicesChanged { [weak self] in
            guard let self = self else { return }
            if self.isActive {
                let list = self.dm.listDevices()
                let stillThere = self.prefs.outputUID.map { uid in
                    list.contains { $0.uid == uid }
                } ?? false
                if !stillThere { self.deactivate() }
            }
            handler()
        }
    }
}
