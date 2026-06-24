import Foundation
import KlangCore

let args = CommandLine.arguments
var gRetain: [Any] = []

if args.contains("--list-devices") {
    let dm = DeviceManager()
    for d in dm.listDevices() {
        let io = "\(d.isInput ? "in" : "  ")/\(d.isOutput ? "out" : "   ")"
        print("[\(io)] \(d.isVirtual ? "V" : " ") \(d.name) — \(d.uid) — rates \(d.supportedRates.map { Int($0) })")
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
    chain.start(aggregateID: aggID, startIO: false) { result in
        switch result {
        case .success: print("HAL setup OK — configured + initialized (IO not started) @\(Int(rate))Hz")
        case .failure(let e): print("HAL setup FAILED:", e)
        }
        chain.stop(); agg.destroy(aggID)
        exit(0)
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
        chain.start(aggregateID: aggID) { result in
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

print("Klang (run via the app bundle for the menu bar UI)")
