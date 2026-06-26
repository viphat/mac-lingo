import XCTest

@testable import MacLingo

/// Coverage for the Phase 5 send-boundary behavior (spec §6.5, §3.1, §5.5):
/// hard-cap refusal, entry-point-agnostic paid confirmation, cache-hit exemption,
/// auto-enhance (run / no-op / pause-for-confirm), and live provider reconciliation.
@MainActor
final class PanelSessionPaidTests: XCTestCase {

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
        func translate(_ request: TranslationRequest) async throws -> TranslationResult {
            counter.bump()
            return TranslationResult(
                operationID: request.operationID, text: FormattedText(plainText: text),
                detectedSource: .unknown, engine: id)
        }
    }

    private struct MockServices: TranslationServiceProviding {
        let map: [EngineID: MockService]
        func service(for engine: EngineID) -> TranslationService? { map[engine] }
    }

    private func snapshot(_ text: String, id: SelectionSnapshotID = 1) -> SelectionSnapshot {
        SelectionSnapshot(id: id, source: FormattedText(plainText: text))
    }

    private func waitUntil(
        _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("timed out", file: file, line: line)
    }

    // MARK: - Hard cap

    func testOverHardCapIsRefusedWithoutSend() {
        let counter = CallCounter()
        let services = MockServices(map: [
            .openAI: MockService(id: .openAI, counter: counter, text: "X")
        ])
        let policy = SendPolicy(hardCap: 5)
        let session = PanelSession(services: services, engine: .openAI, target: .en, policy: policy)
        session.begin(snapshot: snapshot("way too long"), engine: .openAI, target: .en, policy: policy)
        XCTAssertEqual(session.display, .error(.selectionTooLarge(limit: 5), retryable: false))
        XCTAssertEqual(counter.count, 0, "nothing is sent over the hard cap")
    }

    // MARK: - Paid confirmation

    func testPaidOverThresholdPausesForConfirmation() {
        let counter = CallCounter()
        let services = MockServices(map: [
            .openAI: MockService(id: .openAI, counter: counter, text: "AI")
        ])
        let policy = SendPolicy(paidConfirmThreshold: 3, autoSpendLimit: 0)
        let session = PanelSession(services: services, engine: .openAI, target: .en, policy: policy)
        session.begin(snapshot: snapshot("hello there"), engine: .openAI, target: .en, policy: policy)

        guard case .confirmPaid(let estimate) = session.display else {
            return XCTFail("expected a paid-confirmation pause")
        }
        XCTAssertEqual(estimate.engine, .openAI)
        XCTAssertEqual(counter.count, 0, "no spend before confirmation")
    }

    func testConfirmProceedsAndCancelReverts() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .openAI: MockService(id: .openAI, counter: counter, text: "AI")
        ])
        let policy = SendPolicy(paidConfirmThreshold: 3)
        let session = PanelSession(services: services, engine: .openAI, target: .en, policy: policy)
        session.begin(snapshot: snapshot("hello there"), engine: .openAI, target: .en, policy: policy)

        session.confirmPaidSend()
        await waitUntil { if case .result = session.display { return true } else { return false } }
        XCTAssertEqual(counter.count, 1)

        // A new target is a cache miss → re-prompt; decline → no further spend and the
        // prior applied engine/target/result is restored.
        session.switchTarget(.vi)
        guard case .confirmPaid = session.display else { return XCTFail("expected re-prompt") }
        session.cancelPaidSend()
        XCTAssertEqual(counter.count, 1, "declining never spends")
        XCTAssertEqual(session.target, .en, "declining reverts the target change")
        guard case .result = session.display else { return XCTFail("prior result restored") }
    }

    func testFreeEngineNeverPrompts() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: counter, text: "FREE")
        ])
        let policy = SendPolicy(paidConfirmThreshold: 1)  // even a tiny threshold
        let session = PanelSession(services: services, engine: .googleFree, target: .en, policy: policy)
        session.begin(snapshot: snapshot("hello there"), engine: .googleFree, target: .en, policy: policy)
        await waitUntil { if case .result = session.display { return true } else { return false } }
        XCTAssertEqual(counter.count, 1)
    }

    func testCacheHitIsExemptFromConfirmation() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .openAI: MockService(id: .openAI, counter: counter, text: "AI")
        ])
        let policy = SendPolicy(paidConfirmThreshold: 3)
        let session = PanelSession(
            services: services, engine: .openAI, target: .en,
            availableEngines: [.openAI], policy: policy)
        session.begin(
            snapshot: snapshot("hello there"), engine: .openAI, target: .en,
            availableEngines: [.openAI], policy: policy)
        session.confirmPaidSend()
        await waitUntil { if case .result = session.display { return true } else { return false } }

        // Switch target (miss → prompt → confirm), then back to .en → cache hit.
        session.switchTarget(.vi)
        session.confirmPaidSend()
        await waitUntil { if case .result = session.display { return true } else { return false } }
        let callsBefore = counter.count

        session.switchTarget(.en)
        guard case .result = session.display else {
            return XCTFail("cache hit must serve synchronously, not prompt")
        }
        XCTAssertEqual(counter.count, callsBefore, "a cache hit never spends or prompts")
    }

    // MARK: - Auto-enhance

    func testAutoEnhanceRunsAfterNonAIDefault() async {
        let free = CallCounter()
        let ai = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: free, text: "FREE"),
            .openAI: MockService(id: .openAI, counter: ai, text: "AI"),
        ])
        let policy = SendPolicy(
            paidConfirmThreshold: .max, autoEnhance: true, autoEnhanceEngine: .openAI)
        let session = PanelSession(
            services: services, engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)
        session.begin(
            snapshot: snapshot("hi"), engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)

        await waitUntil {
            if case .result(let res) = session.display { return res.engine == .openAI } else { return false }
        }
        XCTAssertEqual(free.count, 1)
        XCTAssertEqual(ai.count, 1)
        XCTAssertEqual(session.engine, .openAI)
    }

    func testAutoEnhanceNoOpWhenDefaultIsAI() async {
        let ai = CallCounter()
        let services = MockServices(map: [
            .openAI: MockService(id: .openAI, counter: ai, text: "AI")
        ])
        // Coordinator leaves autoEnhanceEngine nil when the default is AI.
        let policy = SendPolicy(
            paidConfirmThreshold: .max, autoEnhance: true, autoEnhanceEngine: nil)
        let session = PanelSession(services: services, engine: .openAI, target: .en, policy: policy)
        session.begin(snapshot: snapshot("hi"), engine: .openAI, target: .en, policy: policy)
        await waitUntil { if case .result = session.display { return true } else { return false } }
        // Give any erroneous second pass a chance to run.
        await Task.yield()
        XCTAssertEqual(ai.count, 1, "no redundant second AI call")
    }

    func testAutoEnhancePausesForConfirmationOverThreshold() async {
        let free = CallCounter()
        let ai = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: free, text: "FREE"),
            .openAI: MockService(id: .openAI, counter: ai, text: "AI"),
        ])
        let policy = SendPolicy(
            paidConfirmThreshold: 1, autoSpendLimit: 0, autoEnhance: true, autoEnhanceEngine: .openAI)
        let session = PanelSession(
            services: services, engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)
        session.begin(
            snapshot: snapshot("hello"), engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)

        await waitUntil { if case .confirmPaid = session.display { return true } else { return false } }
        XCTAssertEqual(free.count, 1)
        XCTAssertEqual(ai.count, 0, "auto-enhance must pause, never silently spend")
    }

    // MARK: - Live reconciliation

    func testReconcileReResolvesInvalidEngine() async {
        let free = CallCounter()
        let ai = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: free, text: "FREE"),
            .openAI: MockService(id: .openAI, counter: ai, text: "AI"),
        ])
        let session = PanelSession(
            services: services, engine: .openAI, target: .en,
            providerConfigRevision: 0, availableEngines: [.googleFree, .openAI])
        session.begin(
            snapshot: snapshot("hi"), engine: .openAI, target: .en,
            availableEngines: [.googleFree, .openAI])
        await waitUntil { if case .result = session.display { return true } else { return false } }

        // AI key removed mid-session → openAI invalid; reconcile to Google Free.
        session.reconcile(revision: 1, availableEngines: [.googleFree], resolvedEngine: .googleFree)
        await waitUntil {
            if case .result(let res) = session.display { return res.engine == .googleFree } else { return false }
        }
        XCTAssertEqual(session.engine, .googleFree)
        XCTAssertEqual(session.providerConfigRevision, 1)
    }

    func testReconcileBumpsRevisionAndInvalidatesCache() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: counter, text: "FREE")
        ])
        let session = PanelSession(
            services: services, engine: .googleFree, target: .en,
            providerConfigRevision: 0, availableEngines: [.googleFree])
        session.begin(
            snapshot: snapshot("hi"), engine: .googleFree, target: .en, availableEngines: [.googleFree])
        await waitUntil { counter.count == 1 }

        // Same engine still valid: reconcile invalidates cache + adopts revision.
        session.reconcile(revision: 5, availableEngines: [.googleFree], resolvedEngine: .googleFree)
        XCTAssertEqual(session.providerConfigRevision, 5)

        // Re-presenting now misses the (cleared) cache → a fresh request.
        session.retry()
        await waitUntil { counter.count == 2 }
    }

    func testPinnedPanelRetainsResultOnReconcile() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .openAI: MockService(id: .openAI, counter: counter, text: "AI")
        ])
        let session = PanelSession(
            services: services, engine: .openAI, target: .en,
            providerConfigRevision: 0, availableEngines: [.openAI])
        session.begin(snapshot: snapshot("hi"), engine: .openAI, target: .en, availableEngines: [.openAI])
        await waitUntil { if case .result = session.display { return true } else { return false } }
        session.pinned = true

        // Provider invalidated, but a pinned panel keeps its rendered result.
        session.reconcile(revision: 9, availableEngines: [.googleFree], resolvedEngine: .googleFree)
        guard case .result(let result) = session.display else {
            return XCTFail("pinned panel must retain its rendered result")
        }
        XCTAssertEqual(result.text.plainText, "AI")
        XCTAssertEqual(session.engine, .openAI, "pinned engine is not re-resolved")
    }
}
