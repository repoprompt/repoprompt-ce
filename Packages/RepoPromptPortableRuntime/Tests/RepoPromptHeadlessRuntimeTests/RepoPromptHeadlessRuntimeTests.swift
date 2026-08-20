import RepoPromptAuthorityAPI
@testable import RepoPromptHeadlessRuntime
import RepoPromptRuntimeModel
import XCTest

final class RepoPromptHeadlessRuntimeTests: XCTestCase {
    func testEndToEndOwnerResourceValidation() async throws {
        let runtime = RepoPromptHeadlessRuntime()
        let owner = RuntimeOwnerID(rawValue: "owner")
        try await runtime.registerOwner(owner)
        let reference = try await runtime.attach(RuntimeResourceID(rawValue: "repository"), to: owner)
        let workflow = try WorkflowDefinition(resources: [reference])
        try await runtime.validate(workflow, for: owner)

        await runtime.removeOwner(owner)
        do {
            try await runtime.validate(workflow, for: owner)
            XCTFail("Expected removed owner to be unavailable")
        } catch let error as AuthorityError {
            XCTAssertEqual(error, .ownerUnavailable(owner))
        }
    }
}
