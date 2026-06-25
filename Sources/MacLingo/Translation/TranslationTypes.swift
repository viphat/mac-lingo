import Foundation

/// Source language detected by an engine (spec §5.1). The source may be **any**
/// language, not just a target choice.
enum DetectedLanguage: Sendable, Equatable {
    /// A single dominant language (BCP-47, e.g. `"ja"`, `"fr"`).
    case known(bcp47: String)
    /// Blocks disagreed and no language held a majority (spec §3.2).
    case mixed([String])
    /// The engine returned nothing parseable.
    case unknown

    /// Short tag for the modal header.
    var displayTag: String {
        switch self {
        case .known(let bcp47): bcp47
        case .mixed: "mixed"
        case .unknown: "?"
        }
    }
}

/// Engine-agnostic intermediate model (spec §5.2). Phase 3 carries **plain-text
/// blocks only**; Phase 4 extends each block with inline runs and list metadata
/// via `RichTextCodec`. Block order is the reassembly contract — never parse the
/// translated whitespace (spec §3.4).
struct FormattedText: Sendable, Equatable {

    /// One paragraph / list item. The `index` is stable and drives reassembly.
    struct Block: Sendable, Equatable, Identifiable {
        let index: Int
        var text: String
        var id: Int { index }
    }

    /// Blocks in reassembly order (sorted by `index`).
    var blocks: [Block]

    init(blocks: [Block]) {
        self.blocks = blocks.sorted { $0.index < $1.index }
    }

    /// Build from plain text by splitting on newlines; each line becomes a block,
    /// preserving blank lines (block structure is the universal guarantee, §3.4).
    init(plainText: String) {
        let lines = plainText.components(separatedBy: "\n")
        self.blocks = lines.enumerated().map { Block(index: $0.offset, text: $0.element) }
    }

    /// Reassembled plain text, joined by `\n` in block order.
    var plainText: String {
        blocks.map(\.text).joined(separator: "\n")
    }

    var isEmpty: Bool { blocks.allSatisfy { $0.text.isEmpty } }
}

/// Immutable captured source, built once per capture (spec §5.1). Reused across
/// engine/target switches — switching never re-captures.
struct SelectionSnapshot: Sendable, Equatable {
    let id: SelectionSnapshotID
    let source: FormattedText
}

/// Result-cache key (spec §3.1, §5.1). **Always the full key** — a changed
/// model/key/prompt/codec must miss, so never key on a subset.
struct CacheKey: Hashable, Sendable {
    let selection: SelectionSnapshotID
    let engine: EngineID
    let target: TargetLanguage
    let providerConfigRevision: UInt64
    let promptVersion: UInt32
    let codecVersion: UInt32
}

/// One translate/present operation (spec §5.1).
struct TranslationRequest: Sendable {
    let operationID: OperationID
    let selection: SelectionSnapshot
    let engine: EngineID
    let target: TargetLanguage
}

/// Output of a `TranslationService`. The UI applies it **only if** `operationID`
/// is still current and the panel is open (spec §5.3).
struct TranslationResult: Sendable, Equatable {
    let operationID: OperationID
    let text: FormattedText
    let detectedSource: DetectedLanguage
    let engine: EngineID
}

/// A translation engine (spec §5.1). Adding an engine = one new conformer.
protocol TranslationService: Sendable {
    var id: EngineID { get }
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

/// Errors surfaced by translation engines and the networking layer.
enum TranslationError: Error, Equatable {
    /// Response body did not match the expected shape.
    case malformedResponse
    /// Non-2xx HTTP status.
    case http(status: Int)
    /// The resolved endpoint host is not on the translation-data allowlist (§9).
    case unsupportedHost(String)
    /// The endpoint string could not be parsed into a valid URL.
    case invalidEndpoint
    /// The engine is disabled/unconfigured (e.g. Free kill switch, missing key).
    case providerUnavailable
    /// Nothing to translate.
    case emptySelection
}

/// Version stamps that participate in the `CacheKey` (spec §5.1).
enum TranslationVersioning {
    /// Codec output shape. Phase 4 bumps this when the `RichTextCodec` changes.
    static let codecVersion: UInt32 = 1
    /// AI prompt contract. Phase 5 owns bumping this.
    static let promptVersion: UInt32 = 1
}
