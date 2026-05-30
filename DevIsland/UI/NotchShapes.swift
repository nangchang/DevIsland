import SwiftUI

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

// MARK: - Notch Shape

struct NotchShape: Shape {
    var cornerRadius: CGFloat
    var topFilletRadius: CGFloat
    var shapeStyle: NotchShapeStyle = .classic
    var topGap: CGFloat = 0

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        if shapeStyle == .dynamicIsland {
            return dynamicIslandPath(in: rect)
        }

        var path = Path()

        let w = rect.width
        let h = rect.height
        let r = cornerRadius
        let tr = topFilletRadius

        // Top Left Fillet
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: tr, y: tr), control: CGPoint(x: tr, y: 0))

        // Left Edge
        path.addLine(to: CGPoint(x: tr, y: h - r))

        // Bottom Left Corner
        path.addQuadCurve(to: CGPoint(x: tr + r, y: h), control: CGPoint(x: tr, y: h))

        // Bottom Edge
        path.addLine(to: CGPoint(x: w - tr - r, y: h))

        // Bottom Right Corner
        path.addQuadCurve(to: CGPoint(x: w - tr, y: h - r), control: CGPoint(x: w - tr, y: h))

        // Right Edge
        path.addLine(to: CGPoint(x: w - tr, y: tr))

        // Top Right Fillet
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - tr, y: 0))

        path.closeSubpath()
        return path
    }

    // 다이나믹 아일랜드: 상단에 topGap만큼 여백을 두고 모든 코너가 동일하게 라운드된 직사각형
    private func dynamicIslandPath(in rect: CGRect) -> Path {
        var path = Path()

        let w = rect.width
        let h = rect.height
        let r = min(cornerRadius, (h - topGap) / 2, w / 2)
        let top = topGap

        path.move(to: CGPoint(x: r, y: top))
        path.addLine(to: CGPoint(x: w - r, y: top))
        path.addQuadCurve(to: CGPoint(x: w, y: top + r), control: CGPoint(x: w, y: top))
        path.addLine(to: CGPoint(x: w, y: h - r))
        path.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: r, y: h))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: top + r))
        path.addQuadCurve(to: CGPoint(x: r, y: top), control: CGPoint(x: 0, y: top))
        path.closeSubpath()

        return path
    }
}
