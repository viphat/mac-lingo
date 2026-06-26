import Foundation

/// Shared prompt contract for the OpenAI-compatible AI providers (spec §6.4). The
/// model receives the source encoded as **whitelisted HTML** and is instructed to
/// detect the source language, translate into the target, **preserve all tags,
/// line breaks, and structure exactly**, and return **only** the translated HTML
/// with no commentary. Output is sanitized (§5.4) and structurally validated
/// (§3.4) before rendering.
///
/// `promptVersion` is part of the `CacheKey` (spec §5.1): bump it whenever the
/// wording below changes so previously cached AI results miss.
enum AIPrompt {

    /// Version stamp carried into the `CacheKey`. Must equal
    /// `TranslationVersioning.promptVersion` — kept here as the single place the
    /// prompt and its version live together.
    static let version = TranslationVersioning.promptVersion

    /// System instruction. `target` names the destination language so the model
    /// has it in plain words alongside the engine code.
    static func system(target: TargetLanguage) -> String {
        """
        You are a translation engine. Translate the user's text into \(target.displayName).
        The text is encoded as HTML using only the tags <b>, <i>, <u>, and <code>.
        Rules:
        - Detect the source language automatically; it may be any language.
        - Translate the meaning naturally and accurately into \(target.displayName).
        - Preserve every HTML tag, its nesting, and all line breaks and structure exactly.
        - Do not add, remove, or reorder tags. Do not introduce any tags other than \
        <b>, <i>, <u>, <code>.
        - Return ONLY the translated HTML. No explanations, no code fences, no commentary.
        """
    }

    /// The user message: the source HTML for one chunk.
    static func user(html: String) -> String { html }
}
