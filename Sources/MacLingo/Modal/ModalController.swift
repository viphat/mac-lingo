import AppKit
import SwiftUI

/// Borderless, nonactivating panel that can still become key so it can receive
/// the Escape key (spec §8).
final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns one modal panel and all its AppKit mechanics (spec §8): hover-to-key,
/// the Esc-consuming local monitor, the local+global outside-click monitors, the
/// `resignKey`/deactivation dismissal paths, and the **Pin** contract (Pin
/// suppresses all *implicit* dismissals but never Esc or Close). Translation
/// lifecycle lives in the headless `PanelSession`.
@MainActor
final class ModalController: NSObject, NSWindowDelegate {

    let session: PanelSession
    private let model = ModalViewModel()
    private let panel: TranslationPanel
    private let hosting: NSHostingController<TranslationModalView>

    /// Called when this panel has fully closed, so the presenter can drop it.
    var onClosed: ((ModalController) -> Void)?
    /// Called when the pinned state changes, so the presenter can move the panel
    /// between its transient slot and the pinned set.
    var onPinnedChange: ((ModalController, Bool) -> Void)?
    /// Called when the session commits an explicit engine/target switch, so it can
    /// be persisted as the new session override (spec §5.5).
    var onCommit: ((EngineID, TargetLanguage) -> Void)?
    /// Called when the session's Reset action runs, so any persisted session
    /// override can be forgotten (spec §5.5).
    var onReset: (() -> Void)?

    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var isClosing = false

    init(session: PanelSession) {
        self.session = session
        let hosting = NSHostingController(rootView: TranslationModalView(model: model))
        self.hosting = hosting
        self.panel = TranslationPanel(contentViewController: hosting)
        super.init()

        configurePanel()
        wireModelActions()
        session.onChange = { [weak self] display in
            guard let self else { return }
            self.syncSelectors()
            self.model.apply(display, target: self.session.target)
            DispatchQueue.main.async { [weak self] in self?.sizeToFit() }
        }
        session.onCommit = { [weak self] engine, target in self?.onCommit?(engine, target) }
        session.onReset = { [weak self] in self?.onReset?() }
        syncSelectors()
        model.apply(session.display, target: session.target)
    }

    /// Mirror the session's engine/target/available engines into the view model so
    /// the selectors and Enhance button reflect the live state.
    private func syncSelectors() {
        model.currentEngine = session.engine
        model.currentTarget = session.target
        model.availableEngines = session.availableEngines
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.styleMask = [.borderless, .nonactivatingPanel, .resizable]
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.minSize = NSSize(width: 280, height: 80)
    }

    // Resize the panel to wrap its SwiftUI content, keeping the top-left corner
    // pinned so the panel grows downward (toward the cursor).
    private func sizeToFit() {
        hosting.view.needsLayout = true
        hosting.view.layoutSubtreeIfNeeded()
        let ideal = hosting.view.fittingSize
        guard ideal.width > 10, ideal.height > 10 else { return }
        let old = panel.frame
        guard old.width != ideal.width || old.height != ideal.height else { return }

        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let newX = min(max(old.minX, visible.minX + 8), visible.maxX - ideal.width - 8)
        let newY = max(old.maxY - ideal.height, visible.minY + 8)
        panel.setFrame(
            NSRect(x: newX, y: newY, width: ideal.width, height: ideal.height),
            display: true, animate: false)
    }

    private func wireModelActions() {
        model.onClose = { [weak self] in self?.close() }
        model.onRetry = { [weak self] in self?.session.retry() }
        model.onCopy = { [weak self] in self?.copyActiveResult() }
        model.onTogglePin = { [weak self] in self?.togglePin() }
        model.onEnhance = { [weak self] in self?.enhance() }
        model.onReset = { [weak self] in self?.session.resetToDefault() }
        model.onSwitchEngine = { [weak self] engine in self?.session.switchEngine(engine) }
        model.onSwitchTarget = { [weak self] target in self?.session.switchTarget(target) }
        model.onConfirmPaid = { [weak self] in self?.session.confirmPaidSend() }
        model.onCancelPaid = { [weak self] in self?.session.cancelPaidSend() }
        model.onHoverChange = { [weak self] hovering in
            // Hover = key (spec §8): the panel becomes key (and receives Esc)
            // without activating the owning app.
            if hovering { self?.panel.makeKeyAndOrderFront(nil) }
        }
    }

    // MARK: - Presentation

    /// Show (or re-anchor) the panel near `point`, then start/replace the session.
    func present(at point: NSPoint, snapshot: SelectionSnapshot?, context: ModalPresenter.Context) {
        isClosing = false
        session.begin(
            snapshot: snapshot, engine: context.engine, target: context.target,
            availableEngines: context.availableEngines, policy: context.policy,
            providerConfigRevision: context.providerConfigRevision,
            resetEngine: context.resetEngine, resetTarget: context.resetTarget)
        // Size to the initial (loading) state before showing, then position.
        sizeToFit()
        panel.orderFront(nil)
        position(near: point)
        installMouseMonitors()
        // After SwiftUI settles the first layout pass, snap size + position again.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeToFit()
            self.position(near: point)
        }
    }

    private func position(near point: NSPoint) {
        let screen =
            NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        // Below-right of the cursor so the panel doesn't cover the selection.
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Pin (spec §8)

    private func togglePin() {
        session.pinned.toggle()
        model.pinned = session.pinned
        onPinnedChange?(self, session.pinned)
    }

    var isPinned: Bool { session.pinned }

    /// Enhance with AI (spec §3.1): switch to the configured AI engine. The session
    /// opens a new op on the same snapshot and pauses for paid confirmation if the
    /// selection is over the threshold (spec §6.5).
    private func enhance() {
        guard let aiEngine = session.availableEngines.first(where: \.isAI) else { return }
        session.switchEngine(aiEngine)
    }

    // MARK: - Copy (spec §3.4: sanitized RTF + plain-text fallback)

    private func copyActiveResult() {
        guard case .result(let result) = session.display else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Rich RTF first so a rich editor keeps the styling that survived
        // validation; always write the plain-text fallback too.
        if let rtf = FormattedTextRenderer.rtfData(result.text) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(result.text.plainText, forType: .string)
    }

    // MARK: - Dismissal

    private func installMouseMonitors() {
        removeMouseMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        // Clicks inside other MacLingo windows/menus (own event stream).
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.window !== self?.panel { self?.dismissIfUnpinned() }
            return event
        }
        // Clicks in other applications.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.dismissIfUnpinned()
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    /// Implicit dismissal — suppressed while pinned (spec §8).
    private func dismissIfUnpinned() {
        guard !session.pinned else { return }
        close()
    }

    // MARK: - NSWindowDelegate (key/Esc lifecycle, spec §8)

    func windowDidBecomeKey(_ notification: Notification) {
        guard keyMonitor == nil else { return }
        // Local monitor consumes Esc (keyCode 53) so it never reaches the
        // previously-active app. Esc closes even when pinned.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.panel.isKeyWindow else { return event }
            self.close()
            return nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // resignKey covers Command-Tab, Space switches, and system alerts that
        // mouse monitors miss (spec §8) — implicit, so suppressed while pinned.
        dismissIfUnpinned()
    }

    // MARK: - Close

    func close() {
        guard !isClosing else { return }
        isClosing = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        removeMouseMonitors()
        session.close()
        panel.orderOut(nil)
        onClosed?(self)
    }
}
