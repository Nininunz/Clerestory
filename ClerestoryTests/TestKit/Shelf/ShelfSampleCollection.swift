import AppKit

extension ShelfSampleFiles {
    /// Each entry is authored from its own project data; no copied sample payloads.
    static func createCollection(in directory: URL, count: Int, longNames: Bool) throws -> [URL] {
        let projects = ["Harbor market", "Alpine trails", "Orbit observatory", "Juniper kitchen", "Metro festival", "Cinder workshop"]
        let goals = ["a weekend food market", "a mountain walking guide", "a public astronomy program", "a seasonal restaurant menu", "a city music festival", "a ceramics workshop"]
        let deliverables = ["Vendor map and wayfinding", "Trail markers and route cards", "Star charts and event posters", "Menu layout and ingredient labels", "Stage schedule and ticket artwork", "Class handouts and glaze samples"]
        let colors: [NSColor] = [.systemTeal, .systemGreen, .systemIndigo, .systemOrange, .systemPink, .systemBrown]
        return try (0..<count).map { index in
            let seed = index + (longNames ? 40 : 0)
            let projectIndex = (seed / 8) % projects.count
            let project = projects[projectIndex]
            let type = seed % 8
            let title = ["Area study", "Creative brief", "Progress report", "Planning notes", "Cost estimate", "Reference pack", "Event poster", "Production checklist"][type]
            let ext = ["png", "rtf", "png", "txt", "csv", "", "png", "rtf"][type]
            let suffix = longNames ? " - stakeholder review with accessibility annotations and final production specifications version \(seed + 1)" : ""
            let name = "\(project) - \(title)\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
            let url = directory.appendingPathComponent(name, isDirectory: type == 5)
            let accent = colors[projectIndex]
            switch type {
            case 0:
                try artwork(size: NSSize(width: 1200, height: 800), to: url) {
                    accent.withAlphaComponent(0.18).setFill()
                    NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
                    if projectIndex == 0 || projectIndex == 4 {
                        // A neighborhood map, with a distinct street grid and highlighted route.
                        for i in 0..<6 {
                            for j in 0..<4 {
                                accent.withAlphaComponent(CGFloat(2 + (i + j + seed) % 5) / 10).setFill()
                                NSBezierPath(roundedRect: NSRect(x: 40 + i * 195, y: 40 + j * 170, width: 155, height: 130), xRadius: 12, yRadius: 12).fill()
                            }
                        }
                        let route = NSBezierPath(); route.move(to: NSPoint(x: 110, y: 90))
                        route.line(to: NSPoint(x: 110, y: 510)); route.line(to: NSPoint(x: 900, y: 510))
                        route.lineWidth = 16; NSColor.white.setStroke(); route.stroke()
                    } else if projectIndex == 2 {
                        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
                        NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
                        for i in 0..<70 {
                            NSColor.white.withAlphaComponent(CGFloat(3 + i % 7) / 10).setFill()
                            NSBezierPath(ovalIn: NSRect(x: (i * 173 + seed * 13) % 1150, y: (i * 97) % 680, width: 4 + i % 5, height: 4 + i % 5)).fill()
                        }
                        for i in 0..<4 {
                            accent.withAlphaComponent(0.8).setStroke()
                            NSBezierPath(ovalIn: NSRect(x: 250 - i * 50, y: 220 - i * 35, width: 400 + i * 100, height: 220 + i * 70)).stroke()
                        }
                    } else {
                        for layer in 0..<5 {
                            accent.blended(withFraction: CGFloat(layer) / 6, of: .black)!.setFill()
                            let path = NSBezierPath(); path.move(to: .zero)
                            for step in 0...8 {
                                let y = CGFloat(120 + (step * 73 + layer * 131 + seed * 11) % 340 + layer * 35)
                                path.line(to: NSPoint(x: CGFloat(step * 150), y: y))
                            }
                            path.line(to: NSPoint(x: 1200, y: 0)); path.close(); path.fill()
                        }
                    }
                    label(project.uppercased(), at: NSPoint(x: 45, y: 730), size: 28, color: .white)
                }
            case 2:
                try artwork(size: NSSize(width: 1200, height: 800), to: url) {
                    NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
                    NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
                    label(project, at: NSPoint(x: 60, y: 690), size: 40, color: .white)
                    label("Production progress · Week \(projectIndex + 2)", at: NSPoint(x: 60, y: 630), size: 23, color: .lightGray)
                    for i in 0..<8 {
                        let height = 100 + (seed * 19 + i * 61) % 350
                        accent.setFill()
                        NSBezierPath(roundedRect: NSRect(x: 60 + i * 140, y: 90, width: 92, height: height), xRadius: 10, yRadius: 10).fill()
                        label("\(height / 5)%", at: NSPoint(x: 60 + i * 140, y: 110 + height), size: 18, color: .white)
                    }
                }
            case 6:
                try artwork(size: NSSize(width: 800, height: 1100), to: url) {
                    accent.setFill(); NSRect(x: 0, y: 0, width: 800, height: 1100).fill()
                    NSColor.white.withAlphaComponent(0.18).setFill()
                    for i in 0..<4 {
                        NSBezierPath(ovalIn: NSRect(x: -150 + i * 180, y: 320 + (i % 2) * 100, width: 400, height: 400)).fill()
                    }
                    label(project.uppercased().replacingOccurrences(of: " ", with: "\n"), at: NSPoint(x: 55, y: 750), size: 62, color: .white)
                    label("OPEN STUDIO / \(18 + projectIndex) NOV", at: NSPoint(x: 55, y: 120), size: 25, color: .white)
                    label("Explore. Make. Share.", at: NSPoint(x: 55, y: 70), size: 23, color: .white)
                }
            case 1, 7:
                try writeProjectDocument(title: title, project: project, goal: goals[projectIndex],
                                         deliverable: deliverables[projectIndex], seed: seed,
                                         checklist: type == 7, accent: accent, to: url)
            case 3:
                let content = planningNotes(project: project, goal: goals[projectIndex],
                                            deliverable: deliverables[projectIndex], seed: seed)
                try content.write(to: url, atomically: true, encoding: .utf8)
            case 4:
                try budgetCSV(project: project, seed: seed).write(to: url, atomically: true, encoding: .utf8)
            default:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try "\(project) reference pack\n\(deliverables[projectIndex])\nCollection \(seed + 1)\n".write(to: url.appendingPathComponent("Read me.txt"), atomically: true, encoding: .utf8)
                let tasks = ["Confirm audience", "Inventory content", "Collect references", "Review terminology",
                             "Prepare outline", "Draft concepts", "Build layouts", "Create artwork",
                             "Review copy", "Test readability", "Check accessibility", "Collect feedback",
                             "Revise proofs", "Approve outputs", "Package sources", "Complete handoff"]
                var scope = ["Project,Task,Sequence,Owner,Status"]
                for (index, task) in tasks.enumerated() {
                    scope.append("\(project),\(task),\(index + 1),\(["Design", "Content", "Production"][index % 3]),\(index < seed % 8 ? "Complete" : "Planned")")
                }
                try (scope.joined(separator: "\n") + "\n").write(to: url.appendingPathComponent("Scope.csv"), atomically: true, encoding: .utf8)
            }
            return url
        }
    }
}
