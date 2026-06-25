# MacLingo

A native macOS menu-bar utility that translates the **selected text** anywhere on
the system via a global hotkey, showing the result in a floating panel near the
cursor.

- **Default engine:** Google Translate (free, no key).
- **Optional engines:** DeepSeek / OpenAI (BYOK "enhance"), Google Cloud v2 (BYOK).
- **Targets:** English, Vietnamese, Chinese (Simplified), Chinese (Traditional);
  source language auto-detected.
- **Style:** menu-bar agent (`LSUIElement`, no Dock icon), Developer ID notarized
  `.dmg`, in-app updates via Sparkle. **Not** Mac App Store.

The authoritative design is [`docs/MacLingo-spec.md`](docs/MacLingo-spec.md); the
build sequence is [`docs/MacLingo-plan.md`](docs/MacLingo-plan.md). Contributor
guidance and invariants are in [`CLAUDE.md`](CLAUDE.md).

---

## Requirements

- **macOS 15.0** (Sequoia) or newer.
- **Full Xcode** (not just Command Line Tools) — `xcodebuild` is required to
  build, sign, and notarize. Install from the App Store, then:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **Swift 6** with strict concurrency.
- Tooling: [XcodeGen](https://github.com/yonyz/XcodeGen) (project generation),
  [SwiftLint](https://github.com/realm/SwiftLint), and
  [swift-format](https://github.com/swiftlang/swift-format):
  ```bash
  brew install xcodegen swiftlint swift-format
  ```

## Project layout

The Xcode project is **generated** from [`project.yml`](project.yml) via XcodeGen
(the `.xcodeproj` is git-ignored — `project.yml` is the source of truth):

```bash
xcodegen generate
```

Dependencies (Swift Package Manager): `KeyboardShortcuts`, `Defaults`, `Sparkle`.
Keychain access uses the native Security framework (no third-party wrapper).

## Build / run / test

```bash
xcodegen generate                                              # regenerate the project
xcodebuild -scheme MacLingo -configuration Debug build         # build
xcodebuild -scheme MacLingo -destination 'platform=macOS' test # test
swiftlint                                                      # lint  (before every commit)
swift-format lint --recursive Sources                          # format (before every commit)
```

Accessibility permission is required at runtime — grant it to the build in
*System Settings → Privacy & Security → Accessibility* (re-grant after a
significant rebuild if macOS drops the entitlement).

## Security note

Never commit signing identities, API keys, the Sparkle EdDSA private key, or the
remote-config private keys. See the invariants in [`CLAUDE.md`](CLAUDE.md) — this
app touches the clipboard, synthesizes keystrokes, reads the Accessibility API,
and sends user-selected text over the network; correctness and safety there are
the whole game.
