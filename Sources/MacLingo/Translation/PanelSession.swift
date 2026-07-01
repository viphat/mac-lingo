import Foundation

/// Headless per-panel translation lifecycle (spec §3.1, §5.3). One session backs
/// one modal panel; the AppKit `ModalController` owns a session and renders its
/// `display`. Kept free of AppKit so the operation-lifecycle invariants —
/// every-presentation-change-opens-a-new-op (incl. cache hit), apply-if-current,
/// closure invalidation, full-`CacheKey` caching, the entry-point-agnostic
/// paid-confirmation / hard-cap gate, and auto-enhance — are unit-tested directly.
@MainActor
final class PanelSession {

    /// What the panel should show.
    enum Display: Equatable {
        case loading(engine: EngineID, target: TargetLanguage)
        case result(TranslationResult)
        case error(TranslationError, retryable: Bool)
        /// A paid send is paused awaiting confirmation (spec §6.5).
        case confirmPaid(PaidEstimate)
        case noSelection
    }

    private let services: TranslationServiceProviding
    private(set) var providerConfigRevision: UInt64
    let registry = RequestRegistry()

    private(set) var snapshot: SelectionSnapshot?
    private(set) var engine: EngineID
    private(set) var target: TargetLanguage
    private(set) var display: Display = .noSelection
    /// Engines the modal may switch among (the configured engines, spec §3.1).
    private(set) var availableEngines: [EngineID]
    private var policy: SendPolicy
    /// Pinned panels suppress implicit dismissal (spec §8) and retain their rendered
    /// result across a live `providerConfigRevision` bump (spec §5.5).
    var pinned = false

    /// A paid send held at the confirmation gate; resumed by `confirmPaidSend`.
    private struct PendingSend {
        let service: TranslationService
        let request: TranslationRequest
        let key: CacheKey
    }

    /// A successfully applied presentation, restored verbatim if a confirmation is
    /// declined so no spend leaves a half-changed panel.
    private struct AppliedState {
        let engine: EngineID
        let target: TargetLanguage
        let display: Display
    }

    private var task: Task<Void, Never>?
    private var pending: PendingSend?
    private var lastApplied: AppliedState?
    /// One auto-enhance pass per capture (spec §3.1).
    private var didAutoEnhance = false

    /// Invoked on every `display` change so the owning view can update.
    var onChange: ((Display) -> Void)?
    /// Invoked when a paid engine rejects the key (HTTP 401/403) on the current
    /// operation, so live reconciliation can mark it unconfigured (spec §5.5).
    var onProviderUnauthorized: ((EngineID) -> Void)?
    /// Invoked when an explicit, user-initiated engine/target switch actually lands
    /// (spec §5.5 "remember last choice"), so the owner can persist it as the new
    /// default. Never fires for automatic switches (auto-enhance, live-reconciliation
    /// fallback) or a declined paid confirmation.
    var onCommit: ((EngineID, TargetLanguage) -> Void)?

    /// An explicit switch armed here, consumed by `update(_:)` once it lands as a
    /// `.result` (spec §5.5). Cleared without firing on decline/close/new capture.
    private var pendingCommit: (engine: EngineID, target: TargetLanguage)?

    init(
        services: TranslationServiceProviding,
        engine: EngineID,
        target: TargetLanguage,
        providerConfigRevision: UInt64 = 0,
        availableEngines: [EngineID]? = nil,
        policy: SendPolicy = SendPolicy()
    ) {
        self.services = services
        self.engine = engine
        self.target = target
        self.providerConfigRevision = providerConfigRevision
        self.availableEngines = availableEngines ?? [engine]
        self.policy = policy
    }

    // MARK: - Presentation changes (each opens a new OperationID, spec §5.3)

    /// (Re)start the session for a fresh capture — used when a transient panel is
    /// reused by a new trigger. Cancels in-flight work and clears the prior
    /// snapshot's cache (spec §3.1 transient-reuse), then starts fresh.
    func begin(
        snapshot: SelectionSnapshot?,
        engine: EngineID,
        target: TargetLanguage,
        availableEngines: [EngineID]? = nil,
        policy: SendPolicy? = nil,
        providerConfigRevision: UInt64? = nil
    ) {
        task?.cancel()
        registry.invalidateCache()
        self.snapshot = snapshot
        self.engine = engine
        self.target = target
        if let availableEngines { self.availableEngines = availableEngines }
        if let policy { self.policy = policy }
        if let providerConfigRevision { self.providerConfigRevision = providerConfigRevision }
        self.didAutoEnhance = false
        self.lastApplied = nil
        self.pendingCommit = nil
        guard snapshot != nil else {
            registry.open()
            update(.noSelection)
            return
        }
        present()
    }

    /// Switch the active engine (engine selector / Enhance with AI) — a user choice,
    /// persisted as the new default once it lands (spec §5.5).
    func switchEngine(_ engine: EngineID) {
        pendingCommit = (engine, target)
        applyEngine(engine)
    }

    /// Switch the target language (inline switcher) — a user choice, persisted as
    /// the new default once it lands (spec §5.5).
    func switchTarget(_ target: TargetLanguage) {
        pendingCommit = (engine, target)
        applyTarget(target)
    }

    /// Non-persisting engine switch for automatic changes (auto-enhance, live
    /// reconciliation) that must never overwrite the user's chosen default.
    private func applyEngine(_ engine: EngineID) {
        self.engine = engine
        present()
    }

    /// Non-persisting target switch, mirroring `applyEngine`.
    private func applyTarget(_ target: TargetLanguage) {
        self.target = target
        present()
    }

    /// Retry the current engine/target on the same snapshot.
    func retry() { present() }

    /// Core: cancel the in-flight task, open a **new** operation (this is what
    /// makes even a cache hit cancel a slow in-flight response), then serve the
    /// cache synchronously, refuse over the hard cap, pause for paid confirmation,
    /// or issue a request (spec §5.3, §6.5).
    private func present() {
        guard let snapshot else {
            task?.cancel()
            registry.open()
            update(.noSelection)
            return
        }

        task?.cancel()
        pending = nil
        let operationID = registry.open()
        let key = cacheKey(for: snapshot)

        // Cache hit: serve synchronously, never spends — exempt from the gate.
        if let hit = registry.cached(key) {
            update(
                .result(
                    TranslationResult(
                        operationID: operationID, text: hit.text,
                        detectedSource: hit.detectedSource, engine: hit.engine)))
            return
        }

        // Hard cap: refuse before any send, regardless of engine (spec §6.5).
        let characters = sourceCharacterCount(snapshot)
        if characters > policy.hardCap {
            update(.error(.selectionTooLarge(limit: policy.hardCap), retryable: false))
            return
        }

        guard let service = services.service(for: engine) else {
            update(.error(.providerUnavailable, retryable: false))
            return
        }

        let request = TranslationRequest(
            operationID: operationID, selection: snapshot, engine: engine, target: target)

        // Entry-point-agnostic paid confirmation (spec §6.5): pause every paid
        // cache-miss send over the threshold, however it was triggered.
        if policy.requiresConfirmation(engine: engine, characters: characters) {
            pending = PendingSend(service: service, request: request, key: key)
            update(
                .confirmPaid(
                    PaidEstimate(
                        characters: characters,
                        approxTokens: EncodedSize.tokens(snapshot.source.plainText),
                        engine: engine, target: target)))
            return
        }

        issue(service: service, request: request, key: key)
    }

    /// The user approved a paused paid send (spec §6.5): issue it under the same
    /// operation that opened the confirmation.
    func confirmPaidSend() {
        guard case .confirmPaid = display, let pending else { return }
        self.pending = nil
        update(.loading(engine: pending.request.engine, target: pending.request.target))
        issue(service: pending.service, request: pending.request, key: pending.key)
    }

    /// The user declined a paused paid send (spec §6.5): no spend, restore the last
    /// applied engine/target/result (e.g. the non-AI default behind an auto-enhance
    /// prompt), or `noSelection` if nothing had applied yet.
    func cancelPaidSend() {
        guard case .confirmPaid = display else { return }
        pending = nil
        pendingCommit = nil
        if let last = lastApplied {
            engine = last.engine
            target = last.target
            update(last.display)
        } else {
            update(.noSelection)
        }
    }

    private func issue(service: TranslationService, request: TranslationRequest, key: CacheKey) {
        update(.loading(engine: request.engine, target: request.target))
        task = Task { [weak self] in
            await self?.run(service: service, request: request, key: key)
        }
    }

    private func run(
        service: TranslationService, request: TranslationRequest, key: CacheKey
    ) async {
        do {
            let result = try await service.translate(request)
            // Apply-if-current: a stale/late result never overwrites a newer state.
            guard registry.isCurrent(result.operationID) else { return }
            registry.store(
                RequestRegistry.CachedResult(
                    text: result.text, detectedSource: result.detectedSource, engine: result.engine),
                for: key)
            update(.result(result))
            maybeAutoEnhance(after: result)
        } catch is CancellationError {
            // Superseded operation — discard silently.
        } catch {
            guard registry.isCurrent(request.operationID) else { return }
            let translationError = (error as? TranslationError) ?? .malformedResponse
            // A 401/403 is not retryable here — the provider is now unconfigured
            // and live reconciliation (driven externally) removes it (spec §5.5).
            let retryable = translationError != .unauthorized
            update(.error(translationError, retryable: retryable))
            if translationError == .unauthorized {
                onProviderUnauthorized?(request.engine)
            }
        }
    }

    /// After a non-AI default result, run a single AI pass if auto-enhance is on and
    /// an AI engine is configured (spec §3.1). No-op when the default is already AI
    /// (the coordinator leaves `autoEnhanceEngine` nil), or once it has already run.
    private func maybeAutoEnhance(after result: TranslationResult) {
        guard policy.autoEnhance, !didAutoEnhance,
            let aiEngine = policy.autoEnhanceEngine,
            !result.engine.isAI, aiEngine != engine
        else { return }
        didAutoEnhance = true
        applyEngine(aiEngine)  // re-presents → pauses for confirmation if over threshold
    }

    /// Close/dismiss: cancel in-flight work and invalidate the operation so any
    /// late completion is rejected (spec §5.3 closure invalidation).
    func close() {
        task?.cancel()
        pending = nil
        pendingCommit = nil
        registry.close()
    }

    // MARK: - Live provider reconciliation (spec §5.5)

    /// Apply a live provider change: adopt the new revision, invalidate the cache,
    /// cancel in-flight work, and re-resolve the engine if the current one became
    /// invalid. A **pinned** panel retains its already-rendered result unchanged;
    /// its prior cache entries are unreachable under the new revision, so any later
    /// switch misses and re-resolves (spec §5.5).
    func reconcile(revision: UInt64, availableEngines: [EngineID], resolvedEngine: EngineID) {
        providerConfigRevision = revision
        self.availableEngines = availableEngines
        registry.invalidateCache()

        let engineInvalid = !availableEngines.contains(engine)

        // A held confirmation captured a service built from the OLD config (key /
        // model / provider). The config just changed, so that service is stale —
        // drop it and rebuild the confirmation against the new config so a later
        // confirm can never send a stale key. This applies to pinned panels too: a
        // paused confirmation is not a rendered result, and re-presenting only
        // re-shows the prompt (no spend) (spec §5.5, §6.5).
        if case .confirmPaid = display {
            task?.cancel()
            pending = nil
            if engineInvalid {
                engine = resolvedEngine
                // The config just invalidated the engine this held confirmation was
                // armed for; any pending user commit referred to that stale engine.
                pendingCommit = nil
            }
            present()
            return
        }

        guard !pinned else { return }

        if engineInvalid {
            task?.cancel()
            applyEngine(resolvedEngine)
        } else if case .loading = display {
            // Mid-flight under the old config → redo under the new revision.
            present()
        }
        // A settled, still-valid result is left in place; its cache was cleared, so
        // the next presentation change misses and re-resolves (spec §5.5).
    }

    // MARK: - Helpers

    private func cacheKey(for snapshot: SelectionSnapshot) -> CacheKey {
        CacheKey(
            selection: snapshot.id,
            engine: engine,
            target: target,
            providerConfigRevision: providerConfigRevision,
            promptVersion: TranslationVersioning.promptVersion,
            codecVersion: TranslationVersioning.codecVersion)
    }

    private func sourceCharacterCount(_ snapshot: SelectionSnapshot) -> Int {
        snapshot.source.blocks.reduce(0) { $0 + $1.text.count }
    }

    private func update(_ newDisplay: Display) {
        display = newDisplay
        if case .result = newDisplay {
            lastApplied = AppliedState(engine: engine, target: target, display: newDisplay)
            if let pendingCommit {
                self.pendingCommit = nil
                onCommit?(pendingCommit.engine, pendingCommit.target)
            }
        }
        onChange?(newDisplay)
    }
}
