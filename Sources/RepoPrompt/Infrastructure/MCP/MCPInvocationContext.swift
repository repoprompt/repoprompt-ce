import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared
import RepoPromptWorkspaceCore

typealias MCPTabContextHint = RepoPromptShared.MCPTabContextHint

typealias MCPRequestMetadata = RepoPromptShared.MCPRequestMetadata

struct MCPWindowToolDispatchIdentity {
    let windowID: Int
    let windowStateIdentity: ObjectIdentifier
    let serverViewModelIdentity: ObjectIdentifier
    let catalogRegistrationHandle: MCPDomainToolRegistrationHandle
    var modelRouteToken: AgentSessionLinkRunCatalogRouteToken?
}

struct MCPToolDispatchAuthorization {
    let connectionID: UUID
    let connectionIdentity: ObjectIdentifier
    let lifecycleGeneration: UInt64
    let windowIdentity: MCPWindowToolDispatchIdentity?
}

/// Immutable app-host evidence carried across the unchanged canonical args-only binding.
/// DomainRuntime remains the owner of admission, cancellation, settlement, and delivery.
struct ToolInvocationContext {
    enum Origin {
        case network
        case trustedLocal
    }

    let origin: Origin
    let invocationID: UUID
    /// Correlation only. Existing host/transport identities remain the deduplication authority.
    let requestID: JSONRPCBridgeID?
    let toolName: String
    let metadata: MCPRequestMetadata
    let dispatchAuthorization: MCPToolDispatchAuthorization?

    var connectionID: UUID? {
        metadata.connectionID
    }

    func withDispatchAuthorization(
        _ authorization: MCPToolDispatchAuthorization,
        explicitWindowRoutingHint: MCPExplicitWindowRoutingHint?
    ) -> Self {
        Self(
            origin: origin,
            invocationID: invocationID,
            requestID: requestID,
            toolName: toolName,
            metadata: MCPRequestMetadata(
                connectionID: metadata.connectionID,
                clientName: metadata.clientName,
                windowID: authorization.windowIdentity?.windowID ?? metadata.windowID,
                runPurpose: metadata.runPurpose,
                tabContextHint: metadata.tabContextHint,
                explicitWindowRoutingHint: explicitWindowRoutingHint,
                invocationID: metadata.invocationID,
                requestID: metadata.requestID
            ),
            dispatchAuthorization: authorization
        )
    }

    static func trustedLocal(toolName: String, metadata: MCPRequestMetadata) -> Self {
        let invocationID = metadata.invocationID ?? UUID()
        return Self(
            origin: .trustedLocal,
            invocationID: invocationID,
            requestID: metadata.requestID,
            toolName: toolName,
            metadata: metadata,
            dispatchAuthorization: nil
        )
    }
}

enum MCPInvocationContextFailure: Error, Equatable {
    case missingExpectedContext
    case toolMismatch
    case connectionMismatch
    case windowMismatch
    case missingAuthorization
}

/// The single app-binding ingress bridge. Capture before callbacks/detached tasks, then
/// forward the value explicitly; those hops must not rely on TaskLocal inheritance.
enum MCPInvocationContextBridge {
    // Boxed: runtime-sized payloads must not use `@TaskLocal` directly (#1039).
    static let currentTaskLocal = BoxedTaskLocal<ToolInvocationContext?>(nil)
    static var current: ToolInvocationContext? {
        currentTaskLocal.get()
    }

    @TaskLocal static var diagnosticSink: (@Sendable (MCPInvocationContextFailure) -> Void)?

    static func require(
        toolName: String,
        expectedWindowID: Int? = nil,
        diagnosticSink: @Sendable (MCPInvocationContextFailure) -> Void = { failure in
            MCPInvocationDiagnosticAdapter().report(failure)
        }
    ) throws -> ToolInvocationContext {
        guard let context = current else { throw failure(.missingExpectedContext, fallback: diagnosticSink) }
        guard context.toolName == toolName else { throw failure(.toolMismatch, fallback: diagnosticSink) }
        switch context.origin {
        case .network:
            guard let connectionID = context.connectionID,
                  context.metadata.invocationID == context.invocationID
            else { throw failure(.connectionMismatch, fallback: diagnosticSink) }
            if let authorization = context.dispatchAuthorization {
                guard authorization.connectionID == connectionID else { throw failure(.connectionMismatch, fallback: diagnosticSink) }
            }
            if let expectedWindowID {
                guard let authorization = context.dispatchAuthorization else { throw failure(.missingAuthorization, fallback: diagnosticSink) }
                guard authorization.windowIdentity?.windowID == expectedWindowID,
                      context.metadata.windowID == expectedWindowID
                else { throw failure(.windowMismatch, fallback: diagnosticSink) }
            }
        case .trustedLocal:
            if let expectedWindowID, let windowID = context.metadata.windowID, windowID != expectedWindowID {
                throw failure(.windowMismatch, fallback: diagnosticSink)
            }
        }
        return context
    }

    static func withInvocation<T>(
        _ context: ToolInvocationContext,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await currentTaskLocal.withValue(context, operation: operation)
    }

    private static func failure(
        _ failure: MCPInvocationContextFailure,
        fallback: @Sendable (MCPInvocationContextFailure) -> Void
    ) -> MCPInvocationContextFailure {
        #if DEBUG
            if let diagnosticSink {
                diagnosticSink(failure)
            } else {
                fallback(failure)
            }
        #endif
        return failure
    }
}

typealias MCPToolInvocationValidator = @Sendable (
    _ context: ToolInvocationContext,
    _ expectedWindowID: Int,
    _ expectedServerViewModelIdentity: ObjectIdentifier
) async -> Bool

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
