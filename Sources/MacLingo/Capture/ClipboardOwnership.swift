import Foundation

/// The conservative clipboard-ownership rules (spec §4.3). Pure decision logic,
/// isolated from `NSPasteboard` so the safety-critical predicates are unit-tested.
enum ClipboardOwnership {

    /// Whether to restore the pre-copy snapshot after a synthesized copy.
    ///
    /// Restore **only if** the change count is *still* exactly the value observed
    /// right after our copy (`postCopyCount`) **and** the step from `initialCount`
    /// to `postCopyCount` was a single, unambiguous increment. Otherwise abstain —
    /// a different/extra writer touched the pasteboard and we must not clobber it
    /// (spec §4.3 step 5).
    ///
    /// - Parameters:
    ///   - initialCount: `C0`, recorded before synthesizing the copy.
    ///   - postCopyCount: `C1`, recorded right after the copy was observed.
    ///   - currentCount: the change count now, at restore time.
    static func shouldRestore(initialCount: Int, postCopyCount: Int, currentCount: Int) -> Bool {
        // Someone wrote after our copy → keep their newer content.
        guard currentCount == postCopyCount else { return false }
        // Our copy must have been exactly one step past the initial snapshot.
        return postCopyCount == initialCount + 1
    }

    /// Whether the pasteboard registered any change after the synthesized copy. If
    /// not, the copy was swallowed (e.g. browser/Electron) and we fall back to AX.
    static func didCopyProduceChange(initialCount: Int, postCopyCount: Int) -> Bool {
        postCopyCount > initialCount
    }
}
