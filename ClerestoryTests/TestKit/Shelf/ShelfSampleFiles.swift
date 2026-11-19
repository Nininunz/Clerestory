import AppKit

/// Synthetic, disposable documents and artwork. Never reads personal files.
@MainActor
enum ShelfSampleFiles {
    static private(set) var generatedDirectory: URL?
    static let shared = Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clerestory-sample-files-\(UUID().uuidString)", isDirectory: true)
        let urls = try create(in: directory)
        generatedDirectory = directory
        return urls
    }

    static let manyItems = Result { try variants(count: 40, longNames: false) }
    static let longNames = Result { try variants(count: 8, longNames: true) }

    private static func variants(count: Int, longNames: Bool) throws -> [URL] {
        let sources = try shared.get()
        let directory = sources[0].deletingLastPathComponent()
            .appendingPathComponent(longNames ? "Long filenames" : "Project collection", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try createCollection(in: directory, count: count, longNames: longNames)
    }

    static func create(in directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let landscape = directory.appendingPathComponent("Coastal study.png")
        try artwork(size: NSSize(width: 1200, height: 800), to: landscape) {
            NSColor(calibratedRed: 0.73, green: 0.85, blue: 0.89, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
            NSColor(calibratedRed: 1, green: 0.87, blue: 0.58, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 850, y: 515, width: 150, height: 150)).fill()
            NSColor(calibratedRed: 0.17, green: 0.43, blue: 0.53, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1200, height: 390).fill()
            for (offset, color) in [(0.0, NSColor(calibratedRed: 0.15, green: 0.31, blue: 0.32, alpha: 1)), (-180.0, NSColor(calibratedRed: 0.34, green: 0.49, blue: 0.42, alpha: 1))] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: 0))
                path.line(to: NSPoint(x: 0, y: 600 + offset))
                path.curve(to: NSPoint(x: 950, y: 0), controlPoint1: NSPoint(x: 500, y: 500 + offset), controlPoint2: NSPoint(x: 430, y: 120))
                path.close(); color.setFill(); path.fill()
            }
        }
        let dashboard = directory.appendingPathComponent("Studio dashboard.png")
        try artwork(size: NSSize(width: 1280, height: 800), to: dashboard) {
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1280, height: 800).fill()
            label("NORTHLINE / STUDIO", at: NSPoint(x: 64, y: 700), size: 22, color: .lightGray)
            label("Project overview", at: NSPoint(x: 64, y: 620), size: 44, color: .white)
            for (i, value) in ["12 projects", "84% complete", "6 reviews"].enumerated() {
                let x = CGFloat(64 + i * 390)
                NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 410, width: 360, height: 150), xRadius: 20, yRadius: 20).fill()
                label(value, at: NSPoint(x: x + 28, y: 465), size: 30, color: .white)
            }
            label("Weekly activity", at: NSPoint(x: 64, y: 325), size: 24, color: .lightGray)
            for (i, height) in [70, 120, 95, 165, 150, 205, 180, 240].enumerated() {
                NSColor(calibratedRed: 0.43, green: 0.74, blue: 0.91, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 64 + i * 145, y: 60, width: 100, height: height), xRadius: 8, yRadius: 8).fill()
            }
        }
        let brief = directory.appendingPathComponent("Northline - project brief.rtf")
        try writeProjectDocument(title: "Project brief", project: "Northline",
                                 goal: "a coastal design studio launch",
                                 deliverable: "Identity concepts, a landing page, and launch templates", seed: 0, to: brief)
        let notes = directory.appendingPathComponent("Kickoff notes.txt")
        try planningNotes(project: "Northline", goal: "a coastal design studio launch",
                          deliverable: "Identity concepts, a landing page, and launch templates", seed: 0)
            .write(to: notes, atomically: true, encoding: .utf8)
        let budget = directory.appendingPathComponent("Production budget.csv")
        try budgetCSV(project: "Northline", seed: 0).write(to: budget, atomically: true, encoding: .utf8)
        let folder = directory.appendingPathComponent("Brand assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Northline palette\nOcean #2B6E87\nSand #F6D895\nPine #265054\n".write(to: folder.appendingPathComponent("Palette.txt"), atomically: true, encoding: .utf8)
        return [landscape, brief, dashboard, notes, budget, folder]
    }

    static func label(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
    }

    static func artwork(size: NSSize, to url: URL, draw: () -> Void) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        draw()
        image.unlockFocus()
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ShelfSampleFiles", code: 1)
        }
        try png.write(to: url)
    }
}
