import AppKit
import SwiftUI
import XCTest
@testable import OpenYoink

@MainActor
final class IslandModuleChromeTests: XCTestCase {
    func testHeaderHeightWithNoSingleAndMultipleActions() throws {
        for subtitle in [nil, "A module subtitle"] as [String?] {
            for count in 0...3 {
                let header = IslandModuleHeader(title: "Module", subtitle: subtitle, systemImage: "tray") {
                    ForEach(0..<count, id: \.self) { _ in
                        Button {} label: {
                            Image(systemName: "plus").frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 464)
                let image = try render(header)
                XCTAssertEqual(image.pixelsHigh, 68, "subtitle: \(String(describing: subtitle)), actions: \(count)")
                XCTAssertEqual(image.pixelsWide, 928)
            }
        }
    }

    func testLongTitleAndSubtitleLeaveActionSlotClear() throws {
        for width: CGFloat in [240, 320, 464] {
            let header = IslandModuleHeader(
                title: "An unusually long module title that must truncate",
                subtitle: "An unusually long subtitle that must also leave room for the buttons",
                systemImage: "tray"
            ) {
                // Transparent stand-ins make any title ink underneath the
                // reserved controls visible to this assertion.
                Color.clear.frame(width: 30, height: 30)
                Color.clear.frame(width: 30, height: 30)
            }
            .frame(width: width)
            .background(Color.black)
            let image = try render(header)
            XCTAssertEqual(image.pixelsHigh, 68)
            var brightest: CGFloat = 0
            for x in (image.pixelsWide - 136)..<image.pixelsWide {
                for y in 0..<image.pixelsHigh {
                    let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    brightest = max(brightest, color.redComponent, color.greenComponent, color.blueComponent)
                }
            }
            XCTAssertLessThan(brightest, 0.05, "Title overlaps actions at width \(width)")
        }
    }

    func testOverflowScrollsWithoutMovingHeaderAndBottomIsReachable() async throws {
        for height: CGFloat in [140, 260] {
            let probe = Probe()
            let window = host(ScrollFixture(probe: probe, contentHeight: 600, fillsViewport: true), height: height)
            defer { window.close() }
            await settle(window)
            let headerBefore = try XCTUnwrap(probe.frames["header"])
            let contentBefore = try XCTUnwrap(probe.frames["content"])
            let viewport = try XCTUnwrap(probe.frames["viewport"])
            XCTAssertEqual(headerBefore.height, 34, accuracy: 0.5)
            XCTAssertEqual(viewport.minY - headerBefore.maxY, 10, accuracy: 0.5)
            XCTAssertEqual(contentBefore.height, 600, accuracy: 0.5)

            try XCTUnwrap(probe.scrollToBottom)()
            await settle(window)
            let contentAfter = try XCTUnwrap(probe.frames["content"])
            XCTAssertEqual(probe.frames["header"], headerBefore)
            XCTAssertLessThan(contentAfter.minY, contentBefore.minY - 100)
            XCTAssertEqual(contentAfter.maxY, viewport.maxY - 1, accuracy: 1)
        }
    }

    func testShortContentDoesNotAcquireScrollRange() async throws {
        for fillsViewport in [false, true] {
            let probe = Probe()
            let window = host(ScrollFixture(probe: probe, contentHeight: 60, fillsViewport: fillsViewport), height: 260)
            defer { window.close() }
            await settle(window)
            let before = try XCTUnwrap(probe.frames["content"])
            let viewport = try XCTUnwrap(probe.frames["viewport"])
            XCTAssertGreaterThanOrEqual(before.minY, viewport.minY)
            XCTAssertLessThanOrEqual(before.maxY, viewport.maxY)
            try XCTUnwrap(probe.scrollToBottom)()
            await settle(window)
            XCTAssertEqual(probe.frames["content"], before)
        }
    }

    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func host<V: View>(_ view: V, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 464, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private final class Probe {
        var frames: [String: CGRect] = [:]
        var scrollToBottom: (() -> Void)?
    }

    private struct ScrollFixture: View {
        let probe: Probe
        let contentHeight: CGFloat
        let fillsViewport: Bool

        var body: some View {
            VStack(spacing: IslandModuleLayout.headerSpacing) {
                IslandModuleHeader(title: "Module", subtitle: "Subtitle", systemImage: "tray") {
                    Button {} label: { Image(systemName: "plus").frame(width: 30, height: 30) }
                        .buttonStyle(.plain)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["header"] = $0 }

                ScrollViewReader { proxy in
                    IslandModuleScrollView(fillsViewport: fillsViewport) {
                        Color.blue
                            .frame(height: contentHeight)
                            .id("content")
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["content"] = $0 }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["viewport"] = $0 }
                    .onAppear { probe.scrollToBottom = { proxy.scrollTo("content", anchor: .bottom) } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
