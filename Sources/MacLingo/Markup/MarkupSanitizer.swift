import AppKit
import Foundation

/// Trust boundary for **all** untrusted markup (spec §5.4): captured clipboard
/// HTML, captured RTF, and engine-generated HTML alike. Every path here:
///
/// - keeps **only** the allowlisted inline attributes {bold, italic, underline,
///   code} and block structure {paragraph, line break, list};
/// - strips RTF attachments/images, hyperlinks, embedded objects, fonts, colors,
///   sizes, and `\field`/external-reference constructs;
/// - **never loads a remote resource** — HTML is parsed by a hand-rolled tokenizer
///   (never `NSAttributedString`'s HTML importer, which can fetch); `<img>`,
///   `<link>`, `<object>`, `<script>`, `<style>` and their network-bearing
///   attributes are dropped;
/// - enforces caps on nesting depth and node/character count, rejecting input that
///   blows past them (caller degrades to plain text).
///
/// Output is a normalized `FormattedText`. A `nil` return means "could not safely
/// sanitize — fall back to plain text" (spec §3.4 degrade-to-plain).
enum MarkupSanitizer {

    /// Maximum inline-nesting depth (style stack). Beyond this the input is rejected.
    static let maxNestingDepth = 32
    /// Maximum number of nodes (runs + blocks) produced before rejecting.
    static let maxNodeCount = 10_000
    /// Maximum character count of the *input* before rejecting (cheap pre-check).
    static let maxCharacterCount = 200_000

    // MARK: - Captured RTF

    /// Sanitize captured RTF bytes into `FormattedText`, or `nil` to fall back to
    /// plain text. RTF is parsed via `NSAttributedString` (which does **not** fetch
    /// remote resources for the `.rtf` document type); attachments and disallowed
    /// attributes are then dropped.
    static func formattedText(fromRTF data: Data) -> FormattedText? {
        // Cheap byte cap (RTF is verbose; allow generous headroom over the char cap).
        guard data.count <= maxCharacterCount * 8 else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        else { return nil }
        return formattedText(fromAttributed: attributed)
    }

    /// Walk an `NSAttributedString`, dropping attachments and keeping only
    /// allowlisted traits, then segment into blocks on newlines.
    static func formattedText(fromAttributed attributed: NSAttributedString) -> FormattedText? {
        guard attributed.length <= maxCharacterCount else { return nil }
        var segments: [InlineRun] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            // Drop embedded attachments/images/objects entirely (spec §5.4).
            if attrs[.attachment] != nil { return }
            let text = attributed.attributedSubstring(from: range).string
            guard !text.isEmpty else { return }
            segments.append(InlineRun(text, style: style(forRTFAttributes: attrs)))
        }
        let blocks = blocksFromSegments(segments)
        guard blocks.count + blocks.reduce(0, { $0 + $1.runs.count }) <= maxNodeCount else { return nil }
        return FormattedText(blocks: blocks)
    }

    /// Map RTF/AppKit run attributes to the allowlisted inline style. Everything
    /// not on the allowlist (colors, sizes, links, fonts beyond their traits) is
    /// ignored — only the trait survives.
    private static func style(forRTFAttributes attrs: [NSAttributedString.Key: Any]) -> InlineStyle {
        var style: InlineStyle = []
        if let font = attrs[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { style.insert(.bold) }
            if traits.contains(.italic) { style.insert(.italic) }
            if traits.contains(.monoSpace) { style.insert(.code) }
        }
        if let underline = attrs[.underlineStyle] as? Int, underline != 0 {
            style.insert(.underline)
        }
        return style
    }

    // MARK: - Captured / generated HTML

    /// Sanitize an HTML string into `FormattedText`, or `nil` to fall back to plain
    /// text. Hand-rolled tokenizer — no `NSAttributedString` HTML importer, so no
    /// network load is ever triggered.
    static func formattedText(fromHTML html: String) -> FormattedText? {
        guard html.utf16.count <= maxCharacterCount else { return nil }
        var tokenizer = HTMLTokenizer(html: html)
        return tokenizer.parse()
    }

    // MARK: - Block segmentation

    /// Split an ordered run sequence into blocks on `"\n"`, preserving blank lines
    /// and merging adjacent equal-style runs. Used by the RTF path.
    static func blocksFromSegments(_ segments: [InlineRun]) -> [FormattedText.Block] {
        var blocks: [FormattedText.Block] = []
        var current: [InlineRun] = []

        func flush() {
            blocks.append(FormattedText.Block(index: blocks.count, runs: mergeAdjacent(current)))
            current = []
        }

        for segment in segments {
            let parts = segment.text.components(separatedBy: "\n")
            for (offset, part) in parts.enumerated() {
                if offset > 0 { flush() }
                if !part.isEmpty { current.append(InlineRun(part, style: segment.style)) }
            }
        }
        flush()
        return blocks
    }

    /// Merge consecutive runs that share a style so the run list is canonical.
    static func mergeAdjacent(_ runs: [InlineRun]) -> [InlineRun] {
        var merged: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = merged.last, last.style == run.style {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}
