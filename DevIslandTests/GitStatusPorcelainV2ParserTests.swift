import XCTest
@testable import DevIsland

final class GitStatusPorcelainV2ParserTests: XCTestCase {
    private let oidA = String(repeating: "a", count: 40)
    private let oidB = String(repeating: "b", count: 40)
    private let oidC = String(repeating: "c", count: 40)
    private let oidA256 = String(repeating: "a", count: 64)
    private let zeroOID256 = String(repeating: "0", count: 64)

    func testParsesCleanBranch() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main"
        )

        XCTAssertEqual(result.branchHead, "main")
        XCTAssertEqual(result.headOID, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(result.changedPaths, [])
        XCTAssertEqual(result.changedEntryCount, 0)
        XCTAssertFalse(result.hasUnmergedEntries)
    }

    func testFormatsDetachedHeadUsingFirstEightOIDCharacters() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head (detached)"
        )

        XCTAssertEqual(result.branchHead, "detached@01234567")
        XCTAssertEqual(result.headOID, "0123456789abcdef0123456789abcdef01234567")
    }

    func testParsesUnbornBranch() throws {
        let result = try parse(
            "# branch.oid (initial)",
            "# branch.head feature/fleet-radar"
        )

        XCTAssertEqual(result.branchHead, "feature/fleet-radar")
        XCTAssertNil(result.headOID)
    }

    func testIgnoresOptionalBranchHeaders() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1"
        )

        XCTAssertEqual(result.branchHead, "main")
        XCTAssertEqual(result.changedEntryCount, 0)
    }

    func testParsesStagedUnstagedAndDeletedOrdinaryEntries() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main",
            "1 M. N... 100644 100644 100644 \(oidA) \(oidB) Sources/Staged.swift",
            "1 .M N... 100644 100644 100644 \(oidA) \(oidA) Sources/Unstaged.swift",
            "1 .D N... 100644 100644 000000 \(oidA) \(oidA) Sources/Deleted.swift"
        )

        XCTAssertEqual(
            result.changedPaths,
            ["Sources/Staged.swift", "Sources/Unstaged.swift", "Sources/Deleted.swift"]
        )
        XCTAssertEqual(result.changedEntryCount, 3)
        XCTAssertFalse(result.hasUnmergedEntries)
    }

    func testParsesSHA256ObjectIDsIncludingZeroOID() throws {
        let result = try parse(
            "# branch.oid \(oidA256)",
            "# branch.head feature/sha256",
            "1 A. N... 000000 100644 100644 \(zeroOID256) \(oidA256) Sources/Added.swift"
        )

        XCTAssertEqual(result.headOID, oidA256)
        XCTAssertEqual(result.changedPaths, ["Sources/Added.swift"])
        XCTAssertEqual(result.changedEntryCount, 1)
        XCTAssertFalse(result.hasUnmergedEntries)
    }

    func testParsesUntrackedPath() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main",
            "? Notes/new-file.md"
        )

        XCTAssertEqual(result.changedPaths, ["Notes/new-file.md"])
        XCTAssertEqual(result.changedEntryCount, 1)
        XCTAssertFalse(result.hasUnmergedEntries)
    }

    func testIgnoresIgnoredPath() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main",
            "! .build/output.o"
        )

        XCTAssertEqual(result.changedPaths, [])
        XCTAssertEqual(result.changedEntryCount, 0)
    }

    func testPreservesSpacesKoreanAndQuotesInPaths() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main",
            "1 .M N... 100644 100644 100644 \(oidA) \(oidA) Sources/파일 이름.swift",
            "? Notes/\"quoted file\".md",
            "? Notes/line\nbreak.md"
        )

        XCTAssertEqual(
            result.changedPaths,
            ["Sources/파일 이름.swift", "Notes/\"quoted file\".md", "Notes/line\nbreak.md"]
        )
        XCTAssertEqual(result.changedEntryCount, 3)
    }

    func testRenameIncludesOldAndNewPathsButCountsOneEntry() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head feature/rename",
            "2 R. N... 100644 100644 100644 \(oidA) \(oidB) R100 Sources/New Name.swift",
            "Sources/Old Name.swift"
        )

        XCTAssertEqual(
            result.changedPaths,
            ["Sources/New Name.swift", "Sources/Old Name.swift"]
        )
        XCTAssertEqual(result.changedEntryCount, 1)
        XCTAssertFalse(result.hasUnmergedEntries)
    }

    func testCopyIncludesSourceAndDestinationPathsButCountsOneEntry() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head feature/copy",
            "2 C. N... 100644 100644 100644 \(oidA) \(oidB) C75 Sources/Copy.swift",
            "Sources/Original.swift"
        )

        XCTAssertEqual(result.changedPaths, ["Sources/Copy.swift", "Sources/Original.swift"])
        XCTAssertEqual(result.changedEntryCount, 1)
        XCTAssertFalse(result.hasUnmergedEntries)
    }

    func testParsesUnmergedEntryAndSetsFlag() throws {
        let result = try parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head feature/conflict",
            "u UU N... 100644 100644 100644 100644 \(oidA) \(oidB) \(oidC) Sources/Conflict.swift"
        )

        XCTAssertEqual(result.changedPaths, ["Sources/Conflict.swift"])
        XCTAssertEqual(result.changedEntryCount, 1)
        XCTAssertTrue(result.hasUnmergedEntries)
    }

    func testRejectsRenameWithoutOriginToken() {
        assertMalformed(
            data(
                "# branch.oid 0123456789abcdef0123456789abcdef01234567",
                "# branch.head main",
                "2 R. N... 100644 100644 100644 \(oidA) \(oidB) R100 Sources/New.swift"
            )
        )
    }

    func testRejectsUnknownRecordPrefix() {
        assertMalformed(
            data(
                "# branch.oid 0123456789abcdef0123456789abcdef01234567",
                "# branch.head main",
                "x future-format"
            )
        )
    }

    func testRejectsOrdinaryRecordWithMissingFields() {
        assertMalformed(
            data(
                "# branch.oid 0123456789abcdef0123456789abcdef01234567",
                "# branch.head main",
                "1 M. N... 100644 Sources/Truncated.swift"
            )
        )
    }

    func testRejectsOrdinaryRecordWhosePathWordsFillMissingMetadata() {
        assertMalformed(
            data(
                "# branch.oid 0123456789abcdef0123456789abcdef01234567",
                "# branch.head main",
                "1 M. N... 100644 100644 100644 \(oidA) Missing metadata path.swift"
            )
        )
    }

    func testRejectsRenameRecordWhosePathWordsFillMissingScore() {
        assertMalformed(
            data(
                "# branch.oid 0123456789abcdef0123456789abcdef01234567",
                "# branch.head main",
                "2 R. N... 100644 100644 100644 \(oidA) \(oidB) Sources New Name.swift",
                "Sources/Old.swift"
            )
        )
    }

    func testRejectsUnmergedRecordWhosePathWordsFillMissingObjectID() {
        assertMalformed(
            data(
                "# branch.oid 0123456789abcdef0123456789abcdef01234567",
                "# branch.head main",
                "u UU N... 100644 100644 100644 100644 \(oidA) \(oidB) Sources Conflict File.swift"
            )
        )
    }

    func testRejectsOutputWithoutBranchHead() {
        assertMalformed(
            data("# branch.oid 0123456789abcdef0123456789abcdef01234567")
        )
    }

    func testRejectsOutputWithoutBranchOID() {
        assertMalformed(data("# branch.head main"))
    }

    func testRejectsShortBranchOID() {
        assertMalformed(
            data(
                "# branch.oid 01234567",
                "# branch.head main"
            )
        )
    }

    func testRejectsNonHexBranchOID() {
        assertMalformed(
            data(
                "# branch.oid g\(String(repeating: "a", count: 39))",
                "# branch.head (detached)"
            )
        )
    }

    func testRejectsInvalidUTF8() {
        var fixture = data(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main"
        )
        fixture.removeLast()
        fixture.append(contentsOf: [0x3f, 0x20, 0xff, 0x00])

        assertMalformed(fixture)
    }

    func testRejectsOutputWithoutFinalNULTerminator() {
        var fixture = data(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main"
        )
        fixture.removeLast()

        assertMalformed(fixture)
    }

    private func parse(_ tokens: String...) throws -> GitStatusParseResult {
        try GitStatusPorcelainV2Parser.parse(data(tokens))
    }

    private func data(_ tokens: String...) -> Data {
        data(tokens)
    }

    private func data(_ tokens: [String]) -> Data {
        Data((tokens.joined(separator: "\0") + "\0").utf8)
    }

    private func assertMalformed(
        _ fixture: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try GitStatusPorcelainV2Parser.parse(fixture),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? GitStatusPorcelainV2Parser.ParseError,
                .malformedOutput,
                file: file,
                line: line
            )
        }
    }
}
