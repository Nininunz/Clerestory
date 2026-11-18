// Generate the custom background for the DMG installer window.
//
// Run with swift Scripts/generate-dmg-background.swift.
// The output is Scripts/dmg-background.png at 600 × 360 pixels. Finder draws the
// image at one point per pixel, so a 2x output would overshoot the window.
// Render at 2x and downsample to 1x for antialiasing.
//
// Layout follows make-dmg.sh in 1x points and pixels. The window is 600 × 360 and
// the 128-point icons are centered at x = 140 and x = 460. Draw a dotted arrow
// between the icons. NSGraphicsContext places the origin at the lower left, so
// subtract distances from the top from the canvas height.

import AppKit

// Output dimensions at 1x and the 2x supersampling factor.
let W: CGFloat = 600
let H: CGFloat = 360
let SS: CGFloat = 2

func makeRep(_ w: CGFloat, _ h: CGFloat) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(w), pixelsHigh: Int(h),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Failed to create bitmap rep \(Int(w))x\(Int(h))") }
    return rep
}

let big = makeRep(W * SS, H * SS)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: big)
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: SS, y: SS)  // Draw in 1x coordinates with the origin at the lower left.

// Draw a subtle background gradient from white on top to light gray below.
let bg = NSGradient(colors: [
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
    NSColor(srgbRed: 0.95, green: 0.96, blue: 0.975, alpha: 1.0),
])!
bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// Draw the gray-blue dotted guide and solid arrowhead 165 points from the top,
// 15 points above the original position.
let arrowY: CGFloat = H - 165
let startX: CGFloat = 228   // Leave 24 points after the app icon's right edge at 204.
let endX: CGFloat = 372     // Leave 24 points before the Applications icon's left edge at 396.
let dotColor = NSColor(srgbRed: 0.4, green: 0.52, blue: 0.76, alpha: 0.95)

dotColor.setFill()
var x = startX
while x <= endX - 40 {
    ctx.fillEllipse(in: CGRect(x: x, y: arrowY - 3, width: 6, height: 6))
    x += 17
}

let head = NSBezierPath()
head.move(to: NSPoint(x: endX, y: arrowY))
head.line(to: NSPoint(x: endX - 22, y: arrowY - 13))
head.line(to: NSPoint(x: endX - 22, y: arrowY - 5))
head.line(to: NSPoint(x: endX - 32, y: arrowY - 5))
head.line(to: NSPoint(x: endX - 32, y: arrowY + 5))
head.line(to: NSPoint(x: endX - 22, y: arrowY + 5))
head.line(to: NSPoint(x: endX - 22, y: arrowY + 13))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

// Downsample to the 1x canvas using high-quality interpolation.
let final = makeRep(W, H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: final)
NSGraphicsContext.current!.imageInterpolation = .high
big.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()

guard let png = final.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode PNG")
}
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let outputURL = scriptURL.deletingLastPathComponent().appendingPathComponent("dmg-background.png")
do {
    try png.write(to: outputURL)
    print("wrote \(outputURL.path) (\(Int(W))x\(Int(H))px, supersampled \(Int(SS))x)")
} catch {
    fatalError("Failed to write PNG: \(error.localizedDescription)")
}

