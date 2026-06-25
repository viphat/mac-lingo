# MacLingo — Implementation Log & TODO

Running progress tracker for the phased build (`docs/MacLingo-plan.md`).
Authoritative design: `docs/MacLingo-spec.md`. Conventions/invariants: `CLAUDE.md`.

**Last updated:** 2026-06-25

---

## Status at a glance

| Phase | Title | Status |
|---|---|---|
| 0 | Project setup, trust material, skeleton | ✅ Done (commit `1b64ca4`) |
| 1 | Settings, permissions & reconciliation | ✅ Done (commit `0c6a55d`) |
| 2 | Hotkey + text capture | 🚧 Code complete — actor + wiring done; on-device QA pending |
| 3 | Translation service + Google Free + modal (plain text) | 🚧 Code complete — pipeline + modal done; on-device QA pending |
| 4 | Formatting preservation + markup trust boundary | ⛔ Not started |
| 5 | AI providers (BYOK) + Keychain + live reconciliation | ⛔ Not started |
| 6 | Google Cloud provider | ⛔ Not started |
| 7 | Networking trust boundary, remote config & hardening | ⛔ Not started |
| 8 | Packaging & release | ⛔ Not started |

**Toolchain:** Xcode 26.5, macOS 26.5 SDK, Swift 6 strict concurrency.
**Build verified:** `xcodebuild` BUILD + TEST SUCCEEDED; `swiftlint --strict` and
`swift-format --strict` clean. **74 unit tests passing.**

---

## What's implemented

### Phase 0 — scaffold ✅
- `project.yml` (XcodeGen) → `MacLingo.xcodeproj` (git-ignored). macOS 15, Swift 6
  strict concurrency, SPM deps (KeyboardShortcuts 2.4, Defaults 9.0, Sparkle 2.9),
  hardened runtime, no sandbox, `LSUIElement`.
- `Sources/MacLingo/Trust/TrustMaterial.swift` — dual host allowlists (§9), default
  Free endpoint + endpoint allowlist (§6.1), starting config epoch, config/Sparkle
  key placeholders.
- `Sources/MacLingo/App/MacLingoApp.swift` — menu-bar skeleton.
- Tooling: `.gitignore`, `.swiftlint.yml`, `.swift-format`, `.github/workflows/ci.yml`,
  `README.md`.

### Phase 1 — settings / permissions / reconciliation ✅
- **Core types:** `TargetLanguage`, `EngineID` (`isPaid`/`isAI`), `DefaultEngine`,
  `AIProvider` (editable default models), `CaptureMethod`, `AppearanceMode`.
- **`SettingsStore`** (Defaults-backed, injectable suite): all §7 prefs; only
  `hasKey(...)` booleans persisted (secrets in Keychain); `settingsSchemaVersion`;
  **fail-safe migration** (back up → reset → surface; never hard-fails launch);
  `applyAtomic` (system op first, persist only on success).
- **`KeychainStore`** + `KeychainStoring` protocol (Security framework; never logs keys).
- **`EngineResolver`** — centralized fallback chain (§6.1).
- **`StateReconciler`** — launch reconcile: hotkey re-register, SMAppService check,
  Keychain↔`hasKey`, stale-default-engine fallback; injectable services; returns a report.
- **`PermissionsCoordinator`** (AX detect/prompt/deep-link/recheck), **`HotkeyManager`**
  (KeyboardShortcuts, `⌥⌘T`), **`LoginItemController`** (SMAppService).
- **`SettingsView`** + `AppModel`/`AppDelegate` launch bootstrap.
- **Tests (24):** settings round-trip, migration fail-safe, atomic-write, reconciler
  repair paths, engine resolution.

### Phase 2 — capture (code complete) 🚧
- **Identities:** `SelectionSnapshotID`, `OperationID`, `invalidOperationID` sentinel.
  (The Phase 2 `OperationIDIssuer` actor was removed in Phase 3 — `RequestRegistry`
  now owns monotonic operation issuance.)
- **`CapturedSelection`** / `CapturedRich` types.
- **Pure §4.3 predicates (tested):** `ClipboardOwnership.shouldRestore` (conservative,
  abstain on race/ambiguity), `Materializability` (skip copy over promised types),
  `CaptureCombiner` (richest-result selection).
- **Ports (`CapturePorts.swift`):** `AccessibilityReading`, `KeystrokeSynthesizing`,
  `Pasteboarding` protocols + `PasteboardSnapshot`/`PasteboardItemSnapshot` — the
  injection seams that keep the actor unit-testable.
- **Live conformers (`LiveCapturePorts.swift`):** `LiveAccessibilityReader`
  (`kAXSelectedTextAttribute` off the focused element; `unsafeDowncast` past the
  always-succeeds CF cast — `as?` is a lint error), `LiveKeystrokeSynthesizer`
  (⌘C via `CGEvent`), `LivePasteboard` (snapshot/read-richest/restore over
  `NSPasteboard.general`; stateless value types stay `Sendable`).
- **`SelectionCapturer` actor:** serialized dual capture — AX read → materializability
  pre-check → snapshot C0 → synthesize ⌘C → poll `changeCount > C0` (cancellation-aware
  `Task.sleep`) → read-richest → combine. **Guaranteed `defer` cleanup** restores
  **only if** the ownership predicate passes (`postCopy = observedC1 ?? current`, so a
  late-landing copy on cancel is handled). `.axOnly` privacy mode never snapshots,
  reads, or mutates the pasteboard.
- **Wiring:** `AppModel.handleTranslateTrigger` re-checks AX, cancels any in-flight
  `triggerTask`, opens an `OperationID` **before** capture, runs the actor, and logs a
  debug summary (Phase 3 swaps in the coordinator + modal).
- **Tests (+7, `SelectionCapturerTests`):** AX-only no-touch, clean-copy restore,
  swallowed-copy AX fallback, non-materializable skip, concurrent-writer abstain,
  ambiguous multi-step abstain, cancellation-returns-nil. **Still in `CaptureLogicTests`:**
  predicate coverage (12). 46 tests total.

### Phase 3 — translation + Google Free + modal (code complete) 🚧
- **Types (`Translation/TranslationTypes.swift`):** `DetectedLanguage`, `FormattedText`
  (Phase 3 = plain-text blocks; Phase 4 extends), `SelectionSnapshot`, full `CacheKey`
  (selection + engine + target + `providerConfigRevision` + `promptVersion` +
  `codecVersion`), `TranslationRequest`/`TranslationResult`, `TranslationService`
  protocol, `TranslationError`, `TranslationVersioning` (codec/prompt = 1).
- **`LanguageAggregator`** — deterministic §3.2: non-whitespace-grapheme weighting,
  undetected blocks excluded from num+denom, `>50%` → `.known`, else `.mixed`,
  none → `.unknown`. Pure + tested.
- **Google Free (`Translation/GoogleFree/`):** `GoogleFreeEndpoint` (query builder +
  translation-data host-allowlist guard), `GoogleFreeResponseParser` (JSON-array
  shape), `GoogleFreeProvider` (block-by-block, reassemble by index, bounded
  exponential backoff on 429/5xx, cancellation-aware). Injectable `HTTPClient`.
- **`RequestRegistry`** (@MainActor, per panel) — monotonic op issuance, current-op,
  open/close, **apply-if-current**, full-`CacheKey` cache, closure invalidation on
  close. Tested.
- **`PanelSession`** (@MainActor, headless) — the lifecycle core: every presentation
  change (begin / engine switch / target switch / retry / **cache hit**) opens a new
  op + cancels in-flight; apply-if-current; cache hit served synchronously; errors
  surfaced; `begin` clears cache on transient reuse. Tested (apply-if-current,
  stale-after-switch, late-after-close, cache-hit-opens-op, error, unavailable).
- **Modal (`Modal/`):** `TranslationModalView` + `ModalViewModel` (SwiftUI, plain
  text), `ModalController` (`TranslationPanel` nonactivating+borderless+canBecomeKey;
  hover=key; Esc-consuming local monitor on becomeKey/resignKey; local+global
  outside-click monitors; `resignKey`/deactivation dismissal; **Pin** suppresses
  implicit dismissals but not Esc/Close; cursor-anchored + screen-clamped position),
  `ModalPresenter` (single transient reuse + accumulating pinned panels).
- **`TranslationCoordinator`** (@MainActor) — trigger → resolve engine (§6.1) → capture
  → build `SelectionSnapshot` → present; cancels in-flight capture on retrigger.
- **Wiring:** `AppModel` owns the coordinator (capturer + `DefaultTranslationServices`
  + presenter); `handleTranslateTrigger` re-checks AX then delegates.
- **Tests (+28):** `LanguageAggregatorTests` (8), `GoogleFreeTests` (10, incl. provider
  over a mock client), `RequestRegistryTests` (4), `PanelSessionTests` (7 incl. gated
  interleaving). **74 tests total.**
- **Deferred to later phases (by design):** rich `FormattedText` from captured RTF/HTML
  (Phase 4); engine selector / Enhance-with-AI / target switcher *UI* (Phase 5);
  rich RTF copy-out (Phase 4); networking redirect/allowlist *hardening* via a
  `URLSession` delegate (Phase 7 — host allowlist is already enforced at build time).

---

## Next steps (checklist)

### Phase 2 — finish capture
- [x] `SelectionCapturer` **actor** (serialized; one capture at a time).
- [x] AX read via `kAXSelectedTextAttribute` behind an injectable `AccessibilityReading` protocol.
- [x] Synthesized `⌘C` via `CGEvent`; poll `changeCount > C0` (~200–400 ms timeout).
- [x] `NSPasteboard` snapshot / read-richest (`public.rtf`/`public.html` → plain) /
      restore behind a `Pasteboarding` protocol — drive the pure predicates above.
- [x] Wire **materializability pre-check** → skip synthesized copy, fall back to AX.
- [x] **Cancellation-aware** capture: open `OperationID` *before* capture; guaranteed
      `defer` cleanup that runs on supersede but **gates restore** on the ownership predicate.
- [x] **AX-only privacy mode** (no synthesized copy, no clipboard mutation).
- [x] Wire `AppModel.handleTranslateTrigger` → issue OperationID → capture → debug overlay.
- [x] Build + lint clean; commit Phase 2.
- [ ] **On-device QA matrix** → deferred to **Human tasks** below.

### Phase 3 — translation service + Google Free + modal (plain text)
- [x] `TranslationService` protocol + `TranslationRequest`/`TranslationResult`/full `CacheKey`.
- [x] `RequestRegistry` + `TranslationCoordinator`: monotonic OperationID, one current,
      **every presentation change (incl. cache hit) opens new op + cancels in-flight**,
      apply-if-current, closure invalidation, full-`CacheKey` cache.
      (Lifecycle lives in `PanelSession`; coordinator owns capture→snapshot→present.)
- [x] `GoogleFreeProvider` (unofficial endpoint, JSON-array parse, backoff).
- [x] Deterministic source-language aggregation (`>50%` / `.mixed` / `.unknown`, §3.2).
- [x] `ModalPresenter` + `TranslationModalView` (NSPanel; Esc consume; full dismissal
      coverage; authoritative Pin contract; single-transient + accumulating-pinned retrigger).
- [x] Build + lint clean; commit Phase 3.
- [ ] **On-device QA** (manual; built app + Accessibility) → see **Human tasks** below.

### Phase 4 — formatting + markup trust boundary
- [ ] `RichTextCodec` (RTF/HTML ↔ `FormattedText`, block indices, `codecVersion`).
- [ ] Tagged-segment encoding (HTML tags / sentinel tokens); structural validation;
      degrade-to-plain on failure.
- [ ] `MarkupSanitizer` (attribute allowlist, RTF normalization, no remote resources, caps).

### Phase 5 — AI providers (BYOK) + live reconciliation
- [ ] OpenAI + DeepSeek providers (shared HTML round-trip prompt, `promptVersion`).
- [ ] Settings: provider/model (editable list)/key + **Validate**, auto-enhance,
      paid-confirm threshold, auto-spend policy.
- [ ] Entry-point-agnostic **paid confirmation** at the send boundary; auto-enhance rules.
- [ ] Key validity (not just presence); live reconciliation + `providerConfigRevision`.
- [ ] Large-selection chunking (block → sentence → word → grapheme; encoded budget).

### Phase 6 — Google Cloud (v2 + `X-Goog-Api-Key` header)
- [ ] `GoogleCloudProvider`, settings toggle + key + Validate; paid-confirm + reconciliation.

### Phase 7 — networking trust boundary, remote config & hardening
- [ ] Dual allowlists enforced; **HTTP-redirect validation** (P0); fail-closed remote
      config (signature, monotonic version, sticky-disable, epoch floor); degraded behavior.

### Phase 8 — packaging & release
- [ ] Verify universal/Release build; notarized stapled `.dmg`; signed Sparkle feed;
      config-epoch in release process; run spec §12 acceptance matrix; legal/ToS sign-off.

---

## 👤 Human tasks (require a person / device / account; not automatable here)

These are blocked on hardware, granted permissions, paid accounts, or human
judgement — they can't be done from the coding session and must be run by a person.

### On-device capture QA (deferred from Phase 2)
Needs Accessibility granted to a built, signed `.app` and real target apps running.
- [ ] Capture correct string in TextEdit, Safari, Chrome, VS Code, Slack (+1 Electron).
- [ ] Copy *during* the capture window → newer clipboard kept (no clobber).
- [ ] Promised/non-materializable original on clipboard → synthesized copy skipped, AX used.
- [ ] Ambiguous multi-change during window → original **not** restored.
- [ ] Cancel during the synthesized-copy window → cleanup restores **only if** predicate passes.
- [ ] AX-only privacy mode → clipboard untouched across many triggers.

### On-device translation/modal QA (deferred from Phase 3)
Needs a built app with Accessibility granted, plus live network.
- [ ] Hotkey on a selection → modal appears near cursor, clamped on-screen (multi-display).
- [ ] Google Free returns a translation; detected source label + target tag correct.
- [ ] Multi-paragraph selection → line breaks preserved 1:1 (block reassembly).
- [ ] Esc while panel is key → closes and the key event does **not** reach the app behind.
- [ ] Outside click / Command-Tab / Space switch → dismisses (unpinned).
- [ ] **Pin** → survives outside-click/Command-Tab/Space; Esc and Close still work.
- [ ] Retrigger with an unpinned panel → reused/re-anchored; with a pinned panel → new
      transient opens, pinned accumulates.
- [ ] Copy → plain text on the clipboard (rich RTF copy lands in Phase 4).
- [ ] Live endpoint sanity: rate-limit/backoff behaves; error state shows Retry.

### Other known human-only gates (forward references)
- [ ] **Phase 3 (legal):** Google Free unofficial-endpoint ToS / legal release sign-off
      before shipping it as the default (§6.1 release gate).
- [ ] **Phase 5/6:** real BYOK / Google Cloud API keys to exercise Validate + live 401/403.
- [ ] **Phase 8:** Developer ID signing identity, notarization, Sparkle EdDSA key,
      remote-config signing key, ToS/legal sign-off for Google Free.

---

## Key decisions & gotchas (for the next session)

- **No `.xcodeproj` in git** — it's generated. Edit `project.yml`, run `xcodegen generate`.
- **Debug = active arch only**; Release = universal (Xcode explicit-modules + SwiftPM
  universal bug). Don't "fix" the Debug arch setting without re-checking the package build.
- **Lint:** swift-format owns commas/whitespace; SwiftLint owns correctness. `todo` and
  `trailing_comma` SwiftLint rules are disabled on purpose.
- **Concurrency:** reconciler service protocols (`HotkeyRegistering`, `LoginItemControlling`)
  are `@MainActor` (so @MainActor conformers satisfy them); `KeychainStoring` is `Sendable`.
- **Tests** inject a throwaway `UserDefaults` suite + temp backup dir via
  `makeIsolatedStore()` in `Tests/.../Support/Mocks.swift`. `@MainActor` test classes
  create the env inside each test (not in `setUp`) to avoid non-Sendable actor-hop errors.
- **Trust material** (`TrustMaterial.swift`) has placeholder hosts/keys marked `TODO(Phase 7/8)`.
- **Operation lifecycle is per-panel.** Each panel owns a `RequestRegistry` + a headless
  `PanelSession`. The op opens at *presentation* time (begin/switch/retry/cache-hit), not
  literally before capture — the in-flight **capture** is instead guarded by
  `captureTask.cancel()` in `TranslationCoordinator`, so a superseded capture never
  presents. Apply-if-current (registry) is the authoritative correctness gate; task
  cancellation is an optimization (mocks deliberately ignore cancellation to prove this).
- **Phase 3 networking is deliberately un-hardened:** `URLSessionHTTPClient` uses a plain
  session. The host allowlist is enforced at request-build (`GoogleFreeEndpoint`), but the
  per-redirect `URLSession`-delegate validation (§9) is Phase 7. Don't ship without it.
- **Provider config revision** is fixed at `0` until Phase 5 wires bumping; it's already a
  `CacheKey` field so a changed model/key/endpoint will force a miss once wired.
