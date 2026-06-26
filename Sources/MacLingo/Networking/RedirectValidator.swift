import Foundation

/// Pure decision for an HTTP 3xx redirect (spec §9, P0). A redirect is followed
/// **only if** its destination host is on the **same** allowlist as the original
/// request; cross- or off-allowlist redirects are rejected. When a followed
/// redirect changes host, the request **body and sensitive headers**
/// (`Authorization`, `X-Goog-Api-Key`) are never forwarded — so selected text and
/// credentials cannot be exfiltrated via a redirect from an otherwise-allowlisted
/// endpoint.
///
/// This type is intentionally pure (host strings in, decision out) so the whole
/// policy is unit-tested without the network; the `URLSession` delegate that
/// applies it lives in ``HardenedSessionDelegate``.
enum RedirectValidator {

    /// Sensitive request headers that must never cross to a different host.
    static let sensitiveHeaders = ["Authorization", "X-Goog-Api-Key"]

    enum Decision: Equatable {
        /// Same host: follow as-is.
        case follow
        /// Same allowlist, different host: follow but strip the body and sensitive
        /// headers first.
        case followStripped
        /// Cross-allowlist, off-allowlist, or unparsable: do not follow (error).
        case reject
    }

    /// Decide how to handle a redirect from `originalHost` to `newHost`.
    static func decide(originalHost: String?, newHost: String?) -> Decision {
        guard let originalHost, let newHost else { return .reject }

        let originalList = TrustMaterial.allowlist(for: originalHost)
        let newList = TrustMaterial.allowlist(for: newHost)

        // A request that didn't originate on an allowlist should never have been
        // made; an off-allowlist destination is always rejected.
        guard originalList != .none, newList == originalList else { return .reject }

        // Host comparison is case-insensitive (DNS is) so a cosmetic case change
        // isn't treated as a different host.
        return originalHost.caseInsensitiveCompare(newHost) == .orderedSame
            ? .follow : .followStripped
    }
}
