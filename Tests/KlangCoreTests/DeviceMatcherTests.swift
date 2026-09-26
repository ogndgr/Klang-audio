import XCTest
@testable import KlangCore

private func dev(_ id: UInt32, _ uid: String, _ name: String,
                 input: Bool = false, output: Bool = false, virtual: Bool = false) -> AudioDeviceInfo {
    AudioDeviceInfo(id: id, uid: uid, name: name, isInput: input, isOutput: output,
                    isVirtual: virtual, supportedRates: [44100, 48000, 96000])
}

final class DeviceMatcherTests: XCTestCase {
    func testFindsBlackHoleByName() {
        let list = [dev(1, "AppleHDA", "External Headphones", output: true),
                    dev(2, "BlackHole2ch_UID", "BlackHole 2ch", input: true, output: true, virtual: true)]
        XCTAssertEqual(DeviceMatcher.blackHole(in: list)?.id, 2)
    }

    func testPhysicalOutputExcludesVirtualAndBlackHole() {
        let list = [dev(1, "AppleHDA", "External Headphones", output: true),
                    dev(2, "BlackHole2ch_UID", "BlackHole 2ch", input: true, output: true, virtual: true)]
        XCTAssertEqual(DeviceMatcher.physicalOutput(in: list, excludingUID: nil)?.id, 1)
    }

    func testPhysicalOutputHonorsExclusion() {
        let list = [dev(1, "AppleHDA", "External Headphones", output: true),
                    dev(3, "USB-DAC", "External DAC", output: true)]
        XCTAssertEqual(DeviceMatcher.physicalOutput(in: list, excludingUID: "AppleHDA")?.id, 3)
    }

    func testSelectableOutputsListsPhysicalOutputsOnly() {
        let list = [dev(1, "AppleHDA", "Built-in Output", output: true),
                    dev(3, "USB-DAC", "Scarlett 2i2", output: true),
                    dev(2, "BlackHole2ch_UID", "BlackHole 2ch", input: true, output: true, virtual: true),
                    dev(4, "com.klang.aggregate", "Klang Aggregate", input: true, output: true, virtual: true),
                    dev(5, "MicUID", "Built-in Microphone", input: true)]
        XCTAssertEqual(DeviceMatcher.selectableOutputs(in: list).map(\.id), [1, 3])
    }
}
