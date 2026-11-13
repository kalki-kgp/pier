// Renders Assets/AppIcon.icns: three linked nodes on a blue-to-indigo squircle tile.
// Usage: swift Scripts/make-icon.swift   (run from app/)
import AppKit

let canvas: CGFloat = 1024, tile: CGFloat = 824, margin = (canvas - tile) / 2

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(px) / canvas
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    let rect = NSRect(x: margin, y: margin, width: tile, height: tile)
    let shape = NSBezierPath(roundedRect: rect, xRadius: tile * 0.225, yRadius: tile * 0.225)
    NSGradient(colors: [NSColor(red: 0.12, green: 0.52, blue: 1.0, alpha: 1),
                        NSColor(red: 0.35, green: 0.30, blue: 0.86, alpha: 1)])!
        .draw(in: shape, angle: -90)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    shape.lineWidth = 3
    shape.stroke()

    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "point.3.filled.connected.trianglepath.dotted",
                            accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (canvas - s.width) / 2, y: (canvas - s.height) / 2, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(atPath: "Assets", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Assets/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
try! render(1024).write(to: URL(fileURLWithPath: "Assets/AppIcon.png"))
print("Assets/AppIcon.icns")
