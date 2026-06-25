import Foundation

/// A minimal, **sanitizing** HTML tokenizer (spec §5.4). It exists precisely so we
/// never hand untrusted HTML to `NSAttributedString`'s importer, which can fetch
/// remote resources. It recognizes only the allowlisted inline tags and block
/// structure; every other tag is dropped (its text content kept), and the contents
/// of `<script>`/`<style>` are discarded. Nothing here triggers a network load.
///
/// Produces a normalized `FormattedText`, or `nil` when caps are exceeded so the
/// caller degrades to plain text.
struct HTMLTokenizer {

    private let chars: [Character]
    private var index = 0

    // Output accumulators.
    private var blocks: [FormattedText.Block] = []
    private var currentRuns: [InlineRun] = []
    private var currentKind: BlockKind = .paragraph

    // Inline style stack — each pushed entry is the bit a tag contributed.
    private var styleStack: [InlineStyle] = []
    // List context stack — `count` is the nesting level, the bool is `ordered`.
    private var listStack: [Bool] = []

    private var nodeCount = 0
    private var overflowed = false

    /// Inline tags that map to a style bit.
    private static let inlineStyles: [String: InlineStyle] = [
        "b": .bold, "strong": .bold,
        "i": .italic, "em": .italic,
        "u": .underline,
        "code": .code,
    ]
    /// Block-level tags whose open/close (or self) finalizes the current block.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]
    /// Tags whose entire text content must be discarded.
    private static let opaqueTags: Set<String> = ["script", "style", "head", "title"]

    init(html: String) {
        self.chars = Array(html)
    }

    mutating func parse() -> FormattedText? {
        while index < chars.count {
            if overflowed { return nil }
            if chars[index] == "<" {
                consumeTag()
            } else {
                consumeText()
            }
        }
        finalizeBlock()
        if overflowed { return nil }
        return FormattedText(blocks: blocks)
    }

    // MARK: - Text

    private mutating func consumeText() {
        var raw = ""
        while index < chars.count && chars[index] != "<" {
            raw.append(chars[index])
            index += 1
        }
        let text = HTMLTokenizer.decodeEntities(collapseWhitespace(raw))
        guard !text.isEmpty else { return }
        appendRun(InlineRun(text, style: currentStyle))
    }

    private var currentStyle: InlineStyle {
        styleStack.reduce(into: InlineStyle()) { $0.formUnion($1) }
    }

    private mutating func appendRun(_ run: InlineRun) {
        bumpNode()
        // Drop a leading space that would only pad the start of a block.
        if currentRuns.isEmpty && run.text == " " { return }
        currentRuns.append(run)
    }

    // MARK: - Tags

    private mutating func consumeTag() {
        // Skip comments and declarations: <!-- ... -->, <!DOCTYPE ...>.
        if matchesAhead("<!--") {
            skipUntil("-->")
            return
        }
        if index + 1 < chars.count && chars[index + 1] == "!" {
            skipUntil(">")
            return
        }

        index += 1  // consume '<'
        let isClosing = (index < chars.count && chars[index] == "/")
        if isClosing { index += 1 }

        var name = ""
        while index < chars.count, chars[index].isLetter || chars[index].isNumber {
            name.append(chars[index])
            index += 1
        }
        name = name.lowercased()

        // Skip the rest of the tag (attributes), noting a self-closing `/>`.
        var selfClosing = false
        while index < chars.count && chars[index] != ">" {
            if chars[index] == "/" { selfClosing = true }
            // Step over quoted attribute values so a '>' inside them doesn't end the tag.
            if chars[index] == "\"" || chars[index] == "'" { skipQuoted(chars[index]) } else { index += 1 }
        }
        if index < chars.count { index += 1 }  // consume '>'

        guard !name.isEmpty else { return }
        handleTag(name: name, isClosing: isClosing, selfClosing: selfClosing)
    }

    private mutating func handleTag(name: String, isClosing: Bool, selfClosing: Bool) {
        if HTMLTokenizer.opaqueTags.contains(name) {
            if !isClosing && !selfClosing { skipOpaqueElement(name) }
            return
        }

        if let style = HTMLTokenizer.inlineStyles[name] {
            if isClosing {
                popStyle(style)
            } else if !selfClosing {
                pushStyle(style)
            }
            return
        }

        handleStructuralTag(name: name, isClosing: isClosing)
    }

    /// Block-level / list tags. Unknown or disallowed tags (img, link, object,
    /// span, a, …) fall through: the tag is dropped, its text kept, no network load.
    private mutating func handleStructuralTag(name: String, isClosing: Bool) {
        switch name {
        case "br":
            finalizeBlock()
        case "ul", "ol":
            if isClosing {
                if !listStack.isEmpty { listStack.removeLast() }
            } else {
                listStack.append(name == "ol")
            }
        case "li":
            finalizeBlock()
            currentKind =
                isClosing
                ? .paragraph
                : .listItem(level: max(1, listStack.count), ordered: listStack.last ?? false)
        case let block where HTMLTokenizer.blockTags.contains(block):
            finalizeBlock()
        default:
            break
        }
    }

    private mutating func pushStyle(_ style: InlineStyle) {
        styleStack.append(style)
        if styleStack.count > MarkupSanitizer.maxNestingDepth { overflowed = true }
    }

    private mutating func popStyle(_ style: InlineStyle) {
        // Pop the nearest matching entry (tolerates mis-nesting without corrupting
        // the rest of the stack).
        if let last = styleStack.lastIndex(of: style) {
            styleStack.remove(at: last)
        }
    }

    // MARK: - Block finalization

    private mutating func finalizeBlock() {
        let merged = MarkupSanitizer.mergeAdjacent(trimEdges(currentRuns))
        currentRuns = []
        let kind = currentKind
        currentKind = .paragraph
        // Drop empty paragraphs (collapsed whitespace / adjacent boundaries); keep
        // empty list items so structure survives.
        let isEmpty = merged.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if isEmpty, case .paragraph = kind { return }
        bumpNode()
        blocks.append(FormattedText.Block(index: blocks.count, runs: merged, kind: kind))
    }

    /// Trim a leading/trailing space introduced by whitespace collapsing.
    private func trimEdges(_ runs: [InlineRun]) -> [InlineRun] {
        var runs = runs
        if var first = runs.first {
            first.text = String(first.text.drop(while: { $0 == " " }))
            runs[0] = first
        }
        if var last = runs.last {
            while last.text.hasSuffix(" ") { last.text.removeLast() }
            if runs.isEmpty == false { runs[runs.count - 1] = last }
        }
        return runs.filter { !$0.text.isEmpty }
    }

    private mutating func bumpNode() {
        nodeCount += 1
        if nodeCount > MarkupSanitizer.maxNodeCount { overflowed = true }
    }

    // MARK: - Scanning helpers

    private mutating func skipOpaqueElement(_ name: String) {
        let close = "</\(name)"
        while index < chars.count {
            if chars[index] == "<" && matchesAhead(close, caseInsensitive: true) {
                consumeTag()
                return
            }
            index += 1
        }
    }

    private mutating func skipQuoted(_ quote: Character) {
        index += 1  // opening quote
        while index < chars.count && chars[index] != quote { index += 1 }
        if index < chars.count { index += 1 }  // closing quote
    }

    private mutating func skipUntil(_ marker: String) {
        let markerChars = Array(marker)
        while index < chars.count {
            if matchesAhead(marker) {
                index += markerChars.count
                return
            }
            index += 1
        }
    }

    private func matchesAhead(_ marker: String, caseInsensitive: Bool = false) -> Bool {
        let markerChars = Array(marker)
        guard index + markerChars.count <= chars.count else { return false }
        for (offset, expected) in markerChars.enumerated() {
            let actual = chars[index + offset]
            if caseInsensitive {
                if String(actual).lowercased() != String(expected).lowercased() { return false }
            } else if actual != expected {
                return false
            }
        }
        return true
    }

    private func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if character == " " || character == "\n" || character == "\t" || character == "\r" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result
    }

    // MARK: - Entities

    /// Decode the common named and numeric HTML entities. Unknown entities are
    /// left verbatim (they carry no markup meaning).
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        let scalars = Array(text)
        var cursor = 0
        while cursor < scalars.count {
            guard scalars[cursor] == "&", let semicolon = scalars[(cursor + 1)...].firstIndex(of: ";"),
                semicolon - cursor <= 10
            else {
                result.append(scalars[cursor])
                cursor += 1
                continue
            }
            let entity = String(scalars[(cursor + 1)..<semicolon])
            if let decoded = decodeEntity(entity) {
                result.append(decoded)
                cursor = semicolon + 1
            } else {
                result.append(scalars[cursor])
                cursor += 1
            }
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> Character? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return "\u{00A0}"
        default: return decodeNumericEntity(entity)
        }
    }

    private static func decodeNumericEntity(_ entity: String) -> Character? {
        let code: UInt32?
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            code = UInt32(entity.dropFirst(2), radix: 16)
        } else if entity.hasPrefix("#") {
            code = UInt32(entity.dropFirst())
        } else {
            code = nil
        }
        guard let code, let scalar = Unicode.Scalar(code) else { return nil }
        return Character(scalar)
    }
}
