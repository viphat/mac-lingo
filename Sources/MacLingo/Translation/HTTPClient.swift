import Foundation

/// Minimal async HTTP seam so providers are testable without the network. The live
/// conformer wraps a **hardened** `URLSession` whose redirects are validated by
/// ``HardenedSessionDelegate`` (spec §9, P0): default redirect auto-following is
/// disabled and every 3xx is checked against ``RedirectValidator`` before it is
/// followed. The host allowlist is also enforced at request-build time
/// (`GoogleFreeEndpoint`, `AIChatEndpoint`, `GoogleCloudEndpoint`).
protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live `HTTPClient` over a redirect-validating, non-persisting `URLSession`.
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession = .hardened()) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.malformedResponse
        }
        return (data, http)
    }
}
