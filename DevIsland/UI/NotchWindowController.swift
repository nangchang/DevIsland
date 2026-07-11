import AppKit
import SwiftUI
import Combine
import CoreGraphics
import os

// MARK: - Window Controller

let baseCollapsedNotchSize = NSSize(width: 260, height: 32)
let baseExpandedNotchSize = NSSize(width: 692, height: 300)
let notchHorizontalOffset: CGFloat = -10
let baseNotchExpansionDuration: TimeInterval = 0.35
let baseNotchCollapseDuration: TimeInterval = 0.28

enum NotchLayout {
    static func shadowOutset(expanded: Bool, settings: AppSettings) -> CGFloat {
        settings.notchBackdropShadowEnabled ? (expanded ? 8 : 5) : 0
    }

    static func collapsedSize(settings: AppSettings) -> NSSize {
        NSSize(width: settings.collapsedNotchWidth, height: settings.collapsedNotchHeight)
    }

    static func expandedSize(settings: AppSettings) -> NSSize {
        NSSize(width: settings.expandedNotchWidth, height: settings.expandedNotchHeight)
    }

    static func size(expanded: Bool, settings: AppSettings) -> NSSize {
        expanded ? expandedSize(settings: settings) : collapsedSize(settings: settings)
    }

    static func windowSize(expanded: Bool, settings: AppSettings) -> NSSize {
        let size = size(expanded: expanded, settings: settings)
        let outset = shadowOutset(expanded: expanded, settings: settings)
        return NSSize(width: size.width, height: size.height + outset)
    }

    static func transitionScale(settings: AppSettings) -> Double {
        let widthRatio = settings.expandedNotchWidth / baseExpandedNotchSize.width
        let heightRatio = settings.expandedNotchHeight / baseExpandedNotchSize.height
        let ratio = max(widthRatio, heightRatio)
        return min(max(ratio, 1.0), 1.7)
    }

    static func expansionDuration(settings: AppSettings) -> TimeInterval {
        guard settings.notchAnimationEnabled, settings.notchAnimationSpeed > 0 else { return 0 }
        return baseNotchExpansionDuration * transitionScale(settings: settings) / settings.notchAnimationSpeed
    }

    static func collapseDuration(settings: AppSettings) -> TimeInterval {
        guard settings.notchAnimationEnabled, settings.notchAnimationSpeed > 0 else { return 0 }
        return baseNotchCollapseDuration * transitionScale(settings: settings) / settings.notchAnimationSpeed
    }
}

private struct NotchAppearanceSnapshot: Equatable {
    let collapsedSize: NSSize
    let expandedSize: NSSize
    let collapsedWindowSize: NSSize
    let expandedWindowSize: NSSize
    let shadowEnabled: Bool
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class NotchWindowController: NSWindowController {
    static weak var current: NotchWindowController?

    private var cancellables = Set<AnyCancellable>()
    private var pendingSettle: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var isShowingModal = false
    private var screenCheckTimer: Timer?

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        screenCheckTimer?.invalidate()
        cancellables.removeAll()
    }
    private var pinnedCenterX: CGFloat?
    private var pinnedDisplayId: UInt32?
    private var isHiddenForFullScreen = false
    private var isManualExpand = false
    private var expandedPanel: NSPanel!

    convenience init() {
        let collapsedPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NotchLayout.windowSize(expanded: false, settings: SettingsStore.shared.settings)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        collapsedPanel.isFloatingPanel = true
        collapsedPanel.level = .mainMenu + 1
        collapsedPanel.backgroundColor = .clear
        collapsedPanel.isOpaque = false
        collapsedPanel.hasShadow = false
        collapsedPanel.ignoresMouseEvents = false
        collapsedPanel.acceptsMouseMovedEvents = true
        collapsedPanel.isMovableByWindowBackground = false
        collapsedPanel.animationBehavior = .none
        collapsedPanel.collectionBehavior = Self.collectionBehavior(showInFullScreenApps: AppState.shared.displayPrefs.showInFullScreenApps)

        let expandedPanel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: NotchLayout.windowSize(expanded: true, settings: SettingsStore.shared.settings)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        expandedPanel.isFloatingPanel = true
        expandedPanel.level = .mainMenu + 2
        expandedPanel.backgroundColor = .clear
        expandedPanel.isOpaque = false
        expandedPanel.hasShadow = false
        expandedPanel.ignoresMouseEvents = false
        expandedPanel.acceptsMouseMovedEvents = true
        expandedPanel.isMovableByWindowBackground = false
        expandedPanel.animationBehavior = .none
        expandedPanel.becomesKeyOnlyIfNeeded = true
        expandedPanel.collectionBehavior = Self.collectionBehavior(showInFullScreenApps: AppState.shared.displayPrefs.showInFullScreenApps)

        self.init(window: collapsedPanel)
        self.expandedPanel = expandedPanel
        Self.current = self

        let collapsedView = NotchCollapsedHostingView(rootView: NotchCollapsedView())
        collapsedView.wantsLayer = true
        collapsedView.layer?.backgroundColor = .clear
        collapsedPanel.contentView = collapsedView

        let expandedView = NotchHostingView(rootView: NotchView())
        expandedView.wantsLayer = true
        expandedView.layer?.backgroundColor = .clear
        expandedPanel.contentView = expandedView
        
        updateWindowFrame(animate: false)

        AppState.shared.$isNotchExpanded
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                self?.handleExpansionChange(expanded)
            }
            .store(in: &cancellables)

        AppState.shared.displayPrefs.$notchDisplayTarget
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false)
            }
            .store(in: &cancellables)

        AppState.shared.displayPrefs.$selectedDisplayId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false)
            }
            .store(in: &cancellables)

        AppState.shared.displayPrefs.$requestDisplayTarget
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetPinnedPosition()
                // 만약 현재 요청을 보여주는 중이라면 새로운 설정에 맞춰 화면을 이동시킨다.
                let override = AppState.shared.isNotchExpanded ? ScreenTargeting.requestTargetScreen() : nil
                self?.updateWindowFrame(animate: false, targetScreenOverride: override)
            }
            .store(in: &cancellables)

        AppState.shared.displayPrefs.$showInFullScreenApps
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] showInFullScreenApps in
                let behavior = Self.collectionBehavior(showInFullScreenApps: showInFullScreenApps)
                self?.window?.collectionBehavior = behavior
                self?.expandedPanel.collectionBehavior = behavior
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false)
                self?.updateFullScreenVisibility()
            }
            .store(in: &cancellables)

        SettingsStore.shared.$settings
            .map { settings in
                NotchAppearanceSnapshot(
                    collapsedSize: NotchLayout.collapsedSize(settings: settings),
                    expandedSize: NotchLayout.expandedSize(settings: settings),
                    collapsedWindowSize: NotchLayout.windowSize(expanded: false, settings: settings),
                    expandedWindowSize: NotchLayout.windowSize(expanded: true, settings: settings),
                    shadowEnabled: settings.notchBackdropShadowEnabled
                )
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.window?.hasShadow = false
                self?.expandedPanel.hasShadow = false
                self?.updateWindowFrame(animate: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false)
                self?.updateFullScreenVisibility()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: collapsedPanel)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.resetPinnedPosition()
                self.updateWindowFrame(animate: false)
                // makeKey()를 받은 NSPanel은 canJoinAllSpaces에도 불구하고
                // 해당 Space에 고정될 수 있으므로, 스페이스 전환 시 재표시한다.
                guard !self.isHiddenForFullScreen, !self.isShowingModal else { return }
                if AppState.shared.isNotchExpanded {
                    self.expandedPanel.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    return
                }
                // 확장 상태가 아닐 때만 포커스를 따라감 (확장 중에는 사용자 조작 보호를 위해 고정)
                let state = AppState.shared
                if !state.isNotchExpanded {
                    self?.resetPinnedPosition()
                    self?.updateWindowFrame(animate: false)
                } else {
                    // 확장 중 포커스가 바뀌었다면 터미널로 돌아갔는지 확인하여 자동 pass 처리
                    state.passIfTerminalFocused()
                }
                self?.updateFullScreenVisibility()
            }
            .store(in: &cancellables)

        AppState.shared.sessionStore.$pendingItems
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                guard count > 0, AppState.shared.isNotchExpanded else { return }
                // 새로운 요청이 추가되었을 때, 설정된 요청 표시 위치로 이동
                let override = ScreenTargeting.requestTargetScreen()
                Log.ui.debug("PendingCount changed (\(count, privacy: .public)), requesting move to: \(override?.displayId.description ?? "default", privacy: .public)")
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false, targetScreenOverride: override)
            }
            .store(in: &cancellables)

        // 전역 마우스 클릭 감지: 마우스/포커스 이동 시 즉각적인 반응을 위해 사용 (접근성 권한 필요)
        self.mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let state = AppState.shared
            let isRequestShowing = state.isNotchExpanded && !state.sessionStore.pendingItems.isEmpty
            
            let isTargetFocused = isRequestShowing ? (state.displayPrefs.requestDisplayTarget == .focused) : (state.displayPrefs.notchDisplayTarget == .focused)
            let isTargetMouse = isRequestShowing ? (state.displayPrefs.requestDisplayTarget == .mouse) : (state.displayPrefs.notchDisplayTarget == .mouse)
            
            // 확장 상태가 아닐 때만 클릭 시 즉시 위치 갱신
            if !state.isNotchExpanded && (isTargetFocused || isTargetMouse) {
                self.resetPinnedPosition()
                self.updateWindowFrame(animate: false)
            } else if state.isNotchExpanded {
                // 확장 중 클릭 시 터미널 포커스 여부 확인하여 자동 pass 처리
                state.passIfTerminalFocused()
            }
        }
        
        // 주기적 화면 체크 (마우스/포커스 이동 감지 보완)
        // .common 모드로 등록해 스크롤/드래그 등 UI 트래킹 중에도 계속 실행되도록 한다.
        let screenCheckTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !AppState.shared.isNotchExpanded else { return }
                let state = AppState.shared
                if state.displayPrefs.notchDisplayTarget == .focused || state.displayPrefs.notchDisplayTarget == .mouse {
                    self.updateWindowFrame(animate: false)
                }
            }
        }
        RunLoop.main.add(screenCheckTimer, forMode: .common)
        self.screenCheckTimer = screenCheckTimer

        DispatchQueue.main.async { [weak self] in
            self?.updateFullScreenVisibility()
        }
    }

    private func handleExpansionChange(_ expanded: Bool) {
        guard !isShowingModal else { return }
        pendingSettle?.cancel()
        let settings = SettingsStore.shared.settings
        let usesTransparentPanel = settings.notchPanelOpacity < 0.999
        let expansionDuration = NotchLayout.expansionDuration(settings: settings)
        let collapseDuration = NotchLayout.collapseDuration(settings: settings)
        
        if expanded {
            window?.level = .mainMenu + 1
            expandedPanel.level = .mainMenu + 2
            
            if isManualExpand {
                isManualExpand = false
                resetPinnedPosition()
                updateWindowFrame(animate: false)
            } else {
                let override = ScreenTargeting.requestTargetScreen()
                resetPinnedPosition()
                updateWindowFrame(animate: false, targetScreenOverride: override)
                
                if AppState.shared.sessionStore.pendingCount > 0 {
                    AppState.shared.isExpandingFromRequest = false
                }
            }
            
            expandedPanel.orderFrontRegardless()

            if usesTransparentPanel || expansionDuration == 0 {
                window?.orderOut(nil)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    self?.window?.orderOut(nil)
                }
                pendingSettle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + expansionDuration, execute: work)
            }

        } else {
            window?.level = .mainMenu + 2
            expandedPanel.level = .mainMenu + 1

            AppState.shared.isExpandingFromRequest = false
            resetPinnedPosition()

            if usesTransparentPanel {
                if collapseDuration == 0 {
                    expandedPanel.orderOut(nil)
                    updateWindowFrame(animate: false)
                    window?.orderFrontRegardless()
                } else {
                    let work = DispatchWorkItem { [weak self] in
                        self?.expandedPanel.orderOut(nil)
                        self?.updateWindowFrame(animate: false)
                        self?.window?.orderFrontRegardless()
                    }
                    pendingSettle = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration, execute: work)
                }
            } else {
                updateWindowFrame(animate: false)
                window?.orderFrontRegardless()

                if collapseDuration == 0 {
                    expandedPanel.orderOut(nil)
                } else {
                    let work = DispatchWorkItem { [weak self] in
                        self?.expandedPanel.orderOut(nil)
                    }
                    pendingSettle = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration, execute: work)
                }
            }
        }

        reportPluginSurfaceVisibility()
    }

    /// Reports whether the expanded notch surface is actually on screen so plugins
    /// tick only while visible. Accounts for the modal/fullscreen hide paths that
    /// order the panel out without changing `isNotchExpanded`. v1 exposes only the
    /// `notch.expanded.activity` surface.
    private func reportPluginSurfaceVisibility() {
        let expandedVisible = AppState.shared.isNotchExpanded
            && !isShowingModal
            && !isHiddenForFullScreen
        AppState.shared.pluginHost.setVisibleSurfaces(
            expandedVisible ? [.notchExpandedActivity] : [],
            source: "notch"
        )
    }

    func updateWindowFrame(animate: Bool = true, sizeOverride: NSSize? = nil, targetScreenOverride: NSScreen? = nil) {
        guard let window = window else { return }
        let screen = targetScreenOverride ?? ScreenTargeting.targetScreen(for: window)
        let settings = SettingsStore.shared.settings
        let collapsedWindowSize = NotchLayout.windowSize(expanded: false, settings: settings)
        let expandedWindowSize = NotchLayout.windowSize(expanded: true, settings: settings)
        
        if let pinnedDisplayId, pinnedDisplayId != screen.displayId {
            resetPinnedPosition()
        }

        let centerX = pinnedCenterX ?? ScreenTargeting.notchCenterX(on: screen)
        pinnedCenterX = centerX
        pinnedDisplayId = screen.displayId

        let colX = centerX - collapsedWindowSize.width / 2 + notchHorizontalOffset
        let colY = screen.frame.maxY - collapsedWindowSize.height
        window.setFrame(NSRect(origin: NSPoint(x: colX, y: colY), size: sizeOverride ?? collapsedWindowSize), display: true, animate: animate)
        
        let expX = centerX - expandedWindowSize.width / 2 + notchHorizontalOffset
        let expY = screen.frame.maxY - expandedWindowSize.height
        expandedPanel.setFrame(NSRect(origin: NSPoint(x: expX, y: expY), size: expandedWindowSize), display: true, animate: animate)
        
        updateFullScreenVisibility()
    }

    /// 드래그 리사이즈 중 NSPanel 프레임을 직접 업데이트한다 (SettingsStore 우회).
    func updateLiveExpandedFrame(size: NSSize) {
        guard let screen = expandedPanel.screen ?? window?.screen ?? NSScreen.main else { return }
        let settings = SettingsStore.shared.settings
        let outset = NotchLayout.shadowOutset(expanded: true, settings: settings)
        let winSize = NSSize(width: size.width, height: size.height + outset)
        let centerX = pinnedCenterX ?? ScreenTargeting.notchCenterX(on: screen)
        let expX = centerX - winSize.width / 2 + notchHorizontalOffset
        let expY = screen.frame.maxY - winSize.height
        expandedPanel.setFrame(NSRect(origin: NSPoint(x: expX, y: expY), size: winSize), display: false, animate: false)
    }

    func hideForModal() {
        isShowingModal = true
        pendingSettle?.cancel()
        pendingSettle = nil
        window?.orderOut(nil)
        expandedPanel.orderOut(nil)
        reportPluginSurfaceVisibility()
    }

    func restoreAfterModal() {
        isShowingModal = false
        window?.orderFrontRegardless()
        reportPluginSurfaceVisibility()
    }

    func expandFromCollapsedWindow() {
        guard !AppState.shared.isNotchExpanded else { return }

        let store = AppState.shared.sessionStore
        for session in store.activeSessions where session.isUnread {
            store.setUnread(false, sessionId: session.id)
        }

        isManualExpand = true
        updateWindowFrame(animate: false)
        AppState.shared.isNotchExpanded = true
    }

    private static func notchSize(expanded: Bool) -> NSSize {
        NotchLayout.size(expanded: expanded, settings: SettingsStore.shared.settings)
    }

    private static func collectionBehavior(showInFullScreenApps: Bool) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary]
        if showInFullScreenApps {
            behavior.insert(.fullScreenAuxiliary)
        }
        return behavior
    }

    private func resetPinnedPosition() {
        pinnedCenterX = nil
        pinnedDisplayId = nil
    }

    private func updateFullScreenVisibility() {
        guard let window = window else { return }

        let shouldHide = !AppState.shared.displayPrefs.showInFullScreenApps && ScreenTargeting.frontmostApplicationIsFullScreen()
        if shouldHide {
            guard !isHiddenForFullScreen else { return }
            isHiddenForFullScreen = true
            window.orderOut(nil)
            expandedPanel.orderOut(nil)
            reportPluginSurfaceVisibility()
            return
        }

        guard isHiddenForFullScreen else { return }
        isHiddenForFullScreen = false
        if AppState.shared.isNotchExpanded {
            expandedPanel.orderFrontRegardless()
        } else {
            window.orderFrontRegardless()
        }
        reportPluginSurfaceVisibility()
    }

}

extension NSScreen {
    var displayId: UInt32 {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    }
}

// MARK: - Collapsed Passthrough Hosting View

class NotchCollapsedHostingView: NSHostingView<NotchCollapsedView> {
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard notchHitRect().contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        AppState.shared.pauseAutoTimersForUserViewing()
        (window?.windowController as? NotchWindowController)?.expandFromCollapsedWindow()
        super.mouseDown(with: event)
    }

    private func notchHitRect() -> CGRect {
        let visualSize = NotchLayout.collapsedSize(settings: SettingsStore.shared.settings)
        return CGRect(
            x: (bounds.width - visualSize.width) / 2,
            y: bounds.maxY - visualSize.height,
            width: visualSize.width,
            height: visualSize.height
        )
    }
}

// MARK: - Expanded Passthrough Hosting View

class NotchHostingView: NSHostingView<NotchView> {
    // 투명 픽셀 영역에서 OS 수준 click-through가 동작하도록 비불투명 처리
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        AppState.shared.pauseAutoTimersForUserViewing()
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard notchHitRect().contains(point) else { return nil }
        return super.hitTest(point) ?? self  // SwiftUI 내부 이벤트 라우팅 유지
    }

    private func notchHitRect() -> CGRect {
        let visualSize = NotchLayout.size(
            expanded: AppState.shared.isNotchExpanded,
            settings: SettingsStore.shared.settings
        )
        return CGRect(
            x: (bounds.width - visualSize.width) / 2,
            y: bounds.maxY - visualSize.height,
            width: visualSize.width,
            height: visualSize.height
        )
    }
}
