// Generates Resources/AppIcon.icns — a gradient rounded-rect with a tilted paperplane.
// Run: swift scripts/make_icon.swift
import AppKit

let canvas: CGFloat = 1024

func drawIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()

    // Big Sur-style rounded rect with margin
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    // Drop shadow
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 36
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Gradient: deep indigo -> sky blue, diagonal
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.85, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.96, alpha: 1),
    ])!
    gradient.draw(in: path, angle: 55)

    // Subtle top sheen
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    sheen.draw(in: path, angle: -90)

    // Paperplane symbol, white, tilted
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: canvas / 2, y: canvas / 2)
        ctx.rotate(by: -10 * .pi / 180)
        let scale = 500 / max(tinted.size.width, tinted.size.height)
        let w = tinted.size.width * scale, h = tinted.size.height * scale
        // paperplane glyph leans right; nudge left to look centered
        tinted.draw(in: NSRect(x: -w / 2 - 14, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    image.unlockFocus()
    return image
}

let icon = drawIcon()
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "scripts/Sendling.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! rep.representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}

try? fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
