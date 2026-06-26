# MacLingo — Privacy Note

**Last updated:** 2026-06-26 · Applies to MacLingo v1.

MacLingo is a menu-bar utility that translates the text you have selected. This
note states plainly **what is sent where**, and what is not. It mirrors the
guarantees enforced in code (spec §9) — it is not marketing copy.

## What MacLingo sends, and to whom

When you trigger a translation, the **selected text** is sent over HTTPS to a
single translation host — and only to a host on the **translation-data
allowlist**:

| Engine | Host | Key |
|---|---|---|
| Google Translate (free, default) | `translate.googleapis.com` | none |
| Google Cloud Translation v2 (optional) | `translation.googleapis.com` | your key, in the `X-Goog-Api-Key` header |
| OpenAI (optional, BYOK) | `api.openai.com` | your key, in the `Authorization` header |
| DeepSeek (optional, BYOK) | `api.deepseek.com` | your key, in the `Authorization` header |

Selected text is sent **only at translation time**, **only** to the engine you
are using, and is **never written to disk** (v1 keeps no history, cache, or
cookies on disk).

## What MacLingo never does

- **No analytics. No telemetry.** Availability of the free endpoint is monitored
  **on-device only** (success/rate-limit/error counts you can see in
  *Settings → Diagnostics*); none of it leaves your Mac.
- **Selected text is never sent to a control-plane host.** The remote-config host
  and the Sparkle update host are on a **separate** allowlist and can never
  receive your text. The two allowlists are never merged.
- **No redirect can exfiltrate text or keys.** Every HTTP redirect is inspected
  before it is followed: it may only stay on the *same* allowlist, and on any
  host change the request body and credentials (`Authorization`, `X-Goog-Api-Key`)
  are dropped. Cross- or off-allowlist redirects are rejected.
- **No remote resources are loaded** from captured or translated content. HTML and
  RTF are sanitized (images, links, scripts, embedded objects, external references
  stripped) before render, copy, or validation.

## Your API keys

BYOK keys (OpenAI, DeepSeek, Google Cloud) are stored **only in the macOS
Keychain** — never in preferences, plists, or logs, and they are redacted from all
diagnostics. Preferences store only a "key present" boolean per provider.

## The clipboard

To capture the selection MacLingo may synthesize a copy (⌘C). It first checks the
clipboard can be fully restored; if it holds content that cannot be safely put
back, MacLingo does **not** overwrite it and reads via the Accessibility API
instead. Restoration is ownership-guarded and abstains whenever ownership is
ambiguous. An "Accessibility only" capture mode never touches the clipboard at
all.

## Signed remote configuration

MacLingo fetches a small **signed** configuration from a control-plane host. This
config is strictly bounded: it may only **disable** the free Google endpoint (a
kill switch, e.g. if the unofficial endpoint must be turned off) or **switch among
pre-approved Google hosts**. It can **never** introduce a new host, so your text
can never be redirected to an unlisted destination. The config carries no personal
data and the fetch never includes your selected text.

## Updates

In-app updates use Sparkle over HTTPS. Both the update archive and the update feed
are EdDSA-signed and verified **before** anything is installed; only signed,
notarized builds are accepted. MacLingo never offers a downgrade.
