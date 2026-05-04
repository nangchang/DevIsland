import SwiftUI

enum ToolRiskLevel: String, Comparable {
    case safe = "Safe"
    case low = "Low Risk"
    case medium = "Medium Risk"
    case high = "High Risk"
    case critical = "Critical Risk"
    
    var color: Color {
        switch self {
        case .safe: return .green
        case .low: return .blue
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .low: return "info.circle.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.octagon.fill"
        case .critical: return "xmark.shield.fill"
        }
    }

    var emoji: String {
        switch self {
        case .safe: return "🟢"
        case .low: return "🔵"
        case .medium: return "🟡"
        case .high: return "🟠"
        case .critical: return "🔴"
        }
    }

    static func < (lhs: ToolRiskLevel, rhs: ToolRiskLevel) -> Bool {
        let order: [ToolRiskLevel: Int] = [.safe: 0, .low: 1, .medium: 2, .high: 3, .critical: 4]
        return order[lhs]! < order[rhs]!
    }
}

struct KnownTool: Identifiable, Hashable {
    let id: String
    let name: String
    let risk: ToolRiskLevel
}

struct ToolKnowledge {
    static let predefined: [KnownTool] = [
        KnownTool(id: "Bash", name: "Bash", risk: .critical),
        KnownTool(id: "Edit", name: "Edit", risk: .high),
        KnownTool(id: "Replace", name: "Replace", risk: .high),
        KnownTool(id: "Glob", name: "Glob", risk: .low),
        KnownTool(id: "View", name: "View", risk: .safe),
        KnownTool(id: "Read", name: "Read", risk: .safe),
        KnownTool(id: "LS", name: "LS", risk: .safe),
        KnownTool(id: "Grep", name: "Grep", risk: .safe),
        KnownTool(id: "SemanticSearch", name: "Semantic Search", risk: .safe),
        KnownTool(id: "Notebook", name: "Notebook", risk: .medium),
        
        KnownTool(id: "run_shell_command", name: "Run Shell Command", risk: .critical),
        KnownTool(id: "run_command", name: "Run Command", risk: .critical),
        KnownTool(id: "write_to_file", name: "Write to File", risk: .high),
        KnownTool(id: "replace_file_content", name: "Replace File Content", risk: .high),
        KnownTool(id: "multi_replace_file_content", name: "Multi Replace File", risk: .high),
        KnownTool(id: "view_file", name: "View File", risk: .safe),
        KnownTool(id: "list_dir", name: "List Directory", risk: .safe),
        KnownTool(id: "grep_search", name: "Grep Search", risk: .safe),
        KnownTool(id: "search_web", name: "Search Web", risk: .safe),
        KnownTool(id: "read_url_content", name: "Read URL Content", risk: .safe),
        KnownTool(id: "read_browser_page", name: "Read Browser Page", risk: .low),
        KnownTool(id: "ask_user", name: "Ask User", risk: .safe)
    ].sorted { $0.id < $1.id }
    
    static func risk(for toolName: String) -> ToolRiskLevel {
        let lower = toolName.lowercased()
        if let found = predefined.first(where: { $0.id.lowercased() == lower }) {
            return found.risk
        }
        
        // Fallback heuristics
        if lower.contains("shell") || lower.contains("bash") || lower.contains("exec") || lower.contains("run") {
            return .critical
        }
        if lower.contains("write") || lower.contains("edit") || lower.contains("replace") || lower.contains("delete") {
            return .high
        }
        if lower.contains("read") || lower.contains("view") || lower.contains("list") || lower.contains("search") || lower.contains("get") || lower.contains("ls") {
            return .safe
        }
        return .medium
    }
}
