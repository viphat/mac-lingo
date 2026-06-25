# MacLingo — Implementation Plan

**Companion to:** `MacLingo-spec.md`
**Status:** Draft v6 (fully re-synced with spec v6)
**Last updated:** 2026-06-25

This plan sequences the build into phases that each end in something runnable and
demoable. Earlier phases de-risk the hard parts (input capture, permissions,
formatting) before investing in polish.

> **Re-sync note (v6):** the phase bodies are now aligned with **spec v6**. The
> v3–v6 spec rounds added substantial scope that this revision folds in: the
> two-identity model (`SelectionSnapshotID` vs `OperationID`) and full `CacheKey`;
> the single-transient + accumulating-pinned retrigger policy and authoritative
> Pin contract; full dismissal coverage and closure invalidation; live provider
> reconciliation with `providerConfigRevision`; the fail-closed allowlist-bound
> remote-config lifecycle with sticky-disable, monotonic version, expiry, and a
> monotonic epoch floor; dual network allowlists with HTTP-redirect validation
> (P0); Cloud v2 + `X-Goog-Api-Key` header; entry-point-agnostic paid-translation
> confirmation (AI **and** Cloud); key-validity-not-just-presence; the settings
> migration fail-safe; and the signed Sparkle feed.

---

## 0. Approach

- Build the menu-bar skeleton and the **capture + permissions** pipeline first,
  because that is the riskiest, most environment-dependent part.
- Get a **plain-text** end-to-end translation working before tackling
  formatting preservation.
- Layer engines behind one protocol so Google-Free, Google-Cloud, OpenAI, and
  DeepSeek are interchangeable.
- Keep formatting fidelity isolated in `RichTextCodec` so engines stay simple.
- Treat the **trust boundaries** (markup sanitization, dual network allowlists +
  redirect validation, fail-closed remote config) as first-class deliverables,
  not afterthoughts — they are where this app's real risk lives.

**Suggested team:** 1 macOS engineer leading; QA review (Konishi-san) at the end
of phases 2, 4, 5, and 8. Rough estimate: **~8–11 working weeks** for a polished
v1 by a single engineer — the v3–v6 review additions (request lifecycle + two
identities, markup/RTF sanitization, live state reconciliation, large-selection
chunking, the remote-config lifecycle + epoch recovery, dual allowlists + redirect
validation, paid-confirmation) materially expanded the security/networking scope
over the original v2 estimate. Less if parallelized.

---

## Phase 0 — Project setup *(0.5–1 day)*

**Tasks**
- Create Xcode project: SwiftUI App lifecycle, `MenuBarExtra`, `LSUIElement = true`.
- Universal binary; minimum deployment macOS 15.0; Swift 6 **strict concurrency**.
- Add Swift Package dependencies: `KeyboardShortcuts`, `Defaults` (settings),
  `Sparkle` (auto-update, included in v1). Keychain via the native Security framework.
- Configure Developer ID signing, hardened runtime, notarization scaffolding.
- **Embed build-time trust material (spec §6.1, §9, §10):** the compiled
  **translation-data** and **control-plane** host allowlists; the compiled-default
  Google Free endpoint + endpoint allowlist; the **primary + backup config public
  keys** and the starting **config epoch**; the Sparkle EdDSA public key. These are
  separate keys with separate rotation stories (§6.1 vs §10).
- Repo, `CLAUDE.md` conventions, SwiftLint/SwiftFormat, basic CI (build + test).

**Done when:** an empty menu-bar app builds, signs, and launches with no Dock icon;
embedded allowlists/keys/epoch are present as compiled constants.

---

## Phase 1 — Skeleton, settings, permissions & reconciliation *(3–4 days)*

**Tasks**
- Menu-bar menu: Translate, Settings…, Quit.
- `SettingsStore` with all preferences from spec §7 (Defaults-backed), plus a
  persisted `settingsSchemaVersion` and a migration hook. Defaults store only
  `hasKey(provider)` / `hasKey(cloud)` booleans — **never** secrets.
- **Atomic system-state writes (spec §5.5):** apply the system op (hotkey
  registration, `SMAppService`, Keychain) *first*, persist the value only on
  success; keep prior value + surface an actionable error on failure. No optimistic
  persistence.
- **Fail-safe migration (spec §5.5/§10):** if the store is unreadable or a
  migration throws, back up the bad file (timestamped), reset to safe defaults,
  and let `StateReconciler` rebuild system state — Keychain is untouched, so
  `hasKey` is re-derived from key presence. Launch never hard-fails; surface a
  reset notice. Migrations are additive / forward-backward tolerant (ignore
  unknown keys).
- `StateReconciler` — **launch reconciliation (spec §5.5):** (a) re-register the
  hotkey from the persisted shortcut, (b) verify `SMAppService` matches
  launch-at-login, (c) verify Keychain presence matches each `hasKey` flag
  (**AI provider key and the Google Cloud API key**), (d) verify the selected
  default engine is actually configured — *presence is not validity* — and fall
  back per §6.1 if not, (e) repair/clear mismatches and log them.
- Settings window (SwiftUI): target language, hotkey recorder, default engine,
  capture method (Dual / AX-only), appearance, launch-at-login (`SMAppService`).
  (Provider-specific settings land in Phases 5–6.)
- `PermissionsCoordinator`: detect `AXIsProcessTrusted`, onboarding sheet,
  deep-link to System Settings, live re-check on settings focus and at trigger time.

**Acceptance**
- Settings persist across launches; launch reconciliation repairs an induced
  mismatch (e.g. manually removed login item, or a `hasKey` flag with no Keychain
  entry) and logs it; a stale default engine with no key falls back per §6.1.
- A forced failure of a system op does **not** persist the new value.
- A corrupt/unreadable settings file backs up the bad file, resets to safe
  defaults, leaves Keychain intact, and launches without a hard failure.
- Accessibility onboarding appears when permission is missing and clears once granted.

**QA checkpoint** at end of phase.

---

## Phase 2 — Hotkey + text capture *(4–6 days, highest risk)*

**Tasks**
- `HotkeyManager` via `KeyboardShortcuts`; default `⌥⌘T`; conflict handling.
- **Open the `OperationID` before capture (spec §3.1/§5.3):** the trigger issues a
  new `OperationID` *first*, then capture runs; capture is **cancellation-aware**.
- `SelectionCapturer` (**actor**, serialized — spec §4.3) — **dual capture**:
  - AX read (`kAXSelectedTextAttribute`): fast, clipboard-free baseline +
    selection-exists signal.
  - **Materializability pre-check (spec §4.3):** inspect the current pasteboard; if
    it holds **promised/lazy or app-private types that can't be fully materialized
    and restored**, **skip the synthesized copy** and fall back to AX — never
    overwrite a clipboard that can't be put back.
  - Pasteboard: record `changeCount` `C0` + snapshot concrete types → synthesize
    `⌘C` (`CGEvent`) → poll for `changeCount > C0` (timeout ~200–400 ms) → read
    richest type (`public.rtf` / `public.html` → `public.utf8-plain-text`) →
    record `C1`.
  - **Conservative, ownership-gated restore (spec §4.3):** restore the snapshot
    **only if `changeCount == C1`** at restore time **and** `C0`→`C1` was a single
    unambiguous step; on any ambiguity (count jumped, concurrent writers),
    **abstain** and leave the current clipboard intact.
  - **Cancellation-aware cleanup:** a guaranteed `defer` cleanup block always
    *runs* if the op is superseded mid-capture, but restoration inside it is gated
    by the same ownership predicate (cleanup guaranteed, restore not unconditional);
    the partial capture is discarded.
  - Combine: richest successful result wins; AX is also the fallback when the
    pasteboard never changes (copy swallowed) or the pre-check abstains.
  - **AX-only privacy mode:** no synthesized copy, no clipboard mutation.

**Acceptance**
- Selecting text in TextEdit, Safari, Chrome, VS Code, Slack and pressing the
  hotkey yields the correct captured string in a debug overlay.
- Copying something *during* the capture window leaves the user's newer clipboard
  intact (conservative-restore predicate verified).
- A pasteboard holding a promised/non-materializable type → synthesized copy is
  **skipped**, AX used; an ambiguous multi-change → **no restore**.
- Cancelling during the synthesized-copy window runs cleanup that restores **only
  if** the ownership predicate passes.

**QA checkpoint:** test the capture matrix across the apps above (incl. one
Electron app). This is the make-or-break phase.

---

## Phase 3 — Translation service + Google Free + modal (plain text) *(4–6 days)*

**Tasks**
- `TranslationService` protocol + types (spec §5.1): `EngineID`,
  `TargetLanguage` (4 cases), `DetectedLanguage` (`.known(bcp47:)` / `.mixed([..])`
  / `.unknown`), and the **two distinct identities** —
  `SelectionSnapshotID` (stable per capture, reused across switches) and
  `OperationID` (one per translate/present op). `SelectionSnapshot` (immutable),
  `TranslationRequest` (carries `operationID`), `TranslationResult` (carries
  `operationID`), and the full `CacheKey` (selection + engine + target +
  `providerConfigRevision` + `promptVersion` + `codecVersion`).
- `RequestRegistry` + `TranslationCoordinator` (**lifecycle, spec §5.3**):
  - issue monotonic `OperationID`s; track **one current** `OperationID`.
  - **Every presentation change opens a new `OperationID` and cancels the in-flight
    `Task` — *including a cache hit*** (engine switch, target switch, retry,
    auto-enhance, cache hit). A hit fills the UI synchronously from cache; a miss
    issues a request.
  - **Apply-if-current:** a result updates the UI **only if** its `operationID` is
    current **and the panel is open**.
  - **Closure invalidation (cooperative-cancellation safety):** on close/dismiss,
    set a **closed** state and a sentinel-invalid `OperationID`; reject any
    completion that arrives afterward (drop its result + cached entry).
  - **Result cache** keyed by the **full** `CacheKey`; never key on a subset.
- `GoogleFreeProvider`: unofficial endpoint, auto source-detect, target from
  settings, JSON-array parsing, backoff on rate-limit.
- **Deterministic source-language aggregation (spec §3.2):** per-block detection,
  count non-whitespace source grapheme clusters over **detected** blocks, exclude
  undetected blocks from the denominator, `>50%` → `.known`, none `>50%` →
  `.mixed`, no valid detection → `.unknown`.
- `ModalPresenter` + `TranslationModalView`:
  - `NSPanel` (`.nonactivatingPanel` + `.borderless`, `.floating`,
    `canBecomeKey = true`, `hidesOnDeactivate = false`), cursor-anchored,
    screen-clamped (multi-display / Spaces / notch), draggable.
  - States: loading / result / error (retry) / no-selection. Controls: Enhance,
    Copy, engine selector, target switcher, Pin, Close.
  - **Escape + focus (spec §8):** hover → `makeKeyAndOrderFront` (nonactivating);
    a **local** monitor consumes `Esc` (keyCode 53) while key (return nil),
    installed on `becomeKey` / removed on `resignKey`.
  - **Full dismissal coverage (spec §8):** outside mouse-down via **both** a local
    monitor (own windows) **and** a global monitor (other apps);
    `windowDidResignKey` + app-deactivation (covers Command-Tab / Space switch);
    system-interruption (`resignKey`).
  - **Authoritative Pin contract (spec §8):** Pin suppresses **all implicit
    dismissals** (outside-click, deactivation/Command-Tab, Space switch,
    system-interruption) but **not** Esc or Close.
  - **Retrigger policy (spec §3.1):** one **transient** panel — a new trigger
    reuses it (cancel prior op, clear snapshot/cache, re-anchor, new
    `OperationID`); if the current panel is **pinned**, open a **separate** new
    transient panel (pinned panels accumulate as independent windows).
  - **Close/dismiss cleanup (any path):** cancel all in-flight tasks (capture,
    translation, chunks), remove local + global monitors, clear the source snapshot
    + result cache. A pinned panel retains content until final close.

**Acceptance**
- End-to-end: select → hotkey → modal shows the Google Free translation → `Esc`
  closes it instantly when hovered and is **consumed** (does not reach the prior app).
- Rapid re-trigger / target switch / engine switch mid-flight: only the latest
  result shows; no stale overwrite; a completion after close is rejected.
- Retrigger while transient → reuses panel; retrigger while pinned → separate panel.
- 60/40 two-language selection reports the `>50%` language; 50/50 → `.mixed`;
  undetected blocks excluded; no detection → `.unknown`.

---

## Phase 4 — Formatting preservation + markup trust boundary *(5–7 days)*

**Tasks**
- `RichTextCodec`: parse captured RTF/HTML → `FormattedText` (blocks + inline
  runs: bold/italic/underline/code; paragraphs, line breaks, lists). Blocks carry
  stable indices for reassembly. Bumps `codecVersion` when the encoding changes.
- **Tagged-segment encoding (spec §3.4):** inline runs as whitelisted HTML tags
  (HTML-capable engines) or sentinel placeholder tokens (Google Free) — **never
  positional reapplication**.
- `MarkupSanitizer` (**spec §5.4**) — trust boundary for **captured clipboard HTML,
  captured RTF, and engine output alike**:
  - Attribute allowlist (RTF + HTML): only {bold, italic, underline, code} + block
    structure survive; no `style`/`class`/handlers/scripts.
  - **RTF normalization:** strip attachments/images, hyperlinks/`link`, embedded
    objects, fonts/colors/sizes, `\field`/external-reference constructs.
  - **No remote resources ever:** `<img>`/`<link>`/`<object>`/`url()`/RTF
    attachments removed; nothing triggers a network load.
  - Caps: max nesting depth + max node/character count.
- **Structural validation (spec §3.4):** balanced/well-nested markers with a
  matching open/close multiset; on failure → degrade the **affected block** to
  plain text (structure preserved).
- Block-by-block translation + **in-order reassembly by block index** (never by
  parsing translated whitespace) for Google Free.
- Render `FormattedText` as `AttributedString`; **Copy** writes sanitized RTF +
  plain-text fallback.

**Acceptance**
- Multi-paragraph bold/italic selection keeps line breaks everywhere and inline
  styling per the §6.3 matrix (preserved on Cloud/AI; placeholder-validated on
  Google Free, plain fallback on failure).
- Malformed / oversized / deeply-nested / remote-resource markup **and RTF
  attachments/links** are sanitized; affected blocks fall back to plain text; no
  network load is triggered.

**QA checkpoint** at end of phase.

---

## Phase 5 — AI providers (BYOK) + Keychain + live reconciliation *(4–6 days)*

**Tasks**
- `KeychainStore` for API keys (Security framework); Defaults stores only
  `hasKey(provider)`. Keys **redacted** from all logs/diagnostics.
- Settings: AI provider (DeepSeek/OpenAI), model picker (**editable list**, not
  hardcoded — defaults `gpt-5.4-mini` / `deepseek-v4-flash`), key entry,
  **Validate** action, auto-enhance toggle, paid-confirmation threshold
  (default 4,000 chars), auto-spend policy (`N=0` = always confirm).
- `OpenAIProvider` (`/chat/completions`, default `gpt-5.4-mini`) and
  `DeepSeekProvider` (`api.deepseek.com`, default `deepseek-v4-flash`); shared
  whitelisted-HTML round-trip prompt (carries `promptVersion`); output runs
  through `MarkupSanitizer` + structural validation before rendering.
- **Engine selector + Enhance (spec §3.1):** Enhance opens a new `OperationID` on
  the same `SelectionSnapshot`; results cached by full `CacheKey` for instant
  toggling; Copy copies the **active** result.
- **Auto-enhance (spec §3.1/§6.5):** OFF by default; runs a second **AI** pass only
  after a **non-AI** default; **no-op when the default is already AI**; over
  threshold it **pauses for confirmation** (never silently spends or skips).
- **Entry-point-agnostic paid confirmation (spec §6.5):** gate the cost prompt at
  the `TranslationCoordinator` send boundary so *every* paid cache-miss send is
  covered — first op, Enhance, engine switch, target switch, retry, auto-enhance.
  Cache hits are exempt (no spend).
- **Key validity, not just presence (spec §5.5/§7):** a failed **Validate** or a
  runtime 401/403 marks the provider **unconfigured** → live reconciliation (drop
  from selector, fall back per §6.1, disable dependent auto-enhance), not just an
  inline toast.
- **Live provider reconciliation (spec §5.5):** any provider-setting change during
  a session (replace/remove key, switch provider/model) is reconciled immediately
  and atomically: cancel affected in-flight ops, **bump `providerConfigRevision`**
  (invalidating dependent cache entries), update selector/default, disable invalid
  auto-enhance, and re-resolve the active modal's engine via §6.1 if its current
  engine became invalid.
- **Large-selection handling (spec §6.5):** hard cap (20,000 chars → refuse);
  primary split on **block boundaries**; secondary split of an oversized block
  sentence→word→grapheme against the **encoded** budget (UTF-8 bytes / tokens);
  each chunk carries `(blockIndex, subRange)`; chunked jobs honor `OperationID`
  cancellation; partial chunk failure leaves blocks untranslated + retryable;
  intra-block splits rejoin without adding/losing line breaks.

**Acceptance**
- With a valid key, Enhance shows the AI result; toggling back to a cached engine
  is instant and **cancels** any in-flight AI op (late AI result discarded); Copy
  copies the active engine's text.
- A failed Validate / runtime 401 drops the provider from the selector and falls
  back; keys never leave the Keychain and never appear in logs.
- Changing AI model/key/provider mid-session bumps `providerConfigRevision`,
  invalidates caches, cancels affected tasks, and disables incompatible
  auto-enhance — without a restart.
- A selection above the threshold prompts for confirmation before any paid call
  **on every entry point**; a cache hit never prompts; above the hard cap is refused.
- A single paragraph larger than the chunk budget is split and reassembled exactly.

**QA checkpoint** at end of phase.

---

## Phase 6 — Google Cloud provider (optional) *(2–3 days)*

**Tasks**
- `GoogleCloudProvider` — **Cloud Translation API v2 + API key in the
  `X-Goog-Api-Key` request header** (spec §6.2), **never** a URL query param;
  `format=html` for full inline-style preservation. **Not** v3 (v3 needs a service
  account, out of scope).
- Settings toggle + key entry + **Validate**; off by default; per-character
  billing note shown. Key in Keychain; Defaults holds only `hasKey(cloud)`;
  redacted from diagnostics (URL **and** header).
- Cloud participates in launch + live reconciliation (Phase 1/5) and the
  **paid-confirmation** path (Cloud is a paid engine — Phase 5 gating applies).

**Acceptance**
- When enabled, bold/italic survives via the v2 HTML round-trip; the key travels
  in `X-Goog-Api-Key` (redacted in diagnostics); over-threshold Cloud sends prompt
  for confirmation; billing note shown.

*(Deferrable to v1.1 if scope is tight — but the paid-confirmation + reconciliation
hooks from Phase 5 must already account for it.)*

---

## Phase 7 — Networking trust boundary, remote config & hardening *(6–9 days)*

**Tasks**
- **Dual network allowlists (spec §9):** a **translation-data** allowlist (only
  hosts that may receive selected text) and a **control-plane** allowlist
  (remote-config + Sparkle hosts that must **never** receive selected text); the
  two are never merged.
- **HTTP-redirect validation (spec §9, P0):** a `URLSession` delegate that
  **inspects every 3xx before following**; follow **only if** the destination stays
  on the *same* allowlist; **reject** cross/off-allowlist redirects; on any followed
  redirect, **never forward the body or `Authorization`/`X-Goog-Api-Key` to a
  different host**; disable default redirect auto-following.
- **Remote config — fail-closed, allowlist-bound (spec §6.1):**
  - Verify signatures against the **primary + backup** embedded config keys
    (separate from Sparkle's).
  - **Monotonic version** governs trust (anti-rollback/replay); expiry is a backstop.
  - Strict **endpoint allowlist** — config may only **disable** the free provider
    or **select a compiled-in Google host**; it can **never** introduce a new host.
  - **Fail-closed + sticky disable:** a disable directive is sticky past expiry /
    failures / clock changes (only a higher-version valid config re-enables);
    enable/endpoint directives **expire** to the compiled default.
  - **Clock-rollback safe:** a backward clock jump cannot un-expire an enable or
    re-enable a disabled provider.
  - **Fetch timing:** at launch, periodically while running (default 12 h,
    jittered), and on foreground; best-effort + time-boxed; a **control-plane**
    request that never carries selected text.
  - **Atomic application via `StateReconciler`:** cancel active Free ops, bump
    `providerConfigRevision` + **invalidate cached Free results**, update
    endpoint/disabled state, re-resolve the active modal's engine via the fallback
    chain if Free became unavailable.
  - **Monotonic config-epoch floor (spec §6.1/§10):** persist the highest config
    epoch ever seen as a **version-independent** floor (distinct from the binary's
    compiled epoch); **reject below-floor stored configs** so a manual downgrade to
    an older `.dmg` cannot re-activate a discarded sticky-disable. Stored configs
    are scoped to an epoch; an app release that raises the epoch discards prior
    configs (recovery from a lost/compromised key or malicious high-version
    sticky-disable).
- **Defined degraded behavior when Free is blocked (spec §6.1):** AI key → one-tap
  fallback to AI; else Cloud configured → fall back to Cloud; else actionable error.
- **Release gate — legal/ToS sign-off (spec §6.1):** legal/release sign-off on the
  unofficial Google Free endpoint is **required before it ships as the default**;
  the ToS posture is recorded in the release notes. Tracked here, gated in Phase 8.
- **Pinned-panel cache on a live `providerConfigRevision` bump (spec §5.3/§5.5):**
  retain the already-rendered pinned result unchanged; subsequent presentation
  changes re-resolve under the new revision (guaranteed cache miss).
- **Local-only availability monitoring (spec §6.1/§9):** on-device error/block
  rates in diagnostics; **no telemetry**.
- Modal positioning edge cases (multi-monitor, Spaces, menu-bar/notch, small screens).
- Appearance (light/dark/system), animations, empty/error microcopy.
- Full error matrix from spec §11 (provider error classes, offline, large-selection
  partial failure, system/provider-state mismatch, redirect rejection).
- Accessibility/VoiceOver pass; localize UI strings (EN first).
- Launch-at-login verification; low idle footprint check.

**Acceptance**
- Selected text reaches **only translation-data hosts**; control-plane hosts never
  receive source text; a **cross-allowlist HTTP redirect is rejected** and never
  carries the body or credentials.
- A valid signed config toggles the provider / switches among allowlisted hosts and
  applies atomically (cancels Free ops + invalidates Free cache); an expired
  **enable** reverts to the compiled default while an expired **disable stays
  sticky**; a lower-version / wrongly-signed / non-allowlisted config is rejected
  fail-closed; clock rollback cannot re-enable a disabled provider.
- A **manual downgrade** to an older build cannot re-activate a discarded config —
  the epoch floor rejects below-floor stored configs.
- No crashes / clipboard clobbering across the app matrix; graceful errors and
  fallbacks; clean light/dark rendering; endpoint kill-switch verified.

---

## Phase 8 — Packaging & release *(2–3 days)*

**Tasks**
- Notarized, stapled `.dmg`; first-run experience (permission onboarding).
- **Sparkle (spec §10):** HTTPS appcast (single stable channel); **EdDSA-signed
  items + a signed feed (`SURequireSignedFeed`)** with the embedded public key;
  signatures **verified before extraction**; only signed + notarized builds
  accepted; failed download/verification keeps the current version (never a partial
  replace); **forward-version-only** appcast (no downgrade); documented EdDSA key
  backup + **rotation** (ship new public key before retiring old).
- **Settings-schema compatibility (spec §10):** additive migrations; unknown keys
  ignored by older builds; the fail-safe reset path (Phase 1) covers
  corrupt/failed migration.
- **Config-epoch in the release process (spec §6.1/§10):** a release that rotates
  config keys ships an epoch **at or above** the current floor; document the
  epoch-bump recovery procedure.
- Run the full **acceptance-test matrix (spec §12)** as the release gate.
- **Confirm the legal/ToS sign-off** on the Google Free default is recorded before
  release (spec §6.1; tracked in Phase 7).
- README, privacy note (what's sent where, the signed-config disclosure), changelog.
- Release checklist + smoke test on a clean macOS 15 machine.

**Acceptance**
- Clean-machine install → grant Accessibility → translate → enhance → copy works
  start to finish.
- Valid signed appcast **feed + archive** applies; a tampered feed **or** archive
  signature is rejected before extraction; download failure leaves the current
  version intact; a newer→older settings file read ignores unknown keys.

**Final QA checkpoint.**

---

## Milestones

| Milestone | Phases | Outcome |
|---|---|---|
| **M1 — Capture works** | 0–2 | Hotkey reliably captures selection across apps; clipboard ownership-safe |
| **M2 — Translate MVP** | 3 | Google Free plain-text translation; full lifecycle (two identities, cache, Esc/Pin/retrigger) |
| **M3 — Formatting** | 4 | Block structure + inline styles preserved; markup/RTF trust boundary |
| **M4 — AI enhancement** | 5 (+6) | DeepSeek/OpenAI BYOK + Cloud; keys in Keychain; live reconciliation; paid-confirmation |
| **M5 — Trust & ship** | 7–8 | Dual allowlists + redirect validation; fail-closed remote config + epoch floor; signed Sparkle; notarized v1 |

---

## Testing strategy

- **Unit:** `RichTextCodec` round-trips (RTF/HTML ↔ `FormattedText`); tag/token
  encode-decode + structural validation and plain-text fallback;
  `MarkupSanitizer` (remote-resource stripping, RTF attachment/link removal, caps,
  malformed input); engine request builders/parsers; deterministic language
  aggregation (`>50%` / `.mixed` / `.unknown`, undetected excluded);
  `RequestRegistry` **apply-if-current / cache hit-miss / closure rejection /
  cache-hit-cancels-in-flight / full-`CacheKey` correctness**; clipboard
  conservative-restore predicate (materializability pre-check + ambiguity abstain);
  chunking + secondary split; `StateReconciler` repair paths; **corrupt-settings /
  failed-migration fail-safe**; **paid-confirmation gating at the send boundary**
  across every entry point (+ cache-hit exemption); **key validity → unconfigured**
  on failed Validate / 401; **remote-config verification** (signature, monotonic
  version, expiry, sticky disable, allowlist) + **clock-rollback** + **config-epoch
  floor** (downgrade case); **HTTP-redirect rejection** + no body/credential
  forwarding + allowlist separation.
- **Integration:** mock `TranslationService` to drive coordinator/modal without
  network; provider tests against recorded fixtures incl. every error class.
- **Acceptance-test matrix:** execute spec §12 (apps × selection types +
  scenario coverage) as the pre-release gate.
- **Permission states:** granted / denied / revoked-mid-session / re-granted.

---

## Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Google Free endpoint rate-limits or breaks (single point of failure) | Default path fails | Local availability monitoring + signed kill-switch/endpoint override; defined fallback chain (AI → Cloud → actionable error); legal sign-off |
| App doesn't expose selection (some Electron/PDF) | Capture fails | Dual capture (pasteboard + AX); honest "No selection" state |
| Clipboard restore clobbers a newer user copy | Data-loss feel | Materializability pre-check + conservative ownership-gated restore (abstain on ambiguity); serialized captures; matrix testing |
| Stale slow response overwrites newer result / mutates a closed panel | Wrong UI | Two-identity lifecycle: new `OperationID` + cancel on every presentation change (incl. cache hit); apply-if-current + closure invalidation (§5.3) |
| Untrusted captured/generated markup (remote resources, malformed, RTF objects) | Privacy/render bug | `MarkupSanitizer` allowlist + no remote loads + caps; validate or fall back to plain (HTML **and** RTF) |
| Credential/text exfiltration via HTTP redirect | Data leak | Redirect delegate validates every 3xx; reject cross/off-allowlist; never forward body or `Authorization`/`X-Goog-Api-Key` (§9) |
| Compromised config key or malicious sticky-disable | Provider wrongly disabled / redirected | Fail-closed allowlist-bound config (no new hosts); dual config keys; signed-release epoch bump + **monotonic epoch floor** blocks downgrade re-activation (§6.1) |
| Silent overspend on a paid engine | Unexpected cost | Entry-point-agnostic paid-confirmation (AI **and** Cloud); auto-enhance pauses over threshold; auto-spend limit (§6.5) |
| AI model names change (e.g. DeepSeek alias retirement 2026-07-24) | Calls 404 | Editable model config, not hardcoded; document defaults |
| Inline-style preservation imperfect on Google Free | UX expectation | Structure guaranteed everywhere; validated placeholders with plain fallback; AI/Cloud for full fidelity |
| Notarization / Accessibility friction on first run | Drop-off | Strong onboarding with deep links and live re-check |

---

## Out of scope for v1 (candidate backlog)

- Translate-in-place / translate-and-overwrite of the selection (spec decision #6).
- Translation history, favorites, glossary.
- OCR / image / speech translation.
- Additional engines (DeepL, Gemini, Anthropic).
- Per-app rules and additional target languages.
- Google Cloud **v3** (service-account flow, glossaries).
- Mac App Store distribution (sandbox-incompatible — spec §10).
