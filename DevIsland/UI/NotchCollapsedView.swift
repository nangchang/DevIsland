import AppKit
import SwiftUI

// MARK: - Collapsed View (dedicated collapsed window)

struct NotchCollapsedView: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var sessionStore = AppState.shared.sessionStore
    @State private var buddyPulse = false
    @State private var notifPulse = false

    private var notchSize: NSSize {
        NotchLayout.collapsedSize(settings: settingsStore.settings)
    }

    private var hasDotIndicator: Bool {
        sessionStore.pendingCount > 0 || sessionStore.activeSessions.contains { $0.isUnread }
    }

    private var unreadDotX: CGFloat {
        switch settingsStore.settings.notchUnreadDotPosition {
        case .left:   return 18
        case .center: return notchSize.width / 2
        case .right:  return notchSize.width - 18
        }
    }

    private var sideRegionWidth: CGFloat {
        min(64, characterHorizontalInset * 2)
    }

    private var centerRegionWidth: CGFloat {
        max(0, notchSize.width - sideRegionWidth * 2)
    }

    var body: some View {
        HStack {
            Spacer()

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    collapsedBackground

                    ZStack {
                        CompactNotchRegionView(
                            region: .notchCompactCenter,
                            buddyPulse: buddyPulse
                        )
                        .frame(width: centerRegionWidth)
                        .position(x: notchSize.width / 2, y: notchSize.height / 2)

                        CompactNotchRegionView(
                            region: .notchCompactLeading,
                            buddyPulse: buddyPulse
                        )
                            .frame(width: sideRegionWidth, height: 24)
                            .position(x: characterHorizontalInset, y: characterCenterY)

                        CompactNotchRegionView(
                            region: .notchCompactTrailing,
                            buddyPulse: buddyPulse
                        )
                            .frame(width: sideRegionWidth, height: 24)
                            .position(x: notchSize.width - characterHorizontalInset, y: characterCenterY)

                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(notifPulse ? 0.0 : 0.65))
                                .frame(width: notifPulse ? 22 : 7, height: notifPulse ? 22 : 7)
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 7, height: 7)
                                .shadow(color: .orange, radius: 3)
                        }
                        .position(x: unreadDotX, y: notchSize.height - 6)
                        .opacity(hasDotIndicator ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: hasDotIndicator)
                    }
                    .frame(width: notchSize.width, height: notchSize.height)
                }
                .offset(y: settingsStore.settings.notchShapeStyle == .dynamicIsland ? 3 : 0)
            }
            .frame(
                width: notchSize.width,
                height: NotchLayout.windowSize(expanded: false, settings: settingsStore.settings).height,
                alignment: .top
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                buddyPulse = true
            }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                notifPulse = true
            }
            AppState.shared.pluginHost.setVisibleCompactRegions(
                Set(PluginRegionID.allCases),
                source: "notch.compact"
            )
            AppState.shared.pluginHost.compactRegionSelectionChanged()
            AppState.shared.pluginHost.compactRegionsBecameVisible()
        }
        .onDisappear {
            AppState.shared.pluginHost.setVisibleCompactRegions([], source: "notch.compact")
        }
        .onReceive(settingsStore.$settings) { _ in
            AppState.shared.pluginHost.compactRegionSelectionChanged()
        }
    }

    private var collapsedBackground: some View {
        let style = settingsStore.settings.notchShapeStyle
        let (cr, tr): (CGFloat, CGFloat) = style == .dynamicIsland
            ? (notchSize.height / 2, 0)
            : (14, 6)
        let shape = NotchShape(cornerRadius: cr, topFilletRadius: tr, shapeStyle: style)

        return ZStack(alignment: .top) {
            if settingsStore.settings.notchBackdropShadowEnabled {
                shape
                    .fill(Color.black.opacity(0.28))
                    .offset(y: 2)
                    .blur(radius: 2)
                    .allowsHitTesting(false)

                shape
                    .fill(Color.black.opacity(0.14))
                    .offset(y: 1)
                    .blur(radius: 1)
                    .allowsHitTesting(false)
            }

            shape
                .fill(Color.black.opacity(settingsStore.settings.notchPanelOpacity))
        }
        .frame(
            width: notchSize.width,
            height: notchSize.height,
            alignment: .top
        )
    }

    private var characterHorizontalInset: CGFloat {
        max(12, min(notchSize.width / 2 - 12, settingsStore.settings.notchCharacterHorizontalInset))
    }

    private var characterCenterY: CGFloat {
        max(12, min(notchSize.height - 12, notchSize.height / 2 + settingsStore.settings.notchCharacterVerticalOffset))
    }
}

