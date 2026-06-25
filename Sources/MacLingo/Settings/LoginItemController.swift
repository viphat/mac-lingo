import OSLog
import ServiceManagement

/// `SMAppService`-backed login item (spec §5.5b). Registration is applied as the
/// system op in `applyAtomic`; the persisted desired state is written only after
/// it succeeds.
@MainActor
final class LoginItemController: LoginItemControlling {
    private let log = Logger(subsystem: "com.sharewis.maclingo", category: "LoginItem")

    func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        log.notice("login item set enabled=\(enabled, privacy: .public)")
    }
}
