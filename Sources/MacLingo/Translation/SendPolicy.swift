import Foundation

/// Spend/size policy applied at the panel's **send boundary** (spec §6.5), so the
/// paid-confirmation and hard-cap checks are entry-point-agnostic — every paid
/// cache-miss send (first op, Enhance, engine switch, target switch, retry,
/// auto-enhance) is gated through the same code path.
struct SendPolicy: Sendable, Equatable {
    /// Selections over the hard cap are refused before any send (spec §6.5).
    var hardCap: Int = 20_000
    /// Source-character threshold above which a **paid** send needs confirmation.
    var paidConfirmThreshold: Int = .max
    /// Auto-spend allowance: a paid send at or below this many characters skips
    /// confirmation. `0` = always confirm over the threshold (spec §6.5).
    var autoSpendLimit: Int = 0
    /// Whether auto-enhance is on (a single AI pass after a non-AI default).
    var autoEnhance: Bool = false
    /// The AI engine to auto-enhance to, or `nil` when auto-enhance is a no-op
    /// (AI not configured, or the default is already AI — spec §3.1).
    var autoEnhanceEngine: EngineID?

    /// Whether a paid `engine` send of `characters` source chars must pause for
    /// confirmation. Free engines are always exempt; a cache **hit** is gated out
    /// by the caller (it never reaches here). Over the threshold **and** over the
    /// auto-spend allowance → confirm.
    func requiresConfirmation(engine: EngineID, characters: Int) -> Bool {
        guard engine.isPaid else { return false }
        return characters > paidConfirmThreshold && characters > autoSpendLimit
    }
}

/// Cost estimate shown in the paid-confirmation prompt (spec §6.5).
struct PaidEstimate: Equatable, Sendable {
    let characters: Int
    let approxTokens: Int
    let engine: EngineID
    let target: TargetLanguage
}
