import Foundation

/// Identity of a concrete translation engine (spec §5.1). This is the value that
/// participates in the `CacheKey` and the engine selector. Distinct from
/// ``DefaultEngine`` (the user's *setting*, which collapses both AI providers into
/// a single "AI provider" choice).
enum EngineID: String, CaseIterable, Codable, Sendable {
    case googleFree
    case googleCloud
    case openAI
    case deepSeek

    /// Whether this engine bills per use. Paid engines (AI **and** Google Cloud)
    /// are subject to the paid-translation confirmation (spec §6.5); Google Free
    /// is exempt.
    var isPaid: Bool {
        switch self {
        case .googleFree: false
        case .googleCloud, .openAI, .deepSeek: true
        }
    }

    /// Whether this engine is an AI provider (used for the auto-enhance no-op rule
    /// in spec §3.1).
    var isAI: Bool {
        switch self {
        case .openAI, .deepSeek: true
        case .googleFree, .googleCloud: false
        }
    }

    var displayName: String {
        switch self {
        case .googleFree: "Google Translate"
        case .googleCloud: "Google Cloud"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        }
    }
}
