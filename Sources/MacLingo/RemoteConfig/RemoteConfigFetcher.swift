import Foundation

/// Fetches the signed remote config from the **control-plane** host (spec §6.1,
/// §9). This is a control-plane request: it **never carries selected text**, and
/// the host is asserted to be on the control-plane allowlist before any request is
/// built. Best-effort and time-boxed; failures are swallowed by the caller (the
/// fail-closed state machine keeps the last trusted state).
struct RemoteConfigFetcher: Sendable {
    private let client: HTTPClient
    private let host: String
    private let path: String
    private let timeout: TimeInterval

    init(
        client: HTTPClient = URLSessionHTTPClient(),
        host: String = TrustMaterial.remoteConfigHost,
        path: String = "/maclingo/config.json",
        timeout: TimeInterval = 8
    ) {
        self.client = client
        self.host = host
        self.path = path
        self.timeout = timeout
    }

    /// Fetch and JSON-decode the signed config. Throws on a non-2xx status, a
    /// network error, an off-allowlist host, or a malformed body.
    func fetch() async throws -> SignedRemoteConfig {
        // Belt-and-braces: a control-plane fetch must never target a translation or
        // unknown host (spec §9 — the two allowlists are never merged).
        guard TrustMaterial.allowlist(for: host) == .controlPlane else {
            throw TranslationError.unsupportedHost(host)
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard let url = components.url else { throw TranslationError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw TranslationError.http(status: response.statusCode)
        }
        return try JSONDecoder().decode(SignedRemoteConfig.self, from: data)
    }
}
