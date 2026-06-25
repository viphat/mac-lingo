import Foundation

/// The four user-selectable target languages (spec §3.2). The **source** language
/// is auto-detected and may be any language (modeled by `DetectedLanguage` in a
/// later phase) — only the *target* is constrained to these four.
enum TargetLanguage: String, CaseIterable, Codable, Sendable {
    case en
    case vi
    case zhHans
    case zhHant

    /// The code passed to translation engines as the target (`tl`) parameter.
    var engineCode: String {
        switch self {
        case .en: "en"
        case .vi: "vi"
        case .zhHans: "zh-CN"
        case .zhHant: "zh-TW"
        }
    }

    /// The BCP-47-style display tag shown in the UI.
    var displayTag: String {
        switch self {
        case .en: "en"
        case .vi: "vi"
        case .zhHans: "zh-Hans"
        case .zhHant: "zh-Hant"
        }
    }

    /// Human-readable name for settings and the modal.
    var displayName: String {
        switch self {
        case .en: "English"
        case .vi: "Vietnamese"
        case .zhHans: "Chinese (Simplified)"
        case .zhHant: "Chinese (Traditional)"
        }
    }
}
