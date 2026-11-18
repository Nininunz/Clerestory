import Foundation

extension ShelfSampleFiles {
    static func planningNotes(project: String, goal: String, deliverable: String, seed: Int) -> String {
        let observations = [
            "Visitors arrive from several streets and need to locate stalls before joining a queue. Vendor names should remain readable above busy displays. A printed map must still make sense when someone folds it in half.",
            "Walkers need to compare routes before leaving the trailhead. Distance, elevation, and estimated time should appear together. Route markers must be recognizable in rain, bright sun, and low evening light.",
            "Families arrive with different levels of astronomy knowledge. Explain what can be seen without specialist equipment before introducing telescope activities. Printed charts need a strong hierarchy that works under dim lighting.",
            "Guests compare dishes quickly and often ask about ingredients. Seasonal changes should be easy to update without rebuilding the whole menu. Allergen notes need to remain clear beside longer descriptions.",
            "Festival visitors move between stages while checking start times on their phones. The schedule must communicate overlaps without relying only on color. Entry points and quiet areas should be easy to locate.",
            "Workshop participants need to distinguish tools, materials, and finished examples. Instructions should follow the order in which someone actually makes an object. Leave space for handwritten observations and drying times."
        ]
        let observation = project == "Northline"
            ? "Prospective clients compare several studios before making contact. The opening page should communicate the studio's approach through concrete examples. Project summaries need to explain the problem and the result without depending on design terminology."
            : observations[(seed / 8) % observations.count]
        return """
        \(project.uppercased()) - WORKING NOTES
        Session \(seed + 1) | November \(16 + seed % 10), 2026
        Status: draft for internal review

        PROJECT CONTEXT
        This session covered preparation for \(goal). The immediate deliverable is \(deliverable.lowercased()). The group agreed to validate the information structure before polishing individual screens or printed pieces. A convincing first draft should explain the experience clearly, even when all decorative elements are removed.

        The review set will include one complete example, several smaller variations, and a short explanation of the choices made. Each example needs enough realistic content to expose awkward line breaks, crowded labels, and missing information. Short placeholder phrases are not sufficient for the next review.

        FIELD OBSERVATIONS
        \(observation)

        Participants should be able to identify the next useful action without reading every paragraph. Supporting information can be quieter, but it must remain available when needed. During the first round, record where people hesitate and what they expect to happen next. Do not explain the interface until they have described their own interpretation.

        DECISIONS AND RATIONALE
        1. Use a consistent title position across all pieces. This helps people recognize related materials when the format or amount of content changes.
        2. Keep essential instructions in plain language. Technical terms may appear in supporting notes, with a brief explanation where appropriate.
        3. Test the layout with short and long names. The design must tolerate realistic variation without changing the overall rhythm of the page.
        4. Treat color as a supporting cue. Labels, symbols, and grouping should still communicate meaning in grayscale or under poor lighting.
        5. Separate current decisions from open questions. Reviewers need to know which details are ready for approval and which still require evidence.

        CONTENT AND PRODUCTION
        Prepare the first draft using the actual headings and approximate text lengths expected in the final version. Include at least one unusually long title and one section with several consecutive paragraphs. Check that the last line of a paragraph is not stranded beside an image or a narrow column.

        For printed materials, review margins, folds, and trimming tolerances at actual size. For digital materials, check small-window layouts and increased text sizes. Export a proof with a clear revision name, then open it independently to confirm that fonts, graphics, and page order survived the export.

        REVIEW PLAN
        The next review will focus on whether someone new to \(project) can understand the main message in a few seconds. Ask each participant to describe the purpose, locate one specific detail, and explain what they would do next. Record their wording rather than reducing every observation to a pass or fail.

        Group findings by recurring problem. A single unusual comment may be useful, but repeated hesitation around the same element deserves priority. Resolve structural problems before adjusting small visual details. Keep a copy of the earlier draft so the team can compare the effect of each change.

        ACTION ITEMS
        [ ] Prepare \(3 + seed % 4) alternative opening layouts.
        [ ] Assemble complete sample content for the main deliverable.
        [ ] Review terminology and remove ambiguous labels.
        [ ] Test with \(4 + seed % 5) participants unfamiliar with the project.
        [ ] Check grayscale output and small-size legibility.
        [ ] Export a proof and inspect it outside the authoring application.
        [ ] Record unresolved questions before the next review.

        OPEN QUESTIONS
        Which information belongs in the first view, and which can wait until someone asks for more detail? What happens when a name is much longer than expected? Can a person recover from a wrong turn without starting over? These questions should be answered with the next set of examples, not only discussed in the meeting.

        HANDOFF NOTES
        Keep editable sources together with exported proofs. Include a brief change log explaining the revision, the reason for it, and any known limitations. The recipient should be able to identify the latest approved version without comparing timestamps across several folders.

        All names, observations, and project details in this document are synthetic test data.
        """
    }
}
