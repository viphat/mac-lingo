import XCTest

@testable import MacLingo

@MainActor
final class StateReconcilerTests: XCTestCase {

    private func reconciler(
        store: SettingsStore,
        keychain: MockKeychain = MockKeychain(),
        hotkey: MockHotkey = MockHotkey(),
        loginItem: MockLoginItem
    ) -> StateReconciler {
        StateReconciler(settings: store, keychain: keychain, hotkey: hotkey, loginItem: loginItem)
    }

    func testHotkeyReregisteredAtLaunch() {
        let store = makeIsolatedStore().store
        let hotkey = MockHotkey()
        let report = reconciler(store: store, hotkey: hotkey, loginItem: MockLoginItem(enabled: false))
            .reconcileAtLaunch()
        XCTAssertEqual(hotkey.reregisterCount, 1)
        XCTAssertTrue(report.hotkeyReregistered)
    }

    func testHasKeyFlagsReconciledFromKeychain() {
        let store = makeIsolatedStore().store
        // Keychain has the AI key but the persisted flags say otherwise.
        store.hasKeyProvider = false
        store.hasKeyCloud = true
        let keychain = MockKeychain(present: [.aiProvider])  // cloud absent

        let report = reconciler(store: store, keychain: keychain, loginItem: MockLoginItem(enabled: false))
            .reconcileAtLaunch()

        XCTAssertTrue(store.hasKeyProvider)
        XCTAssertFalse(store.hasKeyCloud)
        XCTAssertTrue(report.hasKeyProviderCorrected)
        XCTAssertTrue(report.hasKeyCloudCorrected)
    }

    func testLoginItemRepairedTowardDesired() {
        let store = makeIsolatedStore().store
        store.launchAtLogin = true  // desired on
        let loginItem = MockLoginItem(enabled: false)  // system off

        let report = reconciler(store: store, loginItem: loginItem).reconcileAtLaunch()

        XCTAssertEqual(loginItem.setCalls, [true])
        XCTAssertTrue(loginItem.isEnabled())
        XCTAssertTrue(report.loginItemRepaired)
        XCTAssertTrue(store.launchAtLogin)
    }

    func testLoginItemFailureClearsDesiredToReality() {
        let store = makeIsolatedStore().store
        store.launchAtLogin = true  // desired on
        let loginItem = MockLoginItem(enabled: false)
        loginItem.setError = TestError.forced  // system refuses

        let report = reconciler(store: store, loginItem: loginItem).reconcileAtLaunch()

        // Desired reset to the actual system state; no optimistic persistence.
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertNotNil(report.loginItemError)
        XCTAssertFalse(report.loginItemRepaired)
    }

    func testStaleDefaultEngineFallsBack() {
        let store = makeIsolatedStore().store
        // Cloud selected as default but never configured.
        store.defaultEngine = .googleCloud
        store.googleCloudEnabled = false
        store.hasKeyCloud = false

        let report = reconciler(store: store, loginItem: MockLoginItem(enabled: false)).reconcileAtLaunch()

        XCTAssertEqual(store.defaultEngine, .googleFree)
        XCTAssertEqual(report.defaultEngineCorrectedFrom, .googleCloud)
        XCTAssertEqual(report.defaultEngineCorrectedTo, .googleFree)
    }

    func testConfiguredDefaultEngineUntouched() {
        let store = makeIsolatedStore().store
        // AI default with a present key (reconciled from Keychain) stays put.
        store.defaultEngine = .aiProvider
        store.aiProvider = .openAI
        let keychain = MockKeychain(present: [.aiProvider])

        let report = reconciler(store: store, keychain: keychain, loginItem: MockLoginItem(enabled: false))
            .reconcileAtLaunch()

        XCTAssertEqual(store.defaultEngine, .aiProvider)
        XCTAssertNil(report.defaultEngineCorrectedFrom)
    }
}
