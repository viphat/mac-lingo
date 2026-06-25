import Foundation

/// Parses the unofficial Google Free `dt=t` response (spec §6.1). The body is a
/// JSON array roughly shaped as:
/// `[[["translated","source",…], …], null, "fr", …]` — translated sentence
/// fragments at `[0][*][0]` and the detected source language at `[2]`.
/// Pure so the brittle array shape is unit-tested.
enum GoogleFreeResponseParser {

    struct Parsed: Equatable, Sendable {
        /// Concatenated translated fragments for the block.
        let translated: String
        /// Detected source language (BCP-47), or `nil` if absent/empty.
        let detectedSource: String?
    }

    static func parse(_ data: Data) throws -> Parsed {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let top = root as? [Any], let sentences = top.first as? [Any] else {
            throw TranslationError.malformedResponse
        }

        var translated = ""
        for entry in sentences {
            // Each sentence fragment is itself an array; the translated text is [0].
            if let fragment = entry as? [Any], let piece = fragment.first as? String {
                translated += piece
            }
        }

        // Detected source language at index 2 (a non-empty string when present).
        var detected: String?
        if top.count > 2, let language = top[2] as? String, !language.isEmpty {
            detected = language
        }

        return Parsed(translated: translated, detectedSource: detected)
    }
}
