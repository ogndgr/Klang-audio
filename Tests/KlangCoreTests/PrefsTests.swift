import XCTest
@testable import KlangCore

final class PrefsTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }
    func testLoadMissingReturnsDefaults() {
        XCTAssertEqual(PrefsStore.load(from: tmp()), Prefs.defaults)
    }
    func testSaveThenLoadRoundTrips() throws {
        let url = tmp()
        var p = Prefs.defaults; p.autoStart = true; p.outputUID = "OUT"; p.bufferFrames = 512
        try PrefsStore.save(p, to: url)
        XCTAssertEqual(PrefsStore.load(from: url), p)
    }
    func testLoadCorruptReturnsDefaults() throws {
        let url = tmp()
        try "{ not json".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(PrefsStore.load(from: url), Prefs.defaults)
    }
}
