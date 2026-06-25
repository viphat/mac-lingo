import Foundation

/// Materializability pre-check (spec §4.3 step 1). If the current pasteboard holds
/// promised/lazy or otherwise non-restorable types, MacLingo must **not**
/// synthesize a copy — it can never overwrite content it would be unable to put
/// back. Pure, type-identifier-based logic so it is unit-tested independently of
/// `NSPasteboard`.
enum Materializability {

    /// Known promise/lazy pasteboard type identifiers that cannot be fully captured
    /// and restored.
    private static let nonRestorableTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pboard.promised-file-name",
        "com.apple.pboard.promised-file-content-type",
    ]

    /// Whether a single type identifier is concretely restorable.
    static func isRestorable(_ type: String) -> Bool {
        if nonRestorableTypes.contains(type) { return false }
        let lowered = type.lowercased()
        // Defensive: anything that advertises itself as a promise is non-restorable.
        return !lowered.contains("promise") && !lowered.contains("promised")
    }

    /// Whether **all** present types are restorable. An empty pasteboard is trivially
    /// restorable (nothing to put back).
    static func canRestore(types: [String]) -> Bool {
        types.allSatisfy(isRestorable)
    }
}
