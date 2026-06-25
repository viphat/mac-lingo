import XCTest

@testable import MacLingo

/// Coverage for `RichTextCodec` (spec §3.4): sentinel + HTML tagged-segment
/// round-trips, structural validation, and degrade-to-plain on failure. Inline
/// styling is reattached from tags/tokens — never by character offset.
final class RichTextCodecTests: XCTestCase {

    private func block(_ runs: [InlineRun], kind: BlockKind = .paragraph) -> FormattedText.Block {
        FormattedText.Block(index: 3, runs: runs, kind: kind)
    }

    // MARK: - Sentinel encoding (Google Free)

    func testSentinelPlainBlockEncodesToRawText() {
        let encoded = RichTextCodec.encodeSentinel(block([InlineRun("just text")]))
        XCTAssertEqual(encoded, "just text")
    }

    func testSentinelRoundTripReattachesStyleAndPreservesKind() {
        let source = block(
            [InlineRun("hello "), InlineRun("world", style: .bold)],
            kind: .listItem(level: 2, ordered: true))
        let encoded = RichTextCodec.encodeSentinel(source)
        XCTAssertTrue(encoded.hasPrefix("hello "))
        XCTAssertNotEqual(encoded, "hello world", "styled run must be wrapped in markers")

        // Simulate a faithful translation: word order changes, markers intact.
        let decoded = RichTextCodec.decodeSentinel(encoded, original: source)
        XCTAssertEqual(decoded.index, 3)
        XCTAssertEqual(decoded.kind, .listItem(level: 2, ordered: true))
        XCTAssertEqual(decoded.runs.first { !$0.style.isEmpty }?.text, "world")
        XCTAssertEqual(decoded.runs.first { !$0.style.isEmpty }?.style, .bold)
    }

    func testSentinelTranslatorReordersAndRenamesText() {
        // The translator keeps the markers but changes the wrapped/plain text.
        let source = block([InlineRun("the "), InlineRun("cat", style: .italic)])
        let encoded = RichTextCodec.encodeSentinel(source)
        // Reproduce the marker structure with translated inner text.
        let translated = encoded.replacingOccurrences(of: "the ", with: "le ")
            .replacingOccurrences(of: "cat", with: "chat")
        let decoded = RichTextCodec.decodeSentinel(translated, original: source)
        XCTAssertEqual(decoded.text, "le chat")
        XCTAssertEqual(decoded.runs.first { !$0.style.isEmpty }?.style, .italic)
    }

    func testSentinelMissingCloseDegradesToPlain() {
        let source = block([InlineRun("a", style: .bold), InlineRun(" b")])
        let encoded = RichTextCodec.encodeSentinel(source)
        // Drop the closing marker family by removing the close char — unbalanced.
        let broken = String(encoded.prefix(while: { $0 != "\u{E001}" }))
        let decoded = RichTextCodec.decodeSentinel(broken, original: source)
        XCTAssertTrue(decoded.runs.allSatisfy { $0.style.isEmpty }, "must degrade to plain")
        XCTAssertFalse(decoded.text.contains("\u{E000}"), "markers stripped on degrade")
    }

    func testSentinelDuplicatedMarkerDegradesToPlain() {
        let source = block([InlineRun("x", style: .bold)])
        let encoded = RichTextCodec.encodeSentinel(source)
        let decoded = RichTextCodec.decodeSentinel(encoded + encoded, original: source)
        // The same id appears twice → invalid multiset → degrade.
        XCTAssertTrue(decoded.runs.allSatisfy { $0.style.isEmpty })
    }

    func testSentinelSourceContainingMarkerSkipsStyling() {
        let source = block([InlineRun("danger\u{E000}", style: .bold)])
        XCTAssertEqual(RichTextCodec.encodeSentinel(source), "danger\u{E000}")
    }

    // MARK: - HTML encoding (AI / Cloud)

    func testHTMLEncodeWrapsStylesAndEscapes() {
        let encoded = RichTextCodec.encodeHTML(
            block([InlineRun("a < b ", style: []), InlineRun("bold", style: .bold)]))
        XCTAssertEqual(encoded, "a &lt; b <b>bold</b>")
    }

    func testHTMLRoundTripReattachesStyle() {
        let source = block([InlineRun("hi ", style: []), InlineRun("there", style: [.bold, .italic])])
        let encoded = RichTextCodec.encodeHTML(source)
        let decoded = RichTextCodec.decodeHTML(encoded, original: source)
        XCTAssertEqual(decoded.text, "hi there")
        XCTAssertEqual(decoded.runs.first { !$0.style.isEmpty }?.style, [.bold, .italic])
        XCTAssertEqual(decoded.kind, .paragraph)
    }

    func testHTMLUnbalancedTagsDegradeToPlain() {
        let source = block([InlineRun("x", style: .bold)])
        // Missing closing </b>.
        let decoded = RichTextCodec.decodeHTML("<b>translated", original: source)
        XCTAssertTrue(decoded.runs.allSatisfy { $0.style.isEmpty }, "must degrade to plain")
        XCTAssertEqual(decoded.text, "translated")
    }

    func testHTMLMisnestedTagsDegradeToPlain() {
        let source = block([InlineRun("x", style: [.bold, .italic])])
        let decoded = RichTextCodec.decodeHTML("<b><i>x</b></i>", original: source)
        XCTAssertTrue(decoded.runs.allSatisfy { $0.style.isEmpty })
    }

    // MARK: - parse() dispatch

    func testParseHTMLPayload() throws {
        let rich = CapturedRich(kind: .html, data: Data("<p><b>hi</b></p>".utf8))
        let formatted = try XCTUnwrap(RichTextCodec.parse(rich))
        XCTAssertEqual(formatted.blocks[0].runs[0].style, .bold)
    }
}
