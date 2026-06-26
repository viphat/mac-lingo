# MacLingo — Release Checklist (Phase 8)

Companion to `MacLingo-spec.md` §10 and `MacLingo-plan.md` Phase 8. This is the
operator runbook for cutting a notarized v1 `.dmg` with signed Sparkle updates.
Several steps are **human-only** (they need a signing identity, paid accounts, or
legal judgement) and cannot be done from a coding session — they are marked 👤.

---

## 0. Prerequisites (one-time)

- 👤 **Apple Developer ID Application** certificate installed; set
  `DEVELOPMENT_TEAM` in `project.yml` (currently empty).
- 👤 **Notarization credentials** (`xcrun notarytool store-credentials`).
- 👤 **Sparkle EdDSA key pair** generated with Sparkle's `generate_keys`:
  - Private key stored **offline / in Keychain** — **never** committed.
  - Public key pasted into `project.yml` → `SUPublicEDKey` (currently empty).
- 👤 **Remote-config key pair(s)** (Ed25519) — primary + backup. Public keys go in
  `Sources/MacLingo/Trust/TrustMaterial.swift`
  (`configPublicKeyPrimary` / `configPublicKeyBackup`, currently empty); private
  keys stored **offline**. These are **separate** from the Sparkle key.
- 👤 Set the production hosts in `TrustMaterial.swift`:
  - `remoteConfigHost` (control-plane) — currently `config.maclingo.invalid`.
  - `sparkleAppcastHost` (control-plane) — currently `updates.maclingo.invalid`.
  - and the matching `SUFeedURL` in `project.yml`.
- 👤 **Legal / ToS sign-off** on shipping the unofficial Google Free endpoint as
  the default (spec §6.1 release gate). Record the ToS posture in the release
  notes / `CHANGELOG.md`. **Do not ship the Free default without this.**

> Until these placeholders are filled, a build runs but never reaches a real
> update or config server — `SURequireSignedFeed` + an empty key fail closed, and
> `RemoteConfigVerifier` with empty keys verifies nothing (fail-closed by design).

---

## 1. Versioning & settings schema

- Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`.
- The appcast advertises **forward versions only** — Sparkle never offers a
  downgrade.
- **Settings schema:** migrations are **additive**; never remove or repurpose a key
  within a major version; gate new behavior behind new keys with safe defaults. An
  older build reading a newer settings file **ignores unknown keys**; an
  unreadable store or a throwing migration is **fail-safe** (backed up + reset,
  Keychain untouched). If you added a migration, bump
  `SettingsStore.currentSchemaVersion` and register the step in `runMigrations`.

## 2. Config epoch (spec §6.1 / §10)

- The persisted **monotonic epoch floor** travels with each install and only ever
  rises. A release that **rotates config keys** must ship a `startingConfigEpoch`
  **at or above** the current floor, or its configs will be rejected.
- Raising `TrustMaterial.startingConfigEpoch` **discards all previously stored
  configs** on first launch of the new build — this is the recovery path for a
  lost/compromised config key or a malicious high-version sticky-disable. Use it
  deliberately and document the bump in `CHANGELOG.md`.
- A manual downgrade to an older `.dmg` **cannot** re-activate a discarded
  sticky-disable: the older binary still reads the persisted floor and rejects
  below-floor stored configs.

## 3. Build (universal / Release)

```bash
xcodegen generate
swiftlint --strict
swift-format lint --strict --recursive Sources Tests
xcodebuild -scheme MacLingo -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
# Release is universal (ONLY_ACTIVE_ARCH=NO) — verify both slices:
xcodebuild -scheme MacLingo -configuration Release -destination 'platform=macOS' build
lipo -info "$(…)/MacLingo.app/Contents/MacOS/MacLingo"   # expect x86_64 arm64
```

## 4. Sign, package, notarize, staple 👤

```bash
codesign --deep --force --options runtime --timestamp \
  --sign "Developer ID Application: …" MacLingo.app
# build the .dmg (e.g. create-dmg), then:
xcrun notarytool submit MacLingo.dmg --keychain-profile "…" --wait
xcrun stapler staple MacLingo.dmg
spctl -a -vvv -t install MacLingo.dmg   # expect: accepted, source=Notarized Developer ID
```

## 5. Sparkle appcast 👤

- Sign the archive **and** the feed with the Sparkle private key
  (`sign_update`); `SURequireSignedFeed` requires the signed feed.
- Publish `appcast.xml` to the appcast host (HTTPS, single stable channel).
- Verify: a tampered feed **or** archive signature is rejected **before
  extraction**; a download failure leaves the current version intact (no partial
  replace).
- **Key rotation:** ship the new public key in an app update **before** retiring
  the old key (overlap both during transition).

## 6. Pre-release gate — acceptance matrix (spec §12)

Run the full **§12 acceptance-test matrix** on a clean macOS 15 machine (apps ×
selection types + scenario coverage). This is the release gate — see the on-device
checklist in `.agents/todo.md` (capture, modal, formatting, BYOK, redirect/
allowlist, remote-config kill switch). Confirm:

- Clean install → grant Accessibility → translate → enhance → copy works end to
  end.
- Endpoint kill-switch verified (signed disable → fallback chain engages).
- A valid signed appcast feed + archive applies; tampering is rejected.

## 7. Publish

- Update `README.md`, `docs/PRIVACY.md` (what's sent where + signed-config
  disclosure), and `CHANGELOG.md` (incl. the ToS posture and any epoch bump).
- Tag the release; smoke-test the published `.dmg` on a clean machine.
