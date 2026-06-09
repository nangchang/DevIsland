import SwiftUI

/// Host-owned settings surface for the plugin platform: lists registered plugins and
/// lets the user toggle each one, see its safe-mode/failure state, recover it, and wipe
/// its durable storage. v1 deliberately does not render any plugin-provided settings UI.
struct PluginSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var settings: PluginSettingsStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            let plugins = pluginHost.registeredPlugins
            if plugins.isEmpty {
                Section {
                    Text(l10n.pluginsEmpty)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(l10n.pluginsListHeader) {
                    ForEach(plugins, id: \.id) { manifest in
                        PluginSettingsRow(
                            manifest: manifest,
                            pluginHost: pluginHost,
                            settings: settings
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PluginSettingsRow: View {
    let manifest: PluginManifest
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var settings: PluginSettingsStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: enabledBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name)
                    Text("\(manifest.id) · v\(manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if pluginHost.isInSafemode(manifest.id) {
                Label(l10n.lblPluginSafemode, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            let failures = pluginHost.failures.filter { $0.pluginID == manifest.id }
            if let last = failures.last {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.pluginFailures(failures.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(last.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack {
                if pluginHost.isInSafemode(manifest.id) {
                    Button(l10n.btnPluginReset) {
                        pluginHost.resetPlugin(pluginID: manifest.id)
                    }
                }
                // TODO: [PR 11+] storage 실사용 플러그인 도입 시 confirmationDialog 추가.
                // 파괴적 액션이므로 실수 방지용 확인 대화상자 필요. (PR #261 Gemini review)
                Button(role: .destructive) {
                    pluginHost.resetStorage(forPluginID: manifest.id)
                } label: {
                    Text(l10n.btnPluginResetStorage)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled(manifest.id) },
            set: { newValue in
                settings.setEnabled(newValue, pluginID: manifest.id)
                pluginHost.setPluginEnabled(newValue, pluginID: manifest.id)
            }
        )
    }
}
