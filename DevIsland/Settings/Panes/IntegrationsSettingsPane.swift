import SwiftUI
import AppKit

struct IntegrationsSettingsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.secAppIntegrations) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(l10n.lblProcessVSCode, isOn: store.binding(\.processVSCodeEnabled))
                    Text(l10n.descProcessVSCode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(l10n.lblProcessClaudeDesktop, isOn: store.binding(\.processClaudeDesktopEnabled))
                    Text(l10n.descProcessClaudeDesktop)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(l10n.lblProcessCodexDesktop, isOn: store.binding(\.processCodexDesktopEnabled))
                    Text(l10n.descProcessCodexDesktop)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaceholderToolWindowView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
