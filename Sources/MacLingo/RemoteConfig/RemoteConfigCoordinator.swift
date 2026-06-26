import AppKit
import OSLog

/// Orchestrates the remote-config lifecycle (spec §6.1): normalize at launch
/// against the compiled epoch, fetch best-effort (launch, periodically while
/// running, on foreground), verify + apply fail-closed, persist, and publish the
/// resulting ``EffectiveFreeState`` to the caller — which applies it atomically via
/// `StateReconciler` (cancel Free ops, bump `providerConfigRevision`, invalidate
/// Free cache, re-resolve the active engine).
///
/// All trust decisions live in the pure ``RemoteConfigState`` / ``RemoteConfigVerifier``;
/// this type is thin glue so timing and I/O stay out of the tested core.
@MainActor
final class RemoteConfigCoordinator {
    /// Default periodic refresh interval (spec §6.1: every 12 h, jittered).
    static let baseInterval: TimeInterval = 12 * 60 * 60

    private let store: RemoteConfigStore
    private let verifier: RemoteConfigVerifier
    private let fetcher: RemoteConfigFetcher
    private let compiledEpoch: UInt32
    private let now: @MainActor () -> Date
    private let onEffectiveState: @MainActor (EffectiveFreeState) -> Void

    private var state: RemoteConfigState
    private var lastPublished: EffectiveFreeState?
    private var periodicTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "RemoteConfig")

    init(
        store: RemoteConfigStore,
        verifier: RemoteConfigVerifier = RemoteConfigVerifier(),
        fetcher: RemoteConfigFetcher = RemoteConfigFetcher(),
        compiledEpoch: UInt32 = TrustMaterial.startingConfigEpoch,
        now: @escaping @MainActor () -> Date = { Date() },
        onEffectiveState: @escaping @MainActor (EffectiveFreeState) -> Void
    ) {
        self.store = store
        self.verifier = verifier
        self.fetcher = fetcher
        self.compiledEpoch = compiledEpoch
        self.now = now
        self.onEffectiveState = onEffectiveState
        // Seed from disk (or fresh), then normalize for this binary's epoch — this
        // is where an epoch bump discards prior-epoch configs (spec §6.1).
        let loaded = store.load() ?? .initial(compiledEpoch: compiledEpoch)
        self.state = loaded.normalized(forCompiledEpoch: compiledEpoch)
    }

    /// Run at launch: persist the normalized state, publish the current effective
    /// state (so a sticky disable from a prior session takes effect immediately,
    /// even offline), start periodic + foreground refresh, and kick a first fetch.
    func start() {
        advanceAndPublish(force: true)
        store.save(state)
        observeForeground()
        startPeriodic()
        Task { await self.refresh() }
    }

    /// Stop timers/observers (app teardown / tests).
    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    /// One best-effort fetch + verify + apply cycle (spec §6.1). Network/verify
    /// failures are swallowed — the last trusted state stands (fail-closed).
    func refresh() async {
        let signed: SignedRemoteConfig
        do {
            signed = try await fetcher.fetch()
        } catch {
            log.notice("remote-config fetch failed (keeping last trusted state)")
            advanceAndPublish(force: false)
            return
        }
        guard let payload = verifier.verify(signed) else {
            log.error("remote-config rejected: invalid signature / payload / endpoint")
            advanceAndPublish(force: false)
            return
        }
        applyVerified(payload)
    }

    /// Apply a verified payload through the pure state machine and publish if the
    /// effective state changed. Exposed for tests.
    func applyVerified(_ payload: RemoteConfigPayload) {
        // Re-normalize defensively in case the payload carries a higher epoch.
        let outcome = state.normalized(forCompiledEpoch: compiledEpoch).applying(payload)
        if outcome.accepted {
            state = outcome.state
            store.save(state)
            log.notice("remote-config accepted: v\(payload.version) epoch \(payload.epoch)")
        } else {
            log.notice("remote-config rejected fail-closed (below floor / not higher-version)")
        }
        advanceAndPublish(force: false)
    }

    /// The effective state as of `now` — for tests / diagnostics.
    var currentEffectiveState: EffectiveFreeState { state.effectiveFreeState }

    // MARK: - Private

    private func advanceAndPublish(force: Bool) {
        state = state.advanced(to: now())
        store.save(state)
        let effective = state.effectiveFreeState
        guard force || effective != lastPublished else { return }
        lastPublished = effective
        onEffectiveState(effective)
    }

    private func startPeriodic() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.jitteredInterval() else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    private func jitteredInterval() -> TimeInterval {
        // ±10% jitter so fleets of clients don't synchronize (spec §6.1).
        let jitter = Double.random(in: 0.9...1.1)
        return Self.baseInterval * jitter
    }

    private func observeForeground() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
    }
}
