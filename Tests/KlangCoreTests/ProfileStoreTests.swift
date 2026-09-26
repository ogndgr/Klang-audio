import XCTest
@testable import KlangCore

final class ProfileStoreTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testListEmptyWhenNoIndex() {
        XCTAssertTrue(ProfileStore(home: home).list().isEmpty)
    }

    func testCreateThenListRoundTrips() throws {
        let store = ProfileStore(home: home)
        let a = try store.create(name: "DT 990")
        let b = try store.create(name: "Flat")
        let listed = store.list()
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.map(\.name), ["DT 990", "Flat"])
        XCTAssertNotEqual(a.id, b.id)
    }

    func testRenameUpdatesName() throws {
        let store = ProfileStore(home: home)
        let p = try store.create(name: "old")
        try store.rename(id: p.id, to: "new")
        XCTAssertEqual(store.list().first { $0.id == p.id }?.name, "new")
    }

    func testDeleteRemovesEntryAndStateFile() throws {
        let store = ProfileStore(home: home)
        let p = try store.create(name: "Doomed")
        let stateURL = store.stateURL(id: p.id)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("state".utf8).write(to: stateURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        try store.delete(id: p.id)
        XCTAssertFalse(store.list().contains { $0.id == p.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stateURL(id: p.id).path))
    }

    func testMigrationAdoptsLegacyFullState() throws {
        let legacy = AppPaths.fullStateURL(home: home)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("legacy-eq".utf8).write(to: legacy)

        let store = ProfileStore(home: home)
        let migrated = try store.migrateLegacyFullStateIfNeeded()

        XCTAssertEqual(migrated?.name, "Default")
        XCTAssertEqual(store.list().map(\.name), ["Default"])
        let copied = try Data(contentsOf: store.stateURL(id: migrated!.id))
        XCTAssertEqual(copied, Data("legacy-eq".utf8))
        // legacy file left untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testMigrationNoOpWhenIndexExists() throws {
        let store = ProfileStore(home: home)
        _ = try store.create(name: "Existing")
        // even with a legacy file present, an existing index blocks migration
        let legacy = AppPaths.fullStateURL(home: home)
        try Data("x".utf8).write(to: legacy)
        XCTAssertNil(try store.migrateLegacyFullStateIfNeeded())
        XCTAssertEqual(store.list().map(\.name), ["Existing"])
    }

    func testMigrationNoOpWhenNoLegacyFile() throws {
        XCTAssertNil(try ProfileStore(home: home).migrateLegacyFullStateIfNeeded())
    }
}
