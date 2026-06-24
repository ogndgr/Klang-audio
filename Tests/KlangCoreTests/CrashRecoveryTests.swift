import XCTest
@testable import KlangCore

final class CrashRecoveryTests: XCTestCase {
    func testRestoreOnlyWhenBlackHoleDefaultAndEngineStopped() {
        XCTAssertTrue(CrashRecovery.shouldRestoreDefaultOutput(currentDefaultIsBlackHole: true, engineRunning: false))
        XCTAssertFalse(CrashRecovery.shouldRestoreDefaultOutput(currentDefaultIsBlackHole: true, engineRunning: true))
        XCTAssertFalse(CrashRecovery.shouldRestoreDefaultOutput(currentDefaultIsBlackHole: false, engineRunning: false))
    }
}
