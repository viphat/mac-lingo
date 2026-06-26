import XCTest

@testable import MacLingo

/// Coverage for the paid-confirmation predicate (spec §6.5).
final class SendPolicyTests: XCTestCase {

    func testFreeEngineNeverRequiresConfirmation() {
        let policy = SendPolicy(paidConfirmThreshold: 0, autoSpendLimit: 0)
        XCTAssertFalse(policy.requiresConfirmation(engine: .googleFree, characters: 1_000_000))
    }

    func testPaidUnderThresholdIsExempt() {
        let policy = SendPolicy(paidConfirmThreshold: 4_000, autoSpendLimit: 0)
        XCTAssertFalse(policy.requiresConfirmation(engine: .openAI, characters: 3_999))
    }

    func testPaidOverThresholdConfirmsWhenAutoSpendZero() {
        let policy = SendPolicy(paidConfirmThreshold: 4_000, autoSpendLimit: 0)
        XCTAssertTrue(policy.requiresConfirmation(engine: .openAI, characters: 4_001))
    }

    func testAutoSpendAllowanceSkipsConfirmation() {
        // Over the threshold but within the auto-spend allowance → no confirmation.
        let policy = SendPolicy(paidConfirmThreshold: 4_000, autoSpendLimit: 6_000)
        XCTAssertFalse(policy.requiresConfirmation(engine: .googleCloud, characters: 5_000))
        // Beyond the allowance → confirmation.
        XCTAssertTrue(policy.requiresConfirmation(engine: .googleCloud, characters: 6_001))
    }
}
