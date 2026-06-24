import XCTest
@testable import KlangCore

final class AppPathsTests: XCTestCase {
    func testPathsUnderApplicationSupportKlang() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(AppPaths.supportDir(home: home).path,
                       "/Users/test/Library/Application Support/Klang")
        XCTAssertEqual(AppPaths.prefsURL(home: home).lastPathComponent, "prefs.json")
        XCTAssertEqual(AppPaths.fullStateURL(home: home).lastPathComponent,
                       "headphonelab.fullstate.plist")
    }
}
