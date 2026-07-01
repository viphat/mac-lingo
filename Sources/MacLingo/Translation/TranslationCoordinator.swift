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
        let context = makeContext()
        let point = NSEvent.mouseLocation

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            let captured = await self.capturer.capture(method: method)
            if Task.isCancelled { return }
            self.present(captured: captured, context: context, at: point)
        }
    }

    private func present(
        captured: CapturedSelection?, context: ModalPresenter.Context, at point: NSPoint
    ) {
        let snapshot: SelectionSnapshot?
        if let captured, !captured.plainText.isEmpty {
            snapshotCounter += 1
            // Prefer the sanitized rich representation (spec §5.4 parse-step
            // sanitization); fall back to plain text if there's no rich payload or
            // it couldn't be safely parsed (§3.4 degrade-to-plain).
            let source =
                captured.rich.flatMap(RichTextCodec.parse) ?? FormattedText(plainText: captured.plainText)
            snapshot = SelectionSnapshot(id: snapshotCounter, source: source)
        } else {
            snapshot = nil
        }
        presenter.present(snapshot: snapshot, context: context, at: point)
    }

    /// Build the presentation context from current settings: the resolved engine
    /// (spec §6.1 fallback chain), seeded from any session override
    /// (`lastUsedEngine`/`lastUsedTargetLanguage`) and falling back to the
    /// Settings-screen default; the configured engine selector list; the
    /// spend/size policy (spec §6.5); the current provider-config revision; and the
    /// Settings-screen default alone (ignoring the override), for the modal's Reset
    /// action (spec §5.5).
    private func makeContext() -> ModalPresenter.Context {
        let configured = settings.configuredEngines
        let engine = EngineResolver.resolve(
            preferredEngine: settings.lastUsedEngine, fallback: settings.defaultEngine,
            available: configured)
        let target = settings.lastUsedTargetLanguage ?? settings.targetLanguage
        let available = Self.availableEngines(configured)

        // Auto-enhance (spec §3.1): only after a non-AI default, only if an AI
        // engine is configured — a no-op (nil) otherwise.
        let aiEngine = configured.aiProvider?.engineID
        let autoEnhanceEngine: EngineID? =
            (settings.autoEnhance && !engine.isAI) ? aiEngine : nil

        let policy = SendPolicy(
            paidConfirmThreshold: settings.paidConfirmThreshold,
            autoSpendLimit: settings.autoSpendLimit,
            autoEnhance: settings.autoEnhance,
            autoEnhanceEngine: autoEnhanceEngine)

        let resetEngine = EngineResolver.resolve(preferred: settings.defaultEngine, available: configured)

        return ModalPresenter.Context(
            engine: engine, target: target, availableEngines: available,
            policy: policy, providerConfigRevision: settings.providerConfigRevision,
            resetEngine: resetEngine, resetTarget: settings.targetLanguage)
    }

    /// Concrete engines the modal may switch among, given what's configured.
    static func availableEngines(_ configured: ConfiguredEngines) -> [EngineID] {
        var engines: [EngineID] = []
        if configured.googleFreeAvailable { engines.append(.googleFree) }
        if configured.googleCloudConfigured { engines.append(.googleCloud) }
        if let ai = configured.aiProvider?.engineID { engines.append(ai) }
        return engines
    }
}
