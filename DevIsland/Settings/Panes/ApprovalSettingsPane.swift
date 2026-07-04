import SwiftUI
import AppKit

struct ApprovalSettingsPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.secAutoApprovals) {
                Toggle(l10n.lblAutoSafe, isOn: $appState.autoApproveSafeTools)
            }

            Section(l10n.secPermissionTimeout) {
                Stepper(l10n.lblPermissionTimeout(Int(store.settings.permissionTimeoutSeconds)),
                        value: $store.settings.permissionTimeoutSeconds,
                        in: 10...max(10, store.settings.bridgeResponseTimeoutSeconds - 10),
                        step: 10)
            }

            Section(l10n.secReplayRetention) {
                Stepper(l10n.lblReplayRetention(store.settings.replayRetentionDays),
                        value: $store.settings.replayRetentionDays, in: 1...365)
            }

            Section(l10n.secFallback) {
                Picker(l10n.lblFallbackPolicy, selection: store.binding(\.approvalFallbackPolicy)) {
                    ForEach(ApprovalFallbackPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
