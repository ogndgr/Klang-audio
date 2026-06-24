import AVFoundation
import AudioToolbox
import CoreAudio
import KlangCore

enum AudioChainError: Error {
    case effectNotFound
    case halNotFound
    case osStatus(String, OSStatus)
}

private func check(_ label: String, _ st: OSStatus) throws {
    if st != noErr { throw AudioChainError.osStatus(label, st) }
}

/// Hosts the Headphone Lab effect on a single HALOutput AudioUnit running duplex
/// on the aggregate device (BlackHole input + headphones output share one clock).
/// The effect is instantiated via AVAudioUnit so we get both the v2 handle (for
/// manual AudioUnitRender) and the v3 AUAudioUnit (for the plugin's view).
final class AudioChain {
    private let sampleRate: Double
    private let maxFrames: UInt32 = 4096

    fileprivate var halUnit: AudioUnit?
    fileprivate var effectV2: AudioUnit?
    private var avEffect: AVAudioUnit?
    fileprivate var captureABL: UnsafeMutableAudioBufferListPointer?
    private var started = false
    private var bypassed = false

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    var isRunning: Bool { started }
    var effectAU: AUAudioUnit? { avEffect?.auAudioUnit }
    var inputFormatDescription: String { "\(Int(sampleRate))Hz 2ch HAL duplex" }

    var bypass: Bool {
        get { bypassed }
        set {
            bypassed = newValue
            guard let fx = effectV2 else { return }
            var v: UInt32 = newValue ? 1 : 0
            AudioUnitSetProperty(fx, kAudioUnitProperty_BypassEffect,
                                 kAudioUnitScope_Global, 0, &v, UInt32(MemoryLayout<UInt32>.size))
        }
    }

    func start(aggregateID: AudioDeviceID, startIO: Bool = true,
               completion: @escaping (Result<Void, Error>) -> Void) {
        let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate, channels: 2, interleaved: false)!
        let acd = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("BdHL"),
            componentManufacturer: fourCC("Beyd"),
            componentFlags: 0, componentFlagsMask: 0)

        AVAudioUnit.instantiate(with: acd, options: []) { [weak self] avUnit, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error { completion(.failure(error)); return }
                guard let avUnit = avUnit else { completion(.failure(AudioChainError.effectNotFound)); return }
                do {
                    try self.configure(avEffect: avUnit, aggregateID: aggregateID,
                                       procFormat: procFormat, startIO: startIO)
                    completion(.success(()))
                } catch {
                    self.stop()
                    completion(.failure(error))
                }
            }
        }
    }

    private func configure(avEffect: AVAudioUnit, aggregateID: AudioDeviceID,
                           procFormat: AVAudioFormat, startIO: Bool) throws {
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = procFormat.streamDescription.pointee
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        // --- capture buffer: 2 mono (non-interleaved) channels ---
        let bytes = Int(maxFrames) * MemoryLayout<Float>.size
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        for i in 0..<2 {
            let mem = malloc(bytes)!
            memset(mem, 0, bytes)
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: mem)
        }
        captureABL = abl

        // --- Headphone Lab effect: v2 handle from the AVAudioUnit ---
        self.avEffect = avEffect
        let fx = avEffect.audioUnit
        effectV2 = fx
        AudioUnitUninitialize(fx)   // ensure uninitialized so stream formats are settable
        try check("FX fmt in", AudioUnitSetProperty(fx, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &asbd, asbdSize))
        try check("FX fmt out", AudioUnitSetProperty(fx, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &asbd, asbdSize))
        var mfs = maxFrames
        try check("FX maxframes", AudioUnitSetProperty(fx, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &mfs, u32))
        var fxInCB = AURenderCallbackStruct(inputProc: klangEffectInputProc, inputProcRefCon: ctx)
        try check("FX input cb", AudioUnitSetProperty(fx, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &fxInCB, cbSize))
        try check("FX init", AudioUnitInitialize(fx))
        loadState(home: FileManager.default.homeDirectoryForCurrentUser)

        // --- HALOutput IO unit on the aggregate ---
        var halDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &halDesc) else { throw AudioChainError.halNotFound }
        var unit: AudioUnit?
        try check("HAL new", AudioComponentInstanceNew(comp, &unit))
        guard let hal = unit else { throw AudioChainError.halNotFound }
        halUnit = hal

        var one: UInt32 = 1
        try check("EnableIO input", AudioUnitSetProperty(hal, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &one, u32))
        try check("EnableIO output", AudioUnitSetProperty(hal, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &one, u32))
        var dev = aggregateID
        try check("SetDevice", AudioUnitSetProperty(hal, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)))
        try check("Format input(scope=output, el1)", AudioUnitSetProperty(hal, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &asbd, asbdSize))
        try check("Format output(scope=input, el0)", AudioUnitSetProperty(hal, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &asbd, asbdSize))
        var mfs2 = maxFrames
        try check("MaxFramesPerSlice", AudioUnitSetProperty(hal, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &mfs2, u32))
        var inputCB = AURenderCallbackStruct(inputProc: klangInputProc, inputProcRefCon: ctx)
        try check("SetInputCallback", AudioUnitSetProperty(hal, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &inputCB, cbSize))
        var renderCB = AURenderCallbackStruct(inputProc: klangOutputProc, inputProcRefCon: ctx)
        try check("SetRenderCallback", AudioUnitSetProperty(hal, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &renderCB, cbSize))
        try check("HAL initialize", AudioUnitInitialize(hal))

        bypass = bypassed   // re-apply to the fresh effect instance

        if startIO {
            try check("HAL start", AudioOutputUnitStart(hal))
            started = true
        }
    }

    func stop() {
        if let hal = halUnit {
            if started { AudioOutputUnitStop(hal) }
            AudioUnitUninitialize(hal)
            AudioComponentInstanceDispose(hal)
            halUnit = nil
        }
        started = false
        if let fx = effectV2 { AudioUnitUninitialize(fx) }
        effectV2 = nil
        avEffect = nil   // AVAudioUnit disposes the underlying AU
        if let cap = captureABL {
            for b in cap { free(b.mData) }
            free(cap.unsafeMutablePointer)
            captureABL = nil
        }
    }

    func saveState(home: URL) {
        guard let fx = effectV2 else { return }
        var info: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioUnitGetProperty(fx, kAudioUnitProperty_ClassInfo,
                                   kAudioUnitScope_Global, 0, &info, &size) == noErr,
              let plist = info?.takeRetainedValue() else { return }
        let url = AppPaths.fullStateURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .binary, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadState(home: URL) {
        guard let fx = effectV2 else { return }
        let url = AppPaths.fullStateURL(home: home)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? NSDictionary else { return }
        var cf = dict as CFPropertyList
        _ = AudioUnitSetProperty(fx, kAudioUnitProperty_ClassInfo,
                                 kAudioUnitScope_Global, 0, &cf,
                                 UInt32(MemoryLayout<CFPropertyList>.size))
    }
}

// MARK: - Realtime C callbacks (no captured context; reach AudioChain via refCon)

/// HAL input available → render the captured samples into our capture buffer.
private func klangInputProc(_ refCon: UnsafeMutableRawPointer,
                            _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frames: UInt32,
                            _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let chain = Unmanaged<AudioChain>.fromOpaque(refCon).takeUnretainedValue()
    guard let hal = chain.halUnit, let cap = chain.captureABL else { return noErr }
    for i in 0..<cap.count { cap[i].mDataByteSize = frames * 4 }
    return AudioUnitRender(hal, flags, ts, 1, frames, cap.unsafeMutablePointer)
}

/// Effect needs input → hand it the captured samples.
private func klangEffectInputProc(_ refCon: UnsafeMutableRawPointer,
                                  _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                  _ ts: UnsafePointer<AudioTimeStamp>,
                                  _ bus: UInt32, _ frames: UInt32,
                                  _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let chain = Unmanaged<AudioChain>.fromOpaque(refCon).takeUnretainedValue()
    guard let cap = chain.captureABL, let ioData = ioData else { return noErr }
    let out = UnsafeMutableAudioBufferListPointer(ioData)
    let byteCount = Int(frames) * 4
    for i in 0..<min(out.count, cap.count) {
        out[i].mNumberChannels = 1
        out[i].mDataByteSize = UInt32(byteCount)
        if let dst = out[i].mData, let src = cap[i].mData {
            memcpy(dst, src, byteCount)
        } else {
            out[i].mData = cap[i].mData
        }
    }
    return noErr
}

/// HAL needs output → render the effect into the output buffer.
private func klangOutputProc(_ refCon: UnsafeMutableRawPointer,
                             _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ ts: UnsafePointer<AudioTimeStamp>,
                             _ bus: UInt32, _ frames: UInt32,
                             _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let chain = Unmanaged<AudioChain>.fromOpaque(refCon).takeUnretainedValue()
    guard let fx = chain.effectV2, let ioData = ioData else {
        if let ioData = ioData {
            let abl = UnsafeMutableAudioBufferListPointer(ioData)
            for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        }
        return noErr
    }
    return AudioUnitRender(fx, flags, ts, 0, frames, ioData)
}
