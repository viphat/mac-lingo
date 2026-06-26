import Foundation

/// Maps an `EngineID` to a concrete `TranslationService` (spec §5.1).
protocol TranslationServiceProviding: Sendable {
    func service(for engine: EngineID) -> TranslationService?
}

/// Runtime configuration for the active BYOK AI engine (spec §6.4): which provider,
/// which (editable) model, and the key read from the Keychain. Rebuilt by live
/// reconciliation whenever the provider/model/key changes; `nil` when no AI engine
/// is configured. The key is held in memory only while a provider is active and is
/// **never** logged (spec §9).
struct AIRuntimeConfig: Sendable, Equatable {
    let engineID: EngineID
    let model: String
    let apiKey: String
}

/// Runtime configuration for the optional Google Cloud engine (spec §6.2): the key
/// read from the Keychain. Rebuilt by reconciliation whenever the key/enabled state
/// changes; `nil` when Cloud is disabled or unconfigured. The key is held in memory
/// only while Cloud is active and is **never** logged (spec §9).
struct CloudRuntimeConfig: Sendable, Equatable {
    let apiKey: String
}

/// Factory mapping `EngineID` → live `TranslationService`, with a mutable AI
/// configuration so a mid-session key/model/provider change takes effect on the
/// next request (paired with a `providerConfigRevision` bump that misses the cache,
/// spec §5.5). Reference type + lock so it can be updated off the call that issues
/// requests; the AI key lives only here in memory.
final class TranslationServiceRegistry: TranslationServiceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let httpClient: HTTPClient
    private var googleFreeEndpoint: String
    private var googleFreeAvailable: Bool
    private var aiConfig: AIRuntimeConfig?
    private var cloudConfig: CloudRuntimeConfig?

    init(
        httpClient: HTTPClient = URLSessionHTTPClient(),
        googleFreeEndpoint: String = TrustMaterial.defaultGoogleFreeEndpoint,
        googleFreeAvailable: Bool = true,
        aiConfig: AIRuntimeConfig? = nil,
        cloudConfig: CloudRuntimeConfig? = nil
    ) {
        self.httpClient = httpClient
        self.googleFreeEndpoint = googleFreeEndpoint
        self.googleFreeAvailable = googleFreeAvailable
        self.aiConfig = aiConfig
        self.cloudConfig = cloudConfig
    }

    /// Replace the active AI configuration (live reconciliation, spec §5.5). Pass
    /// `nil` to drop AI (key removed / provider invalid).
    func updateAIConfig(_ config: AIRuntimeConfig?) {
        lock.withLock { aiConfig = config }
    }

    /// Replace the active Google Cloud configuration (live reconciliation, spec
    /// §5.5). Pass `nil` to drop Cloud (disabled / key removed / invalid).
    func updateCloudConfig(_ config: CloudRuntimeConfig?) {
        lock.withLock { cloudConfig = config }
    }

    /// Switch the Google Free endpoint among allowlisted hosts (Phase 7 remote
    /// config). Disable the Free provider with `available: false`.
    func updateGoogleFree(endpoint: String? = nil, available: Bool? = nil) {
        lock.withLock {
            if let endpoint { googleFreeEndpoint = endpoint }
            if let available { googleFreeAvailable = available }
        }
    }

    func service(for engine: EngineID) -> TranslationService? {
        let (endpoint, freeOn, ai, cloud) = lock.withLock {
            (googleFreeEndpoint, googleFreeAvailable, aiConfig, cloudConfig)
        }
        switch engine {
        case .googleFree:
            return freeOn ? GoogleFreeProvider(endpoint: endpoint, client: httpClient) : nil
        case .openAI, .deepSeek:
            guard let ai, ai.engineID == engine else { return nil }
            switch engine {
            case .openAI:
                return OpenAICompatibleProvider.openAI(
                    model: ai.model, apiKey: ai.apiKey, client: httpClient)
            case .deepSeek:
                return OpenAICompatibleProvider.deepSeek(
                    model: ai.model, apiKey: ai.apiKey, client: httpClient)
            default:
                return nil
            }
        case .googleCloud:
            guard let cloud else { return nil }
            return GoogleCloudProvider(apiKey: cloud.apiKey, client: httpClient)
        }
    }
}
