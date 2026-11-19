import AppKit

/// Optional destination override for module-specific drops. When active it
/// owns the complete drop decision, so a rejected file cannot silently fall
/// through into the shared ShelfStore behind another module's UI.
@MainActor
struct DragContainerDropOverride {
    let isActive: @MainActor () -> Bool
    let canHandle: @MainActor (DragContainerDropContext) -> Bool
    let perform: @MainActor (DragContainerDropContext) -> Bool
    var reset: @MainActor () -> Void = {}
}

@MainActor
struct DragContainerDropContext {
    let pasteboard: NSPasteboard
    let location: CGPoint
    let isInternal: Bool
    let internalItems: [ShelfItem]?
}

/// Drag position/hover/insert state, driven by `DragContainerView` (NSDraggingDestination),
/// and injected via `@Environment` to `ShelfView` for rendering drop highlight and insertion guide line
/// (S3 reserved style).
@MainActor
@Observable
final class DropTargetState {
    /// A drag is hovering over the shelf and can be accepted.
    var isTargeted = false
    var hasDuplicateFiles = false
    private var destinationOwner: UUID?
    /// Insert position (target index card front edge; equal to items.count draws after the last card
    /// edge).
    var insertionIndex: Int?
    /// F-05: Current hover drag mode (⌘ pressed is .move), drives `ShelfView`'s
    /// highlight color and 'release to move/add reference' prompt.
    var mode: DropInMode = .copy
    /// Internal Shelf-card drags reorder existing items instead of importing.
    var isReordering = false

    func target(destination: UUID) {
        destinationOwner = destination
        isTargeted = true
    }

    func leave(destination: UUID) {
        guard destinationOwner == destination else { return }
        reset()
    }

    func reset() {
        destinationOwner = nil
        isTargeted = false
        hasDuplicateFiles = false
        insertionIndex = nil
        mode = .copy
        isReordering = false
    }
}

/// Drag Container for Shelf panel: NSView subclass implementing `NSDraggingDestination` (consistency
/// inherited from NSView), wraps the NSHostingController view of `ShelfView` and is placed into
/// `ShelfPanel`.
///
/// Responsibilities (Implementation Plan §2.3 'Drag In'):
/// - Register all types in `PasteboardTypes.dragInTypes` (fileURL / file promise / text family / image
/// family / URL + wide generic coverage from task one, 'universal drag in');
/// - When hovering, pass the highlight and insertion position to `DropTargetState` → ShelfView;
/// - Internal Shelf-card drags reorder existing items without importing;
///   external drops call `DropImportCoordinator`, synchronously adding items
///   and finishing asynchronous materializations through callbacks.
///
/// Insertion position (S10/C6): `draggingEntered/Updated` converts the mouse position (in this view's
/// coordinates, with lower-left as origin) to window .global (upper-left as origin) coordinates, aligns it
/// with the card frame reported by `ShelfGridGeometry`, and passes it to `DropInsertionLocator` to
/// calculate the row and column insertion index, driving the `insertionIndex` indicator line in ShelfView
/// in real time; if the grid's bottom area or geometry is not ready, it falls back to 'append to the end'
/// (Yoink semantics).
@MainActor
final class DragContainerView: NSView {
    private let destinationID = UUID()
    private static let reorderActivationRatio: CGFloat = 0.10
    private let store: ShelfStore
    private let coordinator: DropImportCoordinator
    private let dropTargetState: DropTargetState
    /// S10: Card grid geometry (reported by SwiftUI), used for drag-in insertion positioning.
    private let gridGeometry: ShelfGridGeometry
    private let dropOverride: DragContainerDropOverride?
    private let onDestinationEntered: (Int) -> Void
    private let onDestinationEnded: (Int, Bool) -> Void
    private let onNativeShelfDrag: () -> Void
    private let isApproachZone: Bool
    private var currentDestinationSequenceNumber: Int?
    /// Smoothed travel of the dragged card center, used to tell a horizontal
    /// find-the-slot move from a vertical row change.
    private var reorderTravel = CGVector.zero
    private var lastReorderCenter: CGPoint?
    /// The hosted controller that is retained (addSubview only retains the view, the controller needs to
    /// be explicitly retained).
    private let contentViewController: NSViewController

    init(store: ShelfStore,
         coordinator: DropImportCoordinator,
         dropTargetState: DropTargetState,
         gridGeometry: ShelfGridGeometry,
         dropOverride: DragContainerDropOverride? = nil,
         onDestinationEntered: @escaping (Int) -> Void = { _ in },
         onDestinationEnded: @escaping (Int, Bool) -> Void = { _, _ in },
         onNativeShelfDrag: @escaping () -> Void = {},
         isApproachZone: Bool = false,
         contentViewController: NSViewController) {
        self.store = store
        self.coordinator = coordinator
        self.dropTargetState = dropTargetState
        self.gridGeometry = gridGeometry
        self.dropOverride = dropOverride
        self.onDestinationEntered = onDestinationEntered
        self.onDestinationEnded = onDestinationEnded
        self.onNativeShelfDrag = onNativeShelfDrag
        self.isApproachZone = isApproachZone
        self.contentViewController = contentViewController
        super.init(frame: .zero)

        // The Island paints only its custom silhouette. Keep both AppKit host
        // layers genuinely transparent so the rectangular NSView bounds never
        // become a gray plate behind the screen-attached surface.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let contentView = contentViewController.view
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        registerForDraggedTypes(PasteboardTypes.dragInTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DragContainerView is created programmatically")
    }

    nonisolated static func acceptsApproachPayload(_ types: [NSPasteboard.PasteboardType], isApproachZone: Bool) -> Bool {
        !isApproachZone || PasteboardTypes.hasShelfApproachContent(in: types)
    }

    // MARK: - NSDraggingDestination

    private func isInsideInteractionSurface(_ sender: NSDraggingInfo) -> Bool {
        guard let panel = window as? ShelfPanel, panel.interactionInset > 0 else { return true }
        return panel.containsInteractionPoint(panel.convertPoint(toScreen: sender.draggingLocation))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let panel = window as? ShelfPanel, panel.interactionInset > 0 {
            let inWindow = convert(convert(point, from: superview), to: nil)
            guard panel.containsInteractionPoint(panel.convertPoint(toScreen: inWindow)) else { return nil }
        }
        // The temporary approach zone has an empty child controller. Make
        // the registered destination itself own every point in that zone.
        if isApproachZone {
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isInsideInteractionSurface(sender) else { return [] }
        guard Self.acceptsApproachPayload(sender.draggingPasteboard.types ?? [], isApproachZone: isApproachZone) else { return [] }
        if PasteboardTypes.hasShelfApproachContent(in: sender.draggingPasteboard.types ?? []) {
            onNativeShelfDrag()
        }
        currentDestinationSequenceNumber = sender.draggingSequenceNumber
        onDestinationEntered(sender.draggingSequenceNumber)
        if let dropOverride, dropOverride.isActive() {
            guard dropOverride.canHandle(dropContext(sender)) else {
                dropTargetState.reset()
                return []
            }
            dropTargetState.target(destination: destinationID)
            dropTargetState.insertionIndex = nil
            dropTargetState.mode = .copy
            dropTargetState.isReordering = false
            return .copy
        }
        if let source = shelfReorderSource(from: sender) {
            resetReorderTravel()
            dropTargetState.target(destination: destinationID)
            dropTargetState.mode = .copy
            dropTargetState.isReordering = true
            updateReorderInsertionIndex(sender, source: source)
            return .copy
        }
        // Ordinary internal drags are not imported back into the shelf. A
        // Shelf reorder is handled above; tutorial drags retain their import
        // path so onboarding can finish normally.
        guard sender.draggingSource == nil
                || coordinator.acceptsInternalTutorialDrag(sender.draggingPasteboard) else {
            return []
        }
        guard Self.hasImportableContent(sender.draggingPasteboard) else { return [] }
        dropTargetState.target(destination: destinationID)
        dropTargetState.isReordering = false
        updateDropMode(sender)
        updateDuplicateFeedback(sender)
        updateExternalInsertionIndex(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isInsideInteractionSurface(sender) else {
            draggingExited(sender)
            return []
        }
        guard Self.acceptsApproachPayload(sender.draggingPasteboard.types ?? [], isApproachZone: isApproachZone) else { return [] }
        if PasteboardTypes.hasShelfApproachContent(in: sender.draggingPasteboard.types ?? []) {
            onNativeShelfDrag()
        }
        // The global monitor delivers drag-start on the main actor. Repeating
        // this idempotent registration also covers entering before that delivery.
        onDestinationEntered(sender.draggingSequenceNumber)
        if let dropOverride, dropOverride.isActive() {
            guard dropOverride.canHandle(dropContext(sender)) else {
                dropTargetState.reset()
                return []
            }
            dropTargetState.target(destination: destinationID)
            dropTargetState.isReordering = false
            return .copy
        }
        if let source = shelfReorderSource(from: sender) {
            dropTargetState.target(destination: destinationID)
            dropTargetState.isReordering = true
            updateReorderInsertionIndex(sender, source: source)
            return .copy
        }
        guard sender.draggingSource == nil
                || coordinator.acceptsInternalTutorialDrag(sender.draggingPasteboard) else {
            return []
        }
        guard Self.hasImportableContent(sender.draggingPasteboard) else { return [] }
        dropTargetState.target(destination: destinationID)
        dropTargetState.isReordering = false
        // F-05: ⌘ state may change during dragging, refresh mode in real time (highlight tone / prompt
        // switches accordingly).
        updateDropMode(sender)
        updateDuplicateFeedback(sender)
        // C6: Insertion position is updated in real time during dragging (row and column mapping see
        // DropInsertionLocator).
        updateExternalInsertionIndex(sender)
        // Always return .copy, even for a Command-drop. CutMoveService copies the file and moves
        // the original to Trash. Returning .move would also tell Finder to remove the original
        // after the drop. ShelfView shows the actual mode in its drop prompt.
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        resetReorderTravel()
        dropTargetState.leave(destination: destinationID)
        dropOverride?.reset()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isInsideInteractionSurface(sender) && Self.acceptsApproachPayload(sender.draggingPasteboard.types ?? [], isApproachZone: isApproachZone)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isInsideInteractionSurface(sender) else { return false }
        guard Self.acceptsApproachPayload(sender.draggingPasteboard.types ?? [], isApproachZone: isApproachZone) else { return false }
        var accepted = false
        defer { onDestinationEnded(sender.draggingSequenceNumber, accepted) }
        if let dropOverride, dropOverride.isActive() {
            guard dropOverride.canHandle(dropContext(sender)) else { return false }
            accepted = dropOverride.perform(dropContext(sender))
            if accepted { (sender.draggingSource as? DragSessionController)?.acceptedByFolderCopy = true }
            return accepted
        }
        if let source = shelfReorderSource(from: sender) {
            updateReorderInsertionIndex(sender, source: source)
            let destination = dropTargetState.insertionIndex ?? store.items.count
            accepted = store.move(ids: source.topLevelItemIDs, toOffset: destination)
            if accepted { source.acceptShelfReorder() }
            return accepted
        }
        // Use the live modifier keys at drop time to choose the import mode. Command selects a managed
        // move for regular files. Always import tutorial files as references, even if Command is held, so
        // practice files remain outside Trash and managed storage.
        let mode: DropInMode = coordinator.acceptsInternalTutorialDrag(sender.draggingPasteboard)
            ? .copy
            : DropImportCoordinator.dropMode(for: sender.draggingPasteboard,
                                              modifiers: NSEvent.modifierFlags)
        let result = coordinator.importItems(
            from: sender.draggingPasteboard,
            mode: mode,
            onManagedMoveReady: { [weak self] item in
                self?.commitManagedMove(item) ?? false
            },
            onPromisedItemReady: { [weak self] item in
                self?.commitPromisedItem(item) ?? false
            }
        ) { [weak self] item in
            // Asynchronous materialization completion (promise / image data / cut failure fallback): add
            // one by one to the shelf.
            guard let self else { return }
            self.coordinator.addDroppedItems([item], to: self.store)
        }
        guard result.handled else { return false }
        // C6: Synchronously insert the item into the position indicated by the indicator line (append to
        // the end if no indicator line is present).
        coordinator.addDroppedItems(result.items, to: store, at: dropTargetState.insertionIndex)
        coordinator.noteSynchronousTutorialImport(from: sender.draggingPasteboard,
                                                   items: result.items)
        accepted = true
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // Cancellation, rejection, or a drop elsewhere has no perform callback.
        // After perform this is an idempotent no-op in the session state machine.
        onDestinationEnded(sender.draggingSequenceNumber, false)
        guard currentDestinationSequenceNumber == sender.draggingSequenceNumber else { return }
        currentDestinationSequenceNumber = nil
        resetReorderTravel()
        dropTargetState.leave(destination: destinationID)
        dropOverride?.reset()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        resetReorderTravel()
        dropTargetState.leave(destination: destinationID)
        dropOverride?.reset()
    }

    // MARK: - Helpers

    private func updateDuplicateFeedback(_ sender: NSDraggingInfo) {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        dropTargetState.hasDuplicateFiles = dropTargetState.mode == .copy
            && urls.contains { store.containsFileReference(at: $0) }
    }

    private func dropContext(_ sender: NSDraggingInfo) -> DragContainerDropContext {
        .init(pasteboard: sender.draggingPasteboard,
              location: CGPoint(x: sender.draggingLocation.x, y: bounds.height - sender.draggingLocation.y),
              isInternal: sender.draggingSource != nil,
              internalItems: (sender.draggingSource as? DragSessionController)?.itemsForFolderCopy)
    }

    /// F-05: Read real-time modifier keys (`NSEvent.modifierFlags`) to refresh hover mode during the drag
    /// session (changes with ⌘ press and release); only drag-and-drop with fileURL may be .move.
    private func updateDropMode(_ sender: NSDraggingInfo) {
        dropTargetState.mode = DropImportCoordinator.dropMode(for: sender.draggingPasteboard,
                                                              modifiers: NSEvent.modifierFlags)
    }

    /// C6: Map the drag mouse position to the grid insertion index. `draggingLocation` is in the
    /// coordinate system of this view (panel contentView) (origin at bottom-left); card frame is reported
    /// by SwiftUI with window `.global` (origin at top-left) —— this view fills the window content area,
    /// flipping y to align.
    @discardableResult
    private func updateExternalInsertionIndex(_ sender: NSDraggingInfo) -> Int {
        let location = sender.draggingLocation
        let point = CGPoint(x: location.x, y: bounds.height - location.y)
        let insertionIndex = insertionIndex(for: point)
        dropTargetState.insertionIndex = insertionIndex
        return insertionIndex
    }

    /// Internal reorder follows the dragged card center rather than the mouse
    /// pointer, so grabbing any edge of a wide card behaves symmetrically.
    private func updateReorderInsertionIndex(_ sender: NSDraggingInfo,
                                             source: DragSessionController) {
        let rawLocation = sender.draggingLocation
        let offset = source.dragAnchorOffset
        let centerLocation = CGPoint(x: rawLocation.x + offset.width,
                                     y: rawLocation.y + offset.height)
        let point = CGPoint(x: centerLocation.x,
                            y: bounds.height - centerLocation.y)
        let activation = reorderActivation(following: point)
        let insertionIndex = insertionIndex(
            for: point,
            activation: activation,
            activationRatio: Self.reorderActivationRatio
        )
        dropTargetState.insertionIndex = insertionIndex
    }

    /// Horizontal drags keep the entry-edge thresholds so both directions feel
    /// equally eager. Rows entered from above or below have no horizontal entry
    /// edge: using one leaves the slot about one card off in the travel
    /// direction and forces an extra sideways push, so vertical-dominant drags
    /// fall back to the card's horizontal center.
    private func reorderActivation(following point: CGPoint)
        -> DropInsertionLocator.Activation {
        if let last = lastReorderCenter {
            let dx = point.x - last.x
            let dy = point.y - last.y
            reorderTravel = CGVector(dx: reorderTravel.dx * 0.65 + dx * 0.35,
                                     dy: reorderTravel.dy * 0.65 + dy * 0.35)
        }
        lastReorderCenter = point
        guard abs(reorderTravel.dx) >= abs(reorderTravel.dy),
              reorderTravel.dx != 0 else {
            return .center
        }
        return reorderTravel.dx > 0 ? .leading : .trailing
    }

    private func insertionIndex(for point: CGPoint,
                                activation: DropInsertionLocator.Activation = .center,
                                activationRatio: CGFloat = 0.10) -> Int {
        let frames: [(index: Int, frame: CGRect)] = store.items.enumerated().compactMap { index, item in
            gridGeometry.cardFrames[item.id].map { (index, $0) }
        }
        return DropInsertionLocator.insertionIndex(
            for: point,
            frames: frames,
            itemCount: store.items.count,
            activation: activation,
            activationRatio: activationRatio
        )
    }

    private func shelfReorderSource(from sender: NSDraggingInfo) -> DragSessionController? {
        guard let source = sender.draggingSource as? DragSessionController,
              source.canReorderOnShelf,
              store.visibleItems.count == store.items.count,
              source.topLevelItemIDs.isSubset(of: Set(store.items.map(\.id))),
              !coordinator.acceptsInternalTutorialDrag(sender.draggingPasteboard) else {
            return nil
        }
        return source
    }

    /// A new drag must not inherit the direction of the previous one.
    private func resetReorderTravel() {
        reorderTravel = .zero
        lastReorderCenter = nil
    }

    /// "Drop everything" semantics (task one): After wide fallback registration, almost all drags that
    /// reach here can be materialized into content by the fallback chain, so just declaring any type will
    /// accept highlighting; zero types are rejected.
    private static func hasImportableContent(_ pasteboard: NSPasteboard) -> Bool {
        PasteboardTypes.hasImportableContent(in: pasteboard.types ?? [])
    }

    /// Boundary of ManagedMoveJournal submission: first synchronously save the shelf snapshot containing
    /// the item, then delete the transaction. If writing to disk fails, the item is still added to the
    /// runtime shelf and continues to schedule regular saving, but the journal is retained until next
    /// startup to recover, and the managed copy is continuously protected from cleanup.
    private func commitManagedMove(_ item: ShelfItem) -> Bool {
        do {
            try store.addAndPersistNow(item)
            coordinator.markManagedMoveCommitted(itemID: item.id)
            return true
        } catch {
            store.add(item)
            coordinator.messenger.post(.moveAwaitingSave)
            return false
        }
    }

    /// Promise imports stay in PendingImportJournal until this synchronous
    /// shelf write succeeds. Unlike managed moves, a failed promise commit is
    /// not inserted into memory: Storage > Pending Imports remains the single,
    /// truthful retry path and the in-memory shelf cannot diverge from disk.
    private func commitPromisedItem(_ item: ShelfItem) -> Bool {
        do {
            try store.addAndPersistNow(item)
            return true
        } catch {
            coordinator.messenger.post(.receivedAwaitingRecovery)
            return false
        }
    }
}
