import XCTest

@testable import MacLingo

/// Coverage for the modal's Reset action (spec §5.5, "remember last choice" +
/// its escape hatch): revert the current session to the Settings-screen default,
/// without re-arming it as a new "last used" (`onCommit` must not fire), and tell
/// the owner to forget any session override (`onReset` must fire).
@MainActor
final class PanelSessionResetTests: XCTestCase {

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

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commits: [(EngineID, TargetLanguage)] = []
        private var resets = 0
        func recordCommit(_ engine: EngineID, _ target: TargetLanguage) {
            lock.withLock { commits.append((engine, target)) }
        }
        func recordReset() { lock.withLock { resets += 1 } }
        var commitCount: Int { lock.withLock { commits.count } }
        var resetCount: Int { lock.withLock { resets } }
    }

    // MARK: - Reverts to the Settings default, not the session override

    func testResetRevertsEngineAndTarget() async {
        let free = CallCounter()
        let cloud = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: free, text: "FREE"),
            .googleCloud: MockService(id: .googleCloud, counter: cloud, text: "CLOUD"),
        ])
        let session = PanelSession(
            services: services, engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .googleCloud],
            resetEngine: .googleFree, resetTarget: .en)
        session.begin(
            snapshot: snapshot("hi"), engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .googleCloud])
        await waitUntil { if case .result = session.display { return true } else { return false } }

        session.switchEngine(.googleCloud)
        session.switchTarget(.vi)
        await waitUntil {
            if case .result(let result) = session.display {
                return result.engine == .googleCloud
            } else {
                return false
            }
        }
        XCTAssertEqual(session.engine, .googleCloud)
        XCTAssertEqual(session.target, .vi)

        session.resetToDefault()
        await waitUntil {
            if case .result(let result) = session.display {
                return result.engine == .googleFree
            } else {
                return false
            }
        }
        XCTAssertEqual(session.engine, .googleFree)
        XCTAssertEqual(session.target, .en)
    }

    // MARK: - Never re-commits, always notifies the owner to forget the override

    func testResetDoesNotCommitButFiresOnReset() async {
        let counter = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: counter, text: "FREE")
        ])
        let session = PanelSession(
            services: services, engine: .googleFree, target: .en,
            resetEngine: .googleFree, resetTarget: .en)
        let recorder = EventRecorder()
        session.onCommit = { recorder.recordCommit($0, $1) }
        session.onReset = { recorder.recordReset() }
        session.begin(snapshot: snapshot("hi"), engine: .googleFree, target: .en)
        await waitUntil { if case .result = session.display { return true } else { return false } }

        session.switchTarget(.vi)
        await waitUntil { if case .result = session.display { return true } else { return false } }
        XCTAssertEqual(recorder.commitCount, 1, "the explicit switch commits as usual")

        session.resetToDefault()
        await waitUntil { if case .result = session.display { return true } else { return false } }
        XCTAssertEqual(recorder.commitCount, 1, "reset must not re-arm a commit")
        XCTAssertEqual(recorder.resetCount, 1, "reset must notify the owner to forget the override")
    }

    // MARK: - Re-arms auto-enhance eligibility, like a fresh trigger

    func testResetReArmsAutoEnhance() async {
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
            availableEngines: [.googleFree, .openAI], policy: policy,
            resetEngine: .googleFree, resetTarget: .en)
        session.begin(
            snapshot: snapshot("hi"), engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)
        // Auto-enhance already ran once for this capture.
        await waitUntil {
            if case .result(let res) = session.display { return res.engine == .openAI } else { return false }
        }
        XCTAssertEqual(ai.count, 1)

        // Switching back to the non-AI engine does NOT re-trigger auto-enhance —
        // `didAutoEnhance` still guards this capture (one pass per capture, spec
        // §3.1), so it's a cache hit that stays on the non-AI engine.
        session.switchEngine(.googleFree)
        guard case .result(let afterSwitch) = session.display else { return XCTFail("expected a result") }
        XCTAssertEqual(afterSwitch.engine, .googleFree, "a plain switch never re-arms auto-enhance")
        XCTAssertEqual(free.count, 1, "switching back to the cached default is a cache hit")

        // Force a cache miss (as a live provider-config change would) so the reset
        // below issues a genuine request rather than replaying the cached result —
        // auto-enhance only follows a real (non-cached) response, by design.
        session.reconcile(
            revision: session.providerConfigRevision, availableEngines: [.googleFree, .openAI],
            resolvedEngine: .googleFree)

        // Reset re-arms it: the freshly re-issued non-AI default is immediately
        // upgraded again, exactly as it would be on a fresh trigger.
        session.resetToDefault()
        await waitUntil {
            if case .result(let res) = session.display { return res.engine == .openAI } else { return false }
        }
        XCTAssertEqual(session.engine, .openAI, "reset re-armed auto-enhance for the restored default")
        XCTAssertEqual(free.count, 2, "the reset re-issued the non-AI default before enhancing")
        XCTAssertEqual(ai.count, 2, "auto-enhance ran a second time for the reset capture")
    }

    // MARK: - Cancels a held paid confirmation without spending

    func testResetCancelsHeldConfirmationWithoutSpending() async {
        let free = CallCounter()
        let ai = CallCounter()
        let services = MockServices(map: [
            .googleFree: MockService(id: .googleFree, counter: free, text: "FREE"),
            .openAI: MockService(id: .openAI, counter: ai, text: "AI"),
        ])
        let policy = SendPolicy(paidConfirmThreshold: 3)
        let session = PanelSession(
            services: services, engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy,
            resetEngine: .googleFree, resetTarget: .en)
        session.begin(
            snapshot: snapshot("hello there"), engine: .googleFree, target: .en,
            availableEngines: [.googleFree, .openAI], policy: policy)
        await waitUntil { if case .result = session.display { return true } else { return false } }

        session.switchEngine(.openAI)
        guard case .confirmPaid = session.display else { return XCTFail("expected a pause") }

        session.resetToDefault()
        await waitUntil {
            if case .result(let result) = session.display {
                return result.engine == .googleFree
            } else {
                return false
            }
        }
        XCTAssertEqual(ai.count, 0, "resetting away from a held confirmation must never spend")
    }
}
