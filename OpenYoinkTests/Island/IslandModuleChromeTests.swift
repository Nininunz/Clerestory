import AppKit
import SwiftUI
import XCTest
@testable import OpenYoink

@MainActor
final class IslandModuleChromeTests: XCTestCase {
    func testThumbnailVisibleBoundsExcludeTransparentPaddingAndFaintShadow() throws {
        let width = 20, height = 20
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 4..<12 {
            for x in 4..<14 {
                pixels[(y * width + x) * 4 + 3] = 255
            }
        }
        pixels[3] = 20 // A faint shadow must not pull the control toward the canvas edge.
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                         bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bounds = ShelfThumbnail.visibleBounds(in: image)
        XCTAssertEqual(bounds.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, 0.2, accuracy: 0.001)
        XCTAssertEqual(bounds.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(bounds.height, 0.4, accuracy: 0.001)
    }

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

    func testShelfAvailabilityDoesNotChangeTileOrGridHeight() throws {
        let suite = "ShelfAvailabilityLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        for width: CGFloat in [88, 107, 140] {
            for name in ["File.txt", "Archived project proposal with a long filename.pdf"] {
                var tileHeights = Set<Int>()
                var gridHeights = Set<Int>()
                for availability: ItemAvailability in [.available, .externalFileOffline, .managedCopyMissing] {
                    var item = ShelfItem(kind: .file, displayName: name)
                    item.availability = availability
                    let card = ShelfItemCard(item: item, isSelected: false, onSelect: { _ in }, onRecover: {})
                        .environment(settings)
                        .environment(\.shelfPresentationStyle, .island)
                        .frame(width: width)
                    tileHeights.insert(try render(card).pixelsHigh)
                    let grid = LazyVGrid(columns: [GridItem(.fixed(width), alignment: .top)], spacing: 12) {
                        card
                        card
                    }.frame(width: width)
                    gridHeights.insert(try render(grid).pixelsHigh)
                }
                XCTAssertEqual(tileHeights.count, 1, "Availability changed tile height at \(width)")
                XCTAssertEqual(gridHeights.count, 1, "Availability changed grid height at \(width)")
            }
        }
    }

    func testFooterHeightStaysFixedWhenSelectionActionsAppear() throws {
        for selected in [false, true] {
            let footer = IslandModuleFooter {
                Button(selected ? "Done" : "Select") {}
                if selected { Text("12 selected") }
                Spacer()
                ForEach(0..<(selected ? 4 : 1), id: \.self) { _ in
                    Button {} label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .frame(width: 450)
            let image = try render(footer)
            XCTAssertEqual(image.pixelsHigh, 56)
            XCTAssertEqual(image.pixelsWide, 900)
        }
    }

    func testDragOutlineGrowsFromCompactBoundsAndRemainsVisibleAtCompletion() {
        let rect = CGRect(x: 0, y: 0, width: 492, height: 330)
        var previous = CGRect.zero
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let outline = IslandTransitionDropOutline(progress: progress,
                collapsedSize: CGSize(width: 290, height: 38), attachedToScreenTop: true, isVisible: true)
            let path = outline.path(in: rect)
            XCTAssertFalse(path.isEmpty)
            let bounds = path.boundingRect
            XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.01)
            XCTAssertEqual(bounds.minY, 1, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(bounds.width, previous.width)
            XCTAssertGreaterThanOrEqual(bounds.height, previous.height)
            previous = bounds
        }
        XCTAssertEqual(previous.width, 490, accuracy: 0.01)
        XCTAssertEqual(previous.height, 328, accuracy: 0.01)
        XCTAssertTrue(IslandTransitionDropOutline(progress: 1,
            collapsedSize: CGSize(width: 290, height: 38), attachedToScreenTop: true,
            isVisible: false).path(in: rect).isEmpty)
    }

    func testFloatingDragOutlineKeepsTopEdgeAndRoundedCornersDuringReveal() throws {
        let size = CGSize(width: 492, height: 330)
        let state = DropTargetState()
        state.isTargeted = true
        for duplicate in [false, true] {
            state.hasDuplicateFiles = duplicate
            for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let reveal = IslandSurfaceReveal(progress: progress)
                let frame = reveal.frame(in: size)
                let outline = IslandDropOutline(progress: progress, collapsedSize: reveal.collapsedSize,
                                                attachedToScreenTop: false, state: state)
                let actual = try render(outline.frame(width: size.width, height: size.height))
                let expected = try render(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .inset(by: 1).path(in: frame)
                        .stroke(outline.tint.opacity(0.85), lineWidth: 2)
                        .frame(width: size.width, height: size.height)
                )
                XCTAssertGreaterThan(try XCTUnwrap(actual.colorAt(x: 492, y: 1)).alphaComponent, 0.8,
                                     "Top edge missing at reveal progress \(progress)")
                // Use SwiftUI's inset curve as an independent reference for all four corners.
                let bottom = Int(frame.maxY * 2)
                let rows = Set(Array(0..<52) + Array(max(0, bottom - 52)..<bottom))
                var largestAlphaDifference: CGFloat = 0
                for y in rows {
                    for x in 0..<actual.pixelsWide {
                        largestAlphaDifference = max(largestAlphaDifference,
                            abs(actual.colorAt(x: x, y: y)!.alphaComponent
                                - expected.colorAt(x: x, y: y)!.alphaComponent))
                    }
                }
                XCTAssertLessThan(largestAlphaDifference, 0.01,
                                  "Corner curve differs from the panel at reveal progress \(progress)")
            }
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

    func testFooterStaysBelowScrollingContentWithLargeSelectionCounts() async throws {
        for count in [0, 1, 9999] {
            let probe = Probe()
            let window = host(ScrollFixture(probe: probe, contentHeight: 600,
                                            fillsViewport: true, selectionCount: count), height: 260)
            defer { window.close() }
            await settle(window)
            let footer = try XCTUnwrap(probe.frames["footer"])
            let viewport = try XCTUnwrap(probe.frames["viewport"])
            XCTAssertEqual(footer.height, 28, accuracy: 0.5)
            XCTAssertEqual(footer.maxY, 260, accuracy: 0.5)
            XCTAssertEqual(footer.minY - viewport.maxY, 10, accuracy: 0.5)
            for key in ["select", "actions"] {
                let frame = try XCTUnwrap(probe.frames[key])
                XCTAssertGreaterThanOrEqual(frame.minX, footer.minX)
                XCTAssertLessThanOrEqual(frame.maxX, footer.maxX)
                XCTAssertGreaterThanOrEqual(frame.minY, footer.minY)
                XCTAssertLessThanOrEqual(frame.maxY, footer.maxY)
            }
            XCTAssertLessThanOrEqual(try XCTUnwrap(probe.frames["select"]).maxX,
                                     try XCTUnwrap(probe.frames["actions"]).minX)
            try XCTUnwrap(probe.scrollToBottom)()
            await settle(window)
            XCTAssertEqual(probe.frames["footer"], footer)
            XCTAssertEqual(try XCTUnwrap(probe.frames["content"]).maxY, viewport.maxY - 1, accuracy: 1)
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
        do {
            let probe = Probe()
            let view = IslandExpandedSurface() {
                Color.clear.frame(height: 50)
            } content: {
                Color.white
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["body"] = $0 }
            }
            let window = host(view, height: 330, width: 492)
            defer { window.close() }
            await settle(window)
            let body = try XCTUnwrap(probe.frames["body"])
            let visibleEdge: CGFloat = 0
            XCTAssertEqual(body.minX - visibleEdge, 14, accuracy: 0.5)
            XCTAssertEqual(492 - visibleEdge - body.maxX, 14, accuracy: 0.5)
            XCTAssertEqual(330 - body.maxY, 14, accuracy: 0.5)
            XCTAssertEqual(body.width, IslandExpandedLayout.contentWidth(surfaceWidth: 492), accuracy: 0.5)
            let path = IslandSurfaceShape(attachedToScreenTop: false, cornerRadius: 26)
                .path(in: CGRect(x: 0, y: 0, width: 492, height: 330))
            XCTAssertTrue(path.contains(CGPoint(x: visibleEdge + 0.5, y: 100)))
            XCTAssertFalse(path.contains(CGPoint(x: visibleEdge - 0.5, y: 100)))
        }
    }

    func testToastShadowFadesBeforeWindowEdges() throws {
        for message in [ShelfNoticeMessage.reconnected, .receivedAwaitingRecovery] {
            let bitmap = try render(ShelfNoticePanelContent(notice: message.presentation, onRecovery: { _ in }))
            var edgeAlpha: CGFloat = 0
            for x in 0..<bitmap.pixelsWide {
                edgeAlpha = max(edgeAlpha, try XCTUnwrap(bitmap.colorAt(x: x, y: 0)).alphaComponent)
                edgeAlpha = max(edgeAlpha, try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1)).alphaComponent)
            }
            for y in 0..<bitmap.pixelsHigh {
                edgeAlpha = max(edgeAlpha, try XCTUnwrap(bitmap.colorAt(x: 0, y: y)).alphaComponent)
                edgeAlpha = max(edgeAlpha, try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: y)).alphaComponent)
            }
            XCTAssertLessThanOrEqual(edgeAlpha, 1.0 / 255.0, "Shadow must not end at a visible rectangular crop")
        }
    }

    func testShelfNoticesFitCompactToastAtBothModuleWidths() throws {
        for sample in ShelfFeedbackScenario.notices {
            for width in [CGFloat(260), 464] {
                let toast = ShelfNoticeToast(notice: sample.notice, onPerformRecovery: { _ in })
                    .frame(width: width)
                let bitmap = try render(toast)
                XCTAssertEqual(bitmap.pixelsWide, Int(width * 2), sample.id)
                XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 150, sample.id)
            }
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
        var selectionCount: Int? = nil

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
                if let count = selectionCount {
                    IslandModuleFooter {
                        HStack {
                            Button(count > 0 ? "Done" : "Select") {}
                                .buttonStyle(IslandActionButtonStyle())
                            if count > 0 { Text("\(count) selected").lineLimit(1) }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["select"] = $0 }
                        Spacer(minLength: 4)
                        HStack(spacing: 8) {
                            ForEach(0..<(count > 0 ? 5 : 2), id: \.self) { _ in
                                Button {} label: { Image(systemName: "ellipsis") }
                                    .buttonStyle(IslandHeaderButtonStyle())
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["actions"] = $0 }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames["footer"] = $0 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
