import XCTest
@testable import DevIsland

final class PluginStorageTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginStorageTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - SQLitePluginStorage (direct)

    private func makeStorage(_ name: String = "store") throws -> SQLitePluginStorage {
        try SQLitePluginStorage(
            databaseURL: tempDir.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("storage.sqlite")
        )
    }

    func testSetGetOverwriteDelete() throws {
        let storage = try makeStorage()
        try storage.set("a", value: "1")
        XCTAssertEqual(try storage.get("a"), "1")
        try storage.set("a", value: "2")
        XCTAssertEqual(try storage.get("a"), "2")
        try storage.delete("a")
        XCTAssertNil(try storage.get("a"))
    }

    func testIncrementAccumulates() throws {
        let storage = try makeStorage()
        XCTAssertEqual(try storage.increment("c", by: 1), 1)   // new key starts at 0
        XCTAssertEqual(try storage.increment("c", by: 4), 5)
        XCTAssertEqual(try storage.increment("c", by: -2), 3)
        XCTAssertEqual(try storage.get("c"), "3")
    }

    func testIncrementOverflowThrowsAndLeavesValueUnchanged() throws {
        let storage = try makeStorage()
        try storage.set("n", value: String(Int.max))
        XCTAssertThrowsError(try storage.increment("n", by: 1), "overflow must throw, not trap the host")
        XCTAssertEqual(try storage.get("n"), String(Int.max), "value stays unchanged when increment overflows")
    }

    func testSnapshotRespectsLimit() throws {
        let storage = try makeStorage()
        for i in 0..<10 { try storage.set("k\(i)", value: "\(i)") }
        XCTAssertEqual(try storage.snapshot(limit: 4).count, 4)
        XCTAssertEqual(try storage.snapshot(limit: 100).count, 10)
    }

    func testRejectsOversizedKeyAndValue() throws {
        let storage = try makeStorage()
        let longKey = String(repeating: "k", count: PluginStorageLimits.maxKeyLength + 1)
        let longValue = String(repeating: "v", count: PluginStorageLimits.maxValueLength + 1)
        XCTAssertThrowsError(try storage.set(longKey, value: "x"))
        XCTAssertThrowsError(try storage.set("ok", value: longValue))
        XCTAssertTrue(try storage.snapshot(limit: 100).isEmpty)
    }

    func testQuotaRejectsNewKeysButAllowsOverwrite() throws {
        let storage = try makeStorage()
        for i in 0..<PluginStorageLimits.maxKeys { try storage.set("k\(i)", value: "\(i)") }
        XCTAssertThrowsError(try storage.set("overflow", value: "x"), "a new key beyond maxKeys is rejected")
        XCTAssertEqual(try storage.snapshot(limit: 10_000).count, PluginStorageLimits.maxKeys)
        XCTAssertNoThrow(try storage.set("k0", value: "updated"), "overwriting an existing key stays allowed")
        XCTAssertEqual(try storage.get("k0"), "updated")
    }

    func testStaysDurableAcrossReopen() throws {
        let url = tempDir.appendingPathComponent("dur", isDirectory: true).appendingPathComponent("storage.sqlite")
        let first = try SQLitePluginStorage(databaseURL: url)
        try first.set("persist", value: "yes")
        first.close()

        let second = try SQLitePluginStorage(databaseURL: url)
        XCTAssertEqual(try second.get("persist"), "yes")
    }

    // MARK: - PluginStorageProvider (actor + effect routing)

    func testProviderIsolatesPluginNamespaces() async {
        let provider = PluginStorageProvider(baseDirectory: tempDir)
        await provider.applyStorageEffect(
            PluginEffect(capability: "storage.keyValue", payload: ["key": "x", "value": "A"]),
            pluginID: "com.devisland.a"
        )
        let a = await provider.snapshot(forPluginID: "com.devisland.a")
        let b = await provider.snapshot(forPluginID: "com.devisland.b")
        XCTAssertEqual(a["x"], "A")
        XCTAssertTrue(b.isEmpty, "another plugin must not see the value")
    }

    func testKeyValueEffectSetsThenDeletes() async {
        let provider = PluginStorageProvider(baseDirectory: tempDir)
        await provider.applyStorageEffect(
            PluginEffect(capability: "storage.keyValue", payload: ["key": "x", "value": "1"]),
            pluginID: "com.devisland.a"
        )
        let afterSet = await provider.snapshot(forPluginID: "com.devisland.a")
        XCTAssertEqual(afterSet["x"], "1")

        // No "value" payload means delete.
        await provider.applyStorageEffect(
            PluginEffect(capability: "storage.keyValue", payload: ["key": "x"]),
            pluginID: "com.devisland.a"
        )
        let afterDelete = await provider.snapshot(forPluginID: "com.devisland.a")
        XCTAssertNil(afterDelete["x"])
    }

    func testIncrementEffectUsesDeltaAndDefaultsToOne() async {
        let provider = PluginStorageProvider(baseDirectory: tempDir)
        await provider.applyStorageEffect(
            PluginEffect(capability: "storage.increment", payload: ["key": "n"]),
            pluginID: "com.devisland.a"
        )
        await provider.applyStorageEffect(
            PluginEffect(capability: "storage.increment", payload: ["key": "n", "delta": "4"]),
            pluginID: "com.devisland.a"
        )
        let snapshot = await provider.snapshot(forPluginID: "com.devisland.a")
        XCTAssertEqual(snapshot["n"], "5")
    }

    func testResetClearsPluginStorage() async {
        let provider = PluginStorageProvider(baseDirectory: tempDir)
        await provider.applyStorageEffect(
            PluginEffect(capability: "storage.keyValue", payload: ["key": "x", "value": "1"]),
            pluginID: "com.devisland.a"
        )
        await provider.reset(pluginID: "com.devisland.a")
        let snapshot = await provider.snapshot(forPluginID: "com.devisland.a")
        XCTAssertTrue(snapshot.isEmpty)
    }
}
