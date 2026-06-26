import XCTest

@testable import MacLingo

/// Coverage for the Google Cloud Translation v2 provider (spec §6.2): request shape
/// (key in `X-Goog-Api-Key`, `format=html`, key never in URL), host allowlist, key
/// redaction, response parsing, the HTML round-trip + block reassembly over a mock
/// client, language aggregation from `detectedSourceLanguage`, and 401 →
/// `.unauthorized`.
final class GoogleCloudTests: XCTestCase {

    // MARK: - Endpoint builder

    func testRequestPutsKeyInHeaderNotURLAndRequestsHTML() throws {
        let request = try GoogleCloudEndpoint.makeRequest(
            apiKey: "AIza-secret", html: "<b>hi</b>", target: .vi)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.absoluteString, GoogleCloudEndpoint.defaultBaseURL)
        XCTAssertFalse(url.absoluteString.contains("AIza-secret"), "key must never be in the URL")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Api-Key"), "AIza-secret")
        XCTAssertEqual(request.httpMethod, "POST")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "html")
        XCTAssertEqual(object["target"] as? String, "vi")
        XCTAssertEqual(object["q"] as? [String], ["<b>hi</b>"])
    }

    func testTraditionalChineseTargetCode() throws {
        let request = try GoogleCloudEndpoint.makeRequest(apiKey: "k", html: "hi", target: .zhHant)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["target"] as? String, "zh-TW")
    }

    func testOffAllowlistHostRejected() {
        XCTAssertThrowsError(
            try GoogleCloudEndpoint.makeRequest(
                baseURL: "https://evil.example.com/language/translate/v2", apiKey: "k",
                html: "hi", target: .en)
        ) { error in
            XCTAssertEqual(error as? TranslationError, .unsupportedHost("evil.example.com"))
        }
    }

    func testRedactedDescriptionHidesKey() throws {
        let request = try GoogleCloudEndpoint.makeRequest(
            apiKey: "AIza-topsecret", html: "hi", target: .en)
        let description = GoogleCloudEndpoint.redactedDescription(request)
        XCTAssertFalse(description.contains("AIza-topsecret"))
        XCTAssertTrue(description.contains("<redacted>"))
    }

    // MARK: - Response parser

    func testResponseParserExtractsTextAndDetectedSource() throws {
        let json = #"{"data":{"translations":[{"translatedText":"Xin chào","detectedSourceLanguage":"en"}]}}"#
        let parsed = try GoogleCloudResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(parsed.translatedText, "Xin chào")
        XCTAssertEqual(parsed.detectedSource, "en")
    }

    func testResponseParserMissingDetectedSourceIsNil() throws {
        let json = #"{"data":{"translations":[{"translatedText":"Hola"}]}}"#
        let parsed = try GoogleCloudResponseParser.parse(Data(json.utf8))
        XCTAssertNil(parsed.detectedSource)
    }

    func testResponseParserRejectsMalformed() {
        XCTAssertThrowsError(try GoogleCloudResponseParser.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? TranslationError, .malformedResponse)
        }
    }

    // MARK: - Provider over a mock client

    /// Echoes the request's first `q` value back as the translated text, with a
    /// fixed detected language, so the HTML round-trip is exercised end-to-end.
    private final class EchoCloudClient: HTTPClient, @unchecked Sendable {
        let detected: String
        private let lock = NSLock()
        private var count = 0
        var callCount: Int { lock.withLock { count } }

        init(detected: String = "fr") { self.detected = detected }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { count += 1 }
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = (object["q"] as? [String])?.first ?? ""
            let reply: [String: Any] = [
                "data": ["translations": [["translatedText": query, "detectedSourceLanguage": detected]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: reply)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (data, response)
        }
    }

    private final class StatusClient: HTTPClient, @unchecked Sendable {
        let status: Int
        init(_ status: Int) { self.status = status }
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data("{}".utf8), response)
        }
    }

    func testProviderRoundTripsInlineStyleViaHTML() async throws {
        let styled = FormattedText(blocks: [
            FormattedText.Block(index: 0, runs: [InlineRun("hi "), InlineRun("there", style: .bold)])
        ])
        let client = EchoCloudClient(detected: "en")
        let provider = GoogleCloudProvider(apiKey: "k", client: client)
        let request = TranslationRequest(
            operationID: 9, selection: SelectionSnapshot(id: 1, source: styled),
            engine: .googleCloud, target: .vi)

        let result = try await provider.translate(request)

        XCTAssertEqual(result.operationID, 9)
        XCTAssertEqual(result.engine, .googleCloud)
        XCTAssertEqual(result.detectedSource, .known(bcp47: "en"))
        XCTAssertEqual(result.text.plainText, "hi there")
        let boldRun = result.text.blocks[0].runs.first { $0.style.contains(.bold) }
        XCTAssertEqual(boldRun?.text, "there")
    }

    func testProviderReassemblesByBlockIndexAndSkipsBlankBlocks() async throws {
        let client = EchoCloudClient(detected: "de")
        let provider = GoogleCloudProvider(apiKey: "k", client: client)
        let request = TranslationRequest(
            operationID: 1,
            selection: SelectionSnapshot(id: 1, source: FormattedText(plainText: "one\n\ntwo")),
            engine: .googleCloud, target: .en)

        let result = try await provider.translate(request)
        XCTAssertEqual(result.text.plainText, "one\n\ntwo")
        XCTAssertEqual(result.text.blocks.count, 3)
        XCTAssertEqual(client.callCount, 2, "the blank middle block issues no request")
        XCTAssertEqual(result.detectedSource, .known(bcp47: "de"))
    }

    func testUnauthorizedMapsToTypedError() async {
        let provider = GoogleCloudProvider(apiKey: "bad", client: StatusClient(403))
        let request = TranslationRequest(
            operationID: 1,
            selection: SelectionSnapshot(id: 1, source: FormattedText(plainText: "hi")),
            engine: .googleCloud, target: .en)
        do {
            _ = try await provider.translate(request)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? TranslationError, .unauthorized)
        }
    }

    func testHTTPErrorPropagates() async {
        let provider = GoogleCloudProvider(apiKey: "k", client: StatusClient(400), maxRetries: 0)
        let request = TranslationRequest(
            operationID: 1,
            selection: SelectionSnapshot(id: 1, source: FormattedText(plainText: "hi")),
            engine: .googleCloud, target: .en)
        do {
            _ = try await provider.translate(request)
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? TranslationError, .http(status: 400))
        }
    }
}
