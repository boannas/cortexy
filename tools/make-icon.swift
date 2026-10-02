// Builds the app icon from the artwork: Resources/AppIcon-art.png (the icon's square with its rim, edge to
// edge, no background around it; any size, though 1024 px or more looks best) → Resources/AppIcon.icns and
// Resources/AppIcon.png, on the macOS icon grid (an 824 pt body on a 1024 canvas, rounded corners, a shadow).
//   swiftc tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
guard let art = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon-art.png")) else {
    fatalError("Resources/AppIcon-art.png is missing")
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let u = s / 1024
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    // The artwork's own corners are this round (measured on its rim); a hair inside, so none of what was around it shows.
    let squircle = NSBezierPath(roundedRect: body.insetBy(dx: 2 * u, dy: 2 * u), xRadius: 178 * u, yRadius: 178 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    squircle.addClip()
    art.draw(in: body, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

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
