import AppKit
import SwiftUI
import Combine
import CoreGraphics

// MARK: - Window Controller

let collapsedNotchSize = NSSize(width: 260, height: 32)
let expandedNotchSize = NSSize(width: 692, height: 300)
let notchHorizontalOffset: CGFloat = -10
let notchExpansionDuration: TimeInterval = 0.35
let notchCollapseDuration: TimeInterval = 0.28

class NotchWindowController: NSWindowController {
    private var cancellables = Set<AnyCancellable>()
    private var pendingSettle: DispatchWorkItem?
    private var mouseMonitor: Any?

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
            contentRect: NSRect(origin: .zero, size: collapsedNotchSize),
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
        collapsedPanel.collectionBehavior = Self.collectionBehavior(showInFullScreenApps: AppState.shared.showInFullScreenApps)

        let expandedPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: expandedNotchSize),
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
        expandedPanel.collectionBehavior = Self.collectionBehavior(showInFullScreenApps: AppState.shared.showInFullScreenApps)

        self.init(window: collapsedPanel)
        self.expandedPanel = expandedPanel

        let collapsedView = NotchHostingView(rootView: NotchView(forceCollapsed: true))
        collapsedView.wantsLayer = true
        collapsedView.layer?.backgroundColor = .clear
        collapsedPanel.contentView = collapsedView
        
        let expandedView = NotchHostingView(rootView: NotchView(forceCollapsed: false))
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

        AppState.shared.$notchDisplayTarget
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false)
            }
            .store(in: &cancellables)

        AppState.shared.$selectedDisplayId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false)
            }
            .store(in: &cancellables)

        AppState.shared.$requestDisplayTarget
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetPinnedPosition()
                // 만약 현재 요청을 보여주는 중이라면 새로운 설정에 맞춰 화면을 이동시킨다.
                let override = AppState.shared.isNotchExpanded ? Self.requestTargetScreen() : nil
                self?.updateWindowFrame(animate: false, targetScreenOverride: override)
            }
            .store(in: &cancellables)

        AppState.shared.$showInFullScreenApps
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
                self?.resetPinnedPosition()
                self?.updateWindowFrame(animate: false)
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
            
            let isTargetFocused = isRequestShowing ? (state.requestDisplayTarget == .focused) : (state.notchDisplayTarget == .focused)
            let isTargetMouse = isRequestShowing ? (state.requestDisplayTarget == .mouse) : (state.notchDisplayTarget == .mouse)
            
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
            if state.notchDisplayTarget == .focused || state.notchDisplayTarget == .mouse {
                self.updateWindowFrame(animate: false)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateFullScreenVisibility()
        }
    }

    private func handleExpansionChange(_ expanded: Bool) {
        pendingSettle?.cancel()
        
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
            
            let work = DispatchWorkItem { [weak self] in
                self?.window?.orderOut(nil)
            }
            pendingSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + notchExpansionDuration, execute: work)
            
        } else {
            window?.level = .mainMenu + 2
            expandedPanel.level = .mainMenu + 1
            
            AppState.shared.isExpandingFromRequest = false
            resetPinnedPosition()
            
            window?.orderFrontRegardless()
            
            let work = DispatchWorkItem { [weak self] in
                self?.expandedPanel.orderOut(nil)
                self?.updateWindowFrame(animate: false)
            }
            pendingSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        }
    }

    func updateWindowFrame(animate: Bool = true, sizeOverride: NSSize? = nil, targetScreenOverride: NSScreen? = nil) {
        guard let window = window else { return }
        let screen = targetScreenOverride ?? targetScreen(for: window)
        
        if let pinnedDisplayId, pinnedDisplayId != screen.displayId {
            resetPinnedPosition()
        }

        let centerX = pinnedCenterX ?? Self.notchCenterX(on: screen)
        pinnedCenterX = centerX
        pinnedDisplayId = screen.displayId

        let colX = centerX - collapsedNotchSize.width / 2 + notchHorizontalOffset
        let colY = screen.frame.maxY - collapsedNotchSize.height
        window.setFrame(NSRect(origin: NSPoint(x: colX, y: colY), size: collapsedNotchSize), display: true, animate: animate)
        
        let expX = centerX - expandedNotchSize.width / 2 + notchHorizontalOffset
        let expY = screen.frame.maxY - expandedNotchSize.height
        expandedPanel.setFrame(NSRect(origin: NSPoint(x: expX, y: expY), size: expandedNotchSize), display: true, animate: animate)
        
        updateFullScreenVisibility()
    }

    func expandFromCollapsedWindow() {
        guard !AppState.shared.isNotchExpanded else { return }

        isManualExpand = true
        updateWindowFrame(animate: false)
        AppState.shared.isNotchExpanded = true
    }

    private static func notchSize(expanded: Bool) -> NSSize {
        expanded ? expandedNotchSize : collapsedNotchSize
    }

    private static func collectionBehavior(showInFullScreenApps: Bool) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary]
        if showInFullScreenApps {
            behavior.insert(.fullScreenAuxiliary)
        }
        return behavior
    }

    private static func notchCenterX(on screen: NSScreen) -> CGFloat {
        // TODO: auxiliaryTopLeftArea is a private KVC key. Using it poses a risk for App Store submission
        // and may break in future macOS updates. Ensure a robust fallback to screen center exists.
        // macOS 15+ has private/new APIs for auxiliary areas.
        // We check for them safely to avoid crashes on older versions.
        let leftValue = (screen as NSObject).value(forKey: "auxiliaryTopLeftArea") as? NSValue
        let rightValue = (screen as NSObject).value(forKey: "auxiliaryTopRightArea") as? NSValue

        if let leftArea = leftValue?.rectValue,
           let rightArea = rightValue?.rectValue,
           !leftArea.isEmpty,
           !rightArea.isEmpty {
            let mid = (leftArea.maxX + rightArea.minX) / 2
            
            // 감지된 좌표가 화면 범위 밖이라면(로컬 좌표계라면) 화면 시작점을 더해준다.
            if mid < screen.frame.minX || mid > screen.frame.maxX {
                let globalX = screen.frame.minX + mid
                print("[DevIsland] Using auxiliary areas (local->global): \(mid) -> \(globalX)")
                return round(globalX)
            }
            
            print("[DevIsland] Using auxiliary areas (global): \(mid)")
            return round(mid)
        }

        return round(screen.frame.midX)
    }

    private func resetPinnedPosition() {
        pinnedCenterX = nil
        pinnedDisplayId = nil
    }

    private func updateFullScreenVisibility() {
        guard let window = window else { return }

        let shouldHide = !AppState.shared.showInFullScreenApps && Self.frontmostApplicationIsFullScreen()
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

        switch state.notchDisplayTarget {
        case .main:
            return NSScreen.screens.first!
        case .mouse:
            return Self.mouseScreen() ?? NSScreen.main ?? NSScreen.screens.first!
        case .focused:
            // 키보드 포커스가 있는 화면(NSScreen.main)을 최우선으로 하되, 보조적으로 마우스 위치 참고
            return NSScreen.main ?? Self.mouseScreen() ?? NSScreen.screens.first!
        case .specific:
            if let screen = NSScreen.screens.first(where: { $0.displayId == state.selectedDisplayId }) {
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
        switch AppState.shared.requestDisplayTarget {
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

// MARK: - Passthrough Hosting View

class NotchHostingView: NSHostingView<NotchView> {
    // 투명 픽셀 영역에서 OS 수준 click-through가 동작하도록 비불투명 처리
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard notchHitRect().contains(point) else { return nil }
        return super.hitTest(point) ?? self  // SwiftUI 내부 이벤트 라우팅 유지
    }

    override func mouseDown(with event: NSEvent) {
        if !AppState.shared.isNotchExpanded {
            (window?.windowController as? NotchWindowController)?.expandFromCollapsedWindow()
            return
        }

        super.mouseDown(with: event)
    }

    private func notchHitRect() -> CGRect {
        // 동적 프레임 모드에서는 윈도우 전체가 곧 노치이므로 bounds 전체를 리턴
        return bounds
    }
}

