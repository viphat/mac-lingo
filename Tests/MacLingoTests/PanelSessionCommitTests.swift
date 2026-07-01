import XCTest

@testable import MacLingo

/// Coverage for persisting an explicit, successful in-modal target/engine switch
/// as the new default (spec §5.5, docs/superpowers/specs/2026-07-01-remember-last-translation-choice-design.md).
/// `onCommit` must fire only for user-initiated switches that actually land, never
/// for automatic engine changes (auto-enhance, live reconciliation) or declined
/// paid confirmations.
@MainActor
final class PanelSessionCommitTests: XCTestCase {

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

    private final class CommitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(EngineID, TargetLanguage)] = []
        func record(_ engine: EngineID, _ target: TargetLanguage) {
            lock.withLock { values.append((engine, target)) }
        }
        var commits: [(EngineID, TargetLanguage)] { lock.withLock { values } }
    }

    // MARK: - Explicit switches commit

    func testExplicitSwitchTargetCommitsOnResult() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: counter, text: "FREE")
        ])
        let session = PanelSession(services: services, engine: .googleFree, target: .en)
        let recorder = CommitRecorder()
        session.onCommit = { recorder.record($0, $1) }
        session.begin(snapshot: snapshot("hi"), engine: .googleFree, target: .en)
        await waitUntil { if case .result = session.display { return true } else { return false } }
        XCTAssertTrue(recorder.commits.isEmpty, "the initial trigger is not a user switch")

        session.switchTarget(.vi)
        await waitUntil { if case .result = session.display { return true } else { return false } }
        XCTAssertEqual(recorder.commits.count, 1)
        XCTAssertEqual(recorder.commits.last?.0, .googleFree)
        XCTAssertEqual(recorder.commits.last?.1, .vi)
    }

    func testExplicitSwitchEngineCommitsOnResult() async {
        let free = CallCounter()
        let cloud = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: free, text: "FREE"),
            .googleCloud: MockService(id: .googleCloud, counter: cloud, text: "CLOUD"),
        ])
        let session = PanelSession(
            services: services, engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .googleCloud])
        let recorder = CommitRecorder()
        session.onCommit = { recorder.record($0, $1) }
        session.begin(
            snapshot: snapshot("hi"), engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .googleCloud])
        await waitUntil { if case .result = session.display { return true } else { return false } }

        session.switchEngine(.googleCloud)
        await waitUntil {
            if case .result(let result) = session.display { return result.engine == .googleCloud } else { return false }
        }
        XCTAssertEqual(recorder.commits.count, 1)
        XCTAssertEqual(recorder.commits.last?.0, .googleCloud)
        XCTAssertEqual(recorder.commits.last?.1, .en)
    }

    func testCacheHitAfterExplicitSwitchStillCommits() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: counter, text: "EN")
        ])
        let session = PanelSession(services: services, engine: .googleFree, target: .en)
        let recorder = CommitRecorder()
        session.onCommit = { recorder.record($0, $1) }
        session.begin(snapshot: snapshot("hi"), engine: .googleFree, target: .en)
        await waitUntil { if case .result = session.display { return true } else { return false } }

        session.switchTarget(.vi)
        await waitUntil { if case .result = session.display { return true } else { return false } }
        session.switchTarget(.en)  // now a cache hit, served synchronously
        guard case .result = session.display else { return XCTFail("expected cache hit") }
        XCTAssertEqual(recorder.commits.last?.1, .en)
    }

    // MARK: - Automatic switches never commit

    func testAutoEnhanceSwitchDoesNotCommit() async {
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
        let recorder = CommitRecorder()
        session.onCommit = { recorder.record($0, $1) }
        session.begin(
            snapshot: snapshot("hi"), engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)

        await waitUntil {
            if case .result(let res) = session.display { return res.engine == .openAI } else { return false }
        }
        XCTAssertEqual(session.engine, .openAI)
        XCTAssertTrue(recorder.commits.isEmpty, "auto-enhance must never overwrite the user's default")
    }

    func testReconcileFallbackDoesNotCommit() async {
        let free = CallCounter()
        let ai = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: free, text: "FREE"),
            .openAI: MockService(id: .openAI, counter: ai, text: "AI"),
        ])
        let session = PanelSession(
            services: services, engine: .openAI, target: .en,
            providerConfigRevision: 0, availableEngines: [.googleFree, .openAI])
        let recorder = CommitRecorder()
        session.onCommit = { recorder.record($0, $1) }
        session.begin(
            snapshot: snapshot("hi"), engine: .openAI, target: .en,
            availableEngines: [.googleFree, .openAI])
        await waitUntil { if case .result = session.display { return true } else { return false } }

        session.reconcile(revision: 1, availableEngines: [.googleFree], resolvedEngine: .googleFree)
        await waitUntil {
            if case .result(let res) = session.display { return res.engine == .googleFree } else { return false }
        }
        XCTAssertTrue(recorder.commits.isEmpty, "a live-reconciliation fallback is not a user choice")
    }

    // MARK: - Confirmation invalidated mid-flight never commits

    /// An explicit switch into a paid engine pauses for confirmation; if the config
    /// then invalidates that engine before the user confirms, the rebuilt/resolved
    /// send must not commit the stale pre-invalidation choice (spec §5.5, §6.5).
    func testConfirmationInvalidatedByReconcileDoesNotCommit() async {
        let free = CallCounter()
        let ai = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: free, text: "FREE"),
            .openAI: MockService(id: .openAI, counter: ai, text: "AI"),
        ])
        let policy = SendPolicy(paidConfirmThreshold: 3)
        let session = PanelSession(
            services: services, engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)
        let recorder = CommitRecorder()
        session.onCommit = { recorder.record($0, $1) }
        session.begin(
            snapshot: snapshot("hello there"), engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)
        await waitUntil { if case .result = session.display { return true } else { return false } }

        session.switchEngine(.openAI)
        guard case .confirmPaid = session.display else { return XCTFail("expected a pause") }

        // The AI key is removed mid-confirmation → openAI becomes invalid; reconcile
        // falls back to Google Free (free, so it resolves without a further prompt).
        session.reconcile(revision: 1, availableEngines: [.googleFree], resolvedEngine: .googleFree)
        await waitUntil {
            if case .result(let result) = session.display {
                return result.engine == .googleFree
            } else {
                return false
            }
        }
        XCTAssertTrue(recorder.commits.isEmpty, "the stale pre-invalidation choice must never commit")
    }

    // MARK: - Declined confirmation never commits

    func testDeclinedPaidConfirmationDoesNotCommitAndStaysUsable() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .openAI: MockService(id: .openAI, counter: counter, text: "AI")
        ])
        let policy = SendPolicy(paidConfirmThreshold: 3)
        let session = PanelSession(services: services, engine: .openAI, target: .en, policy: policy)
        let recorder = CommitRecorder()
        session.onCommit = { recorder.record($0, $1) }
        session.begin(
            snapshot: snapshot("hello there"), engine: .openAI, target: .en, policy: policy)

        session.confirmPaidSend()
        await waitUntil { if case .result = session.display { return true } else { return false } }
        XCTAssertTrue(recorder.commits.isEmpty, "the initial trigger is not a user switch")

        session.switchTarget(.vi)
        guard case .confirmPaid = session.display else { return XCTFail("expected re-prompt") }
        session.cancelPaidSend()
        XCTAssertTrue(recorder.commits.isEmpty, "declining never commits")

        // A later, unrelated explicit switch must still commit correctly (i.e. the
        // pending-persist slot from the declined switch was cleared, not left stale).
        session.switchTarget(.vi)
        session.confirmPaidSend()
        await waitUntil { if case .result = session.display { return true } else { return false } }
        XCTAssertEqual(recorder.commits.count, 1)
        XCTAssertEqual(recorder.commits.last?.1, .vi)
    }
}
