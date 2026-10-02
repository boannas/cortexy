// Draws the app icon and writes Resources/AppIcon.icns.
//   swiftc tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024 // design on a 1024 grid

    // macOS icon body: 824 pt rounded square centered on the 1024 canvas
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.40, green: 0.47, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.20, green: 0.24, blue: 0.80, alpha: 1)])!
        .draw(in: body, angle: -90)

    // faint "desktop window" on the left
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(roundedRect: NSRect(x: 190 * u, y: 300 * u, width: 330 * u, height: 420 * u), xRadius: 36 * u, yRadius: 36 * u).fill()

    // the side panel: frosted card on the right edge with a checklist
    let panel = NSRect(x: 560 * u, y: 190 * u, width: 280 * u, height: 644 * u)
    NSColor.white.withAlphaComponent(0.94).setFill()
    NSBezierPath(roundedRect: panel, xRadius: 56 * u, yRadius: 56 * u).fill()
    let accent = NSColor(srgbRed: 0.29, green: 0.35, blue: 0.95, alpha: 1)
    for (i, done) in [true, true, false, false].enumerated() {
        let y = (700 - CGFloat(i) * 120) * u
        let box = NSRect(x: 605 * u, y: y, width: 56 * u, height: 56 * u)
        let boxPath = NSBezierPath(roundedRect: box, xRadius: 14 * u, yRadius: 14 * u)
        if done {
            accent.setFill()
            boxPath.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 14 * u, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 25 * u, y: box.minY + 16 * u))
            check.line(to: NSPoint(x: box.maxX - 12 * u, y: box.maxY - 14 * u))
            check.lineWidth = 8 * u
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            boxPath.lineWidth = 7 * u
            accent.withAlphaComponent(0.55).setStroke()
            boxPath.stroke()
        }
        NSColor(white: 0.25, alpha: done ? 0.28 : 0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: 685 * u, y: y + 18 * u, width: (done ? 110 : 130) * u, height: 20 * u),
                     xRadius: 10 * u, yRadius: 10 * u).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
