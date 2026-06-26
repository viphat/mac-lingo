import XCTest

@testable import MacLingo

/// Coverage for `SelectionChunker` (spec §6.5): exact reassembly, oversized-run
/// splitting (sentence → word → grapheme), and line-break safety.
final class SelectionChunkerTests: XCTestCase {

    private let tokens: (String) -> Int = EncodedSize.tokens

    func testSmallRunsArePackedAndReassembleExactly() {
        let runs = [InlineRun("Hello "), InlineRun("world", style: .bold), InlineRun("!")]
        let pieces = SelectionChunker.split(runs: runs, budget: 1_000, measure: tokens)
        XCTAssertEqual(pieces.count, 1, "small content fits one chunk")
        XCTAssertEqual(joined(pieces), "Hello world!")
    }

    func testOversizedRunSplitsAndReassembles() {
        let text = String(repeating: "The quick brown fox. ", count: 30)
        let pieces = SelectionChunker.split(
            runs: [InlineRun(text)], budget: 10, measure: tokens)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(joined(pieces), text, "concatenation must reproduce the input exactly")
        // Every chunk fits the budget (or is a single indivisible grapheme run).
        for piece in pieces {
            let pieceText = piece.map(\.text).joined()
            XCTAssertTrue(tokens(pieceText) <= 10 || Array(pieceText).count <= 1)
        }
    }

    func testSplitTextPreservesNewlinesExactly() {
        let text = "line one\nline two\nline three that is a bit longer than the rest"
        let pieces = SelectionChunker.splitText(text, budget: 5, measure: tokens)
        XCTAssertEqual(pieces.joined(), text, "no newline added or lost")
    }

    func testStylePreservedAcrossSplit() {
        let text = String(repeating: "word ", count: 40)
        let pieces = SelectionChunker.split(
            runs: [InlineRun(text, style: .italic)], budget: 8, measure: tokens)
        for piece in pieces {
            for run in piece {
                XCTAssertEqual(run.style, .italic, "split sub-runs keep the original style")
            }
        }
        XCTAssertEqual(joined(pieces), text)
    }

    func testCJKWithoutSpacesSplitsByGrapheme() {
        let text = String(repeating: "你好世界", count: 20)  // no whitespace
        let pieces = SelectionChunker.splitText(text, budget: 3, measure: tokens)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), text)
    }

    private func joined(_ pieces: [[InlineRun]]) -> String {
        pieces.flatMap { $0 }.map(\.text).joined()
    }
}
