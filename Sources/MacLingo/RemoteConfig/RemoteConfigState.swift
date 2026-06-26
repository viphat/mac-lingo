import Foundation

/// Persisted, fail-closed trust state for the remote config lifecycle (spec §6.1).
///
/// This is a pure value type with three operations — `normalized(forCompiledEpoch:)`,
/// `applying(_:)`, and `advanced(to:)` / `effectiveFreeState` — so the whole policy
/// (monotonic version, sticky disable, expiry, clock-rollback, epoch floor) is
/// unit-tested without any I/O. Persistence lives in ``RemoteConfigStore``.
///
/// Invariants encoded here (each a closed review bug):
/// - **Monotonic version governs trust.** A config is accepted only if its version
///   is strictly higher than the highest ever accepted in its epoch.
/// - **Disable is sticky.** Once a valid disable is accepted it stays in effect
///   past expiry, fetch failures, and clock changes; only a strictly higher-version
///   valid non-disable config re-enables.
/// - **Enable/endpoint directives expire** to the compiled default.
/// - **Clock-rollback safe.** Expiry is checked against a monotonic high-water mark
///   (`lastObserved`), so a backward clock jump can never un-expire an enable.
/// - **Monotonic epoch floor.** The highest epoch ever seen only rises; configs
///   below the floor are rejected, and raising the floor (a signed release bumping
///   the compiled epoch) **discards** prior-epoch directives — including a malicious
///   high-version sticky disable.
struct RemoteConfigState: Codable, Equatable, Sendable {
    /// Highest config epoch ever seen — a **version-independent floor** that only
    /// rises. Configs below it are rejected even on an older binary (downgrade-safe).
    var epochFloor: UInt32
    /// The epoch the held directives belong to. When the floor rises above this,
    /// the directives are discarded (epoch scoping).
    var directiveEpoch: UInt32
    /// Highest version accepted within `directiveEpoch` (anti-rollback/replay).
    var highestVersion: UInt64
    /// Whether the sticky kill switch is active.
    var disabled: Bool
    /// A selected allowlisted endpoint host (from a non-expired `selectEndpoint`).
    var endpointHost: String?
    /// Expiry of the active enable/endpoint directive (nil when none / sticky).
    var endpointExpiry: Date?
    /// Monotonic clock high-water mark: `max` of every time the state was advanced.
    /// Expiry is judged against this, never raw wall-clock (clock-rollback safe).
    var lastObserved: Date

    /// The starting state for a fresh install at `compiledEpoch`.
    static func initial(compiledEpoch: UInt32 = TrustMaterial.startingConfigEpoch) -> RemoteConfigState {
        RemoteConfigState(
            epochFloor: compiledEpoch,
            directiveEpoch: compiledEpoch,
            highestVersion: 0,
            disabled: false,
            endpointHost: nil,
            endpointExpiry: nil,
            lastObserved: Date(timeIntervalSince1970: 0))
    }

    /// Normalize at launch against the running binary's compiled epoch (spec §6.1).
    /// The floor only ever rises; if it rises **above** the held directives' epoch,
    /// those directives are discarded — this is the epoch-bump recovery that drops a
    /// malicious or mistaken high-version sticky disable.
    func normalized(forCompiledEpoch compiledEpoch: UInt32) -> RemoteConfigState {
        var next = self
        let newFloor = max(epochFloor, compiledEpoch)
        next.epochFloor = newFloor
        if directiveEpoch < newFloor {
            // Prior-epoch configs are discarded; start a clean version space.
            next.directiveEpoch = newFloor
            next.highestVersion = 0
            next.disabled = false
            next.endpointHost = nil
            next.endpointExpiry = nil
        }
        return next
    }

    /// Result of attempting to apply a verified payload.
    struct ApplyOutcome: Equatable {
        let state: RemoteConfigState
        let accepted: Bool
    }

    /// Apply a **verified** payload, fail-closed (spec §6.1). The state must already
    /// be `normalized(forCompiledEpoch:)`. Rejected (returns `accepted: false`,
    /// state unchanged) when the payload is below the epoch floor or not strictly
    /// higher-version than what's held; otherwise accepted and the held state is
    /// updated. The highest-version valid config is what's retained.
    func applying(_ payload: RemoteConfigPayload) -> ApplyOutcome {
        // Below the monotonic epoch floor → reject (downgrade-safe).
        guard payload.epoch >= epochFloor else { return ApplyOutcome(state: self, accepted: false) }

        var next = self

        // A higher-epoch config opens a fresh version space and raises the floor;
        // prior-epoch directives are discarded before the version check.
        let baseVersion: UInt64
        if payload.epoch > directiveEpoch {
            next.epochFloor = max(next.epochFloor, payload.epoch)
            next.directiveEpoch = payload.epoch
            next.disabled = false
            next.endpointHost = nil
            next.endpointExpiry = nil
            baseVersion = 0
        } else {
            baseVersion = highestVersion
        }

        // Monotonic version: must be strictly higher than the highest seen
        // (anti-rollback / anti-replay). This is also what lets a higher-version
        // non-disable config re-enable a sticky disable.
        guard payload.version > baseVersion else { return ApplyOutcome(state: self, accepted: false) }
        next.highestVersion = payload.version

        switch payload.directive {
        case .disableFree:
            next.disabled = true
            next.endpointHost = nil
            next.endpointExpiry = nil
        case .enableDefault:
            next.disabled = false
            next.endpointHost = nil
            next.endpointExpiry = nil
        case .selectEndpoint:
            next.disabled = false
            next.endpointHost = payload.endpointHost
            next.endpointExpiry = payload.expiry
        }
        return ApplyOutcome(state: next, accepted: true)
    }

    /// Advance the monotonic clock high-water mark to `max(lastObserved, now)`.
    /// Call before reading ``effectiveFreeState`` so expiry is rollback-safe.
    func advanced(to now: Date) -> RemoteConfigState {
        guard now > lastObserved else { return self }
        var next = self
        next.lastObserved = now
        return next
    }

    /// The effective Free state (spec §6.1). A sticky disable wins and ignores the
    /// clock entirely; an enable/endpoint directive expires against the monotonic
    /// high-water mark, reverting to the compiled default.
    var effectiveFreeState: EffectiveFreeState {
        if disabled { return .disabled }
        if let endpointHost {
            if let endpointExpiry, lastObserved > endpointExpiry { return .compiledDefault }
            return .endpoint(endpointHost)
        }
        return .compiledDefault
    }
}
