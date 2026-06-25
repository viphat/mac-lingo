import Foundation

/// Per-panel operation lifecycle and result cache (spec §3.1, §5.3). Each modal
/// panel owns one registry: it tracks **one current `OperationID`** plus the
/// panel's open/closed state, and enforces the apply-if-current rule that keeps a
/// late response from overwriting a newer state.
///
/// `@MainActor` because the panel state it guards is UI state.
@MainActor
final class RequestRegistry {

    /// A cached translation, keyed by the full `CacheKey` (spec §3.1).
    struct CachedResult: Equatable, Sendable {
        let text: FormattedText
        let detectedSource: DetectedLanguage
        let engine: EngineID
    }

    private var counter: OperationID = invalidOperationID
    private(set) var current: OperationID = invalidOperationID
    /// Whether the panel is open. A result applies only while open (spec §5.3).
    private(set) var isOpen = false
    private var cache: [CacheKey: CachedResult] = [:]

    /// Open a **new** operation. Called on every presentation change — first op,
    /// engine/target switch, retry, auto-enhance, **and a cache hit** (spec §5.3)
    /// — so a slow in-flight response can never overwrite what the user switched
    /// to. The caller cancels the in-flight `Task` separately.
    @discardableResult
    func open() -> OperationID {
        counter += 1
        current = counter
        isOpen = true
        return current
    }

    /// Apply-if-current: a result applies **only if** its operation is still the
    /// current one **and** the panel is open (spec §5.3). The invalid sentinel
    /// never matches, so post-close completions are rejected.
    func isCurrent(_ operationID: OperationID) -> Bool {
        isOpen && operationID != invalidOperationID && operationID == current
    }

    /// Close/dismiss: enter the **closed** state, set the current operation to the
    /// invalid sentinel, and drop the panel's cache (spec §5.3). Any completion
    /// arriving afterward — even one carrying the previously-current id — fails
    /// `isCurrent` and is rejected.
    func close() {
        current = invalidOperationID
        isOpen = false
        cache.removeAll()
    }

    // MARK: - Result cache (full `CacheKey` only — never a subset, spec §3.1)

    func cached(_ key: CacheKey) -> CachedResult? { cache[key] }

    func store(_ result: CachedResult, for key: CacheKey) { cache[key] = result }

    /// Drop all cached results (e.g. a live `providerConfigRevision` bump in Phase 5
    /// that should force a miss). The revision is part of the key, so this is belt
    /// and braces.
    func invalidateCache() { cache.removeAll() }
}
