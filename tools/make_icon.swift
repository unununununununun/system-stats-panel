// Liquid Glass–style app icon (gradient squircle + gloss + activity bars).
// Usage: make_icon <pixel_size> <output.png>
import AppKit

let size = Int(CommandLine.arguments[1])!
let outPath = CommandLine.arguments[2]
let s = CGFloat(size)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: s, height: s).fill()

let inset = s * 0.05
let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
let radius = s * 0.224
let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

// Depth shadow under the glass tile.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = s * 0.06
shadow.shadowOffset = NSSize(width: 0, height: -s * 0.025)
shadow.set()
NSColor.black.withAlphaComponent(0.15).setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

// Base mesh gradient (liquid glass depth).
squircle.addClip()
let base = NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.34, green: 0.22, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.52, blue: 0.92, alpha: 1),
    NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.72, alpha: 1),
], atLocations: [0, 0.38, 0.72, 1], colorSpace: .deviceRGB)!
base.draw(in: body, angle: -55)

// Frosted highlight — upper lens flare.
let glossRect = NSRect(x: body.minX + body.width * 0.08,
                       y: body.midY,
                       width: body.width * 0.84,
                       height: body.height * 0.46)
let glossPath = NSBezierPath(ovalIn: glossRect)
let gloss = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.55),
    NSColor.white.withAlphaComponent(0.12),
    NSColor.clear,
])!
gloss.draw(in: glossPath, angle: 90)

// Inner edge light.
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let strokePath = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.008, dy: s * 0.008),
                              xRadius: radius * 0.98, yRadius: radius * 0.98)
strokePath.lineWidth = max(1, s * 0.02)
NSColor.white.withAlphaComponent(0.42).setStroke()
strokePath.stroke()

// Chart glyph — three glass bars + baseline.
func drawBars() {
    let centerX = s * 0.5
    let baseY = s * 0.36
    let barW = s * 0.09
    let gap = s * 0.06
    let heights: [CGFloat] = [0.30, 0.46, 0.34]
    let colors: [NSColor] = [
        NSColor(calibratedRed: 0.45, green: 0.88, blue: 1.0, alpha: 0.95),
        NSColor(calibratedRed: 0.62, green: 0.55, blue: 1.0, alpha: 0.95),
        NSColor(calibratedRed: 0.38, green: 0.95, blue: 0.82, alpha: 0.95),
    ]
    for (i, hFrac) in heights.enumerated() {
        let x = centerX - barW - gap + CGFloat(i) * (barW + gap)
        let h = s * hFrac
        let bar = NSRect(x: x, y: baseY, width: barW, height: h)
        let p = NSBezierPath(roundedRect: bar, xRadius: barW * 0.28, yRadius: barW * 0.28)
        colors[i].setFill()
        p.fill()
        let shine = NSBezierPath(roundedRect: bar.insetBy(dx: barW * 0.18, dy: h * 0.55),
                                 xRadius: barW * 0.15, yRadius: barW * 0.15)
        NSColor.white.withAlphaComponent(0.35).setFill()
        shine.fill()
    }
    let line = NSBezierPath()
    line.lineWidth = max(1, s * 0.018)
    line.move(to: NSPoint(x: s * 0.28, y: baseY - s * 0.04))
    line.line(to: NSPoint(x: s * 0.72, y: baseY - s * 0.04))
    NSColor.white.withAlphaComponent(0.55).setStroke()
    line.stroke()
}

drawBars()

// SF Symbol activity arc on top.
if let symbol = NSImage(systemSymbolName: "waveform.path.ecg",
                        accessibilityDescription: nil) {
    let symSize = s * 0.36
    let symRect = NSRect(x: (s - symSize) / 2, y: s * 0.52, width: symSize, height: symSize * 0.55)
    let cfg = NSImage.SymbolConfiguration(pointSize: symSize * 0.55, weight: .semibold)
        .applying(.init(paletteColors: [
            NSColor.white,
            NSColor(calibratedRed: 0.75, green: 0.92, blue: 1.0, alpha: 1),
        ]))
    let img = symbol.withSymbolConfiguration(cfg) ?? symbol
    img.draw(in: symRect)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))