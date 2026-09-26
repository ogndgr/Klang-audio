import XCTest
@testable import KlangCore

private func dev(_ id: UInt32, _ uid: String, _ name: String,
                 input: Bool = false, output: Bool = false, virtual: Bool = false) -> AudioDeviceInfo {
    AudioDeviceInfo(id: id, uid: uid, name: name, isInput: input, isOutput: output,
                    isVirtual: virtual, supportedRates: [44100, 48000, 96000])
}

private let headphones = dev(1, "AppleHDA", "External Headphones", output: true)
private let dac = dev(3, "USB-DAC", "Scarlett 2i2", output: true)
private let blackHole = dev(2, "BlackHole2ch_UID", "BlackHole 2ch", input: true, output: true, virtual: true)
private let aggregate = dev(4, "com.klang.aggregate", "Klang Aggregate", input: true, output: true, virtual: true)
private let mic = dev(5, "MicUID", "Built-in Microphone", input: true)

final class DeviceMatcherTests: XCTestCase {
    func testSelectableOutputsListsPhysicalOutputsOnly() {
        let list = [headphones, dac, blackHole, aggregate, mic]
        XCTAssertEqual(DeviceMatcher.selectableOutputs(in: list).map(\.id), [1, 3])
    }

    // MARK: resolveTarget

    func testResolveTargetPrefersChosenDevice() {
        let t = DeviceMatcher.resolveTarget(chosenUID: "USB-DAC", defaultUID: "AppleHDA",
                                            in: [headphones, dac])
        XCTAssertEqual(t?.uid, "USB-DAC")
    }

    func testResolveTargetFallsBackToDefaultWhenChosenIsMissing() {
        let t = DeviceMatcher.resolveTarget(chosenUID: "Gone", defaultUID: "AppleHDA",
                                            in: [headphones, dac])
        XCTAssertEqual(t?.uid, "AppleHDA")
    }

    func testResolveTargetUsesDefaultInAutomaticMode() {
        let t = DeviceMatcher.resolveTarget(chosenUID: nil, defaultUID: "USB-DAC",
                                            in: [headphones, dac])
        XCTAssertEqual(t?.uid, "USB-DAC")
    }

    func testResolveTargetSkipsVirtualDefault() {
        let t = DeviceMatcher.resolveTarget(chosenUID: nil, defaultUID: "BlackHole2ch_UID",
                                            in: [blackHole, headphones])
        XCTAssertEqual(t?.uid, "AppleHDA")
    }

    func testResolveTargetNilWhenNoPhysicalOutput() {
        XCTAssertNil(DeviceMatcher.resolveTarget(chosenUID: nil, defaultUID: "BlackHole2ch_UID",
                                                 in: [blackHole, mic]))
    }

    // MARK: followTarget

    func testFollowsNewDefaultInAutomaticMode() {
        let t = DeviceMatcher.followTarget(activeUID: "AppleHDA", chosenUID: nil,
                                           defaultUID: "USB-DAC", in: [headphones, dac])
        XCTAssertEqual(t?.uid, "USB-DAC")
    }

    func testDoesNotFollowWhenUserChoseADevice() {
        XCTAssertNil(DeviceMatcher.followTarget(activeUID: "AppleHDA", chosenUID: "AppleHDA",
                                                defaultUID: "USB-DAC", in: [headphones, dac]))
    }

    func testDoesNotFollowWhenActiveDeviceDisappeared() {
        // Unplugging the headphones also moves the default; that path deactivates instead.
        XCTAssertNil(DeviceMatcher.followTarget(activeUID: "AppleHDA", chosenUID: nil,
                                                defaultUID: "USB-DAC", in: [dac]))
    }

    func testDoesNotFollowWhenTargetIsUnchanged() {
        XCTAssertNil(DeviceMatcher.followTarget(activeUID: "AppleHDA", chosenUID: nil,
                                                defaultUID: "AppleHDA", in: [headphones, dac]))
    }

    func testDoesNotFollowToVirtualDefault() {
        // Default moved to BlackHole: nothing physical changed, stay on the headphones.
        XCTAssertNil(DeviceMatcher.followTarget(activeUID: "AppleHDA", chosenUID: nil,
                                                defaultUID: "BlackHole2ch_UID",
                                                in: [headphones, dac, blackHole]))
    }
}
