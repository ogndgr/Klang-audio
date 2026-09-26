import Foundation
import CoreAudio
import AudioToolbox
import KlangCore

let args = CommandLine.arguments
var gRetain: [Any] = []

if args.contains("--list-devices") {
    let dm = DeviceManager()
    for d in dm.listDevices() {
        let io = "\(d.isInput ? "in" : "  ")/\(d.isOutput ? "out" : "   ")"
        print("id=\(d.id) [\(io)] \(d.isVirtual ? "V" : " ") \(d.name) — \(d.uid) — rates \(d.supportedRates.map { Int($0) })")
    }
    print("default output id:", dm.defaultOutputDeviceID())
    let list = dm.listDevices()
    print("BlackHole:", DeviceMatcher.blackHole(in: list)?.name ?? "none")
    print("Physical out:", DeviceMatcher.physicalOutput(in: list, excludingUID: nil)?.name ?? "none")
    exit(0)
}

if args.contains("--test-aggregate") {
    let dm = DeviceManager()
    let list = dm.listDevices()
    guard let bh = DeviceMatcher.blackHole(in: list),
          let out = DeviceMatcher.physicalOutput(in: list, excludingUID: nil) else {
        print("missing devices"); exit(1)
    }
    let spec = AggregateSpec.make(outputUID: out.uid, inputUID: bh.uid)
    let agg = AggregateDevice()
    guard let id = agg.create(spec) else { print("create failed"); exit(1) }
    print("created aggregate id:", id, "(master \(out.name), input \(bh.name))")
    agg.destroy(id)
    print("destroyed ok")
    exit(0)
}

func negotiatedRate(_ dm: DeviceManager, _ bh: AudioDeviceInfo, _ out: AudioDeviceInfo) -> Double {
    SampleRateNegotiator.bestCommonRate(preferred: 96000, bh.supportedRates, out.supportedRates) ?? 48000
}

if args.contains("--restore") {
    // Recovery: force the system default output back to the physical headphones
    // (use if a previous run left it stuck on BlackHole). No mic needed.
    let dm = DeviceManager()
    let list = dm.listDevices()
    guard let out = DeviceMatcher.physicalOutput(in: list, excludingUID: nil),
          let id = dm.deviceID(forUID: out.uid) else { print("no physical output found"); exit(1) }
    dm.setDefaultOutput(id)
    print("default output restored to:", out.name)
    exit(0)
}

if args.contains("--test-halsetup") {
    // Validates the full HAL/effect configuration WITHOUT starting audio (no mic
    // capture, no output), so it can be run non-interactively to catch config bugs.
    let dm = DeviceManager()
    let agg = AggregateDevice()
    let list = dm.listDevices()
    guard let bh = DeviceMatcher.blackHole(in: list),
          let out = DeviceMatcher.physicalOutput(in: list, excludingUID: nil) else {
        print("missing devices"); exit(1)
    }
    let rate = negotiatedRate(dm, bh, out)
    guard let aggID = agg.create(AggregateSpec.make(outputUID: out.uid, inputUID: bh.uid)) else {
        print("aggregate create failed"); exit(1)
    }
    let chain = AudioChain(sampleRate: rate)
    chain.start(aggregateID: aggID, initialStateURL: nil, startIO: false) { result in
        switch result {
        case .success: print("HAL setup OK — configured + initialized (IO not started) @\(Int(rate))Hz")
        case .failure(let e): print("HAL setup FAILED:", e)
        }
        chain.stop(); agg.destroy(aggID)
        exit(0)
    }
    RunLoop.main.run()
}

// Output-only silence render proc for --diag-grab (no mic needed).
func klangSilenceProc(_ refCon: UnsafeMutableRawPointer,
                      _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                      _ ts: UnsafePointer<AudioTimeStamp>,
                      _ bus: UInt32, _ frames: UInt32,
                      _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    if let ioData = ioData {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    }
    return noErr
}

if args.contains("--diag-grab") {
    // No-mic reproduction: start OUTPUT-ONLY IO on the aggregate (grabs the UMC202HD
    // which is the current default output) and watch whether macOS reassigns the
    // system default output away from BlackHole after we set it there.
    let dm = DeviceManager()
    let agg = AggregateDevice()
    func devName(_ id: AudioDeviceID) -> String {
        dm.listDevices().first { $0.id == id }.map { "\($0.name) [\(id)]" } ?? "unknown [\(id)]"
    }
    func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) }

    let list = dm.listDevices()
    guard let bh = DeviceMatcher.blackHole(in: list),
          let out = DeviceMatcher.physicalOutput(in: list, excludingUID: nil) else {
        print("missing devices"); exit(1)
    }
    let savedDefault = dm.defaultOutputDeviceID()
    print("[\(stamp())] initial default output:", devName(savedDefault))
    print("[\(stamp())] target physical output:", devName(out.id), "  BlackHole:", devName(bh.id))

    dm.onDefaultOutputChanged {
        let cur = dm.defaultOutputDeviceID()
        print("[\(stamp())] >>> DEFAULT-OUTPUT CHANGED →", devName(cur),
              cur == bh.id ? "(BlackHole ✓)" : "(NOT BlackHole ✗ — guard would TRIP)")
    }

    let rate = negotiatedRate(dm, bh, out)
    dm.setNominalSampleRate(rate, deviceID: bh.id)
    dm.setNominalSampleRate(rate, deviceID: out.id)
    guard let aggID = agg.create(AggregateSpec.make(outputUID: out.uid, inputUID: bh.uid)) else {
        print("aggregate create failed"); exit(1)
    }
    print("[\(stamp())] aggregate created:", aggID, "@\(Int(rate))Hz")

    var halDesc = AudioComponentDescription(componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    let comp = AudioComponentFindNext(nil, &halDesc)!
    var hal: AudioUnit?
    AudioComponentInstanceNew(comp, &hal)
    let unit = hal!
    var one: UInt32 = 1
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4)
    var zero: UInt32 = 0
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, 4)
    var dev = aggID
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
    var cb = AURenderCallbackStruct(inputProc: klangSilenceProc, inputProcRefCon: nil)
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                         UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    AudioUnitInitialize(unit)
    print("[\(stamp())] default before HAL start:", devName(dm.defaultOutputDeviceID()))
    AudioOutputUnitStart(unit)
    print("[\(stamp())] HAL output IO started (grabbed \(out.name)) — default now:", devName(dm.defaultOutputDeviceID()))
    dm.setDefaultOutput(bh.id)
    print("[\(stamp())] setDefaultOutput(BlackHole) issued — default now:", devName(dm.defaultOutputDeviceID()))

    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        let cur = dm.defaultOutputDeviceID()
        print("[\(stamp())] after 4s settle — default output:", devName(cur),
              cur == bh.id ? "(BlackHole ✓ — no false trip)" : "(NOT BlackHole ✗ — REVERTED, root cause confirmed)")
        dm.setDefaultOutput(savedDefault)
        AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
        agg.destroy(aggID)
        print("[\(stamp())] restored & stopped")
        exit(0)
    }
    RunLoop.main.run()
}

if args.contains("--diag-safety") {
    // Reproduces the exact activate() routing while logging every default-output
    // change, to see whether starting the aggregate (which grabs the physical
    // output that is the current system default) makes macOS reassign the default
    // away from BlackHole — the thing the safety guard would false-trip on.
    let dm = DeviceManager()
    let agg = AggregateDevice()

    func devName(_ id: AudioDeviceID) -> String {
        dm.listDevices().first { $0.id == id }.map { "\($0.name) [\(id)]" } ?? "unknown [\(id)]"
    }
    func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) }

    PermissionManager.ensureMic { granted in
        guard granted else { print("mic permission denied"); exit(1) }
        let list = dm.listDevices()
        guard let bh = DeviceMatcher.blackHole(in: list),
              let out = DeviceMatcher.physicalOutput(in: list, excludingUID: nil) else {
            print("missing devices"); exit(1)
        }
        let savedDefault = dm.defaultOutputDeviceID()
        print("[\(stamp())] initial default output:", devName(savedDefault))
        print("[\(stamp())] target physical output:", devName(out.id), "  BlackHole:", devName(bh.id))

        dm.onDefaultOutputChanged {
            let cur = dm.defaultOutputDeviceID()
            let isBH = cur == bh.id
            print("[\(stamp())] >>> DEFAULT-OUTPUT CHANGED →", devName(cur),
                  isBH ? "(BlackHole ✓)" : "(NOT BlackHole ✗ — guard would TRIP)")
        }

        let rate = negotiatedRate(dm, bh, out)
        dm.setNominalSampleRate(rate, deviceID: bh.id)
        dm.setNominalSampleRate(rate, deviceID: out.id)
        print("[\(stamp())] rates set @\(Int(rate))Hz on both")

        guard let aggID = agg.create(AggregateSpec.make(outputUID: out.uid, inputUID: bh.uid)) else {
            print("aggregate create failed"); exit(1)
        }
        print("[\(stamp())] aggregate created:", aggID)

        let chain = AudioChain(sampleRate: rate)
        chain.start(aggregateID: aggID, initialStateURL: nil) { result in
            switch result {
            case .failure(let e): print("start failed:", e); agg.destroy(aggID); exit(1)
            case .success:
                print("[\(stamp())] IO started (aggregate grabbed \(out.name)) — default now:", devName(dm.defaultOutputDeviceID()))
                dm.setDefaultOutput(bh.id)
                print("[\(stamp())] setDefaultOutput(BlackHole) issued — default now:", devName(dm.defaultOutputDeviceID()))
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let cur = dm.defaultOutputDeviceID()
            print("[\(stamp())] after 4s settle — default output:", devName(cur),
                  cur == bh.id ? "(BlackHole ✓ — no false trip)" : "(NOT BlackHole ✗ — REVERTED, root cause confirmed)")
            dm.setDefaultOutput(savedDefault)
            chain.stop(); agg.destroy(aggID)
            print("[\(stamp())] restored & stopped")
            exit(0)
        }
    }
    RunLoop.main.run()
}

if args.contains("--run-headless") {
    let dm = DeviceManager()
    let agg = AggregateDevice()

    PermissionManager.ensureMic { granted in
        guard granted else { print("mic permission denied"); exit(1) }
        let list = dm.listDevices()
        guard let bh = DeviceMatcher.blackHole(in: list),
              let out = DeviceMatcher.physicalOutput(in: list, excludingUID: nil),
              let outID = dm.deviceID(forUID: out.uid) else {
            print("missing devices"); exit(1)
        }
        let rate = negotiatedRate(dm, bh, out)
        dm.setNominalSampleRate(rate, deviceID: bh.id)
        dm.setNominalSampleRate(rate, deviceID: outID)
        print("using rate:", Int(rate))

        guard let aggID = agg.create(AggregateSpec.make(outputUID: out.uid, inputUID: bh.uid)) else {
            print("aggregate create failed"); exit(1)
        }
        let chain = AudioChain(sampleRate: rate)
        let savedDefault = dm.defaultOutputDeviceID()
        let store = ProfileStore(home: FileManager.default.homeDirectoryForCurrentUser)
        let stateURL = store.list().first.map { store.stateURL(id: $0.id) }
        chain.start(aggregateID: aggID, initialStateURL: stateURL,
                    captureChannelOffset: out.inputChannels) { result in
            switch result {
            case .failure(let e): print("start failed:", e); agg.destroy(aggID); exit(1)
            case .success:
                dm.setDefaultOutput(bh.id)
                print("running (\(chain.inputFormatDescription)) — play audio; Ctrl-C to stop.")
            }
        }
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            dm.setDefaultOutput(savedDefault)
            chain.stop(); agg.destroy(aggID)
            print("\nrestored & stopped"); exit(0)
        }
        src.resume()
        gRetain.append(src)
    }
    RunLoop.main.run()
}

import AppKit
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
