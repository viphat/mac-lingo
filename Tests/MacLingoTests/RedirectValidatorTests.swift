import XCTest

@testable import MacLingo

/// Coverage for the HTTP-redirect policy and dual-allowlist classification
/// (spec §9, P0). These are the pure decisions behind `HardenedSessionDelegate`.
final class RedirectValidatorTests: XCTestCase {

    // MARK: - Host classification

    func testHostClassification() {
        XCTAssertEqual(
            TrustMaterial.allowlist(for: "translate.googleapis.com"), .translationData)
        XCTAssertEqual(TrustMaterial.allowlist(for: "api.openai.com"), .translationData)
        XCTAssertEqual(
            TrustMaterial.allowlist(for: TrustMaterial.remoteConfigHost), .controlPlane)
        XCTAssertEqual(
            TrustMaterial.allowlist(for: TrustMaterial.sparkleAppcastHost), .controlPlane)
        XCTAssertEqual(TrustMaterial.allowlist(for: "evil.example.com"), .none)
    }

    // MARK: - Redirect decisions

    func testSameHostFollows() {
        XCTAssertEqual(
            RedirectValidator.decide(
                originalHost: "api.openai.com", newHost: "api.openai.com"),
            .follow)
    }

    func testSameHostCaseInsensitiveFollows() {
        XCTAssertEqual(
            RedirectValidator.decide(
                originalHost: "api.openai.com", newHost: "API.OpenAI.com"),
            .follow)
    }

    func testSameAllowlistDifferentHostStrips() {
        // Both on the translation-data allowlist but different hosts → follow but
        // strip body + credentials.
        XCTAssertEqual(
            RedirectValidator.decide(
                originalHost: "api.openai.com", newHost: "translate.googleapis.com"),
            .followStripped)
    }

    func testCrossAllowlistRejected() {
        // translation-data → control-plane must be rejected (and vice versa).
        XCTAssertEqual(
            RedirectValidator.decide(
                originalHost: "api.openai.com", newHost: TrustMaterial.remoteConfigHost),
            .reject)
        XCTAssertEqual(
            RedirectValidator.decide(
                originalHost: TrustMaterial.sparkleAppcastHost, newHost: "api.openai.com"),
            .reject)
    }

    func testOffAllowlistRejected() {
        XCTAssertEqual(
            RedirectValidator.decide(
                originalHost: "api.openai.com", newHost: "evil.example.com"),
            .reject)
    }

    func testOriginalOffAllowlistRejected() {
        // A request that somehow originated off-allowlist can never follow anywhere.
        XCTAssertEqual(
            RedirectValidator.decide(
                originalHost: "evil.example.com", newHost: "api.openai.com"),
            .reject)
    }

    func testNilHostsRejected() {
        XCTAssertEqual(RedirectValidator.decide(originalHost: nil, newHost: "api.openai.com"), .reject)
        XCTAssertEqual(RedirectValidator.decide(originalHost: "api.openai.com", newHost: nil), .reject)
    }
}
