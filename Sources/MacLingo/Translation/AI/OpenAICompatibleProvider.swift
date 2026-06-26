import Foundation

/// BYOK AI engine over an OpenAI-compatible `/chat/completions` API (spec §6.4).
/// Backs both OpenAI and DeepSeek — they differ only in base URL, default model,
/// and `EngineID`. Translates **block-by-block** and reassembles by block index
/// (spec §3.4); a single block larger than the per-chunk **token budget** is split
/// via `SelectionChunker` and rejoined within the block without adding or losing
/// line breaks (spec §6.5).
///
/// Inline styling round-trips as whitelisted **HTML tags**; the model output is
/// sanitized (§5.4) and structurally validated (§3.4) — a block (or chunk) whose
/// tags don't validate degrades to plain-within-block rather than mis-styling.
struct OpenAICompatibleProvider: TranslationService {
    let id: EngineID

    private let baseURL: String
    private let model: String
    private let apiKey: String
    private let client: HTTPClient
    private let tokenBudget: Int
    private let maxRetries: Int
    private let baseBackoff: Duration

    init(
        id: EngineID,
        baseURL: String,
        model: String,
        apiKey: String,
        client: HTTPClient = URLSessionHTTPClient(),
        tokenBudget: Int = 2_000,
        maxRetries: Int = 2,
        baseBackoff: Duration = .milliseconds(400)
    ) {
        self.id = id
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.client = client
        self.tokenBudget = tokenBudget
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let blocks = request.selection.source.blocks
        guard !blocks.isEmpty else { throw TranslationError.emptySelection }

        var translatedBlocks: [FormattedText.Block] = []
        for block in blocks {
            try Task.checkCancellation()
            translatedBlocks.append(try await translate(block: block, target: request.target))
        }

        try Task.checkCancellation()
        // AI returns only translated HTML (spec §6.4) — no machine-readable source
        // detection — so the aggregated source is `.unknown`.
        return TranslationResult(
            operationID: request.operationID,
            text: FormattedText(blocks: translatedBlocks),
            detectedSource: .unknown,
            engine: id)
    }

    /// Translate one block, splitting it into chunks only when it exceeds the token
    /// budget. Chunk runs are concatenated in order and merged, preserving the
    /// block's structure exactly.
    private func translate(
        block: FormattedText.Block, target: TargetLanguage
    ) async throws -> FormattedText.Block {
        // Whitespace-only / empty: preserve verbatim, no request (spec §6.1 parity).
        if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FormattedText.Block(index: block.index, runs: block.runs, kind: block.kind)
        }

        let pieces = SelectionChunker.split(
            runs: block.runs, budget: tokenBudget, measure: EncodedSize.tokens)

        var runs: [InlineRun] = []
        for piece in pieces {
            try Task.checkCancellation()
            let html = RichTextCodec.encodeHTML(runs: piece)
            let translated = try await chat(html: html, target: target)
            var decoded =
                RichTextCodec.decodeHTMLToRuns(translated)
                // Validation failed for this chunk → degrade it to plain (§3.4).
                ?? [InlineRun(RichTextCodec.plainFallback(translated))]
            // The HTML round-trip trims a fragment's edge whitespace; restore the
            // source piece's leading/trailing whitespace so chunk seams don't fuse
            // words or drop spaces (spec §6.5 line-break safety).
            reattachEdgeWhitespace(of: piece, to: &decoded)
            runs.append(contentsOf: decoded)
        }
        return FormattedText.Block(
            index: block.index, runs: MarkupSanitizer.mergeAdjacent(runs), kind: block.kind)
    }

    /// Restore the leading/trailing whitespace of a chunk's **source** text onto its
    /// decoded translation. The HTML tokenizer trims block-edge whitespace, which
    /// would otherwise fuse words across chunk seams.
    private func reattachEdgeWhitespace(of piece: [InlineRun], to runs: inout [InlineRun]) {
        let text = piece.map(\.text).joined()
        let leading = String(text.prefix(while: \.isWhitespace))
        let trailing = String(text.reversed().prefix(while: \.isWhitespace).reversed())
        if !leading.isEmpty { runs.insert(InlineRun(leading), at: 0) }
        if !trailing.isEmpty, !(leading.count == text.count) { runs.append(InlineRun(trailing)) }
    }

    /// One chat-completions round-trip with bounded exponential backoff on
    /// rate-limit / 5xx. A 401/403 maps to `.unauthorized` so a bad key triggers
    /// live reconciliation (spec §5.5) instead of an opaque retry loop.
    private func chat(html: String, target: TargetLanguage) async throws -> String {
        let urlRequest = try AIChatEndpoint.makeRequest(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            system: AIPrompt.system(target: target),
            user: AIPrompt.user(html: html))

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await client.data(for: urlRequest)

            if (200..<300).contains(response.statusCode) {
                return try AIChatResponseParser.parse(data)
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw TranslationError.unauthorized
            }

            let retryable = response.statusCode == 429 || (500..<600).contains(response.statusCode)
            guard retryable, attempt < maxRetries else {
                throw TranslationError.http(status: response.statusCode)
            }
            try await Task.sleep(for: baseBackoff * (1 << attempt))
            attempt += 1
        }
    }
}

/// Concrete provider configuration for the two BYOK AI engines (spec §6.4). Base
/// URLs are constants; the model is editable config, the key comes from Keychain.
extension OpenAICompatibleProvider {

    static func openAI(model: String, apiKey: String, client: HTTPClient = URLSessionHTTPClient()) -> Self {
        Self(
            id: .openAI, baseURL: "https://api.openai.com/v1", model: model, apiKey: apiKey,
            client: client)
    }

    static func deepSeek(model: String, apiKey: String, client: HTTPClient = URLSessionHTTPClient()) -> Self {
        Self(
            id: .deepSeek, baseURL: "https://api.deepseek.com", model: model, apiKey: apiKey,
            client: client)
    }
}
