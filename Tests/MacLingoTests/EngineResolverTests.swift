import XCTest

@testable import MacLingo

final class EngineResolverTests: XCTestCase {

    func testPreferredFreeUsesFreeWhenAvailable() {
        let available = ConfiguredEngines(googleFreeAvailable: true)
        XCTAssertEqual(EngineResolver.resolve(preferred: .googleFree, available: available), .googleFree)
    }

    func testFreeBlockedFallsBackToAIThenCloud() {
        // Free blocked, AI configured -> AI (spec §6.1 degraded chain).
        var available = ConfiguredEngines(googleFreeAvailable: false, aiProvider: .openAI)
        XCTAssertEqual(EngineResolver.resolve(preferred: .googleFree, available: available), .openAI)

        // Free blocked, no AI, Cloud configured -> Cloud.
        available = ConfiguredEngines(googleFreeAvailable: false, googleCloudConfigured: true, aiProvider: nil)
        XCTAssertEqual(EngineResolver.resolve(preferred: .googleFree, available: available), .googleCloud)
    }

    func testMisconfiguredCloudDefaultFallsBackToFree() {
        let available = ConfiguredEngines(googleFreeAvailable: true, googleCloudConfigured: false)
        XCTAssertEqual(EngineResolver.resolve(preferred: .googleCloud, available: available), .googleFree)
    }

    func testMisconfiguredAIDefaultFallsBackToFree() {
        let available = ConfiguredEngines(googleFreeAvailable: true, aiProvider: nil)
        XCTAssertEqual(EngineResolver.resolve(preferred: .aiProvider, available: available), .googleFree)
    }

    func testAIPreferredUsesConfiguredProvider() {
        let available = ConfiguredEngines(aiProvider: .deepSeek)
        XCTAssertEqual(EngineResolver.resolve(preferred: .aiProvider, available: available), .deepSeek)
    }

    func testIsAvailable() {
        let available = ConfiguredEngines(googleFreeAvailable: true, googleCloudConfigured: false, aiProvider: nil)
        XCTAssertTrue(EngineResolver.isAvailable(.googleFree, available: available))
        XCTAssertFalse(EngineResolver.isAvailable(.googleCloud, available: available))
        XCTAssertFalse(EngineResolver.isAvailable(.aiProvider, available: available))
    }

    func testDefaultEngineMapping() {
        XCTAssertEqual(EngineResolver.defaultEngine(for: .googleFree), .googleFree)
        XCTAssertEqual(EngineResolver.defaultEngine(for: .googleCloud), .googleCloud)
        XCTAssertEqual(EngineResolver.defaultEngine(for: .openAI), .aiProvider)
        XCTAssertEqual(EngineResolver.defaultEngine(for: .deepSeek), .aiProvider)
    }

    // MARK: - Concrete-engine validity (spec §5.5, session override)

    func testIsEngineValidDistinguishesConcreteAIProviders() {
        let available = ConfiguredEngines(aiProvider: .deepSeek)
        XCTAssertTrue(EngineResolver.isEngineValid(.deepSeek, available: available))
        XCTAssertFalse(
            EngineResolver.isEngineValid(.openAI, available: available),
            "a different concrete AI provider than the one configured is invalid, unlike"
                + " the collapsed DefaultEngine.aiProvider category")
    }

    func testIsEngineValidForFreeAndCloud() {
        let available = ConfiguredEngines(googleFreeAvailable: false, googleCloudConfigured: true)
        XCTAssertFalse(EngineResolver.isEngineValid(.googleFree, available: available))
        XCTAssertTrue(EngineResolver.isEngineValid(.googleCloud, available: available))
    }

    // MARK: - Session-override resolution (spec §5.5 "remember last choice")

    func testResolveWithValidPreferredEngineUsesItExactly() {
        // Two AI providers can't be configured at once today, but the resolution
        // must still prefer the concrete override over the collapsed fallback.
        let available = ConfiguredEngines(aiProvider: .deepSeek)
        XCTAssertEqual(
            EngineResolver.resolve(preferredEngine: .deepSeek, fallback: .googleFree, available: available),
            .deepSeek)
    }

    func testResolveWithStalePreferredEngineFallsBackWithoutSubstitutingAnotherProvider() {
        // The override pointed at OpenAI, but Settings now has DeepSeek configured.
        // A stale override must fall back to the resolved *fallback*, never
        // silently swap in whichever AI provider happens to be configured.
        let available = ConfiguredEngines(googleFreeAvailable: true, aiProvider: .deepSeek)
        XCTAssertEqual(
            EngineResolver.resolve(preferredEngine: .openAI, fallback: .googleFree, available: available),
            .googleFree)
    }

    func testResolveWithNilPreferredEngineUsesFallback() {
        let available = ConfiguredEngines(googleFreeAvailable: true, aiProvider: .openAI)
        XCTAssertEqual(
            EngineResolver.resolve(preferredEngine: nil, fallback: .aiProvider, available: available),
            .openAI)
    }
}
