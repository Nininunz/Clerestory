import AppKit
import CryptoKit
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
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertEqual(csvText.split(separator: "\n").count, 34)
        XCTAssertTrue(csvText.contains("All phases"))
        XCTAssertGreaterThan(document.string.split(whereSeparator: \.isWhitespace).count, 500)
        let folder = try XCTUnwrap(urls.first { $0.hasDirectoryPath })
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Palette.txt").path))
    }

    func testLargeGridAndLongNamesUseDistinctRealFiles() throws {
        for (scenario, count) in [(ShelfScenario.manyItems, 40), (.longNames, 8)] {
            let fixture = try ShelfScenarioFixture(scenario)
            let items = fixture.store.items
            XCTAssertEqual(items.count, count)
            let urls = try items.map { try XCTUnwrap($0.fileURL) }
            XCTAssertEqual(Set(urls).count, count)
            XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertTrue(items.allSatisfy { $0.kind != .text && $0.displayName == $0.fileURL?.lastPathComponent })
            XCTAssertTrue(items.contains { $0.kind == .image })
            XCTAssertTrue(items.contains { $0.kind == .folder })
            if scenario == .longNames { XCTAssertTrue(items.allSatisfy { $0.displayName.count > 90 }) }
        }
        let snippets = try ShelfScenarioFixture(.textSnippets)
        XCTAssertTrue(snippets.store.items.allSatisfy { $0.kind == .text && $0.fileURL == nil })
    }

    func testGeneratedCollectionsDoNotReuseFileContents() throws {
        let urls = try ShelfSampleFiles.manyItems.get() + ShelfSampleFiles.longNames.get()
        var payloads = Set<Data>()
        for url in urls {
            let files = url.hasDirectoryPath
                ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                : [url]
            var bytes = Data()
            for file in files { bytes.append(try Data(contentsOf: file)) }
            XCTAssertTrue(payloads.insert(Data(SHA256.hash(data: bytes))).inserted,
                          "Repeated contents: \(url.lastPathComponent)")
        }
        XCTAssertEqual(payloads.count, 48)
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
