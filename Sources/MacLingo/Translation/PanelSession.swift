import Foundation

/// Headless per-panel translation lifecycle (spec §3.1, §5.3). One session backs
/// one modal panel; the AppKit `ModalController` owns a session and renders its
/// `display`. Kept free of AppKit so the operation-lifecycle invariants —
/// every-presentation-change-opens-a-new-op (incl. cache hit), apply-if-current,
/// closure invalidation, full-`CacheKey` caching — are unit-tested directly.
@MainActor
final class PanelSession {

    /// What the panel should show.
    enum Display: Equatable {
        case loading(engine: EngineID, target: TargetLanguage)
        case result(TranslationResult)
        case error(TranslationError, retryable: Bool)
        case noSelection
    }

    private let services: TranslationServiceProviding
    private let providerConfigRevision: UInt64
    let registry = RequestRegistry()

    private(set) var snapshot: SelectionSnapshot?
    private(set) var engine: EngineID
    private(set) var target: TargetLanguage
    private(set) var display: Display = .noSelection
    /// Pinned panels suppress implicit dismissal (spec §8); lifecycle-neutral here.
    var pinned = false

    private var task: Task<Void, Never>?

    /// Invoked on every `display` change so the owning view can update.
    var onChange: ((Display) -> Void)?

    init(
        services: TranslationServiceProviding,
        engine: EngineID,
        target: TargetLanguage,
        providerConfigRevision: UInt64 = 0
    ) {
        self.services = services
        self.engine = engine
        self.target = target
        self.providerConfigRevision = providerConfigRevision
    }

    // MARK: - Presentation changes (each opens a new OperationID, spec §5.3)

    /// (Re)start the session for a fresh capture — used when a transient panel is
    /// reused by a new trigger. Cancels in-flight work and clears the prior
    /// snapshot's cache (spec §3.1 transient-reuse), then starts fresh.
    func begin(snapshot: SelectionSnapshot?, engine: EngineID, target: TargetLanguage) {
        task?.cancel()
        registry.invalidateCache()
        self.snapshot = snapshot
        self.engine = engine
        self.target = target
        guard snapshot != nil else {
            registry.open()
            update(.noSelection)
            return
        }
        present()
    }

    /// Switch the active engine (engine selector / Enhance with AI).
    func switchEngine(_ engine: EngineID) {
        self.engine = engine
        present()
    }

    /// Switch the target language (inline switcher).
    func switchTarget(_ target: TargetLanguage) {
        self.target = target
        present()
    }

    /// Retry the current engine/target on the same snapshot.
    func retry() { present() }

    /// Core: cancel the in-flight task, open a **new** operation (this is what
    /// makes even a cache hit cancel a slow in-flight response), then either serve
    /// the cache synchronously or issue a request (spec §5.3).
    private func present() {
        guard let snapshot else {
            task?.cancel()
            registry.open()
            update(.noSelection)
            return
        }

        task?.cancel()
        let operationID = registry.open()
        let key = cacheKey(for: snapshot)

        if let hit = registry.cached(key) {
            update(
                .result(
                    TranslationResult(
                        operationID: operationID, text: hit.text,
                        detectedSource: hit.detectedSource, engine: hit.engine)))
            return
        }

        update(.loading(engine: engine, target: target))

        guard let service = services.service(for: engine) else {
            update(.error(.providerUnavailable, retryable: false))
            return
        }

        let request = TranslationRequest(
            operationID: operationID, selection: snapshot, engine: engine, target: target)
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
        } catch is CancellationError {
            // Superseded operation — discard silently.
        } catch {
            guard registry.isCurrent(request.operationID) else { return }
            let translationError = (error as? TranslationError) ?? .malformedResponse
            update(.error(translationError, retryable: true))
        }
    }

    /// Close/dismiss: cancel in-flight work and invalidate the operation so any
    /// late completion is rejected (spec §5.3 closure invalidation).
    func close() {
        task?.cancel()
        registry.close()
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

    private func update(_ newDisplay: Display) {
        display = newDisplay
        onChange?(newDisplay)
    }
}
