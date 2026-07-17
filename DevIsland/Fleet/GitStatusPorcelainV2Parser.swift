import Foundation

struct GitStatusParseResult: Equatable, Sendable {
    let branchHead: String
    let headOID: String?
    let changedPaths: Set<String>
    let changedEntryCount: Int
    let hasUnmergedEntries: Bool
}

enum GitStatusPorcelainV2Parser {
    enum ParseError: Error, Equatable, Sendable {
        case malformedOutput
    }

    static func parse(_ data: Data) throws -> GitStatusParseResult {
        let tokens = try tokenize(data)
        var branchHead: String?
        var headOID: String?
        var hasBranchOID = false
        var changedPaths: Set<String> = []
        var changedEntryCount = 0
        var hasUnmergedEntries = false
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            if token.hasPrefix("# branch.oid ") {
                let value = String(token.dropFirst("# branch.oid ".count))
                guard value == "(initial)" || isValidObjectID(value) else {
                    throw ParseError.malformedOutput
                }
                hasBranchOID = true
                headOID = value == "(initial)" ? nil : value
            } else if token.hasPrefix("# branch.head ") {
                let value = String(token.dropFirst("# branch.head ".count))
                guard !value.isEmpty else { throw ParseError.malformedOutput }
                branchHead = value
            } else if token.hasPrefix("# branch.oid") || token.hasPrefix("# branch.head") {
                throw ParseError.malformedOutput
            } else if token.hasPrefix("# ") {
                // Other porcelain v2 headers are not needed by Fleet Radar.
            } else if token.hasPrefix("1 ") {
                changedPaths.insert(try ordinaryPath(in: token))
                changedEntryCount += 1
            } else if token.hasPrefix("2 ") {
                let newPath = try renameOrCopyPath(in: token)
                let originIndex = index + 1
                guard originIndex < tokens.count, !tokens[originIndex].isEmpty else {
                    throw ParseError.malformedOutput
                }
                changedPaths.insert(newPath)
                changedPaths.insert(tokens[originIndex])
                changedEntryCount += 1
                index = originIndex
            } else if token.hasPrefix("u ") {
                changedPaths.insert(try unmergedPath(in: token))
                changedEntryCount += 1
                hasUnmergedEntries = true
            } else if token.hasPrefix("? ") {
                let path = String(token.dropFirst(2))
                guard !path.isEmpty else { throw ParseError.malformedOutput }
                changedPaths.insert(path)
                changedEntryCount += 1
            } else if token.hasPrefix("! ") {
                guard token.count > 2 else { throw ParseError.malformedOutput }
            } else {
                throw ParseError.malformedOutput
            }

            index += 1
        }

        guard hasBranchOID, let branchHead else { throw ParseError.malformedOutput }
        let displayBranch: String
        if branchHead == "(detached)" {
            guard let headOID else { throw ParseError.malformedOutput }
            displayBranch = "detached@\(headOID.prefix(8))"
        } else {
            displayBranch = branchHead
        }

        return GitStatusParseResult(
            branchHead: displayBranch,
            headOID: headOID,
            changedPaths: changedPaths,
            changedEntryCount: changedEntryCount,
            hasUnmergedEntries: hasUnmergedEntries
        )
    }

    private static func tokenize(_ data: Data) throws -> [String] {
        guard data.last == 0 else { throw ParseError.malformedOutput }

        var rawTokens = data.split(separator: 0, omittingEmptySubsequences: false)
        guard rawTokens.last?.isEmpty == true else { throw ParseError.malformedOutput }
        rawTokens.removeLast()

        return try rawTokens.map { bytes in
            guard !bytes.isEmpty,
                  let token = String(bytes: bytes, encoding: .utf8) else {
                throw ParseError.malformedOutput
            }
            return token
        }
    }

    private static let validStatusBytes = Set(".MTADRCUX".utf8)

    private static func ordinaryPath(in token: String) throws -> String {
        let fields = try recordFields(in: token, maxSplits: 8)
        guard fields[0] == "1",
              isValidXY(fields[1]),
              isValidSubmoduleField(fields[2]),
              fields[3...5].allSatisfy(isValidMode),
              areValidObjectIDs([fields[6], fields[7]]) else {
            throw ParseError.malformedOutput
        }
        return String(fields[8])
    }

    private static func renameOrCopyPath(in token: String) throws -> String {
        let fields = try recordFields(in: token, maxSplits: 9)
        guard fields[0] == "2",
              isValidXY(fields[1]),
              isValidSubmoduleField(fields[2]),
              fields[3...5].allSatisfy(isValidMode),
              areValidObjectIDs([fields[6], fields[7]]),
              isValidRenameOrCopyScore(fields[8]) else {
            throw ParseError.malformedOutput
        }
        return String(fields[9])
    }

    private static func unmergedPath(in token: String) throws -> String {
        let fields = try recordFields(in: token, maxSplits: 10)
        guard fields[0] == "u",
              isValidXY(fields[1]),
              isValidSubmoduleField(fields[2]),
              fields[3...6].allSatisfy(isValidMode),
              areValidObjectIDs([fields[7], fields[8], fields[9]]) else {
            throw ParseError.malformedOutput
        }
        return String(fields[10])
    }

    private static func recordFields(in token: String, maxSplits: Int) throws -> [Substring] {
        let fields = token.split(
            separator: " ",
            maxSplits: maxSplits,
            omittingEmptySubsequences: false
        )
        guard fields.count == maxSplits + 1,
              fields.dropLast().allSatisfy({ !$0.isEmpty }),
              let path = fields.last,
              !path.isEmpty else {
            throw ParseError.malformedOutput
        }
        return fields
    }

    private static func isValidXY(_ field: Substring) -> Bool {
        field.utf8.count == 2 && field.utf8.allSatisfy(validStatusBytes.contains)
    }

    private static func isValidSubmoduleField(_ field: Substring) -> Bool {
        let bytes = Array(field.utf8)
        guard bytes.count == 4 else { return false }
        if bytes[0] == Character("N").asciiValue {
            return bytes[1...3].allSatisfy { $0 == Character(".").asciiValue }
        }
        guard bytes[0] == Character("S").asciiValue else { return false }
        return (bytes[1] == Character(".").asciiValue || bytes[1] == Character("C").asciiValue)
            && (bytes[2] == Character(".").asciiValue || bytes[2] == Character("M").asciiValue)
            && (bytes[3] == Character(".").asciiValue || bytes[3] == Character("U").asciiValue)
    }

    private static func isValidMode(_ field: Substring) -> Bool {
        field.utf8.count == 6 && field.utf8.allSatisfy { byte in
            byte >= Character("0").asciiValue! && byte <= Character("7").asciiValue!
        }
    }

    private static func areValidObjectIDs(_ fields: [Substring]) -> Bool {
        guard let length = fields.first?.utf8.count,
              length == 40 || length == 64,
              fields.allSatisfy({ $0.utf8.count == length }) else {
            return false
        }
        return fields.allSatisfy { isValidObjectID($0) }
    }

    private static func isValidObjectID<Value: StringProtocol>(_ field: Value) -> Bool {
        let bytes = field.utf8
        guard bytes.count == 40 || bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
                || (byte >= Character("a").asciiValue! && byte <= Character("f").asciiValue!)
                || (byte >= Character("A").asciiValue! && byte <= Character("F").asciiValue!)
        }
    }

    private static func isValidRenameOrCopyScore(_ field: Substring) -> Bool {
        let bytes = field.utf8
        guard let prefix = bytes.first,
              prefix == Character("R").asciiValue || prefix == Character("C").asciiValue else {
            return false
        }
        let digits = bytes.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { byte in
            byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!
        }
    }
}
