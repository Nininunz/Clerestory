import AppKit

// Separate process: the production receiver correctly rejects ordinary internal drags.
@main
@MainActor
struct DragSourceApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = DragSourceDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class DragSourceDelegate: NSObject, NSApplicationDelegate {
    private var sourceWindow: NSWindow?
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClerestoryDragSource-" + UUID().uuidString)
    private var file: URL { directory.appendingPathComponent("Northline brief.txt") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "Northline brief\nReview the export requirements and delivery checklist.\n".write(to: file, atomically: true, encoding: .utf8)
            showDragSource()
        } catch { fatalError("Could not create drag fixture: \(error)") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: directory)
    }

    func showDragSource() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: CGRect(x: screen.minX + 30, y: screen.midY - 90, width: 260, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.title = "Shelf UI Test Sources"
        window.setAccessibilityIdentifier("uitest.dragSource")
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 180))
        root.addSubview(SourceView(frame: CGRect(x: 20, y: 100, width: 220, height: 56),
                                   identifier: "uitest.drag.file", label: file.lastPathComponent,
                                   writer: file as NSURL))
        let text = NSPasteboardItem()
        text.setString("Northline review notes\nConfirm the export sizes and finish the release checklist.", forType: .string)
        root.addSubview(SourceView(frame: CGRect(x: 20, y: 24, width: 220, height: 56),
                                   identifier: "uitest.drag.text", label: "Northline review notes", writer: text))
        window.contentView = root
        sourceWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class SourceView: NSButton, NSDraggingSource {
    let writer: any NSPasteboardWriting
    private var dragStatus = "idle"

    init(frame: CGRect, identifier: String, label: String, writer: any NSPasteboardWriting) {
        self.writer = writer
        super.init(frame: frame)
        title = label
        bezelStyle = .rounded
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic fixture") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? { dragStatus }

    override func mouseDown(with event: NSEvent) {
        dragStatus = "dragging"
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(CGRect(x: 0, y: 0, width: 32, height: 32),
                              contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        dragStatus = "ended:\(operation.rawValue)"
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
