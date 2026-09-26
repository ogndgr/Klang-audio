import Foundation
import CoreAudio
import AudioToolbox
import KlangCore

let args = CommandLine.arguments
var gRetain: [Any] = []

if args.contains("--list-devices") {
    let dm = DeviceManager()
    let list = dm.listDevices()
    for d in list {
        let io = "\(d.isInput ? "in" : "  ")/\(d.isOutput ? "out" : "   ")"
        print("id=\(d.id) [\(io)] \(d.isVirtual ? "V" : " ") \(d.name) — \(d.uid) — rates \(d.supportedRates.map { Int($0) })")
    }
    let def = dm.defaultOutputDeviceID()
    print("default output id:", def)
    let defUID = list.first { $0.id == def }?.uid
    print("Target (automatic):", DeviceMatcher.resolveTarget(chosenUID: nil, defaultUID: defUID, in: list)?.name ?? "none")
    exit(0)
}

/// Tap + aggregate on the automatic target, or nil (printing why).
func makeTapAggregate(_ dm: DeviceManager, _ agg: AggregateDevice)
-> (tap: SystemAudioTap, aggID: AudioDeviceID, out: AudioDeviceInfo)? {
    let list = dm.listDevices()
    let def = dm.defaultOutputDeviceID()
    guard let out = DeviceMatcher.resolveTarget(chosenUID: nil, defaultUID: list.first { $0.id == def }?.uid,
                                                in: list) else {
        print("no physical output"); return nil
    }
    guard let tap = SystemAudioTap() else { print("tap create failed"); return nil }
    guard let aggID = agg.create(AggregateSpec.make(outputUID: out.uid, tapUUID: tap.uuid)) else {
        tap.destroy(); print("aggregate create failed"); return nil
    }
    return (tap, aggID, out)
}

if args.contains("--test-aggregate") {
    let dm = DeviceManager()
    let agg = AggregateDevice()
    guard let t = makeTapAggregate(dm, agg) else { exit(1) }
    print("created tap \(t.tap.id) + aggregate \(t.aggID) (output \(t.out.name), \(Int(dm.nominalSampleRate(t.aggID) ?? 0)) Hz)")
    agg.destroy(t.aggID)
    t.tap.destroy()
    print("destroyed ok")
    exit(0)
}

if args.contains("--test-halsetup") {
    // Validates the full effect + IOProc configuration WITHOUT starting audio, so it can
    // be run non-interactively to catch config bugs.
    let dm = DeviceManager()
    let agg = AggregateDevice()
    guard let t = makeTapAggregate(dm, agg) else { exit(1) }
    let rate = dm.nominalSampleRate(t.aggID) ?? 48000
    let chain = AudioChain(sampleRate: rate)
    chain.start(aggregateID: t.aggID, initialStateURL: nil, startIO: false) { result in
        switch result {
        case .success: print("setup OK — configured + initialized (IO not started) @\(Int(rate))Hz")
        case .failure(let e): print("setup FAILED:", e)
        }
        chain.stop(); agg.destroy(t.aggID); t.tap.destroy()
        exit(0)
    }
    RunLoop.main.run()
}

if args.contains("--run-headless") {
    // System Audio Recording permission is attributed to the launching terminal app.
    let dm = DeviceManager()
    let agg = AggregateDevice()
    guard let t = makeTapAggregate(dm, agg) else { exit(1) }
    let rate = dm.nominalSampleRate(t.aggID) ?? 48000
    let chain = AudioChain(sampleRate: rate)
    let store = ProfileStore(home: FileManager.default.homeDirectoryForCurrentUser)
    let stateURL = store.list().first.map { store.stateURL(id: $0.id) }
    chain.start(aggregateID: t.aggID, initialStateURL: stateURL) { result in
        switch result {
        case .failure(let e): print("start failed:", e); agg.destroy(t.aggID); t.tap.destroy(); exit(1)
        case .success: print("running on \(t.out.name) @\(Int(rate))Hz — play audio; Ctrl-C to stop.")
        }
    }
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    src.setEventHandler {
        chain.stop(); agg.destroy(t.aggID); t.tap.destroy()
        print("\nstopped"); exit(0)
    }
    src.resume()
    gRetain.append(src)
    RunLoop.main.run()
}

import AppKit
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
