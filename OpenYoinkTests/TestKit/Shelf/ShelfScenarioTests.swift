import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfScenarioTests: XCTestCase {
    func testGeneratedSamplesContainReadableDocumentsAndImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try ShelfSampleFiles.create(in: root)
        XCTAssertEqual(urls.count, 6)
        for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        for url in urls where url.pathExtension == "png" {
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            XCTAssertGreaterThanOrEqual(image.size.width, 1200)
            XCTAssertGreaterThanOrEqual(image.size.height, 800)
        }
        let brief = try XCTUnwrap(urls.first { $0.pathExtension == "rtf" })
        let document = try NSAttributedString(url: brief, options: [:], documentAttributes: nil)
        XCTAssertTrue(document.string.contains("Project brief"))
        let csv = try XCTUnwrap(urls.first { $0.pathExtension == "csv" })
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains("4250"))
        let folder = try XCTUnwrap(urls.first { $0.hasDirectoryPath })
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Palette.txt").path))
    }

    func testFixturesAreIndependentAndSelectionDoesNotLeak() throws {
        let selected = try ShelfScenarioFixture(.selected)
        let fresh = try ShelfScenarioFixture(.populated)
        XCTAssertEqual(selected.store.selection.count, 2)
        XCTAssertTrue(fresh.store.selection.isEmpty)
        XCTAssertTrue(Set(selected.store.items.map(\.id)).isDisjoint(with: fresh.store.items.map(\.id)))
    }

    func testStackSelectionCanBeClearedWithoutChangingParentSelection() throws {
        let fixture = try ShelfScenarioFixture(.stackSelection)
        let parent = try XCTUnwrap(fixture.interaction.expandedStackID)
        XCTAssertEqual(fixture.interaction.childSelection.count, 2)
        XCTAssertEqual(fixture.store.selection, [parent])
        XCTAssertTrue(fixture.interaction.clearActiveSelection(in: fixture.store))
        XCTAssertTrue(fixture.interaction.childSelection.isEmpty)
        XCTAssertEqual(fixture.store.selection, [parent])
        XCTAssertEqual(fixture.interaction.expandedStackID, parent)
    }

    func testDuplicateStateAndSearchDoNotMutateContents() throws {
        let duplicate = try ShelfScenarioFixture(.duplicate)
        XCTAssertTrue(duplicate.dropTarget.isTargeted)
        XCTAssertTrue(duplicate.dropTarget.hasDuplicateFiles)
        XCTAssertFalse(duplicate.dropTarget.isReordering)
        XCTAssertEqual(duplicate.store.items.count, 7)
        let search = try ShelfScenarioFixture(.noResults)
        XCTAssertTrue(search.store.visibleItems.isEmpty)
        XCTAssertEqual(search.store.items.count, 7)
        search.store.searchQuery = ""
        XCTAssertEqual(search.store.visibleItems.count, 7)
    }

    func testScenarioCatalogHasUniqueStableIDs() {
        let context = PreviewContext()
        defer { context.cleanUp() }
        let scenarios = ShelfScenario.allCases.map { $0.scenario(context: context) }
        XCTAssertEqual(Set(scenarios.map(\.id)).count, scenarios.count)
        XCTAssertTrue(scenarios.contains { $0.id == "expanded-stack" })
        XCTAssertTrue(scenarios.contains { $0.id == "duplicate" })
    }
}
