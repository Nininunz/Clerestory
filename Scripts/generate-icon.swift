#!/usr/bin/env swift
// Run with swift Scripts/generate-icon.swift to regenerate the macOS icon set.
// AppIcon-master.png is square artwork with transparent corners and its final silhouette.

import AppKit

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let masterURL = repoRoot.appendingPathComponent("Scripts/AppIcon-master.png")
let iconsetURL = repoRoot
    .appendingPathComponent("OpenYoink/Resources/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: masterURL.path) else {
    fatalError("Master artwork missing: \(masterURL.path)")
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
guard let source = NSImage(contentsOf: masterURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
      source.width == source.height, source.width >= 1024,
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                              bytesPerRow: 1024 * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot decode or render master artwork")
}
// Scale the transparent master to match the footprint of other macOS Dock icons.
let bounds = CGRect(x: 64, y: 64, width: 896, height: 896)
context.interpolationQuality = .high
context.draw(source, in: bounds)
guard let rendered = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode icon")
}
let normalizedURL = iconsetURL.appendingPathComponent("AppIcon-1024.png")
try png.write(to: normalizedURL, options: .atomic)

for size in sizes where size != 1024 {
    let output = iconsetURL.appendingPathComponent("AppIcon-\(size).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "\(size)", "\(size)", normalizedURL.path, "--out", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("sips failed for size \(size) (status \(process.terminationStatus))")
    }
    print("wrote \(output.path)")
}

for size in sizes {
    let url = iconsetURL.appendingPathComponent("AppIcon-\(size).png")
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)), rep.hasAlpha else {
        fatalError("Icon has no alpha: \(size)")
    }
    for point in [(0, 0), (0, size - 1), (size - 1, 0), (size - 1, size - 1)] {
        guard rep.colorAt(x: point.0, y: point.1)?.alphaComponent == 0 else {
            fatalError("Icon corner is opaque: \(size)")
        }
    }
    let mid = size / 2
    let visible = (0..<size).filter { (rep.colorAt(x: $0, y: mid)?.alphaComponent ?? 0) > 0.5 }
    guard visible.count >= Int(Double(size) * 0.7), visible.count <= Int(Double(size) * 0.85) else {
        fatalError("Unexpected icon footprint: \(size)")
    }
    print("verified \(size)px: transparent corners, visible width \(visible.count)px")
}

// Contents.json：10 个槽位（512@2x 复用 1024 主图，依此类推）。
let contents = """
{
  "images" : [
    { "filename" : "AppIcon-16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "AppIcon-32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "AppIcon-32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "AppIcon-64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "AppIcon-128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "AppIcon-256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "AppIcon-256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "AppIcon-512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "AppIcon-512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "AppIcon-1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
do {
    try contents.write(to: iconsetURL.appendingPathComponent("Contents.json"),
                       atomically: true, encoding: .utf8)
    print("wrote Contents.json")
} catch {
    fatalError("Failed to write Contents.json: \(error.localizedDescription)")
}

print("AppIcon generation complete.")
