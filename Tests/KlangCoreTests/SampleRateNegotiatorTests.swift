import XCTest
@testable import KlangCore

final class SampleRateNegotiatorTests: XCTestCase {
    func testPrefers96kWhenBothSupport() {
        XCTAssertEqual(SampleRateNegotiator.bestCommonRate(
            preferred: 96000, [44100, 48000, 96000], [48000, 96000, 192000]), 96000)
    }
    func testFallsBackToHighestCommon() {
        XCTAssertEqual(SampleRateNegotiator.bestCommonRate(
            preferred: 96000, [44100, 48000], [48000, 96000]), 48000)
    }
    func testNilWhenNoCommonRate() {
        XCTAssertNil(SampleRateNegotiator.bestCommonRate(
            preferred: 96000, [44100], [48000]))
    }
}
