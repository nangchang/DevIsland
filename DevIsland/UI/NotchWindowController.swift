import AppKit
import SwiftUI
import Combine
import CoreGraphics

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
        baseNotchExpansionDuration * transitionScale(settings: settings)
    }

    static func collapseDuration(settings: AppSettings) -> TimeInterval {
        baseNotchCollapseDuration * transitionScale(settings: settings)
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

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
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
                let override = AppState.shared.isNotchExpanded ? Self.requestTargetScreen() : nil
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

        AppState.shared.$currentClaudeQuestion
            .receive(on: RunLoop.main)
            .sink { [weak self] question in
                guard question != nil, AppState.shared.isNotchExpanded else { return }
                self?.focusExpandedPanelForTextInput()
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
                let override = Self.requestTargetScreen()
                print("[DevIsland] PendingCount changed (\(count)), requesting move to: \(override?.displayId.description ?? "default")")
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
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !AppState.shared.isNotchExpanded else { return }
            let state = AppState.shared
            if state.displayPrefs.notchDisplayTarget == .focused || state.displayPrefs.notchDisplayTarget == .mouse {
                self.updateWindowFrame(animate: false)
            }
        }

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
                let override = Self.requestTargetScreen()
                resetPinnedPosition()
                updateWindowFrame(animate: false, targetScreenOverride: override)
                
                if AppState.shared.sessionStore.pendingCount > 0 {
                    AppState.shared.isExpandingFromRequest = false
                }
            }
            
            expandedPanel.orderFrontRegardless()
            focusExpandedPanelForTextInput()

            if usesTransparentPanel {
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
                let work = DispatchWorkItem { [weak self] in
                    self?.expandedPanel.orderOut(nil)
                    self?.updateWindowFrame(animate: false)
                    self?.window?.orderFrontRegardless()
                }
                pendingSettle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration, execute: work)
            } else {
                updateWindowFrame(animate: false)
                window?.orderFrontRegardless()

                let work = DispatchWorkItem { [weak self] in
                    self?.expandedPanel.orderOut(nil)
                }
                pendingSettle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration, execute: work)
            }
        }
    }

    private func focusExpandedPanelForTextInput() {
        guard AppState.shared.currentClaudeQuestion != nil else { return }
        expandedPanel.makeKey()
    }

    func updateWindowFrame(animate: Bool = true, sizeOverride: NSSize? = nil, targetScreenOverride: NSScreen? = nil) {
        guard let window = window else { return }
        let screen = targetScreenOverride ?? targetScreen(for: window)
        let settings = SettingsStore.shared.settings
        let collapsedWindowSize = NotchLayout.windowSize(expanded: false, settings: settings)
        let expandedWindowSize = NotchLayout.windowSize(expanded: true, settings: settings)
        
        if let pinnedDisplayId, pinnedDisplayId != screen.displayId {
            resetPinnedPosition()
        }

        let centerX = pinnedCenterX ?? Self.notchCenterX(on: screen)
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
        let centerX = pinnedCenterX ?? Self.notchCenterX(on: screen)
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
    }

    func restoreAfterModal() {
        isShowingModal = false
        window?.orderFrontRegardless()
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

    private static func notchCenterX(on screen: NSScreen) -> CGFloat {
        // auxiliaryTopLeftArea/auxiliaryTopRightArea are public APIs since macOS 12.
        // Nil or empty rects indicate a non-notched display — fall back to screen center.
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              !leftArea.isEmpty, !rightArea.isEmpty else {
            return round(screen.frame.midX)
        }

        let mid = (leftArea.maxX + rightArea.minX) / 2

        // Coordinates may be in display-local space; shift to global if needed.
        if mid < screen.frame.minX || mid > screen.frame.maxX {
            return round(screen.frame.minX + mid)
        }

        return round(mid)
    }

    private func resetPinnedPosition() {
        pinnedCenterX = nil
        pinnedDisplayId = nil
    }

    private func updateFullScreenVisibility() {
        guard let window = window else { return }

        let shouldHide = !AppState.shared.displayPrefs.showInFullScreenApps && Self.frontmostApplicationIsFullScreen()
        if shouldHide {
            guard !isHiddenForFullScreen else { return }
            isHiddenForFullScreen = true
            window.orderOut(nil)
            expandedPanel.orderOut(nil)
            return
        }

        guard isHiddenForFullScreen else { return }
        isHiddenForFullScreen = false
        if AppState.shared.isNotchExpanded {
            expandedPanel.orderFrontRegardless()
        } else {
            window.orderFrontRegardless()
        }
    }

    private func targetScreen(for window: NSWindow) -> NSScreen {
        let state = AppState.shared

        // 만약 요청 표시 중(확장 상태 + 대기 아이템 존재)이라면 requestDisplayTarget 설정을 먼저 확인
        if state.isNotchExpanded && !AppState.shared.sessionStore.pendingItems.isEmpty {
            if let requestScreen = Self.requestTargetScreen() {
                return requestScreen
            }
        }

        switch state.displayPrefs.notchDisplayTarget {
        case .main:
            return NSScreen.screens.first!
        case .mouse:
            return Self.mouseScreen() ?? NSScreen.main ?? NSScreen.screens.first!
        case .focused:
            // 키보드 포커스가 있는 화면(NSScreen.main)을 최우선으로 하되, 보조적으로 마우스 위치 참고
            return NSScreen.main ?? Self.mouseScreen() ?? NSScreen.screens.first!
        case .specific:
            if let screen = NSScreen.screens.first(where: { $0.displayId == state.displayPrefs.selectedDisplayId }) {
                return screen
            }
            return NSScreen.main ?? NSScreen.screens.first!
        case .automatic:
            break
        }

        if let windowScreen = window.screen {
            return windowScreen
        }

        if let mouseScreen = Self.mouseScreen() {
            return mouseScreen
        }

        return NSScreen.screens.first!
    }

    /// 요청 표시 위치 설정에 따라 override할 화면을 반환한다.
    /// .notch는 기존 notchDisplayTarget을 따르므로 nil 반환.
    private static func requestTargetScreen() -> NSScreen? {
        switch AppState.shared.displayPrefs.requestDisplayTarget {
        case .notch:
            return nil
        case .focused:
            // 키보드 포커스가 있는 화면을 우선 감지
            return NSScreen.main ?? mouseScreen() ?? frontmostApplicationScreen()
        case .mouse:
            return mouseScreen() ?? NSScreen.main
        }
    }

    private static func mouseScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    private static func frontmostApplicationScreen() -> NSScreen? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        print("[DevIsland] Finding screen for frontmost app: \(appName) (pid: \(frontmostPID))")

        let frontmostWindows = windows.compactMap { windowInfo -> CGRect? in
            guard (windowInfo[kCGWindowOwnerPID as String] as? Int32) == frontmostPID,
                  (windowInfo[kCGWindowLayer as String] as? Int) == 0,
                  Self.isWindowOnScreen(windowInfo[kCGWindowIsOnscreen as String]),
                  let boundsInfo = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width > 40,
                  bounds.height > 40 else {
                return nil
            }
            return bounds
        }

        let screens = NSScreen.screens
        let screenBounds = screens.reduce(into: [UInt32: CGRect]()) { dict, screen in
            dict[screen.displayId] = CGDisplayBounds(screen.displayId)
        }

        let screenAreas = frontmostWindows.reduce(into: [UInt32: CGFloat]()) { dict, windowBounds in
            for screen in screens {
                if let displayBounds = screenBounds[screen.displayId] {
                    dict[screen.displayId, default: 0] += windowBounds.intersection(displayBounds).area
                }
            }
        }

        let bestDisplayId = screenAreas.max { $0.value < $1.value }?.key

        if let bestDisplayId, bestDisplayId != 0 {
            print("[DevIsland] Best display found: \(bestDisplayId)")
            return NSScreen.screens.first { $0.displayId == bestDisplayId }
        }
        
        print("[DevIsland] No suitable display found for frontmost app windows.")
        return nil
    }

    private static func frontmostApplicationIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        if let isFullScreen = accessibilityFullScreenState(for: app.processIdentifier) {
            return isFullScreen
        }

        return frontmostApplicationScreenCoveringWindow(for: app.processIdentifier) != nil
    }

    private static func accessibilityFullScreenState(for pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        if focusedResult == .success,
           let focusedWindow,
           CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
            return fullScreenState(for: focusedWindow as! AXUIElement)
        }

        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )

        guard windowsResult == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            if let isFullScreen = fullScreenState(for: window), isFullScreen {
                return true
            }
        }

        return windows.isEmpty ? nil : false
    }

    private static func fullScreenState(for window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
        guard result == .success else { return nil }

        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func frontmostApplicationScreenCoveringWindow(for pid: pid_t) -> NSScreen? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let displayBounds = NSScreen.screens.map { screen in
            (screen, CGDisplayBounds(screen.displayId))
        }

        for windowInfo in windows {
            guard (windowInfo[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (windowInfo[kCGWindowLayer as String] as? Int) == 0,
                  Self.isWindowOnScreen(windowInfo[kCGWindowIsOnscreen as String]),
                  let boundsInfo = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else {
                continue
            }

            if let coveringScreen = displayBounds.first(where: { _, screenBounds in
                bounds.intersection(screenBounds).area >= screenBounds.area * 0.96
            })?.0 {
                return coveringScreen
            }
        }

        return nil
    }

    private static func isWindowOnScreen(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value == 1 }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }
}

extension NSScreen {
    var displayId: UInt32 {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    }
}

fileprivate extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
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
