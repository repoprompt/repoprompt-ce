@testable import RepoPromptApp
import XCTest

final class WorkspaceLookupRootSelectorValidatorTests: XCTestCase {
    func testNameOnlyDuplicatesNormalizeToOneIDPathBinding() throws {
        let rootID = UUID()
        let first = WorkspaceRootRef(id: rootID, name: "First", fullPath: "/tmp/project/../project")
        let second = WorkspaceRootRef(id: rootID, name: "Second", fullPath: "/tmp/project")

        let validation = WorkspaceLookupRootSelectorValidator.validate(
            canonicalRoots: [first, second],
            physicalRoots: []
        )

        let selector = try validatedSelector(validation)
        XCTAssertEqual(selector.canonicalRootPathsByID, [rootID: "/tmp/project"])
        XCTAssertTrue(selector.physicalRootPathsByID.isEmpty)
    }

    func testWithinRoleMultiplePathConflictFailsClosed() {
        let rootID = UUID()
        let validation = WorkspaceLookupRootSelectorValidator.validate(
            canonicalRoots: [
                WorkspaceRootRef(id: rootID, name: "First", fullPath: "/tmp/first"),
                WorkspaceRootRef(id: rootID, name: "Second", fullPath: "/tmp/second")
            ],
            physicalRoots: []
        )

        XCTAssertEqual(validation, .conflict(.rootIDHasMultiplePaths))
    }

    func testFullyEqualReferenceAcrossRolesConflicts() {
        let root = WorkspaceRootRef(id: UUID(), name: "Shared", fullPath: "/tmp/shared")

        let validation = WorkspaceLookupRootSelectorValidator.validate(
            canonicalRoots: [root],
            physicalRoots: [root]
        )

        XCTAssertEqual(validation, .conflict(.rootIDHasMultipleRoles))
    }

    private func validatedSelector(
        _ validation: WorkspaceLookupRootSelectorValidation
    ) throws -> WorkspaceValidatedLookupRootSelector {
        guard case let .valid(selector) = validation else {
            throw ValidationError.expectedValidSelector
        }
        return selector
    }

    private enum ValidationError: Error {
        case expectedValidSelector
    }
}
