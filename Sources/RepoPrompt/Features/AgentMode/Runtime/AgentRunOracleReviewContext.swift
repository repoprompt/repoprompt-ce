import Foundation

/// Why an Agent-run review source cannot be used by its delegated consumer.
///
/// These failures are carried with the run rather than failing an otherwise valid Agent start.
/// A later delegated Oracle review must surface the failure instead of packaging the child tab.
enum AgentRunOracleReviewUnavailableReason: Equatable, LocalizedError {
    case sourceCaptureFailed(String)
    case targetWorkspaceMismatch
    case parentSessionMismatch
    case targetBindingMismatch
    case targetActivationMismatch
    case pendingContextAlreadyConsumed

    var errorDescription: String? {
        switch self {
        case let .sourceCaptureFailed(message):
            "The launching tab's Oracle review context could not be captured: \(message)"
        case .targetWorkspaceMismatch:
            "The delegated Oracle review context belongs to a different workspace."
        case .parentSessionMismatch:
            "The delegated Oracle review context does not match the child Agent session's parent lineage."
        case .targetBindingMismatch:
            "The delegated Oracle review context does not match the child Agent session's exact worktree binding."
        case .targetActivationMismatch:
            "The delegated Oracle review context does not match the child Agent session's current activation."
        case .pendingContextAlreadyConsumed:
            "The delegated Oracle review context was already consumed by a different Agent run."
        }
    }
}

/// The trusted route that supplied an Agent launch's Oracle review packaging source.
///
/// Conversation parentage is intentionally not represented here. A top-level window-only
/// launch has no Agent parent, but still delegates the exact active compose tab's review package.
enum AgentRunOracleReviewLaunchRoute: Equatable {
    case runScoped
    case explicitTabContext
    case windowOnlyActiveCompose
}

/// Request-time value snapshot of the exact compose tab delegated to a child Agent run.
///
/// This is captured on the main actor before child creation and never re-resolved from mutable
/// active-window or active-tab state at Oracle time.
struct AgentRunOracleReviewLaunchSnapshot: Equatable {
    let route: AgentRunOracleReviewLaunchRoute
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let selectionRevision: UInt64
    let promptText: String
    let selection: StoredSelection
    let sourceAgentSessionID: UUID?
    let routedRunID: UUID?

    var normalizedSourceSelectionIdentities: [String] {
        AgentRunOracleReviewSelectionIdentity.normalizedSourceSelectionIdentities(selection)
    }
}

/// Canonical selected-file identity comparison for delegated Agent-run Oracle review packaging.
///
/// Selection revisions can advance because active UI state is mirrored or re-committed while the
/// frozen review capability is built. Delegated review source validation therefore compares these
/// normalized identities before treating revision-only churn as a real source change.
enum AgentRunOracleReviewSelectionIdentity {
    static func normalizedSourceSelectionIdentities(_ selection: StoredSelection) -> [String] {
        normalizedIdentities(
            selection.selectedPaths
                + selection.manualCodemapPaths
                + Array(selection.slices.keys)
        )
    }

    static func normalizedSelectedArtifactIdentities(_ selection: StoredSelection) -> [String] {
        normalizedIdentities(
            selection.selectedPaths
                + Array(selection.slices.keys)
        )
    }

    private static func normalizedIdentities(_ candidates: [String]) -> [String] {
        Array(Set(candidates.compactMap(StoredSelectionPathNormalization.standardizedPath))).sorted()
    }
}

/// Fully frozen launch source ready for the existing pending/delegated carrier lifecycle.
struct ResolvedAgentRunOracleReviewLaunchSource: Equatable {
    let snapshot: AgentRunOracleReviewLaunchSnapshot
    let source: AgentRunOracleReviewSource
}

/// Immutable source state captured from the launching tab before a child target is created.
///
/// This value is deliberately ephemeral and has no persistence conformance. The unavailable case
/// preserves trusted source identity so non-review Agent work may continue while later review calls
/// fail explicitly.
enum AgentRunOracleReviewSource: Equatable {
    struct Captured: Equatable {
        let delegationID: UUID
        let sourceTabID: UUID
        let workspaceID: UUID
        let sourceSelectionRevision: UInt64
        let promptText: String
        let selection: StoredSelection
        let lookupContext: WorkspaceLookupContext
        let reviewGitContext: FrozenPromptGitReviewContext
        let sourceAgentSessionID: UUID?
        let sourceAgentRunID: UUID?
        let sourceWorktreeBindings: [AgentSessionWorktreeBinding]
        let exactSelectedIdentities: [String]

        init(
            delegationID: UUID = UUID(),
            sourceTabID: UUID,
            workspaceID: UUID,
            sourceSelectionRevision: UInt64,
            promptText: String,
            selection: StoredSelection,
            lookupContext: WorkspaceLookupContext,
            reviewGitContext: FrozenPromptGitReviewContext,
            sourceAgentSessionID: UUID?,
            sourceAgentRunID: UUID?,
            sourceWorktreeBindings: [AgentSessionWorktreeBinding]
        ) {
            self.delegationID = delegationID
            self.sourceTabID = sourceTabID
            self.workspaceID = workspaceID
            self.sourceSelectionRevision = sourceSelectionRevision
            self.promptText = promptText
            self.selection = selection
            self.lookupContext = lookupContext
            self.reviewGitContext = reviewGitContext
            self.sourceAgentSessionID = sourceAgentSessionID
            self.sourceAgentRunID = sourceAgentRunID
            self.sourceWorktreeBindings = sourceWorktreeBindings
            exactSelectedIdentities = AgentRunOracleReviewSelectionIdentity.normalizedSelectedArtifactIdentities(selection)
        }
    }

    struct Unavailable: Equatable {
        let delegationID: UUID
        let sourceTabID: UUID
        let workspaceID: UUID
        let sourceAgentSessionID: UUID?
        let sourceAgentRunID: UUID?
        let reason: AgentRunOracleReviewUnavailableReason
    }

    case captured(Captured)
    case unavailable(Unavailable)

    var delegationID: UUID {
        switch self {
        case let .captured(source): source.delegationID
        case let .unavailable(source): source.delegationID
        }
    }

    var sourceTabID: UUID {
        switch self {
        case let .captured(source): source.sourceTabID
        case let .unavailable(source): source.sourceTabID
        }
    }

    var workspaceID: UUID {
        switch self {
        case let .captured(source): source.workspaceID
        case let .unavailable(source): source.workspaceID
        }
    }

    var sourceAgentSessionID: UUID? {
        switch self {
        case let .captured(source): source.sourceAgentSessionID
        case let .unavailable(source): source.sourceAgentSessionID
        }
    }
}

/// A captured source staged for one exact child control activation. It has no run identity and
/// therefore cannot yet be consumed by Oracle. Source packaging and target conversation bindings
/// are independent checkout domains; only the frozen target snapshot must match the later consumer.
struct AgentRunOracleReviewTargetSnapshot: Equatable {
    let tabID: UUID
    let workspaceID: UUID
    let agentSessionID: UUID
    let activationID: UUID
    let expectedParentSessionID: UUID?
    let worktreeBindings: [AgentSessionWorktreeBinding]
    let validationFailure: AgentRunOracleReviewUnavailableReason?

    var boundCheckouts: [FrozenBoundCheckoutIdentity] {
        worktreeBindings.map(FrozenBoundCheckoutIdentity.init(binding:))
    }
}

struct PendingAgentRunOracleReviewContext: Equatable {
    let source: AgentRunOracleReviewSource
    let target: AgentRunOracleReviewTargetSnapshot
}

/// The only delegated form that may be used for Oracle review packaging.
struct DelegatedAgentRunOracleReviewContext: Equatable {
    let source: AgentRunOracleReviewSource
    let target: AgentRunOracleReviewTargetSnapshot
    let targetRunID: UUID

    var capturedSource: AgentRunOracleReviewSource.Captured? {
        guard target.validationFailure == nil, case let .captured(source) = source else { return nil }
        return source
    }

    var unavailableReason: AgentRunOracleReviewUnavailableReason? {
        if let validationFailure = target.validationFailure { return validationFailure }
        guard case let .unavailable(source) = source else { return nil }
        return source.reason
    }
}
