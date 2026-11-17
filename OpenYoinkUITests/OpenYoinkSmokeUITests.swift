import AppKit
import XCTest

@MainActor
final class OpenYoinkSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // Both fork and upstream builds can intercept the test's drops.
        // Refuse to run over a normal session; never terminate it automatically.
        let testAppURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("OpenYoink.app").resolvingSymlinksInPath()
        let otherBuilds = ["com.nininunz.OpenYoink", "com.weijue.OpenYoink"]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { $0.bundleURL?.resolvingSymlinksInPath() != testAppURL }
        XCTAssertTrue(otherBuilds.isEmpty, "Quit other OpenYoink builds before running UI tests: \(otherBuilds.compactMap { $0.bundleURL?.path })")
    }

    func testShelfLaunchesIntoAccessibleEmptyState() throws {
        let app = launch(surface: "--ui-testing-show-shelf")

        XCTAssertTrue(element("shelf.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("shelf.emptyState", in: app).waitForExistence(timeout: 2))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Empty shelf smoke test"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsSidebarNavigatesToStorage() throws {
        let app = launch(surface: "--ui-testing-open-settings")

        XCTAssertTrue(element("settings.content.general", in: app).waitForExistence(timeout: 5))
        let storage = element("settings.pane.storage", in: app)
        XCTAssertTrue(storage.waitForExistence(timeout: 2))
        storage.click()
        XCTAssertTrue(element("settings.content.storage", in: app).waitForExistence(timeout: 2))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Storage settings smoke test"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPanelAndNotchSettingsHaveSeparateDestinations() throws {
        let app = launch(surface: "--ui-testing-open-settings")
        XCTAssertTrue(element("settings.content.general", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("settings.pane.compact", in: app).label, "Notch")
        XCTAssertFalse(element("settings.showCompactIsland", in: app).exists)
        element("settings.pane.panel", in: app).click()
        XCTAssertTrue(element("settings.panelDisplayBehavior", in: app).waitForExistence(timeout: 3))
        let panelCapture = XCTAttachment(screenshot: app.screenshot())
        panelCapture.name = "Panel settings"
        panelCapture.lifetime = .keepAlways
        add(panelCapture)
        element("settings.pane.compact", in: app).click()
        let companion = element("settings.showCompactIsland", in: app)
        XCTAssertTrue(companion.waitForExistence(timeout: 3))
        XCTAssertEqual(companion.label, "Show in notch")
        let notchCapture = XCTAttachment(screenshot: app.screenshot())
        notchCapture.name = "Notch settings"
        notchCapture.lifetime = .keepAlways
        add(notchCapture)
        let previous = try XCTUnwrap(companion.value as? NSNumber).boolValue
        companion.click()
        let changed = try XCTUnwrap(companion.value as? NSNumber).boolValue
        XCTAssertNotEqual(changed, previous)
        element("settings.pane.panel", in: app).click()
        element("settings.pane.compact", in: app).click()
        XCTAssertEqual(try XCTUnwrap(companion.value as? NSNumber).boolValue, changed)
        XCTAssertFalse(element("settings.pane.triggers", in: app).exists)
        XCTAssertFalse(element("settings.pane.ignoredApps", in: app).exists)
    }

    func testSettingsPassesCoreAccessibilityAudit() throws {
        let app = launch(surface: "--ui-testing-open-settings")
        XCTAssertTrue(element("settings.content.general", in: app).waitForExistence(timeout: 5))

        let popupIdentifiers = [
            "settings.dragOutRemovalPolicy",
            "settings.language",
        ]
        let systemZoomButton = app.buttons.matching(
            identifier: "_XCUI:ZoomWindow"
        ).firstMatch

        try app.performAccessibilityAudit(
            for: [
                .sufficientElementDescription,
                .action,
                .parentChild,
            ],
            { issue in
                // SwiftUI's native macOS Picker is exposed as an actionable
                // PopUpButton and is exercised by testSettingsPopupPickerOpens,
                // but the XCTest audit still reports a missing action.
                // Suppress only that verified framework control; every other
                // issue still fails.
                if issue.auditType.contains(.action),
                   let element = issue.element,
                   element.elementType == .popUpButton,
                   popupIdentifiers.contains(element.identifier) {
                    return true
                }

                // AppKit owns the nested decoration groups inside the green
                // zoom traffic-light button. XCTest reports a parent/child
                // mismatch for that system element on macOS 26.5; scope the
                // exception to a group geometrically contained by that button.
                if issue.auditType.contains(.parentChild),
                   let element = issue.element,
                   element.elementType == .group,
                   systemZoomButton.exists,
                   systemZoomButton.frame.insetBy(dx: -1, dy: -1).contains(element.frame) {
                    return true
                }

                // XCTest includes the disabled, system-generated Touch Bar
                // container in the app hierarchy on Touch Bar Macs even when
                // OpenYoink defines no Touch Bar content.
                if issue.auditType.contains(.sufficientElementDescription),
                   let element = issue.element,
                   element.elementType == .touchBar,
                   !element.isEnabled {
                    return true
                }

                print("AUDIT ISSUE: \(issue.compactDescription)")
                print(issue.element?.debugDescription ?? "No associated element")
                return false
            }
        )
    }

    func testSettingsPopupPickerOpens() throws {
        let app = launch(surface: "--ui-testing-open-settings")

        for (pane, identifier) in [("general", "settings.language")] {
            element("settings.pane.\(pane)", in: app).click()
            let picker = element(identifier, in: app)
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(picker.isHittable)
            picker.click()
            XCTAssertTrue(app.menuItems.firstMatch.waitForExistence(timeout: 2))
            app.typeKey(.escape, modifierFlags: [])
        }
        openShelfSettings(in: app)
        let picker = element("settings.dragOutRemovalPolicy", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isHittable)
        picker.click()
        XCTAssertTrue(app.menuItems.firstMatch.waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testExpandedPinNavigationAndCollapse() throws {
        let app = launch(surface: "--ui-testing-show-shelf")
        let panel = expandedPanel(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let pin = element("island.pin", in: panel)
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.hover()
        XCTAssertTrue(pin.isHittable)
        pin.click()
        assertValue("pinned", of: pin)

        element("island.module.quickSettings", in: panel).click()
        XCTAssertTrue(element("island.shortcut.position.0", in: panel).waitForExistence(timeout: 3))
        XCTAssertEqual(pin.value as? String, "pinned")
        element("island.module.shelf", in: panel).click()
        XCTAssertTrue(element("shelf.emptyState", in: panel).waitForExistence(timeout: 3))

        pin.hover()
        XCTAssertTrue(pin.isHittable)
        pin.click()
        assertValue("unpinned", of: pin)
        element("island.collapse", in: panel).click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
    }

    func testNotchActivationPreservesPinnedExpandedPanel() throws {
        try requireNotchedDisplay()
        let app = launch(surface: "--ui-testing-show-shelf")
        let panel = expandedPanel(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let notch = element("island.window.compact", in: app)
        XCTAssertTrue(notch.waitForExistence(timeout: 3))
        let pin = element("island.pin", in: panel)
        pin.hover()
        XCTAssertTrue(pin.isHittable)
        pin.click()
        assertValue("pinned", of: pin)
        element("island.module.quickSettings", in: panel).click()
        XCTAssertTrue(element("island.shortcut.position.0", in: panel).waitForExistence(timeout: 3))
        // Click a visible wing, outside the physical camera cutout.
        notch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0)).click()
        XCTAssertTrue(element("shelf.emptyState", in: panel).waitForExistence(timeout: 3))
        assertValue("pinned", of: pin)
    }

    func testExpandedPanelWithoutNotch() throws {
        try assertExpandedWithoutNotch(hideNotch: true)
    }

    func testNotchHoverOpensLeavesAndReopens() throws {
        try requireNotchedDisplay()
        let app = launch(surface: "--ui-testing-hover")
        let notch = element("island.window.compact", in: app)
        XCTAssertTrue(notch.waitForExistence(timeout: 3))
        let wing = notch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0))
        let outside = wing.withOffset(CGVector(dx: 0, dy: 600))
        let panel = expandedPanel(in: app)
        outside.hover()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        wing.hover()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        outside.hover()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        wing.hover()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let pin = element("island.pin", in: panel)
        pin.hover()
        XCTAssertTrue(pin.isHittable)
        pin.click()
        assertValue("pinned", of: pin)
        outside.hover()
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: panel)
        disappeared.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 1), .completed)
        assertValue("pinned", of: pin)
        pin.hover()
        pin.click()
        assertValue("unpinned", of: pin)
        outside.hover()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "Unpinning must restore hover dismissal")
        wing.hover()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
    }

    func testExpandedPanelOnSimulatedNotchlessDisplay() throws {
        try assertExpandedWithoutNotch(simulateNoNotch: true)
    }

    func testQuickSettingsOnNotchlessDisplayShowsOnlyPanelEditor() {
        let app = launch(surface: "--ui-testing-show-shelf", simulateNoNotch: true)
        let panel = expandedPanel(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        element("island.pin", in: panel).click()
        element("island.module.quickSettings", in: panel).click()
        XCTAssertTrue(element("island.shortcut.position.0", in: panel).waitForExistence(timeout: 3))
        XCTAssertFalse(panel.buttons["Notch modules"].exists)
        XCTAssertFalse(panel.buttons["Panel shortcuts"].exists)
    }

    func testQuickLookKeepsHoverPanelOpenUntilPreviewCloses() throws {
        try requireNotchedDisplay()
        let app = launch(surface: "--ui-testing-hover", fixtures: ["--ui-testing-shelf-files"])
        let notch = element("island.window.compact", in: app)
        XCTAssertTrue(notch.waitForExistence(timeout: 5))
        notch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0)).hover()
        let panel = expandedPanel(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let first = element("shelf.item.00000000-0000-0000-0000-000000000001", in: panel)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeKey(.space, modifierFlags: [])
        let preview = element("shelf.quickLook", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        notch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 750)).hover()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: panel)
        closed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 1), .completed)
        XCTAssertTrue(preview.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 3))
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
    }

    func testQuickLookKeyboardNavigationAndFocusReturn() throws {
        let app = launch(surface: "--ui-testing-show-shelf", fixtures: ["--ui-testing-shelf-files"])
        let panel = expandedPanel(in: app)
        let first = element("shelf.item.00000000-0000-0000-0000-000000000001", in: panel)
        let second = element("shelf.item.00000000-0000-0000-0000-000000000002", in: panel)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // The fixture is visible; use its center to avoid XCTest auto-scrolling
        // through the panel's custom hit-testing before the pointer enters it.
        let center = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.hover()
        center.click()
        app.typeKey(.space, modifierFlags: [])
        let preview = element("shelf.quickLook", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.staticTexts["Northline brief.txt"].waitForExistence(timeout: 3))
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(preview.staticTexts["Release checklist.txt"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 3))
        // No mouse click: closing Quick Look must return keyboard focus to Shelf.
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(second.isSelected)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(preview.staticTexts["Northline brief.txt"].waitForExistence(timeout: 3))
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 3))
    }

    func testFileDragApproachImportsAndDuplicateShowsNotice() throws {
        try requireNotchedDisplay()
        let app = launch(surface: "--ui-testing-drag-source")
        let helper = launchDragSource()
        let source = element("uitest.drag.file", in: helper)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let notch = element("island.window.compact", in: app)
        XCTAssertTrue(notch.waitForExistence(timeout: 3))
        let panel = expandedPanel(in: app)
        XCTAssertFalse(panel.exists)
        let target = notch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 35))
        drag(source, to: target)
        // Import feedback can close an unpinned panel; reopen to inspect storage.
        notch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0)).click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let cards = shelfCards(in: panel)
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards.firstMatch.label.contains("Northline brief.txt"))
        element("island.collapse", in: panel).click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        drag(source, to: target)
        let duplicate = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'shelf.notice' AND label CONTAINS 'Already on Shelf'")
        ).firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        notch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0)).click()
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, 1, "Duplicate drops must not add a second card")
    }

    func testTextDragApproachCreatesSnippet() throws {
        try requireNotchedDisplay()
        let app = launch(surface: "--ui-testing-drag-source")
        let helper = launchDragSource()
        let source = element("uitest.drag.text", in: helper)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let notch = element("island.window.compact", in: app)
        XCTAssertTrue(notch.waitForExistence(timeout: 3))
        let panel = expandedPanel(in: app)
        XCTAssertFalse(panel.exists)
        drag(source, to: notch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 35)))
        notch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0)).click()
        let cards = shelfCards(in: panel)
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards.firstMatch.label.contains("Northline review notes"))
        XCTAssertTrue(cards.firstMatch.label.contains("Text"))
    }

    func testDuplicateNoticeStaysBelowPinnedPanel() throws {
        try requireNotchedDisplay()
        let app = launch(surface: "--ui-testing-drag-source")
        let helper = launchDragSource()
        let source = element("uitest.drag.file", in: helper)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let notch = element("island.window.compact", in: app)
        XCTAssertTrue(notch.waitForExistence(timeout: 3))
        let target = notch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 35))
        drag(source, to: target)
        notch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0)).click()
        let panel = expandedPanel(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let cards = shelfCards(in: panel)
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        let pin = element("island.pin", in: panel)
        pin.hover()
        pin.click()
        assertValue("pinned", of: pin)
        drag(source, to: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let duplicate = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'shelf.notice' AND label CONTAINS 'Already on Shelf'")
        ).firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.exists)
        assertValue("pinned", of: pin)
        XCTAssertEqual(cards.count, 1)
        let root = element("island.root", in: panel)
        XCTAssertGreaterThan(root.frame.width, 0)
        XCTAssertGreaterThan(root.frame.height, 0)
        XCTAssertTrue(root.frame.maxY.isFinite)
        XCTAssertGreaterThan(duplicate.frame.height, 0)
        XCTAssertTrue(duplicate.frame.minY.isFinite)
        XCTAssertGreaterThanOrEqual(duplicate.frame.minY, root.frame.maxY,
                                   "The notice must sit below the visible panel rather than covering files")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Duplicate notice below pinned panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHoverReentryCancelsPendingDismissal() throws {
        try requireNotchedDisplay()
        let app = launch(surface: "--ui-testing-hover",
                         fixtures: ["-OpenYoink.islandHoverLeaveDelaySeconds", "1"])
        let notch = element("island.window.compact", in: app)
        XCTAssertTrue(notch.waitForExistence(timeout: 3))
        let wing = notch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0))
        let outside = wing.withOffset(CGVector(dx: 0, dy: 600))
        wing.hover()
        let panel = expandedPanel(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        for _ in 0..<3 {
            outside.hover()
            wing.hover()
            XCTAssertTrue(panel.exists)
        }
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: panel)
        disappeared.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 1.2), .completed)
        outside.hover()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        wing.hover()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
    }

    private func launchDragSource() -> XCUIApplication {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("OpenYoinkUITestDragSource.app")
        let helper = XCUIApplication(url: url)
        addTeardownBlock { @MainActor in helper.terminate() }
        helper.launch()
        return helper
    }

    private func shelfCards(in panel: XCUIElement) -> XCUIElementQuery {
        panel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shelf.item.' AND NOT identifier ENDSWITH '.remove'"))
    }

    private func drag(_ source: XCUIElement, to target: XCUICoordinate) {
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1)
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'ended:'"), object: source)
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 5), .completed)
        XCTAssertEqual(source.value as? String, "ended:1", "Native source must complete a copy drop")
    }

    private func assertExpandedWithoutNotch(hideNotch: Bool = false, simulateNoNotch: Bool = false) throws {
        let app = launch(surface: "--ui-testing-show-shelf", hideNotch: hideNotch, simulateNoNotch: simulateNoNotch)
        let panel = expandedPanel(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(element("shelf.emptyState", in: panel).waitForExistence(timeout: 3))
        XCTAssertFalse(element("island.window.compact", in: app).exists)
        element("island.collapse", in: panel).click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
    }

    private func assertValue(_ expected: String, of element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 2), .completed)
    }

    private func requireNotchedDisplay() throws {
        try XCTSkipUnless((NSScreen.main?.safeAreaInsets.top ?? 0) > 0,
                          "Requires a physical notched display")
    }

    private func expandedPanel(in app: XCUIApplication) -> XCUIElement {
        element("island.window.expanded", in: app)
    }

    private func openShelfSettings(in app: XCUIApplication) {
        let modules = element("settings.pane.modules", in: app)
        XCTAssertTrue(modules.waitForExistence(timeout: 5))
        modules.click()
        let shelf = element("settings.module.shelf.open", in: app)
        XCTAssertTrue(shelf.waitForExistence(timeout: 2))
        shelf.click()
    }

    private func launch(surface: String, hideNotch: Bool = false, simulateNoNotch: Bool = false,
                        fixtures: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENYOINK_UI_TESTING"] = "1"
        app.launchArguments = [
            "-OpenYoink.onboardingVersion", "1",
            "-OpenYoink.autoUpdateCheckEnabled", "NO",
            "-AppleLanguages", "(en)",
            "-OpenYoinkSimulateNoNotch", simulateNoNotch ? "YES" : "NO",
            surface,
        ] + (hideNotch ? ["--ui-testing-hide-compact"] : []) + fixtures
        addTeardownBlock { @MainActor in app.terminate() }
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIElement) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
