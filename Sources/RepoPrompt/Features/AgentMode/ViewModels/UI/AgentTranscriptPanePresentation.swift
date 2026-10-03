import Foundation

/// What the Agent transcript pane should present for its current target.
enum AgentTranscriptPanePresentation: Equatable {
    case transcript
    case runningOrWaiting
    case restoring
    case welcome
    case unavailable(UnavailableReason, retry: AgentTranscriptRetryTarget?)

    enum UnavailableReason: Equatable {
        case missing
        case loadFailed
        case interrupted
        case persistenceSuppressed
        case workspaceUnavailable

        /// User-facing explanation; never raw paths or error descriptions (§4.5).
        var message: String {
            switch self {
            case .missing: "This saved conversation could not be found."
            case .loadFailed: "This saved conversation could not be loaded."
            case .interrupted: "Conversation restoration was interrupted."
            case .persistenceSuppressed: "Saved conversations are unavailable while session persistence is disabled."
            case .workspaceUnavailable: "This conversation\u{2019}s workspace is unavailable."
            }
        }
    }

    /// Fallback copy for `.runningOrWaiting` when no existing run status or interaction card is visible
    /// (§4.5); never duplicates an existing indicator.
    static func runningOrWaitingFallback(
        isWaitingForInput: Bool,
        isRunIndicatorVisible: Bool,
        isInteractionCardVisible: Bool
    ) -> String? {
        guard !isRunIndicatorVisible, !isInteractionCardVisible else { return nil }
        return isWaitingForInput ? "Waiting for input\u{2026}" : "Starting\u{2026}"
    }

    struct Input: Equatable {
        let target: AgentTranscriptPaneTarget
        let content: AgentTranscriptPaneContentFacts?
        /// Scope of the session with a current run or pending interaction.
        let liveRunScope: AgentSessionPresentationScope?
        /// Current activation's workspace/binding discovery has not completed.
        let isDiscoveryPending: Bool
        /// The persisted-load attempt the owner currently considers live or latest for this scope.
        let currentAttemptID: UUID?
        let record: AgentSessionPresentationRecord?
    }

    /// Pure classifier: no I/O, tasks, clocks or mutable authority.
    static func resolve(_ input: Input) -> AgentTranscriptPanePresentation? {
        let scope = input.target.scope
        if let scope, scope.tabID != input.target.tabID {
            return nil
        }
        // A materialized scope is current only under the installed owner it names; awaiting-owner and
        // no-workspace targets authorize no scope (outgoing or same-workspace replacement).
        if let scope {
            guard case let .owner(owner) = input.target.owner, scope.owner == owner else { return nil }
        }
        if let content = input.content, content.scope == scope, content.hasUsableContent || content.hasArchivedHistory {
            return .transcript
        }
        if let runScope = input.liveRunScope, runScope == scope {
            return .runningOrWaiting
        }
        if input.isDiscoveryPending {
            return .restoring
        }
        if case .awaitingOwner = input.target.owner {
            return .restoring
        }
        if case .settledUnowned(_, hasSelectedSavedBinding: true) = input.target.owner {
            return .unavailable(.workspaceUnavailable, retry: nil)
        }
        guard let record = input.record else { return scope?.binding == nil ? .welcome : nil }
        guard record.scope == scope else { return nil }
        guard record.origin == .saved else { return .welcome }
        /// Load evidence is the full qualified attempt for this scope, not only its UUID.
        func isCurrent(_ attempt: AgentPersistedLoadAttempt) -> Bool {
            attempt.attemptID == input.currentAttemptID && attempt.scope == scope
        }
        switch record.phase {
        case .notStarted:
            return .restoring
        case .settledLocal:
            return input.content?.scope == scope ? .welcome : .restoring
        case let .loading(attempt):
            return isCurrent(attempt) ? .restoring : nil
        case let .settled(attempt, exit):
            guard isCurrent(attempt) else { return nil }
            let retry = AgentTranscriptRetryTarget(
                target: input.target,
                attemptID: attempt.attemptID,
                sourceItemsRevision: attempt.sourceItemsRevision
            )
            switch exit {
            case .payloadApplied, .sourceRevisionSuperseded:
                // Intentional emptiness only once this scope's projection has committed.
                return input.content?.scope == scope ? .welcome : .restoring
            case .missingPayload: return .unavailable(.missing, retry: retry)
            case .loadFailed: return .unavailable(.loadFailed, retry: retry)
            case .cancelled: return .unavailable(.interrupted, retry: retry)
            case .persistenceSuppressed: return .unavailable(.persistenceSuppressed, retry: nil)
            case .workspaceUnavailable: return .unavailable(.workspaceUnavailable, retry: nil)
            }
        }
    }
}

/// The selected pane target the classifier qualifies evidence against.
struct AgentTranscriptPaneTarget: Equatable {
    enum Owner: Equatable {
        case owner(AgentWorkspaceSessionIndexStore.SessionIndexOwner)
        /// Active ID published for an actual switch/queued adoption; owner not yet installed.
        case awaitingOwner(workspaceID: UUID)
        /// Settled with no active workspace.
        case noWorkspace
        /// Active workspace settled without any owning runtime/adoption (authority-only projection).
        case settledUnowned(workspaceID: UUID, hasSelectedSavedBinding: Bool)
    }

    let owner: Owner
    /// Selected tab; nil when the workspace has no selection.
    let tabID: UUID?
    let sessionActivationGeneration: Int
    let scope: AgentSessionPresentationScope?

    /// Target of the empty, unresolved snapshot.
    static let unresolved = AgentTranscriptPaneTarget(owner: .noWorkspace, tabID: nil, sessionActivationGeneration: 0, scope: nil)
}

/// Admission result of an explicit Retry; never a success claim.
enum AgentTranscriptRetryResult: Equatable {
    case started
    case alreadyLoading
    case stale
    case notRetryable
}

/// Captured identity an explicit Retry must revalidate before admitting a load.
struct AgentTranscriptRetryTarget: Equatable {
    let target: AgentTranscriptPaneTarget
    let attemptID: UUID
    let sourceItemsRevision: Int
}

/// Scope-qualified content facts captured from the current transcript projection.
struct AgentTranscriptPaneContentFacts: Equatable {
    let scope: AgentSessionPresentationScope
    /// Current rows, including partial or unsaved local content.
    let hasUsableContent: Bool
    /// Archived history blocks reachable from this scope's projection.
    let hasArchivedHistory: Bool

    init(scope: AgentSessionPresentationScope, hasUsableContent: Bool, hasArchivedHistory: Bool = false) {
        self.scope = scope
        self.hasUsableContent = hasUsableContent
        self.hasArchivedHistory = hasArchivedHistory
    }
}
