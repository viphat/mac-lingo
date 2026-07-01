# Remember last-used target language / engine — design

Date: 2026-07-01
Status: Approved

## Problem

`SettingsStore.targetLanguage` / `defaultEngine` are read once per hotkey
trigger (`TranslationCoordinator.makeContext()`) and never written back. The
modal's target-language menu, engine menu, and "Enhance with AI" button
(`PanelSession.switchEngine`/`switchTarget`, `Sources/MacLingo/Translation/PanelSession.swift`)
only mutate the session's local vars. Closing the panel discards the choice;
the next trigger — even in the same run — starts over from the old defaults.

## Goal

An explicit, successful choice of target language or engine inside the modal
becomes the new app-wide default, surviving relaunch, exactly like changing it
in the Settings screen would.

## Non-goals

- Does not touch the `autoEnhance` toggle. Clicking "Enhance with AI" changes
  the *engine* for that session (and, per this feature, persists that engine
  choice); it does not flip the separate auto-enhance-by-default setting.
- Does not persist engine/target changes that were not explicitly chosen by
  the user (auto-enhance's automatic upgrade pass, live-reconciliation's
  fallback when a configured engine becomes invalid).
- Does not persist a choice that never actually completed (declined paid
  confirmation).

## Design

### `PanelSession` (`Sources/MacLingo/Translation/PanelSession.swift`)

- Add `private var pendingPersist: (engine: EngineID, target: TargetLanguage)?`.
- Split the existing mutation logic into an internal, non-persisting core and
  a persisting public entry point:
  - `private func applyEngine(_ engine: EngineID)` / `applyTarget(_ target:)`:
    sets the var, calls `present()`. No effect on `pendingPersist`.
  - `func switchEngine(_ engine: EngineID)` / `switchTarget(_ target:)`
    (existing public API, called by `ModalController` for menu picks and
    "Enhance with AI"): arms `pendingPersist = (engine, target)`, then calls
    the internal `apply...`.
- `maybeAutoEnhance()` and `reconcile(...)`'s invalid-engine fallback switch
  to calling `applyEngine` directly instead of `switchEngine`, so they never
  arm `pendingPersist`.
- `update(_:)`: when the new display is `.result` and `pendingPersist` is
  armed, fire `onCommit?(pendingPersist.engine, pendingPersist.target)` and
  clear `pendingPersist`. This covers a direct send, a cache hit (served
  synchronously inside `present()`), and a send that resumed after paid
  confirmation.
- `cancelPaidSend()`: clear `pendingPersist` (in addition to existing
  `pending = nil` / revert-to-`lastApplied` behavior) — a declined send must
  not persist.
- `begin(...)`: clear `pendingPersist` (fresh capture, no in-flight user
  choice to commit).
- New public hook: `var onCommit: ((EngineID, TargetLanguage) -> Void)?`.

### `ModalController` (`Sources/MacLingo/Modal/ModalController.swift`)

- Wire `session.onCommit` (alongside the existing `onChange`/
  `onProviderUnauthorized` wiring) to a closure that writes into
  `SettingsStore`:
  - `settings.targetLanguage = target`
  - `settings.defaultEngine = <mapped from engine>`:
    `.googleFree → .googleFree`, `.googleCloud → .googleCloud`,
    `.openAI`/`.deepSeek → .aiProvider` (the modal only ever offers the one
    AI provider that's already configured in Settings, so `aiProvider` itself
    never needs to change here).
- No other reconciliation call is needed: `defaultEngine`/`targetLanguage`
  writes are not among the provider-setting changes that trigger
  `StateReconciler.reconcileProvidersLive()` today (that's driven by
  `googleCloudEnabled` / `aiProvider` / key changes), so this is a plain
  `SettingsStore` write, identical to what the Settings screen already does.

## Testing

Unit tests on `PanelSession` (existing test target covers cache hit / paid
confirmation / auto-enhance already, per CLAUDE.md's testing priorities):

- Explicit `switchEngine` → successful `.result` → `onCommit` fires with the
  new engine/target.
- Explicit `switchTarget` → successful `.result` → `onCommit` fires.
- Cache hit after an explicit switch → `onCommit` still fires (synchronous
  path through `present()`).
- Auto-enhance's automatic engine switch → `onCommit` does **not** fire.
- `reconcile`'s invalid-engine fallback switch → `onCommit` does **not** fire.
- Paid confirmation declined (`cancelPaidSend`) → `onCommit` does **not**
  fire, and a subsequent unrelated switch still works correctly (i.e.
  `pendingPersist` was properly cleared, not left stale).
