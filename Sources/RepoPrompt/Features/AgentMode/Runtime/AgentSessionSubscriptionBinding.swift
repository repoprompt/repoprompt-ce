import Foundation
import RepoPromptSettingsCore

/// Saved account provenance, not authorization. Managed records cannot contact any provider
/// until a provider-specific, verified admission path is installed.
enum AgentSessionSubscriptionBinding: Codable, Equatable {
    case legacy
    case pinned(profileID: SubscriptionProfileID, identityEpoch: UUID)
    case detached
    case unreadable

    static let version = 1

    var blocksProviderOperations: Bool {
        self != .legacy
    }

    static let notRunnableMessage = "Managed subscription sessions are read-only until their account can be verified."

    private enum Kind: String, Codable {
        case pinned
        case detached
    }

    private struct Wire: Codable {
        let version: Int
        let kind: Kind
        let profileID: SubscriptionProfileID?
        let identityEpoch: UUID?
    }

    init(from decoder: any Decoder) throws {
        guard let wire = try? Wire(from: decoder), wire.version == Self.version else {
            self = .unreadable
            return
        }
        switch wire.kind {
        case .pinned:
            if let profileID = wire.profileID, let identityEpoch = wire.identityEpoch {
                self = .pinned(profileID: profileID, identityEpoch: identityEpoch)
            } else {
                self = .unreadable
            }
        case .detached:
            self = wire.profileID == nil && wire.identityEpoch == nil ? .detached : .unreadable
        }
    }

    func encode(to encoder: any Encoder) throws {
        let wire: Wire
        switch self {
        case let .pinned(profileID, identityEpoch):
            wire = .init(version: Self.version, kind: .pinned, profileID: profileID, identityEpoch: identityEpoch)
        case .detached:
            wire = .init(version: Self.version, kind: .detached, profileID: nil, identityEpoch: nil)
        case .legacy, .unreadable:
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "An absent or unreadable account binding cannot be encoded."
            ))
        }
        try wire.encode(to: encoder)
    }

    /// The debug baseline snapshot has a JSON-level transport, not a full session decoder.
    static var detachedSnapshotValue: [String: Any] {
        ["version": version, "kind": Kind.detached.rawValue]
    }
}

extension KeyedDecodingContainer {
    /// Only a genuinely absent key is legacy. Explicit null is not an authorization signal.
    func decode(_ type: AgentSessionSubscriptionBinding.Type, forKey key: Key) throws -> AgentSessionSubscriptionBinding {
        guard contains(key) else { return .legacy }
        return try decodeIfPresent(type, forKey: key) ?? .unreadable
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: AgentSessionSubscriptionBinding, forKey key: Key) throws {
        guard value != .legacy else { return }
        try encodeIfPresent(Optional(value), forKey: key)
    }
}
