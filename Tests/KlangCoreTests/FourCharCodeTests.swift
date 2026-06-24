import XCTest
@testable import KlangCore

final class FourCharCodeTests: XCTestCase {
    func testKnownCodes() {
        XCTAssertEqual(fourCC("Beyd"), 0x42657964)
        XCTAssertEqual(fourCC("BdHL"), 0x4264484C)
        XCTAssertEqual(fourCC("aufx"), 0x61756678)
    }
}
