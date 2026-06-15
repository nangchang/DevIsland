import XCTest
@testable import DevIsland

final class OpenPeonPackValidatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPeonPackValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    func testValidPackLoads() throws {
        let packURL = try makePack(soundPath: "sounds/done.wav")

        let pack = CESPPackValidator.loadPack(at: packURL)

        XCTAssertEqual(pack?.manifest.name, "sample-pack")
        XCTAssertTrue(pack?.validation.isValid == true)
    }

    func testInvalidCESPVersionRejectsPack() throws {
        let packURL = try makePack(soundPath: "sounds/done.wav", cespVersion: "2.0")

        let pack = CESPPackValidator.loadPack(at: packURL)

        XCTAssertFalse(pack?.validation.isValid == true)
        XCTAssertTrue(pack?.validation.errors.contains { $0.contains("Unsupported CESP version") } == true)
    }

    func testPathTraversalRejectsPack() throws {
        let packURL = try makePack(soundPath: "../done.wav", createSound: false)

        let pack = CESPPackValidator.loadPack(at: packURL)

        XCTAssertFalse(pack?.validation.isValid == true)
        XCTAssertTrue(pack?.validation.errors.contains { $0.contains("must not contain") } == true)
    }

    func testMissingAudioRejectsPack() throws {
        let packURL = try makePack(soundPath: "sounds/missing.wav", createSound: false)

        let pack = CESPPackValidator.loadPack(at: packURL)

        XCTAssertFalse(pack?.validation.isValid == true)
        XCTAssertTrue(pack?.validation.errors.contains { $0.contains("is missing") } == true)
    }

    func testUnsupportedExtensionRejectsPack() throws {
        let packURL = try makePack(soundPath: "sounds/done.aiff")

        let pack = CESPPackValidator.loadPack(at: packURL)

        XCTAssertFalse(pack?.validation.isValid == true)
        XCTAssertTrue(pack?.validation.errors.contains { $0.contains("unsupported audio extension") } == true)
    }

    func testOggWarnsButDoesNotReject() throws {
        let packURL = try makePack(soundPath: "sounds/done.ogg")

        let pack = CESPPackValidator.loadPack(at: packURL)

        XCTAssertTrue(pack?.validation.isValid == true)
        XCTAssertTrue(pack?.validation.warnings.contains { $0.contains("not playable") } == true)
    }

    func testOversizePackRejectsPack() throws {
        let packURL = try makePack(
            soundPath: "sounds/done.wav",
            extraFileSize: CESPPackValidator.maxPackSize + 1
        )

        let pack = CESPPackValidator.loadPack(at: packURL)

        XCTAssertFalse(pack?.validation.isValid == true)
        XCTAssertTrue(pack?.validation.errors.contains { $0.contains("exceeds 50 MB") } == true)
    }

    private func makePack(
        soundPath: String,
        cespVersion: String = "1.0",
        createSound: Bool = true,
        extraFileSize: Int64? = nil
    ) throws -> URL {
        let packURL = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: packURL, withIntermediateDirectories: true)
        if createSound {
            let soundURL = packURL.appendingPathComponent(soundPath)
            try FileManager.default.createDirectory(at: soundURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0, 1, 2, 3]).write(to: soundURL)
        }
        if let extraFileSize {
            try writeSparseFile(
                at: packURL.appendingPathComponent("oversize.bin"),
                byteCount: extraFileSize
            )
        }
        let manifest = """
        {
          "cesp_version": "\(cespVersion)",
          "name": "sample-pack",
          "version": "1.0.0",
          "categories": {
            "task.complete": {
              "sounds": [
                { "file": "\(soundPath)" }
              ]
            }
          }
        }
        """
        try Data(manifest.utf8).write(to: packURL.appendingPathComponent("openpeon.json"))
        return packURL
    }

    private func writeSparseFile(at url: URL, byteCount: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }
}
