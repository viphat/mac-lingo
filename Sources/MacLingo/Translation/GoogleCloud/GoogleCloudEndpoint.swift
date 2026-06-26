import Foundation

/// Builds requests for the Google Cloud Translation API **v2** (spec §6.2) and
/// parses its response. Pure (no network) so the request shape, the
/// **host-allowlist guard**, and **key redaction** are unit-tested.
///
/// The API key travels in the **`X-Goog-Api-Key` request header** — never a URL
/// query parameter (spec §6.2/§9) — and is **redacted** from any diagnostic
/// description (URL *and* header). `format=html` is requested so inline styling
/// round-trips as whitelisted HTML tags (spec §6.3).
///
/// > **v2, not v3:** v3 requires a service-account flow and is out of scope (spec
/// > §6.2); v2's API-key auth is what the BYOK Cloud engine uses.
enum GoogleCloudEndpoint {

    /// Compiled-default Cloud Translation v2 endpoint. The host is on the
    /// translation-data allowlist (spec §9).
    static let defaultBaseURL = "https://translation.googleapis.com/language/translate/v2"

    /// Build the `POST` request translating one block of HTML-encoded text.
    ///
    /// `source` is omitted so Cloud auto-detects it (returned per-translation as
    /// `detectedSourceLanguage`). The resolved host is checked against the
    /// **translation-data allowlist** before any send.
    static func makeRequest(
        baseURL: String = defaultBaseURL,
        apiKey: String,
        html: String,
        target: TargetLanguage
    ) throws -> URLRequest {
        guard let components = URLComponents(string: baseURL),
            let host = components.host,
            let url = components.url
        else {
            throw TranslationError.invalidEndpoint
        }
        guard TrustMaterial.translationDataHosts.contains(host) else {
            throw TranslationError.unsupportedHost(host)
        }

        let body: [String: Any] = [
            "q": [html],
            "target": target.engineCode,
            "format": "html",
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Key in the header, **never** the URL (spec §6.2/§9). Redacted below.
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        return request
    }

    /// A diagnostic description with the API key **redacted** (spec §9). The key is
    /// never in the URL, so only the header is masked.
    static func redactedDescription(_ request: URLRequest) -> String {
        let urlString = request.url?.absoluteString ?? "<no url>"
        let method = request.httpMethod ?? "?"
        let key = request.value(forHTTPHeaderField: "X-Goog-Api-Key") == nil ? "absent" : "<redacted>"
        return "\(method) \(urlString) [X-Goog-Api-Key: \(key)]"
    }
}

/// Parses a Cloud Translation v2 response (spec §6.2): the translated text is
/// `data.translations[0].translatedText` and the auto-detected source language is
/// `data.translations[0].detectedSourceLanguage`. Pure so the shape is unit-tested.
enum GoogleCloudResponseParser {

    struct Parsed: Equatable, Sendable {
        /// The translated HTML for the block.
        let translatedText: String
        /// Auto-detected source language (BCP-47), or `nil` if absent/empty.
        let detectedSource: String?
    }

    static func parse(_ data: Data) throws -> Parsed {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
            let dataField = object["data"] as? [String: Any],
            let translations = dataField["translations"] as? [Any],
            let first = translations.first as? [String: Any],
            let translated = first["translatedText"] as? String
        else {
            throw TranslationError.malformedResponse
        }

        var detected: String?
        if let language = first["detectedSourceLanguage"] as? String, !language.isEmpty {
            detected = language
        }
        return Parsed(translatedText: translated, detectedSource: detected)
    }
}
