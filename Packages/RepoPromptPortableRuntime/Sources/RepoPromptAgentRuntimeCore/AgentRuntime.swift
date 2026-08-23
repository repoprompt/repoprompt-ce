import Foundation
import RepoPromptRuntimeModel

public enum AgentRuntimeError: Error, Equatable, Sendable {
    case resourceUnavailable(OwnedResourceReference)
}

public typealias ResourceAuthorization = @Sendable (
    OwnedResourceReference,
    RuntimeOwnerID
) async throws -> ResourceGrant

public actor AgentRuntime {
    public let ownerID: RuntimeOwnerID
    private let authorizeResource: ResourceAuthorization

    public init(
        ownerID: RuntimeOwnerID,
        authorizeResource: @escaping ResourceAuthorization
    ) {
        self.ownerID = ownerID
        self.authorizeResource = authorizeResource
    }

    public func validateAccess(for workflow: WorkflowDefinition) async throws {
        var seen: Set<OwnedResourceReference> = []
        for reference in workflow.resources where seen.insert(reference).inserted {
            try Task.checkCancellation()
            guard reference.ownerID == ownerID else {
                throw AgentRuntimeError.resourceUnavailable(reference)
            }
            _ = try await authorizeResource(reference, ownerID)
        }
    }
}
