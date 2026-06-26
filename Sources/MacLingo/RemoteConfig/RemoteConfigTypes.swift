import Foundation

/// What a signed remote config may instruct (spec §6.1). Strictly bounded: a config
/// can only *disable* the free provider (kill switch) or *select an endpoint from
/// the compiled allowlist* — it can **never** introduce a new host.
enum RemoteConfigDirective: String, Codable, Equatable, Sendable {
    /// Kill switch — **sticky**: stays in effect past expiry / fetch failures /
    /// clock changes; only a strictly higher-version valid config re-enables.
    case disableFree
    /// Select an allowlisted Google host. **Expires** to the compiled default.
    case selectEndpoint
    /// Explicitly (re-)enable the compiled default. **Expires** (a no-op once past
    /// expiry — it already maps to the compiled default).
    case enableDefault
}

/// The signed payload of a remote config (spec §6.1). The exact bytes that were
/// signed are produced by ``canonicalData()`` so signing and verification agree.
struct RemoteConfigPayload: Codable, Equatable, Sendable {
    /// Config epoch — scopes the config. An app release that raises the epoch
    /// discards all prior-epoch configs (recovery from a lost/compromised key).
    let epoch: UInt32
    /// Monotonically increasing version (anti-rollback/replay). Governs trust.
    let version: UInt64
    /// Wall-clock expiry backstop (seconds since 1970 when encoded).
    let expiry: Date
    let directive: RemoteConfigDirective
    /// The chosen host for `.selectEndpoint`; must be on the compiled allowlist.
    let endpointHost: String?

    /// Deterministic JSON encoding (sorted keys, seconds-since-1970 dates) — the
    /// canonical bytes the signature covers.
    func canonicalData() throws -> Data {
        try Self.canonicalEncoder.encode(self)
    }

    /// Decode a payload from canonical bytes.
    static func decode(_ data: Data) throws -> RemoteConfigPayload {
        try canonicalDecoder.decode(RemoteConfigPayload.self, from: data)
    }

    static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let canonicalDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// A remote config plus its detached Ed25519 signature over ``RemoteConfigPayload``
/// canonical bytes (spec §6.1). Transported as base64 fields in the fetched JSON.
struct SignedRemoteConfig: Codable, Equatable, Sendable {
    /// Base64 of the canonical payload bytes (signed verbatim).
    let payload: String
    /// Base64 of the Ed25519 signature over the decoded payload bytes.
    let signature: String

    var payloadData: Data? { Data(base64Encoded: payload) }
    var signatureData: Data? { Data(base64Encoded: signature) }
}

/// The effective Google Free state derived from the persisted config state
/// (spec §6.1). Drives the service registry endpoint + availability.
enum EffectiveFreeState: Equatable, Sendable {
    /// Sticky kill switch is active — Free is unavailable (fallback chain applies).
    case disabled
    /// A non-expired select-endpoint directive picks this allowlisted host.
    case endpoint(String)
    /// No active directive (or it expired) — use the compiled default endpoint.
    case compiledDefault
}
