// Renders an emoji into a macOS .iconset (all standard sizes) as transparent PNGs.
// Usage: swift scripts/render_emoji_icon.swift "👽" /path/to/AppIcon.iconset
import AppKit

let args = CommandLine.arguments
let emoji = args.count > 1 ? args[1] : "👽"
let outDir = args.count > 2 ? args[2] : "AppIcon.iconset"

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in specs {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { continue }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let fontSize = CGFloat(px) * 0.80
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
    let glyph = emoji as NSString
    let bounds = glyph.size(withAttributes: attributes)
    let origin = NSPoint(x: (CGFloat(px) - bounds.width) / 2,
                         y: (CGFloat(px) - bounds.height) / 2)
    glyph.draw(at: origin, withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}
