import Foundation

/// Deterministic source-language aggregation across blocks (spec §3.2). Pure, so
/// the `> 50%` / `.mixed` / `.unknown` rules are unit-tested independently of any
/// engine. Block-wise/chunked translation can detect different languages per
/// block; this collapses them into one `DetectedLanguage`.
enum LanguageAggregator {

    /// One block's contribution: its source text (for the grapheme weight) and the
    /// language the engine detected for it (`nil` when the block had no detection).
    struct BlockDetection: Sendable, Equatable {
        let sourceText: String
        let detected: String?
    }

    /// Aggregate per the spec rules:
    /// 1. Weight each **detected** block by its **non-whitespace grapheme** count;
    ///    undetected blocks are excluded from numerator **and** denominator.
    /// 2. No detected block → `.unknown`.
    /// 3. One language `> 50%` of the detected weight → `.known`; otherwise `.mixed`.
    static func aggregate(_ blocks: [BlockDetection]) -> DetectedLanguage {
        var weightByLanguage: [String: Int] = [:]
        var order: [String] = []  // first-seen order, for stable `.mixed` output

        for block in blocks {
            guard let language = block.detected else { continue }
            if weightByLanguage[language] == nil { order.append(language) }
            weightByLanguage[language, default: 0] += nonWhitespaceGraphemeCount(block.sourceText)
        }

        guard !weightByLanguage.isEmpty else { return .unknown }

        let total = weightByLanguage.values.reduce(0, +)

        // All detected blocks were whitespace-only (weight 0): fall back to identity
        // by distinct language rather than dividing by zero.
        guard total > 0 else {
            return order.count == 1 ? .known(bcp47: order[0]) : .mixed(order)
        }

        if let majority = weightByLanguage.first(where: { $0.value * 2 > total }) {
            return .known(bcp47: majority.key)
        }
        return .mixed(order)
    }

    /// Count of grapheme clusters that are not whitespace/newlines (spec §3.2 step 1).
    static func nonWhitespaceGraphemeCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if !character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                count += 1
            }
        }
    }
}
