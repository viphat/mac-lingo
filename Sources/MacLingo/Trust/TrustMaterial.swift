import Foundation

/// Build-time trust material (spec §6.1, §9, §10).
///
/// These are compiled constants — the **only** hosts MacLingo will ever contact,
/// the compiled-default Google Free endpoint and its allowlist, the starting
/// config epoch, and the public keys used to verify remote config and Sparkle
/// updates. The two network allowlists are **never merged** (spec §9): only
/// ``translationDataHosts`` may receive selected text; only ``controlPlaneHosts``
/// are used for app machinery (config + updates) and never receive source text.
///
/// String constants (not `URL`) are intentional: the networking layer parses and
/// validates these, and the project forbids force-unwrapping `URL(string:)` in
/// non-test code (see `CLAUDE.md`).
enum TrustMaterial {

    // MARK: - Network allowlists (spec §9)

    /// Hosts that may receive selected text. The signed remote config (§6.1) may
    /// only *disable* the free provider or *switch among hosts on this list* — it
    /// can never introduce a new one.
    static let translationDataHosts: Set<String> = [
        "translate.googleapis.com",  // Google Free (unofficial endpoint)
        "translation.googleapis.com",  // Google Cloud Translation API v2
        "api.openai.com",  // OpenAI (BYOK)
        "api.deepseek.com",  // DeepSeek (BYOK)
    ]

    /// Hosts contacted for app machinery only. **Selected text is never sent here.**
    static let controlPlaneHosts: Set<String> = [
        remoteConfigHost,
        sparkleAppcastHost,
    ]

    // MARK: - Google Free endpoint (spec §6.1)

    /// Compiled-default Google Free endpoint, used unless a higher-version signed
    /// config selects a different (allowlisted) host or a sticky-disable is active.
    static let defaultGoogleFreeEndpoint =
        "https://translate.googleapis.com/translate_a/single"

    /// Known Google hosts a signed remote config may select among. A config that
    /// names any host outside this set is rejected (spec §6.1).
    static let googleFreeEndpointAllowlist: Set<String> = [
        "translate.googleapis.com"
    ]

    // MARK: - Remote config trust (spec §6.1, §10)

    /// Host serving the signed remote config (control-plane).
    /// TODO(Phase 7): set the production remote-config host.
    static let remoteConfigHost = "config.maclingo.invalid"

    /// Starting config epoch baked into this binary. The persisted *monotonic epoch
    /// floor* (spec §6.1) may be higher; configs below the floor are rejected.
    static let startingConfigEpoch: UInt32 = 1

    /// Primary config-verification public key (Ed25519, base64). Separate from the
    /// Sparkle key and from the backup key (dual-key rotation, spec §6.1).
    /// TODO(Phase 7): replace placeholder with the real public key.
    static let configPublicKeyPrimary = ""

    /// Backup config-verification public key (Ed25519, base64).
    /// TODO(Phase 7): replace placeholder with the real public key.
    static let configPublicKeyBackup = ""

    // MARK: - Sparkle update trust (spec §10)

    /// Host serving the Sparkle appcast (control-plane).
    /// TODO(Phase 8): set the production appcast host.
    static let sparkleAppcastHost = "updates.maclingo.invalid"

    /// Sparkle EdDSA (ed25519) public key, base64. Embedded so update signatures
    /// are verified before extraction (`SUPublicEDKey`).
    /// TODO(Phase 8): replace placeholder with the real public key.
    static let sparklePublicEDKey = ""
}
