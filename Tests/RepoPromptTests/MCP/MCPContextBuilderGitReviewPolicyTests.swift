import Foundation
@testable import RepoPromptApp
import RepoPromptVCS
import RepoPromptWorkspaceCore
import XCTest

@MainActor
final class MCPContextBuilderGitReviewPolicyTests: XCTestCase {
    private func deferredResolution() -> ContextBuilderReviewTargetResolution {
        .deferred(ContextBuilderDeferredReviewAuthority(
            workspaceID: UUID(),
            tabID: UUID(),
            initialSelectionRevision: 1,
            lookupContext: .visibleWorkspace,
            reviewGitContext: FrozenPromptGitReviewContext(
                artifactCapability: nil,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            )
        ))
    }

    private func admitDeferred(
        hasExplicitSelector: Bool,
        requestsArtifactPublication: Bool
    ) async throws -> MCPContextBuilderGitReviewAdmission {
        try await admit(
            deferredResolution(),
            hasExplicitSelector: hasExplicitSelector,
            requestsArtifactPublication: requestsArtifactPublication
        )
    }

    private func admit(
        _ resolution: ContextBuilderReviewTargetResolution,
        hasExplicitSelector: Bool,
        requestsArtifactPublication: Bool
    ) async throws -> MCPContextBuilderGitReviewAdmission {
        try await MCPContextBuilderGitReviewPolicy().admit(
            resolution: resolution,
            hasExplicitSelector: hasExplicitSelector,
            requestsArtifactPublication: requestsArtifactPublication,
            operation: .diff,
            allRepositories: [],
            store: WorkspaceFileContextStore()
        )
    }

    func testDeferredDiscoveryAdmitsReadOnlyExplicitRepositoryInspectionWithoutElectingTarget() async throws {
        let admission = try await admitDeferred(hasExplicitSelector: true, requestsArtifactPublication: false)

        XCTAssertNil(admission.target)
        XCTAssertNil(admission.publicationFence)
    }

    func testDeferredDiscoveryRefusalsTellAgentHowToInspectDiffReadOnly() async {
        for (hasExplicitSelector, requestsArtifactPublication) in [(false, false), (false, true), (true, true)] {
            do {
                _ = try await admitDeferred(
                    hasExplicitSelector: hasExplicitSelector,
                    requestsArtifactPublication: requestsArtifactPublication
                )
                XCTFail("Deferred admission must refuse selector=\(hasExplicitSelector) artifacts=\(requestsArtifactPublication)")
            } catch let error as MCPContextBuilderGitReviewPolicyError {
                XCTAssertEqual(error, .targetDeferred)
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("repo_root"), message)
                XCTAssertTrue(message.contains("artifacts"), message)
                XCTAssertTrue(message.contains("manage_selection"), message)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUnelectedTargetsShareTheExplicitReadOnlyGitRestriction() async throws {
        let unavailable = ContextBuilderReviewTargetResolution.unavailable(.nonGitSelection(count: 1))
        XCTAssertTrue(deferredResolution().restrictsGitToExplicitReadOnly)
        XCTAssertTrue(unavailable.restrictsGitToExplicitReadOnly)

        let admission = try await admit(unavailable, hasExplicitSelector: true, requestsArtifactPublication: false)
        XCTAssertNil(admission.target)
        XCTAssertNil(admission.publicationFence)

        for (hasExplicitSelector, requestsArtifactPublication) in [(false, false), (true, true)] {
            do {
                _ = try await admit(
                    unavailable,
                    hasExplicitSelector: hasExplicitSelector,
                    requestsArtifactPublication: requestsArtifactPublication
                )
                XCTFail("Unavailable admission must refuse selector=\(hasExplicitSelector) artifacts=\(requestsArtifactPublication)")
            } catch let error as MCPContextBuilderGitReviewPolicyError {
                XCTAssertEqual(error, .targetUnavailable(.nonGitSelection(count: 1)))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAvailableFrozenTargetSuppliesRelativeDefaultOrRefusesInsteadOfAmbientElection() throws {
        let repo = GitRepoDescriptor(rootURL: URL(fileURLWithPath: "/tmp/frozen-review-target"))
        let target = Self.target(primaryCheckout: repo)
        let available = MCPContextBuilderGitReviewAdmission(
            target: target, implicitRepositories: nil, preferredDefaultRepository: repo, publicationFence: nil
        )
        XCTAssertEqual(try MCPGitToolProvider.frozenDefaultRepository(for: available), repo)

        let identityLost = MCPContextBuilderGitReviewAdmission(
            target: target, implicitRepositories: nil, preferredDefaultRepository: nil, publicationFence: nil
        )
        XCTAssertThrowsError(try MCPGitToolProvider.frozenDefaultRepository(for: identityLost)) { error in
            XCTAssertEqual(error as? MCPContextBuilderGitReviewPolicyError, .targetUnavailable(.checkoutIdentityChanged))
        }
    }

    func testUnelectedOrAbsentTargetsLeaveRelativeSelectorsToAmbientElection() async throws {
        let deferred = try await admitDeferred(hasExplicitSelector: true, requestsArtifactPublication: false)
        XCTAssertNil(deferred.preferredDefaultRepository)
        XCTAssertNil(try MCPGitToolProvider.frozenDefaultRepository(for: deferred))

        let unavailable = try await admit(
            .unavailable(.nonGitSelection(count: 1)), hasExplicitSelector: true, requestsArtifactPublication: false
        )
        XCTAssertNil(try MCPGitToolProvider.frozenDefaultRepository(for: unavailable))

        let generic = try await MCPContextBuilderGitReviewPolicy().admit(
            resolution: nil,
            hasExplicitSelector: false,
            requestsArtifactPublication: false,
            operation: .status,
            allRepositories: [],
            store: WorkspaceFileContextStore()
        )
        XCTAssertNil(try MCPGitToolProvider.frozenDefaultRepository(for: generic))
    }

    private static func target(primaryCheckout repo: GitRepoDescriptor) -> ContextBuilderReviewTarget {
        let root = WorkspaceRootRef(id: UUID(), name: repo.displayName, fullPath: repo.rootPath)
        let checkout = ContextBuilderReviewCheckoutTarget(
            contributingRoots: [ContextBuilderReviewRootAuthority(
                logicalWorkspaceRoot: root,
                physicalWorkspaceRoot: root,
                physicalWorkspaceRootKind: .primaryWorkspace,
                sessionRootAuthorization: nil
            )],
            checkoutRootPath: repo.rootPath,
            repoKey: repo.repoKey,
            repositoryID: "gitrepo_frozen",
            worktreeID: "wt_frozen",
            kind: .canonical
        )
        return ContextBuilderReviewTarget(
            workspaceID: UUID(),
            tabID: UUID(),
            sourceSelectionRevision: 1,
            initialOrdinarySelectionIdentities: [],
            initialSelectedArtifactIdentities: [],
            checkouts: [checkout],
            primaryCheckout: checkout,
            artifactCapability: nil,
            displayContext: ReviewGitDisplayContext(roots: [])
        )
    }
}
