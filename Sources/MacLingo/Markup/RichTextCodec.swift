import Foundation

/// RTF/HTML ↔ `FormattedText`, plus the **tagged-segment** encode/decode used to
/// carry inline styling through translation (spec §3.4). Two encodings:
///
/// - **Sentinel tokens** for the plain-text Google Free endpoint — invisible
///   private-use markers wrap each styled run so the translator leaves them intact.
/// - **HTML tags** (`<b>`, `<i>`, `<u>`, `<code>`) for HTML-capable engines (AI,
///   Google Cloud) — wired in Phases 5/6.
///
/// Either way, styling is **never** reapplied by character offset. After
/// translation the output is **structurally validated** (whitelist, balance,
/// matching open/close multiset); on any failure the block **degrades to plain
/// text** (structure preserved) rather than producing wrong styling.
enum RichTextCodec {

    /// The codec encoding version, mirrored into the `CacheKey` (spec §5.1).
    static let codecVersion = TranslationVersioning.codecVersion

    // MARK: - Parse captured rich payloads (sanitized at this step, spec §5.4)

    /// Turn a captured rich payload into `FormattedText`, sanitizing it through
    /// `MarkupSanitizer`. Returns `nil` when it cannot be safely parsed so the
    /// caller falls back to the plain-text capture.
    static func parse(_ rich: CapturedRich) -> FormattedText? {
        switch rich.kind {
        case .rtf:
            return MarkupSanitizer.formattedText(fromRTF: rich.data)
        case .html:
            let html = String(data: rich.data, encoding: .utf8) ?? String(data: rich.data, encoding: .utf16)
            guard let html else { return nil }
            return MarkupSanitizer.formattedText(fromHTML: html)
        }
    }

    // MARK: - Sentinel tokens (Google Free)

    // Private-use-area markers: very unlikely to occur in real text or to be
    // altered by a translator. A styled run `i` becomes  OPEN i SEP  text  CLOSE i SEP.
    private static let open: Character = "\u{E000}"
    private static let close: Character = "\u{E001}"
    private static let sep: Character = "\u{E002}"

    /// Encode a block's styled runs as sentinel-wrapped text for translation. Plain
    /// runs pass through verbatim. If the source already contains a sentinel marker
    /// (pathological), styling is dropped pre-emptively and the plain text returned.
    static func encodeSentinel(_ block: FormattedText.Block) -> String {
        if block.isPlain { return block.text }
        if block.text.contains(where: isSentinel) { return block.text }
        var encoded = ""
        for (runIndex, run) in block.runs.enumerated() where !run.text.isEmpty {
            if run.style.isEmpty {
                encoded += run.text
            } else {
                encoded += "\(open)\(runIndex)\(sep)\(run.text)\(close)\(runIndex)\(sep)"
            }
        }
        return encoded
    }

    /// Decode translated sentinel text back into a styled block, reattaching each
    /// run's original style by token id. On any structural failure the block
    /// degrades to a single plain run with the markers stripped (spec §3.4).
    static func decodeSentinel(_ translated: String, original: FormattedText.Block) -> FormattedText.Block {
        let styleByID = styleByRunID(original)
        guard let runs = parseSentinelRuns(translated, styleByID: styleByID) else {
            return FormattedText.Block(
                index: original.index, runs: [InlineRun(stripSentinels(translated))], kind: original.kind)
        }
        return FormattedText.Block(
            index: original.index, runs: MarkupSanitizer.mergeAdjacent(runs), kind: original.kind)
    }

    /// Build run-id → style for the styled runs that were encoded.
    private static func styleByRunID(_ block: FormattedText.Block) -> [Int: InlineStyle] {
        var map: [Int: InlineStyle] = [:]
        for (runIndex, run) in block.runs.enumerated() where !run.style.isEmpty && !run.text.isEmpty {
            map[runIndex] = run.style
        }
        return map
    }

    /// Parse the translated string into runs, validating sentinel structure. Returns
    /// `nil` on any violation (unknown id, unbalanced, overlapping/nested, or an id
    /// used more than once) — the signal to degrade to plain. The flat state machine
    /// lives in `SentinelParser` to keep this orchestration small.
    private static func parseSentinelRuns(
        _ translated: String, styleByID: [Int: InlineStyle]
    ) -> [InlineRun]? {
        var parser = SentinelParser(styleByID: styleByID)
        var chars = Array(translated)[...]
        while let character = chars.first {
            if character == open || character == close {
                chars = chars.dropFirst()
                guard let id = scanID(&chars), parser.handleMarker(opening: character == open, id: id)
                else { return nil }
            } else if character == sep {
                return nil  // a bare separator with no preceding marker is malformed
            } else {
                parser.append(character)
                chars = chars.dropFirst()
            }
        }
        return parser.finish()
    }

    /// Flat (non-nesting) sentinel state machine: text accumulates into a plain or a
    /// styled buffer depending on whether a marker is currently open.
    private struct SentinelParser {
        private let styleByID: [Int: InlineStyle]
        private var runs: [InlineRun] = []
        private var plain = ""
        private var styled = ""
        private var openID: Int?
        private var seen = Set<Int>()

        init(styleByID: [Int: InlineStyle]) {
            self.styleByID = styleByID
        }

        mutating func append(_ character: Character) {
            if openID == nil { plain.append(character) } else { styled.append(character) }
        }

        /// Returns `false` on any structural violation.
        mutating func handleMarker(opening: Bool, id: Int) -> Bool {
            if opening {
                // No nesting/overlap, known id, used at most once.
                guard openID == nil, styleByID[id] != nil, !seen.contains(id) else { return false }
                if !plain.isEmpty { runs.append(InlineRun(plain)); plain = "" }
                openID = id
                styled = ""
            } else {
                guard openID == id, let style = styleByID[id] else { return false }
                runs.append(InlineRun(styled, style: style))
                seen.insert(id)
                openID = nil
            }
            return true
        }

        /// Returns the parsed runs, or `nil` if a token is unclosed or a styled run
        /// that was sent didn't come back exactly once.
        mutating func finish() -> [InlineRun]? {
            guard openID == nil else { return nil }
            if !plain.isEmpty { runs.append(InlineRun(plain)) }
            guard seen == Set(styleByID.keys) else { return nil }
            return runs
        }
    }

    /// Read the digits + separator that follow an open/close marker.
    private static func scanID(_ chars: inout ArraySlice<Character>) -> Int? {
        var digits = ""
        while let character = chars.first, character.isNumber {
            digits.append(character)
            chars = chars.dropFirst()
        }
        guard chars.first == sep else { return nil }
        chars = chars.dropFirst()  // consume separator
        return Int(digits)
    }

    private static func isSentinel(_ character: Character) -> Bool {
        character == open || character == close || character == sep
    }

    private static func stripSentinels(_ text: String) -> String {
        var result = ""
        var chars = Array(text)[...]
        while let character = chars.first {
            if character == open || character == close {
                chars = chars.dropFirst()
                _ = scanID(&chars)  // drop the id+separator too, best-effort
            } else if character == sep {
                chars = chars.dropFirst()
            } else {
                result.append(character)
                chars = chars.dropFirst()
            }
        }
        return result
    }

    // MARK: - HTML tags (AI / Google Cloud — Phases 5/6)

    /// Encode a block's runs as whitelisted HTML for an HTML-capable engine.
    static func encodeHTML(_ block: FormattedText.Block) -> String {
        block.runs.filter { !$0.text.isEmpty }.map { run in
            wrapHTML(escapeHTML(run.text), style: run.style)
        }
        .joined()
    }

    /// Decode translated HTML back into a styled block. The markup must be
    /// structurally valid (balanced, well-nested allowlisted tags); otherwise the
    /// block degrades to plain text (spec §3.4).
    static func decodeHTML(_ translated: String, original: FormattedText.Block) -> FormattedText.Block {
        guard isWellFormedHTML(translated),
            let parsed = MarkupSanitizer.formattedText(fromHTML: translated)
        else {
            let plain =
                MarkupSanitizer.formattedText(fromHTML: translated)?.plainText
                ?? HTMLTokenizer.decodeEntities(translated)
            return FormattedText.Block(index: original.index, runs: [InlineRun(plain)], kind: original.kind)
        }
        // A single block is expected; flatten any stray block breaks into one.
        let runs = parsed.blocks.flatMap(\.runs)
        return FormattedText.Block(
            index: original.index, runs: MarkupSanitizer.mergeAdjacent(runs), kind: original.kind)
    }

    private static func wrapHTML(_ inner: String, style: InlineStyle) -> String {
        var text = inner
        // Deterministic nesting order.
        if style.contains(.code) { text = "<code>\(text)</code>" }
        if style.contains(.underline) { text = "<u>\(text)</u>" }
        if style.contains(.italic) { text = "<i>\(text)</i>" }
        if style.contains(.bold) { text = "<b>\(text)</b>" }
        return text
    }

    static func escapeHTML(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Validate that the allowlisted style tags in `html` are balanced and properly
    /// nested. Non-allowlisted tags are ignored (the sanitizer strips them); only an
    /// imbalance among style tags is a structural failure.
    private static func isWellFormedHTML(_ html: String) -> Bool {
        let allow: Set<String> = ["b", "strong", "i", "em", "u", "code"]
        var stack: [String] = []
        let chars = Array(html)
        var cursor = 0
        while cursor < chars.count {
            guard chars[cursor] == "<" else { cursor += 1; continue }
            var scan = cursor + 1
            let isClosing = scan < chars.count && chars[scan] == "/"
            if isClosing { scan += 1 }
            var name = ""
            while scan < chars.count, chars[scan].isLetter || chars[scan].isNumber {
                name.append(chars[scan])
                scan += 1
            }
            var selfClosing = false
            while scan < chars.count, chars[scan] != ">" {
                if chars[scan] == "/" { selfClosing = true }
                scan += 1
            }
            name = name.lowercased()
            if allow.contains(name) {
                if isClosing {
                    guard stack.last == name else { return false }
                    stack.removeLast()
                } else if !selfClosing {
                    stack.append(name)
                }
            }
            cursor = (scan < chars.count) ? scan + 1 : scan
        }
        return stack.isEmpty
    }
}
