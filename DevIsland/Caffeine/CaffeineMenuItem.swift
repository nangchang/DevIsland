import SwiftUI

/// MenuBarExtra 메뉴에 들어가는 Caffeine 토글 + 상태 사유 라벨.
struct CaffeineMenuItem: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var coordinator = AppState.shared.caffeineCoordinator
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { store.settings.caffeineEnabled },
            set: { store.settings.caffeineEnabled = $0 }
        )) {
            Text(l10n.menuCaffeineToggle)
        }

        Text(reasonText)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    private var reasonText: String {
        switch coordinator.reason {
        case .off:
            return l10n.menuCaffeineOff
        case .onAC:
            return l10n.menuCaffeineOnAC
        case .onBattery:
            return l10n.menuCaffeineOnBattery
        case .lowBattery:
            return l10n.menuCaffeineLowBattery
        case .excludedSSID(let ssid):
            return l10n.menuCaffeineExcludedSSID(ssid)
        }
    }
}
