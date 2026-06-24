import XCTest
@testable import KlangCore

final class AggregateSpecTests: XCTestCase {
    func testMakeBuildsMasterOutputAndDriftedInput() {
        let s = AggregateSpec.make(outputUID: "OUT", inputUID: "IN")
        XCTAssertEqual(s.masterUID, "OUT")
        XCTAssertEqual(s.subDeviceUIDs, ["OUT", "IN"])
        XCTAssertEqual(s.driftUIDs, ["IN"])
        XCTAssertEqual(s.uid, "com.klang.aggregate")
        XCTAssertFalse(s.name.isEmpty)
    }
}
