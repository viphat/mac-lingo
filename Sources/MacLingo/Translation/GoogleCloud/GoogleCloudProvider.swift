import Foundation

/// Optional key-based engine (spec §6.2): Google Cloud Translation **v2** with the
/// API key in the `X-Goog-Api-Key` header and `format=html` for full inline-style
/// preservation. Translates **block-by-block** and reassembles by block index
/// (spec §3.4) — never by parsing the translated whitespace.
///
/// Inline styling round-trips as whitelisted **HTML tags** (`RichTextCodec`); the
/// translated HTML is sanitized (§5.4) and structurally validated (§3.4) — a block
/// whose tags don't validate degrades to plain-within-block rather than mis-styling.
/// Cloud is a **paid** engine, so it is subject to the entry-point-agnostic
/// paid-confirmation gate at the coordinator send boundary (spec §6.5).
struct GoogleCloudProvider: TranslationService {
    let id: EngineID = .googleCloud

    private let baseURL: String
    private let apiKey: String
    private let client: HTTPClient
    private let maxRetries: Int
    private let baseBackoff: Duration

    init(
        apiKey: String,
        baseURL: String = GoogleCloudEndpoint.defaultBaseURL,
        client: HTTPClient = URLSessionHTTPClient(),
        maxRetries: Int = 2,
        baseBackoff: Duration = .milliseconds(400)
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.client = client
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let blocks = request.selection.source.blocks
        guard !blocks.isEmpty else { throw TranslationError.emptySelection }

        var translatedBlocks: [FormattedText.Block] = []
        var detections: [LanguageAggregator.BlockDetection] = []

        for block in blocks {
            try Task.checkCancellation()

            // Whitespace-only / empty blocks: preserve verbatim, no request, no
            // detection (excluded from language aggregation, §3.2). Block kind is
            // carried through unchanged.
            if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translatedBlocks.append(
                    FormattedText.Block(index: block.index, runs: block.runs, kind: block.kind))
                detections.append(LanguageAggregator.BlockDetection(sourceText: block.text, detected: nil))
                continue
            }

            let html = RichTextCodec.encodeHTML(block)
            let parsed = try await translateHTML(html, target: request.target)

            var decoded =
                RichTextCodec.decodeHTMLToRuns(parsed.translatedText)
                // Validation failed for this block → degrade it to plain (§3.4).
                ?? [InlineRun(RichTextCodec.plainFallback(parsed.translatedText))]
            // The HTML round-trip trims a fragment's edge whitespace; restore the
            // block's leading/trailing whitespace so reassembly keeps line breaks
            // and word spacing exact (spec §3.4/§6.5).
            reattachEdgeWhitespace(of: block.runs, to: &decoded)

            translatedBlocks.append(
                FormattedText.Block(
                    index: block.index, runs: MarkupSanitizer.mergeAdjacent(decoded), kind: block.kind))
            detections.append(
                LanguageAggregator.BlockDetection(
                    sourceText: block.text, detected: parsed.detectedSource))
        }

        try Task.checkCancellation()
        return TranslationResult(
            operationID: request.operationID,
            text: FormattedText(blocks: translatedBlocks),
            detectedSource: LanguageAggregator.aggregate(detections),
            engine: id)
    }

    /// One Cloud v2 round-trip with bounded exponential backoff on rate-limit / 5xx.
    /// A 401/403 maps to `.unauthorized` so a bad key triggers live reconciliation
    /// (spec §5.5) instead of an opaque retry loop.
    private func translateHTML(
        _ html: String, target: TargetLanguage
    ) async throws -> GoogleCloudResponseParser.Parsed {
        let urlRequest = try GoogleCloudEndpoint.makeRequest(
            baseURL: baseURL, apiKey: apiKey, html: html, target: target)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await client.data(for: urlRequest)

            if (200..<300).contains(response.statusCode) {
                return try GoogleCloudResponseParser.parse(data)
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

    /// Restore the leading/trailing whitespace of a block's **source** runs onto its
    /// decoded translation. The HTML tokenizer trims fragment-edge whitespace, which
    /// would otherwise fuse words or drop a trailing space on reassembly.
    private func reattachEdgeWhitespace(of source: [InlineRun], to runs: inout [InlineRun]) {
        let text = source.map(\.text).joined()
        let leading = String(text.prefix(while: \.isWhitespace))
        let trailing = String(text.reversed().prefix(while: \.isWhitespace).reversed())
        if !leading.isEmpty { runs.insert(InlineRun(leading), at: 0) }
        if !trailing.isEmpty, !(leading.count == text.count) { runs.append(InlineRun(trailing)) }
    }
}
