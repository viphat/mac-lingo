import XCTest

@testable import MacLingo

/// Coverage for the OpenAI-compatible AI providers (spec §6.4): request shape +
/// host allowlist + key redaction, response parsing, the HTML round-trip over a
/// mock client, 401 → `.unauthorized`, and chunked reassembly of an oversized block.
final class AIProviderTests: XCTestCase {

    // MARK: - Endpoint builder

    func testRequestPutsKeyInHeaderNotURL() throws {
        let request = try AIChatEndpoint.makeRequest(
            baseURL: "https://api.openai.com/v1", model: "gpt-5.4-mini", apiKey: "sk-secret",
            system: "sys", user: "<b>hi</b>")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertFalse(url.absoluteString.contains("sk-secret"), "key must never be in the URL")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-secret")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testDeepSeekBasePathPreserved() throws {
        let request = try AIChatEndpoint.makeRequest(
            baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash", apiKey: "k",
            system: "s", user: "u")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
    }

    func testOffAllowlistHostRejected() {
        XCTAssertThrowsError(
            try AIChatEndpoint.makeRequest(
                baseURL: "https://evil.example.com/v1", model: "m", apiKey: "k", system: "s", user: "u")
        ) { error in
            XCTAssertEqual(error as? TranslationError, .unsupportedHost("evil.example.com"))
        }
    }

    func testRedactedDescriptionHidesKey() throws {
        let request = try AIChatEndpoint.makeRequest(
            baseURL: "https://api.openai.com/v1", model: "m", apiKey: "sk-topsecret",
            system: "s", user: "u")
        let description = AIChatEndpoint.redactedDescription(request)
        XCTAssertFalse(description.contains("sk-topsecret"))
        XCTAssertTrue(description.contains("<redacted>"))
    }

    func testResponseParserExtractsContent() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"Xin chào"}}]}"#
        XCTAssertEqual(try AIChatResponseParser.parse(Data(json.utf8)), "Xin chào")
    }

    func testResponseParserRejectsMalformed() {
        XCTAssertThrowsError(try AIChatResponseParser.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? TranslationError, .malformedResponse)
        }
    }

    // MARK: - Provider over a mock client

    /// Echoes the user message (the source HTML) back as the assistant content, so
    /// the HTML round-trip and tag reattachment are exercised end-to-end.
    private final class EchoChatClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var callCount: Int { lock.withLock { count } }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { count += 1 }
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            let userContent = messages.last?["content"] as? String ?? ""
            let reply: [String: Any] = ["choices": [["message": ["content": userContent]]]]
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
        let provider = OpenAICompatibleProvider.openAI(
            model: "gpt-5.4-mini", apiKey: "k", client: EchoChatClient())
        let request = TranslationRequest(
            operationID: 7, selection: SelectionSnapshot(id: 1, source: styled),
            engine: .openAI, target: .vi)

        let result = try await provider.translate(request)

        XCTAssertEqual(result.operationID, 7)
        XCTAssertEqual(result.engine, .openAI)
        XCTAssertEqual(result.detectedSource, .unknown)
        XCTAssertEqual(result.text.plainText, "hi there")
        let boldRun = result.text.blocks[0].runs.first { $0.style.contains(.bold) }
        XCTAssertEqual(boldRun?.text, "there")
    }

    func testProviderReassemblesByBlockIndex() async throws {
        let provider = OpenAICompatibleProvider.deepSeek(
            model: "deepseek-v4-flash", apiKey: "k", client: EchoChatClient())
        let request = TranslationRequest(
            operationID: 1,
            selection: SelectionSnapshot(id: 1, source: FormattedText(plainText: "one\ntwo\nthree")),
            engine: .deepSeek, target: .en)

        let result = try await provider.translate(request)
        XCTAssertEqual(result.text.plainText, "one\ntwo\nthree")
        XCTAssertEqual(result.text.blocks.count, 3)
    }

    func testUnauthorizedMapsToTypedError() async {
        let provider = OpenAICompatibleProvider.openAI(
            model: "m", apiKey: "bad", client: StatusClient(401))
        let request = TranslationRequest(
            operationID: 1,
            selection: SelectionSnapshot(id: 1, source: FormattedText(plainText: "hi")),
            engine: .openAI, target: .en)
        do {
            _ = try await provider.translate(request)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? TranslationError, .unauthorized)
        }
    }

    /// A single block larger than the token budget is split into multiple chunks
    /// and reassembled **exactly** (spec §6.5).
    func testOversizedBlockIsChunkedAndReassembledExactly() async throws {
        let long = String(repeating: "alpha beta gamma. ", count: 40)  // ~720 chars
        let client = EchoChatClient()
        let provider = OpenAICompatibleProvider(
            id: .openAI, baseURL: "https://api.openai.com/v1", model: "m", apiKey: "k",
            client: client, tokenBudget: 20)  // tiny budget forces many chunks
        let request = TranslationRequest(
            operationID: 1,
            selection: SelectionSnapshot(
                id: 1,
                source: FormattedText(blocks: [
                    FormattedText.Block(index: 0, runs: [InlineRun(long)])
                ])),
            engine: .openAI, target: .en)

        let result = try await provider.translate(request)
        XCTAssertEqual(result.text.blocks.count, 1, "intra-block splits must not add blocks")
        XCTAssertEqual(result.text.plainText, long, "reassembly must be exact")
        XCTAssertGreaterThan(client.callCount, 1, "the oversized block must split into chunks")
    }
}
