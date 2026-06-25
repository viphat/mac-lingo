import Foundation

/// Stable identity of one captured source (spec §5.1, §5.3). Reused across engine
/// and target switches — switching engines never re-captures.
typealias SelectionSnapshotID = UInt64

/// Identity of a single translate/present operation (spec §5.1, §5.3). A new one
/// is opened on **every** presentation change (including a cache hit) and at the
/// start of each trigger, before capture.
typealias OperationID = UInt64

/// Sentinel for a closed/invalidated panel (spec §5.3). `RequestRegistry` never
/// hands out `0`, so a completion carrying this can never pass apply-if-current.
let invalidOperationID: OperationID = 0
