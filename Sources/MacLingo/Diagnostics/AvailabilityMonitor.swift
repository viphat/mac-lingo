import Foundation

/// **Local-only** availability monitoring (spec §6.1, §9): on-device counts of
/// Google Free successes / rate-limits / errors, exposed in diagnostics. There is
/// **no telemetry** — nothing here is ever sent off the device. A bounded ring of
/// recent outcomes feeds a simple recent-block-rate readout the user can see when
/// the free endpoint is flaky.
///
/// An `actor` so providers can record outcomes from any task without a data race.
actor AvailabilityMonitor {
    enum Outcome: Equatable, Sendable {
        case success
        /// HTTP 429 / explicit block from the unofficial endpoint.
        case rateLimited
        /// Any other failure (network, 5xx, parse).
        case error
    }

    private let capacity: Int
    private var recent: [Outcome] = []

    private(set) var totalSuccess = 0
    private(set) var totalRateLimited = 0
    private(set) var totalError = 0

    init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    func record(_ outcome: Outcome) {
        switch outcome {
        case .success: totalSuccess += 1
        case .rateLimited: totalRateLimited += 1
        case .error: totalError += 1
        }
        recent.append(outcome)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
    }

    /// Fraction of recent outcomes that were rate-limited or errored (0...1).
    var recentBlockRate: Double {
        guard !recent.isEmpty else { return 0 }
        let bad = recent.filter { $0 != .success }.count
        return Double(bad) / Double(recent.count)
    }

    /// A human-readable snapshot for the diagnostics panel (no network).
    var snapshot: String {
        let pct = Int((recentBlockRate * 100).rounded())
        return """
            Google Free — ok: \(totalSuccess), rate-limited: \(totalRateLimited), \
            errors: \(totalError), recent block rate: \(pct)%
            """
    }
}
