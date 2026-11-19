import AppKit
import SwiftUI
import XCTest
@testable import Clerestory

/// Owns the outer layout, capture handshake, gallery, and manifest.
@MainActor
final class ModulePreviewRenderer {
    private var configuration: [String: Any] = [:]
    var output = URL(fileURLWithPath: "/tmp/clerestory-module-previews", isDirectory: true)
    private var manifest: [[String: String]] = []
    private var sheets: [(String, String)] = []

    init() throws {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/clerestory-preview-request.json")) {
            configuration = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if let path = configuration["output"] as? String { output = URL(fileURLWithPath: path, isDirectory: true) }
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    func finish() throws {
        if let directory = ShelfSampleFiles.generatedDirectory {
            try JSONSerialization.data(withJSONObject: ["shelf": directory.path], options: [.prettyPrinted])
                .write(to: output.appendingPathComponent("samples.json"), options: .atomic)
        }
        let html = """
        <!doctype html><meta charset="utf-8"><title>Clerestory module state previews</title>
        <style>body{background:#171717;color:#eee;font:16px system-ui;margin:32px}img{max-width:100%;height:auto}nav a{color:#aaa;margin-right:18px}section{margin:48px 0}</style>
        <h1>Clerestory module state previews</h1><p>Actual module views with isolated sample data. Buttons are the real controls; these images are static. Each panel shows the initial scroll position. No invented loading/error screens.</p>
        <nav>\(sheets.map { "<a href='#\($0.0)'>\($0.1)</a>" }.joined())</nav>
        \(sheets.map { "<section id='\($0.0)'><h2>\($0.1)</h2><img loading='lazy' src='\($0.0).png'></section>" }.joined())
        """
        try html.write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertFalse(manifest.isEmpty, "No scenarios match the requested module/scenario filters")
    }

    func export(_ slug: String, _ title: String, _ states: [ModuleScenario]) async throws {
        guard Set(states.map(\.id)).count == states.count else {
            throw NSError(domain: "PreviewCatalog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Duplicate scenario IDs in \(slug)"])
        }
        let modules = configuration["modules"] as? [String] ?? []
        guard modules.isEmpty || modules.contains(slug) else { return }
        let filters = configuration["scenarios"] as? [String] ?? []
        let descriptor = try XCTUnwrap(ModulePreviewHost.descriptor(for: slug))
        let captures = states.flatMap { scenario in
            (descriptor.supportsExtendedHeight ? [false, true] : [false]).map {
                ModulePreviewCapture(scenario: scenario, extended: $0, supportsExtension: descriptor.supportsExtendedHeight)
            }
        }.filter { capture in
            filters.isEmpty || filters.contains {
                capture.label.localizedCaseInsensitiveContains($0) || capture.id.localizedCaseInsensitiveContains($0)
            }
        }
        guard !captures.isEmpty else { return }
        let capturesWindow = configuration["capture"] as? String == "window"
        var images: [NSImage] = []
        for state in captures {
            let name = state.id
            let filename = "\(slug)-\(name).png"
            manifest.append(["module": slug, "scenario": state.label, "id": state.id, "scenarioID": state.scenario.id, "heightMode": state.extended ? "extended" : "regular", "image": filename])
            if configuration["list"] as? Bool == true { continue }
            let content = try state.scenario.makeView()
            let coordinator = IslandActivityCoordinator()
            coordinator.selectedModule = descriptor.id
            coordinator.setModuleExtended(state.extended, descriptor: descriptor)
            let view = ModulePreviewHost(descriptor: descriptor, coordinator: coordinator, content: content.view, dropTarget: content.dropTarget, messages: content.messages)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2000, y: -2000), size: view.size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = host
            defer { window.close() }
            if capturesWindow { window.center() }
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            // Allow the real scroll view to report intrinsic content height, then
            // resize using the same coordinator and screen cap as the app.
            for _ in 0..<6 {
                let target = view.size
                if window.contentView?.bounds.size != target {
                    window.setContentSize(target)
                    if capturesWindow { window.center() }
                }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let captureSize = view.size
            manifest[manifest.count - 1]["height"] = String(Double(captureSize.height))
            manifest[manifest.count - 1]["width"] = String(Double(captureSize.width))
            let image: NSImage
            let destination = output.appendingPathComponent(filename)
            if capturesWindow {
                try await Task.sleep(for: .milliseconds(250))
                let request = output.appendingPathComponent("capture-\(UUID().uuidString).json")
                let response = request.deletingPathExtension().appendingPathExtension("done")
                try JSONSerialization.data(withJSONObject: ["window": window.windowNumber, "path": destination.path])
                    .write(to: request, options: .atomic)
                let deadline = Date().addingTimeInterval(20)
                while !FileManager.default.fileExists(atPath: response.path) && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let result = try String(contentsOf: response, encoding: .utf8)
                guard result == "ok" else {
                    throw NSError(domain: "PreviewCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: result])
                }
                image = try XCTUnwrap(NSImage(contentsOf: destination))
                image.size = captureSize
            } else {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
                image = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: captureSize)
            }
            images.append(image)
        }
        guard !images.isEmpty else { return }
        // Keep large feedback catalogs below bitmap limits and practical memory sizes.
        let pageSize = 12
        let pageCount = (images.count + pageSize - 1) / pageSize
        for page in 0..<pageCount {
            let first = page * pageSize
            let end = min(first + pageSize, images.count)
            let pageSlug = page == 0 ? slug : "\(slug)-\(page + 1)"
            let pageTitle = pageCount == 1 ? title : "\(title) · \(page + 1) / \(pageCount)"
            let gallery = VStack(alignment: .leading, spacing: 16) {
                Text(pageTitle).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text("Live outer layout • navigation band reserved • sample data").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                ForEach(0..<((end - first + 1) / 2), id: \.self) { row in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach((first + row * 2)..<min(first + row * 2 + 2, end), id: \.self) { index in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(captures[index].label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                                Image(nsImage: images[index])
                            }
                        }
                    }
                }
            }.padding(20).background(Color(white: 0.12))
            let renderer = ImageRenderer(content: gallery)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(pageSlug).png"))
            sheets.append((pageSlug, pageTitle))
        }
    }
}
