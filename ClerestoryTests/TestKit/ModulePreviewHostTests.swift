import AppKit
import SwiftUI
import XCTest
@testable import Clerestory

@MainActor
final class ModulePreviewHostTests: XCTestCase {
    private struct ContextProbe: View {
        @Environment(\.islandModuleExtension) var context
        let report: (IslandModuleExtensionContext?) -> Void
        var body: some View { Color.clear.onAppear { report(context) } }
    }

    func testProductionHostInjectsWorkingExtensionBinding() async throws {
        let descriptor = try XCTUnwrap(ModulePreviewHost.descriptor(for: "shelf"))
        let coordinator = IslandActivityCoordinator()
        var received: IslandModuleExtensionContext?
        let view = IslandModuleHost(descriptor: descriptor, coordinator: coordinator) {
            ContextProbe { received = $0 }
        }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let context = try XCTUnwrap(received, "Missing host context hides the header's extend button")
        XCTAssertFalse(context.isExtended.wrappedValue)
        context.reportHeight(480)
        context.isExtended.wrappedValue = true
        XCTAssertTrue(coordinator.isModuleExtended(descriptor))
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: descriptor), 480)
        context.isExtended.wrappedValue = false
        XCTAssertEqual(coordinator.preferredExpandedHeight(for: descriptor), 330)
    }

    func testUnsupportedModuleDoesNotGetExtensionControls() throws {
        let descriptor = try XCTUnwrap(ModulePreviewHost.descriptor(for: "timer"))
        XCTAssertFalse(descriptor.supportsExtendedHeight)
        let host = IslandModuleHost(descriptor: descriptor, coordinator: IslandActivityCoordinator()) { EmptyView() }
        XCTAssertNil(host.extensionContext)
    }

    /// Battery's details (including the Low Power Mode control) use the extended height.
    func testBatteryGetsExtensionControls() throws {
        let descriptor = try XCTUnwrap(ModulePreviewHost.descriptor(for: "battery"))
        let host = IslandModuleHost(descriptor: descriptor, coordinator: IslandActivityCoordinator()) { EmptyView() }
        XCTAssertNotNil(host.extensionContext)
    }

    func testPreviewMeasuresActualShelfContentAndCapsExtendedHeight() async throws {
        let descriptor = try XCTUnwrap(ModulePreviewHost.descriptor(for: "shelf"))
        let fixture = try ShelfScenarioFixture(.manyItems)
        let context = PreviewContext()
        defer { context.cleanUp() }
        let coordinator = IslandActivityCoordinator()
        let view = ModulePreviewHost(descriptor: descriptor, coordinator: coordinator,
                                     content: fixture.view(settings: context.settings()))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2000, y: -2000), size: view.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(view.size.height, 330)
        let measured = try XCTUnwrap(coordinator.moduleContentHeights[.shelf])
        XCTAssertGreaterThan(measured, 550)
        coordinator.setModuleExtended(true, descriptor: descriptor)
        let expected = IslandGeometryResolver.resolve(screen: ModulePreviewHost.screen,
                                                       preferredExpandedHeight: measured).expandedFrame.height
        XCTAssertEqual(view.size.height, expected)
        XCTAssertGreaterThan(view.size.height, 330)
        XCTAssertLessThan(view.size.height, measured)
        coordinator.setModuleExtended(false, descriptor: descriptor)
        XCTAssertEqual(view.size.height, 330)
    }
}
