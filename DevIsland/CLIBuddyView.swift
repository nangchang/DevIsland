import SwiftUI

// MARK: - Buddy Kind

enum BuddyKind: String, CaseIterable, Identifiable {
    case gemini
    case codex
    case claudeCode
    case island

    var id: String { rawValue }

    static let defaultRandomCases: [BuddyKind] = [.gemini, .codex, .claudeCode]
    static let selectableCases: [BuddyKind] = [.gemini, .codex, .claudeCode, .island]

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

    var label: String { accessibilityName }
}

// MARK: - Pixel Cell

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

// MARK: - CLI Buddy View

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
                    .scaleEffect(x: isFlipped ? -1 : 1)
            case .gemini:
                pixelGrid(size: size, cells: terminalBaseCells(kind: .gemini))
                pixelGrid(size: size, cells: geminiBodyCells())
                    .scaleEffect(x: isFlipped ? -1 : 1)
            case .codex:
                pixelGrid(size: size, cells: terminalBaseCells(kind: .codex))
                pixelGrid(size: size, cells: codexBodyCells())
                    .scaleEffect(x: isFlipped ? -1 : 1)
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

        return mirroredHorizontally(cells)
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

    private func mirroredHorizontally(_ cells: [PixelCell]) -> [PixelCell] {
        cells.map { cell in
            PixelCell(128 - cell.x - cell.width, cell.y, cell.width, cell.height, cell.color)
        }
    }

    private func pixelGrid(size: CGFloat, cells: [PixelCell]) -> some View {
        let unit = size / 128

        return Canvas { context, _ in
            for cell in cells {
                let rect = CGRect(
                    x: unit * CGFloat(cell.x),
                    y: unit * CGFloat(cell.y),
                    width: unit * CGFloat(cell.width),
                    height: unit * CGFloat(cell.height)
                )
                context.fill(Path(rect), with: .color(cell.color))
            }
        }
        .frame(width: size, height: size)
    }
}
