# CLAUDE.md — MacLingo

Guidance for Claude Code (and humans) working in this repository. Read this
before writing code. The authoritative design is `MacLingo-spec.md`; the build
sequence is `MacLingo-plan.md`. When code and this file disagree, fix the code;
when this file and the spec disagree, the **spec wins** — update this file to match.

---

## What MacLingo is

A native macOS menu-bar utility that translates the **selected text** anywhere on
the system via a global hotkey, showing the result in a floating panel near the
cursor. Google Translate (free, no key) is the default engine; DeepSeek and
OpenAI are optional BYOK "enhance" engines; Google Cloud v2 is an optional
key-based engine. Targets: English, Vietnamese, Chinese (Simplified), Chinese
(Traditional). Source language is auto-detected.

This is a **utility that touches the clipboard, synthesizes keystrokes, reads the
Accessibility API, and sends user-selected text over the network.** Correctness
and safety in those areas are the whole game — see Invariants below.

---

## Tech stack & environment

- **Language:** Swift 6, strict concurrency enabled.
- **UI:** SwiftUI for settings/content; AppKit (`NSPanel`, `NSHostingView`) for
  the floating modal and event monitors.
- **Min OS:** macOS 15.0 (Sequoia). **Universal** (Apple Silicon + Intel).
- **App style:** menu-bar agent — `LSUIElement = true`, no Dock icon.
- **Distribution:** Developer ID, notarized `.dmg`. **Not** Mac App Store (the
  sandbox forbids the synthesized-copy + Accessibility approach). In-app updates
  via **Sparkle**.
- **Dependencies (SPM):** `KeyboardShortcuts`, `Defaults`, `Sparkle`. Keychain via
  the native Security framework (no third-party wrapper).

---

## Build / run / test

> Exact scheme/target names are filled in once the project is scaffolded (Phase 0).
> Until then treat these as the intended shape.

```bash
# Build (debug)
xcodebuild -scheme MacLingo -configuration Debug build

# Run tests
xcodebuild -scheme MacLingo -destination 'platform=macOS' test

# Lint / format (run before every commit)
swiftlint
swift-format lint --recursive Sources
```

- Accessibility permission is required at runtime; grant it to the debug build in
  *System Settings → Privacy & Security → Accessibility* (re-grant after a
  significant rebuild if macOS drops the entitlement).
- Never commit signing identities, API keys, the Sparkle EdDSA private key, or
  the remote-config private keys.

---

## Module map (see spec §5)

```
MacLingoApp                  SwiftUI App + MenuBarExtra
PermissionsCoordinator       Accessibility check, onboarding, live re-check
HotkeyManager                KeyboardShortcuts → trigger
SelectionCapturer (actor)    Dual AX + pasteboard capture; changeCount-safe restore
RichTextCodec                RTF/HTML ↔ FormattedText; tag encode/decode + validation
MarkupSanitizer              Trust boundary for captured + generated markup
TranslationCoordinator       Operation lifecycle: snapshot → translate → present
  RequestRegistry            OperationID issuance, current-op, cancellation
  TranslationService         Protocol; provider impls below
    GoogleFreeProvider       Default, unofficial endpoint, no key
    GoogleCloudProvider      Optional, v2 + API key (X-Goog-Api-Key header)
    OpenAIProvider           BYOK
    DeepSeekProvider         BYOK
ModalPresenter               NSPanel lifecycle, positioning, key/Esc, dismissal
  TranslationModalView       SwiftUI content
SettingsStore                Defaults-backed desired state + settingsSchemaVersion
  StateReconciler            Launch + live reconciliation of system/provider state
KeychainStore                API keys (Security framework)
```

Adding an engine = one new `TranslationService` conformer + a settings entry.
Nothing else should need to know which engine ran.

---

## Invariants — DO NOT violate these

These encode bugs already found and closed in review. Each looks like a
reasonable shortcut; each is wrong here. Section refs point to `MacLingo-spec.md`.

### Clipboard & capture (§4.3)
- Captures run through the **`SelectionCapturer` actor**, one at a time. Never
  touch `NSPasteboard.general` from elsewhere.
- **Materializability pre-check first:** if the current clipboard holds
  promised/non-restorable types, **do not synthesize a copy** — fall back to the
  AX read. Never overwrite a clipboard you cannot fully restore.
- **Restore is conditional, not guaranteed.** The cleanup block always *runs*, but
  it restores **only if** `changeCount == C1` and the change was a single
  unambiguous step. On any ambiguity, **do not restore**. Never restore
  unconditionally.

### Operation lifecycle (§3.1, §5.3)
- Two distinct identities: `SelectionSnapshotID` (stable per capture) and
  `OperationID` (per operation). Don't conflate them.
- **Every presentation change — including a cache hit — opens a new `OperationID`
  and cancels the in-flight `Task`.** A late response must never overwrite a newer
  state.
- A result applies **only if** its `operationID` is current **and the panel is
  open**. On close, set the closed state and invalidate the `OperationID` so
  post-close completions (cooperative-cancellation race) are rejected.
- The result cache key is the **full `CacheKey`** (selection + engine + target +
  `providerConfigRevision` + `promptVersion` + `codecVersion`). Never key on a
  subset — a changed model/key/prompt/codec must miss.

### Formatting (§3.4, §6.3)
- **Never** reapply inline styles by character offset. Translation changes length
  and order. Use **tagged segments** (HTML tags for HTML-capable engines, sentinel
  tokens for Google Free) with **structural validation**; on validation failure,
  **degrade that block to plain text**.
- Block structure is reassembled **by block index**, never by parsing the
  translated text's whitespace.

### Trust boundary (§5.4)
- **All** captured HTML, captured **RTF**, and **all** model output pass through
  `MarkupSanitizer` before render/validate/copy. Attribute allowlist only; strip
  RTF attachments/links/objects; **no remote-resource loading ever**; enforce
  nesting/size caps.

### Networking & secrets (§6.2, §9)
- Two allowlists: **translation-data** (only hosts that may receive selected text)
  and **control-plane** (config + Sparkle hosts, which must **never** receive
  selected text). Don't merge them.
- **Validate every HTTP redirect.** Follow only if it stays on the same allowlist;
  reject cross/off-allowlist redirects; **never forward the body or
  `Authorization`/`X-Goog-Api-Key` to a different host.** Disable default redirect
  auto-following.
- Google Cloud key goes in the **`X-Goog-Api-Key` header**, never the URL.
- API keys live **only in Keychain**; `Defaults` stores only `hasKey(provider)`.
  **Redact** keys from all logs/diagnostics (URLs and headers).
- No analytics / no telemetry in v1. Availability monitoring is local-only.

### Remote config (§6.1)
- Bounded and **fail-closed**: it may only *disable* the free provider or *select a
  host from the compiled allowlist* — **never introduce a new host**.
- **Disable is sticky** past expiry/failures; enable/endpoint directives expire to
  the compiled default. **Monotonic version governs trust**, not the wall clock.
- Recovery from a lost/compromised key or malicious high-version sticky-disable is
  via a **signed app release that bumps the config epoch** (discards stored
  configs). Apply config changes atomically through `StateReconciler`.

### Settings & system state (§5.5)
- Apply the system op **first**, persist **only on success**. Reconcile at launch
  **and immediately** on any provider-setting change (cancel affected ops, bump
  `providerConfigRevision`, invalidate caches, fix selectors/defaults, disable
  invalid auto-enhance).

### Money & safety (§3.1, §6.5)
- Paid engines (AI **and** Google Cloud) over the confirmation threshold require
  **explicit confirmation**; Google Free is exempt. **Auto-enhance never silently
  spends** — over threshold it pauses for confirmation. Auto-enhance is a **no-op**
  when the default engine is already AI.

---

## Conventions

- **Concurrency:** shared mutable state lives in actors (`SelectionCapturer`,
  registry/cache). Honor cooperative cancellation (`Task.checkCancellation()` /
  check `isCancelled` in loops and between chunks). No blocking the main thread.
- **No force unwraps** (`!`) in non-test code; no `try!`. Model absence with
  optionals/`Result`/typed errors.
- **Engines:** model lists are **editable config, not hardcoded constants**.
  Defaults: OpenAI `gpt-5.4-mini`, DeepSeek `deepseek-v4-flash`. Note: DeepSeek
  legacy aliases `deepseek-chat`/`deepseek-reasoner` retire **2026-07-24**.
- **UI:** keep AppKit panel mechanics out of SwiftUI views; the panel's key/Esc
  and dismissal logic lives in `ModalPresenter` (see spec §8 for the exact
  monitor/Pin contract — local monitor consumes Esc, global+local mouse monitors
  for dismissal, Pin suppresses all implicit dismissals but not Esc/Close).
- **Tests:** prioritize unit coverage for `RichTextCodec`, `MarkupSanitizer`,
  `RequestRegistry` (apply-if-current, cache hit/miss, closure rejection),
  clipboard restore predicate, chunking/secondary split, language aggregation,
  remote-config verification, and redirect rejection. The §12 acceptance-test
  matrix is the pre-release gate.

---

## Workflow

- **Spec-driven:** implement against `MacLingo-spec.md`; if a requirement is
  ambiguous or missing, raise it rather than inventing behavior. Reflect any
  agreed change back into the spec (and bump its revision note).
- Work the plan's phases in order; each phase ends in something runnable. QA
  checkpoints land at the end of phases 2, 4, 5, and 8.
- **Commits:** small and focused; imperative subject; reference the spec section
  or plan phase touched (e.g. `capture: gate restore on changeCount (§4.3)`).
- **Before committing:** `swiftlint` + `swift-format` clean, tests pass, no
  secrets staged.
- Don't expand scope into v1 non-goals (translate-in-place, history/glossary,
  OCR/speech, extra engines/languages) without a spec change.

---

## Pointers

- `MacLingo-spec.md` — authoritative design (§ references throughout this file).
- `MacLingo-plan.md` — phased build order, milestones, testing, risks.
