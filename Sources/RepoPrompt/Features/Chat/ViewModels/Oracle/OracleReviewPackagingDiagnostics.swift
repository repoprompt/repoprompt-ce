import CryptoKit
import Foundation

enum OracleSendOrigin: String {
    case askOracle
    case oracleSend
    case compatibility
}

#if DEBUG
    struct OracleReviewPackagingContentFingerprint: Equatable {
        enum State: String {
            case nilValue
            case empty
            case value
        }

        let state: State
        let byteCount: Int?
        let sha256: String?
    }

    struct OracleReviewPackagingArtifactDispositionSnapshot: Equatable {
        enum Status: String {
            case authorized
            case rejected
        }

        let pathHash: String
        let status: Status
        let kind: String?
        let detail: String
    }

    struct OracleReviewPackagingCapabilitySummary: Equatable {
        let workspaceID: UUID
        let gitDataRootID: UUID
        let gitDataRootPathHash: String
        let creatorTabID: UUID
        let sessionID: UUID?
        let boundRepositoryIDs: [String]
        let boundWorktreeIDs: [String]
        let boundPhysicalRootPathHashes: [String]
        let canonicalWorkspaceRootPathHashes: [String]
    }

    struct OracleReviewPackagingFrozenSnapshot: Equatable {
        let origin: OracleSendOrigin
        let conversationTabID: UUID
        let conversationWorkspaceID: UUID?
        let conversationAgentSessionID: UUID?
        let conversationAgentRunID: UUID?
        let sourceTabID: UUID
        let sourceWorkspaceID: UUID?
        let sourceSelectionRevision: UInt64
        let sourceAgentSessionID: UUID?
        let sourceAgentRunID: UUID?
        let delegationID: UUID?
        let selectedIdentityHashes: [String]
        let capability: OracleReviewPackagingCapabilitySummary?
    }

    struct OracleReviewPackagingPreassemblySnapshot: Equatable {
        enum ResolutionSource: String {
            case none
            case selectedArtifact
            case automatic
            case complete
        }

        let mode: String
        let modelName: String?
        let chatPresetID: UUID
        let chatPresetName: String
        let gitInclusion: String
        let selectedArtifactPolicy: String
        let disabledPromptSections: [String]
        let selectedIdentityHashes: [String]
        let artifactDispositions: [OracleReviewPackagingArtifactDispositionSnapshot]
        let resolutionSource: ResolutionSource
        let gitDiff: OracleReviewPackagingContentFingerprint
        let fileBlocks: [OracleReviewPackagingContentFingerprint]
    }

    struct OracleReviewPackagingSubmissionSnapshot: Equatable {
        let gitDiff: OracleReviewPackagingContentFingerprint
        let fileBlocks: [OracleReviewPackagingContentFingerprint]
    }

    enum OracleReviewPackagingTraceEvent: Equatable {
        case contextFrozen(
            correlationID: UUID,
            snapshot: OracleReviewPackagingFrozenSnapshot
        )
        case preassemblyCompleted(
            correlationID: UUID,
            snapshot: OracleReviewPackagingPreassemblySnapshot
        )
        case messageSubmitted(
            correlationID: UUID,
            snapshot: OracleReviewPackagingSubmissionSnapshot
        )
        case failedOrCancelled(correlationID: UUID, errorType: String)
    }

    struct OracleReviewPackagingTraceContext {
        typealias Observer = @MainActor @Sendable (OracleReviewPackagingTraceEvent) -> Void

        let correlationID: UUID
        let frozenSnapshot: OracleReviewPackagingFrozenSnapshot
        let observer: Observer
    }

    enum OracleReviewPackagingDiagnostics {
        @TaskLocal static var current: OracleReviewPackagingTraceContext?

        @MainActor
        static func makeTraceContext(
            tabContext: OracleViewModel.OracleSendTabContext?,
            observer: OracleReviewPackagingTraceContext.Observer?
        ) -> OracleReviewPackagingTraceContext? {
            guard let tabContext, let observer else { return nil }
            let packaging = tabContext.packaging
            let capability = packaging.reviewGitContext.artifactCapability.map {
                OracleReviewPackagingCapabilitySummary(
                    workspaceID: $0.workspaceID,
                    gitDataRootID: $0.gitDataRoot.id,
                    gitDataRootPathHash: identityHash($0.gitDataRoot.standardizedFullPath),
                    creatorTabID: $0.creatorTabID,
                    sessionID: $0.sessionID,
                    boundRepositoryIDs: $0.boundCheckouts.map(\.repositoryID),
                    boundWorktreeIDs: $0.boundCheckouts.map(\.worktreeID),
                    boundPhysicalRootPathHashes: $0.boundCheckouts.map { identityHash($0.physicalWorktreeRootPath) },
                    canonicalWorkspaceRootPathHashes: $0.canonicalWorkspaceRootPaths.map(identityHash)
                )
            }
            let delegationID: UUID? = if case let .delegated(id) = packaging.provenance {
                id
            } else {
                nil
            }
            let snapshot = OracleReviewPackagingFrozenSnapshot(
                origin: tabContext.origin,
                conversationTabID: tabContext.tabID,
                conversationWorkspaceID: tabContext.workspaceID,
                conversationAgentSessionID: tabContext.agentModeSessionID,
                conversationAgentRunID: tabContext.agentModeRunID,
                sourceTabID: packaging.sourceTabID,
                sourceWorkspaceID: packaging.sourceWorkspaceID,
                sourceSelectionRevision: packaging.sourceSelectionRevision,
                sourceAgentSessionID: packaging.sourceAgentSessionID,
                sourceAgentRunID: packaging.sourceAgentRunID,
                delegationID: delegationID,
                selectedIdentityHashes: normalizedSelectionIdentityHashes(packaging.selection),
                capability: capability
            )
            return OracleReviewPackagingTraceContext(
                correlationID: UUID(),
                frozenSnapshot: snapshot,
                observer: observer
            )
        }

        @MainActor
        static func withTrace<T>(
            _ trace: OracleReviewPackagingTraceContext?,
            operation: () async throws -> T
        ) async rethrows -> T {
            guard let trace else { return try await operation() }
            return try await $current.withValue(trace) {
                trace.observer(.contextFrozen(
                    correlationID: trace.correlationID,
                    snapshot: trace.frozenSnapshot
                ))
                return try await operation()
            }
        }

        @MainActor
        static func recordPreassembly(
            mode: PromptViewModel.PlanActMode,
            model: AIModel?,
            chatPreset: ChatPreset,
            config: PromptContextResolved,
            selectedArtifactPolicy: SelectedGitDiffArtifactPolicy,
            logicalSelection: StoredSelection,
            preassembly: PromptContextPreAssemblyResult,
            message: AIMessage,
            disabledPromptSections: Set<PromptSection>
        ) {
            guard let trace = current else { return }
            let snapshot = OracleReviewPackagingPreassemblySnapshot(
                mode: mode.rawValue,
                modelName: model?.displayName,
                chatPresetID: chatPreset.id,
                chatPresetName: chatPreset.name,
                gitInclusion: config.gitInclusion.rawValue,
                selectedArtifactPolicy: String(describing: selectedArtifactPolicy),
                disabledPromptSections: disabledPromptSections.map { String(describing: $0) }.sorted(),
                selectedIdentityHashes: normalizedSelectionIdentityHashes(logicalSelection),
                artifactDispositions: preassembly.selectedGitArtifactDispositions.map(dispositionSnapshot),
                resolutionSource: resolutionSource(preassembly.gitDiffResolution),
                gitDiff: fingerprint(message.gitDiff),
                fileBlocks: message.fileBlocks.map { fingerprint($0) }
            )
            trace.observer(.preassemblyCompleted(
                correlationID: trace.correlationID,
                snapshot: snapshot
            ))
        }

        @MainActor
        static func recordSubmission(_ message: AIMessage) {
            guard let trace = current else { return }
            trace.observer(.messageSubmitted(
                correlationID: trace.correlationID,
                snapshot: OracleReviewPackagingSubmissionSnapshot(
                    gitDiff: fingerprint(message.gitDiff),
                    fileBlocks: message.fileBlocks.map { fingerprint($0) }
                )
            ))
        }

        @MainActor
        static func recordFailure(_ error: Error) {
            guard let trace = current else { return }
            trace.observer(.failedOrCancelled(
                correlationID: trace.correlationID,
                errorType: String(reflecting: type(of: error))
            ))
        }

        static func fingerprint(_ content: String?) -> OracleReviewPackagingContentFingerprint {
            guard let content else {
                return OracleReviewPackagingContentFingerprint(
                    state: .nilValue,
                    byteCount: nil,
                    sha256: nil
                )
            }
            let data = Data(content.utf8)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return OracleReviewPackagingContentFingerprint(
                state: data.isEmpty ? .empty : .value,
                byteCount: data.count,
                sha256: digest
            )
        }

        static func identityHash(_ identity: String) -> String {
            let normalized = StoredSelectionPathNormalization.standardizedPath(identity) ?? identity
            return SHA256.hash(data: Data(normalized.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }

        private static func normalizedSelectionIdentityHashes(_ selection: StoredSelection) -> [String] {
            selection.selectedPaths.map(identityHash)
        }

        private static func dispositionSnapshot(
            _ disposition: SelectedGitArtifactDisposition
        ) -> OracleReviewPackagingArtifactDispositionSnapshot {
            switch disposition {
            case let .authorized(path, kind, readability):
                OracleReviewPackagingArtifactDispositionSnapshot(
                    pathHash: identityHash(path),
                    status: .authorized,
                    kind: kind.rawValue,
                    detail: readability == .readable ? "readable" : "empty"
                )
            case let .rejected(path, reason):
                OracleReviewPackagingArtifactDispositionSnapshot(
                    pathHash: identityHash(path),
                    status: .rejected,
                    kind: nil,
                    detail: reason.diagnosticLabel
                )
            }
        }

        private static func resolutionSource(
            _ resolution: PromptGitDiffResolution
        ) -> OracleReviewPackagingPreassemblySnapshot.ResolutionSource {
            switch resolution {
            case .none: .none
            case .selectedArtifact: .selectedArtifact
            case .automatic: .automatic
            case .complete: .complete
            }
        }
    }
#endif
