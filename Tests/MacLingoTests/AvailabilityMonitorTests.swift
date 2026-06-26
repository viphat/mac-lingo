import XCTest

@testable import MacLingo

/// Coverage for local-only availability monitoring (spec §6.1/§9). No telemetry —
/// these are on-device counters only.
final class AvailabilityMonitorTests: XCTestCase {

    func testCountsAndBlockRate() async {
        let monitor = AvailabilityMonitor(capacity: 10)
        await monitor.record(.success)
        await monitor.record(.success)
        await monitor.record(.rateLimited)
        await monitor.record(.error)

        let success = await monitor.totalSuccess
        let rateLimited = await monitor.totalRateLimited
        let error = await monitor.totalError
        XCTAssertEqual(success, 2)
        XCTAssertEqual(rateLimited, 1)
        XCTAssertEqual(error, 1)

        let rate = await monitor.recentBlockRate
        XCTAssertEqual(rate, 0.5, accuracy: 0.001)
    }

    func testRingBufferBounded() async {
        let monitor = AvailabilityMonitor(capacity: 3)
        await monitor.record(.error)
        await monitor.record(.success)
        await monitor.record(.success)
        await monitor.record(.success)  // evicts the first .error
        let rate = await monitor.recentBlockRate
        XCTAssertEqual(rate, 0, accuracy: 0.001, "recent window should hold only the last 3")
        // Totals are cumulative and unaffected by the ring bound.
        let error = await monitor.totalError
        XCTAssertEqual(error, 1)
    }

    func testEmptyMonitorIsZero() async {
        let monitor = AvailabilityMonitor()
        let rate = await monitor.recentBlockRate
        XCTAssertEqual(rate, 0)
    }
}
