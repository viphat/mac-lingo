import XCTest

@testable import MacLingo

/// Coverage for the deterministic source-language aggregation (spec §3.2).
final class LanguageAggregatorTests: XCTestCase {

    private func block(_ text: String, _ detected: String?) -> LanguageAggregator.BlockDetection {
        LanguageAggregator.BlockDetection(sourceText: text, detected: detected)
    }

    func testNoDetectionIsUnknown() {
        let result = LanguageAggregator.aggregate([block("hello", nil), block("world", nil)])
        XCTAssertEqual(result, .unknown)
    }

    func testEmptyInputIsUnknown() {
        XCTAssertEqual(LanguageAggregator.aggregate([]), .unknown)
    }

    func testSingleLanguageIsKnown() {
        let result = LanguageAggregator.aggregate([block("bonjour", "fr"), block("salut", "fr")])
        XCTAssertEqual(result, .known(bcp47: "fr"))
    }

    func testMajorityOverFiftyPercentWins() {
        // 7 fr graphemes vs 3 en → fr is > 50%.
        let result = LanguageAggregator.aggregate([block("bonjour", "fr"), block("hey", "en")])
        XCTAssertEqual(result, .known(bcp47: "fr"))
    }

    func testExactlyFiftyPercentIsMixed() {
        // 3 vs 3 → no language exceeds 50% → mixed.
        let result = LanguageAggregator.aggregate([block("abc", "fr"), block("xyz", "en")])
        XCTAssertEqual(result, .mixed(["fr", "en"]))
    }

    func testUndetectedBlocksExcludedFromDenominator() {
        // The big undetected block must not dilute the single detected language.
        let result = LanguageAggregator.aggregate([
            block("hola", "es"),
            block(String(repeating: "x", count: 100), nil),
        ])
        XCTAssertEqual(result, .known(bcp47: "es"))
    }

    func testWhitespaceNotCounted() {
        // "a   b" has 2 non-whitespace graphemes; both attributed to one language.
        XCTAssertEqual(LanguageAggregator.nonWhitespaceGraphemeCount("a   b\n\t"), 2)
    }

    func testAllWhitespaceDetectedFallsBackToDistinctLanguage() {
        let result = LanguageAggregator.aggregate([block("   ", "ja")])
        XCTAssertEqual(result, .known(bcp47: "ja"))
    }
}
