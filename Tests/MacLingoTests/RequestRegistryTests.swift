import XCTest

@testable import MacLingo

/// Coverage for the per-panel operation registry + cache (spec §3.1, §5.3).
@MainActor
final class RequestRegistryTests: XCTestCase {

    private func key(
        selection: SelectionSnapshotID = 1, engine: EngineID = .googleFree,
        target: TargetLanguage = .en, revision: UInt64 = 0
    ) -> CacheKey {
        CacheKey(
            selection: selection, engine: engine, target: target,
            providerConfigRevision: revision, promptVersion: 1, codecVersion: 1)
    }

    func testOpenIsMonotonicAndCurrent() {
        let registry = RequestRegistry()
        let first = registry.open()
        let second = registry.open()
        XCTAssertNotEqual(first, invalidOperationID)
        XCTAssertGreaterThan(second, first)
        XCTAssertTrue(registry.isCurrent(second))
        XCTAssertFalse(registry.isCurrent(first), "only the latest operation is current")
    }

    func testInvalidSentinelIsNeverCurrent() {
        let registry = RequestRegistry()
        registry.open()
        XCTAssertFalse(registry.isCurrent(invalidOperationID))
    }

    func testCloseRejectsEverythingAndClearsCache() {
        let registry = RequestRegistry()
        let op = registry.open()
        registry.store(
            RequestRegistry.CachedResult(
                text: FormattedText(plainText: "x"), detectedSource: .unknown, engine: .googleFree),
            for: key())
        registry.close()
        XCTAssertFalse(registry.isCurrent(op), "a post-close completion is rejected")
        XCTAssertFalse(registry.isOpen)
        XCTAssertNil(registry.cached(key()), "close clears the panel cache")
    }

    func testCacheRoundTripAndFullKeyMiss() {
        let registry = RequestRegistry()
        registry.open()
        let cached = RequestRegistry.CachedResult(
            text: FormattedText(plainText: "hola"), detectedSource: .known(bcp47: "es"),
            engine: .googleFree)
        registry.store(cached, for: key(target: .en))

        XCTAssertEqual(registry.cached(key(target: .en)), cached)
        // A different target is a different full key → miss.
        XCTAssertNil(registry.cached(key(target: .vi)))
        // A different providerConfigRevision is also a miss (spec §3.1).
        XCTAssertNil(registry.cached(key(target: .en, revision: 1)))
    }
}
