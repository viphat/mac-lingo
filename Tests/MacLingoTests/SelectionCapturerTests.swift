import XCTest

@testable import MacLingo

/// Behavioral coverage for the `SelectionCapturer` actor — the serialized,
/// cancellation-aware capture flow (spec §4.3). The pure predicates it relies on
/// are covered separately in `CaptureLogicTests`.
final class SelectionCapturerTests: XCTestCase {

    // MARK: - Doubles

    private struct StubAX: AccessibilityReading {
        let text: String?
        func selectedText() -> String? { text }
    }

    /// Mutable pasteboard double. The capturer is the single, serialized caller, so
    /// `@unchecked Sendable` with a lock is sufficient.
    private final class MockPasteboard: Pasteboarding, @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int
        let presentTypes: [String]
        let rich: CapturedSelection?
        /// How many steps the synthesized copy advances `changeCount` (0 = swallowed).
        let copyBump: Int
        /// Extra advance applied during `readRichest`, simulating a concurrent writer.
        let bumpOnRead: Int
        private(set) var snapshotCalls = 0
        private(set) var restoreCalls = 0
        private(set) var readCalls = 0

        init(
            startCount: Int = 100,
            presentTypes: [String] = ["public.utf8-plain-text"],
            rich: CapturedSelection? = nil,
            copyBump: Int = 1,
            bumpOnRead: Int = 0
        ) {
            self.count = startCount
            self.presentTypes = presentTypes
            self.rich = rich
            self.copyBump = copyBump
            self.bumpOnRead = bumpOnRead
        }

        var changeCount: Int { lock.withLock { count } }
        func types() -> [String] { presentTypes }

        func snapshot() -> PasteboardSnapshot {
            lock.withLock { snapshotCalls += 1 }
            return PasteboardSnapshot(items: [], changeCount: changeCount)
        }

        func readRichest() -> CapturedSelection? {
            lock.withLock {
                readCalls += 1
                count += bumpOnRead
            }
            return rich
        }

        func restore(_ snapshot: PasteboardSnapshot) {
            lock.withLock { restoreCalls += 1 }
        }

        /// Called by the keystroke double to model the copy landing on the board.
        func applyCopy() { lock.withLock { count += copyBump } }
    }

    private struct MockKeystroke: KeystrokeSynthesizing {
        let board: MockPasteboard
        func synthesizeCopy() { board.applyCopy() }
    }

    private func makeCapturer(
        ax: String?, board: MockPasteboard
    ) -> SelectionCapturer {
        SelectionCapturer(
            accessibility: StubAX(text: ax),
            pasteboard: board,
            keystroke: MockKeystroke(board: board),
            pollInterval: .milliseconds(1),
            maxPolls: 25)
    }

    // MARK: - AX-only privacy mode (no clipboard touch)

    func testAXOnlyNeverTouchesPasteboard() async {
        let board = MockPasteboard()
        let capturer = makeCapturer(ax: "hola", board: board)
        let result = await capturer.capture(method: .axOnly)
        XCTAssertEqual(result?.plainText, "hola")
        XCTAssertNil(result?.rich)
        XCTAssertEqual(board.snapshotCalls, 0)
        XCTAssertEqual(board.restoreCalls, 0)
        XCTAssertEqual(board.readCalls, 0)
    }

    // MARK: - Dual: clean single-step copy

    func testDualCleanCopyReadsRichAndRestores() async {
        let rich = CapturedSelection(
            plainText: "selected", rich: CapturedRich(kind: .rtf, data: Data([0xAA])))
        let board = MockPasteboard(rich: rich, copyBump: 1)
        let capturer = makeCapturer(ax: "ax fallback", board: board)
        let result = await capturer.capture(method: .dual)
        XCTAssertEqual(result, rich)
        XCTAssertEqual(board.restoreCalls, 1, "clean single-step copy must restore the original")
    }

    // MARK: - Dual: copy swallowed → AX fallback

    func testDualSwallowedCopyFallsBackToAX() async {
        let board = MockPasteboard(copyBump: 0)  // copy never registers
        let capturer = makeCapturer(ax: "ax text", board: board)
        let result = await capturer.capture(method: .dual)
        XCTAssertEqual(result?.plainText, "ax text")
        XCTAssertNil(result?.rich)
        XCTAssertEqual(board.readCalls, 0, "nothing to read when the copy was swallowed")
        XCTAssertEqual(board.restoreCalls, 0, "no change → nothing to restore")
    }

    // MARK: - Dual: non-materializable original → skip copy, use AX

    func testDualNonMaterializableSkipsCopy() async {
        let board = MockPasteboard(
            presentTypes: ["public.utf8-plain-text", "com.apple.pasteboard.promised-file-url"])
        let capturer = makeCapturer(ax: "ax only", board: board)
        let result = await capturer.capture(method: .dual)
        XCTAssertEqual(result?.plainText, "ax only")
        XCTAssertEqual(board.snapshotCalls, 0, "must not snapshot a clipboard it cannot restore")
        XCTAssertEqual(board.restoreCalls, 0)
    }

    // MARK: - Dual: concurrent writer after our copy → abstain from restore

    func testDualConcurrentWriterAbstainsFromRestore() async {
        let rich = CapturedSelection(plainText: "x", rich: nil)
        // Copy lands (+1) then a writer bumps again during the read (+1).
        let board = MockPasteboard(rich: rich, copyBump: 1, bumpOnRead: 1)
        let capturer = makeCapturer(ax: "ax", board: board)
        _ = await capturer.capture(method: .dual)
        XCTAssertEqual(board.restoreCalls, 0, "a write after our copy must not be clobbered")
    }

    // MARK: - Dual: ambiguous multi-step copy → abstain from restore

    func testDualAmbiguousMultiStepAbstainsFromRestore() async {
        let rich = CapturedSelection(plainText: "x", rich: nil)
        let board = MockPasteboard(rich: rich, copyBump: 2)  // C0 -> C0+2 in one observation
        let capturer = makeCapturer(ax: "ax", board: board)
        _ = await capturer.capture(method: .dual)
        XCTAssertEqual(board.restoreCalls, 0, "ambiguous multi-step change must not restore")
    }

    // MARK: - Cancellation mid-capture

    func testCancellationMidCaptureReturnsNil() async {
        let board = MockPasteboard(copyBump: 0, bumpOnRead: 0)  // never breaks the poll loop
        let capturer = SelectionCapturer(
            accessibility: StubAX(text: "ax"),
            pasteboard: board,
            keystroke: MockKeystroke(board: board),
            pollInterval: .milliseconds(10),
            maxPolls: 100)
        let task = Task { await capturer.capture(method: .dual) }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result, "a cancelled capture is discarded")
        XCTAssertEqual(board.restoreCalls, 0, "no change landed → cleanup restores nothing")
    }
}
