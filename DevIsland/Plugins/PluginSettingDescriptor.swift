import Foundation

/// Localized text owned by a plugin. The host only passes the current language snapshot
/// and renders the resolved string; it does not keep a plugin string catalog.
struct PluginLocalizedString: Codable, Equatable, Sendable {
    let english: String
    let korean: String

    func resolved(for language: AppLanguage) -> String {
        language.s(english, korean)
    }
}

/// A single setting value a plugin can hold. Codable so it can persist in UserDefaults
/// (via `PluginSettingsStore`) and be injected into `PluginContext.settings`. v1.3 supports
/// four kinds, one per supported UI control (toggle/picker/stepper-slider/text).
enum PluginSettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    var intValue: Int? { if case .int(let v) = self { return v } else { return nil } }
    var doubleValue: Double? { if case .double(let v) = self { return v } else { return nil } }
    var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }

    // Tagged representation (`{"type":"bool","value":...}`) keeps the value self-describing
    // in JSON so a stored value round-trips back to the right case.
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum ValueType: String, Codable { case bool, int, double, string }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int: self = .int(try container.decode(Int.self, forKey: .value))
        case .double: self = .double(try container.decode(Double.self, forKey: .value))
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v): try container.encode(ValueType.bool, forKey: .type); try container.encode(v, forKey: .value)
        case .int(let v): try container.encode(ValueType.int, forKey: .type); try container.encode(v, forKey: .value)
        case .double(let v): try container.encode(ValueType.double, forKey: .type); try container.encode(v, forKey: .value)
        case .string(let v): try container.encode(ValueType.string, forKey: .type); try container.encode(v, forKey: .value)
        }
    }
}

/// Declarative description of one plugin setting. Plugins return these from
/// `DevIslandPlugin.settingsSchema`; the host renders a matching control, validates user
/// input, persists the value, and injects the resolved value back via `PluginContext`.
/// Plugins never build SwiftUI — they declare intent, the host owns presentation.
struct PluginSettingDescriptor: Equatable, Sendable, Identifiable {
    let key: String              // unique within a plugin
    let label: String            // English fallback
    var localizedLabel: PluginLocalizedString? = nil
    let kind: Kind
    let defaultValue: PluginSettingValue

    var id: String { key }

    func displayLabel(language: AppLanguage) -> String {
        localizedLabel?.resolved(for: language) ?? label
    }

    enum Kind: Equatable, Sendable {
        case toggle
        case picker(options: [Option])
        case stepper(range: ClosedRange<Int>, step: Int)
        case slider(range: ClosedRange<Double>, step: Double)
        case text(maxLength: Int)
    }

    struct Option: Equatable, Sendable, Identifiable {
        let value: String
        let label: String
        var localizedLabel: PluginLocalizedString? = nil
        var id: String { value }

        func displayLabel(language: AppLanguage) -> String {
            localizedLabel?.resolved(for: language) ?? label
        }
    }

    /// Coerces a stored or user-entered value into a valid value for this descriptor.
    /// Returns `defaultValue` when the value is missing or the wrong kind; clamps numeric
    /// values to range and truncates text to `maxLength`. The host calls this both on read
    /// (default fallback) and on user input (validation), so a malformed stored value can
    /// never reach a plugin.
    func validated(_ value: PluginSettingValue?) -> PluginSettingValue {
        switch kind {
        case .toggle:
            guard let b = value?.boolValue else { return defaultValue }
            return .bool(b)
        case .picker(let options):
            guard let s = value?.stringValue, options.contains(where: { $0.value == s }) else {
                return defaultValue
            }
            return .string(s)
        case .stepper(let range, _):
            guard let i = value?.intValue else { return defaultValue }
            return .int(min(max(i, range.lowerBound), range.upperBound))
        case .slider(let range, _):
            guard let d = value?.doubleValue else { return defaultValue }
            return .double(min(max(d, range.lowerBound), range.upperBound))
        case .text(let maxLength):
            guard let s = value?.stringValue else { return defaultValue }
            // `prefix` traps on a negative length; a plugin could declare one by mistake.
            return .string(String(s.prefix(max(0, maxLength))))
        }
    }
}
