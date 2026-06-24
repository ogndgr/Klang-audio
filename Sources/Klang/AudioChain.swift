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
/// AVAudioEngine cannot point its input node at an arbitrary capture device on
/// macOS without hijacking the system default input, so we drive CoreAudio directly.
final class AudioChain {
    private let sampleRate: Double
    private let maxFrames: UInt32 = 4096

    fileprivate var halUnit: AudioUnit?
    private var effect: AVAudioUnit?
    private var effectAU: AUAudioUnit?
    fileprivate var effectRenderBlock: AURenderBlock?
    fileprivate var pullBlock: AURenderPullInputBlock?
    fileprivate var captureABL: UnsafeMutableAudioBufferListPointer?
    private var started = false

    // Diagnostics (written from the realtime thread; approximate by design).
    fileprivate var dbgInCalls = 0
    fileprivate var dbgOutCalls = 0
    fileprivate var dbgInPeak: Float = 0
    fileprivate var dbgOutPeak: Float = 0
    fileprivate var dbgStatus: OSStatus = 0

    func debugSnapshot() -> String {
        String(format: "in:%d out:%d inPeak:%.4f outPeak:%.4f renderSt:%d",
               dbgInCalls, dbgOutCalls, dbgInPeak, dbgOutPeak, Int(dbgStatus))
    }

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    var isRunning: Bool { started }
    var audioUnit: AUAudioUnit? { effectAU }
    var inputFormatDescription: String { "\(Int(sampleRate))Hz 2ch HAL duplex" }

    var bypass: Bool {
        get { effectAU?.shouldBypassEffect ?? false }
        set { effectAU?.shouldBypassEffect = newValue }
    }

    func start(aggregateID: AudioDeviceID, startIO: Bool = true,
               completion: @escaping (Result<Void, Error>) -> Void) {
        let acd = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("BdHL"),
            componentManufacturer: fourCC("Beyd"),
            componentFlags: 0, componentFlagsMask: 0)
        let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate, channels: 2, interleaved: false)!

        AVAudioUnit.instantiate(with: acd, options: []) { [weak self] avUnit, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error { completion(.failure(error)); return }
                guard let avUnit = avUnit else { completion(.failure(AudioChainError.effectNotFound)); return }
                do {
                    try self.configure(avUnit: avUnit, aggregateID: aggregateID,
                                       procFormat: procFormat, startIO: startIO)
                    completion(.success(()))
                } catch {
                    self.stop()
                    completion(.failure(error))
                }
            }
        }
    }

    private func configure(avUnit: AVAudioUnit, aggregateID: AudioDeviceID,
                           procFormat: AVAudioFormat, startIO: Bool) throws {
        // --- v3 effect: format, resources, render block ---
        let au = avUnit.auAudioUnit
        try au.inputBusses[0].setFormat(procFormat)
        try au.outputBusses[0].setFormat(procFormat)
        au.maximumFramesToRender = maxFrames
        try au.allocateRenderResources()
        effect = avUnit
        effectAU = au
        effectRenderBlock = au.renderBlock
        loadState(home: FileManager.default.homeDirectoryForCurrentUser)

        // --- capture buffer: 2 mono (non-interleaved) channels ---
        let bytes = Int(maxFrames) * MemoryLayout<Float>.size
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        for i in 0..<2 {
            let mem = malloc(bytes)!
            memset(mem, 0, bytes)
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: mem)
        }
        captureABL = abl
        let cap = abl
        pullBlock = { _, _, frames, _, ioData in
            let inABL = UnsafeMutableAudioBufferListPointer(ioData)
            for i in 0..<min(inABL.count, cap.count) {
                inABL[i].mNumberChannels = 1
                inABL[i].mDataByteSize = frames * 4
                inABL[i].mData = cap[i].mData     // lend the captured samples
            }
            return noErr
        }

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

        let u32 = UInt32(MemoryLayout<UInt32>.size)
        var one: UInt32 = 1
        try check("EnableIO input", AudioUnitSetProperty(hal, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &one, u32))
        try check("EnableIO output", AudioUnitSetProperty(hal, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &one, u32))

        var dev = aggregateID
        try check("SetDevice", AudioUnitSetProperty(hal, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)))

        var asbd = procFormat.streamDescription.pointee
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("Format input(scope=output, el1)", AudioUnitSetProperty(hal, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &asbd, asbdSize))
        try check("Format output(scope=input, el0)", AudioUnitSetProperty(hal, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &asbd, asbdSize))

        var mfs = maxFrames
        try check("MaxFramesPerSlice", AudioUnitSetProperty(hal, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &mfs, u32))

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        var inputCB = AURenderCallbackStruct(inputProc: klangInputProc, inputProcRefCon: ctx)
        try check("SetInputCallback", AudioUnitSetProperty(hal, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &inputCB, cbSize))
        var renderCB = AURenderCallbackStruct(inputProc: klangOutputProc, inputProcRefCon: ctx)
        try check("SetRenderCallback", AudioUnitSetProperty(hal, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &renderCB, cbSize))

        try check("HAL initialize", AudioUnitInitialize(hal))

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
        effectRenderBlock = nil
        pullBlock = nil
        if let cap = captureABL {
            for b in cap { free(b.mData) }
            free(cap.unsafeMutablePointer)
            captureABL = nil
        }
        effectAU = nil
        effect = nil
    }

    func saveState(home: URL) {
        guard let state = effectAU?.fullState else { return }
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
        effectAU?.fullState = state
    }
}

// MARK: - Realtime C callbacks (no captured context; reach AudioChain via refCon)

private func klangInputProc(_ refCon: UnsafeMutableRawPointer,
                            _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frames: UInt32,
                            _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let chain = Unmanaged<AudioChain>.fromOpaque(refCon).takeUnretainedValue()
    guard let hal = chain.halUnit, let cap = chain.captureABL else { return noErr }
    for i in 0..<cap.count { cap[i].mDataByteSize = frames * 4 }
    let st = AudioUnitRender(hal, flags, ts, 1, frames, cap.unsafeMutablePointer)
    chain.dbgInCalls &+= 1
    if st == noErr { chain.dbgInPeak = peak(cap, frames: frames) }
    return st
}

private func peak(_ abl: UnsafeMutableAudioBufferListPointer, frames: UInt32) -> Float {
    var m: Float = 0
    let n = Int(frames)
    for b in abl {
        guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
        var i = 0
        while i < n { let v = Swift.abs(p[i]); if v > m { m = v }; i += 1 }
    }
    return m
}

private func klangOutputProc(_ refCon: UnsafeMutableRawPointer,
                             _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ ts: UnsafePointer<AudioTimeStamp>,
                             _ bus: UInt32, _ frames: UInt32,
                             _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let chain = Unmanaged<AudioChain>.fromOpaque(refCon).takeUnretainedValue()
    guard let render = chain.effectRenderBlock, let pull = chain.pullBlock, let ioData = ioData else {
        if let ioData = ioData {
            let abl = UnsafeMutableAudioBufferListPointer(ioData)
            for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        }
        return noErr
    }
    var f = flags.pointee
    let st = render(&f, ts, frames, 0, ioData, pull)
    flags.pointee = f
    chain.dbgOutCalls &+= 1
    chain.dbgStatus = st
    chain.dbgOutPeak = peak(UnsafeMutableAudioBufferListPointer(ioData), frames: frames)
    return st
}
