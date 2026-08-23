import Foundation
import RepoPromptRuntimeModel

public enum AuthorityError: Error, Equatable, Sendable {
    case ownerUnavailable(RuntimeOwnerID)
    case resourceUnavailable(OwnedResourceReference)
    case staleGrant(ResourceGrant)
    case revisionConflict(expected: Int64, actual: Int64)
    case resourceGenerationExhausted
}

public protocol ResourceAuthorizing: Sendable {
    func authorize(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws -> ResourceGrant

    func validate(_ grant: ResourceGrant, requestedBy ownerID: RuntimeOwnerID) async throws
}

public protocol ResourceAuthorityManaging: ResourceAuthorizing {
    func registerOwner(_ ownerID: RuntimeOwnerID) async throws
    func removeOwner(_ ownerID: RuntimeOwnerID) async
    func attach(
        _ resourceID: RuntimeResourceID,
        to ownerID: RuntimeOwnerID
    ) async throws -> OwnedResourceReference
    func detach(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws
}

public struct AuthorityEvent: Codable, Hashable, Sendable {
    public let cursor: ServiceCursor
    public let name: String
    public let payload: WorkflowValue

    public init(cursor: ServiceCursor, name: String, payload: WorkflowValue) {
        self.cursor = cursor
        self.name = name
        self.payload = payload
    }
}

public protocol RepoPromptEventServing: Sendable {
    func events(after cursor: ServiceCursor?, limit: Int) async throws -> [AuthorityEvent]
}

public protocol RepoPromptProviderDispatching: Sendable {
    func reserveRun(provider: ProviderKind, operationID: UUID) async throws
    func launchReservedRun(operationID: UUID) async throws
    func requestCancellation(operationID: UUID) async throws
}

public protocol RepoPromptHostCapabilityProviding: Sendable {
    var events: any RepoPromptEventServing { get }
    var resources: any ResourceAuthorizing { get }
}

public struct EventDeliveryCursorGate: Sendable {
    public private(set) var greatestDelivered: ServiceCursor?

    public init(greatestDelivered: ServiceCursor? = nil) {
        self.greatestDelivered = greatestDelivered
    }

    public mutating func shouldDeliver(_ cursor: ServiceCursor) -> Bool {
        guard let greatestDelivered else {
            greatestDelivered = cursor
            return true
        }
        guard greatestDelivered.storeID == cursor.storeID else {
            self.greatestDelivered = cursor
            return true
        }
        guard cursor.globalSequence > greatestDelivered.globalSequence else {
            return false
        }
        self.greatestDelivered = cursor
        return true
    }
}
