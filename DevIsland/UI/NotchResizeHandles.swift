import AppKit
import SwiftUI

// MARK: - Resize Handle (NSView-backed, 스크린 절대좌표 사용으로 창 이동에 의한 lag 제거)

struct ResizeHandle: NSViewRepresentable {
    @Binding var liveHeight: Double?

    func makeNSView(context: Context) -> ResizeHandleNSView {
        ResizeHandleNSView(axis: .vertical, liveValue: $liveHeight)
    }
    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.liveValue = $liveHeight
    }
}

struct RightResizeHandle: NSViewRepresentable {
    @Binding var liveWidth: Double?

    func makeNSView(context: Context) -> ResizeHandleNSView {
        ResizeHandleNSView(axis: .horizontal, liveValue: $liveWidth)
    }
    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.liveValue = $liveWidth
    }
}

// MARK: - ResizeHandleNSView

final class ResizeHandleNSView: NSView {
    enum Axis { case vertical, horizontal }

    var liveValue: Binding<Double?>

    private let axis: Axis
    private var isTracking = false
    private var dragStartValue: Double = 0
    private var startScreenPos: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    private var minValue: Double { axis == .vertical ? 240 : 610 }
    private var maxValue: Double { axis == .vertical ? 720 : 1200 }

    init(axis: Axis, liveValue: Binding<Double?>) {
        self.axis = axis
        self.liveValue = liveValue
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        axis == .vertical
            ? NSSize(width: NSView.noIntrinsicMetric, height: 12)
            : NSSize(width: 12, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.2).setFill()
        let (w, h): (CGFloat, CGFloat) = axis == .vertical ? (36, 4) : (4, 36)
        let rect = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w, height: h
        )
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        (axis == .vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
    }
    override func mouseExited(with event: NSEvent) {
        if !isTracking { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        let settings = SettingsStore.shared.settings
        dragStartValue = axis == .vertical ? settings.expandedNotchHeight : settings.expandedNotchWidth
        startScreenPos = axis == .vertical ? NSEvent.mouseLocation.y : NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        let currentPos = axis == .vertical ? NSEvent.mouseLocation.y : NSEvent.mouseLocation.x
        let delta = currentPos - startScreenPos
        let settings = SettingsStore.shared.settings

        let clamped: Double
        let size: NSSize
        if axis == .vertical {
            // 아래로 드래그 = y 감소 = delta 음수 → 높이 증가
            clamped = min(max(dragStartValue - delta, minValue), maxValue)
            size = NSSize(width: settings.expandedNotchWidth, height: clamped)
        } else {
            // 오른쪽으로 드래그 = x 증가 = delta 양수 → 패널 중앙 고정이므로 ×2
            clamped = min(max(dragStartValue + delta * 2, minValue), maxValue)
            size = NSSize(width: clamped, height: settings.expandedNotchHeight)
        }
        liveValue.wrappedValue = clamped
        NotchWindowController.current?.updateLiveExpandedFrame(size: size)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        if let final = liveValue.wrappedValue {
            if axis == .vertical {
                SettingsStore.shared.settings.expandedNotchHeight = final
            } else {
                SettingsStore.shared.settings.expandedNotchWidth = final
            }
        }
        liveValue.wrappedValue = nil
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - NSCursor helpers

private extension NSCursor {
    /// macOS 창 우하단 모서리 리사이즈 커서 (↖↘). 공개 API 부재로 private selector 사용, 실패 시 crosshair 폴백.
    static var resizeNorthWestSouthEast: NSCursor {
        let sel = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        // perform(_:)은 셀렉터 미응답 시 nil이 아니라 unrecognized selector NSException으로
        // 크래시하므로, 옵셔널/타입 폴백에 앞서 클래스 레벨 responds(to:)로 먼저 가드한다.
        guard NSCursor.responds(to: sel) else { return .crosshair }
        return (NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor) ?? .crosshair
    }
}

// MARK: - Corner Resize Handle

struct CornerResizeHandle: NSViewRepresentable {
    @Binding var liveHeight: Double?
    @Binding var liveWidth: Double?

    func makeNSView(context: Context) -> CornerResizeHandleNSView {
        CornerResizeHandleNSView(liveHeight: $liveHeight, liveWidth: $liveWidth)
    }
    func updateNSView(_ nsView: CornerResizeHandleNSView, context: Context) {
        nsView.liveHeight = $liveHeight
        nsView.liveWidth = $liveWidth
    }
}

final class CornerResizeHandleNSView: NSView {
    var liveHeight: Binding<Double?>
    var liveWidth: Binding<Double?>

    private var isTracking = false
    private var dragStartHeight: Double = 0
    private var dragStartWidth: Double = 0
    private var startScreenX: CGFloat = 0
    private var startScreenY: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    private let minHeight: Double = 240, maxHeight: Double = 720
    private let minWidth: Double = 610, maxWidth: Double = 1200

    init(liveHeight: Binding<Double?>, liveWidth: Binding<Double?>) {
        self.liveHeight = liveHeight
        self.liveWidth = liveWidth
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // 모서리 그립: 우하단 방향 대각선 3줄
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for i in 0..<3 {
            let offset = CGFloat(i * 5 + 4)
            path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + offset))
        }
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.resizeNorthWestSouthEast.set() }
    override func mouseExited(with event: NSEvent) {
        if !isTracking { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        let settings = SettingsStore.shared.settings
        dragStartHeight = settings.expandedNotchHeight
        dragStartWidth = settings.expandedNotchWidth
        startScreenX = NSEvent.mouseLocation.x
        startScreenY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        let dx = NSEvent.mouseLocation.x - startScreenX
        let dy = NSEvent.mouseLocation.y - startScreenY
        // 아래로 드래그 = y 감소 → 높이 증가 / 오른쪽 드래그 = x 증가 → 너비 증가 (중앙 고정 ×2)
        let newHeight = min(max(dragStartHeight - dy, minHeight), maxHeight)
        let newWidth  = min(max(dragStartWidth + dx * 2, minWidth), maxWidth)
        liveHeight.wrappedValue = newHeight
        liveWidth.wrappedValue  = newWidth
        NotchWindowController.current?.updateLiveExpandedFrame(size: NSSize(width: newWidth, height: newHeight))
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        if let h = liveHeight.wrappedValue { SettingsStore.shared.settings.expandedNotchHeight = h }
        if let w = liveWidth.wrappedValue  { SettingsStore.shared.settings.expandedNotchWidth  = w }
        liveHeight.wrappedValue = nil
        liveWidth.wrappedValue  = nil
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
