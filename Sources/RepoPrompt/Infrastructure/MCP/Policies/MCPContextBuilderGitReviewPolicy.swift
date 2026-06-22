import Foundation
import RepoPromptCore

enum MCPContextBuilderGitReviewOperation: String {
    case status, diff, log, show, blame
}

struct MCPContextBuilderGitPublicationFence {
    let target: ContextBuilderReviewTarget
}

struct MCPContextBuilderGitReviewAdmission {
    let target: ContextBuilderReviewTarget?
    let implicitRepositories: [GitRepoDescriptor]?
    let preferredDefaultRepository: GitRepoDescriptor?
    let publicationFence: MCPContextBuilderGitPublicationFence?
}

struct MCPContextBuilderGitPublishedOutcome {
    let repository: GitRepoDescriptor
    let manifest: GitDiffSnapshotManifest?
    let hasPublishedArtifacts: Bool
}

enum MCPContextBuilderGitReviewPolicyError: Equatable, LocalizedError {
    case targetDeferred
    case targetUnavailable(ContextBuilderReviewTargetUnavailableReason)
    case publicationOutsideFrozenTarget
    case implicitMultiRepositoryOperation
    case publishedRepositoryMismatch
    case incompletePublishedMetadata
    case publishedOutcomeMismatch
    case publishedCheckoutMismatch

    var errorDescription: String? {
        switch self {
        case .targetDeferred:
            "Context Builder review target election is deferred until discovery commits its final selection."
        case let .targetUnavailable(reason):
            reason.localizedDescription
        case .publicationOutsideFrozenTarget:
            "Context Builder Git artifacts may only be published for the frozen selected repository target."
        case .implicitMultiRepositoryOperation:
            "The frozen Context Builder selection owns multiple repositories; specify repo_root or repo_key for this operation."
        case .publishedRepositoryMismatch:
            "Published Git artifact repository did not match the frozen Context Builder target."
        case .incompletePublishedMetadata:
            "Published Git artifact metadata was incomplete for the frozen Context Builder target."
        case .publishedOutcomeMismatch:
            "Published Git artifact outcomes did not match the frozen Context Builder target."
        case .publishedCheckoutMismatch:
            "Published Git artifact checkout did not match its requested frozen Context Builder target."
        }
    }
}

struct MCPContextBuilderGitReviewPolicy {
    func admit(
        resolution: ContextBuilderReviewTargetResolution?,
        hasExplicitSelector: Bool,
        requestsArtifactPublication: Bool,
        operation: MCPContextBuilderGitReviewOperation,
        allRepositories: [GitRepoDescriptor],
        query: WorkspaceSessionQueryCapability?
    ) async throws -> MCPContextBuilderGitReviewAdmission {
        guard let resolution else {
            return MCPContextBuilderGitReviewAdmission(
                target: nil,
                implicitRepositories: nil,
                preferredDefaultRepository: nil,
                publicationFence: nil
            )
        }
        guard let query else {
            throw MCPContextBuilderGitReviewPolicyError.targetUnavailable(.staleWorkspaceRoot)
        }

        let target: ContextBuilderReviewTarget
        switch resolution {
        case let .available(availableTarget):
            if let reason = await ContextBuilderReviewTargetResolver().revalidate(
                availableTarget,
                query: query
            ) {
                throw MCPContextBuilderGitReviewPolicyError.targetUnavailable(reason)
            }
            target = availableTarget
        case .deferred:
            guard hasExplicitSelector, !requestsArtifactPublication else {
                throw MCPContextBuilderGitReviewPolicyError.targetDeferred
            }
            return MCPContextBuilderGitReviewAdmission(
                target: nil,
                implicitRepositories: nil,
                preferredDefaultRepository: nil,
                publicationFence: nil
            )
        case let .unavailable(reason):
            guard hasExplicitSelector, !requestsArtifactPublication else {
                throw MCPContextBuilderGitReviewPolicyError.targetUnavailable(reason)
            }
            return MCPContextBuilderGitReviewAdmission(
                target: nil,
                implicitRepositories: nil,
                preferredDefaultRepository: nil,
                publicationFence: nil
            )
        }

        let preferredDefaultRepository = allRepositories.first(where: target.primaryCheckout.matches)
        let implicitRepositories: [GitRepoDescriptor]?
        if hasExplicitSelector {
            implicitRepositories = nil
        } else {
            guard let repositories = target.repositories(from: allRepositories), !repositories.isEmpty else {
                throw MCPContextBuilderGitReviewPolicyError.targetUnavailable(.checkoutIdentityChanged)
            }
            if repositories.count > 1, operation != .status, operation != .diff {
                throw MCPContextBuilderGitReviewPolicyError.implicitMultiRepositoryOperation
            }
            implicitRepositories = repositories
        }

        return MCPContextBuilderGitReviewAdmission(
            target: target,
            implicitRepositories: implicitRepositories,
            preferredDefaultRepository: preferredDefaultRepository,
            publicationFence: requestsArtifactPublication
                ? MCPContextBuilderGitPublicationFence(target: target)
                : nil
        )
    }

    func validatePublicationRepositories(
        _ repositories: [GitRepoDescriptor],
        fence: MCPContextBuilderGitPublicationFence
    ) throws {
        guard repositories.allSatisfy(fence.target.contains) else {
            throw MCPContextBuilderGitReviewPolicyError.publicationOutsideFrozenTarget
        }
    }

    func validatePublishedOutcomes(
        _ outcomes: [MCPContextBuilderGitPublishedOutcome],
        publishedArtifactSetCount: Int,
        fence: MCPContextBuilderGitPublicationFence,
        query: WorkspaceSessionQueryCapability
    ) async throws {
        var matchedTargets: [ContextBuilderReviewCheckoutTarget] = []
        for outcome in outcomes {
            switch (outcome.manifest, outcome.hasPublishedArtifacts) {
            case (nil, false):
                continue
            case let (.some(manifest), true):
                guard let target = fence.target.checkout(matching: outcome.repository) else {
                    throw MCPContextBuilderGitReviewPolicyError.publishedRepositoryMismatch
                }
                guard target.matches(manifest) else {
                    throw MCPContextBuilderGitReviewPolicyError.publishedCheckoutMismatch
                }
                matchedTargets.append(target)
            case (nil, true), (.some, false):
                throw MCPContextBuilderGitReviewPolicyError.incompletePublishedMetadata
            }
        }

        guard matchedTargets.count == publishedArtifactSetCount else {
            throw MCPContextBuilderGitReviewPolicyError.publishedOutcomeMismatch
        }
        guard Set(matchedTargets.map(\.identityKey)).count == matchedTargets.count else {
            throw MCPContextBuilderGitReviewPolicyError.publishedCheckoutMismatch
        }
        if let reason = await ContextBuilderReviewTargetResolver().revalidate(fence.target, query: query) {
            throw MCPContextBuilderGitReviewPolicyError.targetUnavailable(reason)
        }
    }
}
