import SwiftUI
import AppKit

struct FeaturesSettingsPane: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var store: SettingsStore
    @ObservedObject var appState: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var selectedPaneID: String = ""

    private var descriptors: [PluginSettingsPaneDescriptor] {
        pluginHost.settingsPaneDescriptors()
    }

    private var effectiveSelectedID: String {
        descriptors.contains(where: { $0.pluginID == selectedPaneID })
            ? selectedPaneID
            : descriptors.first?.pluginID ?? ""
    }

    private var selectionBinding: Binding<String> {
        Binding(get: { effectiveSelectedID }, set: { selectedPaneID = $0 })
    }

    var body: some View {
        let descs = descriptors
        if descs.isEmpty {
            Text(l10n.s("No active feature panes.", "활성 기능 창이 없습니다."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                if descs.count > 1 {
                    Picker("", selection: selectionBinding) {
                        ForEach(descs, id: \.pluginID) { desc in
                            Label(desc.label.resolved(for: l10n.language), systemImage: desc.systemImage)
                                .tag(desc.pluginID)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                featureView(for: effectiveSelectedID)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func featureView(for pluginID: String) -> some View {
        VStack(spacing: 0) {
            if pluginHost.isInSafemode(pluginID) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(l10n.lblPluginSafemode)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(l10n.btnPluginReset) {
                        pluginHost.resetPlugin(pluginID: pluginID)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.08))
                Divider()
            }
            switch pluginID {
            case CaffeinePlugin.pluginID:
                CaffeineSettingsPane(store: store, coordinator: appState.caffeineCoordinator)
            case OpenPeonPlugin.pluginID:
                OpenPeonSettingsPane(store: store)
            default:
                EmptyView()
            }
        }
    }
}

private struct OpenPeonSettingsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var packStore = CESPPackStore.shared
    @ObservedObject private var l10n = L10n.shared

    private var activePackSelection: Binding<String> {
        Binding(
            get: { store.settings.openPeonActivePackName ?? "" },
            set: { store.settings.openPeonActivePackName = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        Form {
            Section(l10n.secOpenPeonSoundPacks) {
                Toggle(l10n.lblOpenPeonEnable, isOn: $store.settings.openPeonEnabled)

                HStack {
                    TextField(l10n.phOpenPeonPacksFolder, text: $store.settings.openPeonPacksDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        CESPPackStore.shared.reload(settings: store.settings)
                        AppState.shared.refreshPluginScopedFileScopes(settings: store.settings)
                    } label: {
                        Label(l10n.btnReload, systemImage: "arrow.clockwise")
                    }
                    Button {
                        openPacksFolder()
                    } label: {
                        Label(l10n.btnOpen, systemImage: "folder")
                    }
                }

                Picker(l10n.lblOpenPeonActivePack, selection: activePackSelection) {
                    Text(l10n.lblOpenPeonFirstValidPack).tag("")
                    ForEach(packStore.packs.filter { $0.validation.isValid }) { pack in
                        Text(pack.displayName).tag(pack.manifest.name)
                    }
                }
                .disabled(packStore.packs.filter { $0.validation.isValid }.isEmpty)

                if let errorPath = packStore.lastReloadErrorPath {
                    Label(l10n.errOpenPeonReadPacks(errorPath), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if packStore.packs.isEmpty {
                    Text(l10n.lblOpenPeonNoPacks)
                        .foregroundStyle(.secondary)
                }
            }

            Section(l10n.secOpenPeonPlayback) {
                Slider(value: $store.settings.openPeonMasterVolume, in: 0...1) {
                    Text(l10n.lblOpenPeonMasterVolume)
                } minimumValueLabel: {
                    Image(systemName: "speaker")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3")
                }
                Stepper(
                    l10n.lblOpenPeonDebounce(store.settings.openPeonDebounceMilliseconds),
                    value: $store.settings.openPeonDebounceMilliseconds,
                    in: 0...10_000,
                    step: 100
                )
            }

            Section(l10n.secOpenPeonCategories) {
                ForEach(CESPCategory.allCases) { category in
                    let hasSound = packStore.hasSounds(for: category, settings: store.settings)
                    HStack {
                        Toggle(isOn: categoryBinding(category)) {
                            HStack {
                                Text(category.label)
                                Spacer()
                                Text(category.cespKey)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            CESPAudioPlayer.shared.play(category: category, bypassChecks: true)
                        } label: {
                            Image(systemName: hasSound ? "speaker.wave.2.circle.fill" : "speaker.slash.circle.fill")
                                .font(.title3)
                                .foregroundStyle(hasSound ? .blue : .gray)
                        }
                        .buttonStyle(.plain)
                        .help(hasSound ? l10n.btnPlayPreview : l10n.lblOpenPeonNoSoundFile)
                        .disabled(!hasSound)
                    }
                }
            }

            Section(l10n.secOpenPeonValidation) {
                ForEach(packStore.packs) { pack in
                    DisclosureGroup(pack.displayName) {
                        if pack.validation.isValid {
                            Label(l10n.lblOpenPeonValid, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        ForEach(pack.validation.errors, id: \.self) { error in
                            Label(error, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                        ForEach(pack.validation.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            CESPPackStore.shared.reload(settings: store.settings)
            AppState.shared.refreshPluginScopedFileScopes(settings: store.settings)
        }
        .onChange(of: store.settings.openPeonPacksDirectory) { _, _ in
            CESPPackStore.shared.reload(settings: store.settings)
            AppState.shared.refreshPluginScopedFileScopes(settings: store.settings)
        }
    }

    private func categoryBinding(_ category: CESPCategory) -> Binding<Bool> {
        Binding(
            get: { !store.settings.openPeonMutedCategories.contains(category.rawValue) },
            set: { enabled in
                if enabled {
                    store.settings.openPeonMutedCategories.remove(category.rawValue)
                } else {
                    store.settings.openPeonMutedCategories.insert(category.rawValue)
                }
            }
        )
    }

    private func openPacksFolder() {
        let url = URL(fileURLWithPath: NSString(string: store.settings.openPeonPacksDirectory).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
