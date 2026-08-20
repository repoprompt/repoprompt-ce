@testable import RepoPromptAgentRuntimeCore
import RepoPromptRuntimeModel
import XCTest

final class AgentRuntimeTests: XCTestCase {
    func testDeduplicatesResourceChecksAndRejectsCrossOwnerReference() async throws {
        let owner = RuntimeOwnerID(rawValue: "owner")
        let reference = OwnedResourceReference(
            ownerID: owner,
            resourceID: RuntimeResourceID(rawValue: "resource")
        )
        let authorizer = CountingAuthorizer(available: [reference])
        let runtime = AgentRuntime(ownerID: owner) { reference, requestedBy in
            try await authorizer.authorize(reference, requestedBy: requestedBy)
        }
        let workflow = try WorkflowDefinition(resources: [reference, reference])

        try await runtime.validateAccess(for: workflow)
        let authorizationCount = await authorizer.authorizationCount
        XCTAssertEqual(authorizationCount, 1)

        let foreign = OwnedResourceReference(
            ownerID: RuntimeOwnerID(rawValue: "foreign"),
            resourceID: reference.resourceID
        )
        let invalid = try WorkflowDefinition(resources: [foreign])
        do {
            try await runtime.validateAccess(for: invalid)
            XCTFail("Expected cross-owner denial")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .resourceUnavailable(foreign))
        }
    }
}

private actor CountingAuthorizer {
    let available: Set<OwnedResourceReference>
    private(set) var authorizationCount = 0

    init(available: Set<OwnedResourceReference>) {
        self.available = available
    }

    func authorize(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) throws -> ResourceGrant {
        authorizationCount += 1
        guard available.contains(reference), reference.ownerID == ownerID else {
            throw AgentRuntimeError.resourceUnavailable(reference)
        }
        return ResourceGrant(reference: reference, generation: 1)
    }
}
