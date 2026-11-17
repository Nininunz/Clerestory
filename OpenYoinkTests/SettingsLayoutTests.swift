import AppKit
import SwiftUI
import XCTest
@testable import OpenYoink

@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testPanelAndNotchPagesFitMinimumSettingsWidth() async throws {
        let suite = "SettingsLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.experimentalModulesEnabled = true
        let monitor = HotKeyMonitor(onPress: {}, onDoublePress: {})
        for dark in [false, true] {
            for (name, page) in [("Panel", AnyView(PanelSettingsTab())),
                                 ("Notch", AnyView(NotchSettingsTab()))] {
                // Minimum window width (680), maximum sidebar width (188), divider.
                let host = NSHostingView(rootView: page.environment(settings).environment(monitor)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 491, height: 480),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1, name)
                XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height, name)

            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
