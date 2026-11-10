import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPServer
import RepoPromptShared
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

typealias MCPRequestMetadata = RepoPromptShared.MCPRequestMetadata
typealias MCPTabContextHint = RepoPromptShared.MCPTabContextHint

extension MCPInvocationContextBridge {
    static func require(toolName: String, expectedWindowID: Int? = nil) throws -> ToolInvocationContext {
        try require(toolName: toolName, expectedWindowID: expectedWindowID, diagnosticSink: {
            MCPInvocationDiagnosticAdapter().report($0)
        })
    }
}

struct MCPTabContextSnapshot {
    let tabID: UUID
    let windowID: Int
    let workspaceID: UUID?
    var promptText: String
    /// True when terminal commit copied assistant output into an otherwise empty prompt.
    var usedAgentOutputAsPrompt: Bool
    var selection: StoredSelection
    /// Monotonic canonical selection revision observed when this snapshot last synchronized.
    /// A final commit uses it to avoid overwriting selection persisted by a newer connection.
    var selectionRevision: UInt64
    /// Selected stored prompt IDs for computing meta tokens in tab-context snapshots.
    var selectedMetaPromptIDs: [UUID]
    /// Selected Context Builder prompt IDs. These are distinct from StoredPrompt IDs.
    var selectedContextBuilderPromptIDs: [UUID]
    /// Tab name for MCP metadata block generation.
    var tabName: String
    /// Optional run lease associated with this snapshot.
    var runID: UUID?
    /// Active persisted Agent session bound to this tab, if any.
    var activeAgentSessionID: UUID?
    /// Hydration-aware worktree binding state for the active Agent session at snapshot time.
    var worktreeBindingState: AgentSessionWorktreeBindingState
    var worktreeBindings: [AgentSessionWorktreeBinding] {
        get { worktreeBindingState.bindings ?? [] }
        set { worktreeBindingState = .hydrated(newValue) }
    }

    var fileToolAuthoritySourceIdentity: AgentWorkspaceLookupContextIdentity? {
        AgentWorkspaceLookupContextSource(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingState: worktreeBindingState
        ).authorityIdentity
    }

    /// Process-lifetime catalog, lookup, and worktree-lifetime authority inherited by nested tools.
    var frozenFileToolAuthority: MCPFrozenFileToolAuthority?
    private var fallbackFrozenLookupContext: WorkspaceLookupContext?
    var frozenLookupContext: WorkspaceLookupContext? {
        get { frozenFileToolAuthority?.lookupContext ?? fallbackFrozenLookupContext }
        set {
            fallbackFrozenLookupContext = newValue
            if frozenFileToolAuthority?.lookupContext != newValue {
                frozenFileToolAuthority = nil
            }
        }
    }

    /// Ephemeral Context Builder review repository authority for one exact nested run.
    var contextBuilderReviewTargetResolution: ContextBuilderReviewTargetResolution?
    /// True if this snapshot was created via explicit `bind_context` / `_tabID` binding.
    /// Explicit bindings should persist even when the bound tab is not the active tab.
    let explicitlyBound: Bool
    /// Ephemeral identity for deferred read-file auto-selection work. A replacement binding
    /// receives a fresh generation so stale queued work cannot apply to the new snapshot.
    var readFileAutoSelectionGeneration: UInt64

    init(
        tabID: UUID,
        windowID: Int,
        workspaceID: UUID?,
        promptText: String,
        usedAgentOutputAsPrompt: Bool = false,
        selection: StoredSelection,
        selectionRevision: UInt64 = 0,
        selectedMetaPromptIDs: [UUID],
        selectedContextBuilderPromptIDs: [UUID] = [],
        tabName: String,
        runID: UUID?,
        activeAgentSessionID: UUID? = nil,
        worktreeBindings: [AgentSessionWorktreeBinding] = [],
        worktreeBindingState: AgentSessionWorktreeBindingState? = nil,
        frozenLookupContext: WorkspaceLookupContext? = nil,
        frozenFileToolAuthority: MCPFrozenFileToolAuthority? = nil,
        contextBuilderReviewTargetResolution: ContextBuilderReviewTargetResolution? = nil,
        explicitlyBound: Bool,
        readFileAutoSelectionGeneration: UInt64 = 0
    ) {
        self.tabID = tabID
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.promptText = promptText
        self.usedAgentOutputAsPrompt = usedAgentOutputAsPrompt
        self.selection = selection
        self.selectionRevision = selectionRevision
        self.selectedMetaPromptIDs = selectedMetaPromptIDs
        self.selectedContextBuilderPromptIDs = selectedContextBuilderPromptIDs
        self.tabName = tabName
        self.runID = runID
        self.activeAgentSessionID = activeAgentSessionID
        self.worktreeBindingState = worktreeBindingState
            ?? (activeAgentSessionID == nil ? .notApplicable : .hydrated(worktreeBindings))
        fallbackFrozenLookupContext = frozenLookupContext
        self.frozenFileToolAuthority = frozenFileToolAuthority
        self.contextBuilderReviewTargetResolution = contextBuilderReviewTargetResolution
        self.explicitlyBound = explicitlyBound
        self.readFileAutoSelectionGeneration = readFileAutoSelectionGeneration
    }
}

typealias MCPTabContextSnapshotSource = RepoPromptShared.MCPTabContextSnapshotSource

enum MCPTabContextResolution {
    case tabContextSnapshot(MCPTabContextSnapshot, source: MCPTabContextSnapshotSource)

    var snapshot: MCPTabContextSnapshot? {
        if case let .tabContextSnapshot(snapshot, _) = self { return snapshot }
        return nil
    }
}

typealias MCPConnectionBindingSnapshot = RepoPromptShared.MCPConnectionBindingSnapshot

struct MCPResolvedTabContextSnapshot {
    var snapshot: MCPTabContextSnapshot
    let source: MCPTabContextSnapshotSource?

    var isRunlessOneShotHint: Bool {
        source == .explicitHint && snapshot.runID == nil
    }

    init(
        snapshot: MCPTabContextSnapshot,
        source: MCPTabContextSnapshotSource? = nil
    ) {
        self.snapshot = snapshot
        self.source = source
    }
}

struct MCPFrozenFileToolAuthority {
    let lookupContext: WorkspaceLookupContext
    let rootCatalogSnapshot: WorkspaceRootCatalogSnapshot
    var canonicalRoots: Set<WorkspaceRootRef> {
        Set(rootCatalogSnapshot.primaryRoots)
    }

    let sessionRootLifetimeSnapshot: WorkspaceSessionRootLifetimeSnapshot?
    let sourceIdentity: AgentWorkspaceLookupContextIdentity?

    func hasSameRoutingAuthority(as other: MCPFrozenFileToolAuthority) -> Bool {
        guard sourceIdentity == other.sourceIdentity,
              lookupContext == other.lookupContext,
              rootCatalogSnapshot == other.rootCatalogSnapshot,
              canonicalRoots == other.canonicalRoots
        else {
            return false
        }
        switch (sessionRootLifetimeSnapshot, other.sessionRootLifetimeSnapshot) {
        case (nil, nil):
            return true
        case let (lhs?, _?):
            return lhs.isGenerationCurrent()
        default:
            return false
        }
    }
}

enum MCPFileToolAuthorityFailure: LocalizedError, Equatable {
    case unavailable
    case timedOut
    case superseded
    case mismatchedProjection
    case worktreeScopeUnavailable

    static let retryAfterMilliseconds = 1000

    var errorCode: String {
        switch self {
        case .unavailable: "workspace_authority_unavailable"
        case .timedOut: "workspace_authority_timeout"
        case .superseded: "workspace_authority_superseded"
        case .mismatchedProjection: "workspace_authority_mismatch"
        case .worktreeScopeUnavailable: "worktree_scope_unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The resolved workspace file authority is unavailable. No canonical checkout was used."
        case .timedOut:
            "The workspace root catalog did not become ready in time. No canonical checkout was used."
        case .superseded:
            "Workspace authority changed while the file request was resolving. No canonical checkout was used."
        case .mismatchedProjection:
            "The workspace root catalog no longer matches the loaded roots. No canonical checkout was used."
        case .worktreeScopeUnavailable:
            "The bound worktree scope is unavailable. No canonical checkout was used."
        }
    }

    var retryable: Bool {
        true
    }
}
