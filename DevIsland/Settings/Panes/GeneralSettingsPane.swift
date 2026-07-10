import SwiftUI
import AppKit

struct GeneralSettingsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var launchManager = LaunchAtLoginManager.shared

    private var installedTerminals: [(name: String, bundleId: String)] {
        TerminalFocuser.installedTerminals
    }

    var body: some View {
        Form {
            Section(l10n.secLanguage) {
                Picker(l10n.lblLanguage, selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section(l10n.secPreferredTerminal) {
                Picker(l10n.lblPreferredTerminal, selection: $store.settings.preferredTerminal) {
                    Text(l10n.optTerminalSessionDefault).tag(String?.none)
                    ForEach(installedTerminals, id: \.name) { terminal in
                        Text(terminal.name).tag(String?.some(terminal.name))
                    }
                }
                .pickerStyle(.radioGroup)
                Text(l10n.hintPreferredTerminal)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(l10n.secAoEFocus) {
                Picker(l10n.lblAoEFocusMode, selection: store.binding(\.aoeSessionFocusMode)) {
                    ForEach(AoESessionFocusMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(store.settings.aoeSessionFocusMode.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(l10n.hintAoEFocusMode)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(l10n.secStartup) {
                Toggle(l10n.lblLaunchAtLogin, isOn: Binding(
                    get: { launchManager.isEnabled },
                    set: { launchManager.setEnabled($0) }
                ))

                if launchManager.status == .requiresApproval {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(l10n.lblLaunchAtLoginApproval)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Spacer()
                        Button(l10n.btnOpenLoginSettings) {
                            launchManager.openLoginItemsSettings()
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Section(l10n.secUpdates) {
                Toggle(l10n.lblCheckForUpdatesOnStartup, isOn: store.binding(\.checkForUpdatesOnStartup))
                Picker(l10n.lblReleaseChannel, selection: store.binding(\.releaseChannel)) {
                    ForEach(ReleaseChannel.allCases) { channel in
                        Text(channel.label).tag(channel)
                    }
                }
            }

            Section(l10n.secNotifications) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(l10n.lblNotificationsEnabled, isOn: Binding(
                        get: { store.settings.notificationsEnabled },
                        set: { enabled in
                            if enabled {
                                store.settings.notificationsEnabled = true
                                NotificationManager.shared.requestAuthorization { granted in
                                    if !granted { store.settings.notificationsEnabled = false }
                                }
                            } else {
                                store.settings.notificationsEnabled = false
                            }
                        }
                    ))
                    Text(l10n.descNotificationsEnabled)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(l10n.secSounds) {
                Toggle(l10n.lblMuteAllSounds, isOn: $store.settings.openPeonGlobalMuted)
            }

            Section {
                Button(l10n.btnResetAllSettings) {
                    store.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { l10n.language },
            set: { newValue in
                l10n.language = newValue
                AppState.shared.pluginHost.pluginLanguageChanged()
            }
        )
    }
}
