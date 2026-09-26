import XCTest
@testable import KlangCore

final class AggregateSpecTests: XCTestCase {
    func testMakeUsesOutputAsOnlySubDeviceAndClock() {
        let s = AggregateSpec.make(outputUID: "OUT", tapUUID: "TAP")
        XCTAssertEqual(s.mainUID, "OUT")
        XCTAssertEqual(s.subDeviceUIDs, ["OUT"])
        XCTAssertEqual(s.uid, "com.klang.aggregate")
        XCTAssertFalse(s.name.isEmpty)
    }

    func testMakeAttachesTheTap() {
        let s = AggregateSpec.make(outputUID: "OUT", tapUUID: "TAP")
        XCTAssertEqual(s.tapUUIDs, ["TAP"])
    }
}
