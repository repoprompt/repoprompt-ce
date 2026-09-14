import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class WorkspaceCodemapRootCapabilityServiceTests: XCTestCase {
    /// A release can arrive while a root epoch is between `invalidateForAuthorityReplacement` and
    /// its replacement registration. In that gap there is no record left to remove, so the release
    /// has to terminalize the epoch itself; otherwise the epoch keeps neither a tombstone nor its
    /// high-water generation and a delayed resolve reissues an authority that was already revoked.
    ///
    /// The native replacement scenario reaches this state through unload during recovery; this test
    /// isolates the capability-service invariant itself, without the store lifecycle around it.
    func testReleaseInsideAuthorityReplacementGapTerminalizesRootEpoch() async throws {
        let rootURL = try makeTemporaryRoot()
        let probe = WorkspaceCodemapLocalGitClassificationProbe.production
        guard case let .definitelyNonGit(proof) = await probe.resolve(rootURL) else {
            return XCTFail("A plain temporary directory must classify as definitely non-Git")
        }
        let service = makeService(probe: probe)
        let request = WorkspaceCodemapRootCapabilityRequest(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: rootURL
        )
        addTeardownBlock { await service.release(rootEpoch: request.rootEpoch) }

        guard case let .eligible(capability) = await service.resolve(
            root: request,
            evidence: .filesystem(proof)
        ) else {
            return XCTFail("Expected an eligible filesystem Code Map capability")
        }
        let issuedGeneration = try XCTUnwrap(
            Self.filesystemAuthorityGeneration(capability.rootAuthority)
        )

        await service.invalidateForAuthorityReplacement(rootEpoch: request.rootEpoch)
        await service.release(rootEpoch: request.rootEpoch)

        let delayed = await service.resolve(root: request, evidence: .filesystem(proof))
        let delayedState = await service.state(for: request.rootEpoch)
        XCTAssertEqual(delayed, .terminalUnavailable(.releasedRootEpoch))
        XCTAssertEqual(delayedState, .terminalUnavailable(.releasedRootEpoch))
        if case let .eligible(resurrected) = delayed {
            XCTAssertNotEqual(
                Self.filesystemAuthorityGeneration(resurrected.rootAuthority),
                issuedGeneration,
                "A released epoch must never reissue the revoked authority generation"
            )
        }
    }

    /// Losing search permission on the loaded root makes the proof unobservable, which is not
    /// evidence that the binding or source mode changed. Revalidation must stay transient so the
    /// root is not revoked and its generation is not advanced, and restoring access must return the
    /// same authority rather than a replacement.
    ///
    /// The store scenarios cannot reach this either: they observe the engine's serving decision,
    /// not the typed distinction between a transient read failure and a binding change.
    func testLostRootSearchPermissionIsTransientRatherThanAuthorityChange() async throws {
        try XCTSkipIf(getuid() == 0, "Permission denial cannot be observed while running as root")
        let rootURL = try makeTemporaryRoot()
        let probe = WorkspaceCodemapLocalGitClassificationProbe.production
        guard case let .definitelyNonGit(proof) = await probe.resolve(rootURL) else {
            return XCTFail("A plain temporary directory must classify as definitely non-Git")
        }
        let service = makeService(probe: probe)
        let request = WorkspaceCodemapRootCapabilityRequest(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: rootURL
        )
        addTeardownBlock { await service.release(rootEpoch: request.rootEpoch) }

        guard case let .eligible(capability) = await service.resolve(
            root: request,
            evidence: .filesystem(proof)
        ) else {
            return XCTFail("Expected an eligible filesystem Code Map capability")
        }
        let validated = await service.revalidateRootAuthority(capability: capability)
        XCTAssertEqual(validated, .current)

        XCTAssertEqual(chmod(rootURL.path, 0), 0)
        let denied = await service.revalidateRootAuthority(capability: capability)
        XCTAssertEqual(denied, .unavailable(.permissionFailure))

        XCTAssertEqual(chmod(rootURL.path, 0o755), 0)
        let restored = await service.revalidateRootAuthority(capability: capability)
        let restoredState = await service.state(for: request.rootEpoch)
        XCTAssertEqual(
            restored,
            .current,
            "Restored access on the same directory must refresh the proof, not advance authority"
        )
        XCTAssertEqual(restoredState, .eligible(capability))
    }

    private func makeService(
        probe: WorkspaceCodemapLocalGitClassificationProbe
    ) -> WorkspaceCodemapRootCapabilityService {
        WorkspaceCodemapRootCapabilityService(
            namespaceSalt: Data(repeating: 0x6C, count: GitBlobRepositoryNamespace.saltByteCount),
            localClassificationProbe: probe
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceCodemapRootCapabilityServiceTests-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        let rootURL = sandbox.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock {
            chmod(rootURL.path, 0o755)
            try? FileManager.default.removeItem(at: sandbox)
        }
        return rootURL
    }

    private static func filesystemAuthorityGeneration(
        _ token: WorkspaceCodemapRootAuthorityToken
    ) -> UInt64? {
        guard case let .filesystem(_, authorityGeneration) = token else { return nil }
        return authorityGeneration
    }

    func testSourceAuthorityRejectsCandidateChangedAfterPostRepositoryCapture() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let relativePath = "Sources/Feature.swift"
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [relativePath: "struct BeforeCapture {}\n"]
        )
        let sourceURL = rootURL.appendingPathComponent(relativePath)
        let pathCaptures = CodemapLockedValues<Int>()
        let service = WorkspaceCodemapRootCapabilityService(
            namespaceSalt: Data(repeating: 0x6C, count: GitBlobRepositoryNamespace.saltByteCount),
            hooks: WorkspaceCodemapRootCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: {
                    let shouldChangeCandidate = pathCaptures.values.count == 1
                    pathCaptures.append(1)
                    if shouldChangeCandidate {
                        try? Data("struct AfterCapture {}\n".utf8).write(to: sourceURL, options: .atomic)
                    }
                }
            )
        )
        let request = WorkspaceCodemapRootCapabilityRequest(
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
            observedRootAuthority: capability.rootAuthority,
            candidateRootRelativePath: relativePath,
            observedPathGeneration: 1,
            currentPathGeneration: 1,
            observedIngressGeneration: 1,
            currentIngressGeneration: 1
        )

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "struct AfterCapture {}\n")
        XCTAssertNil(authority)
    }
}
