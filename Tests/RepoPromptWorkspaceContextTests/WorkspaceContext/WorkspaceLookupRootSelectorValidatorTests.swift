import Foundation
@testable import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore
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

final class WorkspaceCodemapStructureQueryExecutorOwningTests: XCTestCase {
    func testScopedDeduplicationAndLogicalOrderingKeepFirstRecord() {
        let firstRoot = WorkspaceRootRef(id: UUID(), name: "A", fullPath: "/one")
        let secondRoot = WorkspaceRootRef(id: UUID(), name: "B", fullPath: "/two")
        let outsider = UUID()
        func file(_ id: UUID = UUID(), _ root: UUID, _ relative: String, _ full: String) -> WorkspaceFileRecord {
            WorkspaceFileRecord(id: id, rootID: root, name: relative, relativePath: relative, fullPath: full, parentFolderID: nil)
        }
        let first = file(UUID(), firstRoot.id, "z.swift", "/one/z.swift")
        let duplicate = file(UUID(), firstRoot.id, "z.swift", "/one/./z.swift")
        let second = file(UUID(), secondRoot.id, "a.swift", "/two/a.swift")
        let outside = file(UUID(), outsider, "x.swift", "/outside/x.swift")
        let roots = [firstRoot, secondRoot]
        let unique = WorkspaceCodemapStructureQueryExecutor.uniqueScopedFiles([first, duplicate, second, outside], roots: roots)
        let ordered = WorkspaceCodemapStructureQueryExecutor.orderFiles(
            unique, roots: roots, logicalRootNames: [firstRoot.id: "Z", secondRoot.id: "A"]
        )
        XCTAssertEqual(ordered.map(\.id), [second.id, first.id])
    }

    func testInitialInvalidationRemainsStickyWhileFinalValidUpdatesReplaceValid() {
        let invalidRoot = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let validRoot = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let invalid: WorkspaceCodemapStructureGraphRevalidationResult = .invalid(code: "stale", message: "old")
        let merged = WorkspaceCodemapStructureQueryExecutor.mergeRevalidation(
            initial: [invalidRoot: invalid, validRoot: .valid(updatesPending: false)],
            final: [invalidRoot: .valid(updatesPending: false), validRoot: .valid(updatesPending: true)]
        )
        XCTAssertEqual(merged[invalidRoot], invalid)
        XCTAssertEqual(merged[validRoot], .valid(updatesPending: true))
    }
}
