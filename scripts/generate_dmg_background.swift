import AppKit
import CoreGraphics

let width = 1200
let height = 800
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bytesPerPixel = 4
let bytesPerRow = bytesPerPixel * width
let bitsPerComponent = 8

guard let context = CGContext(data: nil,
                              width: width,
                              height: height,
                              bitsPerComponent: bitsPerComponent,
                              bytesPerRow: bytesPerRow,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Failed to create context")
}

let w = CGFloat(width)
let h = CGFloat(height)

// 1. Draw Background Gradient (Light Grey/Blue)
let colors = [
    NSColor(white: 0.95, alpha: 1.0).cgColor,
    NSColor(red: 0.90, green: 0.94, blue: 0.98, alpha: 1.0).cgColor
] as CFArray
let locations: [CGFloat] = [0.0, 1.0]
guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
    fatalError("Failed to create gradient")
}

context.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: h),
                           end: CGPoint(x: w, y: 0),
                           options: [])

// 2. Draw a subtle "Island" shape at the bottom (Light Teal/Blue)
context.saveGState()
let islandPath = CGMutablePath()
islandPath.move(to: CGPoint(x: 0, y: 120))
islandPath.addCurve(to: CGPoint(x: w, y: 120),
                    control1: CGPoint(x: w * 0.3, y: 180),
                    control2: CGPoint(x: w * 0.7, y: 40))
islandPath.addLine(to: CGPoint(x: w, y: 0))
islandPath.addLine(to: CGPoint(x: 0, y: 0))
islandPath.closeSubpath()

context.addPath(islandPath)
context.setFillColor(NSColor(red: 0.0, green: 0.4, blue: 0.7, alpha: 0.08).cgColor)
context.fillPath()

// Add a very subtle stroke to the curve to define it better
context.addPath(islandPath)
context.setStrokeColor(NSColor(red: 0.0, green: 0.4, blue: 0.7, alpha: 0.1).cgColor)
context.setLineWidth(1)
context.strokePath()

context.restoreGState()

// 3. Draw the Arrow (Darker Grey/Blue)
context.saveGState()
let arrowColor = NSColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.4).cgColor
context.setStrokeColor(arrowColor)
context.setLineWidth(12)
context.setLineCap(.round)
context.setLineJoin(.round)

let centerX: CGFloat = 600
let centerY: CGFloat = 400 
let arrowLength: CGFloat = 160

// Arrow shaft
context.move(to: CGPoint(x: centerX - arrowLength/2, y: centerY))
context.addLine(to: CGPoint(x: centerX + arrowLength/2, y: centerY))

// Arrow head
context.move(to: CGPoint(x: centerX + arrowLength/2 - 35, y: centerY - 35))
context.addLine(to: CGPoint(x: centerX + arrowLength/2, y: centerY))
context.addLine(to: CGPoint(x: centerX + arrowLength/2 - 35, y: centerY + 35))

context.strokePath()

// 4. Text: Drag to install (Dark Grey)
let text = "Drag to install"
let font = NSFont.systemFont(ofSize: 42, weight: .semibold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.6)
]

let textSize = text.size(withAttributes: attributes)
let textRect = CGRect(x: centerX - textSize.width / 2,
                      y: centerY + 80,
                      width: textSize.width,
                      height: textSize.height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
text.draw(in: textRect, withAttributes: attributes)
NSGraphicsContext.restoreGraphicsState()

context.restoreGState()

// 5. Save to file
guard let image = context.makeImage() else { fatalError("Failed to make image") }

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_background.png"
let url = URL(fileURLWithPath: outputPath)
let baseName = url.deletingPathExtension().lastPathComponent
let dir = url.deletingLastPathComponent()

// Save @2x version (1200x800)
let bitmapRep2x = NSBitmapImageRep(cgImage: image)
bitmapRep2x.size = NSSize(width: width / 2, height: height / 2) // 600x400 points
if let data2x = bitmapRep2x.representation(using: .png, properties: [:]) {
    let url2x = dir.appendingPathComponent("\(baseName)@2x.png")
    do {
        try data2x.write(to: url2x)
        print("Background saved to \(url2x.path) (1200x800, 144 DPI)")
    } catch {
        fatalError("Failed to write @2x image: \(error)")
    }
}

// Save standard version (600x400)
let standardSize = NSSize(width: width / 2, height: height / 2)
let standardImage = NSImage(size: standardSize)
standardImage.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
let standardRect = NSRect(origin: .zero, size: standardSize)
let sourceRect = NSRect(x: 0, y: 0, width: width, height: height)
NSImage(cgImage: image, size: NSSize(width: width, height: height))
    .draw(in: standardRect, from: sourceRect, operation: .copy, fraction: 1.0)
standardImage.unlockFocus()

if let tiffData = standardImage.tiffRepresentation,
   let bitmapRep = NSBitmapImageRep(data: tiffData),
   let data = bitmapRep.representation(using: .png, properties: [:]) {
    do {
        try data.write(to: url)
        print("Background saved to \(url.path) (600x400, 72 DPI)")
    } catch {
        fatalError("Failed to write standard image: \(error)")
    }
}
