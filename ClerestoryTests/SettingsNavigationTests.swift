import XCTest
@testable import Clerestory

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testDownContinuesFromTabFocusedPaneRatherThanSelection() {
        let navigation = SettingsNavigationModel()
        navigation.selectedPane = .general

        #if DEBUG
        XCTAssertEqual(navigation.moveSidebarSelection(forward: true, focusedPane: .storage), .debug)
        XCTAssertEqual(navigation.selectedPane, .debug)
        #else
        XCTAssertEqual(navigation.moveSidebarSelection(forward: true, focusedPane: .storage), .about)
        XCTAssertEqual(navigation.selectedPane, .about)
        #endif
    }

    func testUpContinuesFromTabFocusedPaneRatherThanSelection() {
        let navigation = SettingsNavigationModel()
        navigation.selectedPane = .about

        XCTAssertEqual(navigation.moveSidebarSelection(forward: false, focusedPane: .modules), .notch)
        XCTAssertEqual(navigation.selectedPane, .notch)
    }

    func testNoFocusedButtonFallsBackToSelectedPane() {
        let navigation = SettingsNavigationModel()
        navigation.selectedPane = .general

        XCTAssertEqual(navigation.moveSidebarSelection(forward: true, focusedPane: nil), .panel)
        XCTAssertEqual(navigation.moveSidebarSelection(forward: false, focusedPane: nil), .general)
    }

    func testFormerSidebarLinksOpenModuleDetails() {
        let navigation = SettingsNavigationModel()
        for (pane, destination) in [(SettingsPane.shelf, ModuleSettingsDestination.shelf), (.clipboard, .clipboard)] {
            navigation.open(pane)
            XCTAssertEqual(navigation.selectedPane, .modules)
            XCTAssertEqual(navigation.moduleSettingsDestination, destination)
            XCTAssertFalse(SettingsPane.visibleCases.contains(pane))
        }
        navigation.open(.modules)
        XCTAssertNil(navigation.moduleSettingsDestination)
    }

    func testSidebarNavigationLeavesModuleDetail() {
        let navigation = SettingsNavigationModel()
        navigation.open(.clipboard)
        XCTAssertEqual(navigation.moveSidebarSelection(forward: true, focusedPane: .modules), .storage)
        XCTAssertNil(navigation.moduleSettingsDestination)
    }

    func testModuleDestinationsAreUniqueAndExcludeFixedQuickSettings() {
        let ids = ModuleSettingsDestination.allCases.map(\.moduleID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(ids), Set([.shelf, .transfers, .timer, .battery, .system, .media, .folders, .clipboard, .aiUsage]))
        XCTAssertFalse(ids.contains(.quickSettings))
    }

    func testLegacyTriggerAndIgnoreLinksOpenPanel() {
        let navigation = SettingsNavigationModel()
        for pane in [SettingsPane.triggers, .ignoredApps] {
            navigation.open(.clipboard)
            navigation.open(pane)
            XCTAssertEqual(navigation.selectedPane, .panel)
            XCTAssertNil(navigation.moduleSettingsDestination)
            XCTAssertFalse(SettingsPane.visibleCases.contains(pane))
        }
    }

    func testSidebarSeparatesPanelNotchAndModules() {
        XCTAssertEqual(Array(SettingsPane.visibleCases.prefix(5)), [.general, .panel, .notch, .modules, .storage])
    }

    func testArrowsDoNotWrapAtSidebarBoundaries() {
        let navigation = SettingsNavigationModel()
        navigation.selectedPane = .general
        XCTAssertNil(navigation.moveSidebarSelection(forward: false, focusedPane: .general))
        XCTAssertEqual(navigation.selectedPane, .general)

        navigation.selectedPane = .about
        XCTAssertNil(navigation.moveSidebarSelection(forward: true, focusedPane: .about))
        XCTAssertEqual(navigation.selectedPane, .about)
    }
}
