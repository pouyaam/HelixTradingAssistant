import Foundation

extension PromptBuilder {

    /// Strip every `### XXX_JSON` heading + the immediately-following
    /// ```json fence from `markdown`. The rendered report shows only the
    /// prose; the parsed JSON drives the right-column structured cards
    /// and the chart preview, so the raw payload is implementation
    /// detail the user shouldn't see.
    ///
    /// Idempotent — running it on already-clean text returns the input
    /// unchanged. Tolerates partial fences (a half-streamed block with
    /// no closing ``` yet is dropped from the marker to end-of-string,
    /// so the streaming report doesn't flash a wall of raw JSON before
    /// the closing fence arrives).
    static func stripStructuredBlocks(_ markdown: String) -> String {
        // Order matters: strip the longer "SCENARIOS_JSON" /
        // "ALT_SCENARIO_JSON" markers before the shorter
        // "SCENARIO_JSON" so a partial match can't leave a dangling
        // "S" / "ALT_" prefix behind.
        let markers = [
            "### LEVELS_JSON",
            "### SCENARIOS_JSON",
            "### ALT_SCENARIO_JSON",
            "### SCENARIO_JSON",
            "### FVG_JSON",
            "### SUPPLY_DEMAND_JSON",
            "### CLARIFY_JSON",
        ]
        var result = markdown
        for marker in markers {
            // Loop in case the model emitted the same marker twice
            // (rare, but cheap to defend against).
            while let stripped = stripMarkerAndFence(result, marker: marker) {
                result = stripped
            }
        }
        return result
    }

    /// One-shot strip: find the marker, walk to the line start, then
    /// consume the immediately-following ```…``` fence (or to end-of-
    /// string if the closing fence hasn't streamed in yet). Returns
    /// `nil` when the marker isn't present so the outer loop can stop.
    private static func stripMarkerAndFence(_ s: String, marker: String) -> String? {
        guard let markerRange = s.range(of: marker) else { return nil }

        // Snap to the start of the marker's line so we don't leave a
        // dangling prefix like "Foo bar " in front of the removal.
        let lineStart = s[..<markerRange.lowerBound]
            .lastIndex(of: "\n")
            .map { s.index(after: $0) } ?? s.startIndex

        let tail = s[markerRange.upperBound...]
        let cut: String.Index

        if let firstFence = tail.range(of: "```") {
            let afterFirst = firstFence.upperBound
            if let secondFence = tail.range(of: "```", range: afterFirst..<tail.endIndex) {
                cut = secondFence.upperBound
            } else {
                // Closing fence hasn't arrived yet (still streaming).
                // Drop everything from the marker to end-of-string so
                // the user doesn't see a half-rendered JSON wall.
                cut = tail.endIndex
            }
        } else {
            // Marker is present but no fence yet — same fallback.
            cut = tail.endIndex
        }

        return String(s[..<lineStart]) + "\n" + String(s[cut...])
    }
}
