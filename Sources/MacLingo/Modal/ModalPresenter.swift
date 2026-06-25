import AppKit

/// Manages the modal panels and the retrigger policy (spec §3.1): there is at most
/// **one transient (unpinned) panel**, reused by each new trigger; **pinned panels
/// accumulate** as independent windows until the user closes them.
@MainActor
final class ModalPresenter {

    private let services: TranslationServiceProviding
    private let providerConfigRevision: UInt64

    /// All live controllers (for cleanup bookkeeping).
    private var controllers: [ModalController] = []
    /// The single reusable transient panel, if one is currently open and unpinned.
    private weak var transient: ModalController?

    init(services: TranslationServiceProviding, providerConfigRevision: UInt64 = 0) {
        self.services = services
        self.providerConfigRevision = providerConfigRevision
    }

    /// Present a capture result. Reuses the transient panel if one exists
    /// (re-anchoring at `point` and restarting its session); otherwise opens a new
    /// transient panel. Pinned panels are left untouched (spec §3.1).
    func present(
        snapshot: SelectionSnapshot?, engine: EngineID, target: TargetLanguage, at point: NSPoint
    ) {
        if let transient {
            transient.present(at: point, snapshot: snapshot, engine: engine, target: target)
            return
        }
        let controller = makeController(engine: engine, target: target)
        controllers.append(controller)
        transient = controller
        controller.present(at: point, snapshot: snapshot, engine: engine, target: target)
    }

    private func makeController(engine: EngineID, target: TargetLanguage) -> ModalController {
        let session = PanelSession(
            services: services, engine: engine, target: target,
            providerConfigRevision: providerConfigRevision)
        let controller = ModalController(session: session)
        controller.onClosed = { [weak self] closed in self?.handleClosed(closed) }
        controller.onPinnedChange = { [weak self] changed, pinned in
            self?.handlePinChange(changed, pinned: pinned)
        }
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
