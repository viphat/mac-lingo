import CryptoKit
import XCTest

@testable import MacLingo

/// Coverage for the fail-closed remote-config lifecycle (spec §6.1): signature
/// verification, the endpoint allowlist, monotonic version, sticky disable, expiry,
/// clock-rollback safety, and the monotonic epoch floor (downgrade case).
final class RemoteConfigTests: XCTestCase {

    // MARK: - Signing helpers

    private func makeKey() -> (Curve25519.Signing.PrivateKey, String) {
        let key = Curve25519.Signing.PrivateKey()
        let b64 = key.publicKey.rawRepresentation.base64EncodedString()
        return (key, b64)
    }

    private func sign(
        _ payload: RemoteConfigPayload, with key: Curve25519.Signing.PrivateKey
    ) throws -> SignedRemoteConfig {
        let data = try payload.canonicalData()
        let signature = try key.signature(for: data)
        return SignedRemoteConfig(
            payload: data.base64EncodedString(),
            signature: signature.base64EncodedString())
    }

    private func payload(
        epoch: UInt32 = 1, version: UInt64 = 1,
        expiry: Date = Date(timeIntervalSince1970: 10_000),
        directive: RemoteConfigDirective = .disableFree, host: String? = nil
    ) -> RemoteConfigPayload {
        RemoteConfigPayload(
            epoch: epoch, version: version, expiry: expiry, directive: directive,
            endpointHost: host)
    }

    // MARK: - Verifier

    func testValidSignatureVerifies() throws {
        let (priv, pub) = makeKey()
        let verifier = RemoteConfigVerifier(base64Keys: [pub])
        let signed = try sign(payload(), with: priv)
        XCTAssertNotNil(verifier.verify(signed))
    }

    func testBackupKeyVerifies() throws {
        let (priv, _) = makeKey()
        let (_, otherPub) = makeKey()
        // Primary is a different key; backup is the signer → still accepted.
        let signerPub = priv.publicKey.rawRepresentation.base64EncodedString()
        let verifier = RemoteConfigVerifier(base64Keys: [otherPub, signerPub])
        let signed = try sign(payload(), with: priv)
        XCTAssertNotNil(verifier.verify(signed))
    }

    func testWrongKeyRejected() throws {
        let (priv, _) = makeKey()
        let (_, otherPub) = makeKey()
        let verifier = RemoteConfigVerifier(base64Keys: [otherPub])
        let signed = try sign(payload(), with: priv)
        XCTAssertNil(verifier.verify(signed))
    }

    func testTamperedPayloadRejected() throws {
        let (priv, pub) = makeKey()
        let verifier = RemoteConfigVerifier(base64Keys: [pub])
        var signed = try sign(payload(), with: priv)
        // Flip the payload to a different (unsigned) one.
        let tampered = try payload(version: 99).canonicalData()
        signed = SignedRemoteConfig(
            payload: tampered.base64EncodedString(), signature: signed.signature)
        XCTAssertNil(verifier.verify(signed))
    }

    func testEmptyKeysVerifyNothing() throws {
        let (priv, _) = makeKey()
        let verifier = RemoteConfigVerifier(base64Keys: ["", ""])
        let signed = try sign(payload(), with: priv)
        XCTAssertNil(verifier.verify(signed), "placeholder build must fail closed")
    }

    func testSelectEndpointOffAllowlistRejected() throws {
        let (priv, pub) = makeKey()
        let verifier = RemoteConfigVerifier(
            base64Keys: [pub], endpointAllowlist: ["translate.googleapis.com"])
        let signed = try sign(
            payload(directive: .selectEndpoint, host: "evil.example.com"), with: priv)
        XCTAssertNil(verifier.verify(signed))
    }

    func testSelectEndpointOnAllowlistVerifies() throws {
        let (priv, pub) = makeKey()
        let verifier = RemoteConfigVerifier(
            base64Keys: [pub], endpointAllowlist: ["translate.googleapis.com"])
        let signed = try sign(
            payload(directive: .selectEndpoint, host: "translate.googleapis.com"), with: priv)
        XCTAssertNotNil(verifier.verify(signed))
    }

    // MARK: - State machine: monotonic version

    func testHigherVersionAccepted() {
        let state = RemoteConfigState.initial(compiledEpoch: 1)
        let out = state.applying(payload(version: 1, directive: .disableFree))
        XCTAssertTrue(out.accepted)
        XCTAssertTrue(out.state.disabled)
    }

    func testEqualOrLowerVersionRejected() {
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state = state.applying(payload(version: 5, directive: .enableDefault)).state
        XCTAssertFalse(state.applying(payload(version: 5, directive: .disableFree)).accepted)
        XCTAssertFalse(state.applying(payload(version: 4, directive: .disableFree)).accepted)
    }

    // MARK: - State machine: sticky disable

    func testDisableIsStickyPastExpiry() {
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state =
            state.applying(
                payload(version: 1, expiry: Date(timeIntervalSince1970: 100), directive: .disableFree)
            ).state
        // Advance the clock well past the disable's own expiry.
        state = state.advanced(to: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(state.effectiveFreeState, .disabled, "disable must never expire")
    }

    func testOnlyHigherVersionReEnables() {
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state = state.applying(payload(version: 2, directive: .disableFree)).state
        XCTAssertEqual(state.effectiveFreeState, .disabled)
        // A higher-version enable re-enables.
        state = state.applying(payload(version: 3, directive: .enableDefault)).state
        XCTAssertEqual(state.effectiveFreeState, .compiledDefault)
    }

    // MARK: - State machine: endpoint expiry + clock rollback

    func testEndpointExpiresToCompiledDefault() {
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state =
            state.applying(
                payload(
                    version: 1, expiry: Date(timeIntervalSince1970: 500),
                    directive: .selectEndpoint, host: "translate.googleapis.com")
            ).state
        state = state.advanced(to: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(state.effectiveFreeState, .endpoint("translate.googleapis.com"))
        state = state.advanced(to: Date(timeIntervalSince1970: 600))
        XCTAssertEqual(state.effectiveFreeState, .compiledDefault)
    }

    func testClockRollbackCannotUnExpireEndpoint() {
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state =
            state.applying(
                payload(
                    version: 1, expiry: Date(timeIntervalSince1970: 500),
                    directive: .selectEndpoint, host: "translate.googleapis.com")
            ).state
        // Advance past expiry, then roll the clock backwards.
        state = state.advanced(to: Date(timeIntervalSince1970: 600))
        state = state.advanced(to: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            state.effectiveFreeState, .compiledDefault,
            "rollback must not un-expire (high-water mark governs)")
    }

    func testClockRollbackCannotReEnableDisable() {
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state = state.applying(payload(version: 1, directive: .disableFree)).state
        state = state.advanced(to: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(state.effectiveFreeState, .disabled)
    }

    // MARK: - State machine: epoch floor / downgrade

    func testBelowFloorConfigRejected() {
        var state = RemoteConfigState.initial(compiledEpoch: 2)
        // Floor is 2; an epoch-1 config is below the floor → rejected.
        let out = state.applying(payload(epoch: 1, version: 100, directive: .disableFree))
        XCTAssertFalse(out.accepted)
        state = out.state
        XCTAssertEqual(state.effectiveFreeState, .compiledDefault)
    }

    func testEpochBumpDiscardsPriorStickyDisable() {
        // Epoch 1: a high-version sticky disable is accepted and persisted.
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state = state.applying(payload(epoch: 1, version: 9_999, directive: .disableFree)).state
        XCTAssertEqual(state.effectiveFreeState, .disabled)

        // A signed release bumps the compiled epoch to 2: normalization discards the
        // prior-epoch sticky disable and raises the floor.
        let normalized = state.normalized(forCompiledEpoch: 2)
        XCTAssertEqual(normalized.epochFloor, 2)
        XCTAssertFalse(normalized.disabled)
        XCTAssertEqual(normalized.highestVersion, 0, "version space resets per epoch")
        XCTAssertEqual(normalized.effectiveFreeState, .compiledDefault)
    }

    func testManualDowngradeCannotResurrectDiscardedDisable() {
        // Floor was raised to 2 (e.g. after an epoch bump). The persisted floor
        // travels with the install.
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state.epochFloor = 2
        state.directiveEpoch = 2
        state.highestVersion = 0

        // User manually reinstalls the OLD binary (compiled epoch 1). Normalization
        // must NOT lower the floor.
        let normalized = state.normalized(forCompiledEpoch: 1)
        XCTAssertEqual(normalized.epochFloor, 2, "floor only ever rises")

        // The discarded epoch-1 sticky disable cannot be re-applied — below floor.
        let out = normalized.applying(payload(epoch: 1, version: 9_999, directive: .disableFree))
        XCTAssertFalse(out.accepted)
        XCTAssertEqual(out.state.effectiveFreeState, .compiledDefault)
    }

    func testHigherEpochConfigResetsVersionSpace() {
        var state = RemoteConfigState.initial(compiledEpoch: 1)
        state = state.applying(payload(epoch: 1, version: 50, directive: .disableFree)).state
        // A higher-epoch config with a *low* version is still accepted (new version
        // space) and supersedes the old-epoch disable.
        let out = state.applying(payload(epoch: 2, version: 1, directive: .enableDefault))
        XCTAssertTrue(out.accepted)
        XCTAssertEqual(out.state.epochFloor, 2)
        XCTAssertEqual(out.state.effectiveFreeState, .compiledDefault)
    }

    // MARK: - Store round-trip

    @MainActor
    func testStateStoreRoundTrip() {
        let suiteName = "com.sharewis.maclingo.tests.remoteconfig"
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)
        let store = RemoteConfigStore(defaults: suite, key: "rc")
        XCTAssertNil(store.load())

        var state = RemoteConfigState.initial(compiledEpoch: 3)
        state.disabled = true
        store.save(state)
        XCTAssertEqual(store.load(), state)
        suite.removePersistentDomain(forName: suiteName)
    }
}
