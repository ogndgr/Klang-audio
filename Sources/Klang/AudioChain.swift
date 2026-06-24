import AVFoundation
import AudioToolbox
import KlangCore

enum AudioChainError: Error { case instantiateFailed(OSStatus) }

final class AudioChain {
    private let engine = AVAudioEngine()
    private var effect: AVAudioUnit?

    var isRunning: Bool { engine.isRunning }
    var audioUnit: AUAudioUnit? { effect?.auAudioUnit }

    var inputFormatDescription: String {
        let f = engine.inputNode.inputFormat(forBus: 0)
        return "\(Int(f.sampleRate))Hz \(f.channelCount)ch"
    }

    var bypass: Bool {
        get { effect?.auAudioUnit.shouldBypassEffect ?? false }
        set { effect?.auAudioUnit.shouldBypassEffect = newValue }
    }

    func start(aggregateID: AudioDeviceID,
               completion: @escaping (Result<Void, Error>) -> Void) {
        // Bind the engine's HAL IO unit to the aggregate (input + output).
        var dev = aggregateID
        if let outAU = engine.outputNode.audioUnit {
            AudioUnitSetProperty(outAU, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let acd = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("BdHL"),
            componentManufacturer: fourCC("Beyd"),
            componentFlags: 0, componentFlagsMask: 0)

        AVAudioUnit.instantiate(with: acd, options: []) { [weak self] avUnit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { completion(.failure(error)); return }
                guard let avUnit else {
                    completion(.failure(AudioChainError.instantiateFailed(-1))); return
                }

                self.engine.attach(avUnit)
                let fmt = self.engine.inputNode.inputFormat(forBus: 0)
                self.engine.connect(self.engine.inputNode, to: avUnit, format: fmt)
                self.engine.connect(avUnit, to: self.engine.mainMixerNode, format: fmt)
                self.effect = avUnit
                self.loadState(home: FileManager.default.homeDirectoryForCurrentUser)

                self.engine.prepare()
                do { try self.engine.start(); completion(.success(())) }
                catch { completion(.failure(error)) }
            }
        }
    }

    func stop() {
        engine.stop()
        if let e = effect { engine.detach(e) }
        effect = nil
    }

    func saveState(home: URL) {
        guard let state = effect?.auAudioUnit.fullState else { return }
        let url = AppPaths.fullStateURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: state,
                                                          format: .binary, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadState(home: URL) {
        let url = AppPaths.fullStateURL(home: home)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let state = plist as? [String: Any] else { return }
        effect?.auAudioUnit.fullState = state
    }
}
