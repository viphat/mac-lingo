import OSLog
import Sparkle

/// Thin wrapper over Sparkle's standard updater (spec §10). The trust boundary —
/// **EdDSA-signed items + a signed feed** (`SURequireSignedFeed`), signatures
/// **verified before extraction**, forward-versions-only, current-version-on-failure
/// — is configured declaratively in `Info.plist` (`SUFeedURL`, `SUPublicEDKey`,
/// `SURequireSignedFeed`); Sparkle enforces it. This type just exposes a
/// "Check for Updates…" entry point and keeps the updater alive.
///
/// Created lazily on first use so the updater (and its background feed checks)
/// never start during unit tests that don't drive the menu.
@MainActor
final class UpdateController {
    private let controller: SPUStandardUpdaterController
    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "Updates")

    init() {
        // `startingUpdater: true` begins scheduled checks against the signed appcast
        // declared in Info.plist. The appcast host is a control-plane host (§9) and
        // never receives selected text.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// User-initiated update check (menu item).
    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else {
            log.notice("update check unavailable (an update is already in progress)")
            return
        }
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
}
