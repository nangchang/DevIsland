import AppKit
import CoreGraphics

// MARK: - Screen Targeting

/// 노치 윈도우가 표시될 화면 선정과 최전면 앱의 전체화면 감지 로직.
/// 순수 계산 위주로 NotchWindowController에서 추출됨(행동 변화 없음).
enum ScreenTargeting {
    @MainActor
    static func targetScreen(for window: NSWindow) -> NSScreen {
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
    @MainActor
    static func requestTargetScreen() -> NSScreen? {
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

    static func notchCenterX(on screen: NSScreen) -> CGFloat {
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

    static func frontmostApplicationIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        if let isFullScreen = accessibilityFullScreenState(for: app.processIdentifier) {
            return isFullScreen
        }

        return frontmostApplicationScreenCoveringWindow(for: app.processIdentifier) != nil
    }

    static func isWindowOnScreen(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value == 1 }
        if let value = value as? NSNumber { return value.boolValue }
        return false
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
}

fileprivate extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
