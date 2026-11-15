import AppKit
import SwiftUI
import XCTest
@testable import OpenYoink

@MainActor
final class IslandCompactWingRowTests: XCTestCase {
    private let housingWidths: [CGFloat] = [184, 220, 222, 260]
    private let scale: CGFloat = 2

    func testIconsAndValuesStayInsideBothWings() throws {
        let roundedThousandCost = AIUsageFormat.compactCost(999.9)
        let abbreviatedCost = AIUsageFormat.compactCost(1_234)
        XCTAssertEqual(roundedThousandCost, "$1K")
        XCTAssertEqual(abbreviatedCost, "$1.2K")
        let values: [(text: String, minimumScale: CGFloat)] = [
            ("24:56", 0.65), ("105m", 0.65),
            (AIUsageFormat.compactCost(9.99), 0.7),
            (AIUsageFormat.compactCost(99.75), 0.7), ("$314", 0.7), (roundedThousandCost, 0.7),
            (abbreviatedCost, 0.7), ("$1000", 0.7)
        ]

        for housingWidth in housingWidths {
            var iconCenters: [String: Int] = [:]
            for symbol in ["battery.75percent", "chart.line.uptrend.xyaxis", "tray.and.arrow.down.fill", "arrow.down"] {
                for value in values {
                    let image = try render(housingWidth: housingWidth, symbol: symbol,
                                           value: value.text, minimumScale: value.minimumScale)
                if housingWidth == 220 && ((symbol == "battery.75percent" && ["105m", "$1K", "$9.99"].contains(value.text))
                    || (symbol == "chart.line.uptrend.xyaxis" && ["24:56", "$1.2K"].contains(value.text))) {
                    let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(image.cgImage),
                                                                  size: NSSize(width: image.pixelsWide / 2,
                                                                               height: image.pixelsHigh / 2)))
                    attachment.name = "compact-\(symbol)-\(value.text)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                let wingPixels = Int(IslandGeometryResolver.compactWingWidth * scale)
                let left = try inkBounds(in: image, xRange: 0..<wingPixels)
                let right = try inkBounds(in: image,
                                          xRange: (image.pixelsWide - wingPixels)..<image.pixelsWide)
                XCTAssertFalse(hasInk(in: image,
                                       xRange: wingPixels..<(image.pixelsWide - wingPixels)),
                               "Housing overflow: \(housingWidth), \(symbol), \(value.text)")

                XCTAssertGreaterThanOrEqual(left.minX, Int(11 * scale), "\(symbol), \(value.text)")
                XCTAssertLessThan(left.maxX, wingPixels, "\(symbol), \(value.text)")
                XCTAssertGreaterThanOrEqual(right.minX, image.pixelsWide - wingPixels,
                                            "\(symbol), \(value.text)")
                XCTAssertLessThanOrEqual(right.maxX, image.pixelsWide - Int(8 * scale),
                                         "\(symbol), \(value.text)")
                let valueCenter = (right.minX + right.maxX) / 2
                XCTAssertLessThanOrEqual(abs(valueCenter - (image.pixelsWide - Int(25 * scale))),
                                         Int(4 * scale), "\(housingWidth), \(symbol), \(value.text)")
                let iconCenter = (left.minX + left.maxX) / 2
                XCTAssertLessThanOrEqual(abs(iconCenter - Int(25 * scale)), Int(2 * scale),
                                         "\(symbol), \(value.text)")
                iconCenters[symbol] = iconCenter
                }
            }
            XCTAssertLessThanOrEqual(abs(try XCTUnwrap(iconCenters["battery.75percent"])
                                        - XCTUnwrap(iconCenters["chart.line.uptrend.xyaxis"])), 4)
        }
    }

    func testRightWingCenteredContent() throws {
        for housingWidth in housingWidths {
            for kind in ["sparkles", "equalizer", "spinner", "shelf12", "shelf1000", "battery85", "battery100"] {
            let width = housingWidth + IslandGeometryResolver.compactWingWidth * 2
            let row = IslandCompactWingRow(cameraHousingWidth: housingWidth, display: .shelf, height: 38) {
                IslandCompactWingIcon(systemName: "arrow.down")
                    .foregroundStyle(.white)
            } trailing: {
                if kind == "equalizer" {
                    IslandCompactWingIcon(systemName: "play.fill")
                        .foregroundStyle(.white)
                } else if kind == "spinner" {
                    IslandCompactTransferSpinner()
                } else if kind == "shelf12" || kind == "shelf1000" {
                    Text(kind == "shelf12" ? "12" : "1000")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                } else if kind == "battery85" || kind == "battery100" {
                    IslandCompactBatteryValueText(percentage: kind == "battery85" ? 85 : 100)
                        .foregroundStyle(.white)
                } else {
                    IslandCompactWingIcon(systemName: "sparkles")
                        .foregroundStyle(.white)
                }
            }
            .frame(width: width, height: 38)
            .background(Color.black)
            let renderer = ImageRenderer(content: row)
            renderer.scale = scale
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            if housingWidth == 220 && (kind == "spinner" || kind == "shelf12" || kind == "battery100") {
                let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(image.cgImage),
                                                              size: NSSize(width: image.pixelsWide / 2,
                                                                           height: image.pixelsHigh / 2)))
                attachment.name = "compact-\(kind)-both-wings"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let wingPixels = Int(IslandGeometryResolver.compactWingWidth * scale)
            let right = try inkBounds(in: image,
                                      xRange: (image.pixelsWide - wingPixels)..<image.pixelsWide,
                                      minimumBrightness: 0.1)
            XCTAssertFalse(hasInk(in: image,
                                   xRange: wingPixels..<(image.pixelsWide - wingPixels),
                                   minimumBrightness: 0.1),
                           "Housing overflow: \(housingWidth), \(kind)")
            let center = (right.minX + right.maxX) / 2
            XCTAssertLessThanOrEqual(abs(center - (image.pixelsWide - Int(25 * scale))),
                                     Int(4 * scale), kind)
            if kind == "battery100" {
                XCTAssertLessThanOrEqual(right.maxY - right.minY, Int(16 * scale),
                                         "100% must remain on one line")
            }
            }
        }
    }

    func testArtworkFootprintMatchesLeftIconSlot() throws {
        for housingWidth in housingWidths {
            let width = housingWidth + IslandGeometryResolver.compactWingWidth * 2
            let row = IslandCompactWingRow(cameraHousingWidth: housingWidth, display: .shelf, height: 38) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white)
                    .frame(width: 23, height: 23)
            } trailing: {
                Image(systemName: "play.fill")
                    .foregroundStyle(.white)
            }
            .frame(width: width, height: 38)
            .background(Color.black)
            let renderer = ImageRenderer(content: row)
            renderer.scale = scale
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let wingPixels = Int(IslandGeometryResolver.compactWingWidth * scale)
            let left = try inkBounds(in: image, xRange: 0..<wingPixels)
            XCTAssertLessThanOrEqual(abs((left.minX + left.maxX) / 2 - Int(25 * scale)),
                                     Int(scale), "Housing width: \(housingWidth)")
            XCTAssertFalse(hasInk(in: image,
                                   xRange: wingPixels..<(image.pixelsWide - wingPixels)),
                           "Artwork entered housing: \(housingWidth)")
        }
    }

    func testSlidingContentCannotEscapeVisibleIslandOutline() throws {
        for housingWidth in housingWidths {
            let width = housingWidth + IslandGeometryResolver.compactWingWidth * 2
            let maskRenderer = ImageRenderer(content:
                IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11)
                    .fill(.white)
                    .frame(width: width, height: 38)
                    .background(Color.black))
            maskRenderer.scale = scale
            let mask = NSBitmapImageRep(cgImage: try XCTUnwrap(maskRenderer.cgImage))
            // Oversized, offset content exercises clipping throughout the slide's travel.
            for offset: CGFloat in [-40, -20, 0, 20, 40] {
                let row = IslandCompactWingRow(cameraHousingWidth: housingWidth,
                                              display: .shelf, height: 38) {
                    Color.white.frame(width: 80, height: 60).offset(x: offset)
                } trailing: {
                    Color.white.frame(width: 80, height: 60).offset(x: offset)
                }
                .frame(width: width, height: 38)
                .background(Color.black)
                let renderer = ImageRenderer(content: row)
                renderer.scale = scale
                let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                for x in 0..<image.pixelsWide {
                    for y in 0..<image.pixelsHigh {
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / scale,
                                            y: (CGFloat(y) + 0.5) / scale)
                        let boundary = try XCTUnwrap(mask.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        guard boundary.redComponent < 0.05 else { continue }
                        let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        XCTAssertLessThan(color.redComponent, 0.1,
                                          "Escaped outline at \(point), offset \(offset)")
                    }
                }
                let wingPixels = Int(IslandGeometryResolver.compactWingWidth * scale)
                XCTAssertFalse(hasInk(in: image,
                    xRange: wingPixels..<(image.pixelsWide - wingPixels)))
            }
        }
    }

    private func render(housingWidth: CGFloat, symbol: String, value: String,
                        minimumScale: CGFloat) throws -> NSBitmapImageRep {
        let width = housingWidth + IslandGeometryResolver.compactWingWidth * 2
        let row = IslandCompactWingRow(cameraHousingWidth: housingWidth, display: .shelf, height: 38) {
            IslandCompactWingIcon(systemName: symbol)
                .foregroundStyle(.white)
        } trailing: {
            if minimumScale == 0.7 {
                IslandCompactAIValueText(value: value)
                    .foregroundStyle(.white)
            } else {
                Text(value)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(minimumScale)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: 38)
        .background(Color.black)
        let renderer = ImageRenderer(content: row)
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func hasInk(in image: NSBitmapImageRep, xRange: Range<Int>,
                        minimumBrightness: CGFloat = 0.4) -> Bool {
        for x in xRange {
            for y in 0..<image.pixelsHigh {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > minimumBrightness,
                   color.greenComponent > minimumBrightness,
                   color.blueComponent > minimumBrightness { return true }
            }
        }
        return false
    }

    private func inkBounds(in image: NSBitmapImageRep,
                           xRange: Range<Int>,
                           minimumBrightness: CGFloat = 0.4) throws -> (minX: Int, maxX: Int,
                                                                          minY: Int, maxY: Int) {
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
        for x in xRange {
            for y in 0..<image.pixelsHigh {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > minimumBrightness,
                      color.greenComponent > minimumBrightness,
                      color.blueComponent > minimumBrightness else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else {
            throw NSError(domain: "IslandCompactWingRowTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No rendered ink in the requested wing"])
        }
        return (minX, maxX, minY, maxY)
    }
}
