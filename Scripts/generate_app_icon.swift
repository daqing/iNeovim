#!/usr/bin/env swift
// Generates the macOS AppIcon image set from the Neovim mark. Run from the repo root:
//   swift Scripts/generate_app_icon.swift
// Optional args: <output-dir> <svg-path>
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
let svgPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "iNeovim/Assets.xcassets/logo.imageset/logo.svg"

guard let logo = NSImage(contentsOfFile: svgPath) else {
    FileHandle.standardError.write(Data("Could not load SVG at \(svgPath)\n".utf8))
    exit(1)
}
let logoSize = logo.size.width > 0 && logo.size.height > 0 ? logo.size : CGSize(width: 602, height: 734)
let aspect = logoSize.width / logoSize.height

// Big Sur icon geometry: artwork occupies ~824 of 1024 pt, centred.
let artworkFraction = 824.0 / 1024.0

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
    NSGraphicsContext.current?.imageInterpolation = .high

    let box = size * artworkFraction
    var width = box
    var height = box
    if aspect >= 1 {
        height = box / aspect
    } else {
        width = box * aspect
    }
    let rect = CGRect(
        x: (size - width) / 2,
        y: (size - height) / 2,
        width: width,
        height: height
    )
    logo.draw(in: rect)

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
