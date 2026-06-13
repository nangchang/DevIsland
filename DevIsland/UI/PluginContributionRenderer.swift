import AppKit
import SwiftUI

// MARK: - Truncation Helpers (internal for testing)

func truncatedPluginLabel(_ text: String?) -> String? {
    text.flatMap { $0.isEmpty ? nil : String($0.prefix(pluginLabelMaxLength)) }
}

func truncatedPluginValue(_ text: String?) -> String? {
    text.flatMap { $0.isEmpty ? nil : String($0.prefix(pluginValueMaxLength)) }
}

func truncatedMenuText(_ text: String?) -> String {
    String((text ?? "").prefix(pluginMenuMaxLength))
}

let pluginLabelMaxLength = 40
let pluginValueMaxLength = 60
let pluginMenuMaxLength = 40

// MARK: - Notch Plugin Slot View

/// Renders PluginUIContributions for a given slot in the expanded notch panel.
/// Reads only from the pre-computed cache; never calls plugin code during render.
struct PluginSlotView: View {
    let contributions: [PluginUIContribution]

    @ViewBuilder
    var body: some View {
        let valid = activePluginContributions(contributions)
        if !valid.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(valid, id: \.pluginID) { contribution in
                    PluginContributionRow(
                        pluginID: contribution.pluginID,
                        components: contribution.components
                    )
                }
            }
        }
    }
}

private struct PluginContributionRow: View {
    let pluginID: String
    let components: [PluginUIComponentDTO]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(components, id: \.id) { component in
                PluginComponentView(pluginID: pluginID, component: component)
            }
        }
    }
}

// MARK: - Component View

private struct PluginComponentView: View {
    let pluginID: String
    let component: PluginUIComponentDTO

    private var label: String? { truncatedPluginLabel(component.label) }
    private var value: String? { truncatedPluginValue(component.value) }

    private var toneColor: Color {
        switch component.tone ?? .default {
        case .default: return .white.opacity(0.7)
        case .success:  return .green
        case .warning:  return .orange
        case .error:    return .red
        }
    }

    @ViewBuilder
    var body: some View {
        switch component.type {
        case .metric:  metricView
        case .badge:   badgeView
        case .button:  buttonView
        case .text:    textView
        }
    }

    private var metricView: some View {
        HStack(spacing: 4) {
            if let icon = validatedIcon(component.iconName) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(toneColor)
            }
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }
            if let value {
                Text(value)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(toneColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var badgeView: some View {
        HStack(spacing: 3) {
            if let icon = validatedIcon(component.iconName) {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .foregroundColor(toneColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(toneColor.opacity(0.15))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var buttonView: some View {
        if let action = component.action {
            Button {
                AppState.shared.pluginHost.handleAction(action, from: pluginID, componentID: component.id)
            } label: {
                buttonLabel.foregroundColor(toneColor)
            }
            .buttonStyle(.plain)
        } else {
            // No action — non-interactive, no tap target
            buttonLabel
                .foregroundColor(.white.opacity(0.35))
        }
    }

    private var buttonLabel: some View {
        HStack(spacing: 4) {
            if let icon = validatedIcon(component.iconName) {
                Image(systemName: icon)
                    .font(.system(size: 10))
            }
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var textView: some View {
        if let label {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(2)
        }
    }
}

// MARK: - SF Symbol Validation

/// Returns the name if it resolves to a valid SF Symbol; nil otherwise.
/// Prevents crashes from plugin-supplied unknown symbol names.
func validatedIcon(_ name: String?) -> String? {
    guard let name, !name.isEmpty else { return nil }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : nil
}

// MARK: - MenuBar Plugin Items

/// Renders PluginUIContributions for the .menubarMenu slot as SwiftUI menu content.
/// Emits a Divider only when contributions with non-empty components exist.
struct PluginMenuItemsView: View {
    let contributions: [PluginUIContribution]

    @ViewBuilder
    var body: some View {
        let valid = activePluginContributions(contributions)
        if !valid.isEmpty {
            Divider()
            ForEach(valid, id: \.pluginID) { contribution in
                ForEach(contribution.components, id: \.id) { component in
                    PluginMenuComponentView(pluginID: contribution.pluginID, component: component)
                }
            }
        }
    }
}

/// Renders `.sessionContextMenu` contributions for one session as context-menu items,
/// separated from the core items by a Divider. Reuses the menu component renderer, so
/// only `button` components are interactive (the session context menu is action-only in
/// v1). Button taps route through `PluginHost.handleAction`, which validates the command.
struct PluginSessionMenuItemsView: View {
    let contributions: [PluginUIContribution]

    @ViewBuilder
    var body: some View {
        let valid = activePluginContributions(contributions)
        if !valid.isEmpty {
            Divider()
            ForEach(valid, id: \.pluginID) { contribution in
                ForEach(contribution.components, id: \.id) { component in
                    PluginMenuComponentView(pluginID: contribution.pluginID, component: component)
                }
            }
        }
    }
}

private struct PluginMenuComponentView: View {
    let pluginID: String
    let component: PluginUIComponentDTO

    private var label: String { truncatedMenuText(component.label) }
    private var value: String { truncatedMenuText(component.value) }

    @ViewBuilder
    var body: some View {
        switch component.type {
        case .metric:
            if label.isEmpty && value.isEmpty {
                EmptyView()
            } else if label.isEmpty {
                Text(value).foregroundStyle(.secondary)
            } else if value.isEmpty {
                Text(label).foregroundStyle(.secondary)
            } else {
                Text("\(label): \(value)").foregroundStyle(.secondary)
            }

        case .text, .badge:
            if !label.isEmpty {
                Text(label).foregroundStyle(.secondary)
            }

        case .button:
            if let action = component.action {
                let title = label.isEmpty ? value : label
                if !title.isEmpty {
                    Button(title) {
                        AppState.shared.pluginHost.handleAction(action, from: pluginID, componentID: component.id)
                    }
                }
            }
        }
    }
}
