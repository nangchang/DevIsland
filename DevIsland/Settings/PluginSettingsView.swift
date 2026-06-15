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
                    Text(manifest.displayName(language: l10n.language))
                    Text("\(manifest.id) · v\(manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let description = manifest.displayDescription(language: l10n.language) {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

            let schema = pluginHost.settingsSchema(forPluginID: manifest.id)
            if !schema.isEmpty && settings.isEnabled(manifest.id) {
                Divider()
                Text(l10n.lblPluginSettings)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(schema) { descriptor in
                    PluginSettingControlView(
                        descriptor: descriptor,
                        pluginID: manifest.id,
                        pluginHost: pluginHost,
                        settings: settings
                    )
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

/// Renders a single plugin-declared setting as the matching SwiftUI control. The host owns
/// presentation; the plugin only declared the descriptor. Every write is validated/clamped
/// via `descriptor.validated` before persisting, then `pluginSettingChanged` notifies the
/// plugin so its contributions rebuild.
private struct PluginSettingControlView: View {
    let descriptor: PluginSettingDescriptor
    let pluginID: String
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var settings: PluginSettingsStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        switch descriptor.kind {
        case .toggle:
            Toggle(descriptor.displayLabel(language: l10n.language), isOn: boolBinding)
                .font(.caption)
        case .picker(let options):
            Picker(descriptor.displayLabel(language: l10n.language), selection: stringBinding) {
                ForEach(options) { option in
                    Text(option.displayLabel(language: l10n.language)).tag(option.value)
                }
            }
            .font(.caption)
        case .stepper(let range, let step):
            Stepper(value: intBinding, in: range, step: step) {
                labeledValue(String(current.intValue ?? 0))
            }
            .font(.caption)
        case .slider(let range, let step):
            VStack(alignment: .leading, spacing: 2) {
                labeledValue(String(format: "%g", current.doubleValue ?? 0))
                Slider(value: doubleBinding, in: range, step: step)
            }
            .font(.caption)
        case .text:
            // A local @State row so typing doesn't write to UserDefaults and drain a plugin
            // event on every keystroke; it commits once on return/blur.
            TextSettingRow(
                descriptor: descriptor,
                pluginID: pluginID,
                settings: settings,
                commit: commit
            )
        }
    }

    private func labeledValue(_ value: String) -> some View {
        HStack {
            Text(descriptor.displayLabel(language: l10n.language))
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    /// Current value resolved against the schema (default fallback), so controls always show
    /// a valid value even before the user has changed anything.
    private var current: PluginSettingValue {
        descriptor.validated(settings.value(forKey: descriptor.key, pluginID: pluginID))
    }

    private func commit(_ value: PluginSettingValue) {
        settings.setValue(descriptor.validated(value), forKey: descriptor.key, pluginID: pluginID)
        pluginHost.pluginSettingChanged(pluginID: pluginID)
    }

    private var boolBinding: Binding<Bool> {
        Binding(get: { current.boolValue ?? false }, set: { commit(.bool($0)) })
    }
    // Stepper/Slider require a value inside their range; fall back to the lower bound (not 0,
    // which may be out of range) and clamp, in case a plugin's default is the wrong kind.
    private var intBinding: Binding<Int> {
        Binding(
            get: {
                guard case .stepper(let range, _) = descriptor.kind else { return current.intValue ?? 0 }
                let value = current.intValue ?? range.lowerBound
                return min(max(value, range.lowerBound), range.upperBound)
            },
            set: { commit(.int($0)) }
        )
    }
    private var doubleBinding: Binding<Double> {
        Binding(
            get: {
                guard case .slider(let range, _) = descriptor.kind else { return current.doubleValue ?? 0 }
                let value = current.doubleValue ?? range.lowerBound
                return min(max(value, range.lowerBound), range.upperBound)
            },
            set: { commit(.double($0)) }
        )
    }
    private var stringBinding: Binding<String> {
        Binding(get: { current.stringValue ?? "" }, set: { commit(.string($0)) })
    }
}

/// Text setting backed by local `@State` so editing stays in-memory and only commits on
/// return/blur — avoids a UserDefaults write plus plugin event drain per keystroke. Stays in
/// sync if the stored value changes elsewhere.
private struct TextSettingRow: View {
    let descriptor: PluginSettingDescriptor
    let pluginID: String
    @ObservedObject var settings: PluginSettingsStore
    let commit: (PluginSettingValue) -> Void
    @ObservedObject private var l10n = L10n.shared

    @State private var localText = ""

    var body: some View {
        HStack {
            Text(descriptor.displayLabel(language: l10n.language))
            TextField("", text: $localText, onCommit: { commit(.string(localText)) })
                .textFieldStyle(.roundedBorder)
        }
        .font(.caption)
        .onAppear { localText = resolved }
        .onChange(of: settings.value(forKey: descriptor.key, pluginID: pluginID)) { _, _ in
            localText = resolved
        }
    }

    private var resolved: String {
        descriptor.validated(settings.value(forKey: descriptor.key, pluginID: pluginID)).stringValue ?? ""
    }
}
