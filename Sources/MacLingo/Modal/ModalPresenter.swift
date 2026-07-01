import AppKit

/// Manages the modal panels and the retrigger policy (spec §3.1): there is at most
/// **one transient (unpinned) panel**, reused by each new trigger; **pinned panels
/// accumulate** as independent windows until the user closes them. Also fans out
/// live provider reconciliation to every open panel (spec §5.5).
@MainActor
final class ModalPresenter {

    /// What an engine/target/policy presentation needs beyond the snapshot.
    struct Context {
        let engine: EngineID
        let target: TargetLanguage
        let availableEngines: [EngineID]
        let policy: SendPolicy
        let providerConfigRevision: UInt64
        /// The Settings-screen default this trigger resolved, ignoring any session
        /// override — what the modal's Reset action restores (spec §5.5).
        let resetEngine: EngineID
        let resetTarget: TargetLanguage
    }

    private let services: TranslationServiceProviding

    /// Invoked when any panel's paid engine rejects the key (spec §5.5).
    var onProviderUnauthorized: ((EngineID) -> Void)?
    /// Invoked when any panel commits an explicit engine/target switch, so it can be
    /// persisted as the new session override (spec §5.5).
    var onCommit: ((EngineID, TargetLanguage) -> Void)?
    /// Invoked when any panel's Reset action runs, so any persisted session
    /// override can be forgotten (spec §5.5).
    var onReset: (() -> Void)?

    /// All live controllers (for cleanup + live reconciliation fan-out).
    private var controllers: [ModalController] = []
    /// The single reusable transient panel, if one is currently open and unpinned.
    private weak var transient: ModalController?

    init(services: TranslationServiceProviding) {
        self.services = services
    }

    /// Present a capture result. Reuses the transient panel if one exists
    /// (re-anchoring at `point` and restarting its session); otherwise opens a new
    /// transient panel. Pinned panels are left untouched (spec §3.1).
    func present(snapshot: SelectionSnapshot?, context: Context, at point: NSPoint) {
        if let transient {
            transient.present(at: point, snapshot: snapshot, context: context)
            return
        }
        let controller = makeController(context: context)
        controllers.append(controller)
        transient = controller
        controller.present(at: point, snapshot: snapshot, context: context)
    }

    /// Apply a live provider change to every open panel (spec §5.5). New panels
    /// pick up the change via the next `present` (the coordinator passes the new
    /// revision in the context); existing panels reconcile in place.
    func reconcileProviders(
        revision: UInt64, availableEngines: [EngineID], resolve: (EngineID) -> EngineID
    ) {
        for controller in controllers {
            let resolved = resolve(controller.session.engine)
            controller.session.reconcile(
                revision: revision, availableEngines: availableEngines, resolvedEngine: resolved)
        }
    }

    private func makeController(context: Context) -> ModalController {
        let session = PanelSession(
            services: services, engine: context.engine, target: context.target,
            providerConfigRevision: context.providerConfigRevision,
            availableEngines: context.availableEngines, policy: context.policy,
            resetEngine: context.resetEngine, resetTarget: context.resetTarget)
        session.onProviderUnauthorized = { [weak self] engine in
            self?.onProviderUnauthorized?(engine)
        }
        let controller = ModalController(session: session)
        controller.onClosed = { [weak self] closed in self?.handleClosed(closed) }
        controller.onPinnedChange = { [weak self] changed, pinned in
            self?.handlePinChange(changed, pinned: pinned)
        }
        controller.onCommit = { [weak self] engine, target in self?.onCommit?(engine, target) }
        controller.onReset = { [weak self] in self?.onReset?() }
        return controller
    }

    private func handleClosed(_ controller: ModalController) {
        controllers.removeAll { $0 === controller }
        // `transient` is weak, so it auto-clears when the controller is released.
    }

    private func handlePinChange(_ controller: ModalController, pinned: Bool) {
        if pinned {
            // A pinned panel becomes an independent window; free the transient slot
            // so the next trigger opens a fresh transient (spec §3.1).
            if transient === controller { transient = nil }
        } else if transient == nil {
            // Unpinned and no transient in play → it becomes the reusable transient.
            transient = controller
        }
    }
}
