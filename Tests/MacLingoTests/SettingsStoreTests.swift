import XCTest

@testable import MacLingo

@MainActor
final class SettingsStoreTests: XCTestCase {

    func testDefaultsMatchSpec() {
        let store = makeIsolatedStore().store
        XCTAssertEqual(store.targetLanguage, .en)
        XCTAssertEqual(store.defaultEngine, .googleFree)
        XCTAssertEqual(store.captureMethod, .dual)
        XCTAssertEqual(store.appearance, .system)
        XCTAssertEqual(store.paidConfirmThreshold, 4_000)
        XCTAssertEqual(store.autoSpendLimit, 0)
        XCTAssertFalse(store.autoEnhance)
        XCTAssertFalse(store.googleCloudEnabled)
        XCTAssertNil(store.aiProvider)
        XCTAssertNil(store.lastUsedTargetLanguage)
        XCTAssertNil(store.lastUsedEngine)
    }

    // MARK: - Last-used session override (spec §5.5 "remember last choice")

    func testLastUsedFieldsRoundTripAndClearToNil() {
        let env = makeIsolatedStore()
        env.store.lastUsedTargetLanguage = .vi
        env.store.lastUsedEngine = .openAI

        let reopened = SettingsStore(defaults: env.suite)
        XCTAssertEqual(reopened.lastUsedTargetLanguage, .vi)
        XCTAssertEqual(reopened.lastUsedEngine, .openAI)

        reopened.lastUsedTargetLanguage = nil
        reopened.lastUsedEngine = nil
        XCTAssertNil(reopened.lastUsedTargetLanguage)
        XCTAssertNil(reopened.lastUsedEngine)
        // Clearing removes the underlying key rather than storing a sentinel.
        XCTAssertNil(env.suite.object(forKey: "lastUsedTargetLanguage"))
        XCTAssertNil(env.suite.object(forKey: "lastUsedEngine"))
    }

    func testLastUsedFieldsDoNotAffectSettingsDefault() {
        let store = makeIsolatedStore().store
        store.lastUsedTargetLanguage = .vi
        store.lastUsedEngine = .openAI
        // The Settings-screen default is untouched by a session override.
        XCTAssertEqual(store.targetLanguage, .en)
        XCTAssertEqual(store.defaultEngine, .googleFree)
    }

    func testRoundTripPersistsAcrossInstances() {
        let env = makeIsolatedStore()
        env.store.targetLanguage = .zhHant
        env.store.defaultEngine = .aiProvider
        env.store.captureMethod = .axOnly
        env.store.aiProvider = .deepSeek

        let reopened = SettingsStore(defaults: env.suite)
        XCTAssertEqual(reopened.targetLanguage, .zhHant)
        XCTAssertEqual(reopened.defaultEngine, .aiProvider)
        XCTAssertEqual(reopened.captureMethod, .axOnly)
        XCTAssertEqual(reopened.aiProvider, .deepSeek)
    }

    func testAIModelFallsBackToProviderDefault() {
        let store = makeIsolatedStore().store
        store.aiProvider = .openAI
        XCTAssertEqual(store.aiModel, "gpt-5.4-mini")
        store.aiModel = "gpt-5.5"
        XCTAssertEqual(store.aiModel, "gpt-5.5")
    }

    // MARK: - Atomic write (spec §5.5)

    func testApplyAtomicPersistsOnSuccess() throws {
        let store = makeIsolatedStore().store
        try store.applyAtomic(
            true,
            system: { _ in /* succeeds */ },
            persist: { store.launchAtLogin = $0 })
        XCTAssertTrue(store.launchAtLogin)
    }

    func testApplyAtomicDoesNotPersistOnSystemFailure() {
        let store = makeIsolatedStore().store
        store.launchAtLogin = false
        XCTAssertThrowsError(
            try store.applyAtomic(
                true,
                system: { _ in throw TestError.forced },
                persist: { store.launchAtLogin = $0 }))
        // The persisted value must be untouched — no optimistic persistence.
        XCTAssertFalse(store.launchAtLogin)
    }
}
