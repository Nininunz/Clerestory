import AppKit
import SwiftUI
import XCTest
@testable import OpenYoink

@MainActor
final class IslandModuleChromeTests: XCTestCase {
    func testShelfCardsKeepHeightAcrossNamesAndTransferStates() throws {
        let suite = "ShelfCardLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        for width: CGFloat in [88, 107, 140] {
            var heights: Set<Int> = []
            for name in ["Note", "A very long project document name with multiple words.txt"] {
                for status: TransferItemAccessibilityStatus? in [nil, .receiving, .destinationAccepted, .deliveryFailed] {
                    let card = ShelfItemCard(
                        item: ShelfItem(kind: .text, displayName: name, text: "Sample"),
                        isSelected: false, onSelect: { _ in }, transferStatus: status
                    )
                    .environment(settings)
                    .environment(\.shelfPresentationStyle, .island)
                    .frame(width: width)
                    heights.insert(try render(card).pixelsHigh)
                }
            }
            XCTAssertEqual(heights.count, 1, "Uneven cards at width \(width): \(heights)")
        }
    }

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

    func testHeaderActionStyleKeepsSameSizeWhenDisabled() throws {
        for disabled in [false, true] {
            let image = try render(
                Button {} label: { Image(systemName: "plus") }
                    .buttonStyle(IslandHeaderButtonStyle())
                    .disabled(disabled)
            )
            XCTAssertEqual(image.pixelsWide, 56)
            XCTAssertEqual(image.pixelsHigh, 56)
        }
    }

    func testStateAllowsLongErrorDetailsToGrowWithoutTruncation() throws {
        let short = try render(IslandModuleState(title: "Couldn't load", message: "Try again.") {
            Button("Retry") {}
        }.frame(width: 240).fixedSize(horizontal: false, vertical: true))
        let long = try render(IslandModuleState(
            title: "Couldn't load",
            message: "The service could not be reached. Check that the application is running and that access has been granted, then try again. Your existing data is still available."
        ) {
            Button("Retry") {}
        }.frame(width: 240).fixedSize(horizontal: false, vertical: true))
        XCTAssertEqual(short.pixelsWide, 480)
        XCTAssertEqual(long.pixelsWide, 480)
        XCTAssertGreaterThan(long.pixelsHigh, short.pixelsHigh + 40)
    }

    func testClipboardStatesKeepTitleInsideViewport() async throws {
        let suite = "OpenYoink.ClipboardLayoutTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardHistoryEnabled = true
        for state in ["loading", "empty", "no-results", "error"] {
            let store = ClipboardHistoryStore.preview(
                settings: settings, directory: FileManager.default.temporaryDirectory,
                loading: state == "loading",
                error: state == "error" ? "Clipboard history could not be loaded. Clear history to reset it." : nil
            )
            let view = ClipboardHistoryView.preview(query: state == "no-results" ? "missing" : "")
                .environment(settings).environment(store).environment(\.colorScheme, .dark)
                .frame(width: 464, height: 240).background(Color.black)
            let window = host(view, height: 240)
            defer { window.close() }
            await settle(window)
            let host = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / 464
            var titlePixels = 0
            // The white title belongs in the top 18 pt; a pushed-out header
            // leaves only its gray subtitle (or nothing) in this region.
            for x in Int(40 * scale)..<Int(220 * scale) {
                for y in 0..<Int(18 * scale) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8 { titlePixels += 1 }
                }
            }
            XCTAssertGreaterThan(titlePixels, 100, "Header clipped in \(state) state")
        }
    }

    func testExpandedSurfacePaddingIsMeasuredFromVisibleEdge() async throws {
        for notched in [true, false] {
            let probe = Probe()
            let view = IslandExpandedSurface(hasPhysicalNotch: notched) {
                Color.clear.frame(height: 32)
            } content: {
                Color.white
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["body"] = $0 }
            }
            let window = host(view, height: 330, width: 492)
            defer { window.close() }
            await settle(window)
            let body = try XCTUnwrap(probe.frames["body"])
            let visibleEdge: CGFloat = notched ? 7 : 0
            XCTAssertEqual(body.minX - visibleEdge, 14, accuracy: 0.5)
            XCTAssertEqual(492 - visibleEdge - body.maxX, 14, accuracy: 0.5)
            XCTAssertEqual(330 - body.maxY, 14, accuracy: 0.5)
            XCTAssertEqual(body.width, IslandExpandedLayout.contentWidth(surfaceWidth: 492, hasPhysicalNotch: notched), accuracy: 0.5)
            let path = IslandSurfaceShape(attachedToScreenTop: notched, cornerRadius: 26)
                .path(in: CGRect(x: 0, y: 0, width: 492, height: 330))
            XCTAssertTrue(path.contains(CGPoint(x: visibleEdge + 0.5, y: 100)))
            XCTAssertFalse(path.contains(CGPoint(x: visibleEdge - 0.5, y: 100)))
        }
    }

    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func host<V: View>(_ view: V, height: CGFloat, width: CGFloat = 464) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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
