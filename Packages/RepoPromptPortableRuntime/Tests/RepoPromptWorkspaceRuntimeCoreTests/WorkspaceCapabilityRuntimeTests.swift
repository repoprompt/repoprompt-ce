import RepoPromptRuntimeModel
@testable import RepoPromptWorkspaceRuntimeCore
import XCTest

final class WorkspaceCapabilityRuntimeTests: XCTestCase {
    func testWorkspaceRelativePathCodablePreservesValidation() throws {
        let valid = try WorkspaceRelativePath(validating: "Sources/main.swift")
        let encoded = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceRelativePath.self, from: encoded), valid)

        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceRelativePath.self,
            from: Data("\"../secret\"".utf8)
        ))
    }

    func testCrossOwnerAndStaleGrantFailBeforePhysicalPortInvocation() async throws {
        let authority = WorkspaceRuntime()
        let owner = RuntimeOwnerID(rawValue: "owner")
        let foreign = RuntimeOwnerID(rawValue: "foreign")
        try await authority.registerOwner(owner)
        try await authority.registerOwner(foreign)
        let reference = try await authority.attach(RuntimeResourceID(rawValue: "repository"), to: owner)
        let ports = RecordingWorkspacePorts()
        let runtime = WorkspaceCapabilityRuntime(
            authority: authority,
            filesystem: ports,
            worktrees: ports,
            artifacts: ports,
            projectSources: ports
        )
        let path = try WorkspaceRelativePath(validating: "Sources/main.swift")

        do {
            _ = try await runtime.readFile(reference, path: path, requestedBy: foreign)
            XCTFail("Expected cross-owner denial")
        } catch let error as WorkspaceRuntimeError {
            XCTAssertEqual(error, .resourceUnavailable(reference))
        }
        let callsAfterCrossOwner = await ports.invocationCount()
        XCTAssertEqual(callsAfterCrossOwner, 0)

        let staleGrant = try await authority.authorize(reference, requestedBy: owner)
        try await authority.detach(reference, requestedBy: owner)
        _ = try await authority.attach(reference.resourceID, to: owner)
        do {
            _ = try await runtime.readFile(grant: staleGrant, path: path, requestedBy: owner)
            XCTFail("Expected stale grant denial")
        } catch let error as WorkspaceRuntimeError {
            XCTAssertEqual(error, .staleGrant(staleGrant))
        }
        let callsAfterStaleGrant = await ports.invocationCount()
        XCTAssertEqual(callsAfterStaleGrant, 0)
    }

    func testAuthorizedCapabilityFamiliesDelegateWithCurrentGrant() async throws {
        let authority = WorkspaceRuntime()
        let owner = RuntimeOwnerID(rawValue: "owner")
        try await authority.registerOwner(owner)
        let reference = try await authority.attach(RuntimeResourceID(rawValue: "repository"), to: owner)
        let ports = RecordingWorkspacePorts()
        let runtime = WorkspaceCapabilityRuntime(
            authority: authority,
            filesystem: ports,
            worktrees: ports,
            artifacts: ports,
            projectSources: ports
        )

        let file = try await runtime.readFile(
            reference,
            path: WorkspaceRelativePath(validating: "README.md"),
            requestedBy: owner
        )
        XCTAssertEqual(String(decoding: file.contents, as: UTF8.self), "contents")
        _ = try await runtime.checkout(reference, requestedBy: owner)
        _ = try await runtime.loadArtifact(reference, name: "codemap", requestedBy: owner)
        _ = try await runtime.projectSource(reference, requestedBy: owner)
        let invocationCount = await ports.invocationCount()
        XCTAssertEqual(invocationCount, 4)
    }
}

private actor RecordingWorkspacePorts:
    WorkspaceFilesystemPort,
    WorkspaceWorktreePort,
    WorkspaceArtifactPort,
    WorkspaceProjectSourcePort
{
    private var calls = 0

    func readFile(
        grant _: ResourceGrant,
        path: WorkspaceRelativePath
    ) async throws -> WorkspaceFileSnapshot {
        calls += 1
        return WorkspaceFileSnapshot(path: path, contents: Data("contents".utf8))
    }

    func checkout(grant _: ResourceGrant) async throws -> WorkspaceCheckoutSnapshot {
        calls += 1
        return WorkspaceCheckoutSnapshot(canonicalPath: "/workspace")
    }

    func loadArtifact(grant _: ResourceGrant, name: String) async throws -> WorkspaceArtifactSnapshot {
        calls += 1
        return try WorkspaceArtifactSnapshot(name: name, contents: Data())
    }

    func projectSource(grant _: ResourceGrant) async throws -> ProjectSourceSnapshot {
        calls += 1
        return ProjectSourceSnapshot(files: [])
    }

    func invocationCount() -> Int {
        calls
    }
}
