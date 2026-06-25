import XCTest

@testable import MacLingo

/// Coverage for the headless per-panel translation lifecycle (spec §5.3):
/// apply-if-current, cache-hit-opens-new-op, closure invalidation, error handling.
@MainActor
final class PanelSessionTests: XCTestCase {

    // MARK: - Doubles

    /// Releasable suspension point so a translation can be held mid-flight.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private struct MockService: TranslationService {
        let id: EngineID
        let counter: CallCounter
        let text: String
        let detected: DetectedLanguage
        let gate: Gate?
        let failure: TranslationError?

        func translate(_ request: TranslationRequest) async throws -> TranslationResult {
            counter.bump()
            if let gate { await gate.wait() }
            // Intentionally does NOT honor cancellation — so apply-if-current alone
            // must reject stale/post-close completions (spec §5.3).
            if let failure { throw failure }
            return TranslationResult(
                operationID: request.operationID,
                text: FormattedText(plainText: text),
                detectedSource: detected,
                engine: id)
        }
    }

    private struct MockServices: TranslationServiceProviding {
        let map: [EngineID: MockService]
        func service(for engine: EngineID) -> TranslationService? { map[engine] }
    }

    private func snapshot(_ id: SelectionSnapshotID = 1, _ text: String = "hello") -> SelectionSnapshot {
        SelectionSnapshot(id: id, source: FormattedText(plainText: text))
    }

    /// Spin the main-actor executor until `predicate` holds or we time out.
    private func waitUntil(
        _ predicate: () -> Bool, _ message: String = "timed out",
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail(message, file: file, line: line)
    }

    // MARK: - Tests

    func testNoSelectionShowsNoSelection() {
        let services = MockServices(map: [:])
        let session = PanelSession(services: services, engine: .googleFree, target: .en)
        session.begin(snapshot: nil, engine: .googleFree, target: .en)
        XCTAssertEqual(session.display, .noSelection)
    }

    func testResultAppliesAndIsCached() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(
                id: .googleFree, counter: counter, text: "OUT",
                detected: .known(bcp47: "fr"), gate: nil, failure: nil)
        ])
        let session = PanelSession(services: services, engine: .googleFree, target: .en)
        session.begin(snapshot: snapshot(), engine: .googleFree, target: .en)

        await waitUntil { if case .result = session.display { return true } else { return false } }
        guard case .result(let result) = session.display else { return XCTFail("expected result") }
        XCTAssertEqual(result.text.plainText, "OUT")
        XCTAssertEqual(counter.count, 1)
    }

    func testCacheHitServesSynchronouslyAndOpensNewOp() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(
                id: .googleFree, counter: counter, text: "EN",
                detected: .known(bcp47: "fr"), gate: nil, failure: nil)
        ])
        let session = PanelSession(services: services, engine: .googleFree, target: .en)
        session.begin(snapshot: snapshot(), engine: .googleFree, target: .en)
        await waitUntil { if case .result = session.display { return true } else { return false } }

        // Switch target (miss → would call service, but our single mock returns "EN"
        // regardless); then switch back to .en, which must be a cache hit.
        session.switchTarget(.vi)
        await waitUntil { if case .result = session.display { return true } else { return false } }
        let callsAfterVi = counter.count

        let opBefore = session.registry.current
        session.switchTarget(.en)
        // Cache hit is synchronous: result is present on the same turn.
        guard case .result(let result) = session.display else {
            return XCTFail("cache hit should present synchronously")
        }
        XCTAssertEqual(result.text.plainText, "EN")
        XCTAssertGreaterThan(session.registry.current, opBefore, "a cache hit still opens a new op")
        XCTAssertEqual(counter.count, callsAfterVi, "a cache hit issues no request")
    }

    func testStaleResultIsRejectedAfterSwitch() async {
        let slowCounter = CallCounter()
        let fastCounter = CallCounter()
        let gate = Gate()
        let services = MockServices(map: [
            .googleFree: MockService(
                id: .googleFree, counter: slowCounter, text: "SLOW",
                detected: .unknown, gate: gate, failure: nil),
            .googleCloud: MockService(
                id: .googleCloud, counter: fastCounter, text: "FAST",
                detected: .unknown, gate: nil, failure: nil),
        ])
        let session = PanelSession(services: services, engine: .googleFree, target: .en)
        session.begin(snapshot: snapshot(), engine: .googleFree, target: .en)
        await waitUntil { slowCounter.count == 1 }  // slow op in-flight (gated)

        // Switch to the fast engine; its result becomes current.
        session.switchEngine(.googleCloud)
        await waitUntil { if case .result = session.display { return true } else { return false } }

        // Release the slow op: it returns carrying the stale operation id → rejected.
        await gate.open()
        await Task.yield()
        await Task.yield()
        guard case .result(let result) = session.display else { return XCTFail("expected result") }
        XCTAssertEqual(result.text.plainText, "FAST", "stale result must not overwrite the newer one")
    }

    func testLateCompletionAfterCloseIsRejected() async {
        let counter = CallCounter()
        let gate = Gate()
        let services = MockServices(map: [
            .googleFree: MockService(
                id: .googleFree, counter: counter, text: "LATE",
                detected: .unknown, gate: gate, failure: nil)
        ])
        let session = PanelSession(services: services, engine: .googleFree, target: .en)
        session.begin(snapshot: snapshot(), engine: .googleFree, target: .en)
        await waitUntil { counter.count == 1 }

        session.close()
        XCTAssertFalse(session.registry.isOpen)

        await gate.open()  // completion arrives after close → must be rejected
        await Task.yield()
        await Task.yield()
        if case .result = session.display {
            XCTFail("a completion after close must not mutate the panel")
        }
    }

    func testErrorIsSurfacedWhenCurrent() async {
        let services = MockServices(map: [
            .googleFree: MockService(
                id: .googleFree, counter: CallCounter(), text: "",
                detected: .unknown, gate: nil, failure: .http(status: 503))
        ])
        let session = PanelSession(services: services, engine: .googleFree, target: .en)
        session.begin(snapshot: snapshot(), engine: .googleFree, target: .en)

        await waitUntil { if case .error = session.display { return true } else { return false } }
        guard case .error(let error, let retryable) = session.display else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(error, .http(status: 503))
        XCTAssertTrue(retryable)
    }

    func testUnavailableEngineSurfacesProviderUnavailable() {
        let services = MockServices(map: [:])  // nothing registered
        let session = PanelSession(services: services, engine: .openAI, target: .en)
        session.begin(snapshot: snapshot(), engine: .openAI, target: .en)
        XCTAssertEqual(session.display, .error(.providerUnavailable, retryable: false))
    }
}
