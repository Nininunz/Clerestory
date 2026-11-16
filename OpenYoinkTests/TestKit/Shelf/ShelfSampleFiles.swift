import AppKit

/// Synthetic, disposable documents and artwork. Never reads personal files.
@MainActor
enum ShelfSampleFiles {
    static private(set) var generatedDirectory: URL?
    static let shared = Result {
        let directory = URL(fileURLWithPath: "/tmp/openyoink-sample-files-\(UUID().uuidString)", isDirectory: true)
        let urls = try create(in: directory)
        generatedDirectory = directory
        return urls
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
        let brief = directory.appendingPathComponent("Northline — project brief.rtf")
        let text = NSMutableAttributedString(string: "NORTHLINE STUDIO\nProject brief\n\nCoastal identity refresh\nNovember 2026 · Draft 03\n\nOverview\nCreate a calm, approachable identity for a fictional coastal design studio. The system should work across print, web, and small-screen interfaces.\n\nDeliverables\n• Identity concepts and color studies\n• Responsive landing page\n• Social launch templates\n\nMilestones\nDiscovery — November 18\nConcept review — November 25\nFinal handoff — December 4\n\nSuccess criteria\nClear typography, accessible contrast, and consistent spacing across every surface.\n\nSynthetic sample document for OpenYoink previews.\n", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 28), range: (text.string as NSString).range(of: "Project brief"))
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: brief)
        let notes = directory.appendingPathComponent("Kickoff notes.txt")
        try """
        NORTHLINE — KICKOFF NOTES
        November 16, 2026

        Agenda
        1. Confirm project scope and audience
        2. Review the coastal color studies
        3. Agree on the first milestone

        Decisions
        - Keep navigation simple and labels short.
        - Use the blue-green palette as the starting point.
        - Prepare two concepts for next week's review.

        Next steps
        [ ] Draft wireframes
        [ ] Collect typography samples
        [ ] Schedule concept review

        Fictional project. Generated test content only.
        """.write(to: notes, atomically: true, encoding: .utf8)
        let budget = directory.appendingPathComponent("Production budget.csv")
        try "Category,Description,Quantity,Unit Cost,Total\nDesign,Identity concepts,3,450,1350\nWeb,Landing page,1,1800,1800\nPrint,Sample cards,250,2,500\nPhotography,Studio session,1,600,600\nTotal,,,,4250\n".write(to: budget, atomically: true, encoding: .utf8)
        let folder = directory.appendingPathComponent("Brand assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Northline palette\nOcean #2B6E87\nSand #F6D895\nPine #265054\n".write(to: folder.appendingPathComponent("Palette.txt"), atomically: true, encoding: .utf8)
        return [landscape, brief, dashboard, notes, budget, folder]
    }

    private static func label(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
    }

    private static func artwork(size: NSSize, to url: URL, draw: () -> Void) throws {
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
