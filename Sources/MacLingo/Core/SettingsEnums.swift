import Foundation

/// The user's **default engine** setting (spec §7). Collapses the two AI providers
/// into a single "AI provider" choice; the concrete provider is the separate
/// ``AIProvider`` setting. Resolves to an ``EngineID`` via `SettingsStore`.
enum DefaultEngine: String, CaseIterable, Codable, Sendable {
    case googleFree
    case googleCloud
    case aiProvider

    var displayName: String {
        switch self {
        case .googleFree: "Google Translate (free)"
        case .googleCloud: "Google Cloud"
        case .aiProvider: "AI provider"
        }
    }
}

/// The configured AI provider for BYOK enhancement (spec §6.4, §7).
enum AIProvider: String, CaseIterable, Codable, Sendable {
    case openAI
    case deepSeek

    var engineID: EngineID {
        switch self {
        case .openAI: .openAI
        case .deepSeek: .deepSeek
        }
    }

    /// Default model — **editable config, not a hardcoded constant** (CLAUDE.md):
    /// this is only the seed value the user can override.
    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5.4-mini"
        case .deepSeek: "deepseek-v4-flash"
        }
    }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        }
    }
}

/// Text-capture strategy (spec §4.3, §7). `axOnly` is the privacy mode that never
/// touches the clipboard.
enum CaptureMethod: String, CaseIterable, Codable, Sendable {
    case dual
    case axOnly

    var displayName: String {
        switch self {
        case .dual: "Dual (pasteboard + Accessibility)"
        case .axOnly: "Accessibility only (no clipboard)"
        }
    }
}

/// Modal appearance preference (spec §7).
enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case light
    case dark
    case system

    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}
