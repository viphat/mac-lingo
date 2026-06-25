import Foundation

/// Injection seams for `SelectionCapturer` (spec §4.3). Keeping the AppKit /
/// Accessibility / CoreGraphics calls behind protocols lets the actor's
/// ownership-safe capture flow be unit-tested without a live pasteboard.

/// Reads the selected text via the Accessibility API (clipboard-free).
protocol AccessibilityReading: Sendable {
    /// Plain text of the current selection from the focused element, or `nil`
    /// when there is no selection / AX is unavailable.
    func selectedText() -> String?
}

/// Synthesizes the copy keystroke (⌘C).
protocol KeystrokeSynthesizing: Sendable {
    func synthesizeCopy()
}

/// A concrete, fully-materialized snapshot of one pasteboard item (spec §4.3
/// step 2): every type identifier mapped to its bytes, so it can be written back
/// verbatim during a conservative restore.
struct PasteboardItemSnapshot: Sendable, Equatable {
    let contents: [String: Data]
}

/// A snapshot of the whole pasteboard plus the `changeCount` at capture time.
struct PasteboardSnapshot: Sendable, Equatable {
    let items: [PasteboardItemSnapshot]
    let changeCount: Int
}

/// The pasteboard operations the capturer needs. The live conformer is a
/// stateless value that talks to `NSPasteboard.general`; the actor serializes all
/// access so the shared pasteboard is never touched concurrently (spec §4.3).
protocol Pasteboarding: Sendable {
    /// `NSPasteboard.general.changeCount` right now.
    var changeCount: Int { get }

    /// All concrete type identifiers currently present (drives the
    /// materializability pre-check, spec §4.3 step 1).
    func types() -> [String]

    /// Full snapshot of every item's bytes (spec §4.3 step 2).
    func snapshot() -> PasteboardSnapshot

    /// Read the richest representation now on the pasteboard, preferring
    /// RTF/HTML, then plain text. `nil` when nothing usable is present.
    func readRichest() -> CapturedSelection?

    /// Restore a previously captured snapshot. Only called when the ownership
    /// predicate (spec §4.3 step 5) has confirmed we still own the pasteboard.
    func restore(_ snapshot: PasteboardSnapshot)
}
