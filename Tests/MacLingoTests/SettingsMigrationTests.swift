import XCTest

@testable import MacLingo

@MainActor
final class SettingsMigrationTests: XCTestCase {

    func testFreshInstallStampsCurrentVersion() {
        let env = makeIsolatedStore()
        XCTAssertEqual(env.store.migrateIfNeeded(), .upToDate)
        XCTAssertEqual(env.suite.integer(forKey: "settingsSchemaVersion"), SettingsStore.currentSchemaVersion)
        XCTAssertFalse(env.store.didResetDueToCorruption)
    }

    func testCurrentVersionIsUpToDate() {
        let env = makeIsolatedStore()
        env.suite.set(SettingsStore.currentSchemaVersion, forKey: "settingsSchemaVersion")
        let store = SettingsStore(defaults: env.suite, backupDirectory: env.backupDir)
        XCTAssertEqual(store.migrateIfNeeded(), .upToDate)
        XCTAssertFalse(store.didResetDueToCorruption)
    }

    func testNewerVersionIsToleratedNotDowngraded() {
        let env = makeIsolatedStore()
        // A future build wrote a higher version + an unknown key.
        env.suite.set(99, forKey: "settingsSchemaVersion")
        env.suite.set("someFutureValue", forKey: "unknownFutureKey")
        let store = SettingsStore(defaults: env.suite, backupDirectory: env.backupDir)
        XCTAssertEqual(store.migrateIfNeeded(), .upToDate)
        XCTAssertFalse(store.didResetDueToCorruption)
        XCTAssertEqual(env.suite.string(forKey: "unknownFutureKey"), "someFutureValue")
    }

    func testCorruptVersionTypeTriggersFailSafeReset() throws {
        let env = makeIsolatedStore()
        env.suite.set("not-an-int", forKey: "settingsSchemaVersion")
        env.suite.set("garbage", forKey: "targetLanguage")
        let store = SettingsStore(defaults: env.suite, backupDirectory: env.backupDir)

        let outcome = store.migrateIfNeeded()
        guard case .resetToDefaults(let backupURL) = outcome else {
            return XCTFail("expected resetToDefaults, got \(outcome)")
        }
        XCTAssertTrue(store.didResetDueToCorruption)
        // Bad keys cleared; version re-stamped; backup written.
        XCTAssertNil(env.suite.object(forKey: "targetLanguage"))
        XCTAssertEqual(env.suite.integer(forKey: "settingsSchemaVersion"), SettingsStore.currentSchemaVersion)
        let url = try XCTUnwrap(backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: env.backupDir)
    }

    func testUndecodableEnumValueTriggersReset() {
        let env = makeIsolatedStore()
        env.suite.set(SettingsStore.currentSchemaVersion, forKey: "settingsSchemaVersion")
        env.suite.set("notALanguage", forKey: "targetLanguage")
        let store = SettingsStore(defaults: env.suite, backupDirectory: env.backupDir)

        guard case .resetToDefaults = store.migrateIfNeeded() else {
            return XCTFail("expected resetToDefaults for undecodable enum")
        }
        XCTAssertTrue(store.didResetDueToCorruption)
        // After reset, accessors return safe defaults.
        XCTAssertEqual(store.targetLanguage, .en)
    }

    func testUnregisteredOlderVersionResetsFailSafe() {
        let env = makeIsolatedStore()
        // No migration registered for v0 -> reset rather than silently skip.
        env.suite.set(0, forKey: "settingsSchemaVersion")
        let store = SettingsStore(defaults: env.suite, backupDirectory: env.backupDir)
        guard case .resetToDefaults = store.migrateIfNeeded() else {
            return XCTFail("expected resetToDefaults for unmigratable version")
        }
        XCTAssertTrue(store.didResetDueToCorruption)
    }
}
