import Foundation

// MARK: - AnyJSON

/// Arbitrary JSON value that round-trips through Codable.
enum AnyJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyJSON].self) {
            self = .array(v)
        } else {
            self = .object(try container.decode([String: AnyJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let v):    try container.encode(v)
        case .int(let v):     try container.encode(v)
        case .double(let v):  try container.encode(v)
        case .string(let v):  try container.encode(v)
        case .array(let v):   try container.encode(v)
        case .object(let v):  try container.encode(v)
        }
    }

    /// Convert to Foundation's Any for use with JSONSerialization-based code.
    var rawValue: Any {
        switch self {
        case .null:           return NSNull()
        case .bool(let v):    return v
        case .int(let v):     return v
        case .double(let v):  return v
        case .string(let v):  return v
        case .array(let v):   return v.map { $0.rawValue }
        case .object(let v):  return v.mapValues { $0.rawValue }
        }
    }
}

// MARK: - IPC Envelope (bridge → app)

/// Structured envelope sent by the bridge for IPC protocol v1.
/// The bridge sends a 4-byte big-endian length prefix followed by this JSON.
struct IPCEnvelope: Codable {
    let `protocol`: String      // "dev-island-hook-ipc"
    let version: Int            // 1
    let requestId: String       // UUID string
    let sentAt: String          // ISO 8601
    let token: String?          // nil → grace mode (no token file on either side)
    let source: String          // "claude" | "codex" | "gemini"
    let payload: [String: AnyJSON]

    static let protocolName = "dev-island-hook-ipc"
    static let currentVersion = 1
}

// MARK: - IPC Rich Response (app → bridge)

/// Rich response returned by the app for framed requests.
/// Encoded with a 4-byte big-endian length prefix followed by this JSON.
struct IPCRichResponse: Codable {
    let `protocol`: String
    let version: Int
    let requestId: String
    let status: String                      // "ok" | "error"
    let decision: String?                   // "approved" | "denied" | "pass"
    let reason: String?
    let providerOutput: [String: AnyJSON]?  // populated by ProviderAdapter in Phase 3

    init(
        requestId: String,
        status: String = "ok",
        decision: String?,
        reason: String? = nil,
        providerOutput: [String: AnyJSON]? = nil
    ) {
        self.protocol = IPCEnvelope.protocolName
        self.version = IPCEnvelope.currentVersion
        self.requestId = requestId
        self.status = status
        self.decision = decision
        self.reason = reason
        self.providerOutput = providerOutput
    }

    /// Encode to length-prefixed bytes: [4-byte big-endian length][JSON].
    func framedData() throws -> Data {
        let body = try JSONEncoder().encode(self)
        var length = UInt32(body.count).bigEndian
        var result = Data(bytes: &length, count: 4)
        result.append(body)
        return result
    }
}
