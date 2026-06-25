import Foundation

/// Combines the AX and pasteboard reads into the richest successful result
/// (spec §4.3 "Combine"). Pure logic, unit-tested.
enum CaptureCombiner {

    /// Pick the richest non-empty capture:
    /// 1. pasteboard **rich** (RTF/HTML) when present,
    /// 2. otherwise the AX plain text (clipboard-free; reliable in native apps),
    /// 3. otherwise pasteboard plain text,
    /// 4. otherwise `nil` → "No text selected".
    static func combine(axPlainText: String?, pasteboard: CapturedSelection?) -> CapturedSelection? {
        if let pasteboard, pasteboard.rich != nil {
            return pasteboard
        }
        if let axPlainText, !axPlainText.isEmpty {
            return CapturedSelection(plainText: axPlainText, rich: nil)
        }
        if let pasteboard, !pasteboard.plainText.isEmpty {
            return CapturedSelection(plainText: pasteboard.plainText, rich: nil)
        }
        return nil
    }
}
