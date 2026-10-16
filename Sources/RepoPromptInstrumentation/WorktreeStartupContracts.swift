import Foundation

package enum WorktreeStartupServingControl: Equatable, Sendable {
    case automatic
    case forceFullCrawl
}

package struct WorktreeStartupFeatureFlags: Equatable, Sendable {
    package static let observeDefaultsKey = "observeDiffSeededWorktreeStartup"
    package static let serveDefaultsKey = "serveDiffSeededWorktreeStartup"

    package let observeDiffSeededWorktreeStartup: Bool
    package let serveDiffSeededWorktreeStartup: Bool

    package init(
        observeDiffSeededWorktreeStartup: Bool = false,
        serveDiffSeededWorktreeStartup: Bool = false
    ) {
        self.observeDiffSeededWorktreeStartup = observeDiffSeededWorktreeStartup
        // Serving can never be active without observation authority.
        self.serveDiffSeededWorktreeStartup = serveDiffSeededWorktreeStartup
            && observeDiffSeededWorktreeStartup
    }
}

package struct WorktreeStartupContext: Equatable, Sendable {
    package let agentSessionID: UUID
    package let correlationID: UUID
    package let flags: WorktreeStartupFeatureFlags
    package let servingControl: WorktreeStartupServingControl

    package init(
        rawAgentSessionID: UUID,
        correlationID: UUID,
        flags: WorktreeStartupFeatureFlags,
        servingControl: WorktreeStartupServingControl
    ) {
        agentSessionID = rawAgentSessionID
        self.correlationID = correlationID
        self.flags = flags
        self.servingControl = servingControl
    }
}

package enum WorkspaceRootStartupRoute: String, Equatable, Sendable {
    case fullCrawl
    case diffSeedObservation
    case diffSeedServing
}

package enum WorkspaceRootSeedFallbackReason: String, Equatable, Sendable {
    case noReceipt
    case expiredReceipt
    case unsupportedDestination
    case baseUnavailable
    case baseEvicted
    case compatibilityMismatch
    case authorityChanging
    case authorityUnstable
    case gitTimeout
    case gitError
    case gitMalformedOutput
    case gitCappedOutput
    case gitResourceUnavailable
    case gitEvidenceCorrupt
    case namespaceEvidenceCorrupt
    case targetEvidenceIncoherent
    case evidenceResourceUnavailable
    case evidenceIOFailure
    case evidenceWaitDeadlineExceeded
    case witnessGap
    case witnessDrop
    case witnessOverflow
    case includeCopyFailure
    case unknownCopiedPath
    case changedIgnoreAuthority
    case conflictOrUnmergedIndex
    case assumeUnchangedIndexEntry
    case sparseCheckout
    case submoduleOrNestedRepository
    case symlinkOrSpecialTopology
    case unexplainedFilesystemEntry
    case projectedSearchMismatch
    case ownerSuperseded
    case serviceIngressGenerationChanged
    case watcherRecoveryUncertain
    case watcherActivationFailure
    case watcherDrop
    case watcherOverflow
    case pendingIngressSequenceGap
    case seededShardPreparationFailure
    case cancellation
}

package enum WorktreeStartupPhase: String, Equatable, Sendable {
    case agentRunStarted
    case worktreePreparationStarted
    case bindingTransitionStarted
    case rootLoadStarted
    case shadowVerified
    case seedWatcherAttached
    case seedReplayFenced
    case seedReadyForCommit
    case seedPublished
    case seedFallback
    case rootReady
    case providerStart
    #if DEBUG
        case firstBenchmarkSearchStarted
        case firstBenchmarkSearchCompleted
        case firstBenchmarkReadStarted
        case firstBenchmarkReadCompleted
        case firstBenchmarkCodemapStarted
        case firstBenchmarkCodemapCompleted
        case warmBenchmarkCodemapStarted
        case warmBenchmarkCodemapCompleted
        case passiveBenchmarkTreeStarted
        case passiveBenchmarkTreeCompleted
        case benchmarkSelectionStarted
        case benchmarkSelectionCompleted
    #endif
    case failed
}

/// Bounded phase record. The app owns storage, timestamps, and log output.
package struct WorktreeStartupPhaseEvent: Equatable, Sendable {
    package let phase: WorktreeStartupPhase
    package let context: WorktreeStartupContext
    package let route: WorkspaceRootStartupRoute?
    package let fallback: WorkspaceRootSeedFallbackReason?

    package init(
        phase: WorktreeStartupPhase,
        context: WorktreeStartupContext,
        route: WorkspaceRootStartupRoute? = nil,
        fallback: WorkspaceRootSeedFallbackReason? = nil
    ) {
        self.phase = phase
        self.context = context
        self.route = route
        self.fallback = fallback
    }
}

package protocol WorktreeStartupPhaseEventSink: Sendable {
    func record(_ event: WorktreeStartupPhaseEvent)
}

package struct NoopWorktreeStartupPhaseEventSink: WorktreeStartupPhaseEventSink {
    package init() {}

    package func record(_: WorktreeStartupPhaseEvent) {}
}

package enum GitProcessCommandFamily: String, Equatable, Sendable {
    case treeResolution
    case treeInventory
    case treeDelta
    case indexManifest
    case status
    case authorityMetadata
    case codemapAuthority
    case repositoryRead
    case mutation
}
