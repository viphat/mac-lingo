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

/// Inline character styling preserved across translation (spec §5.2, §5.4). The
/// allowlist is **exactly** {bold, italic, underline, code}; everything else is
/// stripped at the `MarkupSanitizer` / `RichTextCodec` boundary.
struct InlineStyle: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let bold = InlineStyle(rawValue: 1 << 0)
    static let italic = InlineStyle(rawValue: 1 << 1)
    static let underline = InlineStyle(rawValue: 1 << 2)
    static let code = InlineStyle(rawValue: 1 << 3)
}

/// A maximal run of text sharing one inline style (spec §5.2). Styling is carried
/// on the run, never reapplied by character offset (spec §3.4).
struct InlineRun: Sendable, Equatable {
    var text: String
    var style: InlineStyle

    init(_ text: String, style: InlineStyle = []) {
        self.text = text
        self.style = style
    }
}

/// A block's structural role (spec §5.2). List items carry a nesting level and an
/// ordered/unordered marker; the marker is rendered, never sent for translation.
enum BlockKind: Sendable, Equatable {
    case paragraph
    case listItem(level: Int, ordered: Bool)
}

/// Engine-agnostic intermediate model (spec §5.2): an ordered list of blocks, each
/// a sequence of styled inline runs. Block order is the reassembly contract — never
/// parse the translated whitespace (spec §3.4). Built by `RichTextCodec` from
/// sanitized RTF/HTML, or from plain text when no rich payload is available.
struct FormattedText: Sendable, Equatable {

    /// One paragraph / list item. The `index` is stable and drives reassembly.
    struct Block: Sendable, Equatable, Identifiable {
        let index: Int
        var runs: [InlineRun]
        var kind: BlockKind
        var id: Int { index }

        init(index: Int, runs: [InlineRun], kind: BlockKind = .paragraph) {
            self.index = index
            self.runs = runs.isEmpty ? [InlineRun("")] : runs
            self.kind = kind
        }

        /// Plain convenience: a single unstyled run.
        init(index: Int, text: String, kind: BlockKind = .paragraph) {
            self.init(index: index, runs: [InlineRun(text)], kind: kind)
        }

        /// Concatenated run text (no list marker).
        var text: String { runs.map(\.text).joined() }

        /// True when no run carries inline styling — the block can skip tagged
        /// encoding and translate as plain text (spec §3.4).
        var isPlain: Bool { runs.allSatisfy { $0.style.isEmpty } }
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
    /// A paid engine rejected the key (HTTP 401/403). Marks the provider
    /// **unconfigured** and triggers live reconciliation (spec §5.5, §6.2).
    case unauthorized
    /// The selection exceeds the hard cap; refused before any send (spec §6.5).
    case selectionTooLarge(limit: Int)
}

/// Version stamps that participate in the `CacheKey` (spec §5.1).
enum TranslationVersioning {
    /// Codec output shape (the `RichTextCodec` encoding). Bumped to 2 in Phase 4
    /// when blocks gained inline runs + list metadata, so any cached Phase 3
    /// plain-text result misses (spec §3.1, §5.1).
    static let codecVersion: UInt32 = 2
    /// AI prompt contract. Phase 5 owns bumping this.
    static let promptVersion: UInt32 = 1
}
