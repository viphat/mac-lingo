import CryptoKit
import Foundation

/// Verifies a ``SignedRemoteConfig`` against the embedded config public keys
/// (spec §6.1). Two keys are tried — **primary and backup** — for dual-key
/// rotation; either valid signature is accepted. Separate from the Sparkle update
/// key (§10). A verified payload also passes the **endpoint allowlist** check so a
/// `selectEndpoint` can never name a host outside the compiled set.
struct RemoteConfigVerifier: Sendable {
    private let publicKeys: [Curve25519.Signing.PublicKey]
    private let endpointAllowlist: Set<String>

    /// - Parameters:
    ///   - base64Keys: Ed25519 public keys, base64-encoded raw representation.
    ///     Empty / unparsable entries are ignored (a build with placeholder keys
    ///     simply verifies nothing — fail-closed).
    ///   - endpointAllowlist: hosts a `selectEndpoint` directive may name.
    init(
        base64Keys: [String] = [
            TrustMaterial.configPublicKeyPrimary, TrustMaterial.configPublicKeyBackup,
        ],
        endpointAllowlist: Set<String> = TrustMaterial.googleFreeEndpointAllowlist
    ) {
        self.publicKeys = base64Keys.compactMap { encoded in
            guard let raw = Data(base64Encoded: encoded), !raw.isEmpty else { return nil }
            return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }
        self.endpointAllowlist = endpointAllowlist
    }

    /// Returns the verified payload, or `nil` if the signature is invalid, the
    /// payload is malformed, or a `selectEndpoint` names a non-allowlisted host.
    /// **Fail-closed**: any uncertainty yields `nil`.
    func verify(_ signed: SignedRemoteConfig) -> RemoteConfigPayload? {
        guard !publicKeys.isEmpty,
            let payloadData = signed.payloadData,
            let signatureData = signed.signatureData
        else { return nil }

        let signatureValid = publicKeys.contains { key in
            key.isValidSignature(signatureData, for: payloadData)
        }
        guard signatureValid else { return nil }

        guard let payload = try? RemoteConfigPayload.decode(payloadData) else { return nil }

        // A select-endpoint host must be a member of the compiled allowlist
        // (spec §6.1) — never introduce a new host.
        if payload.directive == .selectEndpoint {
            guard let host = payload.endpointHost, endpointAllowlist.contains(host) else {
                return nil
            }
        }
        return payload
    }
}
