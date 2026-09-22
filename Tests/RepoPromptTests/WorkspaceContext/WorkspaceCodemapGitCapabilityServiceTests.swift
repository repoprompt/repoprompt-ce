import Foundation
@testable import RepoPromptApp
import XCTest

final class WorkspaceCodemapGitCapabilityServiceTests: XCTestCase {
    func testSourceAuthorityRejectsCandidateChangedAfterPostRepositoryCapture() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let relativePath = "Sources/Feature.swift"
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [relativePath: "struct BeforeCapture {}\n"]
        )
        let sourceURL = rootURL.appendingPathComponent(relativePath)
        let pathCaptures = CodemapLockedValues<Int>()
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: Data(repeating: 0x6C, count: GitBlobRepositoryNamespace.saltByteCount),
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: {
                    let shouldChangeCandidate = pathCaptures.values.count == 1
                    pathCaptures.append(1)
                    if shouldChangeCandidate {
                        try? Data("struct AfterCapture {}\n".utf8).write(to: sourceURL, options: .atomic)
                    }
                }
            )
        )
        let request = WorkspaceCodemapGitCapabilityRequest(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: rootURL
        )
        guard case let .eligible(capability) = await service.resolve(root: request) else {
            return XCTFail("Expected an eligible Git Code Map capability")
        }
        addTeardownBlock {
            await service.release(rootEpoch: request.rootEpoch)
            repository.cleanup()
        }

        let authority = await service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: request.rootEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: relativePath,
            observedPathGeneration: 1,
            currentPathGeneration: 1,
            observedIngressGeneration: 1,
            currentIngressGeneration: 1
        )

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "struct AfterCapture {}\n")
        XCTAssertNil(authority)
    }
}
