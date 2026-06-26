import Foundation

/// Cheap, deterministic size estimators used to keep each translation chunk within
/// the **encoded** budget (spec §6.5) — never approximate character counts at the
/// call site. Two measures: model **tokens** (AI) and **UTF-8 bytes** (Google
/// Free). Both are intentionally conservative so a chunk never overruns a real
/// budget; exactness isn't required, only a stable upper-ish bound.
enum EncodedSize {

    /// Rough token estimate for `text`. Real tokenizers are model-specific; a
    /// ~4-characters-per-token heuristic with a floor of 1 per non-empty string is
    /// good enough to bound a chunk. Counts Unicode scalars so multibyte scripts
    /// (which tokenize denser) are not under-counted too badly.
    static func tokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let scalars = text.unicodeScalars.count
        return max(1, (scalars + 3) / 4)
    }

    /// UTF-8 byte length of `text`.
    static func utf8Bytes(_ text: String) -> Int { text.utf8.count }
}
