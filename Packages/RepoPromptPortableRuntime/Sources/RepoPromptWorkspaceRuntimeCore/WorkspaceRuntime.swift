import RepoPromptRuntimeModel
import RepoPromptShared

public enum WorkspaceRuntimeError: Error, Equatable, Sendable {
    case ownerUnavailable(RuntimeOwnerID)
    case resourceUnavailable(OwnedResourceReference)
    case staleGrant(ResourceGrant)
    case generationExhausted
}

public actor WorkspaceRuntime {
    private var owners: Set<RuntimeOwnerID> = []
    private var generations: [OwnedResourceReference: UInt64] = [:]
    private var nextGeneration: UInt64 = 1

    public init() {}

    public func registerOwner(_ ownerID: RuntimeOwnerID) throws {
        try Task.checkCancellation()
        owners.insert(ownerID)
    }

    public func removeOwner(_ ownerID: RuntimeOwnerID) {
        owners.remove(ownerID)
        generations = generations.filter { $0.key.ownerID != ownerID }
    }

    public func attach(
        _ resourceID: RuntimeResourceID,
        to ownerID: RuntimeOwnerID
    ) throws -> OwnedResourceReference {
        try Task.checkCancellation()
        guard owners.contains(ownerID) else {
            throw WorkspaceRuntimeError.ownerUnavailable(ownerID)
        }
        let reference = OwnedResourceReference(ownerID: ownerID, resourceID: resourceID)
        if generations[reference] == nil {
            guard nextGeneration < UInt64.max else {
                throw WorkspaceRuntimeError.generationExhausted
            }
            generations[reference] = nextGeneration
            nextGeneration += 1
        }
        return reference
    }

    public func detach(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) throws {
        try Task.checkCancellation()
        guard reference.ownerID == ownerID, owners.contains(ownerID) else {
            throw WorkspaceRuntimeError.resourceUnavailable(reference)
        }
        generations.removeValue(forKey: reference)
    }

    public func authorize(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) throws -> ResourceGrant {
        guard reference.ownerID == ownerID,
              owners.contains(ownerID),
              let generation = generations[reference]
        else {
            throw WorkspaceRuntimeError.resourceUnavailable(reference)
        }
        return ResourceGrant(reference: reference, generation: generation)
    }

    public func validate(_ grant: ResourceGrant, requestedBy ownerID: RuntimeOwnerID) throws {
        guard grant.reference.ownerID == ownerID,
              owners.contains(ownerID),
              generations[grant.reference] == grant.generation
        else {
            throw WorkspaceRuntimeError.staleGrant(grant)
        }
    }
}
