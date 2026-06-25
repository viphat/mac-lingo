import XCTest

@testable import MacLingo

/// Coverage for the Google Free request builder and response parser (spec §6.1),
/// plus the provider's block-wise translation over a mock HTTP client.
final class GoogleFreeTests: XCTestCase {

    // MARK: - Endpoint builder

    func testRequestCarriesExpectedQueryAndAllowedHost() throws {
        let request = try GoogleFreeEndpoint.makeRequest(
            endpoint: TrustMaterial.defaultGoogleFreeEndpoint, text: "héllo & bye", target: .vi)
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["client"], "gtx")
        XCTAssertEqual(items["sl"], "auto")
        XCTAssertEqual(items["tl"], "vi")
        XCTAssertEqual(items["dt"], "t")
        XCTAssertEqual(items["q"], "héllo & bye")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testOffAllowlistHostIsRejected() {
        XCTAssertThrowsError(
            try GoogleFreeEndpoint.makeRequest(
                endpoint: "https://evil.example.com/translate_a/single", text: "hi", target: .en)
        ) { error in
            XCTAssertEqual(error as? TranslationError, .unsupportedHost("evil.example.com"))
        }
    }

    func testInvalidEndpointIsRejected() {
        XCTAssertThrowsError(
            try GoogleFreeEndpoint.makeRequest(endpoint: "not a url", text: "hi", target: .en))
    }

    // MARK: - Response parser

    func testParsesTranslationAndDetectedSource() throws {
        let json = #"[[["Xin chào","Hello",null,null,10]],null,"en",null]"#
        let parsed = try GoogleFreeResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(parsed.translated, "Xin chào")
        XCTAssertEqual(parsed.detectedSource, "en")
    }

    func testConcatenatesMultipleSentenceFragments() throws {
        let json = #"[[["Bonjour ","Hello "],["le monde","world"]],null,"en"]"#
        let parsed = try GoogleFreeResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(parsed.translated, "Bonjour le monde")
    }

    func testMissingDetectedSourceIsNil() throws {
        let json = #"[[["Hola","Hi"]],null,""]"#
        let parsed = try GoogleFreeResponseParser.parse(Data(json.utf8))
        XCTAssertNil(parsed.detectedSource)
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try GoogleFreeResponseParser.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? TranslationError, .malformedResponse)
        }
    }

    // MARK: - Provider (block-wise, over a mock client)

    /// Returns a canned body for every request, recording how many calls landed.
    private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
        let body: Data
        let status: Int
        private let lock = NSLock()
        private var count = 0
        var callCount: Int { lock.withLock { count } }

        init(translated: String, detected: String, status: Int = 200) {
            self.body = Data(#"[[["\#(translated)","src"]],null,"\#(detected)"]"#.utf8)
            self.status = status
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { count += 1 }
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (body, response)
        }
    }

    private func snapshot(_ plain: String) -> SelectionSnapshot {
        SelectionSnapshot(id: 1, source: FormattedText(plainText: plain))
    }

    func testProviderTranslatesEachBlockAndReassemblesByIndex() async throws {
        let client = StubHTTPClient(translated: "OUT", detected: "fr")
        let provider = GoogleFreeProvider(client: client)
        let request = TranslationRequest(
            operationID: 5, selection: snapshot("line one\nline two"), engine: .googleFree, target: .en)

        let result = try await provider.translate(request)

        XCTAssertEqual(result.operationID, 5)
        XCTAssertEqual(result.text.blocks.count, 2)
        XCTAssertEqual(result.text.plainText, "OUT\nOUT")
        XCTAssertEqual(result.detectedSource, .known(bcp47: "fr"))
        XCTAssertEqual(client.callCount, 2, "one request per non-empty block")
    }

    func testProviderSkipsBlankBlocks() async throws {
        let client = StubHTTPClient(translated: "X", detected: "de")
        let provider = GoogleFreeProvider(client: client)
        // Blank middle line must be preserved verbatim with no request.
        let request = TranslationRequest(
            operationID: 1, selection: snapshot("hi\n\nbye"), engine: .googleFree, target: .en)

        let result = try await provider.translate(request)

        XCTAssertEqual(result.text.plainText, "X\n\nX")
        XCTAssertEqual(client.callCount, 2, "blank block issues no request")
    }

    /// Echoes the request's `q` back as the translation, so sentinel tokens survive
    /// the round-trip and styling is reattached (spec §3.4).
    private final class EchoHTTPClient: HTTPClient, @unchecked Sendable {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try XCTUnwrap(request.url)
            let query =
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value ?? ""
            // Embed the query as a JSON string the parser accepts (escaping specials).
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let body = Data(#"[[["\#(escaped)","src"]],null,"en"]"#.utf8)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (body, response)
        }
    }

    func testProviderPreservesInlineStyleViaSentinelTokens() async throws {
        let styled = FormattedText(blocks: [
            FormattedText.Block(index: 0, runs: [InlineRun("hi "), InlineRun("there", style: .bold)])
        ])
        let provider = GoogleFreeProvider(client: EchoHTTPClient())
        let request = TranslationRequest(
            operationID: 1, selection: SelectionSnapshot(id: 1, source: styled),
            engine: .googleFree, target: .vi)

        let result = try await provider.translate(request)

        XCTAssertEqual(result.text.plainText, "hi there")
        let boldRun = result.text.blocks[0].runs.first { !$0.style.isEmpty }
        XCTAssertEqual(boldRun?.text, "there")
        XCTAssertEqual(boldRun?.style, .bold)
    }

    func testProviderThrowsOnHTTPError() async {
        let client = StubHTTPClient(translated: "x", detected: "en", status: 400)
        let provider = GoogleFreeProvider(client: client, maxRetries: 0)
        let request = TranslationRequest(
            operationID: 1, selection: snapshot("hello"), engine: .googleFree, target: .en)

        do {
            _ = try await provider.translate(request)
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? TranslationError, .http(status: 400))
        }
    }
}
