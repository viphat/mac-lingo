import Foundation

/// Stable identity of one captured source (spec §5.1, §5.3). Reused across engine
/// and target switches — switching engines never re-captures.
typealias SelectionSnapshotID = UInt64

/// Identity of a single translate/present operation (spec §5.1, §5.3). A new one
/// is opened on **every** presentation change (including a cache hit) and at the
/// start of each trigger, before capture.
typealias OperationID = UInt64

/// Sentinel for a closed/invalidated panel (spec §5.3). The issuer never hands out
/// `0`, so a completion carrying this can never pass the apply-if-current check.
let invalidOperationID: OperationID = 0

/// Monotonic issuer of `OperationID`s. A full `RequestRegistry` (current-operation
/// tracking, apply-if-current, closure invalidation) is layered on in Phase 3; this
/// is just the counter so the trigger can open an operation *before* capture (§4.3).
actor OperationIDIssuer {
    private var last: OperationID = invalidOperationID

    func next() -> OperationID {
        last += 1
        return last
    }
}
