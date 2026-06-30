import Foundation

actor WorkspaceRootMaterializationHintEvaluator {
    static let shared = WorkspaceRootMaterializationHintEvaluator()

    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared
    ) {
        self.gitService = gitService
        self.authority = authority
    }

    func observe(
        _ hint: WorkspaceRootMaterializationHint?,
        observationEnabled: Bool
    ) async -> WorkspaceRootMaterializationHintObservation {
        guard observationEnabled else { return .observationDisabled }
        guard let hint else { return .fallback(.noReceipt) }
        if let reason = hint.validationFallbackReason ?? hint.creationReceipt.fallbackReason() {
            return .fallback(reason)
        }
        guard hint.orderedCompatibleBaseCandidates.contains(hint.creationReceipt.parentSnapshotIdentity) else {
            return .fallback(.baseUnavailable)
        }
        guard await authority.reusableSnapshot(
            identity: hint.creationReceipt.parentSnapshotIdentity,
            expectedCompatibilityKey: hint.creationReceipt.parentCompatibilityKey
        ) != nil else {
            return .fallback(.baseEvicted)
        }

        do {
            let current = try await gitService.generationFencedAuthoritySnapshot(
                layout: hint.creationReceipt.targetLayout,
                prefix: hint.creationReceipt.repositoryRelativeRootPrefix
            )
            let receiptAuthority = hint.creationReceipt.targetAuthorityAfter
            guard current.repositoryKey == receiptAuthority.repositoryKey,
                  current.repositoryNamespace == receiptAuthority.repositoryNamespace,
                  current.objectFormat == receiptAuthority.objectFormat,
                  current.headCommitOID == receiptAuthority.headCommitOID,
                  current.treeOID == receiptAuthority.treeOID,
                  current.repositoryRelativeRootPrefix == receiptAuthority.repositoryRelativeRootPrefix,
                  current.repositoryBindingEpoch == receiptAuthority.repositoryBindingEpoch,
                  current.worktreeBindingEpoch == receiptAuthority.worktreeBindingEpoch,
                  current.layoutGeneration == receiptAuthority.layoutGeneration,
                  current.policyIdentity == receiptAuthority.policyIdentity
            else {
                return .fallback(.authorityUnstable)
            }
            let currentCompatibility = WorkspaceRootSeedCompatibilityKey(authority: current)
            let compatibilityEvaluation = currentCompatibility.deltaCompatibilityEvaluation(
                with: hint.creationReceipt.parentCompatibilityKey,
                source: .hintEvaluator
            )
            let currentSearchABIReached = compatibilityEvaluation.decision == .compatible
            let currentSearchABIMatched = currentSearchABIReached
                ? currentCompatibility.searchABI == .current
                : nil
            let compatibilityFallback: WorkspaceRootSeedFallbackReason? =
                compatibilityEvaluation.decision == .compatible && currentSearchABIMatched == true
                    ? nil
                    : .compatibilityMismatch
            #if DEBUG
                WorktreeStartupInstrumentation.recordDeltaCompatibilityEvaluation(
                    correlationID: hint.correlationID,
                    evaluation: compatibilityEvaluation,
                    policyCanonicalizationComparison: GitWorkspacePolicyCanonicalizationDiagnostics.comparison(
                        base: hint.creationReceipt.parentCompatibilityKey.policyIdentity,
                        target: hint.creationReceipt.targetAuthorityAfter.policyIdentity
                    ),
                    exactSnapshotLookupReached: true,
                    exactSnapshotLookupPassed: true,
                    targetAuthorityComparisonReached: true,
                    targetAuthorityComparisonPassed: true,
                    currentSearchABIReached: currentSearchABIReached,
                    currentSearchABIMatched: currentSearchABIMatched,
                    catalogPolicyComparisonReached: false,
                    catalogPolicyMatched: nil,
                    terminalFallback: compatibilityFallback
                )
            #endif
            guard compatibilityFallback == nil else {
                return .fallback(.compatibilityMismatch)
            }
            return .eligible(hint.creationReceipt.parentSnapshotIdentity)
        } catch let reason as GitWorkspaceAuthorityUnavailableReason {
            switch reason {
            case .mutationInProgress, .metadataEventPending:
                return .fallback(.authorityChanging)
            case .noSnapshot, .monitorCoverageUnavailable, .superseded,
                 .invalidatedDuringCollection, .collectionScopeMismatch:
                return .fallback(.authorityUnstable)
            }
        } catch let error as GitWorktreeInitializationError {
            switch error.reason {
            case .timeout:
                return .fallback(.gitTimeout)
            case .cappedOutput, .recordLimitExceeded, .pathLimitExceeded:
                return .fallback(.gitCappedOutput)
            case .malformedOutput, .invalidRootPrefix:
                return .fallback(.gitMalformedOutput)
            case .gitError:
                return .fallback(.gitError)
            case .cancelled:
                return .fallback(.cancellation)
            }
        } catch {
            return .fallback(.gitError)
        }
    }
}
