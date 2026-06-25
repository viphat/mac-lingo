import Foundation

/// Minimal async HTTP seam so providers are testable without the network. The live
/// conformer wraps `URLSession`.
///
/// > NOTE(Phase 7): the live client currently uses a default session. The
/// > networking trust boundary — dual allowlists and **explicit per-redirect
/// > validation** (spec §9) — is layered on in Phase 7 via a `URLSession`
/// > delegate. The host allowlist is already enforced at request-build time
/// > (`GoogleFreeEndpoint`).
protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live `HTTPClient` over `URLSession`.
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
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
