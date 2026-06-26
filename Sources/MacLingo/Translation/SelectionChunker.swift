import Foundation

/// Splits a block's inline runs into translation chunks that each fit an **encoded
/// budget** (spec §6.5). Primary split is on block boundaries (the caller iterates
/// blocks); this handles the **secondary** split of a single oversized block:
/// sentence → word → grapheme cluster, in that order, never mid-grapheme.
///
/// The contract that matters: concatenating every piece's runs reproduces the
/// input runs **exactly** — no characters added or lost, no line breaks introduced
/// or dropped (spec §6.5 line-break safety). Pieces are contiguous slices, so the
/// provider rejoins them by simple concatenation + `mergeAdjacent`.
enum SelectionChunker {

    /// Split `runs` into ordered pieces, each measured (on its concatenated text)
    /// within `budget`. Runs that already fit are packed greedily; a single run
    /// larger than the budget is broken at the coarsest safe boundary that fits.
    ///
    /// - Parameters:
    ///   - measure: encoded size of a string (tokens or UTF-8 bytes — `EncodedSize`).
    static func split(
        runs: [InlineRun], budget: Int, measure: (String) -> Int
    ) -> [[InlineRun]] {
        let safeBudget = max(budget, 1)

        // 1. Break any single oversized run into sub-runs that each fit, preserving
        //    text and style exactly.
        var units: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if measure(run.text) <= safeBudget {
                units.append(run)
            } else {
                for piece in splitText(run.text, budget: safeBudget, measure: measure) {
                    units.append(InlineRun(piece, style: run.style))
                }
            }
        }
        guard !units.isEmpty else { return [runs] }

        // 2. Greedily pack consecutive units into pieces under the budget.
        var pieces: [[InlineRun]] = []
        var current: [InlineRun] = []
        var currentText = ""
        for unit in units {
            let combined = currentText + unit.text
            if !current.isEmpty, measure(combined) > safeBudget {
                pieces.append(current)
                current = [unit]
                currentText = unit.text
            } else {
                current.append(unit)
                currentText = combined
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Split a single string into contiguous substrings that each fit `budget`,
    /// preferring to break after sentence punctuation, then after whitespace, then
    /// (for unbroken scripts) at a grapheme boundary. Concatenation reproduces the
    /// input exactly.
    static func splitText(_ text: String, budget: Int, measure: (String) -> Int) -> [String] {
        let safeBudget = max(budget, 1)
        let graphemes = Array(text)
        guard !graphemes.isEmpty else { return [] }

        let sentenceBreaks = breakIndices(graphemes, after: sentenceTerminators, requireSpaceNext: false)
        let wordBreaks = breakIndices(graphemes, after: [], requireSpaceNext: true)

        var pieces: [String] = []
        var start = 0
        while start < graphemes.count {
            func fits(upTo: Int) -> Bool { measure(String(graphemes[start..<upTo])) <= safeBudget }
            // Grow `end` as far as the budget allows (at least one grapheme).
            var end = start + 1
            while end < graphemes.count, fits(upTo: end + 1) { end += 1 }
            // Back off to the coarsest preferred boundary within (start, end].
            if end < graphemes.count {
                if let boundary = lastBreak(in: sentenceBreaks, after: start, atMost: end) {
                    end = boundary
                } else if let boundary = lastBreak(in: wordBreaks, after: start, atMost: end) {
                    end = boundary
                }
            }
            pieces.append(String(graphemes[start..<end]))
            start = end
        }
        return pieces
    }

    // MARK: - Boundary helpers

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "。", "！", "？", "…", "\n",
    ]

    /// Indices **after** which a break is allowed. With `requireSpaceNext`, a break
    /// is allowed after any character followed by whitespace (word boundary);
    /// otherwise it's allowed after any character in `terminators`.
    private static func breakIndices(
        _ graphemes: [Character], after terminators: Set<Character>, requireSpaceNext: Bool
    ) -> [Int] {
        var indices: [Int] = []
        for index in 0..<graphemes.count {
            let character = graphemes[index]
            let allowed: Bool
            if requireSpaceNext {
                allowed = character.isWhitespace
            } else {
                allowed = terminators.contains(character)
            }
            if allowed { indices.append(index + 1) }
        }
        return indices
    }

    /// The largest break index that is `> after` and `<= atMost`, or `nil`.
    private static func lastBreak(in breaks: [Int], after: Int, atMost: Int) -> Int? {
        var best: Int?
        for index in breaks where index > after && index <= atMost {
            best = index
        }
        return best
    }
}
