import Foundation

/// Maps an `EngineID` to a concrete `TranslationService` (spec §5.1). Phase 3
/// implements Google Free only; Google Cloud and the AI providers arrive in
/// Phases 5–6 and return `nil` until then (the session surfaces
/// `providerUnavailable`).
protocol TranslationServiceProviding: Sendable {
    func service(for engine: EngineID) -> TranslationService?
}

/// Default factory. The Google Free endpoint is injected (Phase 7 remote config
/// can switch it among allowlisted hosts); the HTTP client is injected for tests.
struct DefaultTranslationServices: TranslationServiceProviding {
    private let httpClient: HTTPClient
    private let googleFreeEndpoint: String

    init(
        httpClient: HTTPClient = URLSessionHTTPClient(),
        googleFreeEndpoint: String = TrustMaterial.defaultGoogleFreeEndpoint
    ) {
        self.httpClient = httpClient
        self.googleFreeEndpoint = googleFreeEndpoint
    }

    func service(for engine: EngineID) -> TranslationService? {
        switch engine {
        case .googleFree:
            GoogleFreeProvider(endpoint: googleFreeEndpoint, client: httpClient)
        case .googleCloud, .openAI, .deepSeek:
            nil  // Phases 5 (AI) / 6 (Cloud)
        }
    }
}
