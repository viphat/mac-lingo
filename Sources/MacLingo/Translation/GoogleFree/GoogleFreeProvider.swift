import Foundation

/// Default engine (spec §6.1): the unofficial, key-free Google Free endpoint.
/// Translates **block-by-block** and reassembles by block index (spec §3.4) —
/// never by parsing the translated whitespace. Inline styling is carried through
/// the plain-text endpoint as **validated sentinel tokens** (`RichTextCodec`); a
/// block whose tokens don't round-trip cleanly degrades to plain-within-block.
struct GoogleFreeProvider: TranslationService {
    let id: EngineID = .googleFree

    private let endpoint: String
    private let client: HTTPClient
    private let maxRetries: Int
    private let baseBackoff: Duration
    /// Local-only availability monitoring (spec §6.1/§9). No telemetry — outcomes
    /// are recorded on-device for the diagnostics readout only.
    private let monitor: AvailabilityMonitor?

    init(
        endpoint: String = TrustMaterial.defaultGoogleFreeEndpoint,
        client: HTTPClient = URLSessionHTTPClient(),
        maxRetries: Int = 2,
        baseBackoff: Duration = .milliseconds(300),
        monitor: AvailabilityMonitor? = nil
    ) {
        self.endpoint = endpoint
        self.client = client
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff
        self.monitor = monitor
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

            // Carry inline styling through as sentinel tokens; on validation failure
            // `decodeSentinel` degrades that block to plain-within-block (§3.4).
            let encoded = RichTextCodec.encodeSentinel(block)
            let parsed = try await translateBlock(encoded, target: request.target)
            translatedBlocks.append(RichTextCodec.decodeSentinel(parsed.translated, original: block))
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
                await monitor?.record(.success)
                return try GoogleFreeResponseParser.parse(data)
            }

            let retryable = response.statusCode == 429 || (500..<600).contains(response.statusCode)
            guard retryable, attempt < maxRetries else {
                await monitor?.record(response.statusCode == 429 ? .rateLimited : .error)
                throw TranslationError.http(status: response.statusCode)
            }
            // Exponential backoff (300 ms, 600 ms, …); cancellation-aware.
            try await Task.sleep(for: baseBackoff * (1 << attempt))
            attempt += 1
        }
    }
}
