import Foundation

enum CESPCategory: String, CaseIterable, Identifiable, Codable {
    case sessionStart = "session.start"
    case taskAcknowledge = "task.acknowledge"
    case taskComplete = "task.complete"
    case taskError = "task.error"
    case inputRequired = "input.required"
    case resourceLimit = "resource.limit"
    case userSpam = "user.spam"
    case sessionEnd = "session.end"
    case taskProgress = "task.progress"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessionStart: return "Session start"
        case .taskAcknowledge: return "Task acknowledge"
        case .taskComplete: return "Task complete"
        case .taskError: return "Task error"
        case .inputRequired: return "Input required"
        case .resourceLimit: return "Resource limit"
        case .userSpam: return "User spam"
        case .sessionEnd: return "Session end"
        case .taskProgress: return "Task progress"
        }
    }
}

struct CESPManifest: Codable, Equatable {
    let cespVersion: String
    let name: String
    let displayName: String?
    let version: String
    let categories: [String: CESPCategoryManifest]

    enum CodingKeys: String, CodingKey {
        case cespVersion = "cesp_version"
        case name
        case displayName = "display_name"
        case version
        case categories
    }
}

struct CESPCategoryManifest: Codable, Equatable {
    let sounds: [CESPSoundManifest]
}

struct CESPSoundManifest: Codable, Equatable {
    let file: String
    let label: String?
}

struct CESPValidationResult: Equatable {
    var errors: [String] = []
    var warnings: [String] = []

    var isValid: Bool { errors.isEmpty }
}

struct CESPPack: Identifiable, Equatable {
    var id: String { manifest.name }
    let rootURL: URL
    let manifest: CESPManifest
    let validation: CESPValidationResult

    var displayName: String {
        manifest.displayName?.isEmpty == false ? manifest.displayName! : manifest.name
    }
}
