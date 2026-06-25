import XCTest

@testable import MacLingo

/// Unit coverage for the safety-critical capture predicates (spec §4.3). These
/// encode the clipboard-ownership invariants that protect the user's clipboard.
final class CaptureLogicTests: XCTestCase {

    // MARK: - Conservative restore (spec §4.3 step 5)

    func testRestoresAfterCleanSingleStepCopy() {
        // C0=5, our copy -> C1=6, nothing else wrote -> current=6. Safe to restore.
        XCTAssertTrue(
            ClipboardOwnership.shouldRestore(initialCount: 5, postCopyCount: 6, currentCount: 6))
    }

    func testAbstainsWhenSomeoneWroteAfterOurCopy() {
        // User copied during the window: current advanced past C1 -> keep theirs.
        XCTAssertFalse(
            ClipboardOwnership.shouldRestore(initialCount: 5, postCopyCount: 6, currentCount: 7))
    }

    func testAbstainsWhenChangeWasAmbiguousMultiStep() {
        // C0=5 -> C1=8: more than one write happened during the copy -> abstain.
        XCTAssertFalse(
            ClipboardOwnership.shouldRestore(initialCount: 5, postCopyCount: 8, currentCount: 8))
    }

    func testDidCopyProduceChange() {
        XCTAssertTrue(ClipboardOwnership.didCopyProduceChange(initialCount: 5, postCopyCount: 6))
        XCTAssertFalse(ClipboardOwnership.didCopyProduceChange(initialCount: 5, postCopyCount: 5))
    }

    // MARK: - Materializability pre-check (spec §4.3 step 1)

    func testPlainAndRichTypesAreRestorable() {
        XCTAssertTrue(
            Materializability.canRestore(types: [
                "public.utf8-plain-text", "public.rtf", "public.html",
            ]))
    }

    func testPromisedFileTypesAreNotRestorable() {
        XCTAssertFalse(
            Materializability.canRestore(types: [
                "public.utf8-plain-text", "com.apple.pasteboard.promised-file-url",
            ]))
        XCTAssertFalse(Materializability.isRestorable("com.acme.promised-thing"))
    }

    func testEmptyPasteboardIsRestorable() {
        XCTAssertTrue(Materializability.canRestore(types: []))
    }

    // MARK: - Richest-result combine (spec §4.3 "Combine")

    func testPasteboardRichWins() {
        let rich = CapturedSelection(
            plainText: "hi", rich: CapturedRich(kind: .rtf, data: Data([0x01])))
        let result = CaptureCombiner.combine(axPlainText: "ax text", pasteboard: rich)
        XCTAssertEqual(result, rich)
        XCTAssertNotNil(result?.rich)
    }

    func testAXPlainPreferredWhenNoRich() {
        let pbPlain = CapturedSelection(plainText: "pasteboard plain", rich: nil)
        let result = CaptureCombiner.combine(axPlainText: "ax plain", pasteboard: pbPlain)
        XCTAssertEqual(result?.plainText, "ax plain")
        XCTAssertNil(result?.rich)
    }

    func testFallsBackToPasteboardPlainWhenAXEmpty() {
        let pbPlain = CapturedSelection(plainText: "pasteboard plain", rich: nil)
        let result = CaptureCombiner.combine(axPlainText: "", pasteboard: pbPlain)
        XCTAssertEqual(result?.plainText, "pasteboard plain")
    }

    func testNothingSelectedReturnsNil() {
        XCTAssertNil(CaptureCombiner.combine(axPlainText: nil, pasteboard: nil))
        XCTAssertNil(CaptureCombiner.combine(axPlainText: "", pasteboard: nil))
    }
}
