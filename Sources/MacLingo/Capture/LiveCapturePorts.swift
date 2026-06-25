import AppKit
import ApplicationServices
import CoreGraphics

/// Live `AccessibilityReading`: reads `kAXSelectedTextAttribute` from the focused
/// element (spec §4.3). Stateless, so it stays `Sendable` even though it touches
/// the (non-`Sendable`) AX APIs — the actor serializes the calls.
struct LiveAccessibilityReader: AccessibilityReading {
    func selectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        let focusedErr = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard
            focusedErr == .success, let focusedRaw = focusedRef,
            CFGetTypeID(focusedRaw) == AXUIElementGetTypeID()
        else { return nil }
        let focused = unsafeDowncast(focusedRaw, to: AXUIElement.self)

        var selectedRef: AnyObject?
        let selectedErr = AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, &selectedRef)
        guard selectedErr == .success, let text = selectedRef as? String, !text.isEmpty else {
            return nil
        }
        return text
    }
}

/// Live `KeystrokeSynthesizing`: posts ⌘C via `CGEvent` (spec §4.3 step 3).
struct LiveKeystrokeSynthesizer: KeystrokeSynthesizing {
    /// ANSI virtual key code for the `C` key.
    private static let keyC: CGKeyCode = 0x08

    func synthesizeCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: Self.keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: Self.keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Live `Pasteboarding` over `NSPasteboard.general`. Stateless value type (reads
/// `.general` fresh each call), so it is `Sendable`; the capturer actor is the
/// single, serialized caller (spec §4.3).
struct LivePasteboard: Pasteboarding {
    var changeCount: Int { NSPasteboard.general.changeCount }

    func types() -> [String] {
        (NSPasteboard.general.pasteboardItems ?? [])
            .flatMap { $0.types.map(\.rawValue) }
    }

    func snapshot() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = (pasteboard.pasteboardItems ?? []).map { item -> PasteboardItemSnapshot in
            var contents: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type.rawValue] = data
                }
            }
            return PasteboardItemSnapshot(contents: contents)
        }
        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    func readRichest() -> CapturedSelection? {
        let pasteboard = NSPasteboard.general
        let plain = pasteboard.string(forType: .string) ?? ""
        let rich: CapturedRich?
        if let rtf = pasteboard.data(forType: .rtf) {
            rich = CapturedRich(kind: .rtf, data: rtf)
        } else if let html = pasteboard.data(forType: .html) {
            rich = CapturedRich(kind: .html, data: html)
        } else {
            rich = nil
        }
        let result = CapturedSelection(plainText: plain, rich: rich)
        return result.isEmpty ? nil : result
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in snap.contents {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
