import Foundation

/// The rich representation kind captured from the pasteboard, if any.
enum CapturedRichKind: Sendable, Equatable {
    case rtf
    case html
}

/// A rich (formatted) payload captured from the pasteboard. The bytes are
/// **untrusted** until they pass `MarkupSanitizer` at the `RichTextCodec.parse`
/// step (spec §5.4).
struct CapturedRich: Sendable, Equatable {
    let kind: CapturedRichKind
    let data: Data
}

/// The result of a capture (spec §4.3): always plain text, plus the richest
/// representation that was available. Engine-agnostic; `RichTextCodec.parse` turns
/// `rich` into a sanitized `FormattedText`, falling back to `plainText` on failure.
struct CapturedSelection: Sendable, Equatable {
    let plainText: String
    let rich: CapturedRich?

    var isEmpty: Bool { plainText.isEmpty && rich == nil }
}
