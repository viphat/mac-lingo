import Foundation

/// Builds requests for the unofficial Google Free endpoint (spec §6.1):
/// `…/translate_a/single?client=gtx&sl=auto&tl=<target>&dt=t&q=<text>`.
/// Pure (no network) so the URL shape and the host-allowlist guard are unit-tested.
enum GoogleFreeEndpoint {

    /// Build a GET request for one block of text against `endpoint`.
    ///
    /// The resolved host is checked against the **translation-data allowlist**
    /// (spec §9) — selected text may only ever go to an allowlisted host, even
    /// before the full Phase 7 redirect hardening lands.
    static func makeRequest(
        endpoint: String,
        text: String,
        target: TargetLanguage
    ) throws -> URLRequest {
        guard var components = URLComponents(string: endpoint) else {
            throw TranslationError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target.engineCode),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let host = components.host, let url = components.url else {
            throw TranslationError.invalidEndpoint
        }
        guard TrustMaterial.translationDataHosts.contains(host) else {
            throw TranslationError.unsupportedHost(host)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // A browser-like UA reduces the chance the unofficial endpoint blocks us.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent")
        return request
    }
}
