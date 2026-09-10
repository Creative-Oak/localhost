// Generates Resources/AppIcon.icns.
//
// A placeholder, and deliberately a simple one: a socket slot with a live
// indicator beside it. Anything text-based ( ":3000" was the obvious idea )
// turns to mush at 16pt, and this has to survive the menu bar, the Finder and
// the App Switcher. Replace it with a designer's work before shipping.
//
//   swift Scripts/make-icon.swift
import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSBitmapImageRep? {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = size / 1024

    // macOS app icons sit inset inside their canvas.
    let inset = 100 * scale
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

    let background = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.24, alpha: 1),
            NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.15, alpha: 1),
        ])
    background?.draw(in: shape, angle: -90)

    // The socket slot.
    let slotHeight = 96 * scale
    let slotWidth = body.width * 0.46
    let slot = NSRect(
        x: body.minX + body.width * 0.16,
        y: body.midY - slotHeight / 2,
        width: slotWidth,
        height: slotHeight)
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: slot, xRadius: slotHeight / 2, yRadius: slotHeight / 2).fill()

    // The live indicator: something is listening.
    let dot = 132 * scale
    let indicator = NSRect(
        x: slot.maxX + body.width * 0.11,
        y: body.midY - dot / 2,
        width: dot, height: dot)
    NSColor(calibratedRed: 0.30, green: 0.83, blue: 0.47, alpha: 1).setFill()
    NSBezierPath(ovalIn: indicator).fill()

    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let rep = drawIcon(size: variant.size),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed at \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}
print(iconset.path)
