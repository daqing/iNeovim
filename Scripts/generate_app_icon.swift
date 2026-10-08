#!/usr/bin/env swift
// Generates the macOS AppIcon image set. Run from the repo root:
//   swift Scripts/generate_app_icon.swift iNeovim/Assets.xcassets/AppIcon.appiconset
import AppKit

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "iNeovim/Assets.xcassets/AppIcon.appiconset"

func makeIcon(px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Big Sur icon geometry: 824pt artwork centered in 1024pt, corner 185.4pt.
    let inset = size * (1 - 824.0 / 1024.0) / 2
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = size * (185.4 / 1024.0)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    let colors = [
        NSColor(srgbRed: 0.11, green: 0.15, blue: 0.24, alpha: 1).cgColor,
        NSColor(srgbRed: 0.09, green: 0.62, blue: 0.52, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Monospace prompt glyph, centered.
    let font = NSFont.monospacedSystemFont(ofSize: size * 0.36, weight: .bold)
    let text = NSAttributedString(string: ">_", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
    ])
    let textSize = text.size()
    text.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(
    atPath: outputDir,
    withIntermediateDirectories: true
)
for (name, px) in sizes {
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
    try makeIcon(px: px).write(to: url)
    print("wrote \(name) (\(px)px)")
}
