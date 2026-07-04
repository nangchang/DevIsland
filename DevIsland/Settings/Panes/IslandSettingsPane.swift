import SwiftUI
import AppKit

struct IslandSettingsPane: View {
    @ObservedObject var displayPrefs: NotchDisplayPreferences
    @ObservedObject var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.secNotch) {
                Picker(l10n.lblDisplay, selection: $displayPrefs.notchDisplayTarget) {
                    ForEach(NotchDisplayTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }

                if displayPrefs.notchDisplayTarget == .specific {
                    Picker(l10n.lblMonitor, selection: $displayPrefs.selectedDisplayId) {
                        ForEach(NSScreen.screens, id: \.displayId) { screen in
                            Text(displayName(for: screen)).tag(screen.displayId)
                        }
                    }
                }

                Toggle(l10n.lblShowFullScreen, isOn: $displayPrefs.showInFullScreenApps)

                SettingsSliderRow(
                    title: l10n.lblPanelOpacity(Int(store.settings.notchPanelOpacity * 100)),
                    value: store.binding(\.notchPanelOpacity),
                    range: 0.4...1.0,
                    step: 0.05
                )

                Toggle(l10n.lblNotchShadow, isOn: store.binding(\.notchBackdropShadowEnabled))

                Toggle(l10n.lblNotchAnimation, isOn: store.binding(\.notchAnimationEnabled))

                if store.settings.notchAnimationEnabled {
                    SettingsSliderRow(
                        title: l10n.lblAnimationSpeed(store.settings.notchAnimationSpeed),
                        value: store.binding(\.notchAnimationSpeed),
                        range: 0.5...2.0,
                        step: 0.25
                    )
                }

                Picker(l10n.lblNotchShapeStyle, selection: store.binding(\.notchShapeStyle)) {
                    ForEach(NotchShapeStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                SettingsSliderRow(
                    title: l10n.lblCollapsedNotchWidth(Int(store.settings.collapsedNotchWidth)),
                    value: store.binding(\.collapsedNotchWidth),
                    range: 180...420,
                    step: 1
                )

                SettingsSliderRow(
                    title: l10n.lblCollapsedNotchHeight(Int(store.settings.collapsedNotchHeight)),
                    value: store.binding(\.collapsedNotchHeight),
                    range: 24...56,
                    step: 1
                )

                SettingsSliderRow(
                    title: l10n.lblExpandedNotchWidth(Int(store.settings.expandedNotchWidth)),
                    value: store.binding(\.expandedNotchWidth),
                    range: 610...1200,
                    step: 1
                )

                SettingsSliderRow(
                    title: l10n.lblExpandedNotchHeight(Int(store.settings.expandedNotchHeight)),
                    value: store.binding(\.expandedNotchHeight),
                    range: 240...720,
                    step: 1
                )

                Picker(l10n.lblNotchAutoCollapse, selection: store.binding(\.notchAutoCollapseDelay)) {
                    ForEach(NotchAutoCollapseDelay.allCases) { delay in
                        Text(delay.label).tag(delay)
                    }
                }

                TextField(l10n.lblNotchCenterText, text: store.binding(\.notchCenterText))
            }

            Section(l10n.secNotchCharacters) {
                NotchCompactRegionControl(
                    title: l10n.language.s("Left region", "왼쪽 영역"),
                    region: .notchCompactLeading,
                    selection: store.binding(\.notchCompactLeadingSelection)
                )

                NotchCompactRegionControl(
                    title: l10n.language.s("Center region", "중앙 영역"),
                    region: .notchCompactCenter,
                    selection: store.binding(\.notchCompactCenterSelection)
                )

                NotchCompactRegionControl(
                    title: l10n.language.s("Right region", "오른쪽 영역"),
                    region: .notchCompactTrailing,
                    selection: store.binding(\.notchCompactTrailingSelection)
                )

                Divider()

                NotchCharacterControl(
                    title: l10n.lblLeftCharacter,
                    mode: store.binding(\.notchLeftCharacterMode),
                    specificKind: store.binding(\.notchLeftCharacterKind),
                    randomKinds: store.binding(\.notchLeftRandomCharacterKinds)
                )

                Divider()

                NotchCharacterControl(
                    title: l10n.lblRightCharacter,
                    mode: store.binding(\.notchRightCharacterMode),
                    specificKind: store.binding(\.notchRightCharacterKind),
                    randomKinds: store.binding(\.notchRightRandomCharacterKinds)
                )

                SettingsSliderRow(
                    title: l10n.lblCharacterHorizontalInset(Int(store.settings.notchCharacterHorizontalInset)),
                    value: store.binding(\.notchCharacterHorizontalInset),
                    range: 12...64,
                    step: 1
                )

                SettingsSliderRow(
                    title: l10n.lblCharacterVerticalOffset(Int(store.settings.notchCharacterVerticalOffset)),
                    value: store.binding(\.notchCharacterVerticalOffset),
                    range: -8...12,
                    step: 1
                )
            }

            Section(l10n.secRequests) {
                Picker(l10n.lblRequestDisplay, selection: $displayPrefs.requestDisplayTarget) {
                    ForEach(RequestDisplayTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
            }

            Section(l10n.secNotchAutoExpand) {
                Toggle(l10n.lblNotchAutoExpand, isOn: store.binding(\.notchAutoExpandEnabled))

                Picker(l10n.lblUnreadDotPosition, selection: store.binding(\.notchUnreadDotPosition)) {
                    ForEach(NotchUnreadDotPosition.allCases) { pos in
                        Text(pos.label).tag(pos)
                    }
                }
            }

            Section(l10n.secNotchExpandTriggers) {
                let enabled = store.settings.notchAutoExpandEnabled
                triggerRow(
                    label: l10n.lblExpandOnNotification,
                    hint: l10n.hintExpandOnNotification,
                    binding: store.binding(\.expandOnNotification),
                    enabled: enabled
                )
                let notifEnabled = enabled && store.settings.expandOnNotification
                subTriggerRow(
                    label: l10n.lblExpandOnTaskCompletion,
                    hint: l10n.hintExpandOnTaskCompletion,
                    binding: store.binding(\.expandOnTaskCompletion),
                    enabled: notifEnabled
                )
                subTriggerRow(
                    label: l10n.lblExpandOnIdlePrompt,
                    hint: l10n.hintExpandOnIdlePrompt,
                    binding: store.binding(\.expandOnIdlePrompt),
                    enabled: notifEnabled
                )
                subTriggerRow(
                    label: l10n.lblExpandOnNotificationMessage,
                    hint: l10n.hintExpandOnNotificationMessage,
                    binding: store.binding(\.expandOnNotificationMessage),
                    enabled: notifEnabled
                )
                triggerRow(
                    label: l10n.lblExpandOnApprovalRequest,
                    hint: l10n.hintExpandOnApprovalRequest,
                    binding: store.binding(\.expandOnApprovalRequest),
                    enabled: enabled
                )
                triggerRow(
                    label: l10n.lblExpandOnQuestionResponse,
                    hint: l10n.hintExpandOnQuestionResponse,
                    binding: store.binding(\.expandOnQuestionResponse),
                    enabled: enabled
                )
                triggerRow(
                    label: l10n.lblExpandOnInteractiveTool,
                    hint: l10n.hintExpandOnInteractiveTool,
                    binding: store.binding(\.expandOnInteractiveTool),
                    enabled: enabled
                )
            }
        }
        .formStyle(.grouped)
    }

    private func displayName(for screen: NSScreen) -> String {
        let index = NSScreen.screens.firstIndex(of: screen).map { $0 + 1 } ?? 1
        let role = screen == NSScreen.main ? l10n.monitorMain() : l10n.monitorN(index)
        return "\(role) · \(Int(screen.frame.width))×\(Int(screen.frame.height))"
    }

    private func triggerRow(label: String, hint: String, binding: Binding<Bool>, enabled: Bool) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!enabled)
    }

    /// 들여쓰기가 적용된 하위 토글 행 (부모 토글 아래에 종류별 옵션 표시용)
    private func subTriggerRow(label: String, hint: String, binding: Binding<Bool>, enabled: Bool) -> some View {
        triggerRow(label: label, hint: hint, binding: binding, enabled: enabled)
            .padding(.leading, 20)
    }
}

private struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    private let formatter: NumberFormatter

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = step < 1 ? 2 : 0
        self.formatter = formatter
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { value = clamped($0) }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
                .frame(width: 220, alignment: .leading)
            Slider(value: clampedValue, in: range, step: step)
            TextField("", value: clampedValue, formatter: formatter)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .accessibilityLabel(title)
        }
    }

    private func clamped(_ newValue: Double) -> Double {
        guard newValue.isFinite else { return value }
        let stepped = step > 0 ? (newValue / step).rounded() * step : newValue
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

private struct NotchCompactRegionControl: View {
    let title: String
    let region: PluginRegionID
    @Binding var selection: NotchCompactRegionSelection
    @ObservedObject private var pluginHost = AppState.shared.pluginHost
    @ObservedObject private var l10n = L10n.shared

    private var providers: [PluginManifest] {
        pluginHost.compactRegionProviders(for: region)
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text(l10n.language.s("Hidden", "숨김"))
                .tag(NotchCompactRegionSelection.hidden)
            ForEach(providers, id: \.id) { manifest in
                Text(manifest.displayName(language: l10n.language))
                    .tag(NotchCompactRegionSelection.provider(manifest.id))
            }
            if let selectedID = selection.providerID,
               !providers.contains(where: { $0.id == selectedID }) {
                Text(l10n.language.s("Unavailable provider", "사용할 수 없는 제공자"))
                    .tag(selection)
            }
        }
    }
}

private struct NotchCharacterControl: View {
    let title: String
    @Binding var mode: NotchCharacterMode
    @Binding var specificKind: BuddyKind
    @Binding var randomKinds: Set<BuddyKind>
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: $mode) {
                ForEach(NotchCharacterMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            if mode == .specific {
                Picker(l10n.lblCharacter, selection: $specificKind) {
                    ForEach(BuddyKind.selectableCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
            } else if mode == .random {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.lblRandomIncludes)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(BuddyKind.selectableCases) { kind in
                        Toggle(kind.label, isOn: randomBinding(for: kind))
                            .disabled(randomKinds.count == 1 && randomKinds.contains(kind))
                    }
                }
                .padding(.leading, 2)
            }
        }
    }

    private func randomBinding(for kind: BuddyKind) -> Binding<Bool> {
        Binding(
            get: { randomKinds.contains(kind) },
            set: { isIncluded in
                if isIncluded {
                    randomKinds.insert(kind)
                } else if randomKinds.count > 1 {
                    randomKinds.remove(kind)
                }
            }
        )
    }
}
