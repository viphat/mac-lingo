import AppKit
import SwiftUI

/// Renders a `FormattedText` for display (`SwiftUI.Text`) and for rich copy-out
/// (sanitized RTF). The styling reattached here is exactly the allowlist the
/// codec/sanitizer admit — {bold, italic, underline, code} — so nothing un-vetted
/// reaches the screen or the pasteboard (spec §3.4, §5.4).
enum FormattedTextRenderer {

    /// Build a SwiftUI `Text` with per-run styling, list markers, and 1:1 block
    /// breaks (block structure is the universal guarantee, §3.4).
    static func text(_ formatted: FormattedText) -> Text {
        let prefixes = markerPrefixes(for: formatted.blocks)
        var pieces: [Text] = []
        for (offset, block) in formatted.blocks.enumerated() {
            if offset > 0 { pieces.append(Text(verbatim: "\n")) }
            if !prefixes[offset].isEmpty { pieces.append(Text(verbatim: prefixes[offset])) }
            pieces.append(contentsOf: block.runs.map(styled))
        }
        return pieces.reduce(Text(verbatim: "")) { $0 + $1 }
    }

    /// Serialize to sanitized RTF data for the pasteboard, or `nil` if it can't be
    /// produced (the caller still writes the plain-text fallback).
    static func rtfData(_ formatted: FormattedText) -> Data? {
        let attributed = NSMutableAttributedString()
        let prefixes = markerPrefixes(for: formatted.blocks)
        for (offset, block) in formatted.blocks.enumerated() {
            if offset > 0 { attributed.append(NSAttributedString(string: "\n")) }
            if !prefixes[offset].isEmpty { attributed.append(NSAttributedString(string: prefixes[offset])) }
            for run in block.runs {
                attributed.append(NSAttributedString(string: run.text, attributes: rtfAttributes(run.style)))
            }
        }
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])
    }

    // MARK: - SwiftUI styling

    private static func styled(_ run: InlineRun) -> Text {
        var text = Text(verbatim: run.text)
        if run.style.contains(.bold) { text = text.bold() }
        if run.style.contains(.italic) { text = text.italic() }
        if run.style.contains(.underline) { text = text.underline() }
        if run.style.contains(.code) { text = text.monospaced() }
        return text
    }

    // MARK: - RTF styling

    private static func rtfAttributes(_ style: InlineStyle) -> [NSAttributedString.Key: Any] {
        var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if style.contains(.code) {
            font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        var traits: NSFontTraitMask = []
        if style.contains(.bold) { traits.insert(.boldFontMask) }
        if style.contains(.italic) { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if style.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    // MARK: - List markers

    /// Compute the visible prefix (indent + bullet/number) for each block. Ordered
    /// list items are numbered per level; numbering resets when the level's run of
    /// ordered items ends.
    private static func markerPrefixes(for blocks: [FormattedText.Block]) -> [String] {
        var prefixes: [String] = []
        var counters: [Int: Int] = [:]  // level → next ordinal
        for block in blocks {
            switch block.kind {
            case .paragraph:
                counters.removeAll()
                prefixes.append("")
            case .listItem(let level, let ordered):
                let indent = String(repeating: "    ", count: max(0, level - 1))
                if ordered {
                    let ordinal = counters[level, default: 1]
                    counters[level] = ordinal + 1
                    prefixes.append("\(indent)\(ordinal). ")
                } else {
                    counters[level] = nil
                    prefixes.append("\(indent)•  ")
                }
            }
        }
        return prefixes
    }
}
