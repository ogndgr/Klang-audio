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

print("Klang (run via the app bundle for the menu bar UI)")
