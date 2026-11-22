import AppKit
import XCTest
@testable import Clerestory

@MainActor
final class IslandWindowDiagnosticsTests: XCTestCase {
    func testMissingOnlyWhenAppKitShowsTheWindowButTheWindowServerDoesNot() {
        let onScreen = IslandWindowDiagnostics.WindowServerState(isOnScreen: true, layer: 33, alpha: 1)
        let offScreen = IslandWindowDiagnostics.WindowServerState(isOnScreen: false, layer: 33, alpha: 1)
        XCTAssertTrue(IslandWindowDiagnostics.isMissingFromScreen(appKitVisible: true, windowServer: offScreen))
        XCTAssertFalse(IslandWindowDiagnostics.isMissingFromScreen(appKitVisible: true, windowServer: onScreen))
        XCTAssertFalse(IslandWindowDiagnostics.isMissingFromScreen(appKitVisible: false, windowServer: offScreen))
        // Without a window server entry there is nothing to compare.
        XCTAssertFalse(IslandWindowDiagnostics.isMissingFromScreen(appKitVisible: true, windowServer: nil))
    }

    func testWindowServerStateFollowsOrderingInAndOut() async throws {
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 80, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        // The window server registers a newly ordered window asynchronously.
        let registered = await state(of: window) { $0?.isOnScreen == true }
        let shown = try XCTUnwrap(registered)
        XCTAssertEqual(shown.layer, window.level.rawValue)
        window.orderOut(nil)
        let hidden = await state(of: window) { $0?.isOnScreen != true }
        XCTAssertNotEqual(hidden?.isOnScreen, true)
        XCTAssertNil(IslandWindowDiagnostics.windowServerState(windowNumber: 0))
    }

    private func state(of window: NSWindow,
                       until done: (IslandWindowDiagnostics.WindowServerState?) -> Bool) async
        -> IslandWindowDiagnostics.WindowServerState? {
        var state = IslandWindowDiagnostics.windowServerState(windowNumber: window.windowNumber)
        var attempts = 0
        while !done(state), attempts < 40 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(25))
            state = IslandWindowDiagnostics.windowServerState(windowNumber: window.windowNumber)
        }
        return state
    }

    func testLogDescriptions() {
        XCTAssertEqual(IslandWindowDiagnostics.describe(nil), "unknown")
        XCTAssertEqual(IslandWindowDiagnostics.describe(.init(isOnScreen: false, layer: 33, alpha: 1)),
                       "no layer=33 alpha=1.0")
        XCTAssertEqual(IslandWindowDiagnostics.displayDescription(for: nil), "none")
    }
}
