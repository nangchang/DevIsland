import AppKit
import SwiftUI
import Combine
import CoreGraphics

// MARK: - Window Controller

fileprivate let collapsedNotchSize = NSSize(width: 248, height: 32)
fileprivate let expandedNotchSize = NSSize(width: 680, height: 300)
fileprivate let notchHorizontalOffset: CGFloat = -10

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

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: expandedNotchSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .mainMenu + 1
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = Self.collectionBehavior(showInFullScreenApps: AppState.shared.showInFullScreenApps)

        self.init(window: panel)

        let notchView = NotchHostingView(rootView: NotchView())
        notchView.wantsLayer = true
        notchView.layer?.backgroundColor = .clear
        panel.contentView = notchView
        
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
                self?.window?.collectionBehavior = Self.collectionBehavior(showInFullScreenApps: showInFullScreenApps)
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

        NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: panel)
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

        AppState.shared.$pendingCount
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
            let isRequestShowing = state.isNotchExpanded && !state.pendingItems.isEmpty
            
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
            if isManualExpand {
                // 클릭 확장: 현재 화면 그대로 유지
                isManualExpand = false
                resetPinnedPosition()
                updateWindowFrame(animate: false)
            } else {
                // 요청 확장: requestDisplayTarget에 따라 화면 결정
                let override = Self.requestTargetScreen()
                print("[DevIsland] Request expansion detected, override screen: \(override?.displayId.description ?? "none")")
                resetPinnedPosition()
                updateWindowFrame(animate: false, targetScreenOverride: override)
                
                // 실제 승인 요청인 경우에만 즉시 해제 (알림은 메시지 표시를 위해 유지)
                if AppState.shared.pendingCount > 0 {
                    AppState.shared.isExpandingFromRequest = false
                }
            }
        } else {
            // 축소 시: 핀 위치를 즉시 해제해 설정된 화면으로 돌아가도록 한다.
            // 프레임 자체는 SwiftUI 애니메이션이 끝난 후 줄여 점프 방지.
            AppState.shared.isExpandingFromRequest = false
            resetPinnedPosition()
            let work = DispatchWorkItem { [weak self] in
                self?.updateWindowFrame(animate: false)
            }
            pendingSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        }
    }

    func updateWindowFrame(animate: Bool = true, sizeOverride: NSSize? = nil, targetScreenOverride: NSScreen? = nil) {
        guard let window = window else { return }
        let screen = targetScreenOverride ?? targetScreen(for: window)
        
        let expanded = AppState.shared.isNotchExpanded
        let size = sizeOverride ?? Self.notchSize(expanded: expanded)
        
        if let pinnedDisplayId, pinnedDisplayId != screen.displayId {
            resetPinnedPosition()
        }

        let centerX = pinnedCenterX ?? Self.notchCenterX(on: screen)
        pinnedCenterX = centerX
        pinnedDisplayId = screen.displayId

        let x = centerX - size.width / 2
        let y = screen.frame.maxY - size.height
        
        let newFrame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        window.setFrame(newFrame, display: true, animate: animate)
        updateFullScreenVisibility()
    }

    func expandFromCollapsedWindow() {
        guard !AppState.shared.isNotchExpanded else { return }

        // 프레임과 SwiftUI 상태를 같은 런루프에서 바꿔 중간 위치가 보이지 않게 한다.
        isManualExpand = true
        updateWindowFrame(animate: false, sizeOverride: expandedNotchSize)
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
            return
        }

        guard isHiddenForFullScreen else { return }
        isHiddenForFullScreen = false
        window.orderFrontRegardless()
    }

    private func targetScreen(for window: NSWindow) -> NSScreen {
        let state = AppState.shared

        // 만약 요청 표시 중(확장 상태 + 대기 아이템 존재)이라면 requestDisplayTarget 설정을 먼저 확인
        if state.isNotchExpanded && !state.pendingItems.isEmpty {
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

// MARK: - Tool Info

struct ToolInfo {
    let icon: String
    let color: Color
    let label: String
}

func toolInfo(for name: String) -> ToolInfo {
    switch name {
    case "Bash":       return ToolInfo(icon: "terminal.fill",          color: .orange, label: "Bash")
    case "Write":      return ToolInfo(icon: "doc.badge.plus",         color: Color(red: 0.3, green: 0.6, blue: 1.0), label: "Write")
    case "Edit":       return ToolInfo(icon: "pencil.and.outline",     color: Color(red: 0.3, green: 0.85, blue: 0.5), label: "Edit")
    case "Read":       return ToolInfo(icon: "doc.text",               color: .gray,   label: "Read")
    case "MultiEdit":  return ToolInfo(icon: "doc.on.doc",             color: Color(red: 0.3, green: 0.85, blue: 0.5), label: "MultiEdit")
    case "WebFetch":   return ToolInfo(icon: "globe",                  color: .purple, label: "WebFetch")
    case "WebSearch":  return ToolInfo(icon: "magnifyingglass",        color: Color(red: 0.2, green: 0.8, blue: 0.9), label: "WebSearch")
    case "Glob":       return ToolInfo(icon: "folder.badge.magnifyingglass", color: .yellow, label: "Glob")
    case "Grep":       return ToolInfo(icon: "text.magnifyingglass",   color: Color(red: 1.0, green: 0.8, blue: 0.2), label: "Grep")
    case "Agent":      return ToolInfo(icon: "person.2.fill",          color: .mint,   label: "Agent")
    default:           return ToolInfo(icon: "cpu",                    color: .white,  label: name.isEmpty ? "Tool" : name)
    }
}

// MARK: - Buddy Mascot

enum BuddyKind: CaseIterable {
    case gemini
    case codex
    case claudeCode
    case island

    static var allCases: [BuddyKind] {
        return [.gemini, .codex, .claudeCode]
    }

    init(from text: String) {
        let lower = text.lowercased()
        if lower.contains("claude") {
            self = .claudeCode
        } else if lower.contains("gemini") {
            self = .gemini
        } else if lower.contains("codex") || lower.contains("openai") || lower.contains("gpt") {
            self = .codex
        } else {
            self = .island
        }
    }

    var accentColor: Color {
        switch self {
        case .gemini:     return Color(red: 0.34, green: 0.38, blue: 1.0)
        case .codex:      return Color(red: 0.2, green: 0.6, blue: 0.9)
        case .claudeCode: return Color(red: 0.82, green: 0.42, blue: 0.30)
        case .island:     return Color(red: 0.20, green: 0.60, blue: 0.90)
        }
    }

    var accessibilityName: String {
        switch self {
        case .gemini:     return "Gemini"
        case .codex:      return "Codex"
        case .claudeCode: return "Claude Code"
        case .island:     return "DevIsland"
        }
    }
}

private struct PixelCell {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let color: Color

    init(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: Color) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
    }
}

struct CLIBuddyView: View {
    let isActive: Bool
    let kind: BuddyKind

    @State private var isFlipped = false
    private static let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let bob = isActive ? -size * 0.05 : size * 0.03

            ZStack {
                Capsule()
                    .fill(kind.accentColor.opacity(0.22))
                    .frame(width: size * 0.64, height: size * 0.12)
                    .blur(radius: size * 0.02)
                    .offset(y: size * 0.38)

                pixelBody(size: size)
                    .offset(y: bob)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityLabel("\(kind.accessibilityName) Buddy")
        .onReceive(Self.timer) { _ in
            if isActive {
                isFlipped.toggle()
            } else {
                isFlipped = false
            }
        }
    }

    private func pixelBody(size: CGFloat) -> some View {
        return ZStack {
            mascotSprite(size: size)
                .shadow(color: Color.black.opacity(0.25), radius: size * 0.04, y: size * 0.03)
        }
        .frame(width: size, height: size)
    }

    private func mascotSprite(size: CGFloat) -> some View {
        ZStack {
            switch kind {
            case .claudeCode:
                pixelGrid(size: size, cells: terminalBaseCells(kind: .claudeCode))
                pixelGrid(size: size, cells: claudeBodyCells())
                    .scaleEffect(x: isFlipped ? 1 : -1)
            case .gemini:
                pixelGrid(size: size, cells: terminalBaseCells(kind: .gemini))
                pixelGrid(size: size, cells: geminiBodyCells())
                    .scaleEffect(x: isFlipped ? 1 : -1)
            case .codex:
                pixelGrid(size: size, cells: terminalBaseCells(kind: .codex))
                pixelGrid(size: size, cells: codexBodyCells())
                    .scaleEffect(x: isFlipped ? 1 : -1)
            case .island:
                pixelGrid(size: size, cells: islandBodyCells())
            }
        }
    }

    private func codexBodyCells() -> [PixelCell] {
        let fur = Color(red: 0.20, green: 0.40, blue: 0.84)
        let ink = Color.white.opacity(0.95)

        var cells: [PixelCell] = []

        // Head (Original Cloud shape)
        cells += [
            // Ears
            PixelCell(24, 8, 8, 24, fur), PixelCell(32, 16, 8, 16, fur), PixelCell(40, 24, 8, 8, fur), // L
            PixelCell(88, 8, 8, 24, fur), PixelCell(80, 16, 8, 16, fur), PixelCell(72, 24, 8, 8, fur), // R (Moved inward)
            
            // Main Face
            PixelCell(24, 32, 80, 64, fur), // Square center
            PixelCell(16, 40, 8, 48, fur), PixelCell(104, 40, 8, 48, fur), // Side vertical
            PixelCell(8, 48, 8, 32, fur), PixelCell(112, 48, 8, 32, fur), // Far side vertical
            
            // Prompt Eye ( > )
            PixelCell(40, 48, 8, 8, ink),
            PixelCell(48, 56, 8, 8, ink),
            PixelCell(40, 64, 8, 8, ink),
            
            // Shortened Cursor Eye ( _ )
            PixelCell(72, 64, 24, 8, ink),
            
            // Whiskers (Fixed perspective: L shorter, R longer)
            PixelCell(8, 56, 8, 8, fur),                               // L (1px)
            PixelCell(112, 56, 16, 8, fur), PixelCell(112, 72, 16, 8, fur) // R (2px)
        ]
        
        // Simple tail for codex
        cells += [
            PixelCell(104, 80, 16, 8, fur),
            PixelCell(112, 72, 8, 8, fur)
        ]

        return cells
    }

    private func geminiBodyCells() -> [PixelCell] {
        let red = Color(red: 0.94, green: 0.33, blue: 0.23)
        let orange = Color(red: 0.96, green: 0.54, blue: 0.15)
        let yellow = Color(red: 0.98, green: 0.81, blue: 0.12)
        let green = Color(red: 0.22, green: 0.64, blue: 0.44)
        let blue = Color(red: 0.15, green: 0.54, blue: 0.94)
        let purple = Color(red: 0.58, green: 0.33, blue: 0.82)
        let pink = Color(red: 0.96, green: 0.65, blue: 0.72)
        let ink = Color(red: 0.12, green: 0.10, blue: 0.14)

        var cells: [PixelCell] = []

        // Sharper Star Body (4-pointed star look)
        // Top Point & Connections
        cells += [
            PixelCell(56, 16, 16, 8, red),
            PixelCell(40, 24, 40, 8, orange),
            PixelCell(32, 32, 56, 8, orange) // Fills gap between ears and body
        ]
        // Ears
        cells += [
            PixelCell(32, 0, 8, 32, orange), PixelCell(40, 8, 8, 16, pink), // L
            PixelCell(80, 0, 8, 32, purple), PixelCell(72, 8, 8, 16, pink) // R
        ]
        // Side Points (The "Horizontal" span)
        cells += [
            PixelCell(24, 40, 72, 8, orange), // Expanded row above eyes
            PixelCell(16, 48, 88, 8, yellow),
            PixelCell(16, 56, 96, 8, yellow), // Sharp horizontal tip (x=0 and x=15)
            PixelCell(0, 64, 128, 8, green),  // Slightly narrower row
            PixelCell(16, 72, 96, 8, green),
            PixelCell(32, 80, 64, 8, blue)
        ]
        // Bottom Point
        cells += [
            PixelCell(40, 88, 48, 8, blue),
            PixelCell(48, 96, 32, 8, purple),
            PixelCell(56, 104, 16, 8, purple),
            PixelCell(64, 112, 8, 8, purple),
        ]
        
        // Face (Enlarged eyes and "w" mouth from original image)
        cells += [
            PixelCell(24, 48, 8, 16, ink), PixelCell(80, 48, 8, 16, ink), // Symmetric eyes (moved left)
            
            // "w" shaped mouth (Cat smile, moved up)
            PixelCell(40, 64, 8, 8, ink), 
            PixelCell(48, 72, 8, 8, ink), 
            PixelCell(56, 64, 8, 8, ink), 
            PixelCell(64, 72, 8, 8, ink),
            PixelCell(72, 64, 8, 8, ink)
        ]

        return cells
    }

    private func claudeBodyCells() -> [PixelCell] {
        let fur = Color(red: 0.82, green: 0.42, blue: 0.30)

        let ink = Color(red: 0.09, green: 0.04, blue: 0.03)

        var cells: [PixelCell] = []

        // Body (Common) - Shifted Y up by 2 to make room for base
        cells += [
            // Ears (Triangular)
            PixelCell(32, 0, 8, 24, fur), PixelCell(40, 8, 8, 16, fur), PixelCell(48, 16, 8, 8, fur), // L (Moved outward)
            PixelCell(96, 0, 8, 24, fur), PixelCell(88, 8, 8, 16, fur), PixelCell(80, 16, 8, 8, fur), // R (Moved outward)
            PixelCell(24, 24, 80, 8, fur), // Head bridge
            
            // Face/Body (Wider and Shorter)
            PixelCell(24, 32, 80, 48, fur),
            
            // Eyes (Moved right for perspective and enlarged)
            PixelCell(48, 32, 8, 16, ink), PixelCell(88, 32, 8, 16, ink),
            
            // Whiskers (Shifted up slightly)
            PixelCell(16, 40, 8, 8, fur),                               // L
            PixelCell(104, 40, 16, 8, fur), PixelCell(104, 56, 8, 8, fur), // R
            
            // Legs (Shorter, shifted up)
            PixelCell(24, 80, 8, 16, fur), PixelCell(48, 80, 8, 16, fur),
            PixelCell(72, 80, 8, 16, fur), PixelCell(96, 80, 8, 16, fur)
        ]

        // Static Tail (will flip left/right automatically due to scaleEffect)
        cells += [
            PixelCell(8, 56, 16, 8, fur),
            PixelCell(0, 48, 8, 8, fur),
            PixelCell(0, 32, 8, 16, fur),
            PixelCell(8, 24, 8, 8, fur)
        ]

        return cells
    }

    private func islandBodyCells() -> [PixelCell] {
        let c0 = Color(red: 0.18, green: 0.33, blue: 0.33)
        let c1 = Color(red: 0.68, green: 0.79, blue: 0.47)
        let c2 = Color(red: 0.39, green: 0.58, blue: 0.27)
        let c3 = Color(red: 0.42, green: 0.34, blue: 0.27)
        let c4 = Color(red: 0.20, green: 0.60, blue: 0.90) // Water
        let c5 = Color(red: 0.88, green: 0.78, blue: 0.52) // Sand

        var cells: [PixelCell] = []
        cells.append(contentsOf: [
PixelCell(68, 16, 8, 4, c0),
            PixelCell(68, 20, 8, 4, c1),
            PixelCell(80, 20, 8, 4, c0),
            PixelCell(64, 24, 4, 4, c0),
            PixelCell(68, 24, 8, 4, c2),
            PixelCell(76, 24, 4, 4, c0),
            PixelCell(80, 24, 8, 4, c1),
            PixelCell(88, 24, 4, 4, c0),
            PixelCell(60, 28, 4, 4, c0),
            PixelCell(64, 28, 4, 4, c2),
            PixelCell(68, 28, 4, 4, c0),
            PixelCell(72, 28, 4, 4, c3),
            PixelCell(76, 28, 8, 4, c2),
            PixelCell(84, 28, 4, 4, c0),
            PixelCell(88, 28, 4, 4, c2),
            PixelCell(92, 28, 4, 4, c0),
            PixelCell(68, 32, 8, 4, c2),
            PixelCell(76, 32, 4, 4, c3),
            PixelCell(80, 32, 4, 4, c2),
            PixelCell(84, 32, 4, 4, c1),
            PixelCell(88, 32, 4, 4, c0),
            PixelCell(64, 36, 4, 4, c0),
            PixelCell(68, 36, 4, 4, c2),
            PixelCell(72, 36, 4, 4, c0),
            PixelCell(76, 36, 8, 4, c3),
            PixelCell(84, 36, 8, 4, c0),
            PixelCell(44, 40, 8, 4, c4),
            PixelCell(52, 40, 16, 4, c0),
            PixelCell(68, 40, 4, 4, c2),
            PixelCell(76, 40, 4, 4, c0),
            PixelCell(80, 40, 8, 4, c3),
            PixelCell(28, 44, 8, 4, c4),
            PixelCell(36, 44, 8, 4, c5),
            PixelCell(44, 44, 4, 4, c0),
            PixelCell(48, 44, 28, 4, c2),
            PixelCell(76, 44, 12, 4, c3),
            PixelCell(88, 44, 4, 4, c4),
            PixelCell(24, 48, 8, 4, c4),
            PixelCell(32, 48, 12, 4, c5),
            PixelCell(44, 48, 32, 4, c2),
            PixelCell(76, 48, 12, 4, c3),
            PixelCell(88, 48, 4, 4, c2),
            PixelCell(92, 48, 4, 4, c0),
            PixelCell(24, 52, 8, 4, c4),
            PixelCell(32, 52, 16, 4, c5),
            PixelCell(48, 52, 4, 4, c0),
            PixelCell(52, 52, 20, 4, c2),
            PixelCell(72, 52, 4, 4, c0),
            PixelCell(76, 52, 12, 4, c3),
            PixelCell(88, 52, 4, 4, c0)
        ])
        cells.append(contentsOf: [
PixelCell(92, 52, 4, 4, c2),
            PixelCell(96, 52, 4, 4, c0),
            PixelCell(28, 56, 8, 4, c4),
            PixelCell(36, 56, 16, 4, c5),
            PixelCell(52, 56, 4, 4, c0),
            PixelCell(56, 56, 24, 4, c2),
            PixelCell(80, 56, 4, 4, c3),
            PixelCell(84, 56, 12, 4, c2),
            PixelCell(96, 56, 4, 4, c0),
            PixelCell(100, 56, 4, 4, c4),
            PixelCell(32, 60, 4, 4, c4),
            PixelCell(36, 60, 20, 4, c5),
            PixelCell(56, 60, 44, 4, c2),
            PixelCell(100, 60, 4, 4, c4),
            PixelCell(28, 64, 8, 4, c4),
            PixelCell(36, 64, 20, 4, c5),
            PixelCell(56, 64, 8, 4, c2),
            PixelCell(64, 64, 4, 4, c5),
            PixelCell(68, 64, 32, 4, c2),
            PixelCell(100, 64, 4, 4, c4),
            PixelCell(24, 68, 4, 4, c4),
            PixelCell(28, 68, 20, 4, c5),
            PixelCell(48, 68, 4, 4, c0),
            PixelCell(52, 68, 12, 4, c2),
            PixelCell(64, 68, 4, 4, c5),
            PixelCell(68, 68, 28, 4, c2),
            PixelCell(96, 68, 4, 4, c3),
            PixelCell(100, 68, 8, 4, c4),
            PixelCell(20, 72, 8, 4, c4),
            PixelCell(28, 72, 20, 4, c5),
            PixelCell(48, 72, 24, 4, c2),
            PixelCell(72, 72, 8, 4, c5),
            PixelCell(80, 72, 12, 4, c2),
            PixelCell(92, 72, 4, 4, c0),
            PixelCell(96, 72, 4, 4, c3),
            PixelCell(100, 72, 8, 4, c4),
            PixelCell(20, 76, 4, 4, c4),
            PixelCell(24, 76, 28, 4, c5),
            PixelCell(52, 76, 4, 4, c0),
            PixelCell(56, 76, 32, 4, c2),
            PixelCell(88, 76, 4, 4, c0),
            PixelCell(92, 76, 4, 4, c3),
            PixelCell(96, 76, 4, 4, c5),
            PixelCell(100, 76, 4, 4, c4),
            PixelCell(20, 80, 4, 4, c4),
            PixelCell(24, 80, 4, 4, c5),
            PixelCell(28, 80, 4, 4, c3),
            PixelCell(32, 80, 24, 4, c5),
            PixelCell(56, 80, 4, 4, c0),
            PixelCell(60, 80, 4, 4, c2)
        ])
        cells.append(contentsOf: [
PixelCell(64, 80, 8, 4, c0),
            PixelCell(72, 80, 8, 4, c2),
            PixelCell(80, 80, 8, 4, c0),
            PixelCell(88, 80, 4, 4, c3),
            PixelCell(92, 80, 4, 4, c5),
            PixelCell(96, 80, 8, 4, c4),
            PixelCell(20, 84, 8, 4, c4),
            PixelCell(28, 84, 4, 4, c5),
            PixelCell(32, 84, 4, 4, c3),
            PixelCell(36, 84, 32, 4, c5),
            PixelCell(68, 84, 4, 4, c3),
            PixelCell(72, 84, 8, 4, c0),
            PixelCell(80, 84, 8, 4, c3),
            PixelCell(88, 84, 4, 4, c5),
            PixelCell(92, 84, 8, 4, c4),
            PixelCell(24, 88, 8, 4, c4),
            PixelCell(32, 88, 8, 4, c5),
            PixelCell(40, 88, 8, 4, c3),
            PixelCell(48, 88, 4, 4, c5),
            PixelCell(52, 88, 4, 4, c3),
            PixelCell(56, 88, 8, 4, c5),
            PixelCell(64, 88, 4, 4, c3),
            PixelCell(68, 88, 4, 4, c5),
            PixelCell(72, 88, 12, 4, c3),
            PixelCell(84, 88, 4, 4, c5),
            PixelCell(88, 88, 12, 4, c4),
            PixelCell(32, 92, 12, 4, c4),
            PixelCell(44, 92, 4, 4, c0),
            PixelCell(48, 92, 4, 4, c5),
            PixelCell(52, 92, 16, 4, c3),
            PixelCell(68, 92, 4, 4, c5),
            PixelCell(72, 92, 20, 4, c4),
            PixelCell(36, 96, 4, 4, c4),
            PixelCell(40, 96, 4, 4, c0),
            PixelCell(44, 96, 4, 4, c3),
            PixelCell(48, 96, 4, 4, c4),
            PixelCell(52, 96, 4, 4, c0),
            PixelCell(56, 96, 12, 4, c3),
            PixelCell(68, 96, 16, 4, c4),
            PixelCell(36, 100, 8, 4, c4),
            PixelCell(44, 100, 4, 4, c3),
            PixelCell(48, 100, 4, 4, c4),
            PixelCell(52, 100, 4, 4, c0),
            PixelCell(56, 100, 8, 4, c4),
            PixelCell(64, 100, 4, 4, c0),
            PixelCell(68, 100, 12, 4, c4),
            PixelCell(40, 104, 12, 4, c4),
            PixelCell(60, 104, 12, 4, c4)
        ])
        return cells
    }

    private func terminalBaseCells(kind: BuddyKind) -> [PixelCell] {
        let shell = (kind == .gemini || kind == .codex)
            ? Color(red: 0.08, green: 0.09, blue: 0.12)
            : Color(red: 0.09, green: 0.08, blue: 0.07)
        let rim = (kind == .gemini || kind == .codex)
            ? Color(red: 0.24, green: 0.27, blue: 0.34)
            : Color(red: 0.32, green: 0.24, blue: 0.20)
        let text = (kind == .gemini || kind == .codex)
            ? Color.white.opacity(0.45)
            : Color.white.opacity(0.42)

        return [
            PixelCell(8, 96, 112, 8, rim),
            PixelCell(8, 104, 112, 16, shell),
            PixelCell(8, 104, 112, 8, rim),
            PixelCell(24, 104, 8, 8, Color.red.opacity(0.82)),
            PixelCell(40, 104, 8, 8, Color.yellow.opacity(0.82)),
            PixelCell(56, 104, 8, 8, Color.green.opacity(0.82)),
            PixelCell(72, 112, 32, 8, text.opacity(0.36))
        ]
    }

    private func pixelGrid(size: CGFloat, cells: [PixelCell]) -> some View {
        let unit = size / 128

        return ZStack(alignment: .topLeading) {
            ForEach(cells.indices, id: \.self) { index in
                let cell = cells[index]
                Rectangle()
                    .fill(cell.color)
                    .frame(width: unit * CGFloat(cell.width), height: unit * CGFloat(cell.height))
                    .offset(x: unit * CGFloat(cell.x), y: unit * CGFloat(cell.y))
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

}

// MARK: - Components

struct StatusBadge: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 7, weight: .black))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct TagView: View {
    let icon: String?
    let text: String
    var color: Color = .white.opacity(0.15)
    
    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color)
        .clipShape(Capsule())
    }
}

struct AgentRequestBadge: View {
    let kind: BuddyKind
    let tool: ToolInfo
    let isActive: Bool
    var size: CGFloat = 48

    private var mascotSize: CGFloat { size * 0.88 }
    private var requestBadgeSize: CGFloat { size * 0.38 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(kind.accentColor.opacity(0.18))
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(kind.accentColor.opacity(0.28), lineWidth: 1)
                )

            CLIBuddyView(isActive: isActive, kind: kind)
                .frame(width: mascotSize, height: mascotSize)
                .offset(x: -size * 0.04, y: size * 0.03)

            Circle()
                .fill(Color.black.opacity(0.92))
                .frame(width: requestBadgeSize, height: requestBadgeSize)
                .overlay(
                    Circle()
                        .fill(tool.color.opacity(0.22))
                )
                .overlay(
                    Image(systemName: tool.icon)
                        .font(.system(size: size * 0.18, weight: .black))
                        .foregroundColor(tool.color)
                )
                .overlay(
                    Circle()
                        .stroke(Color.black, lineWidth: max(1.5, size * 0.04))
                )
                .offset(x: size * 0.05, y: size * 0.04)
        }
        .frame(width: size + size * 0.08, height: size + size * 0.08)
        .accessibilityLabel("\(kind.accessibilityName) \(tool.label)")
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let session: ActiveSession
    let isCurrent: Bool
    
    @State private var timeAgo: String = ""
    private var tool: ToolInfo { toolInfo(for: session.lastToolName) }
    private var statusLabel: String? {
        switch session.status {
        case .pending:
            return "Pending"
        case .timeoutBypassed:
            return "Bypassed"
        case .idle:
            return nil
        }
    }
    private var statusColor: Color {
        switch session.status {
        case .pending:
            return .orange
        case .timeoutBypassed:
            return Color(red: 0.2, green: 0.8, blue: 0.9)
        case .idle:
            return .white.opacity(0.3)
        }
    }
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 8) {
            Button(action: { AppState.shared.selectedSessionId = session.id }) {
                HStack(spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        AgentRequestBadge(
                            kind: session.agentKind,
                            tool: tool,
                            isActive: session.isPending,
                            size: 32
                        )

                        if session.isPending {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.black, lineWidth: 2))
                                .offset(x: 4, y: -4)
                        }
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(session.terminalTitle)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Spacer()

                            Text(timeAgo)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        
                        HStack(spacing: 6) {
                            Text(String(session.id.prefix(8)))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                            
                            Text("•")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.2))
                            
                            Text(session.lastEventName)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(tool.color.opacity(0.8))
                                .lineLimit(1)

                            if let statusLabel = statusLabel {
                                Text(statusLabel)
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundColor(statusColor)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Button(action: { AppState.shared.focusTerminal(for: session.id) }) {
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Focus terminal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? tool.color.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onAppear { updateTimeAgo() }
        .onReceive(timer) { _ in updateTimeAgo() }
    }

    private func updateTimeAgo() {
        let diff = Int(Date().timeIntervalSince(session.lastActiveAt))
        if diff < 5 { timeAgo = "Just now" }
        else if diff < 60 { timeAgo = "\(diff)s ago" }
        else { timeAgo = "\(diff/60)m ago" }
    }
}

// MARK: - Notch View

struct NotchView: View {
    @ObservedObject var state = AppState.shared
    @State private var buddyPulse = false
    @State private var leftMascot: BuddyKind = .claudeCode
    @State private var rightMascot: BuddyKind = .gemini

    private var tool: ToolInfo { toolInfo(for: state.currentToolName) }
    private var isActionAreaShowing: Bool {
        state.pendingCount > 0 || (state.isNotchExpanded && state.isExpandingFromRequest && !state.currentMessage.isEmpty)
    }
    private var headerTitle: String { isActionAreaShowing && !state.currentToolName.isEmpty ? tool.label : "Sessions" }
    private var displayedSessionId: String {
        state.currentSessionId.isEmpty ? (state.selectedSessionId ?? "") : state.currentSessionId
    }
    private var notchSize: NSSize {
        state.isNotchExpanded ? expandedNotchSize : collapsedNotchSize
    }

    private var currentBuddyKind: BuddyKind {
        let session = state.activeSessions.first { $0.id == state.currentSessionId }
            ?? state.activeSessions.first { $0.id == state.selectedSessionId }
            ?? state.activeSessions.first
        return session?.agentKind ?? BuddyKind(from: "")
    }

    private var notchExpansionAnimation: Animation {
        state.isNotchExpanded
            ? .spring(response: 0.35, dampingFraction: 0.75)
            : .easeOut(duration: 0.28)
    }

    var body: some View {
        HStack {
            Spacer()
            
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    // Background
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: state.isNotchExpanded ? 24 : 14,
                        bottomTrailingRadius: state.isNotchExpanded ? 24 : 14,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(Color.black)
                    .frame(
                        width: notchSize.width,
                        height: notchSize.height,
                        alignment: .top
                    )

                    VStack(alignment: .center, spacing: 0) {
                        if state.isNotchExpanded {
                            expandedContent
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        } else {
                            collapsedContent
                                .transition(.opacity)
                        }
                        
                        if !state.isNotchExpanded {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(
                        width: notchSize.width,
                        height: notchSize.height,
                        alignment: .top
                    )
                }
            }
            .frame(
                width: notchSize.width,
                height: notchSize.height,
                alignment: .top
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if !state.isNotchExpanded {
                    (NSApp.windows.first { $0.windowController is NotchWindowController }?.windowController as? NotchWindowController)?.expandFromCollapsedWindow()
                }
            }
            .animation(notchExpansionAnimation, value: state.isNotchExpanded)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                buddyPulse = true
            }
            
            // Randomly select 2 mascots
            if let randomLeft = BuddyKind.allCases.randomElement() {
                leftMascot = randomLeft
            }
            if let randomRight = BuddyKind.allCases.randomElement() {
                rightMascot = randomRight
            }
            
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: Collapsed

    var collapsedContent: some View {
        ZStack {
            Text("DevIsland")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 11, weight: .semibold))

            HStack {
                CLIBuddyView(
                    isActive: buddyPulse,
                    kind: leftMascot
                )
                .frame(width: 24, height: 24)
                .offset(x: -6, y: 4)

                Spacer(minLength: 0)

                CLIBuddyView(
                    isActive: buddyPulse, 
                    kind: rightMascot
                )
                .frame(width: 24, height: 24)
                .offset(x: 6, y: 4)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Expanded

    var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────
            HStack(spacing: 16) {
                AgentRequestBadge(
                    kind: currentBuddyKind,
                    tool: tool,
                    isActive: buddyPulse,
                    size: 48
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(headerTitle)
                            .font(.system(size: 18, weight: .black))
                            .foregroundColor(.white)
                        
                        StatusBadge(
                            text: state.pendingCount > 0 ? "Approval Required" : (isActionAreaShowing ? "Notification" : "Monitoring"),
                            color: state.pendingCount > 0 ? .orange : (isActionAreaShowing ? .blue.opacity(0.7) : .green.opacity(0.6))
                        )
                    }
                    
                    if !displayedSessionId.isEmpty {
                        HStack(spacing: 6) {
                            TagView(icon: "terminal.fill", text: String(displayedSessionId.prefix(8)))
                            TagView(icon: "macwindow", text: state.activeSessions.first(where: { $0.id == displayedSessionId })?.terminalTitle ?? "Unknown")
                            if state.pendingCount > 1 {
                                TagView(icon: "list.bullet", text: "\(state.pendingCount) tasks queued", color: .orange.opacity(0.2))
                            }
                        }
                    } else if state.pendingCount > 1 {
                        HStack(spacing: 6) {
                            TagView(icon: "list.bullet", text: "\(state.pendingCount) tasks queued", color: .orange.opacity(0.2))
                        }
                    }
                }

                Spacer()

                if !displayedSessionId.isEmpty {
                    Button {
                        state.focusTerminal(for: displayedSessionId)
                    } label: {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Focus terminal")
                }

                // Close Button
                Button {
                    state.dismissCurrentRequest()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.2))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            // ── Main Dashboard ──────────────────────────
            if isActionAreaShowing {
                approvalContent
            } else {
                sessionsContent
            }
        }
    }

    private var approvalContent: some View {
        HStack(alignment: .top, spacing: 0) {
            // LEFT: Focus Area
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(state.hasResponseHandler ? "ACTIVE ACTION" : "NOTIFICATION")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(.white.opacity(0.3))
                        
                        if !state.currentToolName.isEmpty {
                            let risk = ToolKnowledge.risk(for: state.currentToolName)
                            HStack(spacing: 4) {
                                Image(systemName: risk.icon)
                                Text(risk.rawValue.uppercased())
                            }
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(risk.color.opacity(0.2))
                            .foregroundColor(risk.color)
                            .clipShape(Capsule())
                        }
                        
                        Spacer()
                        Text(state.currentEventName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(tool.color)
                    }
                    .padding(.horizontal, 20)
                    
                    ScrollView {
                        Text(state.currentMessage)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: 120)
                }
                
                Spacer()
                
                VStack(spacing: 12) {
                    if state.hasResponseHandler {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.07))
                                Capsule()
                                    .fill(
                                        LinearGradient(colors: [progressColor.opacity(0.8), progressColor], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .frame(width: geo.size.width * state.timeoutProgress)
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 20)
                    }
                    
                    HStack(spacing: 12) {
                        if state.hasResponseHandler {
                            Button(action: { state.focusTerminal() }) {
                                HStack {
                                    Image(systemName: "arrow.up.forward.app.fill")
                                    Text("Focus")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 92, height: 38)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(.white.opacity(0.82))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Focus terminal")

                            Button(action: { state.deny() }) {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Deny Request")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 1) {
                                Button(action: { state.approve() }) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Approve")
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(tool.color.opacity(0.15))
                                    .foregroundColor(tool.color)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                // [UI/UX] macOS 기본 Menu 스타일 버그 우회용 ZStack 트릭
                                // macOS의 borderlessButton Menu는 커스텀 배경색(.background)을 무시하거나 클리핑하는 버그가 있습니다.
                                // 이를 해결하기 위해 배경색과 아이콘을 먼저 렌더링하고, 실제 기능하는 Menu를 그 위에 겹쳐(오버레이) 구현합니다.
                                ZStack {
                                    tool.color.opacity(0.2)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(tool.color)
                                        
                                    Menu {
                                        Button("Auto-Approve for this Session") { state.approve(globalAlways: false, sessionAlways: true) }
                                        Button("Always Auto-Approve (Global)") { state.approve(globalAlways: true, sessionAlways: false) }
                                    } label: {
                                        // Text("")를 사용하면 크기가 0x0이 되어 클릭 히트 박스가 생성되지 않습니다.
                                        // 눈에 보이지 않지만 프레임을 꽉 채우는 투명한 도형으로 빈 껍데기를 만들어 클릭 이벤트를 낚아챕니다.
                                        Color.black.opacity(0.001)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .contentShape(Rectangle())
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(width: 32, height: 38)
                            }
                            .frame(height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Button(action: { state.focusTerminal() }) {
                                HStack {
                                    Image(systemName: "arrow.up.forward.app.fill")
                                    Text("Focus Terminal")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(.white.opacity(0.82))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Focus terminal")

                            Button(action: { state.isNotchExpanded = false }) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Dismiss")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 20)
            }
            .frame(width: state.activeSessions.isEmpty ? 680 : 420)
            
            if !state.activeSessions.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .padding(.vertical, 20)
                
                sessionList
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 12)
    }

    private var sessionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AGENT SESSIONS")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.white.opacity(0.3))
                .padding(.horizontal, 20)
            
            if state.activeSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.1))
                    Text("Listening for AI Agents...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionList
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(state.activeSessions) { session in
                    SessionRowView(
                        session: session,
                        isCurrent: session.id == displayedSessionId
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    private var progressColor: Color {
        if state.timeoutProgress > 0.5  { return .green }
        if state.timeoutProgress > 0.25 { return .orange }
        return .red
    }
}
