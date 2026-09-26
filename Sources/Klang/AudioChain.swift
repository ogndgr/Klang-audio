import AVFoundation
import AudioToolbox
import CoreAudio
import KlangCore
// TEMP diagnostics — os_log isn't readable from the tool shell, so mirror to a file.
private let dbgLogURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/klang-debug.log")
private let dbgQueue = DispatchQueue(label: "com.klang.debug.file")
private let dbgClock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
}()
func klangDbg(_ line: String) {
    let entry = dbgClock.string(from: Date()) + " " + line + "\n"
    dbgQueue.async {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dbgLogURL.path) {
            try? fm.createDirectory(at: dbgLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: dbgLogURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: dbgLogURL) else { return }
        h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close()
    }
}

enum AudioChainError: Error {
    case effectNotFound
    case osStatus(String, OSStatus)
}

private func check(_ label: String, _ st: OSStatus) throws {
    if st != noErr { throw AudioChainError.osStatus(label, st) }
}

/// Hosts the Headphone Lab effect on a plain device IOProc running on the aggregate
/// (system-audio tap input + target output share one clock). AUHAL is deliberately not
/// used: enabling its input triggers a microphone TCC check that zeroes the tap. The
/// effect is instantiated via AVAudioUnit so the v2 handle can be rendered manually.
final class AudioChain {
    private let sampleRate: Double
    private let maxFrames: UInt32 = 4096

    fileprivate var effectV2: AudioUnit?
    private var avEffect: AVAudioUnit?
    fileprivate var captureABL: UnsafeMutableAudioBufferListPointer?
    private var renderABL: UnsafeMutableAudioBufferListPointer?
    private var sampleTime: Float64 = 0
    private var deviceID: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private var started = false
    private var bypassed = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    var isRunning: Bool { started }
    /// The v2 handle used for both rendering and hosting the plugin UI (Cocoa UI).
    /// Requesting the v3 view controller instead disturbs the shared JUCE AU state
    /// and silences the v2 render path, so the v3 handle is deliberately never used.
    var renderAudioUnit: AudioUnit? { effectV2 }

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

    func start(aggregateID: AudioDeviceID, initialStateURL: URL?, startIO: Bool = true,
               completion: @escaping (Result<Void, Error>) -> Void) {
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
                    try self.configureEffect(avUnit, initialStateURL: initialStateURL)
                    try self.configureIO(aggregateID: aggregateID, startIO: startIO)
                    completion(.success(()))
                } catch {
                    self.stop()
                    completion(.failure(error))
                }
            }
        }
    }

    private static func makeStereoBuffers(frames: UInt32) -> UnsafeMutableAudioBufferListPointer {
        let bytes = Int(frames) * MemoryLayout<Float>.size
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        for i in 0..<2 {
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: calloc(bytes, 1))
        }
        return abl
    }

    private func configureEffect(_ avEffect: AVAudioUnit, initialStateURL: URL?) throws {
        let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate, channels: 2, interleaved: false)!
        var asbd = procFormat.streamDescription.pointee
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        captureABL = Self.makeStereoBuffers(frames: maxFrames)
        renderABL = Self.makeStereoBuffers(frames: maxFrames)

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
            kAudioUnitScope_Global, 0, &mfs, UInt32(MemoryLayout<UInt32>.size)))
        var fxInCB = AURenderCallbackStruct(inputProc: klangEffectInputProc,
                                            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check("FX input cb", AudioUnitSetProperty(fx, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &fxInCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check("FX init", AudioUnitInitialize(fx))
        if let initialStateURL = initialStateURL { loadState(from: initialStateURL) }
        bypass = bypassed   // re-apply to the fresh effect instance
    }

    private func configureIO(aggregateID: AudioDeviceID, startIO: Bool) throws {
        deviceID = aggregateID
        try check("IOProc create", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            [unowned self] _, inData, _, outData, _ in
            self.process(input: inData, output: outData)
        })
        restrictStreams()
        if startIO {
            try check("IO start", AudioDeviceStart(aggregateID, procID))
            started = true
        }
    }

    /// Open only the tap (the aggregate's last input stream) and the streams carrying
    /// output channels 0/1. A target with its own inputs (USB interface) thus never has
    /// its hardware inputs opened. Best effort: if the device refuses, every stream stays
    /// on and `process` still picks the tap and the first two output channels.
    private func restrictStreams() {
        guard let procID = procID else { return }
        let inputs = streamChannelCounts(kAudioObjectPropertyScopeInput)
        let outputs = streamChannelCounts(kAudioObjectPropertyScopeOutput)
        setStreamUsage(procID, kAudioObjectPropertyScopeInput,
                       on: inputs.indices.map { $0 == inputs.count - 1 })
        var firstChannel = 0
        setStreamUsage(procID, kAudioObjectPropertyScopeOutput, on: outputs.map { n in
            defer { firstChannel += n }
            return firstChannel < 2
        })
    }

    private func streamChannelCounts(_ scope: AudioObjectPropertyScope) -> [Int] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                           mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &a, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .map { Int($0.mNumberChannels) }
    }

    private func setStreamUsage(_ procID: AudioDeviceIOProcID, _ scope: AudioObjectPropertyScope, on: [Bool]) {
        guard !on.isEmpty,
              let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let size = flagsOffset + on.count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size,
                                                   alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(on.count)
        let flags = (raw + flagsOffset).bindMemory(to: UInt32.self, capacity: on.count)
        for (i, isOn) in on.enumerated() { flags[i] = isOn ? 1 : 0 }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                           mScope: scope, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(deviceID, &a, 0, nil, UInt32(size), raw)
    }

    // MARK: Realtime

    /// Tap stream (interleaved) → capture buffers → Headphone Lab → output channels 0/1.
    private func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outL = UnsafeMutableAudioBufferListPointer(output)
        guard let fx = effectV2, let cap = captureABL, let ren = renderABL,
              let tap = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).last,
              let src = tap.mData?.assumingMemoryBound(to: Float.self), tap.mNumberChannels > 0 else {
            silence(outL); return
        }
        let inCh = Int(tap.mNumberChannels)
        let frames = Int(tap.mDataByteSize) / (inCh * MemoryLayout<Float>.size)
        guard frames > 0, frames <= Int(maxFrames) else { silence(outL); return }

        let capL = cap[0].mData!.assumingMemoryBound(to: Float.self)
        let capR = cap[1].mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            capL[i] = src[i * inCh]
            capR[i] = src[i * inCh + (inCh > 1 ? 1 : 0)]
        }

        for i in 0..<2 { ren[i].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size) }
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        sampleTime += Float64(frames)
        guard AudioUnitRender(fx, &flags, &ts, 0, UInt32(frames), ren.unsafeMutablePointer) == noErr else {
            silence(outL); return
        }

        let renL = ren[0].mData!.assumingMemoryBound(to: Float.self)
        let renR = ren[1].mData!.assumingMemoryBound(to: Float.self)
        var channel = 0
        for b in outL {
            let n = Int(b.mNumberChannels)
            defer { channel += n }
            guard n > 0, let dst = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outFrames = min(frames, Int(b.mDataByteSize) / (n * MemoryLayout<Float>.size))
            for c in 0..<n {
                let g = channel + c
                if g < 2 {
                    let r = g == 0 ? renL : renR
                    for i in 0..<outFrames { dst[i * n + c] = r[i] }
                } else {
                    for i in 0..<outFrames { dst[i * n + c] = 0 }
                }
            }
        }
    }

    private func silence(_ abl: UnsafeMutableAudioBufferListPointer) {
        for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    }

    func stop() {
        if let procID = procID {
            if started { AudioDeviceStop(deviceID, procID) }
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        started = false
        if let fx = effectV2 { AudioUnitUninitialize(fx) }
        effectV2 = nil
        avEffect = nil   // AVAudioUnit disposes the underlying AU
        for abl in [captureABL, renderABL].compactMap({ $0 }) {
            for b in abl { free(b.mData) }
            free(abl.unsafeMutablePointer)
        }
        captureABL = nil
        renderABL = nil
    }

    /// Snapshot the live effect's ClassInfo to `url` (the active profile's state file).
    func saveState(to url: URL) {
        guard let fx = effectV2 else { return }
        var info: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let getStatus = AudioUnitGetProperty(fx, kAudioUnitProperty_ClassInfo,
                                             kAudioUnitScope_Global, 0, &info, &size)
        guard getStatus == noErr, let plist = info?.takeRetainedValue() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .binary, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Apply the ClassInfo stored at `url` to the live effect. Used both for the
    /// initial load on start and for instant profile switching while running.
    func loadState(from url: URL) {
        guard let fx = effectV2 else { return }
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? NSDictionary else { return }
        var cfDict = dict as CFDictionary
        _ = withUnsafePointer(to: &cfDict) {
            AudioUnitSetProperty(fx, kAudioUnitProperty_ClassInfo,
                                 kAudioUnitScope_Global, 0, $0,
                                 UInt32(MemoryLayout<CFDictionary>.size))
        }
    }
}

// MARK: - Realtime C callback (no captured context; reach AudioChain via refCon)

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
