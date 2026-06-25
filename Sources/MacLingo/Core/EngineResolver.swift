import Foundation

/// Snapshot of which engines are currently configured/reachable. "Configured"
/// here means *presence* (a key exists, the provider is selected); **validity**
/// (key passes Validate / no runtime 401) is layered on in Phase 5 — see spec §5.5
/// "presence is not validity".
struct ConfiguredEngines: Equatable, Sendable {
    /// Whether Google Free is currently usable (false only once a remote-config
    /// kill switch lands in Phase 7).
    var googleFreeAvailable: Bool = true
    var googleCloudConfigured: Bool = false
    var aiProvider: AIProvider?

    var aiConfigured: Bool { aiProvider != nil }
}

/// Resolves the engine to actually use, given the user's preferred default and
/// what is currently configured. Centralizes the fallback chain (spec §6.1) so
/// launch reconciliation (§5.5), live reconciliation (§5.5), and trigger-time
/// resolution (§3.1) all agree.
enum EngineResolver {

    /// Resolve a concrete `EngineID` for the preferred default. Falls back when the
    /// preferred engine is unconfigured/unavailable:
    /// - Free blocked → AI → Cloud (spec §6.1 degraded chain).
    /// - A misconfigured paid default → Free (if available) → the other paid engine.
    static func resolve(preferred: DefaultEngine, available: ConfiguredEngines) -> EngineID {
        for choice in fallbackOrder(for: preferred) {
            if let engine = engine(for: choice, available: available) { return engine }
        }
        return .googleFree
    }

    /// Ordered preference list: the requested engine first, then the fallback chain.
    private static func fallbackOrder(for preferred: DefaultEngine) -> [DefaultEngine] {
        switch preferred {
        case .googleFree: [.googleFree, .aiProvider, .googleCloud]
        case .googleCloud: [.googleCloud, .googleFree, .aiProvider]
        case .aiProvider: [.aiProvider, .googleFree, .googleCloud]
        }
    }

    /// The concrete engine for a choice, or `nil` if that choice isn't configured.
    private static func engine(for choice: DefaultEngine, available: ConfiguredEngines) -> EngineID? {
        switch choice {
        case .googleFree: available.googleFreeAvailable ? .googleFree : nil
        case .googleCloud: available.googleCloudConfigured ? .googleCloud : nil
        case .aiProvider: available.aiProvider?.engineID
        }
    }

    /// Whether the preferred default is itself currently valid (no fallback needed).
    static func isAvailable(_ preferred: DefaultEngine, available: ConfiguredEngines) -> Bool {
        switch preferred {
        case .googleFree: available.googleFreeAvailable
        case .googleCloud: available.googleCloudConfigured
        case .aiProvider: available.aiConfigured
        }
    }

    /// The `DefaultEngine` setting value corresponding to a resolved `EngineID`,
    /// used to rewrite a stale default during reconciliation (spec §5.5/§7).
    static func defaultEngine(for engine: EngineID) -> DefaultEngine {
        switch engine {
        case .googleFree: .googleFree
        case .googleCloud: .googleCloud
        case .openAI, .deepSeek: .aiProvider
        }
    }
}
