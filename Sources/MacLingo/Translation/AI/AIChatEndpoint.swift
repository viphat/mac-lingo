import Foundation

/// Builds requests for an OpenAI-compatible `/chat/completions` endpoint (spec
/// §6.4) and parses the chat response. Pure (no network) so the request shape,
/// the **host-allowlist guard**, and **key redaction** are unit-tested.
///
/// The API key travels in the `Authorization: Bearer` header — never the URL — and
/// is **redacted** from any diagnostic description (spec §9).
enum AIChatEndpoint {

    /// Build the `POST /chat/completions` request. `baseURL` is the provider's API
    /// root (e.g. `https://api.openai.com/v1`); the resolved host is checked
    /// against the **translation-data allowlist** (spec §9) before any send.
    static func makeRequest(
        baseURL: String,
        model: String,
        apiKey: String,
        system: String,
        user: String
    ) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL) else {
            throw TranslationError.invalidEndpoint
        }
        // Append the chat-completions path without losing the base path (e.g. `/v1`).
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/chat/completions"

        guard let host = components.host, let url = components.url else {
            throw TranslationError.invalidEndpoint
        }
        guard TrustMaterial.translationDataHosts.contains(host) else {
            throw TranslationError.unsupportedHost(host)
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Auth in the header, never the URL (spec §9). Redacted in diagnostics below.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// A diagnostic description of a request with the bearer token **redacted**
    /// (spec §9). Used in place of `URLRequest`'s default description in any log.
    static func redactedDescription(_ request: URLRequest) -> String {
        let urlString = request.url?.absoluteString ?? "<no url>"
        let method = request.httpMethod ?? "?"
        let auth = request.value(forHTTPHeaderField: "Authorization") == nil ? "absent" : "Bearer <redacted>"
        return "\(method) \(urlString) [Authorization: \(auth)]"
    }
}

/// Parses an OpenAI-compatible chat-completions response: the translated text is
/// `choices[0].message.content`. Pure so the shape is unit-tested.
enum AIChatResponseParser {

    static func parse(_ data: Data) throws -> String {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
            let choices = object["choices"] as? [Any],
            let first = choices.first as? [String: Any],
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw TranslationError.malformedResponse
        }
        return content
    }
}
