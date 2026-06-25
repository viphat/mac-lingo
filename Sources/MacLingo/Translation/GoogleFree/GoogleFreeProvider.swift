import Foundation

/// Default engine (spec §6.1): the unofficial, key-free Google Free endpoint.
/// Translates **block-by-block** and reassembles by block index (spec §3.4) —
/// never by parsing the translated whitespace. Plain text only in Phase 3; inline
/// styling via validated placeholder tokens lands in Phase 4.
struct GoogleFreeProvider: TranslationService {
    let id: EngineID = .googleFree

    private let endpoint: String
    private let client: HTTPClient
    private let maxRetries: Int
    private let baseBackoff: Duration

    init(
        endpoint: String = TrustMaterial.defaultGoogleFreeEndpoint,
        client: HTTPClient = URLSessionHTTPClient(),
        maxRetries: Int = 2,
        baseBackoff: Duration = .milliseconds(300)
    ) {
        self.endpoint = endpoint
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
            // detection (excluded from language aggregation, §3.2).
            if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translatedBlocks.append(FormattedText.Block(index: block.index, text: block.text))
                detections.append(LanguageAggregator.BlockDetection(sourceText: block.text, detected: nil))
                continue
            }

            let parsed = try await translateBlock(block.text, target: request.target)
            translatedBlocks.append(
                FormattedText.Block(index: block.index, text: parsed.translated))
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

    /// Translate one block with bounded exponential backoff on rate-limit / 5xx.
    private func translateBlock(
        _ text: String, target: TargetLanguage
    ) async throws -> GoogleFreeResponseParser.Parsed {
        let urlRequest = try GoogleFreeEndpoint.makeRequest(
            endpoint: endpoint, text: text, target: target)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await client.data(for: urlRequest)

            if (200..<300).contains(response.statusCode) {
                return try GoogleFreeResponseParser.parse(data)
            }

            let retryable = response.statusCode == 429 || (500..<600).contains(response.statusCode)
            guard retryable, attempt < maxRetries else {
                throw TranslationError.http(status: response.statusCode)
            }
            // Exponential backoff (300 ms, 600 ms, …); cancellation-aware.
            try await Task.sleep(for: baseBackoff * (1 << attempt))
            attempt += 1
        }
    }
}
