import XCTest

@testable import MacLingo

/// Phase 0 sanity coverage for the embedded trust material (spec §6.1, §9).
final class TrustMaterialTests: XCTestCase {

    /// §9 invariant: the translation-data and control-plane allowlists are never
    /// merged. No host may appear on both — selected text must never be able to
    /// reach a control-plane host, and a control-plane host can never be a
    /// translation target.
    func testAllowlistsAreDisjoint() {
        let overlap = TrustMaterial.translationDataHosts
            .intersection(TrustMaterial.controlPlaneHosts)
        XCTAssertTrue(overlap.isEmpty, "allowlists overlap on: \(overlap)")
    }

    /// §6.1: the compiled-default Google Free endpoint must resolve to a host on
    /// the translation-data allowlist and on the endpoint allowlist.
    func testDefaultFreeEndpointIsAllowlisted() throws {
        let url = try XCTUnwrap(URL(string: TrustMaterial.defaultGoogleFreeEndpoint))
        let host = try XCTUnwrap(url.host())
        XCTAssertTrue(TrustMaterial.translationDataHosts.contains(host))
        XCTAssertTrue(TrustMaterial.googleFreeEndpointAllowlist.contains(host))
    }

    /// §6.1: every host the remote config may select among must already be on the
    /// translation-data allowlist (config can never introduce a new host).
    func testEndpointAllowlistIsSubsetOfTranslationData() {
        XCTAssertTrue(
            TrustMaterial.googleFreeEndpointAllowlist
                .isSubset(of: TrustMaterial.translationDataHosts))
    }
}
