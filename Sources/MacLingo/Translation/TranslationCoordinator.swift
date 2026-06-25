import AppKit
import OSLog

/// Drives one trigger end-to-end (spec §3.1): resolve the engine/target, run the
/// serialized capture, build an immutable `SelectionSnapshot`, and hand it to the
/// `ModalPresenter`. A new trigger cancels the in-flight capture so a superseded
/// capture never presents.
@MainActor
final class TranslationCoordinator {

    private let capturer: SelectionCapturer
    private let settings: SettingsStore
    private let presenter: ModalPresenter

    private var captureTask: Task<Void, Never>?
    /// Monotonic source identity; stable per capture (spec §5.1).
    private var snapshotCounter: SelectionSnapshotID = 0

    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "Coordinator")

    init(capturer: SelectionCapturer, settings: SettingsStore, presenter: ModalPresenter) {
        self.capturer = capturer
        self.settings = settings
        self.presenter = presenter
    }

    /// Handle a hotkey/menu trigger. Reads the cursor and settings synchronously on
    /// the main actor, then captures off-actor and presents.
    func handleTrigger() {
        let method = settings.captureMethod
        let target = settings.targetLanguage
        let engine = resolveEngine()
        let point = NSEvent.mouseLocation

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            let captured = await self.capturer.capture(method: method)
            if Task.isCancelled { return }
            self.present(captured: captured, engine: engine, target: target, at: point)
        }
    }

    private func present(
        captured: CapturedSelection?, engine: EngineID, target: TargetLanguage, at point: NSPoint
    ) {
        let snapshot: SelectionSnapshot?
        if let captured, !captured.plainText.isEmpty {
            snapshotCounter += 1
            // Phase 3: plain-text source. Phase 4 builds the rich `FormattedText`
            // from `captured.rich` via `RichTextCodec`.
            snapshot = SelectionSnapshot(
                id: snapshotCounter, source: FormattedText(plainText: captured.plainText))
        } else {
            snapshot = nil
        }
        presenter.present(snapshot: snapshot, engine: engine, target: target, at: point)
    }

    /// Resolve the engine to use via the fallback chain (spec §6.1). Phase 3 only
    /// implements Google Free; Cloud/AI configuration arrives in Phases 5–6.
    private func resolveEngine() -> EngineID {
        let available = ConfiguredEngines(
            googleFreeAvailable: true,
            googleCloudConfigured: false,
            aiProvider: nil)
        return EngineResolver.resolve(preferred: settings.defaultEngine, available: available)
    }
}
