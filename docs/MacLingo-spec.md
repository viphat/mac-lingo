# MacLingo — Technical Specification

**Status:** Draft v6 (revised after fifth spec review)
**Platform:** macOS (native)
**Owner:** ShareWis Devs
**Last updated:** 2026-06-25

> **Revision note (v6):** resolves the fifth-round gaps — paid-confirmation is
> entry-point-agnostic (applies to every paid send, not just first-op/auto-enhance)
> (§6.5); pinned-panel result is retained on a live `providerConfigRevision` bump
> while subsequent presentation changes re-resolve under the new revision (§5.3,
> §5.5); a failed **Validate** or runtime 401 marks the provider unconfigured and
> triggers live reconciliation (§5.5, §6.2, §7); defined fail-safe for a failed or
> corrupt settings migration at launch (§5.5, §10); and a **version-independent
> monotonic config-epoch floor** that blocks a manual downgrade from re-activating
> a discarded sticky-disable (§6.1).
>
> **Revision note (v5):** resolves the fourth-round gaps — first op uses the
> **configured default engine** with defined auto-enhance-when-default-is-AI
> behavior (§3.1); single transient panel + accumulating pinned panels retrigger
> policy (§3.1); closure invalidates the `OperationID` and rejects post-close
> completions (§5.3); paid-translation confirmation covers **AI and Cloud** with
> an explicit auto-enhance/auto-spend policy (§6.5, §7); `.unknown` aggregation
> rules (§3.2); remote-config fetch timing + atomic apply through `StateReconciler`
> with Free-cache invalidation (§5.5, §6.1); **HTTP redirect validation /
> cross-allowlist rejection / no body+credential forwarding** (§9, P0); and
> dual config-key rotation + epoch-based recovery via signed release (§6.1).
>
> **Revision note (v4):** cache hits cancel in-flight ops; SelectionSnapshotID vs
> OperationID; full cache key; modal-close lifecycle; cleanup-vs-restore;
> deterministic >50% aggregation; authoritative Pin; live provider reconciliation;
> Cloud key header; data-vs-control-plane allowlists; sticky-disable config.
>
> **Revision note (v3):** fail-closed allowlist-bound remote config, RTF
> sanitization, materializability pre-check, full dismissal coverage, oversized-
> block chunking, `.mixed` aggregation, Cloud settings path, signed Sparkle feed.
>
> **Revision note (v2):** engine-specific formatting guarantees, request lifecycle,
> source typing, clipboard ownership, settings atomicity, markup trust boundary,
> large-selection limits, Cloud v2-vs-v3, acceptance matrix.

---

## 1. Overview

MacLingo is a lightweight macOS menu-bar utility that translates the currently
selected text anywhere on the system via a global hotkey. The result appears in
a small floating modal positioned near the cursor.

- **Default engine:** Google Translate (no API key required).
- **Optional enhancement:** AI translation (BYOK) via DeepSeek or OpenAI,
  triggered by an explicit button — never automatic by default.
- **Target language:** user-selectable from English, Vietnamese, Chinese
  (Simplified), Chinese (Traditional).
- **Formatting:** **block structure (line breaks, paragraphs, lists) is
  preserved on every engine.** Inline styling (bold/italic/underline) is
  preserved on the high-fidelity engines (AI, Google Cloud) and is best-effort —
  with graceful degradation to plain-within-block — on Google Free. Exact
  per-engine guarantees are in §3.4 / §6.3.
- **Dismissal:** the modal closes instantly on `Esc` while it is the key
  (hovered/focused) panel.

### Non-goals (v1)

- Document/file translation, OCR/image translation, speech translation.
- Inline in-place replacement of selected text (translate-and-overwrite).
- Translation history / glossary management (candidate for v2).
- Mac App Store distribution (sandbox is incompatible with the input-capture
  approach — see §10).

---

## 2. Target environment

| Item | Decision |
|---|---|
| Minimum OS | macOS 15.0 (Sequoia) |
| Architecture | Universal binary (Apple Silicon + Intel) |
| Language | Swift 6 |
| UI | SwiftUI for views/settings; AppKit (`NSPanel`, `NSHostingView`) for the floating modal and event taps |
| App style | Menu-bar agent (`LSUIElement = true`, no Dock icon) |
| Distribution | Developer ID–signed, notarized `.dmg`; in-app updates via Sparkle |

---

## 3. User-facing features

### 3.1 Quick translation by hotkey

1. User selects text in any application.
2. User presses the global hotkey (default `⌥⌘T`, customizable).
3. MacLingo opens an `OperationID`, performs a **cancellation-aware capture**
   (§4.3), and builds an immutable `SelectionSnapshot` with a stable
   `SelectionSnapshotID` (the source text; reused across engine/target switches).
   The first translate operation runs the **configured default engine** (§7 —
   Google Free / Google Cloud / AI provider; Google Free out of the box) and
   shows the result in a floating modal near the cursor.
4. The modal exposes an **Enhance with AI** button. Pressing it runs the
   configured AI provider on the same `SelectionSnapshot`.

**Default engine & auto-enhance interaction:**
- The first operation uses the **default engine**, not unconditionally Google.
  If the default engine is unconfigured/unreachable at trigger time, MacLingo
  resolves it via the fallback chain (§6.1).
- **Auto-enhance** (default OFF) only applies a *second, AI* pass after a
  *non-AI* default. **If the default engine is already the AI provider,
  auto-enhance is a no-op** (no redundant second AI call).
- Auto-enhance respects the paid-translation confirmation policy (§6.5): if the
  snapshot exceeds the confirmation threshold it does **not** silently spend —
  see §6.5.

**Single transient panel + pinned panels (retrigger policy):**
- There is at most **one transient (unpinned) panel**. A new hotkey trigger
  **reuses** it: the panel re-anchors at the new cursor location, its prior
  operation is cancelled and its snapshot/cache cleared (§5.3 close lifecycle),
  and a fresh `OperationID` + `SelectionSnapshot` begin.
- If the current panel is **pinned**, it is left in place; the new trigger opens
  a **separate new transient panel**. Pinned panels accumulate as independent
  windows (each with its own snapshot/cache) until the user closes them.

**Result caching & presentation changes (resolved):** the modal shows **one
active result at a time** with an **engine selector** (Google Free / Google
Cloud / AI provider). Each computed result is cached by
`(selectionSnapshotID, engineID, targetLanguage, providerConfigRevision,
promptVersion, codecVersion)` — so changing the AI model, API key, prompt, or
codec version never serves a stale result.

- **Every presentation change opens a new `OperationID` and cancels/invalidates
  the in-flight operation** — *including a cache hit*. A cache hit then presents
  the cached content synchronously (no network); a cache miss issues a request
  (§5.3). This prevents a slow in-flight AI response from overwriting a result
  the user has since switched to.
- **Apply-if-current** is evaluated against `OperationID` (§5.3): a result
  applies only if its operation is still current **and the panel is open**.
- **Copy** always copies the currently displayed (active) result.
- Retry opens a new `OperationID` for the current engine on the same snapshot and
  overwrites that cache entry.

Out of the box the default engine is **Google Free**, so the first result is
key-free and immediate; users may set Google Cloud or an AI provider as the
default instead. AI enhancement beyond the default is opt-in per translation via
the button, or automatic when **auto-enhance** is ON (subject to the rules
above).

### 3.2 Default language selection

Settings let the user pick one **target language** from:

| Language | Engine code (target) | Display tag |
|---|---|---|
| English | `en` | `en` |
| Vietnamese | `vi` | `vi` |
| Chinese (Simplified) | `zh-CN` | `zh-Hans` |
| Chinese (Traditional) | `zh-TW` | `zh-Hant` |

The **source language is always auto-detected** and may be **any** language the
engine returns (e.g. Japanese, French) — it is not limited to the four target
choices. The detected source is a BCP-47 value with `.known`, `.mixed`, and
`.unknown` cases (see §5.1). Because block-wise/chunked translation can detect
different languages per block, aggregation is **deterministic**:

1. For each block **with a valid detection**, count its **non-whitespace source
   grapheme clusters** and attribute them to that block's language. Blocks that
   return **no detection are excluded from both numerator and denominator.**
2. If **no block** has a valid detection, the result is `.unknown`.
3. Otherwise, over the detected-block total: if one language holds **> 50%** it
   is the `.known` source; if no language exceeds 50%, the result is `.mixed`.

Per-block detections (including which blocks were undetected) are retained
internally. The modal shows the aggregated source label and offers a quick
inline target-language switcher.

### 3.3 The translation modal

- Borderless floating panel, appears near the mouse cursor, clamped to the
  visible screen frame.
- Contents: detected source language → target language, the active translated
  text (rendered with preserved formatting), the engine selector/indicator, and
  a loading state while fetching.
- Controls: **Enhance with AI**, **Copy**, engine selector, target-language
  switcher, **Pin** (keep open — authoritative contract in §8), **Close**.
- Draggable by its body.
- **Dismissal:** pressing `Esc` while the panel is the **key** window (it becomes
  key on hover/click — see §8) closes it immediately and the key event is
  consumed (it does not reach the previously-active app). Other dismissal paths
  and the Pin contract are defined authoritatively in §8.

### 3.4 Formatting preservation

**Block structure is the universal guarantee.** Line breaks, paragraph
boundaries, and list item boundaries are preserved 1:1 on every engine because
translation is performed **block-by-block** and reassembled by block index —
never by string offset.

**Inline styling (bold/italic/underline) uses tagged segments, not positional
reapplication.** Because translation changes string length and word order,
offset-based re-styling is unreliable and is not used. Instead:

- Inline runs are encoded as **stable tagged segments** before translation:
  real HTML tags (`<b>`, `<i>`, `<u>`) for HTML-capable engines (AI, Google
  Cloud), or sentinel placeholder tokens for the plain-text Google Free endpoint.
- After translation, the output is **structurally validated**: tag/token
  whitelist, balanced nesting, and the same multiset of opening/closing markers
  as the input. See §5.4.
- **On validation success**, styling is reattached from the tags/tokens.
- **On validation failure or unsupported input**, that block **degrades to
  plain text** (structure still preserved) rather than producing wrong styling.

On **Copy**, MacLingo writes a sanitized rich representation (RTF) plus a
plain-text fallback to the pasteboard, so pasting into a rich editor keeps
styling that survived validation. Exact per-engine guarantees: §6.3.

---

## 4. System integration & permissions

### 4.1 Required permissions

- **Accessibility** (`AXIsProcessTrusted`): required to synthesize the copy
  keystroke and to read selected text via the Accessibility API. On first run,
  MacLingo detects the missing permission, explains why, and deep-links to
  *System Settings → Privacy & Security → Accessibility*. Revocation is detected
  at trigger time and mid-session (see §11).

No other system permissions are required. MacLingo makes outbound network calls
only to the configured translation endpoints.

### 4.2 Global hotkey

- Implemented with the `KeyboardShortcuts` package (user-recordable shortcut +
  conflict handling).
- Default: `⌥⌘T`. Fully customizable; persisted in settings (see §5.5 for
  registration atomicity).

### 4.3 Capturing the selected text — dual capture (pasteboard + AX)

MacLingo needs both plain text and, when available, a rich representation. The
default strategy uses **both** the Accessibility API and the pasteboard,
combining their strengths. **Captures are serialized** (one at a time, via an
actor) so two triggers cannot interleave on the shared pasteboard. The
`OperationID` is opened **before** capture (§3.1, §5.3), and capture is
**cancellation-aware**: a guaranteed-cleanup (`defer`) block always **runs** if
the operation is superseded mid-capture, but **restoration inside that cleanup is
itself gated by the ownership predicate** (step 5 below) — cleanup is guaranteed
to execute, restoration is not unconditional. The partial capture is discarded.

**AX read (fast, clipboard-free).** Read `kAXSelectedTextAttribute` from the
focused `AXUIElement`. Instant, no clipboard mutation; confirms a selection
exists and yields plain text. Reliable in native apps; often empty in
browsers/Electron.

**Pasteboard read via synthesized copy (rich), with conservative ownership rules:**

1. **Materializability pre-check.** Inspect the current pasteboard. If it
   contains **promised/lazy or app-private types that cannot be fully
   materialized and restored**, MacLingo **does not synthesize a copy** for this
   invocation and falls back to the AX read — so it can never overwrite content
   it would be unable to put back.
2. Record `NSPasteboard.general.changeCount` as `C0` and snapshot all concrete,
   fully-materialized items.
3. Synthesize `⌘C` via `CGEvent`; poll for `changeCount > C0` (timeout ~200–400 ms).
4. On change, record `C1` and read the richest type (prefer `public.rtf` /
   `public.html`, then `public.utf8-plain-text`).
5. **Conservative restore.** Restore the snapshot **only if** `changeCount == C1`
   at restore time **and** the change from `C0`→`C1` was a single, unambiguous
   step. If the count differs, jumped by more than the expected single increment,
   or is otherwise ambiguous (concurrent writers), MacLingo **does not restore**
   and leaves the current clipboard intact.

> Acknowledged limit: `changeCount` proves *no write occurred since* our copy; it
> cannot *prove the observed change originated from MacLingo*. The pre-check
> (step 1) plus conservative restore (step 5) bound the risk — MacLingo only ever
> mutates a clipboard it can fully restore, and abstains from restoring whenever
> ownership is uncertain.

**Combine:** use the **richest successful** result — pasteboard RTF/HTML when
present, otherwise AX (or pasteboard plain-text). AX is also the fallback when
the pasteboard never changes (copy swallowed) or when step 1 abstains.

A settings **AX-only privacy mode** restricts capture to the AX read (no
synthesized copy, no clipboard mutation), trading away rich formatting in apps
that only expose selection via the pasteboard.

If both paths yield nothing, the modal shows a friendly "No text selected" state.

---

## 5. Architecture

```
MacLingoApp (SwiftUI App, MenuBarExtra)
├── PermissionsCoordinator      // accessibility check + onboarding + live re-check
├── HotkeyManager               // KeyboardShortcuts registration → trigger
├── SelectionCapturer (actor)   // dual AX + pasteboard, changeCount-safe restore
│     └── RichTextCodec         // RTF/HTML <-> FormattedText; tag encode/decode + validation
├── TranslationCoordinator      // request lifecycle: snapshot → translate → present
│     ├── RequestRegistry        // OperationID issuance, current-operation, cancellation
│     └── TranslationService (protocol)
│           ├── GoogleFreeProvider      // unofficial endpoint, default
│           ├── GoogleCloudProvider     // official API v2 + API key (optional)
│           ├── OpenAIProvider          // BYOK
│           └── DeepSeekProvider        // BYOK
├── MarkupSanitizer             // trust boundary for captured + generated markup
├── ModalPresenter              // NSPanel lifecycle, positioning, key/Esc + outside-click
│     └── TranslationModalView  // SwiftUI content
├── SettingsStore               // Defaults-backed desired state + schema version
│     └── StateReconciler        // launch + live reconcile of system/provider state
└── KeychainStore               // API keys (Security framework)
```

### 5.1 `TranslationService` protocol & types

```swift
enum TargetLanguage { case en, vi, zhHans, zhHant }   // the 4 user choices

enum DetectedLanguage {                                // source: any language
    case known(bcp47: String)                          // e.g. "ja", "fr"
    case mixed([String])                               // blocks disagreed; §3.2 aggregation
    case unknown                                        // engine returned nothing/unparseable
}

// Two distinct identities (see §5.3):
typealias SelectionSnapshotID = UInt64   // stable per capture; reused across switches
typealias OperationID = UInt64           // one per translate/present operation

struct SelectionSnapshot {               // immutable; built after capture
    let id: SelectionSnapshotID
    let source: FormattedText            // blocks + inline runs (only the source)
}

struct CacheKey: Hashable {              // §3.1 result cache
    let selection: SelectionSnapshotID
    let engine: EngineID
    let target: TargetLanguage
    let providerConfigRevision: UInt64   // bumps on model/key/provider change
    let promptVersion: UInt32
    let codecVersion: UInt32
}

struct TranslationRequest {
    let operationID: OperationID
    let selection: SelectionSnapshot
    let engine: EngineID
    let target: TargetLanguage
}

struct TranslationResult {
    let operationID: OperationID         // UI applies only if still current
    let text: FormattedText
    let detectedSource: DetectedLanguage
    let engine: EngineID
}

protocol TranslationService {
    var id: EngineID { get }
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}
```

Adding a future engine = one new `TranslationService` conformer + a settings entry.

### 5.2 `FormattedText` intermediate model

Normalized, engine-agnostic representation produced by `RichTextCodec`:

- **Block list:** paragraphs and list items (with level/marker), preserving
  order and line breaks. Blocks carry a stable index used for reassembly.
- **Inline runs per block:** `(substring, attributes)` where attributes ∈
  {bold, italic, underline, code}.

Used for translation, modal rendering (`AttributedString`), and rich copy-out
(re-serialized to RTF after sanitization).

### 5.3 Concurrency & request lifecycle

- **Two identities.** A `SelectionSnapshotID` is stable for one captured source
  and is reused across engine/target switches. An `OperationID` identifies a
  single translate/present operation; the modal tracks **one current
  `OperationID`**.
- **Open-before-capture.** A new `OperationID` is opened **before** capture
  (§4.3); the `SelectionSnapshot` is then built. The snapshot is immutable, so
  later switches never mutate an in-flight job.
- **Every presentation change opens a new `OperationID` and cancels the in-flight
  `Task`** (Swift structured cancellation) — this includes engine switch, target
  switch, retry, auto-enhance, **and a cache hit**. A cache hit fills the UI
  synchronously from cache; a miss issues a request. Cancelling on cache hits is
  what stops a late AI response from overwriting a result the user switched to.
- **Apply-if-current rule:** a `TranslationResult` updates the UI **only if its
  `operationID` equals the panel's current `OperationID` *and* the panel is in
  the open state.** Stale results are discarded.
- **Closure invalidation (cooperative-cancellation safety):** because Swift task
  cancellation is *cooperative*, a provider call may still return after cancel.
  On close/dismiss the panel transitions to a **closed** state and sets its
  current `OperationID` to an **invalid sentinel**. Any completion arriving after
  closure — even one carrying what was the current `OperationID` — fails the
  apply-if-current check and is **rejected** (its result and any cached entry for
  the released panel are dropped). No late completion can mutate a closed panel.
- **Result cache:** keyed by the full `CacheKey` (§5.1) including
  `providerConfigRevision`, `promptVersion`, and `codecVersion`, so a changed
  model/key/prompt/codec never serves a stale entry.
- **Auto-enhance chaining:** the AI step uses the same `SelectionSnapshot` and a
  new `OperationID`; it applies only if still current and the panel is open.
- **Modal close/dismiss lifecycle:** on close or dismiss, MacLingo sets the
  closed state (above), **cancels all in-flight tasks (capture, translation,
  chunk requests), removes all event monitors, and clears the source
  `SelectionSnapshot` and result cache for that panel.** A **pinned** panel
  retains its current result + cache while open; everything is released when it
  finally closes.

### 5.4 Markup trust boundary (sanitization)

**Captured clipboard HTML, captured RTF, and AI-generated markup** are all
untrusted and pass through `MarkupSanitizer` before rendering, validation, or
copy-out. Captured RTF/HTML is sanitized at the `RichTextCodec` parse step, not
just HTML:

- **Attribute allowlist (RTF and HTML alike):** only the inline attributes
  {bold, italic, underline, code} and block structure {paragraph, line break,
  list} survive. For HTML this means `<b>/<strong>`, `<i>/<em>`, `<u>`, `<br>`,
  `<p>`, and list tags; everything else is stripped to text. No `style`, `class`,
  event handlers, or scripts.
- **RTF normalization:** strip embedded attachments/images (`NSTextAttachment`),
  hyperlinks/`link` attributes, embedded objects, fonts/colors/sizes, and any
  field/`\field`/external-reference constructs — keep only the allowlisted inline
  attributes and structure.
- **No remote resources:** `<img>`, `<link>`, `<object>`, `url()`, RTF
  attachments, and any remote fetch are removed; nothing in captured/generated
  content may trigger a network load.
- **Caps:** maximum nesting depth and maximum node/character count; content over
  the cap is truncated or rejected.
- **Structure validation:** markers must be balanced and well-nested with a
  matching open/close multiset (see §3.4). On any failure → **fall back to plain
  text** for the affected block.

### 5.5 Settings & system-state integrity

System side effects (hotkey registration, `SMAppService` login item, Keychain)
can disagree with stored preferences after a partial failure. Rules:

- **Source of truth:** the persisted `SettingsStore` holds the *desired* state;
  Keychain holds the *key material* (Defaults stores only a `hasKey(provider)`
  boolean, never the secret).
- **Write order:** perform the system operation **first**; persist the new value
  **only after it succeeds**. On failure, keep the prior value and surface an
  actionable error. No optimistic persistence.
- **Launch reconciliation:** `StateReconciler` runs at startup to (a) re-register
  the hotkey from the persisted shortcut, (b) verify `SMAppService` status
  matches "launch at login", (c) verify Keychain presence matches each
  `hasKey` flag (**AI provider key and the Google Cloud API key**), (d) verify
  the selected default engine is actually configured (e.g. don't leave "Cloud"
  selected with no key) and fall back per §6.1 if not, and (e) repair/clear
  mismatches and log them.
  - **Presence is not validity.** Reconciliation checks key *presence*, but a
    present-but-invalid key (rejected by **Validate** in §7, or returning **401**
    at runtime) does **not** count as "configured." A failed Validate or a runtime
    401/403 from a provider marks that provider **unconfigured** and triggers live
    reconciliation immediately: the engine is removed from the selector, the
    default falls back per §6.1, auto-enhance is disabled if it depended on that
    provider, and the failure is surfaced as an actionable settings error — not a
    transient toast that leaves a broken default selected.
- **Immediate (live) reconciliation:** any provider-setting change *during a
  session* — removing/replacing a key, disabling Cloud, switching AI provider or
  model, **or applying a new remote config that switches/disables the Google Free
  endpoint** — is reconciled **immediately and atomically**, not just at launch:
  cancel affected in-flight operations, **bump `providerConfigRevision`** (which
  invalidates dependent cache entries, **including cached Google Free results when
  the Free endpoint changes or is disabled**), update the engine selector and
  default, and **disable auto-enhance if its provider is no longer valid**. The
  active modal re-resolves its engine via §6.1 if its current engine became
  invalid.
  - **Pinned panels on a live bump:** a pinned panel's **already-rendered result
    is retained unchanged** (it was computed under the old revision and is not
    retroactively re-translated). Because the `CacheKey` carries
    `providerConfigRevision`, its prior cache entries become unreachable after the
    bump; any **subsequent presentation change** on that panel (engine/target
    switch, retry) opens a new `OperationID` and re-resolves under the **new**
    revision — a guaranteed cache miss — rather than serving a stale entry. Remote-config application is described in §6.1 and runs through the
  same `StateReconciler` path.
- **Schema versioning:** `settingsSchemaVersion` is persisted; migrations run at
  launch and must be forward/backward tolerant (see §10).
- **Migration failure is fail-safe (never hard-fails launch):** if the settings
  store is unreadable/corrupt or a migration throws, MacLingo **moves the bad file
  aside** (timestamped backup for diagnostics), **resets to safe defaults**, and
  lets `StateReconciler` rebuild system state from those defaults. Key material in
  Keychain is untouched, so re-deriving `hasKey` from Keychain presence restores
  provider configuration without re-entry. The reset is surfaced as an actionable
  notice ("settings could not be read and were reset; a backup was kept").

---

## 6. Translation engines

### 6.1 Google Translate — Free endpoint (default, no key)

- **Implementation:** unofficial web endpoint
  `https://translate.googleapis.com/translate_a/single`
  (`client=gtx&sl=auto&tl=<target>&dt=t&q=<text>`), parsing the JSON array.
- **Pros:** zero setup, no key, fast, good general quality.
- **Cons / risks:** unofficial and subject to Google's ToS; can rate-limit,
  block, or change without notice; plain-text only (no HTML markup support).
- **Formatting:** translate **block-by-block** (line breaks/paragraphs/lists
  preserved); inline styling attempted via validated placeholder tokens and
  **degraded to plain-within-block on validation failure** (§3.4). No positional
  reapplication.

**Resilience & rollback (required — single point of failure):**

- **Release gate:** legal/release sign-off required before shipping the free
  endpoint as default; the ToS posture is recorded in the release notes.
- **Availability monitoring:** **local-only** — error/block rates are tracked on
  device and shown in diagnostics. No telemetry is sent (consistent with §9). Any
  future remote monitoring would be opt-in and disclosed.
- **Remote config — strictly bounded (no arbitrary hosts):** a signed remote
  config may do only two things: (1) **disable** the free provider (kill switch),
  or (2) **select an endpoint from a compiled-in allowlist** of known Google
  hosts. It **cannot introduce a new host**, so selected text can never be
  redirected to an unlisted destination. Specifically:
  - **Pinned key:** verified against a config public key **embedded in the app**
    and separate from the Sparkle update key.
  - **Monotonic version + expiry:** each config carries a monotonically
    increasing version (anti-rollback/replay) and an expiry timestamp.
  - **Strict endpoint allowlist:** the chosen endpoint must be a member of the
    compiled allowlist or the config is rejected.
  - **Fail-closed + sticky disable:** an invalid, lower-version, or unreachable
    config is ignored. The app persists the **highest-version valid config** seen.
    Crucially, the two directive kinds expire differently:
    - A **disable (kill switch) directive is sticky and fail-safe**: it remains in
      effect past its own expiry and across fetch failures, and is **never undone
      by expiry, a missing config, or a clock change** — only a strictly
      higher-version valid config may re-enable the provider. MacLingo never
      re-enables a disabled provider on failure.
    - An **enable / endpoint-selection directive expires**: past expiry the app
      reverts to the **compiled default endpoint** (but a sticky disable, if any,
      still wins).
  - **Clock-rollback handling:** trust decisions are driven by the **monotonic
    version**, not wall-clock; expiry is a backstop only. A backward clock jump
    can never un-expire an enable directive nor re-enable a disabled provider.
  - **Fetch timing:** the config is fetched **at launch**, **periodically while
    running** (default every 12 h, jittered), and **on return to foreground**;
    fetches are best-effort and time-boxed. Fetching is a control-plane request
    (§9) and never carries selected text.
  - **Atomic application:** a newly accepted config is applied **through
    `StateReconciler`** (§5.5) as one atomic step: cancel active Google Free
    operations, **bump `providerConfigRevision` and invalidate cached Google Free
    results**, update the endpoint/disabled state, and re-resolve the active
    modal's engine via the fallback chain if Free became unavailable.
  - **Pinned key (dual-key) + recovery:** config signatures are verified against a
    **primary and a backup config public key**, both embedded in the app and
    **separate from the Sparkle update key**. Key rotation and recovery happen
    only via a **signed app release** (§10): a release may ship a new key pair and
    a bumped **config epoch**. Stored configs are scoped to a config epoch; when an
    app release **raises the epoch, all previously stored configs are discarded**,
    including a malicious or mistaken **high-version sticky disable**. This makes a
    lost/compromised config key (or a bad sticky-disable) recoverable: ship an app
    update that bumps the epoch and rotates keys.
  - **Monotonic epoch floor (downgrade-safe recovery):** the highest config epoch
    ever seen is persisted as a **version-independent floor**, separate from the
    running app's compiled epoch. A config (or an entire stored config set) whose
    epoch is **below the floor is rejected**, even if the running binary's compiled
    epoch is also below it. This closes the manual-downgrade hole: reinstalling an
    **older** `.dmg` (Sparkle never offers a downgrade, but a user can do it by
    hand) cannot re-read pre-bump stored configs and **cannot re-activate a
    sticky-disable that an epoch bump already discarded**. The floor only ever
    rises; a release rotating keys must therefore ship an epoch **at or above** the
    current floor for its configs to be trusted.
  - **User disclosure:** the privacy note states that a signed config may toggle
    the free provider or switch among Google endpoints, and that text is only
    ever sent to allowlisted translation hosts.
- **Defined degraded behavior when blocked:**
  - If an AI provider key is configured → offer one-tap fallback to AI.
  - Else if Google Cloud is configured → fall back to Cloud.
  - Else → show an actionable error explaining the outage and prompting the user
    to add an AI key or enable Cloud. The app never silently fails.

### 6.2 Google Cloud Translation API (optional, BYOK)

- **Implementation:** **Cloud Translation API v2** with an **API key sent in the
  `X-Goog-Api-Key` request header** (never as a URL query parameter) —
  `POST https://translation.googleapis.com/language/translate/v2` with
  `format=html` for full inline-style preservation. Off by default. Query-string
  keys are avoided because they leak through URL logging/scanning; diagnostics
  **redact** the key from both URLs and headers.
- **Credential clarification (do not conflate versions):** API-key auth is a
  **v2** capability. **v3 does not accept API keys** — it requires OAuth2 /
  service-account credentials and a GCP project ID. MacLingo v1 implements **v2
  + API key** for BYOK simplicity. A future v3 integration (e.g. for glossaries)
  would require the full service-account flow and is out of scope here.
- Paid, per-character billing — surfaced clearly in settings.

### 6.3 Formatting fidelity matrix (per-engine guarantees)

| Engine | Line breaks / paragraphs / lists | Inline styling (bold/italic/underline) |
|---|---|---|
| Google Free | **Preserved** (block-wise reassembly) | **Best-effort** via validated placeholders; **degrades to plain-within-block** on validation failure |
| Google Cloud v2 (`format=html`) | **Preserved** | **Preserved** (HTML tags round-trip) |
| AI (OpenAI / DeepSeek) | **Preserved** | **Preserved** (HTML tags + structural validation; plain fallback on failure) |

Structure is guaranteed everywhere. For dependable inline styling, use AI or
Google Cloud.

### 6.4 AI providers (BYOK)

Both are OpenAI-compatible chat APIs; the user supplies their own key (stored in
Keychain). Triggered by **Enhance with AI** (or auto-enhance if ON).

**Shared prompt contract:** the model receives the source encoded as whitelisted
HTML and a system instruction to (a) detect the source language, (b) translate
into the target language, (c) **preserve all tags, line breaks, and structure
exactly**, and (d) return only the translated HTML with no commentary. Output is
sanitized (§5.4) and structurally validated (§3.4) before rendering.

#### OpenAI

| Field | Value |
|---|---|
| Base URL | `https://api.openai.com/v1` |
| Endpoint | `/chat/completions` (Responses API also supported) |
| Default model | `gpt-5.4-mini` (fast/cheap; configurable) |
| Alt models | `gpt-5.4-nano` (cheapest), `gpt-5.5` (highest quality) |
| Auth | `Authorization: Bearer <key>` |

#### DeepSeek

| Field | Value |
|---|---|
| Base URL | `https://api.deepseek.com` (OpenAI-compatible) |
| Endpoint | `/chat/completions` |
| Default model | `deepseek-v4-flash` (cheap/fast; configurable) |
| Alt model | `deepseek-v4-pro` (stronger reasoning) |
| Auth | `Authorization: Bearer <key>` |

> The legacy aliases `deepseek-chat` / `deepseek-reasoner` retire **2026-07-24**;
> MacLingo targets `deepseek-v4-flash`. Model lists are editable config so new
> models can be added without an app update. (Model IDs and the deprecation date
> verified current as of this revision.)

### 6.5 Large-selection handling

| Parameter | Value (configurable) |
|---|---|
| Hard cap (whole selection) | 20,000 source characters → refuse with a clear message |
| Per-chunk limit | encoded **UTF-8 byte budget** (Google Free) / **token budget** (AI) — not approximate character counts |
| Primary split | **block boundaries** (paragraphs/list items) |
| Secondary split (oversized block) | sentence → word → grapheme-cluster, in that order, until each chunk fits the encoded budget |
| Paid-translation confirmation threshold | > 4,000 source characters → confirm before sending to any **paid** engine (AI **and** Google Cloud), with an estimated token/character count and cost |
| Auto-spend policy | default **Confirm every time over threshold**; optional **Auto-spend up to N characters** (user-set); `N = 0` means always confirm |

- **Paid-translation confirmation (AI and Cloud):** before sending a snapshot
  larger than the threshold to a **paid** engine (an AI provider or Google Cloud),
  MacLingo shows a confirmation with the estimated token/character count and a
  cost note. Google Free (no cost) is exempt.
- **Entry-point-agnostic:** the threshold check guards **every** send to a paid
  engine regardless of how the operation was started — first op, **Enhance with
  AI**, **engine-selector switch to a paid engine**, **target-language switch
  while a paid engine is active**, **retry on a paid engine**, and auto-enhance.
  A cache **hit** presents synchronously and never spends, so it is exempt; only
  a cache **miss** that issues a paid request is gated.
- **Auto-enhance + confirmation interaction (resolved):** auto-enhance **never
  silently spends**. When auto-enhance is ON and the snapshot is **at or below**
  the threshold (or within the user's auto-spend limit), the AI pass runs
  automatically. When it is **over** the threshold (and over any auto-spend
  limit), auto-enhance **pauses and surfaces the confirmation** — it does not
  auto-send and does not silently skip; the user confirms or declines. (Recall an
  AI default makes auto-enhance a no-op, §3.1.)

- **Chunking:** split first on block boundaries. A **single block that still
  exceeds the per-chunk budget** is split further by sentence, then word, then
  grapheme cluster — never mid-grapheme — so an oversized paragraph can always be
  translated. Each chunk carries a `(blockIndex, subRange)` so reassembly is
  exact and in order. Limits are measured on the **encoded** payload (UTF-8 bytes
  / model tokens), not character estimates.
- **Cancellation:** chunked jobs honor `OperationID` cancellation (§5.3); a
  superseded job stops issuing remaining chunks.
- **Partial failure:** a failed chunk leaves its blocks untranslated (original
  text + an inline "failed" badge) instead of failing the whole translation;
  failed chunks are retryable.
- **Line-break safety:** intra-block splits rejoin without introducing or losing
  line breaks; block structure is reassembled from indices, never from the
  translated text's whitespace.

---

## 7. Settings

| Setting | Default | Notes |
|---|---|---|
| Target language | English | EN / VI / ZH-Hans / ZH-Hant |
| Global hotkey | `⌥⌘T` | Recordable; registered atomically (§5.5) |
| Default engine | Google Free | Choices: Google Free / Google Cloud / AI provider — a choice is selectable only if configured (§5.5 reconciliation) |
| Capture method | Dual (pasteboard + AX) | Alt: AX-only privacy mode (no clipboard touch) |
| Google Cloud — enabled | Off | Enables the v2 provider |
| Google Cloud — API key | — | Stored in **Keychain**; Defaults holds only `hasKey(cloud)`; **Validate** action tests the key |
| AI provider | None | DeepSeek / OpenAI |
| AI model | provider default | Editable list |
| AI API key | — | Stored in **Keychain**; Defaults holds only `hasKey(provider)`; **Validate** action tests the key |
| Auto-enhance with AI | Off | When on, an AI pass runs automatically after a **non-AI** default; no-op if default is AI; respects the paid-translation confirmation (§3.1, §6.5) |
| Paid-translation confirmation threshold | 4,000 chars | Applies to AI **and** Google Cloud; Google Free exempt (§6.5) |
| Auto-spend policy | Confirm every time over threshold | Optional "auto-spend up to N chars"; `N = 0` = always confirm (§6.5) |
| Launch at login | Off | `SMAppService` (reconciled at launch + live) |
| Appearance | System | Light / Dark / System |

**Engine-selection behavior:** the modal engine selector and the default-engine
setting only offer engines that are configured and reachable. Selecting Google
Cloud requires a validated key; if a configured engine later fails or its key is
removed, selection falls back per §6.1 and `StateReconciler` clears the stale
default at next launch.

---

## 8. UX details — the modal & Escape handling

- **Panel:** `NSPanel` with `.nonactivatingPanel` + `.borderless` style mask,
  `level = .floating`, rounded background, subtle shadow, `canBecomeKey = true`,
  `hidesOnDeactivate = false`.
- **Positioning:** anchored at the mouse location at trigger time, offset so it
  doesn't cover the selection; clamped within the active screen's visible frame;
  correct across multiple displays, Spaces, and notch/menu-bar insets.
- **Focus / Escape (deterministic):**
  - **Hover = key.** On pointer-enter, MacLingo calls `makeKeyAndOrderFront`. The
    panel is *nonactivating*, so the owning app is not brought to the front, but
    the panel becomes the **key window** and receives key events. (Trade-off: the
    previously-active window loses key status while hovered — standard for
    Spotlight-style panels; documented.)
  - **Local monitor (consumes Esc):** while the panel is key, a `local`
    `NSEvent` monitor handles `keyDown` keyCode 53 → close and **return nil**
    (consumes the event so it does not reach any other app). The local monitor is
    installed on `becomeKey` and removed on `resignKey`.
- **Dismissal (full coverage):** the panel dismisses on any of:
  - **Outside mouse-down**, detected by **both** a `local` monitor (clicks within
    MacLingo's own windows/menus) **and** a `global` monitor (clicks in other
    apps) — a global monitor alone misses MacLingo's own event stream.
  - **App deactivation / `resignKey`:** the panel's `windowDidResignKey` and the
    app's deactivation notification close it — this covers **Command-Tab**, Spaces
    switches, and focus moving to another app, which mouse monitors do not catch.
  - **System interruptions:** a system alert/sheet taking key status triggers the
    same `resignKey` path.
- **Authoritative Pin contract:** **Pin** is open/keep-alive only. While pinned,
  MacLingo suppresses **all implicit dismissals** — outside-click, app
  deactivation / Command-Tab, Space switch, and system-interruption (`resignKey`).
  Pin does **not** suppress **Escape** (Esc still closes when the panel is key)
  nor the explicit **Close** control. Unpinning re-enables implicit dismissals.
- **Close/dismiss cleanup (any path):** closing or dismissing **cancels all
  in-flight tasks, removes the local + global monitors, and clears the panel's
  source snapshot and result cache** (§5.3). A pinned panel retains its content
  while open and releases everything on final close.
- **States:** loading (spinner) → result → error (with retry) → "No selection".
- **Accessibility:** VoiceOver labels on all controls; result text selectable.

---

## 9. Security & privacy

- API keys stored only in the **macOS Keychain**; never in `UserDefaults`,
  plists, or logs.
- Pasteboard mutation is gated by a **materializability pre-check** and restore
  is **conservatively ownership-guarded** by `changeCount` (§4.3); MacLingo never
  overwrites clipboard content it cannot restore and abstains when ownership is
  ambiguous.
- Captured and generated markup (HTML **and RTF**) is **sanitized** (§5.4); no
  remote-resource loading is ever triggered by captured or translated content.
- **Two separate network allowlists:**
  - **Translation-data allowlist** — the only hosts that ever receive selected
    text: the compiled Google translation endpoints + the user's configured AI
    provider. The signed remote config (§6.1) may only disable the free provider
    or switch among hosts **on this allowlist** — never introduce a new one.
  - **Control-plane allowlist** — hosts contacted for app machinery only: the
    remote-config host and the Sparkle appcast/update host. **Selected text is
    never sent to any control-plane host**, and control-plane hosts can never be
    used as translation targets.
- **Redirect handling (HTTP 3xx):** all requests use a `URLSession` delegate that
  **inspects every redirect before following it**. A redirect is followed **only
  if its destination host is on the same allowlist as the original request**
  (translation-data redirect must stay on the translation-data allowlist;
  control-plane on control-plane). **Cross-allowlist or off-allowlist redirects
  are rejected** (treated as an error). On any followed redirect, the request
  **body and sensitive headers** (`Authorization`, `X-Goog-Api-Key`) are **never
  forwarded to a different host** — so selected text and credentials cannot be
  exfiltrated via a redirect from an otherwise-allowlisted endpoint. Default
  redirect auto-following is disabled in favor of this explicit check.
- **No analytics / no telemetry in v1.** Availability monitoring is **local-only**
  (on-device); any future remote reporting would be opt-in and disclosed.
- Source text is sent to a translation-data host only at translation time;
  nothing is persisted to disk in v1.

---

## 10. Distribution, signing & updates

- Direct download `.dmg`, Developer ID signed and **notarized** (stapled).
- **Not** Mac App Store: the App Sandbox forbids the synthesized-keystroke +
  Accessibility approach this app depends on.
- **Sparkle (included in v1):**
  - **Appcast:** HTTPS-hosted `appcast.xml`, single **stable** channel for v1
    (structured to allow a future beta channel).
  - **Trust boundary:** each update item is **EdDSA (ed25519) signed**, **and the
    feed itself is signed** — `SURequireSignedFeed` is enabled so appcast
    metadata and update locations are also protected, not just the archive. The
    public key is embedded in the app; signatures are **verified before
    extraction**; only signed + notarized builds are accepted. Download or
    signature-verification failure → keep the current version, surface an error,
    retry later; never a partial replace.
  - **Key management:** the EdDSA signing key is backed up offline and has a
    documented **rotation** procedure (ship the new public key in an app update
    before retiring the old key, overlapping both during transition).
  - **Downgrade contract:** the appcast advertises forward versions only; Sparkle
    will not offer a lower version.
  - **Settings-schema compatibility:** each release declares
    `settingsSchemaVersion`. Migrations are **additive**; keys are never removed
    or repurposed within a major version; new behavior is gated behind new keys
    with safe defaults. An older build reading a newer settings file **ignores
    unknown keys** (never hard-fails), so forward/backward compatibility holds
    across update and (rare) reinstall-older scenarios. An unreadable store or a
    migration that throws is **fail-safe** (back up, reset to defaults, rebuild —
    §5.5), never a launch failure.
  - **Downgrade & the config epoch:** Sparkle never offers a lower version, but a
    user may manually reinstall an older `.dmg`. The persisted **monotonic config
    epoch floor** (§6.1) travels with the install, so an older binary still rejects
    below-floor stored configs and cannot resurrect a sticky-disable that a prior
    epoch bump discarded.

---

## 11. Error handling & edge cases

| Case | Behavior |
|---|---|
| Accessibility not granted / revoked mid-session | Detect at trigger; onboarding sheet + deep link; hotkey no-ops with a toast; re-check on settings focus |
| No text selected | Modal shows "No text selected" |
| Pasteboard didn't change in time | Fall back to AX selection; else "No text selected" |
| Original clipboard has promised/non-materializable types | **Skip synthesized copy**; use AX read so unrestorable content is never overwritten (§4.3) |
| Ambiguous clipboard ownership (multi/unknown change) | **Do not restore**; leave current clipboard intact (§4.3) |
| Google Free rate-limited / blocked | Fallback chain per §6.1 (AI → Cloud → actionable error); kill switch honored |
| AI/Cloud key missing/invalid (401/403) or failed **Validate** | Mark provider **unconfigured**; live-reconcile (remove from selector, fall back per §6.1, disable dependent auto-enhance); inline prompt to add/fix key (§5.5, §7) |
| Quota / payment (402/429) | Clear error; suggest retry later or alternate engine |
| Network offline / timeout / 5xx | Error state with retry; superseded if a newer request starts |
| Malformed engine/model markup (HTML or RTF) | Sanitize + validate; degrade affected blocks to plain text (§3.4, §5.4) |
| Selection over hard cap | Refuse with message (§6.5) |
| Single block over chunk budget | Secondary split sentence→word→grapheme; reassemble exactly (§6.5) |
| Default engine unconfigured at trigger | First op resolves via fallback chain (§3.1, §6.1) |
| Default engine is AI + auto-enhance ON | Single AI op; auto-enhance is a no-op (§3.1) |
| Retrigger while transient panel open | Reuse panel: cancel prior op, clear snapshot/cache, re-anchor, new op (§3.1) |
| Retrigger while panel pinned | New separate transient panel; pinned panel untouched (§3.1) |
| Mixed-language source | Deterministic >50% over **detected** blocks; `.mixed` if none >50% (§3.2) |
| All/most blocks undetected | Undetected blocks excluded from denominator; `.unknown` if no valid detection (§3.2) |
| Paid engine (AI/Cloud) over confirmation threshold | Confirm with cost estimate before sending; Google Free exempt (§6.5) |
| Auto-enhance over threshold | Pauses and surfaces confirmation; never silently spends or skips (§6.5) |
| Switch to cached engine while AI in-flight | New `OperationID` cancels the AI op; cached result shown; late AI result discarded (§3.1, §5.3) |
| AI model/key/provider changed mid-session | `providerConfigRevision` bumped → caches invalidated, affected tasks cancelled, auto-enhance disabled if invalid (§5.5) |
| Remote config switches/disables Free endpoint | Applied atomically via `StateReconciler`: cancel active Free ops, invalidate Free cache, re-resolve engine (§5.5, §6.1) |
| Late provider completion after panel close | Rejected — panel is closed and `OperationID` invalidated (§5.3) |
| Modal closed/dismissed with work in flight | Closed state set; all tasks cancelled, monitors removed, snapshot + cache cleared (§5.3, §8) |
| Cross-allowlist / off-allowlist HTTP redirect | Rejected; body + `Authorization`/`X-Goog-Api-Key` never forwarded to another host (§9) |
| Expired remote config | Enable/endpoint directives expire → compiled default; **disable (kill switch) stays sticky** (§6.1) |
| Clock rollback | Version (not wall-clock) governs trust; cannot un-expire or re-enable a disabled provider (§6.1) |
| Lost/compromised config key or malicious high-version sticky disable | Recover via signed app release that rotates keys + bumps config epoch (discards stored configs) (§6.1) |
| Manual downgrade to an older app build | Persisted **monotonic epoch floor** rejects below-floor stored configs; a discarded sticky-disable cannot be re-activated by reinstalling an older `.dmg` (§6.1) |
| Corrupt/unreadable settings or failed schema migration | Fail-safe: back up bad file, reset to safe defaults, rebuild via `StateReconciler`; Keychain untouched; surface a notice — never hard-fail launch (§5.5, §10) |
| Switch engine/target to a paid engine over threshold | Confirm with cost estimate before the (cache-miss) send, regardless of entry point; cache hits exempt (§6.5) |
| Invalid/lower-version/non-allowlisted remote config | Rejected fail-closed; highest-version valid config retained (§6.1) |
| Large selection, partial chunk failure | Untranslated blocks flagged + retryable (§6.5) |
| Superseded operation (rapid re-trigger / switch) | Earlier `Task` cancelled; stale result discarded; clipboard restored **only if** ownership predicate passes (§4.3, §5.3) |
| System/provider-state mismatch | Reconciled at launch **and immediately on change**; stale default engine cleared (§5.5) |

---

## 12. Acceptance-test matrix

Each cell is a required pass before release.

### Apps × selection types

| App | Plain | Rich (bold/italic) | Mixed inline | Multi-paragraph | Lists |
|---|---|---|---|---|---|
| TextEdit (RTF) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Safari | ✓ | ✓ | ✓ | ✓ | ✓ |
| Chrome | ✓ | ✓ | ✓ | ✓ | ✓ |
| Electron (Slack / VS Code) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Microsoft Word / Office | ✓ | ✓ | ✓ | ✓ | ✓ |
| Notes | ✓ | ✓ | ✓ | ✓ | ✓ |
| PDF viewer (Preview) | ✓ | n/a | n/a | ✓ | n/a |

Expected fidelity follows §6.3 (structure always; inline styling per engine).

### Scenario coverage

- **Clipboard races:** user copies during capture window → newer content kept
  (changeCount); back-to-back triggers serialized; AX-only mode never mutates
  the clipboard.
- **Permissions:** first-run grant flow; permission revoked mid-session;
  re-granted mid-session.
- **Displays / Spaces:** multi-monitor positioning; Space switch; notch/menu-bar
  clamping; small-screen clamping.
- **Request cancellation:** rapid re-trigger, target switch mid-flight, engine
  switch mid-flight, retry — only the latest result shows; no stale overwrite.
  Cancellation **during synthesized copy** triggers cleanup that restores the
  clipboard **only if** the ownership predicate passes.
- **Default engine & auto-enhance:** first op uses the configured default (Google
  Free / Cloud / AI); when default is AI, auto-enhance is a no-op; an unconfigured
  default resolves via the fallback chain.
- **Retrigger policy:** triggering while a transient panel is open reuses it (prior
  op cancelled, snapshot/cache cleared, re-anchored); triggering while pinned opens
  a separate transient panel and leaves the pinned one intact.
- **Cache hit cancels in-flight:** switching to a cached engine/target while AI
  is loading opens a new `OperationID`, cancels the AI op, and shows the cached
  result; the late AI response is discarded (never overwrites).
- **Cache key correctness:** changing AI model/key/provider/prompt/codec does not
  serve a prior cached result.
- **Closure rejection:** a provider completion that arrives **after** the panel is
  closed (cooperative-cancellation race) is rejected — closed state + invalidated
  `OperationID`.
- **Modal close lifecycle:** dismissing with capture/translation/chunks in flight
  cancels all tasks, removes local+global monitors, and clears snapshot + cache.
- **Live provider reconciliation:** removing a key / disabling Cloud / changing
  model / applying a remote config mid-session cancels affected tasks, invalidates
  caches (incl. Google Free results on endpoint change), updates the
  selector/default, and disables incompatible auto-enhance — without a restart.
- **Paid-translation confirmation:** AI **and** Cloud over the threshold prompt
  with a cost estimate **on every entry point** (first op, Enhance, engine switch,
  target switch, retry, auto-enhance); a cache **hit** never prompts; Google Free
  never prompts; auto-enhance over threshold pauses for confirmation instead of
  silently spending or skipping; auto-spend limit honored.
- **Provider validity:** a present-but-invalid key (failed Validate, or runtime
  401/403) marks the provider unconfigured, removes it from the selector, falls
  back per §6.1, and disables dependent auto-enhance — not just an inline toast.
- **Settings integrity:** a corrupt settings store / failed migration backs up the
  bad file, resets to safe defaults, rebuilds system state, leaves Keychain intact,
  and launches without a hard failure.
- **Clipboard ownership:** copy during capture window kept; non-materializable
  (promised) original → synthesized copy **skipped**, AX used; ambiguous
  multi-change → **no restore**.
- **Oversized content:** a single paragraph larger than the chunk budget is split
  (sentence→word→grapheme) and reassembled exactly; whole selection over the hard
  cap is refused.
- **Language aggregation:** 60/40 two-language selection reports the >50% language;
  50/50 reports `.mixed`; some blocks undetected are excluded from the denominator;
  no valid detection at all reports `.unknown` (deterministic grapheme count).
- **Dismissal & Pin:** outside click (in MacLingo and other apps), Command-Tab,
  app deactivation, Space switch, and system alert each dismiss when unpinned;
  when **pinned**, all implicit dismissals are suppressed but **Esc** and
  **Close** still work.
- **Malformed markup (HTML and RTF):** oversized, deeply nested, unbalanced tags,
  remote-resource references, RTF attachments/links → sanitized; affected blocks
  degrade to plain text; no network load.
- **Provider error classes (each engine):** 401 auth, 402/429 quota/rate-limit,
  5xx, network offline, timeout, blocked/changed endpoint, malformed/empty
  response → correct error state and fallback behavior.
- **Network separation & redirects:** selected text reaches **only translation-data
  hosts**; control-plane (config/update) hosts never receive source text; Cloud key
  travels in `X-Goog-Api-Key` and is redacted in diagnostics; **a cross-allowlist
  HTTP redirect is rejected and never carries the body or credentials**.
- **Remote config:** fetched at launch / periodically / on foreground; valid signed
  config toggles provider / switches among allowlisted hosts and applies atomically
  (cancels Free ops + invalidates Free cache); expired **enable** reverts to compiled
  default while an expired **disable stays sticky**; lower-version/wrongly-signed/
  non-allowlisted config rejected fail-closed; clock rollback cannot re-enable a
  disabled provider; a signed app release that bumps the **config epoch** recovers
  from a lost/compromised key or a malicious high-version sticky disable; and a
  **manual downgrade** to an older build cannot re-activate a discarded config —
  the persisted monotonic **epoch floor** rejects below-floor stored configs.
- **Updates:** valid signed appcast **feed + archive** applies; tampered feed or
  archive signature rejected before extraction; download failure leaves current
  version intact; newer→older settings file read ignores unknown keys.

---

## 13. Decisions (all v1 scope resolved)

1. **Google Free endpoint** is the shipping default — accepted for v1 with the
   resilience/rollback controls in §6.1 (release gate, monitoring, kill switch,
   defined degraded behavior).
2. **Minimum OS:** macOS 15.0 (Sequoia).
3. **Default engine & auto-enhance:** first op uses the **configured default
   engine** (Google Free out of the box); auto-enhance default **OFF**, toggle ON;
   no-op when default is AI; respects paid-translation confirmation (§3.1, §6.5).
4. **Sparkle auto-update:** included in v1, with the trust + schema-compat
   contract in §10.
5. **Capture method:** **dual capture (pasteboard + AX)** default;
   ownership-safe restore (§4.3); AX-only privacy mode selectable.
6. **Translate-in-place:** dropped — not planned.
7. **Result presentation & caching:** single active result with an engine
   selector; **every presentation change (incl. a cache hit) opens a new
   `OperationID` and cancels in-flight work**; cache keyed by the full `CacheKey`
   (selection + engine + target + providerConfigRevision + prompt/codec version);
   Copy copies the active result (§3.1, §5.3).
8. **Google Cloud:** **v2 + API key in `X-Goog-Api-Key` header** for the optional
   provider, with enablement, key storage, validation, and launch + live
   reconciliation (§5.5, §6.2, §7); v3 (service account) out of scope.
9. **Source language:** auto-detected, with `.known`/`.mixed`/`.unknown`; >50%
   over **detected** blocks → `.known`; undetected blocks excluded from the
   denominator; no valid detection → `.unknown` (§3.2, §5.1).
10. **Operation timing:** an `OperationID` is opened at trigger **before** capture;
    capture is cancellation-aware (§4.3, §5.3).
11. **Clipboard safety:** materializability pre-check + conservative restore that
    abstains on ambiguity; guaranteed cleanup runs but restoration is gated by the
    ownership predicate (§4.3).
12. **Remote config:** bounded, **fail-closed**; disable is **sticky** past expiry,
    enable/endpoint directives **expire** to the compiled default; monotonic
    version governs trust (clock-rollback safe); fetched at launch/periodically/
    foreground and applied atomically via `StateReconciler` (cancel Free ops +
    invalidate Free cache); local-only monitoring (§5.5, §6.1, §9).
13. **Sparkle feed:** signed feed (`SURequireSignedFeed`) + pre-extraction
    verification + documented key backup/rotation (§10).
14. **Identity model:** distinct `SelectionSnapshotID` (stable per capture) and
    `OperationID` (per operation) (§5.1, §5.3).
15. **Modal lifecycle:** close/dismiss sets a **closed state**, invalidates the
    `OperationID` (rejecting post-close completions), cancels all tasks, removes
    monitors, and clears snapshot + cache (pinned retains until final close)
    (§5.3, §8).
16. **Pin contract (authoritative):** suppresses all implicit dismissals; does not
    suppress Esc or Close (§8).
17. **Network separation + redirects:** distinct translation-data and control-plane
    allowlists; HTTP redirects validated, cross-allowlist redirects rejected, and
    body/credentials never forwarded to another host (§9).
18. **Retrigger policy:** one transient panel (reused on retrigger); pinned panels
    accumulate as separate windows (§3.1).
19. **Paid-translation confirmation:** threshold applies to **AI and Google Cloud**
    (Free exempt) and is **entry-point-agnostic** — every paid cache-miss send
    (first op, Enhance, engine/target switch, retry, auto-enhance) is gated; cache
    hits are exempt; auto-enhance over threshold **pauses for confirmation**;
    optional auto-spend limit (§6.5, §7).
20. **Config-key recovery:** dual config keys + **config epoch** bumped via a signed
    app release discards stored configs, recovering from a lost/compromised key or
    malicious high-version sticky disable; a persisted **monotonic epoch floor**
    keeps a manual downgrade from re-activating discarded configs (§6.1, §10).
21. **Provider validity vs presence:** a present-but-invalid key (failed Validate or
    runtime 401/403) marks the provider **unconfigured** and triggers live
    reconciliation, not just an inline error (§5.5, §6.2, §7).
22. **Settings integrity:** a corrupt store or failed schema migration is fail-safe
    — bad file backed up, reset to safe defaults, system state rebuilt; Keychain
    untouched; launch never hard-fails (§5.5, §10).
