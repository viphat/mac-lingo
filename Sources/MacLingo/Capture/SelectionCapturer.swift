import Foundation

/// Serialized, cancellation-aware text capture (spec §4.3). All captures run
/// through this single actor so two triggers can never interleave on the shared
/// pasteboard. The flow combines a clipboard-free Accessibility read with a
/// pasteboard read via a synthesized copy, guarded by the conservative
/// ownership rules in `ClipboardOwnership` / `Materializability`.
///
/// **Cancellation contract (spec §4.3, §5.3):** the synthesized-copy path always
/// *runs* its cleanup (`defer`), but the restore inside that cleanup is itself
/// gated by the ownership predicate — cleanup is guaranteed, restoration is not.
actor SelectionCapturer {
    private let accessibility: AccessibilityReading
    private let pasteboard: Pasteboarding
    private let keystroke: KeystrokeSynthesizing
    private let pollInterval: Duration
    private let maxPolls: Int

    /// - Parameters:
    ///   - pollInterval: gap between `changeCount` polls after the synthesized copy.
    ///   - maxPolls: poll attempts before giving up (≈ `maxPolls × pollInterval`
    ///     timeout; spec suggests ~200–400 ms → 20 × 20 ms by default).
    init(
        accessibility: AccessibilityReading = LiveAccessibilityReader(),
        pasteboard: Pasteboarding = LivePasteboard(),
        keystroke: KeystrokeSynthesizing = LiveKeystrokeSynthesizer(),
        pollInterval: Duration = .milliseconds(20),
        maxPolls: Int = 20
    ) {
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    /// Capture the current selection. Returns the richest available result, or
    /// `nil` when nothing is selected or the operation was cancelled mid-capture.
    ///
    /// In `.axOnly` privacy mode the pasteboard is never read, snapshotted, or
    /// mutated (spec §4.3).
    func capture(method: CaptureMethod) async -> CapturedSelection? {
        let axText = accessibility.selectedText()

        guard method == .dual else {
            // AX-only privacy mode: no synthesized copy, no clipboard mutation.
            return CaptureCombiner.combine(axPlainText: axText, pasteboard: nil)
        }

        // Step 1 — materializability pre-check. If the current clipboard holds
        // promised/non-restorable types, never synthesize a copy; fall back to AX.
        guard Materializability.canRestore(types: pasteboard.types()) else {
            return CaptureCombiner.combine(axPlainText: axText, pasteboard: nil)
        }

        // Step 2 — record C0 and snapshot every concrete item before we mutate.
        let initialCount = pasteboard.changeCount
        let snapshot = pasteboard.snapshot()

        var didSynthesize = false
        var observedC1: Int?

        // Guaranteed cleanup; restoration gated by the ownership predicate so a
        // supersede/cancel mid-copy never clobbers a clipboard we don't own.
        defer {
            if didSynthesize {
                let current = pasteboard.changeCount
                let postCopy = observedC1 ?? current
                let shouldRestore = ClipboardOwnership.shouldRestore(
                    initialCount: initialCount, postCopyCount: postCopy, currentCount: current)
                if shouldRestore {
                    pasteboard.restore(snapshot)
                }
            }
        }

        // Step 3 — synthesize ⌘C and poll for the change (cancellation-aware).
        keystroke.synthesizeCopy()
        didSynthesize = true
        do {
            for _ in 0..<maxPolls {
                try await Task.sleep(for: pollInterval)
                let current = pasteboard.changeCount
                if current > initialCount {
                    observedC1 = current
                    break
                }
            }
        } catch {
            // Cancelled mid-capture: discard the partial capture. The defer still
            // runs and restores only if the ownership predicate passes.
            return nil
        }

        // Step 4 — copy swallowed (browser/Electron) → AX fallback.
        guard observedC1 != nil else {
            return CaptureCombiner.combine(axPlainText: axText, pasteboard: nil)
        }

        let captured = pasteboard.readRichest()
        return CaptureCombiner.combine(axPlainText: axText, pasteboard: captured)
    }
}
