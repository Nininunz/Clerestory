import AppKit

extension ShelfSampleFiles {
    static func writeProjectDocument(title: String, project: String, goal: String,
                                     deliverable: String, seed: Int, checklist: Bool = false,
                                     accent: NSColor = .systemTeal, to url: URL) throws {
        let sections: [(String, String)] = checklist ? [
            ("Production scope", "This checklist covers \(deliverable.lowercased()) for \(goal). Review the complete package rather than approving isolated pages. The final materials should agree on names, dates, terminology, and visual hierarchy. Keep an editable source and an exported proof together so that the team can trace every approved change."),
            ("Content checks", "☐ Confirm every heading against the approved content list.\n☐ Proofread names, dates, locations, and contact details.\n☐ Replace temporary copy and remove internal review comments.\n☐ Check unusually long titles at their final size.\n☐ Confirm that repeated instructions use the same wording.\n\nRead the document once for meaning and again for small errors. These are separate checks; neither should be skipped because the other passed."),
            ("Layout checks", "☐ Inspect margins and spacing on every page.\n☐ Confirm that headings remain attached to their paragraphs.\n☐ Check captions beside both light and dark artwork.\n☐ Review tables with the longest expected entries.\n☐ Print or display a proof at actual size.\n\nA layout that looks balanced while zoomed out may still be difficult to read at its intended viewing distance."),
            ("Accessibility review", "Use written labels as well as color to distinguish important states. Check text contrast on all background treatments, including tinted panels and images. Read the content in its intended order and confirm that supporting information follows the relevant instruction. Ask someone unfamiliar with \(project) to identify the main action without an explanation."),
            ("Output specifications", "Batch reference: \(seed + 100)\nPlanned quantity: \(50 + seed * 5)\nPaper stock: uncoated, \(120 + seed % 6 * 20) gsm\nProof size: actual output dimensions\n\nVerify image resolution, font inclusion, and page order in the exported file. Do not rely solely on the appearance inside the authoring application. Check the first page, the last page, and a dense middle page."),
            ("Review and approval", "Collect feedback in one review log. Each entry should identify the affected page, describe the problem, and record the proposed correction. Resolve conflicting requests with the project owner before changing the master file. Approval applies to the named revision only; a later export must be checked again if its content or layout changes."),
            ("Packaging", "☐ Include editable sources and linked artwork.\n☐ Include the approved exported proof.\n☐ Add a short revision history and known limitations.\n☐ Confirm that filenames identify their purpose.\n☐ Open the package from a different location.\n\nAvoid dependencies on a personal desktop folder or an application-specific cache. A recipient should be able to inspect the material without reconstructing the creator's workspace."),
            ("Handoff and follow-up", "Walk through the package with the receiving team and explain which files are intended for editing, review, and distribution. Record any remaining questions before delivery. After the first production run, inspect a sample and compare it with the approved proof. Keep that result with the project record so future revisions have a reliable reference.")
        ] : [
            ("Project overview", "Develop \(deliverable.lowercased()) for \(goal). The work should make the experience easier to understand before adding decorative detail. This brief defines the first release and the evidence needed for approval. It is intended to help design, content, and production contributors make compatible decisions without requiring a meeting for every small change."),
            ("Audience and context", "The primary audience includes first-time visitors with limited knowledge of \(project). They may encounter the material while moving, comparing options, or asking for help. Returning participants need faster access to familiar details. The system should support both groups through a clear hierarchy rather than separate, inconsistent versions of the same information."),
            ("Scope and deliverables", "The initial package contains \(deliverable.lowercased()), an editable source set, and a short usage guide. Include one complete example with realistic content, two layout alternatives, and a compact proof for review. Additional formats are outside the initial scope until the main information structure has been approved. Track new requests separately so the first release remains achievable."),
            ("Content requirements", "Write headings that describe the content beneath them. Place essential instructions before background explanation, and keep related details together. Test the structure with both brief and detailed entries. At least one example must include a long title, a dense paragraph, and a multi-step instruction. These examples should expose layout weaknesses before production begins."),
            ("Visual direction", "Use a limited palette and a consistent type hierarchy. Supporting graphics should clarify the subject rather than compete with the main message. Establish repeatable rules for alignment, spacing, captions, and emphasis. Review the system in grayscale as well as color. A successful direction should remain recognizable across large posters, small labels, and digital layouts."),
            ("Review milestones", "Discovery review: November \(17 + seed % 7)\nConcept review: November \(23 + seed % 6)\nProduction review: December \(2 + seed % 5)\n\nEach review should answer a specific question. Discovery confirms the problem and audience. Concept review compares the proposed structure and visual direction. Production review checks complete content, technical output, and handoff readiness. Record decisions before moving to the next stage."),
            ("Acceptance criteria", "A new participant should identify the purpose and next action without assistance. Important text must remain readable at the intended size. Long names and missing optional details must not disrupt the overall structure. Exported files must open independently with correct fonts, images, and page order. The final package should include enough guidance for routine updates by another contributor."),
            ("Risks and dependencies", "Late content changes may affect page count, spacing, and production estimates. Confirm essential names and dates early, and mark uncertain details clearly in working files. Allow time for one complete proof after the last content revision. If a dependency remains unresolved, document the limitation and its impact rather than silently treating an assumption as approved."),
            ("Delivery notes", "Keep the approved revision separate from exploratory concepts. Include sources, exported proofs, a change log, and a short explanation of recurring layout decisions. The recipient should know which files can be edited and which are ready for distribution. Schedule a follow-up after the first use to identify practical issues that were not visible during review.")
        ]
        let document = NSMutableAttributedString(string: "\(project.uppercased())\n\(title)\nRevision \(seed + 1) · Synthetic project document\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 14)])
        document.addAttributes([.font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: accent],
                               range: (document.string as NSString).range(of: title))
        for (heading, body) in sections {
            document.append(NSAttributedString(string: heading + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: accent]))
            document.append(NSAttributedString(string: body + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]))
        }
        document.append(NSAttributedString(string: "All project details are fictional test data.", attributes: [.font: NSFont.systemFont(ofSize: 10)]))
        try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
    }

    static func budgetCSV(project: String, seed: Int) -> String {
        let phases = [
            ("Discovery", ["Kickoff session", "Audience interviews", "Reference research", "Content inventory"]),
            ("Content", ["Outline preparation", "Draft copy", "Copy review", "Final proofreading"]),
            ("Design", ["Concept exploration", "Layout development", "Illustration studies", "Design revisions"]),
            ("Validation", ["Participant recruitment", "Usability sessions", "Accessibility review", "Findings summary"]),
            ("Production", ["Source cleanup", "Artwork preparation", "Export checks", "Proof corrections"]),
            ("Materials", ["Paper samples", "Test prints", "Display mockups", "Packaging supplies"]),
            ("Delivery", ["Source packaging", "Usage guide", "Handoff session", "Archive preparation"]),
            ("Follow-up", ["Launch support", "Feedback review", "Minor adjustments", "Final retrospective"])
        ]
        func row(_ values: [String]) -> String {
            values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        var rows = [row(["Project", "Phase", "Line item", "Quantity", "Unit", "Unit cost", "Total", "Status", "Notes"])]
        var total = 0
        for (phaseIndex, phase) in phases.enumerated() {
            for (index, title) in phase.1.enumerated() {
                let quantity = 2 + (seed + phaseIndex + index * 2) % 9
                let rate = 30 + seed % 7 * 5 + phaseIndex * 10 + index * 5
                let amount = quantity * rate
                total += amount
                rows.append(row([project, phase.0, title, "\(quantity)", phase.0 == "Materials" ? "packs" : "hours",
                                 "\(rate)", "\(amount)", ["Estimated", "Reviewed", "Approved"][(seed + index) % 3],
                                 "\(title) for \(project), revision \(seed + 1)"]))
            }
        }
        rows.append(row([project, "Total", "All phases", "", "", "", "\(total)", "", "Synthetic estimate; USD"]))
        return rows.joined(separator: "\n") + "\n"
    }
}
