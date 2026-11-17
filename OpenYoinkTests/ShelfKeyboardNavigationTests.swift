import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfKeyboardNavigationTests: XCTestCase {
    func testStacksAreDisabledWithoutChangingSelectionOrStoredChildren() {
        let children = ShelfFixtures.notes(count: 3)
        let stack = ShelfItem(kind: .stack, displayName: "Retained stack", children: children)
        let store = ShelfStore(items: [stack])
        store.select(stack.id)
        let interaction = ShelfInteractionState()
        interaction.focusedItemID = stack.id
        interaction.selectionAnchorID = stack.id
        interaction.isSelecting = true

        interaction.enterStack(stack)

        XCTAssertFalse(interaction.stacksEnabled)
        XCTAssertNil(interaction.expandedStackID)
        XCTAssertTrue(interaction.childSelection.isEmpty)
        XCTAssertEqual(interaction.focusedItemID, stack.id)
        XCTAssertEqual(interaction.selectionAnchorID, stack.id)
        XCTAssertTrue(interaction.isSelecting)
        XCTAssertEqual(store.selection, [stack.id])
        XCTAssertEqual(store.items.first?.children?.map(\.id), children.map(\.id))
    }

    func testArrowSelectionReplacesPreviousSelectionAndShiftCanShrinkRange() {
        let items = ShelfFixtures.notes(count: 8)
        let store = ShelfStore(items: items)
        let interaction = ShelfInteractionState()
        store.select(items[0].id)
        interaction.moveSelection(in: items, from: 0, to: 1, extending: false, store: store)
        XCTAssertEqual(store.selection, [items[1].id])
        XCTAssertEqual(interaction.focusedItemID, items[1].id)
        XCTAssertTrue(interaction.showsKeyboardFocus)
        interaction.moveSelection(in: items, from: 1, to: 5, extending: true, store: store)
        XCTAssertEqual(store.selection, Set(items[1...5].map(\.id)))
        interaction.moveSelection(in: items, from: 5, to: 2, extending: true, store: store)
        XCTAssertEqual(store.selection, Set(items[1...2].map(\.id)))
        interaction.moveSelection(in: items, from: 2, to: 3, extending: false, store: store)
        XCTAssertEqual(store.selection, [items[3].id])
        XCTAssertNil(interaction.selectionAnchorID)
    }

    func testStackArrowSelectionDoesNotChangeTopLevelSelection() {
        let children = (0..<3).map { ShelfItem(kind: .text, displayName: "Child \($0)", text: "text") }
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: children)
        let store = ShelfStore(items: [stack])
        store.select(stack.id)
        let interaction = ShelfInteractionState(stacksEnabled: true)
        interaction.enterStack(stack)
        interaction.moveSelection(in: children, from: 0, to: 1, extending: false, store: store)
        XCTAssertEqual(interaction.childSelection, [children[1].id])
        XCTAssertEqual(store.selection, [stack.id])
    }

    func testShiftClickUsesVisibleOrderAndSharesAnchorWithArrows() {
        let items = ShelfFixtures.notes(count: 7)
        let store = ShelfStore(items: items)
        let interaction = ShelfInteractionState()
        let visible = [items[0], items[2], items[4], items[6]]
        interaction.clickSelection(items[2].id, in: visible, additive: false, extending: false, store: store)
        interaction.clickSelection(items[6].id, in: visible, additive: false, extending: true, store: store)
        XCTAssertEqual(store.selection, Set([items[2].id, items[4].id, items[6].id]))
        interaction.moveSelection(in: visible, from: 3, to: 2, extending: true, store: store)
        XCTAssertEqual(store.selection, Set([items[2].id, items[4].id]))
        interaction.clickSelection(items[0].id, in: visible, additive: false, extending: true, store: store)
        XCTAssertEqual(store.selection, Set([items[0].id, items[2].id]))
        XCTAssertFalse(interaction.showsKeyboardFocus)
        interaction.clickSelection(items[0].id, in: visible, additive: true, extending: false, store: store)
        XCTAssertEqual(store.selection, [items[2].id])
    }

    func testClearingSelectionConsumesOnlyFirstEscapeAndResetsFocus() {
        let item = ShelfItem(kind: .text, displayName: "Item", text: "text")
        let store = ShelfStore(items: [item])
        let interaction = ShelfInteractionState()
        interaction.moveSelection(in: [item], from: 0, to: 0, extending: false, store: store)
        XCTAssertTrue(interaction.clearActiveSelection(in: store))
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertNil(interaction.focusedItemID)
        XCTAssertNil(interaction.selectionAnchorID)
        XCTAssertFalse(interaction.showsKeyboardFocus)
        XCTAssertFalse(interaction.clearActiveSelection(in: store))
        interaction.isSelecting = true
        XCTAssertTrue(interaction.clearActiveSelection(in: store))
        XCTAssertFalse(interaction.isSelecting)
    }

    func testStackClickRangeAndClearPreserveParentSelection() {
        let children = (0..<4).map { ShelfItem(kind: .text, displayName: "Child \($0)", text: "text") }
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: children)
        let store = ShelfStore(items: [stack])
        let interaction = ShelfInteractionState(stacksEnabled: true)
        store.select(stack.id)
        interaction.enterStack(stack)
        interaction.clickSelection(children[1].id, in: children, additive: false, extending: false, store: store)
        interaction.clickSelection(children[3].id, in: children, additive: false, extending: true, store: store)
        XCTAssertEqual(interaction.childSelection, Set(children[1...3].map(\.id)))
        XCTAssertTrue(interaction.clearActiveSelection(in: store))
        XCTAssertTrue(interaction.childSelection.isEmpty)
        XCTAssertEqual(interaction.expandedStackID, stack.id)
        XCTAssertEqual(store.selection, [stack.id])
        XCTAssertFalse(interaction.clearActiveSelection(in: store))
    }

    func testTileClickRequestsPanelFocusAndTakesFirstResponderFromTextField() throws {
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                               styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let root = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        let field = NSTextField(frame: NSRect(x: 0, y: 100, width: 180, height: 24))
        let tile = CardDragSourceAnchorView(frame: NSRect(x: 0, y: 0, width: 90, height: 90))
        root.addSubview(field)
        root.addSubview(tile)
        panel.contentView = root
        panel.orderFront(nil)
        panel.makeFirstResponder(field)
        XCTAssertTrue(tile.acceptsFirstMouse(for: nil))
        XCTAssertTrue(tile.needsPanelToBecomeKey)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        tile.mouseDown(with: event)
        XCTAssertTrue(panel.firstResponder === tile)
        XCTAssertTrue(panel.isKeyWindow)
    }

    func testNavigatorMovesAcrossRowsAndClampsAtEdges() {
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 4, itemCount: 8, columnCount: 3, direction: .left), 3)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 4, itemCount: 8, columnCount: 3, direction: .right), 5)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 4, itemCount: 8, columnCount: 3, direction: .up), 1)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 4, itemCount: 8, columnCount: 3, direction: .down), 7)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 0, itemCount: 8, columnCount: 3, direction: .left), 0)
        XCTAssertEqual(ShelfKeyboardNavigator.destinationIndex(
            currentIndex: 7, itemCount: 8, columnCount: 3, direction: .down), 7)
    }

    func testFocusAndSelectionAreIndependentWhenEnteringAndLeavingStack() {
        let children = [
            ShelfItem(kind: .text, displayName: "a", text: "a"),
            ShelfItem(kind: .text, displayName: "b", text: "b")
        ]
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: children)
        let interaction = ShelfInteractionState(stacksEnabled: true)
        interaction.focusedItemID = stack.id
        interaction.childSelection = [children[1].id]

        interaction.enterStack(stack)

        XCTAssertEqual(interaction.expandedStackID, stack.id)
        XCTAssertEqual(interaction.focusedItemID, children[0].id)
        XCTAssertTrue(interaction.childSelection.isEmpty)

        interaction.childSelection = [children[1].id]
        interaction.exitStack()
        XCTAssertEqual(interaction.focusedItemID, stack.id)
        XCTAssertNil(interaction.expandedStackID)
        XCTAssertTrue(interaction.childSelection.isEmpty)
    }

    func testNormalizeDropsOnlyInvalidFocusAndChildSelection() {
        let child = ShelfItem(kind: .text, displayName: "a", text: "a")
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: [child])
        let interaction = ShelfInteractionState(stacksEnabled: true)
        interaction.enterStack(stack)
        interaction.childSelection = [child.id, UUID()]

        interaction.normalize(for: [stack])

        XCTAssertEqual(interaction.focusedItemID, child.id)
        XCTAssertEqual(interaction.childSelection, [child.id])

        interaction.normalize(for: [])
        XCTAssertNil(interaction.expandedStackID)
        XCTAssertNil(interaction.focusedItemID)
        XCTAssertTrue(interaction.childSelection.isEmpty)
    }
}

@MainActor
final class ClipboardControllerTests: XCTestCase {
    private let bookmarks = BookmarkService()

    override func tearDown() {
        bookmarks.stopAccessingAll()
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests.\(UUID().uuidString)"))
    }

    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkClipboard-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCopyTextAndURLWritesOnePasteboardItemPerShelfItem() throws {
        let pasteboard = makePasteboard()
        let items = [
            ShelfItem(kind: .text, displayName: "Text", text: "hello"),
            ShelfItem(kind: .url, displayName: "Example", urlString: "https://example.com")
        ]

        let result = ClipboardController.copy(items,
                                              to: pasteboard,
                                              bookmarkService: bookmarks)

        XCTAssertEqual(result, .init(copiedCount: 2, skippedCount: 0, didWrite: true))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(pasteboard.pasteboardItems?[0].string(forType: PasteboardTypes.plainText),
                       "hello")
        XCTAssertEqual(pasteboard.pasteboardItems?[1].string(forType: PasteboardTypes.url),
                       "https://example.com")
    }

    func testCopyFileUsesNativeFileURLRepresentation() throws {
        let pasteboard = makePasteboard()
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = ShelfItem(kind: .file, path: url.path, displayName: url.lastPathComponent)

        let result = ClipboardController.copy([item],
                                              to: pasteboard,
                                              bookmarkService: bookmarks)

        XCTAssertTrue(result.didWrite)
        XCTAssertEqual(result.copiedCount, 1)
        let copied = pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL
        XCTAssertEqual(copied?.standardizedFileURL, url.standardizedFileURL)
    }

    func testUnavailableOnlySelectionDoesNotDestroyExistingClipboard() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: PasteboardTypes.plainText)
        var item = ShelfItem(kind: .file, path: "/missing", displayName: "missing")
        item.availability = .externalFileOffline

        let result = ClipboardController.copy([item],
                                              to: pasteboard,
                                              bookmarkService: bookmarks)

        XCTAssertEqual(result, .init(copiedCount: 0, skippedCount: 1, didWrite: false))
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.plainText), "keep")
    }

    func testCopyFlattensStackAndSkipsMalformedChildren() {
        let pasteboard = makePasteboard()
        let good = ShelfItem(kind: .text, displayName: "Good", text: "content")
        let bad = ShelfItem(kind: .text, displayName: "Bad", text: "")
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: [good, bad])

        let result = ClipboardController.copy([stack],
                                              to: pasteboard,
                                              bookmarkService: bookmarks)

        XCTAssertEqual(result, .init(copiedCount: 1, skippedCount: 1, didWrite: true))
    }
}
