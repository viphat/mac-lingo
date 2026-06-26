# Changelog

All notable changes to MacLingo are documented here. Dates are ISO-8601.

## [Unreleased]

### Phase 7 — Networking trust boundary, remote config & hardening (§6.1, §9)
- **Dual network allowlists** with case-insensitive host classification
  (`TrustMaterial.allowlist(for:)`): translation-data vs control-plane, never
  merged.
- **HTTP-redirect validation (P0):** `URLSession` default auto-following disabled;
  `HardenedSessionDelegate` inspects every 3xx via `RedirectValidator` — follows
  only within the same allowlist, drops the body and `Authorization`/
  `X-Goog-Api-Key` on any host change, rejects cross/off-allowlist redirects. The
  live HTTP client uses an ephemeral, non-persisting session.
- **Fail-closed remote config:** Ed25519-signed config (primary + backup keys,
  separate from Sparkle), strict endpoint allowlist, **monotonic version**, sticky
  kill-switch disable, expiring enable/endpoint directives, **clock-rollback-safe**
  expiry (monotonic high-water mark), and a **monotonic epoch floor** that makes a
  manual `.dmg` downgrade unable to resurrect a discarded sticky-disable. Applied
  atomically via reconciliation (cancel Free ops, bump `providerConfigRevision`,
  invalidate Free cache, re-resolve the active engine; pinned panels keep their
  rendered result).
- **Degraded behavior when Free is blocked:** fallback chain (AI → Cloud →
  actionable error) via the existing `EngineResolver`.
- **Local-only availability monitoring** (`AvailabilityMonitor`): on-device
  success/rate-limit/error counts surfaced in *Settings → Diagnostics*. **No
  telemetry.**

### Phase 8 — Packaging & release scaffolding (§10)
- **Sparkle** wired: `UpdateController` + "Check for Updates…" menu/settings entry;
  Info.plist trust keys (`SUFeedURL`, `SUPublicEDKey`, `SURequireSignedFeed`,
  scheduled checks). Placeholders fail closed until a release fills them.
- **Release runbook** (`docs/RELEASE.md`): signing/notarization, signed appcast +
  feed, settings-schema compatibility, config-epoch procedure, and the §12
  acceptance-matrix gate.
- **Privacy note** (`docs/PRIVACY.md`): what's sent where, the signed-config
  disclosure, no-telemetry statement.

### Notes / gates
- 👤 **Legal/ToS sign-off** on the Google Free default is still required before
  release (spec §6.1) and must be recorded here.
- 👤 Signing identity, notarization, Sparkle EdDSA key, and remote-config keys are
  release-time human tasks — see `docs/RELEASE.md`.

### Earlier phases (0–6)
- See `.agents/todo.md` for the full implementation log (menu-bar skeleton,
  settings/permissions/reconciliation, dual capture, Google Free + modal,
  formatting + markup trust boundary, BYOK AI providers + paid-confirmation + live
  reconciliation, Google Cloud v2).
