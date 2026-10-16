import Foundation
@testable import RepoPromptApp
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
}
