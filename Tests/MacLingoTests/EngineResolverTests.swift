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
}
