@testable import RepoPromptApp
import XCTest

final class GitWorktreeRetirementTests: XCTestCase {
    func testAdmissionClosesAtomicallyAndWaitsForExistingGenerationLeases() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let preflight = try await fixture.target(using: git, generation: 0, authority: authority)

        let binding = try authority.acquireBindingLease(worktreeID: preflight.worktreeID)
        let mutation = try authority.acquireMutationLease(paths: [preflight.path])
        let gitProcess = try authority.acquireGitProcessLease(
            at: fixture.mainRoot,
            commonGitDirectory: URL(fileURLWithPath: preflight.commonGitDirectory)
        )
        let workspaceRoot = try authority.acquireWorkspaceRootLease(paths: [preflight.path])
        let preparation = try authority.begin(preflight.candidate)

        XCTAssertEqual(try authority.activeAdmissionCount(for: preparation), 4)
        XCTAssertThrowsError(try authority.acquireBindingLease(worktreeID: preflight.worktreeID)) { error in
            XCTAssertEqual(error as? GitWorktreeRetirementError, .bindingRejected(preflight.worktreeID))
        }
        XCTAssertThrowsError(try authority.acquireMutationLease(paths: [preflight.path])) { error in
            XCTAssertEqual(error as? GitWorktreeRetirementError, .mutationRejected(preflight.canonicalPath))
        }
        XCTAssertThrowsError(
            try authority.acquireGitProcessLease(
                at: fixture.mainRoot,
                commonGitDirectory: URL(fileURLWithPath: preflight.commonGitDirectory)
            )
        )
        XCTAssertThrowsError(try authority.acquireWorkspaceRootLease(paths: [preflight.path]))

        let drainPermit = try authority.permit(for: preparation)
        let permittedProbe = try authority.acquireGitProcessLease(
            at: fixture.mainRoot,
            commonGitDirectory: URL(fileURLWithPath: preflight.commonGitDirectory),
            permit: drainPermit
        )
        permittedProbe.release()
        binding.release()
        mutation.release()
        gitProcess.release()
        workspaceRoot.release()
        try await authority.awaitZeroAdmissions(for: preparation)

        let target = try await fixture.target(
            using: git,
            generation: preparation.generation,
            permit: drainPermit,
            authority: authority
        )
        let authorization = try authority.authorizeAfterDrain(
            preparation,
            target: target,
            drain: Self.drain(activeAdmissionsBefore: 4)
        )
        let applyingPermit = try authority.consume(authorization, reattestedTarget: target)
        _ = try authority.blockResidue(applyingPermit, reason: "test terminal tombstone")

        XCTAssertThrowsError(try authority.acquireBindingLease(worktreeID: target.worktreeID))
        XCTAssertThrowsError(try authority.acquireMutationLease(paths: [target.path]))
    }

    func testWorkspaceAdmissionMatchesAncestorAndNestedRoots() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let target = try await fixture.target(using: git, generation: 0, authority: authority)
        let nestedRoot = fixture.linkedRoot.appendingPathComponent("nested-root", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        let ancestorLease = try authority.acquireWorkspaceRootLease(paths: [fixture.sandbox.path])
        let nestedLease = try authority.acquireWorkspaceRootLease(paths: [nestedRoot.path])
        let preparation = try authority.begin(target.candidate)

        XCTAssertEqual(try authority.activeAdmissionCount(for: preparation), 2)
        XCTAssertThrowsError(try authority.acquireWorkspaceRootLease(paths: [fixture.sandbox.path]))
        XCTAssertThrowsError(try authority.acquireWorkspaceRootLease(paths: [target.path]))
        XCTAssertThrowsError(try authority.acquireWorkspaceRootLease(paths: [nestedRoot.path]))

        ancestorLease.release()
        nestedLease.release()
        try await authority.awaitZeroAdmissions(for: preparation)
        _ = try authority.blockPreparation(
            preparation,
            reason: "test completed without physical retirement"
        )
    }

    func testWorkspaceAdmissionIsIsolatedToFixtureAuthority() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let authority = fixture.makeAuthority()
        let target = try await fixture.target(using: GitService(), generation: 0, authority: authority)
        let workspaceLease = try authority.acquireWorkspaceRootLease(paths: [target.path])
        let preparation = try authority.begin(target.candidate)

        XCTAssertEqual(try authority.activeAdmissionCount(for: preparation), 1)
        XCTAssertThrowsError(try authority.acquireWorkspaceRootLease(paths: [target.path]))
        workspaceLease.release()
        try await authority.awaitZeroAdmissions(for: preparation)
        _ = try authority.blockPreparation(preparation, reason: "isolated test completed")
    }

    func testCancelledPreparationReopensAdmissionForCleanRetryWithoutResidue() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let authority = fixture.makeAuthority()
        let target = try await fixture.target(using: GitService(), generation: 0, authority: authority)
        let firstPreparation = try authority.begin(target.candidate)

        try authority.cancelPreparationForRetry(firstPreparation)

        XCTAssertNil(try authority.evidence(token: firstPreparation.token))
        XCTAssertNil(try authority.evidence(worktreeID: target.worktreeID))
        let reopenedLease = try authority.acquireWorkspaceRootLease(paths: [target.path])
        reopenedLease.release()

        let retryPreparation = try authority.begin(target.candidate)
        XCTAssertNotEqual(retryPreparation.token, firstPreparation.token)
        _ = try authority.blockPreparation(
            retryPreparation,
            reason: "retry-path test completed without physical retirement"
        )
    }

    func testInspectionRejectsActiveOperationsAndLocks() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let descriptor = try await fixture.linkedDescriptor(using: git, authority: authority)
        let gitDirectory = try URL(fileURLWithPath: XCTUnwrap(descriptor.gitDir), isDirectory: true)
        try "active\n".write(
            to: gitDirectory.appendingPathComponent("MERGE_HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: gitDirectory.appendingPathComponent("index.lock"))

        do {
            _ = try await git.inspectRetirementTarget(
                descriptor: descriptor,
                generation: 0,
                retirementAuthority: authority
            )
            XCTFail("Expected active Git operation evidence to fail closed")
        } catch {
            XCTAssertEqual(error as? GitWorktreeRetirementError, .activeOperations(2))
        }
    }

    func testIdentityRejectsSymlinkAncestorAndDirectorySubstitution() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let descriptor = try await fixture.linkedDescriptor(using: git, authority: authority)
        let actualParent = fixture.sandbox.appendingPathComponent("actual-parent", isDirectory: true)
        let aliasParent = fixture.sandbox.appendingPathComponent("alias-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: actualParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: actualParent)
        let aliasDescriptor = GitWorktreeDescriptor(
            worktreeID: descriptor.worktreeID,
            repository: descriptor.repository,
            path: aliasParent.appendingPathComponent("linked").path,
            gitDir: descriptor.gitDir,
            name: descriptor.name,
            branch: descriptor.branch,
            head: descriptor.head,
            isMain: descriptor.isMain,
            isCurrent: descriptor.isCurrent,
            isDetached: descriptor.isDetached,
            isLocked: descriptor.isLocked,
            lockReason: descriptor.lockReason,
            isPrunable: descriptor.isPrunable,
            prunableReason: descriptor.prunableReason
        )
        XCTAssertThrowsError(try GitWorktreeRetirementCandidate(descriptor: aliasDescriptor)) { error in
            guard case .symlinkIdentityEvidence = error as? GitWorktreeRetirementError else {
                return XCTFail("Expected ancestor symlink rejection, got \(error)")
            }
        }

        let sealed = try await fixture.target(using: git, generation: 0, authority: authority)
        let displaced = fixture.sandbox.appendingPathComponent("displaced-linked", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.linkedRoot, to: displaced)
        try FileManager.default.createDirectory(at: fixture.linkedRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try sealed.candidate.requireCurrentPhysicalIdentity()) { error in
            XCTAssertEqual(error as? GitWorktreeRetirementError, .targetChanged)
        }
    }

    func testInspectionRejectsIgnoredContentEvenWhenGitOtherwiseClean() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        try "ignored\n".write(
            to: fixture.linkedRoot.appendingPathComponent("ignored.bin"),
            atomically: true,
            encoding: .utf8
        )

        let authority = fixture.makeAuthority()
        let descriptor = try await fixture.linkedDescriptor(using: GitService(), authority: authority)
        do {
            _ = try await GitService().inspectRetirementTarget(
                descriptor: descriptor,
                generation: 0,
                retirementAuthority: authority
            )
            XCTFail("Expected ignored content to fail closed")
        } catch {
            XCTAssertEqual(error as? GitWorktreeRetirementError, .ignoredContent)
        }
    }

    func testRetireReattestsAfterAuthorizationAndBlocksChangedTarget() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let authorization = try await fixture.authorize(using: git, authority: authority)

        try "race\n".write(
            to: fixture.linkedRoot.appendingPathComponent("race.txt"),
            atomically: true,
            encoding: .utf8
        )
        do {
            _ = try await git.retireWorktree(
                authorization: authorization,
                at: fixture.mainRoot,
                authority: authority
            )
            XCTFail("Expected final re-attestation to reject changed content")
        } catch {
            XCTAssertEqual(error as? GitWorktreeRetirementError, .dirtyWorktree)
        }

        let evidence = try XCTUnwrap(authority.evidence(token: authorization.token))
        XCTAssertEqual(evidence.state, .blockedResidue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedRoot.path))
        XCTAssertThrowsError(try authority.acquireBindingLease(worktreeID: authorization.target.worktreeID))
    }

    func testConsumedAuthorizationRecoversAsPermanentBlockedResidueAfterRestart() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let stateURL = fixture.retirementStateURL
        let firstAuthority = GitWorktreeRetirementAuthority(persistenceURL: stateURL)
        let authorization = try await fixture.authorize(using: git, authority: firstAuthority)
        _ = try firstAuthority.consume(authorization, reattestedTarget: authorization.target)

        let restartedAuthority = GitWorktreeRetirementAuthority(persistenceURL: stateURL)
        let evidence = try XCTUnwrap(restartedAuthority.evidence(token: authorization.token))
        XCTAssertEqual(evidence.state, .blockedResidue)
        XCTAssertNotNil(evidence.mutation.authorizationConsumedAt)
        XCTAssertFalse(evidence.postconditions.gitRegistrationAbsent)
        XCTAssertThrowsError(try restartedAuthority.acquireBindingLease(worktreeID: authorization.target.worktreeID))
        XCTAssertThrowsError(try restartedAuthority.acquireMutationLease(paths: [authorization.target.path]))
        XCTAssertThrowsError(try restartedAuthority.begin(authorization.target.candidate)) { error in
            XCTAssertEqual(
                error as? GitWorktreeRetirementError,
                .alreadyRetiring(authorization.target.worktreeID)
            )
        }
    }

    func testAuthorizationTTLExpiresIntoReadbackablePermanentResidue() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let preflight = try await fixture.target(using: git, generation: 0, authority: authority)
        let issuedAt = Date(timeIntervalSince1970: 100)
        let preparation = try authority.begin(preflight.candidate, now: issuedAt)
        let permit = try authority.permit(for: preparation)
        let sealed = try await fixture.target(
            using: git,
            generation: preparation.generation,
            permit: permit,
            authority: authority
        )
        let authorization = try authority.authorizeAfterDrain(
            preparation,
            target: sealed,
            drain: Self.drain(),
            now: issuedAt
        )
        let expiredAt = issuedAt.addingTimeInterval(GitWorktreeRetirementAuthority.authorizationTTL + 1)
        XCTAssertThrowsError(try authority.authorization(token: authorization.token, now: expiredAt)) { error in
            XCTAssertEqual(error as? GitWorktreeRetirementError, .authorizationExpired)
        }
        let evidence = try XCTUnwrap(authority.evidence(token: authorization.token))
        XCTAssertEqual(evidence.state, .blockedResidue)
        XCTAssertThrowsError(try authority.acquireBindingLease(worktreeID: authorization.target.worktreeID))
    }

    func testPersistenceFailurePermanentlyFailsAuthorityClosed() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let inspectionAuthority = fixture.makeAuthority()
        let preflight = try await fixture.target(
            using: git,
            generation: 0,
            authority: inspectionAuthority
        )
        let blockedParent = fixture.sandbox.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedParent)
        let authority = GitWorktreeRetirementAuthority(
            persistenceURL: blockedParent.appendingPathComponent("state.json")
        )

        XCTAssertThrowsError(try authority.begin(preflight.candidate)) { error in
            guard case .persistenceFailed = error as? GitWorktreeRetirementError else {
                return XCTFail("Expected surfaced persistence failure, got \(error)")
            }
        }
        XCTAssertEqual(authority.debugStateGeneration(), 1)

        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        XCTAssertThrowsError(try authority.begin(preflight.candidate)) { error in
            guard case .persistenceFailed = error as? GitWorktreeRetirementError else {
                return XCTFail("Ambiguous persistence must remain fail-closed, got \(error)")
            }
        }
    }

    func testCleanRetirementPersistsEvidenceAndRejectsIdentityReuse() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let authorization = try await fixture.authorize(using: git, authority: authority)
        var reusedCandidateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(authorization.target.candidate)
            ) as? [String: Any]
        )
        reusedCandidateObject["worktreeID"] = "wt_reused_path"
        let reusedPathCandidate = try JSONDecoder().decode(
            GitWorktreeRetirementCandidate.self,
            from: JSONSerialization.data(withJSONObject: reusedCandidateObject, options: [.sortedKeys])
        )

        let evidence = try await git.retireWorktree(
            authorization: authorization,
            at: fixture.mainRoot,
            authority: authority
        )

        XCTAssertEqual(evidence.state, .retired)
        XCTAssertEqual(evidence.consumedAuthorizationDigest, authorization.tokenDigest)
        XCTAssertEqual(evidence.authorityScope, "repoprompt_control_plane")
        XCTAssertEqual(evidence.attestedIdentity, .init(
            repositoryRoot: authorization.target.candidate.repositoryRoot,
            commonGitDirectory: authorization.target.candidate.commonGitDirectory,
            worktreeParentDirectory: authorization.target.candidate.worktreeParentDirectory,
            worktreeDirectory: authorization.target.candidate.worktreeDirectory,
            gitDirectoryParent: authorization.target.candidate.gitDirectoryParent,
            gitDirectory: authorization.target.candidate.gitDirectory
        ))
        XCTAssertTrue(evidence.mutation.serializedExecutor)
        XCTAssertEqual(evidence.mutation.gitRemoveExitCode, 0)
        XCTAssertTrue(evidence.postconditions.gitRegistrationAbsent)
        XCTAssertTrue(evidence.postconditions.pathAbsent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkedRoot.path))
        XCTAssertEqual(try authority.evidence(token: authorization.token), evidence)
        XCTAssertThrowsError(try authority.begin(authorization.target.candidate))
        XCTAssertThrowsError(try authority.acquireBindingLease(worktreeID: authorization.target.worktreeID))
        XCTAssertThrowsError(try authority.acquireMutationLease(paths: [authorization.target.path]))
        XCTAssertThrowsError(
            try authority.acquireBindingLease(
                worktreeID: "wt_recreated",
                repositoryID: authorization.target.repositoryID,
                canonicalPath: authorization.target.path
            )
        )
        XCTAssertThrowsError(
            try authority.acquireGitProcessLease(
                at: fixture.mainRoot,
                commonGitDirectory: URL(fileURLWithPath: authorization.target.commonGitDirectory),
                affectedWorktreeID: authorization.target.worktreeID,
                affectedPaths: [URL(fileURLWithPath: authorization.target.path)]
            )
        )

        XCTAssertThrowsError(try authority.begin(reusedPathCandidate)) { error in
            XCTAssertEqual(
                error as? GitWorktreeRetirementError,
                .alreadyRetiring(authorization.target.worktreeID)
            )
        }
    }

    func testRemoveAndPostconditionFaultsPersistBlockedResidue() async throws {
        for failurePoint in [GitService.RetirementFailurePointForTesting.remove, .postcondition] {
            let fixture = try RetirementGitFixture()
            defer { fixture.cleanup() }
            let git = GitService()
            let authority = fixture.makeAuthority()
            let authorization = try await fixture.authorize(using: git, authority: authority)
            await git.setRetirementFailurePointForTesting(failurePoint)

            do {
                _ = try await git.retireWorktree(
                    authorization: authorization,
                    at: fixture.mainRoot,
                    authority: authority
                )
                XCTFail("Expected injected \(failurePoint) fault")
            } catch {}

            let evidence = try XCTUnwrap(authority.evidence(token: authorization.token))
            XCTAssertEqual(evidence.state, .blockedResidue)
            XCTAssertThrowsError(try authority.acquireBindingLease(worktreeID: authorization.target.worktreeID))
            if failurePoint == .remove {
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedRoot.path))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkedRoot.path))
            }
        }
    }

    func testInspectionRejectsStagedUnstagedUntrackedAndIgnoredContentIndependently() async throws {
        try await assertInspectionRejects(.dirtyWorktree) { fixture in
            try "unstaged\n".write(
                to: fixture.linkedRoot.appendingPathComponent("seed.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        try await assertInspectionRejects(.dirtyWorktree) { fixture in
            try "staged\n".write(
                to: fixture.linkedRoot.appendingPathComponent("seed.txt"),
                atomically: true,
                encoding: .utf8
            )
            try fixture.git(["add", "seed.txt"], at: fixture.linkedRoot)
        }
        try await assertInspectionRejects(.dirtyWorktree) { fixture in
            try "untracked\n".write(
                to: fixture.linkedRoot.appendingPathComponent("line\nbreak.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        try await assertInspectionRejects(.ignoredContent) { fixture in
            try "ignored\n".write(
                to: fixture.linkedRoot.appendingPathComponent("ignored.bin"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func testCleanHeadChangeInvalidatesSealedTargetAndPersistsResidue() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let authorization = try await fixture.authorize(using: git, authority: authority)
        try "new head\n".write(
            to: fixture.linkedRoot.appendingPathComponent("head-change.txt"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.git(["add", "head-change.txt"], at: fixture.linkedRoot)
        try fixture.git(["commit", "-q", "-m", "change head"], at: fixture.linkedRoot)

        do {
            _ = try await git.retireWorktree(
                authorization: authorization,
                at: fixture.mainRoot,
                authority: authority
            )
            XCTFail("Expected changed HEAD rejection")
        } catch {
            XCTAssertEqual(error as? GitWorktreeRetirementError, .targetChanged)
        }
        XCTAssertEqual(try authority.evidence(token: authorization.token)?.state, .blockedResidue)
    }

    func testStaleGenerationAndTokenAreRejected() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let preflight = try await fixture.target(using: git, generation: 0, authority: authority)
        let preparation = try authority.begin(preflight.candidate)
        let permit = try authority.permit(for: preparation)
        let staleGenerationTarget = try await fixture.target(
            using: git,
            generation: preparation.generation + 1,
            permit: permit,
            authority: authority
        )
        XCTAssertThrowsError(
            try authority.authorizeAfterDrain(
                preparation,
                target: staleGenerationTarget,
                drain: Self.drain()
            )
        ) { error in
            XCTAssertEqual(error as? GitWorktreeRetirementError, .invalidAuthorization)
        }
        XCTAssertThrowsError(try authority.authorization(token: "retire_wrong")) { error in
            XCTAssertEqual(error as? GitWorktreeRetirementError, .invalidAuthorization)
        }
        _ = try authority.blockPreparation(preparation, reason: "stale generation test complete")
    }

    func testCompletionRejectsNonzeroExitOrIncompleteExactPostconditions() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        let authorization = try await fixture.authorize(using: git, authority: authority)
        let permit = try authority.consume(authorization, reattestedTarget: authorization.target)

        XCTAssertThrowsError(
            try authority.complete(
                permit,
                gitRemoveExitCode: 1,
                postconditions: .unknown
            )
        ) { error in
            guard case .postconditionFailed = error as? GitWorktreeRetirementError else {
                return XCTFail("Expected fail-closed completion, got \(error)")
            }
        }
        let evidence = try authority.blockResidue(
            permit,
            reason: "invalid completion correctly rejected",
            gitRemoveExitCode: 1,
            postconditions: .unknown
        )
        XCTAssertTrue(evidence.mutation.serializedExecutor)
        XCTAssertEqual(evidence.mutation.gitRemoveExitCode, 1)
    }

    func testConcurrentAuthorityCannotEnterSameCommonDirectoryRetirement() async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let first = fixture.makeAuthority()
        let second = fixture.makeAuthority()
        let candidate = try await fixture.target(using: git, generation: 0, authority: first).candidate
        let preparation = try first.begin(candidate)
        XCTAssertThrowsError(try second.acquireBindingLease(worktreeID: candidate.worktreeID)) { error in
            XCTAssertEqual(error as? GitWorktreeRetirementError, .bindingRejected(candidate.worktreeID))
        }
        XCTAssertThrowsError(try second.begin(candidate)) { error in
            guard case .alreadyRetiring = error as? GitWorktreeRetirementError else {
                return XCTFail("Expected interprocess operation lease rejection, got \(error)")
            }
        }
        _ = try first.blockPreparation(preparation, reason: "operation lease test complete")
    }

    func testDefaultPersistencePathIsCEProductSpecific() {
        XCTAssertTrue(
            GitWorktreeRetirementAuthority.defaultPersistenceURLForTesting.path.contains(
                "/Application Support/RepoPrompt CE/"
            )
        )
    }

    func testCorruptPersistentStateFailsAllAdmissionsClosed() throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.retirementStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(to: fixture.retirementStateURL)
        let authority = fixture.makeAuthority()
        XCTAssertThrowsError(try authority.acquireMutationLease(paths: [fixture.linkedRoot.path])) { error in
            guard case .corruptPersistentState = error as? GitWorktreeRetirementError else {
                return XCTFail("Expected corrupt state fail-closed, got \(error)")
            }
        }
    }

    private func assertInspectionRejects(
        _ expected: GitWorktreeRetirementError,
        mutation: (RetirementGitFixture) throws -> Void
    ) async throws {
        let fixture = try RetirementGitFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let authority = fixture.makeAuthority()
        try mutation(fixture)
        let descriptor = try await fixture.linkedDescriptor(using: git, authority: authority)
        do {
            _ = try await git.inspectRetirementTarget(
                descriptor: descriptor,
                generation: 0,
                retirementAuthority: authority
            )
            XCTFail("Expected content inspection rejection")
        } catch {
            XCTAssertEqual(error as? GitWorktreeRetirementError, expected)
        }
    }

    private static func drain(activeAdmissionsBefore: Int = 0) -> GitWorktreeRetirementDrainEvidence {
        .init(
            drainedSessionIDs: [],
            activeAdmissionsBefore: activeAdmissionsBefore,
            activeAdmissionsAfter: 0,
            liveBindingsRemaining: 0,
            workspaceClaimsRemaining: 0,
            watchersRemaining: 0,
            pendingPublicationsRemaining: 0
        )
    }
}

private final class RetirementGitFixture {
    let sandbox: URL
    let mainRoot: URL
    let linkedRoot: URL
    let retirementStateURL: URL

    init() throws {
        sandbox = URL(
            fileURLWithPath: FileManager.default.temporaryDirectory.path.hasPrefix("/var/")
                ? "/private\(FileManager.default.temporaryDirectory.path)"
                : FileManager.default.temporaryDirectory.path,
            isDirectory: true
        )
        .appendingPathComponent("GitWorktreeRetirementTests-\(UUID().uuidString)", isDirectory: true)
        mainRoot = sandbox.appendingPathComponent("repo", isDirectory: true)
        linkedRoot = GitWorktreeDefaultPathPlanner.defaultContainer(forMainWorktreeRoot: mainRoot)
            .appendingPathComponent("linked", isDirectory: true)
        retirementStateURL = sandbox
            .appendingPathComponent("retirement-state", isDirectory: true)
            .appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: mainRoot, withIntermediateDirectories: true)
        try git(["init", "-q"], at: mainRoot)
        try git(["config", "user.email", "tests@example.com"], at: mainRoot)
        try git(["config", "user.name", "RepoPrompt Tests"], at: mainRoot)
        try "seed\n".write(to: mainRoot.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try "ignored.bin\n".write(
            to: mainRoot.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "seed.txt", ".gitignore"], at: mainRoot)
        try git(["commit", "-q", "-m", "seed"], at: mainRoot)
        try FileManager.default.createDirectory(
            at: linkedRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try git(["worktree", "add", "-q", "-b", "feature/retirement-test", linkedRoot.path], at: mainRoot)
    }

    func makeAuthority() -> GitWorktreeRetirementAuthority {
        GitWorktreeRetirementAuthority(persistenceURL: retirementStateURL)
    }

    func linkedDescriptor(
        using gitService: GitService,
        permit: GitWorktreeRetirementPermit? = nil,
        authority: GitWorktreeRetirementAuthority
    ) async throws -> GitWorktreeDescriptor {
        let worktrees = try await gitService.listWorktrees(
            at: mainRoot,
            retirementPermit: permit,
            retirementAuthority: authority
        )
        return try XCTUnwrap(worktrees.first(where: { !$0.isMain }))
    }

    func target(
        using gitService: GitService,
        generation: UInt64,
        permit: GitWorktreeRetirementPermit? = nil,
        authority: GitWorktreeRetirementAuthority
    ) async throws -> GitWorktreeRetirementTarget {
        let descriptor = try await linkedDescriptor(using: gitService, permit: permit, authority: authority)
        return try await gitService.inspectRetirementTarget(
            descriptor: descriptor,
            generation: generation,
            retirementPermit: permit,
            retirementAuthority: authority
        )
    }

    func authorize(
        using gitService: GitService,
        authority: GitWorktreeRetirementAuthority
    ) async throws -> GitWorktreeRetirementAuthorization {
        let preflight = try await target(using: gitService, generation: 0, authority: authority)
        let preparation = try authority.begin(preflight.candidate)
        let permit = try authority.permit(for: preparation)
        let sealed = try await target(
            using: gitService,
            generation: preparation.generation,
            permit: permit,
            authority: authority
        )
        return try authority.authorizeAfterDrain(
            preparation,
            target: sealed,
            drain: .init(
                drainedSessionIDs: [],
                activeAdmissionsBefore: 0,
                activeAdmissionsAfter: 0,
                liveBindingsRemaining: 0,
                workspaceClaimsRemaining: 0,
                watchersRemaining: 0,
                pendingPublicationsRemaining: 0
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func git(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitWorktreeRetirementTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
