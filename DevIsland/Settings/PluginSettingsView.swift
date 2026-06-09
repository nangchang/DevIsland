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
    @State private var showingResetStorageConfirm = false

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
                Button(role: .destructive) {
                    showingResetStorageConfirm = true
                } label: {
                    Text(l10n.btnPluginResetStorage)
                }
                .confirmationDialog(
                    l10n.btnPluginResetStorage,
                    isPresented: $showingResetStorageConfirm,
                    titleVisibility: .visible
                ) {
                    Button(l10n.btnPluginResetStorage, role: .destructive) {
                        pluginHost.resetStorage(forPluginID: manifest.id)
                    }
                    Button(l10n.btnCancel, role: .cancel) {}
                } message: {
                    Text(l10n.msgPluginResetStorageConfirm)
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
