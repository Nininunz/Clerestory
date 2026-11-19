import AppKit
import SwiftUI
import XCTest
@testable import Clerestory

@MainActor
final class IslandSurfaceAnimationTests: XCTestCase {
    func testBorderAndShadowFollowRevealAtEverySampleAndFadeTogether() throws {
        let size = CGSize(width: 492, height: 330)
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            for opacity in [1.0, 0.5, 0.0] {
                let reveal = IslandSurfaceReveal(progress: progress, opacity: opacity)
                let view = IslandExpandedSurface(reveal: reveal, showsShadow: true) {
                    Color.clear.frame(height: 50)
                } content: {
                    Color.clear
                }
                .frame(width: size.width, height: size.height)
                .padding(IslandSurfaceShadow.inset)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                let frame = reveal.frame(in: size).offsetBy(dx: IslandSurfaceShadow.inset, dy: IslandSurfaceShadow.inset)
                func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                    try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.deviceRGB))
                }
                let border = try color(frame.midX, frame.maxY - 0.5)
                let inside = try color(frame.midX, frame.maxY - 4)
                let shadow = try color(frame.midX, frame.maxY + 6)
                XCTAssertEqual(inside.alphaComponent, opacity, accuracy: 0.015)
                XCTAssertEqual(border.alphaComponent, opacity, accuracy: 0.015)
                if opacity > 0 {
                    XCTAssertGreaterThan(border.redComponent, inside.redComponent + 0.04,
                                         "Border missing at the moving edge, progress \(progress)")
                    XCTAssertGreaterThan(shadow.alphaComponent, 0.01 * opacity,
                                         "Shadow missing at the moving edge, progress \(progress)")
                    XCTAssertLessThan(shadow.alphaComponent, 0.25 * opacity)
                } else {
                    XCTAssertEqual(shadow.alphaComponent, 0, accuracy: 0.001)
                }
                for x in [0, bitmap.pixelsWide - 1] {
                    for y in 0..<bitmap.pixelsHigh {
                        XCTAssertLessThan(bitmap.colorAt(x: x, y: y)!.alphaComponent, 0.005)
                    }
                }
                for y in [0, bitmap.pixelsHigh - 1] {
                    for x in 0..<bitmap.pixelsWide {
                        XCTAssertLessThan(bitmap.colorAt(x: x, y: y)!.alphaComponent, 0.005)
                    }
                }
                // Optional diagnostic export; the normal suite has no file output.
                if ProcessInfo.processInfo.environment["CLERESTORY_EXPORT_SURFACE_FRAMES"] == "1" {
                    let output = FileManager.default.temporaryDirectory
                        .appendingPathComponent("clerestory-shared-chrome-frames", isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("reveal-\(progress)-opacity-\(opacity).png"))
                }
            }
        }
    }

    func testCloseKeepsSurfaceMountedUntilAnimationCompletesAndReopenCancelsRemoval() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let model = AnimationFixtureModel()
        let host = NSHostingView(rootView: AnimationFixture(model: model))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 588, height: 426),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        model.show(true)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(model.mounted)
        XCTAssertTrue(model.completed.contains(1))
        model.show(false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(model.mounted, "The closing surface must remain mounted")
        XCTAssertFalse(model.completed.contains(2), "Native window must not hide before the fold finishes")
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / 588
        let x = Int(294 * scale)
        let opaqueRows = (0..<bitmap.pixelsHigh).filter {
            (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.05
        }
        XCTAssertFalse(opaqueRows.isEmpty, "There must be a visible intermediate closing frame")
        XCTAssertLessThan(opaqueRows.count, Int(320 * scale), "The surface must actually shrink during close")
        model.show(true)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(model.mounted)
        XCTAssertFalse(model.completed.contains(2), "Interrupted close must not remove the reopened surface")
        XCTAssertTrue(model.completed.contains(3))
        model.show(false)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(model.mounted)
        XCTAssertTrue(model.completed.contains(4))
    }

    @Observable
    final class AnimationFixtureModel {
        var expanded = false
        var id: UInt64 = 0
        var mounted = false
        var completed: [UInt64] = []
        func show(_ expanded: Bool) { self.expanded = expanded; id += 1 }
    }

    private struct AnimationFixture: View {
        let model: AnimationFixtureModel
        var body: some View {
            IslandSurfaceAnimationHost(isExpanded: model.expanded, transitionID: model.id,
                                       onCompleted: { model.completed.append($0) }) { reveal in
                IslandExpandedSurface(reveal: reveal, showsShadow: true) {
                    Color.clear.frame(height: 50)
                } content: { Color.clear }
                .onAppear { model.mounted = true }
                .onDisappear { model.mounted = false }
            }
            .padding(IslandSurfaceShadow.inset)
        }
    }

    func testNativeHitRegionMatchesContinuousCornersAtRegularAndExtendedHeights() {
        let owner = IslandExpandedWindowController {
            ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
        }
        owner.configure()
        for height: CGFloat in [330, 600] {
            let surface = CGRect(x: -600, y: 100, width: 492, height: height)
            owner.panel.setFrame(IslandSurfaceShadow.windowFrame(for: surface), display: false)
            let visible = RoundedRectangle(cornerRadius: 26, style: .continuous).path(in: surface)
            var mismatches = 0
            for x in stride(from: 0.5, to: 40.0, by: 1) {
                for y in stride(from: 0.5, to: 40.0, by: 1) {
                    for px in [surface.minX + x, surface.maxX - x] {
                        for py in [surface.minY + y, surface.maxY - y] {
                            let point = CGPoint(x: px, y: py)
                            if owner.panel.containsInteractionPoint(point) != visible.contains(point) {
                                mismatches += 1
                            }
                        }
                    }
                }
            }
            XCTAssertEqual(mismatches, 0, "Native input and visible corners must agree at height \(height)")
            // Previously accepted by the circular AppKit path, outside the continuous corner.
            owner.updatePointer(at: CGPoint(x: surface.minX + 0.5, y: surface.minY + 21.5))
            XCTAssertTrue(owner.panel.ignoresMouseEvents)
        }
    }

    func testShadowCanvasDoesNotEnlargePointerOrDropSurface() {
        let surface = CGRect(x: 300, y: 500, width: 492, height: 330)
        let owner = IslandExpandedWindowController {
            ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
        }
        owner.configure()
        owner.panel.setFrame(IslandSurfaceShadow.windowFrame(for: surface), display: false)
        XCTAssertEqual(owner.panel.interactionFrame, surface)
        for point in [CGPoint(x: surface.minX - 1, y: surface.midY),
                      CGPoint(x: surface.maxX + 1, y: surface.midY),
                      CGPoint(x: surface.midX, y: surface.maxY + 1),
                      CGPoint(x: surface.midX, y: surface.minY - 1),
                      CGPoint(x: surface.minX + 1, y: surface.minY + 1)] {
            XCTAssertFalse(owner.panel.containsInteractionPoint(point))
            owner.updatePointer(at: point)
            XCTAssertTrue(owner.panel.ignoresMouseEvents)
        }
        owner.updatePointer(at: CGPoint(x: surface.midX, y: surface.midY))
        XCTAssertFalse(owner.panel.ignoresMouseEvents)
        XCTAssertFalse(owner.panel.hasShadow, "SwiftUI owns the only shadow throughout the transition")
    }
}
