import Foundation
import KlangCore

let args = CommandLine.arguments

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

print("Klang (run via the app bundle for the menu bar UI)")
