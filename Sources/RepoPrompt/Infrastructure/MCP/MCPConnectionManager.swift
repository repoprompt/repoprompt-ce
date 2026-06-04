// MARK: - Connection Management Components

import Darwin
import Foundation
import JSONSchema
import Logging
import MCP
import Ontology
import OSLog
import RepoPromptShared
import SwiftUI

#if DEBUG
    import CryptoKit
#endif

#if DEBUG
    private var mcpConnectionManagerDebugLoggingEnabled = ProcessInfo.processInfo.environment["REPOPROMPT_MCP_DEBUG"] == "1"
    private var mcpRoutingDebugLoggingEnabled = false
    private var mcpPolicyDebugLoggingEnabled = false

    private func connectionLog(_ message: @autoclosure () -> String) {
        guard mcpConnectionManagerDebugLoggingEnabled else { return }
        print("[MCPConnectionManager] \(message())")
    }

    private func mcpACPLog(_ message: @autoclosure () -> String) {
        guard AgentRuntimeProviderService.enableDebugLogging else { return }
        print(message())
    }

    private func mcpRoutingLog(_ message: @autoclosure () -> String) {
        guard mcpRoutingDebugLoggingEnabled else { return }
        print("[MCPRouting] \(message())")
    }

    private func mcpRoutingInternalDebugLog(_ message: @autoclosure () -> String) {
        mcpRoutingLog(message())
    }

    private func mcpPolicyLog(_ message: @autoclosure () -> String) {
        guard mcpPolicyDebugLoggingEnabled else { return }
        print("[MCPPolicy] \(message())")
    }

    private func mcpToolTrackingDiagnostic(_ message: @autoclosure () -> String) {
        print("[ClaudeToolTracking] \(message())")
    }
#else
    private func connectionLog(_ message: @autoclosure () -> String) {}
    private func mcpACPLog(_ message: @autoclosure () -> String) {}
    private func mcpRoutingLog(_ message: @autoclosure () -> String) {}
    private func mcpRoutingInternalDebugLog(_ message: @autoclosure () -> String) {}
    private func mcpPolicyLog(_ message: @autoclosure () -> String) {}
    private func mcpToolTrackingDiagnostic(_ message: @autoclosure () -> String) {}
#endif

// MARK: - Bundle helpers for safe metadata access

private extension Bundle {
    var name: String {
        object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown"
    }

    var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }
}

// MARK: - MCP Run Purpose

/// Purpose of an MCP connection's run, used to route UI (e.g., ask_user) to the correct surface.
public enum MCPRunPurpose: String, Sendable, Codable {
    case discoverRun // Context Builder agent exploring codebase
    case agentModeRun // Agent mode interactive session
    case unknown // No policy or unspecified
}

/// ---------------------------------------------------------------------
/// Shared constants & logger for the connection-layer (ported from iMCP)
/// ---------------------------------------------------------------------
private let log: Logging.Logger = {
    var logger = Logger(label: "com.repoprompt.mcp.connection")
    #if DEBUG
        logger.logLevel = .debug
    #else
        logger.logLevel = .notice
    #endif
    return logger
}()

enum ConnectionStateSnapshot: Equatable {
    case connecting
    case ready
    case failed(Swift.Error?)
    case cancelled

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting),
             (.ready, .ready),
             (.cancelled, .cancelled):
            true
        case (.failed, .failed):
            // Treat all failures as equivalent for pruning/retention decisions
            true
        default:
            false
        }
    }
}

protocol MCPServerConnection: Actor {
    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws
    func stop() async
    func notifyToolListChanged() async
    func connectionState() -> ConnectionStateSnapshot
    func isViableForRetention() -> Bool
    func secondsSinceLastActivity() async -> TimeInterval
    /// Whether this is a legacy filesystem-backed connection (deprecated)
    nonisolated var isFilesystemBacked: Bool { get }
    /// Legacy: connection folder URL for filesystem connections
    nonisolated var connectionFolderURL: URL? { get }
    /// Optional capability token / session key for routing persistence.
    /// Used to correlate CLI sessions across reconnections.
    nonisolated var capabilityToken: String? { get }
    /// Terminates this connection with a reason.
    /// Writes a kill signal file (filesystem side-channel) so CLI exits without retry, then stops.
    /// - Parameter reason: Why the connection is being terminated
    /// - Parameter message: Optional human-readable message
    func terminate(reason: TerminationReason, message: String?) async

    /// Sends a progress notification to the CLI during long-running operations.
    /// - Parameters:
    ///   - tool: Tool name (e.g., "context_builder", "oracle_send")
    ///   - kind: Progress kind (.stage for transitions, .heartbeat for keep-alive)
    ///   - stage: Current stage name
    ///   - message: Human-readable message
    func sendProgress(tool: String, kind: RepoPromptProgressKind, stage: String, message: String) async
}

// MARK: - Dashboard Models

/// Transport type for MCP connections
enum ConnectionTransport: String, Codable {
    case network
    case filesystem
}

/// Summary state for dashboard display
enum ConnectionStateSummary: String, Codable {
    case setup
    case waiting
    case ready
    case failed
    case cancelled
    case unknown
}

/// Dashboard entry for a single connection
struct ConnectionDashboardEntry: Identifiable, Codable {
    let id: UUID
    let clientName: String
    let windowID: Int?
    let transport: ConnectionTransport
    let state: ConnectionStateSummary
    let createdAt: Date
    let lastToolCallAt: Date?
    let totalToolCalls: Int
    let idleSeconds: TimeInterval?
    let hasInFlightCalls: Bool
    let activeToolName: String?
    /// Session key (capabilityToken) for disambiguating multiple client instances
    let sessionKey: String?
}

/// Complete dashboard snapshot from ServerNetworkManager
struct NetworkDashboardSnapshot {
    let isRunning: Bool
    let connections: [ConnectionDashboardEntry]
    let recentToolCalls: [ServerNetworkManager.ToolCallHistoryEntry]
}

/// Debug snapshot of identity context for a connection
struct IdentityContextSnapshot {
    /// How identity was derived
    enum Source: String {
        case unknown
        case filesystemMeta
        case handshake
    }

    let connectionID: UUID
    let clientName: String?
    let capabilityToken: String?
    let source: Source
    let hasHandshake: Bool
    let lastUpdated: Date
}

// The NWConnection-based MCPConnectionManager and Bonjour-based NetworkDiscoveryManager
// previously lived here. They have been fully removed so that the only remaining
// MCPServerConnection implementation is BootstrapSocketConnectionManager (in a separate file).
// No replacement code is needed; we now go directly to ServerNetworkManager.

/// Manages all MCP connections using the bootstrap UNIX-domain socket.
/// TCP/Bonjour transport has been removed.
actor ServerNetworkManager {
    /// 🚀 Single, app-wide instance that owns the MCP listener and all
    /// active client connections.  Use this when you need to reference the
    /// MCP listener from anywhere in the app.
    static let shared = ServerNetworkManager()
    private static let repoCLIPrefix = "RepoPrompt CLI"
    private static let toolNameAliases: [String: String] = [
        "discover_manage_selection": "manage_selection",
        "discover_prompt": "prompt",
        "discover_workspace_context": "workspace_context"
    ]
    nonisolated static func canonicalToolName(for name: String) -> String {
        toolNameAliases[name] ?? name
    }

    private static func validatedLiveRunID(
        candidateRunID: UUID,
        connectionID: UUID,
        connectionIDByRunID: [UUID: UUID],
        connectionIDToRunID: [UUID: UUID]
    ) -> UUID? {
        guard connectionIDToRunID[connectionID] == candidateRunID,
              connectionIDByRunID[candidateRunID] == connectionID
        else {
            return nil
        }
        return candidateRunID
    }

    #if DEBUG
        nonisolated static func test_validatedLiveRunID(
            candidateRunID: UUID,
            connectionID: UUID,
            connectionIDByRunID: [UUID: UUID],
            connectionIDToRunID: [UUID: UUID]
        ) -> UUID? {
            validatedLiveRunID(
                candidateRunID: candidateRunID,
                connectionID: connectionID,
                connectionIDByRunID: connectionIDByRunID,
                connectionIDToRunID: connectionIDToRunID
            )
        }
    #endif

    /// Resolve the window currently associated with a run ID.
    /// Fast path prefers actor-local caches (run routing/policy state) and only falls
    /// back to scanning live windows when no cached mapping exists.
    private func windowIDForRunID(_ runID: UUID) async -> Int? {
        if let cachedWindowID = windowIDByRunID[runID] {
            return cachedWindowID
        }
        if let policyWindowID = runPolicyStateByRunID[runID]?.windowID {
            windowIDByRunID[runID] = policyWindowID
            return policyWindowID
        }
        let resolvedWindowID = await MainActor.run {
            WindowStatesManager.shared.allWindows.first { $0.mcpServer.hasLiveRunID(runID) }?.windowID
        }
        if let resolvedWindowID {
            windowIDByRunID[runID] = resolvedWindowID
        }
        return resolvedWindowID
    }

    static func sanitizedRoutingRestrictedTools(_ names: Set<String>) -> Set<String> {
        guard !names.isEmpty else { return [] }
        return names
    }

    nonisolated static func shouldAdvertiseCanonicalBindingParams(for toolName: String) -> Bool {
        toolName == "bind_context"
    }

    /// Tools that declare context_id in their own schema and need it rehydrated after dispatch extraction.
    nonisolated static func shouldRehydrateContextID(for toolName: String) -> Bool {
        toolName == "bind_context" || toolName == "oracle_utils" || toolName == "context_builder"
    }

    nonisolated static func shouldRehydrateLegacyTabID(for toolName: String) -> Bool {
        toolName == "context_builder"
    }

    /// Tools that declare public window_id semantics and need an explicit hidden
    /// _windowID compatibility selector restored after dispatch extraction.
    nonisolated static func shouldRehydrateExplicitWindowID(for toolName: String) -> Bool {
        toolName == "bind_context"
    }

    /// Migrated tools resolve tab-context snapshots from request metadata, including
    /// the one-shot TaskLocal hint populated from dispatch-level context_id/_tabID.
    nonisolated static func shouldUseGenericTabBindingCompatibility(for toolName: String) -> Bool {
        guard !shouldSkipGenericTabBinding(for: toolName) else { return false }
        let migrated: Set = [
            "manage_selection",
            "workspace_context",
            "get_file_tree",
            "get_code_structure",
            "read_file",
            "file_search",
            "file_actions",
            "apply_edits",
            "prompt",
            "agent_run",
            "agent_explore",
            "agent_manage",
            "ask_oracle",
            "oracle_send",
            "oracle_utils",
            "oracle_chat_log",
            "git",
            "manage_worktree"
        ]
        return !migrated.contains(toolName)
    }

    nonisolated static func shouldInjectLegacyTabIDForCompatibility(for toolName: String) -> Bool {
        shouldRehydrateLegacyTabID(for: toolName) || shouldUseGenericTabBindingCompatibility(for: toolName)
    }

    /// bind_context manages its own window_id semantics — the dispatch layer must not
    /// auto-inject a routing window_id into its public args, because that would silently
    /// scope `op=list` to a single window instead of returning all windows.
    nonisolated static func isAppWideTool(_ toolName: String) -> Bool {
        toolName == AppSettingsMCPService.toolName
    }

    nonisolated static func shouldAutoInjectPublicWindowID(for toolName: String) -> Bool {
        toolName != "bind_context" && !isAppWideTool(toolName)
    }

    nonisolated static func shouldBypassLogicalContextPreResolution(for toolName: String) -> Bool {
        toolName == "bind_context" || isAppWideTool(toolName)
    }

    nonisolated static func shouldSkipGenericTabBinding(for toolName: String) -> Bool {
        toolName == "manage_workspaces" || toolName == "bind_context" || toolName == "context_builder" || isAppWideTool(toolName)
    }

    nonisolated static func shouldSkipPerCallRunScopedTabRebindFallback(
        toolName: String,
        purpose: MCPRunPurpose
    ) -> Bool {
        guard purpose == .agentModeRun else { return false }
        return toolName == "read_file" || toolName == "file_search"
    }

    nonisolated static func shouldBypassWindowRouting(for toolName: String) -> Bool {
        isAppWideTool(toolName)
    }

    nonisolated static func shouldPersistResolvedLogicalContextWindowMapping(for toolName: String) -> Bool {
        !shouldBypassWindowRouting(for: toolName)
    }

    nonisolated static func isWindowSelectionExempt(toolName: String, args: [String: Value]) -> Bool {
        if toolName == "bind_context" || isAppWideTool(toolName) {
            return true
        }
        guard toolName == "manage_workspaces" else { return false }
        let action = args["action"]?.stringValue?.lowercased()
        if action == "list" {
            return true
        }
        if action == "switch" || action == "create",
           args["open_in_new_window"]?.boolValue ?? false
        {
            return true
        }
        return false
    }

    nonisolated static func multiWindowSelectionGuidance() -> String {
        "Multiple RepoPrompt windows detected. Bind your connection to a tab context to route tool calls:\n\n" +
            "**Recommended: Bind by exact workspace root paths (auto-resolves to the matching workspace/window tab context)**\n" +
            "Call `bind_context` with `{\"op\":\"bind\",\"working_dirs\":[\"/absolute/path/to/root1\",\"/absolute/path/to/root2\"]}` using the full workspace directory set.\n\n" +
            "**Alternatives:**\n" +
            "- `bind_context` with `{\"op\":\"list\"}` to see windows and context_id values\n" +
            "- `bind_context` with `{\"op\":\"bind\",\"context_id\":\"<id>\"}` to bind a specific tab context\n" +
            "- `bind_context` with `{\"op\":\"bind\",\"window_id\":<id>}` to set window affinity only\n" +
            "- Pass `_windowID` as a hidden parameter on any tool call for one-shot routing"
    }

    nonisolated static func multiWindowSelectionGuidance(
        purpose: MCPRunPurpose,
        restrictedTools: Set<String>
    ) -> String {
        if purpose == .agentModeRun {
            return agentModeRoutingFailureGuidance()
        }
        if restrictedTools.contains("bind_context") {
            return restrictedConnectionRoutingFailureGuidance()
        }
        return multiWindowSelectionGuidance()
    }

    nonisolated static func invalidWindowSelectionGuidance(
        windowID: Int,
        purpose: MCPRunPurpose,
        restrictedTools: Set<String>
    ) -> String {
        if purpose == .agentModeRun {
            return "Window \(windowID) is not available for this Agent Mode run.\n" + agentModeRoutingFailureGuidance()
        }
        if restrictedTools.contains("bind_context") {
            return "Window \(windowID) is not available for this restricted MCP connection.\n" + restrictedConnectionRoutingFailureGuidance()
        }
        return "Window \(windowID) not found or MCP tools not enabled.\n" +
            "Call `bind_context` with `{\"op\":\"list\"}` to see available windows."
    }

    nonisolated static func tabBindingTroubleshooting(
        purpose: MCPRunPurpose,
        restrictedTools: Set<String>,
        windowID: Int? = nil
    ) -> [String] {
        if purpose == .agentModeRun {
            return [
                "RepoPrompt could not route this Agent Mode MCP call to the active run.",
                "Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
            ]
        }
        if restrictedTools.contains("bind_context") {
            return [
                "RepoPrompt could not route this restricted MCP connection.",
                "Retry once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart the MCP client or Agent Mode run."
            ]
        }
        if let windowID {
            return [
                "Call `bind_context` with `{\"op\":\"list\",\"window_id\":\(windowID)}` to see available context_id values in this window.",
                "The tab may exist in a different window - verify `_windowID` is correct.",
                "Use `bind_context` with `op=bind` for explicit tab binding with validation."
            ]
        }
        return [
            "Include `_windowID` alongside `_tabID` to specify the target window.",
            "Or call `bind_context` with `{\"op\":\"bind\",\"window_id\":<window_id>}` first.",
            "Or use `bind_context` with `op=bind` and a `context_id` for sticky tab binding."
        ]
    }

    private nonisolated static func agentModeRoutingFailureGuidance() -> String {
        "RepoPrompt could not route this Agent Mode MCP call to the active run. " +
            "Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
    }

    private nonisolated static func restrictedConnectionRoutingFailureGuidance() -> String {
        "RepoPrompt could not route this restricted MCP connection. " +
            "Retry once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart the MCP client or Agent Mode run."
    }

    private static func describeToolList(_ names: Set<String>) -> String {
        guard !names.isEmpty else { return "-" }
        return names.sorted().joined(separator: ",")
    }

    private static func describeGrantedTools(restricted: Set<String>) -> String {
        if restricted.isEmpty {
            return "all tools"
        }
        return "all except \(describeToolList(restricted))"
    }

    private var isRunningState: Bool = false
    private var isEnabledState: Bool = true

    // Bootstrap socket server
    private var bootstrapSocketServer: BootstrapSocketServer?
    private var bootstrapSocketTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var bootstrapStartInProgress: Bool = false
    private var bootstrapRestartInProgress: Bool = false
    private var bootstrapRestartToken: UUID?
    private var lastBootstrapRestartAt: Date = .distantPast
    private let bootstrapRestartMinInterval: TimeInterval = 2.0
    private var bootstrapStartFailures: Int = 0
    private var lastBootstrapHealthCheckAt: Date = .distantPast
    private let bootstrapHealthCheckInterval: TimeInterval = 5.0

    private func resolvedBootstrapSocketURL() -> URL {
        #if DEBUG
            if let testBootstrapSocketURLOverride {
                return testBootstrapSocketURLOverride
            }
        #endif
        return MCPFilesystemConstants.bootstrapSocketURL()
    }

    #if DEBUG
        enum DebugBootstrapSocketURLOverrideError: Error, Equatable {
            case managerNotFullyStopped
            case overrideAlreadyInstalled
            case overrideNotInstalled
            case overrideMismatch
            case productionSocketURLRejected
        }

        private var testBootstrapSocketURLOverride: URL?

        func debugInstallBootstrapSocketURLOverride(_ socketURL: URL) throws {
            try debugRequireFullyStoppedForBootstrapSocketURLOverride()
            let standardizedSocketURL = socketURL.standardizedFileURL
            guard standardizedSocketURL != MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL else {
                throw DebugBootstrapSocketURLOverrideError.productionSocketURLRejected
            }
            guard testBootstrapSocketURLOverride == nil else {
                throw DebugBootstrapSocketURLOverrideError.overrideAlreadyInstalled
            }
            testBootstrapSocketURLOverride = standardizedSocketURL
        }

        func debugRestoreBootstrapSocketURLOverride(expected socketURL: URL) throws {
            try debugRequireFullyStoppedForBootstrapSocketURLOverride()
            guard let testBootstrapSocketURLOverride else {
                throw DebugBootstrapSocketURLOverrideError.overrideNotInstalled
            }
            guard testBootstrapSocketURLOverride == socketURL.standardizedFileURL else {
                throw DebugBootstrapSocketURLOverrideError.overrideMismatch
            }
            self.testBootstrapSocketURLOverride = nil
        }

        func debugResolvedBootstrapSocketURL() -> URL {
            resolvedBootstrapSocketURL()
        }

        func debugIsEnabledForBootstrapSocketURLOverride() -> Bool {
            isEnabledState
        }

        private func debugRequireFullyStoppedForBootstrapSocketURLOverride() throws {
            guard !isRunningState,
                  bootstrapSocketServer == nil,
                  bootstrapSocketTask == nil,
                  maintenanceTask == nil,
                  !bootstrapStartInProgress,
                  !bootstrapRestartInProgress,
                  bootstrapRestartToken == nil,
                  connections.isEmpty,
                  connectionTasks.isEmpty,
                  pendingConnections.isEmpty,
                  bootstrapReservations.isEmpty,
                  connectionWaiters.isEmpty
            else {
                throw DebugBootstrapSocketURLOverrideError.managerNotFullyStopped
            }
        }

        private struct DebugConnectionEvent {
            let seq: UInt64
            let timestamp: Date
            let event: String
            let restartID: UUID?
            let connectionID: UUID?
            let clientName: String?
            let normalizedClientID: String?
            let sessionFingerprint: String?
            let windowID: Int?
            let state: String?
            let reason: String?
        }

        private struct DebugRestartStatus {
            let restartID: UUID
            var state: String
            var lastError: String?
            var updatedAt: Date
        }

        private var debugConnectionHistory: [DebugConnectionEvent] = []
        private var debugConnectionHistorySeq: UInt64 = 0
        private var debugRestartStatesByID: [UUID: DebugRestartStatus] = [:]
        private let debugConnectionHistoryLimit = 1000
        private let debugRestartStatusLimit = 50
    #endif

    private var connections: [UUID: any MCPServerConnection] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingConnections: [UUID: String] = [:]

    /// Callback for dashboard updates (connection changes, tool calls, etc.)
    private var onDashboardUpdate: (@Sendable () -> Void)?

    /// Sets the dashboard update callback. Called when connections are added/removed or tool calls complete.
    func setOnDashboardUpdate(_ handler: @escaping @Sendable () -> Void) {
        onDashboardUpdate = handler
    }

    /// Emits a dashboard update notification
    private func emitDashboardUpdate() {
        connectionLog("Emitting dashboard update notification")
        onDashboardUpdate?()
    }

    static func toolErrorResult(rawJSON: Bool, message: String) -> CallTool.Result {
        guard rawJSON else { return CallTool.Result.err(message) }
        let value: Value = .object([
            "is_error": .bool(true),
            "error": .string(message)
        ])
        return CallTool.Result(content: [.text(text: ToolOutputFormatter.rawJSONString(value), annotations: nil, _meta: nil)], isError: true)
    }

    /// Tool call observers for agent UI feedback (runID-based for stability across handovers)
    /// Enhanced to support both call (with args) and completion (with result) callbacks
    private var toolCallObservers: [UUID: [UUID: @Sendable (String) -> Void]] = [:]

    /// Enhanced tool observer that receives args on call and result on completion
    struct ToolEventObserver: @unchecked Sendable {
        let onCalled: @Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?) async -> Void
        let onCompleted: (@Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?, _ resultJSON: String, _ isError: Bool) async -> Void)?
    }

    private var toolEventObservers: [UUID: [UUID: ToolEventObserver]] = [:]

    // Per-connection restriction + routing state
    private var restrictedToolsByConnection: [UUID: Set<String>] = [:]
    private var additionalToolsByConnection: [UUID: Set<String>] = [:]
    private var runPurposeByConnection: [UUID: MCPRunPurpose] = [:]
    private var windowAssignmentByConnection: [UUID: Int] = [:]
    private var preassignedConnections: Set<UUID> = []

    /// Tracks the window count at the time each connection was established.
    /// Connections established during single-window mode are auto-bound to that window
    /// and stay bound even when multi-window mode becomes active.
    private var windowCountAtConnectionTime: [UUID: Int] = [:]

    /// Snapshot describing a temporary routing/restriction rule for an incoming client connection.
    /// Policies are queued via `installClientConnectionPolicy`, enforced on the next admitted connection
    /// for the matching client/window combination, and cleared automatically after either a one-shot run
    /// or an explicit `clearClientConnectionPolicy` call. `windowID` preserves routing for multi-window
    /// scenarios, while `restrictedTools` and `ttl` gate which tool APIs the connection may invoke before
    /// the policy expires. This keeps Context Builder sandboxes from leaking into shared MCP sessions yet
    /// still allows intentional overrides when necessary.
    private struct ClientConnectionPolicy {
        let windowID: Int
        let restrictedTools: Set<String>
        let oneShot: Bool
        let reason: String?
        let createdAt: Date
        let ttl: TimeInterval
        // Tab context for Context Builder agents
        let tabID: UUID?
        let runID: UUID?
        /// Additional tools to expose for this connection (policy-gated tools like ask_user)
        let additionalTools: Set<String>?
        /// Purpose of this run (for UI routing)
        let purpose: MCPRunPurpose
        /// Task label kind for role-aware tool advertisement filtering
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?
        /// Whether role-aware advertisement should allow agent_run/agent_manage for this run
        let allowsAgentExternalControlTools: Bool
        /// When true, only an MCP peer whose verified PID descends from a registered
        /// expected agent PID may consume this queued policy.
        var requiresExpectedAgentPID: Bool
    }

    /// Run-scoped policy state captured when the first connection for a run is admitted.
    /// Used to rehydrate later handover/reconnect connections from server-maintained run mapping.
    private struct RunConnectionPolicyState {
        let windowID: Int
        let workspaceID: UUID?
        let tabID: UUID?
        let restrictedTools: Set<String>
        let additionalTools: Set<String>?
        let purpose: MCPRunPurpose
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?
        let allowsAgentExternalControlTools: Bool
        let updatedAt: Date
    }

    /// Same-process live reconnect affinity keyed by MCP client name + capability token.
    /// This is never persisted and is only authoritative while the matching run policy
    /// still exists in memory for the current app process.
    private struct LiveRunAffinity {
        let windowID: Int
        let runID: UUID
        let purpose: MCPRunPurpose
        let lastSeenAt: Date
    }

    private enum AgentPolicyAdmissionReadiness: Equatable {
        case notRequired
        case ready
        case timedOut
    }

    private var pendingPoliciesByClient: [String: [ClientConnectionPolicy]] = [:]
    private var expectedAgentPIDsByClient: [String: Set<pid_t>] = [:]
    private var expectedAgentPIDsByRunID: [UUID: Set<pid_t>] = [:]
    private var runPolicyStateByRunID: [UUID: RunConnectionPolicyState] = [:]
    private var admittedPolicyRunIDs: Set<UUID> = []
    private var windowIDByRunID: [UUID: Int] = [:]

    // 🆕 Per-connection → windowID routing map
    private var connectionWindowMap: [UUID: Int] = [:]
    private var runIDByConnectionID: [UUID: UUID] = [:]

    // 🆕 Admission control
    private var activeConnectionsByClient: [String: Set<UUID>] = [:]
    private var clientIDByConnection: [UUID: String] = [:]
    private var callLimiters: [UUID: AsyncLimiter] = [:]

    /// 🆕 Routing persistence: per-connection metadata
    /// Session key (capabilityToken) for disambiguating multiple client instances
    private var capabilityTokenByConnection: [UUID: String] = [:]
    /// Reverse lookup for session token → connection ID (bootstrap socket)
    private var connectionIDBySessionToken: [String: UUID] = [:]
    /// Persisted routing state (survives app restarts)
    private var routingState: MCPRoutingState = MCPRoutingStateStore.load()
    /// In-memory last window selection per (clientID, sessionKey) for quick access
    /// Outer key is clientID, inner key is sessionKey -> windowID
    private var lastWindowByClientSession: [String: [String: Int]] = [:]
    /// Same-process live run reconnect affinity keyed by (clientID, sessionKey).
    private var liveRunAffinityByClientSession: [String: [String: LiveRunAffinity]] = [:]
    #if DEBUG
        private var debugExactRoutingSessionRestorePoints: [UUID: DebugExactRoutingSessionFixtureRestorePoint] = [:]
    #endif
    /// TTL for routing records (24 hours)
    private let routingRecordTTL: TimeInterval = 24 * 60 * 60

    // MARK: - Killed Session Tracking

    /// Session tokens (capabilityTokens) that were explicitly killed from the dashboard.
    /// These sessions should not be allowed to reconnect - the CLI should exit instead of retrying.
    private var killedSessionTokens: Set<String> = []

    /// Expiration time for killed session entries (1 hour - long enough for CLI to exit, not permanent)
    private let killedSessionTTL: TimeInterval = 3600

    /// Tracks when each session was killed for TTL-based cleanup
    private var killedSessionTimestamps: [String: Date] = [:]

    /// ClientIDs (e.g., "claude-ai") that were recently killed by user action from the dashboard.
    /// Brief cooldown to prevent immediate auto-reconnection by the host (e.g., Claude Code).
    private var userKilledClientIDs: [String: Date] = [:]

    /// Cooldown period for user-killed clientIDs (5 seconds - just enough to prevent auto-reconnect race)
    private let userKilledClientCooldown: TimeInterval = 5.0

    // MARK: - Identity Context & Failure Escalation

    /// Tracks how identity was derived for each connection
    private struct ConnectionIdentityContext {
        enum Source {
            case unknown // nothing yet
            case filesystemMeta // from meta.json
            case handshake // from MCP initialize
        }

        var clientName: String?
        var capabilityToken: String?
        var source: Source
        var hasHandshake: Bool
        var lastUpdated: Date
    }

    /// Identity context per connection
    private var identityContextByConnection: [UUID: ConnectionIdentityContext] = [:]

    /// Identity failure escalation tracking
    private var identityFailureWindowStart: Date?
    private var identityFailureCount: Int = 0
    private let identityFailureWindow: TimeInterval = 300 // 5 min
    private let identityFailureThreshold: Int = 3 // 3 failures in 5 min triggers escalation

    /// Callback to notify higher layers (ServerController) of identity escalation
    typealias IdentityEscalationHandler = @Sendable (_ reason: String) -> Void
    private var identityEscalationHandler: IdentityEscalationHandler?

    /// Sets the identity escalation callback
    func setOnIdentityEscalation(_ handler: @escaping IdentityEscalationHandler) {
        identityEscalationHandler = handler
    }

    /// Sets a hook for dashboard updates (tool ownership, connection changes, etc.)
    func setDashboardDidChangeHook(_ hook: @escaping @Sendable () -> Void) {
        dashboardDidChangeHook = hook
    }

    /// 🆕 Connection waiter continuations (replaces polling in waitForNewConnection)
    private struct ConnectionWaiter {
        let clientName: String?
        let excludeExisting: Set<UUID>
        let continuation: CheckedContinuation<UUID?, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private var connectionWaiters: [UUID: ConnectionWaiter] = [:]

    // 🔥 Track which connection owns the active tool per window
    private var activeToolOwnerByWindow: [Int: UUID] = [:] // windowID → connectionID
    private var activeToolNameByWindow: [Int: String] = [:] // windowID → tool name (for logging)
    private var dashboardDidChangeHook: (@Sendable () -> Void)?

    /// ─────────────  Connection value/stats (for admission fairness)  ─────────────
    private struct ConnectionStats {
        let createdAt: Date
        var totalToolCalls: Int
        var lastToolCallAt: Date?
    }

    private var connectionStats: [UUID: ConnectionStats] = [:]

    /// ─────────────  Tool call history (for dashboard display)  ─────────────
    struct ToolCallHistoryEntry {
        let timestamp: Date
        let toolName: String
        let clientName: String
        let connectionID: UUID
    }

    private var recentToolCallHistory: [ToolCallHistoryEntry] = []
    private let maxToolCallHistoryCount = 5
    private struct ToolSchemaCacheKey: Hashable {
        let name: String
        let purpose: MCPRunPurpose
    }

    private var toolSchemaCache: [ToolSchemaCacheKey: Value] = [:]
    /// Tracks bootstrap connections that have been accepted but not yet committed (registered).
    /// This prevents burst scenarios where multiple concurrent accepts could exceed maxGlobalConnections.
    private struct BootstrapReservation {
        let connectionID: UUID
        let createdAt: Date
    }

    private var bootstrapReservations: [UUID: BootstrapReservation] = [:]
    /// Safety-net TTL for reservations (should be released via commit/rollback, but this catches edge cases).
    /// Use a generous value to avoid expiring legitimate reservations under load.
    private let bootstrapReservationTTL: TimeInterval = 60.0

    /// Current load including both active connections and pending reservations
    private func bootstrapLoad() -> Int {
        connections.count + bootstrapReservations.count
    }

    /// Reserve a slot for an incoming bootstrap connection (called before returning .accept)
    private func reserveBootstrapSlot(connectionID: UUID) {
        bootstrapReservations[connectionID] = BootstrapReservation(connectionID: connectionID, createdAt: Date())
    }

    /// Release a bootstrap reservation (called on commit or rollback)
    private func releaseBootstrapReservation(connectionID: UUID) {
        if bootstrapReservations.removeValue(forKey: connectionID) == nil {
            log.warning("releaseBootstrapReservation: no reservation found for \(connectionID) (double release or leak)")
        }
    }

    /// Clean up expired reservations (safety net for edge cases)
    private func cleanupExpiredBootstrapReservations() {
        let now = Date()
        let expired = bootstrapReservations.filter { now.timeIntervalSince($0.value.createdAt) >= bootstrapReservationTTL }
        if !expired.isEmpty {
            let expiredIDs = expired.map(\.key.uuidString).joined(separator: ", ")
            log.warning("Cleaning up \(expired.count) expired bootstrap reservations (indicates a bug or crash): \(expiredIDs)")
            for id in expired.keys {
                bootstrapReservations.removeValue(forKey: id)
            }
        }
    }

    private func defaultsInt(_ key: String, _ def: Int) -> Int {
        let v = UserDefaults.standard.integer(forKey: key)
        return v > 0 ? v : def
    }

    private var maxGlobalConnections: Int {
        defaultsInt("mcp.maxGlobalConnections", 128)
    }

    private var maxConnectionsPerClient: Int {
        defaultsInt("mcp.maxConnectionsPerClient", 64)
    }

    private var maxCallsPerConnection: Int {
        defaultsInt("mcp.maxCallsPerConnection", 8)
    }

    private var pressureEvictIdleSeconds: Int {
        defaultsInt("mcp.pressureEvictIdleSeconds", 7200)
    } // 2h
    private var connectingTimeoutSeconds: Int {
        defaultsInt("mcp.connectingTimeoutSeconds", 60)
    }

    private var preserveOnePerClient: Bool {
        (UserDefaults.standard.object(forKey: "mcp.preserveOnePerClient") as? Bool) ?? true
    }

    /// 🆕 Task-local keys to expose current routing hints inside tool calls
    @TaskLocal
    static var currentConnectionID: UUID?
    @TaskLocal
    static var currentTabContextHint: MCPServerViewModel.TabContextHint?

    // ------------------------------------------------------------------
    // MARK: Tool ownership tracking helpers

    /// ------------------------------------------------------------------
    private func markActiveToolOwner(windowID: Int, connectionID: UUID, toolName: String) {
        activeToolOwnerByWindow[windowID] = connectionID
        activeToolNameByWindow[windowID] = toolName
        connectionLog("Tool '\(toolName)' ownership marked for connection \(connectionID) on window \(windowID)")
        dashboardDidChangeHook?()
    }

    private func clearActiveToolOwner(windowID: Int, connectionID: UUID) {
        // Only clear if the same connection is the current owner
        if activeToolOwnerByWindow[windowID] == connectionID {
            if let toolName = activeToolNameByWindow[windowID] {
                connectionLog("Tool '\(toolName)' ownership cleared for connection \(connectionID) on window \(windowID)")
            }
            activeToolOwnerByWindow.removeValue(forKey: windowID)
            activeToolNameByWindow.removeValue(forKey: windowID)
            dashboardDidChangeHook?()
        }
    }

    private func cancelActiveToolsOwnedByConnection(
        _ connectionID: UUID,
        reason: String
    ) async -> Int {
        let ownerWindowsToClear = activeToolOwnerByWindow.compactMap { windowID, owner in
            owner == connectionID ? windowID : nil
        }
        let cancelledCount = await MainActor.run { () -> Int in
            // The VM API is identity-bound, so it is safe to scan all windows. This avoids
            // missing tools routed via a per-call _windowID override that differs from the
            // connection's sticky/default assigned window.
            WindowStatesManager.shared.allWindows.reduce(into: 0) { partialResult, window in
                partialResult += window.mcpServer.cancelActiveToolsForConnection(
                    connectionID: connectionID,
                    reason: reason
                )
            }
        }

        for windowID in ownerWindowsToClear {
            clearActiveToolOwner(windowID: windowID, connectionID: connectionID)
        }

        return cancelledCount
    }

    /// Run `op` while marking this connection as the active-tool owner for `windowID`.
    /// Ownership is always cleared, even if `op` throws.
    func withWindowToolOwnership<T>(
        windowID: Int,
        connectionID: UUID,
        toolName: String,
        _ op: @Sendable () async throws -> T
    ) async rethrows -> T {
        // Actor context: direct, synchronous calls (no await, no Task)
        markActiveToolOwner(windowID: windowID, connectionID: connectionID, toolName: toolName)
        defer {
            clearActiveToolOwner(windowID: windowID, connectionID: connectionID)
        }
        // Suspend actor while the body runs; resumes here to clear in defer.
        return try await op()
    }

    // ------------------------------------------------------------------
    // MARK: Window-selection helpers (called from WindowRoutingService)

    /// ------------------------------------------------------------------
    func setActiveWindowForCurrentConnection(_ windowID: Int) async throws {
        guard let connID = Self.currentConnectionID else {
            throw MCPError.internalError("No active connection context")
        }
        setConnectionWindowMapping(connID, windowID: windowID)
    }

    func clearActiveWindowForCurrentConnection() async throws {
        guard let connID = Self.currentConnectionID else {
            throw MCPError.internalError("No active connection context")
        }
        clearConnectionWindowMapping(connID)
        clearPersistedWindowAffinity(for: connID)
    }

    func selectedWindow(for connectionID: UUID) -> Int? {
        connectionWindowMap[connectionID]
    }

    private func setConnectionWindowMapping(_ connectionID: UUID, windowID: Int) {
        connectionWindowMap[connectionID] = windowID
        windowAssignmentByConnection[connectionID] = windowID

        // Update per-client memory and persist routing (token-backed only)
        guard let clientID = clientIdentifier(forConnection: connectionID) else { return }

        // Resolve sessionKey - only update in-memory map for token-backed clients
        let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
        if let sessionKey {
            let storageKey = bestStorageKey(for: clientID, in: Array(lastWindowByClientSession.keys))
            lastWindowByClientSession[storageKey, default: [:]][sessionKey] = windowID
        }

        Task { [weak self] in
            await self?.updateRoutingRecordForConnection(connectionID, clientID: clientID)
        }
    }

    private func clearConnectionWindowMapping(_ connectionID: UUID) {
        connectionWindowMap.removeValue(forKey: connectionID)
        windowAssignmentByConnection.removeValue(forKey: connectionID)
    }

    private func clearPersistedWindowAffinity(for connectionID: UUID) {
        guard let clientID = clientIdentifier(forConnection: connectionID) else { return }
        guard let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID] else {
            return
        }

        for key in matchingClientKeys(for: clientID, in: Array(lastWindowByClientSession.keys)) {
            if var sessionMap = lastWindowByClientSession[key] {
                sessionMap.removeValue(forKey: sessionKey)
                if sessionMap.isEmpty {
                    lastWindowByClientSession.removeValue(forKey: key)
                } else {
                    lastWindowByClientSession[key] = sessionMap
                }
            }
        }

        var stateChanged = false
        for key in matchingClientKeys(for: clientID, in: Array(routingState.records.keys)) {
            guard var records = routingState.records[key] else { continue }
            var changed = false
            for index in records.indices {
                guard records[index].sessionKey == sessionKey, records[index].lastWindowID != nil else { continue }
                records[index].lastWindowID = nil
                changed = true
            }
            guard changed else { continue }
            routingState.records[key] = records
            stateChanged = true
        }
        guard stateChanged else { return }
        saveRoutingState()
    }

    private func effectivePolicyState(for connectionID: UUID) -> (restricted: Set<String>, additional: Set<String>, preassigned: Bool, purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind?, allowsAgentExternalControlTools: Bool) {
        let restricted = restrictedToolsByConnection[connectionID] ?? []
        let additional = additionalToolsByConnection[connectionID] ?? []
        let preassigned = preassignedConnections.contains(connectionID)
        let purpose = runPurposeByConnection[connectionID] ?? .unknown
        let runState: RunConnectionPolicyState? = {
            guard let runID = runIDByConnectionID[connectionID] else { return nil }
            return runPolicyStateByRunID[runID]
        }()
        let taskLabelKind = runState?.taskLabelKind
        let allowsAgentExternalControlTools = runState?.allowsAgentExternalControlTools ?? false
        return (restricted, additional, preassigned, purpose, taskLabelKind, allowsAgentExternalControlTools)
    }

    #if DEBUG
        private func debugPolicyDiagnosticFields(
            connectionID: UUID,
            policy: (restricted: Set<String>, additional: Set<String>, preassigned: Bool, purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind?, allowsAgentExternalControlTools: Bool)? = nil,
            extra: [String: String] = [:]
        ) -> [String: String] {
            let effective = policy ?? effectivePolicyState(for: connectionID)
            let runID = runIDByConnectionID[connectionID]
            let runState = runID.flatMap { runPolicyStateByRunID[$0] }
            var fields = extra
            fields["connectionID"] = connectionID.uuidString
            fields["runID"] = runID?.uuidString ?? "nil"
            fields["tabID"] = runState?.tabID?.uuidString ?? "nil"
            fields["windowID"] = connectionWindowMap[connectionID].map(String.init) ?? runState.map { String($0.windowID) } ?? "nil"
            fields["purpose"] = effective.purpose.rawValue
            fields["taskLabel"] = effective.taskLabelKind?.rawValue ?? "nil"
            fields["additionalTools"] = Self.debugDescribeToolSet(effective.additional)
            fields["restrictedTools"] = Self.debugDescribeToolSet(effective.restricted)
            fields["preassigned"] = String(effective.preassigned)
            fields["allowsAgentExternalControlTools"] = String(effective.allowsAgentExternalControlTools)
            fields["hasRunPolicy"] = String(runState != nil)
            return fields
        }

        private static func debugDescribeToolSet(_ tools: Set<String>) -> String {
            guard !tools.isEmpty else { return "[]" }
            return "[" + tools.sorted().joined(separator: ",") + "]"
        }

        private func debugPolicyDiagnostic(_ name: String, connectionID: UUID, policy: (restricted: Set<String>, additional: Set<String>, preassigned: Bool, purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind?, allowsAgentExternalControlTools: Bool)? = nil, extra: [String: String] = [:]) {
            AgentModePerfDiagnostics.event(
                "mcp.policy.\(name)",
                fields: debugPolicyDiagnosticFields(connectionID: connectionID, policy: policy, extra: extra)
            )
        }
    #endif

    func clearWindowSelectionIfClosed(_ windowID: Int) {
        let toClear = connectionWindowMap.filter { $0.value == windowID }.map(\.key)
        for cid in toClear {
            connectionWindowMap[cid] = nil
            windowAssignmentByConnection[cid] = nil // Keep both maps consistent
            runIDByConnectionID[cid] = nil
        }

        // Also clear ownership for this window to avoid stale "owned by …" logs
        activeToolOwnerByWindow.removeValue(forKey: windowID)
        activeToolNameByWindow.removeValue(forKey: windowID)

        // Remove stale run→window cache entries for the closed window.
        let staleRunIDs = windowIDByRunID.compactMap { runID, mappedWindowID in
            mappedWindowID == windowID ? runID : nil
        }
        for runID in staleRunIDs {
            windowIDByRunID.removeValue(forKey: runID)
        }
        if !staleRunIDs.isEmpty {
            let staleRunIDSet = Set(staleRunIDs)
            let staleConnections = runIDByConnectionID.compactMap { connectionID, runID in
                staleRunIDSet.contains(runID) ? connectionID : nil
            }
            for connectionID in staleConnections {
                runIDByConnectionID.removeValue(forKey: connectionID)
            }
        }
        dashboardDidChangeHook?()

        // Remove in-memory mapping to this window (nested structure: clientID -> sessionKey -> windowID)
        let clientIDs = Array(lastWindowByClientSession.keys)
        for clientID in clientIDs {
            guard var sessionMap = lastWindowByClientSession[clientID] else { continue }
            let sessionsToClear = sessionMap.filter { $0.value == windowID }.map(\.key)
            for sessionKey in sessionsToClear {
                sessionMap.removeValue(forKey: sessionKey)
            }
            if sessionMap.isEmpty {
                lastWindowByClientSession.removeValue(forKey: clientID)
            } else {
                lastWindowByClientSession[clientID] = sessionMap
            }
        }

        // Update routingState.records to null out invalid lastWindowID
        var stateChanged = false
        let recordKeys = Array(routingState.records.keys)
        for clientID in recordKeys {
            guard let records = routingState.records[clientID] else { continue }
            var changed = false
            let updated = records.map { record -> MCPRoutingState.ClientRecord in
                var r = record
                if r.lastWindowID == windowID {
                    r.lastWindowID = nil
                    changed = true
                }
                return r
            }
            if changed {
                routingState.records[clientID] = updated
                stateChanged = true
            }
        }
        if stateChanged {
            saveRoutingState()
        }
    }

    /// Ensures a connection has a window binding when the choice is unambiguous.
    /// This provides a single-window fallback for early protocol calls (tools/list, handshake)
    /// that occur before explicit window selection.
    ///
    /// Returns the effective window ID if binding is unambiguous, nil if multi-window ambiguity exists.
    ///
    /// Binding logic:
    /// 1. If connection already has a mapping → use it
    /// 2. If exactly one MCP-enabled window exists → bind to it
    /// 3. If connection was established during single-window mode → bind to first MCP-enabled window
    /// 4. If multi-window mode is not effectively active → bind to first MCP-enabled window
    /// 5. Otherwise → nil (multi-window ambiguous, caller should fail closed or prompt selection)
    private func ensureWindowBindingIfUnambiguous(connectionID: UUID, reason: String) async -> Int? {
        // Check existing mapping first
        if let existing = connectionWindowMap[connectionID] {
            return existing
        }

        // Get window state on MainActor
        let (mcpEnabledWindows, multiWindowEffective) = await MainActor.run {
            let windows = WindowStatesManager.shared.allWindows.filter(\.mcpServer.windowToolsEnabled)
            let effective = WindowStatesManager.shared.isMultiWindowModeEffectivelyActive
            return (windows, effective)
        }

        // Single MCP-enabled window → unambiguous binding
        if mcpEnabledWindows.count == 1, let window = mcpEnabledWindows.first {
            let windowID = window.windowID
            setConnectionWindowMapping(connectionID, windowID: windowID)
            connectionLog("\(reason): auto-bound connection \(connectionID) to single MCP-enabled window \(windowID)")
            return windowID
        }

        // Connection established during single-window mode stays bound.
        // If capture is missing, treat as unknown and only infer single-window when
        // current mode is also effectively single-window.
        let connectedDuringSingleWindow: Bool
        if let recordedWindowCount = windowCountAtConnectionTime[connectionID] {
            connectedDuringSingleWindow = recordedWindowCount == 1
        } else {
            connectedDuringSingleWindow = !multiWindowEffective && mcpEnabledWindows.count <= 1
            if multiWindowEffective {
                connectionLog("\(reason): missing connection-time window count for \(connectionID); treating as multi-window")
            }
        }
        if connectedDuringSingleWindow || !multiWindowEffective {
            if let firstWindow = await WindowStatesManager.shared.firstMCPEnabledWindow() {
                let windowID = firstWindow.windowID
                setConnectionWindowMapping(connectionID, windowID: windowID)
                let bindReason = connectedDuringSingleWindow ? "single-window-at-connect" : "single-window-mode"
                connectionLog("\(reason): auto-bound connection \(connectionID) to window \(windowID) (\(bindReason))")
                return windowID
            }
        }

        // Multi-window ambiguous - caller must handle
        connectionLog("\(reason): connection \(connectionID) has no unambiguous window binding (multi-window active)")
        return nil
    }

    // ------------------------------------------------------------------

    func currentClientIdentifier() -> String? {
        guard let connectionID = Self.currentConnectionID else { return nil }
        if let admitted = clientIDByConnection[connectionID] {
            return admitted
        }
        if let pending = pendingConnections[connectionID] {
            return pending
        }
        return nil
    }

    func currentConnectionWindowID() -> Int? {
        guard let connectionID = Self.currentConnectionID else { return nil }
        return connectionWindowMap[connectionID]
    }

    func currentConnectionUUID() -> UUID? {
        Self.currentConnectionID
    }

    /// Runs the given async operation with the TaskLocal connectionID set.
    /// Use this to propagate the connection context across Task boundaries.
    nonisolated static func withConnectionID<T>(
        _ connectionID: UUID?,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentConnectionID.withValue(connectionID, operation: operation)
    }

    func clientIdentifier(forConnection id: UUID) -> String? {
        if let admitted = clientIDByConnection[id] {
            return admitted
        }
        if let pending = pendingConnections[id] {
            return pending
        }
        return nil
    }

    /// Returns the run purpose for a connection, used for UI routing (e.g., ask_user).
    func runPurpose(for connectionID: UUID) -> MCPRunPurpose {
        runPurposeByConnection[connectionID] ?? .unknown
    }

    func setRunPurpose(_ purpose: MCPRunPurpose, for connectionID: UUID) {
        runPurposeByConnection[connectionID] = purpose
    }

    func hasCachedRunPolicyState(for runID: UUID) -> Bool {
        runPolicyStateByRunID[runID] != nil
    }

    func cachedRunPolicyWindowID(for runID: UUID) -> Int? {
        runPolicyStateByRunID[runID]?.windowID
    }

    private func reusableWindowForClient(newConnectionID: UUID, clientName: String) async -> Int? {
        for (existingID, windowID) in connectionWindowMap where existingID != newConnectionID {
            guard MCPClientIdentity.matches(clientIDByConnection[existingID], clientName) else { continue }
            if let existingManager = connections[existingID] {
                let existingViable = await existingManager.isViableForRetention()
                if existingViable {
                    // Existing connection is healthy; do not auto-route the newcomer.
                    return nil
                } else {
                    return windowID
                }
            } else {
                return windowID
            }
        }
        return nil
    }

    /// Get the runID associated with a connection (if any)
    /// Fast path uses actor-local cache; fallback scans all windows for resilient recovery.
    func runIDForConnection(_ connectionID: UUID) async -> UUID? {
        if let cachedRunID = runIDByConnectionID[connectionID] {
            return cachedRunID
        }

        let resolved = await MainActor.run { () -> (runID: UUID, windowID: Int)? in
            for window in WindowStatesManager.shared.allWindows {
                guard let candidateRunID = window.mcpServer.connectionIDToRunID[connectionID],
                      let runID = Self.validatedLiveRunID(
                          candidateRunID: candidateRunID,
                          connectionID: connectionID,
                          connectionIDByRunID: window.mcpServer.connectionIDByRunID,
                          connectionIDToRunID: window.mcpServer.connectionIDToRunID
                      )
                else {
                    continue
                }
                return (runID, window.windowID)
            }
            return nil
        }
        guard let resolved else {
            connectionLog("runIDForConnection: no run mapping found for connection \(connectionID)")
            return nil
        }

        runIDByConnectionID[connectionID] = resolved.runID
        windowIDByRunID[resolved.runID] = resolved.windowID
        return resolved.runID
    }

    func toolTrackingRunIDForCompletion(
        callTimeRunID: UUID?,
        connectionID: UUID,
        toolName: String,
        invocationID: UUID,
        context: String
    ) async -> UUID? {
        if let callTimeRunID {
            if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName),
               let completionTimeRunID = await runIDForConnection(connectionID),
               completionTimeRunID != callTimeRunID
            {
                mcpToolTrackingDiagnostic(
                    "MCP observer completion runID changed context=\(context) conn=\(connectionID.uuidString) " +
                        "tool=\(toolName) invocation=\(invocationID.uuidString) " +
                        "callRunID=\(callTimeRunID.uuidString) completionRunID=\(completionTimeRunID.uuidString) " +
                        "usingCallTimeRunID=true"
                )
            }
            return callTimeRunID
        }

        let completionTimeRunID = await runIDForConnection(connectionID)
        if let completionTimeRunID {
            if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
                mcpToolTrackingDiagnostic(
                    "MCP observer completion re-resolved runID context=\(context) conn=\(connectionID.uuidString) " +
                        "tool=\(toolName) invocation=\(invocationID.uuidString) " +
                        "runID=\(completionTimeRunID.uuidString)"
                )
            }
            return completionTimeRunID
        }

        if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
            mcpToolTrackingDiagnostic(
                "MCP observer completion skipped no runID context=\(context) conn=\(connectionID.uuidString) " +
                    "tool=\(toolName) invocation=\(invocationID.uuidString)"
            )
        }
        return nil
    }

    /// Map a connection to a runID for server-managed reconnect/handover scenarios.
    /// This creates the connectionID → runID mapping that enables tool tracking across connections.
    @discardableResult
    func mapConnectionToRunID(
        _ connectionID: UUID,
        runID: UUID,
        windowID explicitWindowID: Int? = nil,
        persistWindowBinding: Bool = true
    ) async -> Bool {
        let resolvedWindowID: Int? = if let explicitWindowID {
            explicitWindowID
        } else if let mappedWindowID = connectionWindowMap[connectionID] {
            mappedWindowID
        } else {
            await windowIDForRunID(runID)
        }
        guard let windowID = resolvedWindowID else {
            log.warning("mapConnectionToRunID: cannot map connection \(connectionID) to run \(runID) - no window assignment")
            return false
        }

        // Fast path: if this connection is already mapped to this run in this window,
        // avoid re-registering and re-binding on every tool call.
        let alreadyMapped = await MainActor.run { () -> Bool in
            guard let window = WindowStatesManager.shared.window(withID: windowID) else {
                return false
            }
            let mappedRun = window.mcpServer.connectionIDToRunID[connectionID]
            let mappedConnection = window.mcpServer.connectionID(forRunID: runID)
            return mappedRun == runID && mappedConnection == connectionID
        }
        if alreadyMapped {
            if persistWindowBinding, connectionWindowMap[connectionID] != windowID {
                setConnectionWindowMapping(connectionID, windowID: windowID)
            }
            if persistWindowBinding {
                runIDByConnectionID[connectionID] = runID
            }
            windowIDByRunID[runID] = windowID
            return true
        }

        let registrationSucceeded = await MainActor.run { () -> Bool in
            guard let window = WindowStatesManager.shared.window(withID: windowID) else {
                log.warning("mapConnectionToRunID: window \(windowID) not found for connection \(connectionID)")
                return false
            }

            // Update bidirectional mappings in MCPServerViewModel
            let didRegister = window.mcpServer.registerRunIDMapping(
                connectionID: connectionID,
                runID: runID,
                windowID: windowID
            )
            if didRegister {
                connectionLog("mapConnectionToRunID: mapped connection \(connectionID) to runID \(runID) in window \(windowID)")
            }
            return didRegister
        }
        guard registrationSucceeded else {
            log.warning("mapConnectionToRunID: registerRunIDMapping refused connection \(connectionID) run \(runID) window \(windowID)")
            return false
        }

        if persistWindowBinding, connectionWindowMap[connectionID] != windowID {
            setConnectionWindowMapping(connectionID, windowID: windowID)
        }
        if persistWindowBinding {
            runIDByConnectionID[connectionID] = runID
        }
        windowIDByRunID[runID] = windowID
        updateLiveRunAffinity(
            clientName: clientIdentifier(forConnection: connectionID) ?? "",
            sessionKey: connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID],
            runID: runID,
            windowID: windowID,
            purpose: runPurposeByConnection[connectionID] ?? runPolicyStateByRunID[runID]?.purpose
        )

        // Rehydrate run-scoped policy grants/restrictions on reconnect handovers.
        await applyRunPolicyStateIfAvailable(
            runID: runID,
            connectionID: connectionID,
            persistWindowBinding: persistWindowBinding
        )
        return true
    }

    private func seedRunPolicyState(
        runID: UUID,
        windowID: Int,
        workspaceID: UUID?,
        tabID: UUID?,
        restrictedTools: Set<String>,
        additionalTools: Set<String>?,
        purpose: MCPRunPurpose,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        updatedAt: Date
    ) {
        if let existing = runPolicyStateByRunID[runID], existing.updatedAt >= updatedAt {
            return
        }
        runPolicyStateByRunID[runID] = RunConnectionPolicyState(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            restrictedTools: restrictedTools,
            additionalTools: additionalTools,
            purpose: purpose,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            updatedAt: updatedAt
        )
        windowIDByRunID[runID] = windowID
    }

    private func cacheRunPolicyStateIfNeeded(_ policy: ClientConnectionPolicy) {
        guard let runID = policy.runID else { return }
        seedRunPolicyState(
            runID: runID,
            windowID: policy.windowID,
            workspaceID: nil,
            tabID: policy.tabID,
            restrictedTools: policy.restrictedTools,
            additionalTools: policy.additionalTools,
            purpose: policy.purpose,
            taskLabelKind: policy.taskLabelKind,
            allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools,
            updatedAt: policy.createdAt
        )
    }

    private nonisolated static func normalizedClientName(_ clientName: String) -> String {
        MCPClientIdentity.normalized(clientName) ?? ""
    }

    private nonisolated static func clientStorageKey(_ clientName: String) -> String {
        MCPClientIdentity.storageKey(clientName) ?? normalizedClientName(clientName)
    }

    private func matchingClientKeys(for clientName: String, in availableKeys: [String]) -> [String] {
        guard !Self.normalizedClientName(clientName).isEmpty else { return [] }
        let canonicalKey = Self.clientStorageKey(clientName)
        var seen = Set<String>()
        var matches: [String] = []

        if availableKeys.contains(clientName), seen.insert(clientName).inserted {
            matches.append(clientName)
        }
        if availableKeys.contains(canonicalKey), seen.insert(canonicalKey).inserted {
            matches.append(canonicalKey)
        }

        for key in availableKeys.sorted() where MCPClientIdentity.matches(key, clientName) {
            guard seen.insert(key).inserted else { continue }
            matches.append(key)
        }

        return matches
    }

    private func bestStorageKey(for clientName: String, in availableKeys: [String]) -> String {
        matchingClientKeys(for: clientName, in: availableKeys).first ?? Self.clientStorageKey(clientName)
    }

    private nonisolated static func isKnownAgentClientName(_ clientName: String) -> Bool {
        guard !normalizedClientName(clientName).isEmpty else { return false }
        for agent in AgentProviderKind.allCases {
            guard let hint = agent.mcpClientNameHint else { continue }
            if MCPClientIdentity.matches(clientName, hint) {
                return true
            }
        }
        return false
    }

    private func shouldAllowPersistedAgentModeRestore(clientName: String, purpose: MCPRunPurpose) -> Bool {
        purpose != .agentModeRun || Self.isKnownAgentClientName(clientName)
    }

    private func updateLiveRunAffinity(
        clientName: String,
        sessionKey: String?,
        runID: UUID?,
        windowID: Int?,
        purpose: MCPRunPurpose?
    ) {
        guard !clientName.isEmpty, let sessionKey, let runID, let windowID else { return }
        let resolvedPurpose = purpose ?? runPolicyStateByRunID[runID]?.purpose ?? .unknown
        guard shouldAllowPersistedAgentModeRestore(clientName: clientName, purpose: resolvedPurpose) else {
            return
        }
        let storageKey = bestStorageKey(
            for: clientName,
            in: Array(liveRunAffinityByClientSession.keys)
        )
        liveRunAffinityByClientSession[storageKey, default: [:]][sessionKey] = LiveRunAffinity(
            windowID: windowID,
            runID: runID,
            purpose: resolvedPurpose,
            lastSeenAt: Date()
        )
    }

    private func preferredLiveRunAffinity(
        for clientName: String,
        sessionKey: String?
    ) -> LiveRunAffinity? {
        guard let sessionKey else {
            return nil
        }
        let matchingKeys = matchingClientKeys(
            for: clientName,
            in: Array(liveRunAffinityByClientSession.keys)
        )
        guard let matchedKey = matchingKeys.first,
              let affinity = liveRunAffinityByClientSession[matchedKey]?[sessionKey]
        else {
            return nil
        }
        guard let cached = runPolicyStateByRunID[affinity.runID] else {
            liveRunAffinityByClientSession[matchedKey]?[sessionKey] = nil
            if liveRunAffinityByClientSession[matchedKey]?.isEmpty == true {
                liveRunAffinityByClientSession.removeValue(forKey: matchedKey)
            }
            return nil
        }
        let refreshed = LiveRunAffinity(
            windowID: cached.windowID,
            runID: affinity.runID,
            purpose: cached.purpose,
            lastSeenAt: affinity.lastSeenAt
        )
        liveRunAffinityByClientSession[matchedKey, default: [:]][sessionKey] = refreshed
        return refreshed
    }

    private func preferredExpectedPIDRunAffinity(
        for clientName: String,
        clientPid: Int?
    ) -> LiveRunAffinity? {
        guard let clientPid else { return nil }
        let clientExpectedPIDs = expectedAgentPIDs(for: clientName)
        guard !clientExpectedPIDs.isEmpty else { return nil }

        return expectedAgentPIDsByRunID.compactMap { runID, runExpectedPIDs -> (affinity: LiveRunAffinity, updatedAt: Date)? in
            let expectedPIDs = runExpectedPIDs.intersection(clientExpectedPIDs)
            guard admittedPolicyRunIDs.contains(runID),
                  !expectedPIDs.isEmpty,
                  isAncestor(expectedPIDs: expectedPIDs, ofPid: pid_t(clientPid)),
                  let cached = runPolicyStateByRunID[runID],
                  shouldAllowPersistedAgentModeRestore(clientName: clientName, purpose: cached.purpose)
            else {
                return nil
            }
            return (
                affinity: LiveRunAffinity(
                    windowID: cached.windowID,
                    runID: runID,
                    purpose: cached.purpose,
                    lastSeenAt: cached.updatedAt
                ),
                updatedAt: cached.updatedAt
            )
        }
        .max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }?
        .affinity
    }

    private func oldestPendingPolicyEntry(for clientName: String) -> (key: String, policy: ClientConnectionPolicy)? {
        guard let entry = oldestPendingPolicyEntry(for: clientName, where: { _ in true }) else { return nil }
        return (key: entry.key, policy: entry.policy)
    }

    private func oldestPendingPolicyEntry(
        for clientName: String,
        where predicate: (ClientConnectionPolicy) -> Bool
    ) -> (key: String, index: Int, policy: ClientConnectionPolicy)? {
        pruneExpiredPolicies(for: clientName)
        let matchingKeys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        return matchingKeys
            .flatMap { key -> [(key: String, index: Int, policy: ClientConnectionPolicy)] in
                let queue = pendingPoliciesByClient[key] ?? []
                return queue.indices.compactMap { index in
                    let policy = queue[index]
                    guard predicate(policy) else { return nil }
                    return (key: key, index: index, policy: policy)
                }
            }
            .min { lhs, rhs in
                if lhs.policy.createdAt == rhs.policy.createdAt {
                    if lhs.key == rhs.key {
                        return lhs.index < rhs.index
                    }
                    return lhs.key < rhs.key
                }
                return lhs.policy.createdAt < rhs.policy.createdAt
            }
    }

    private func hasAgentPolicyAdmissionTarget(
        clientName: String,
        sessionKey: String?,
        clientPid: Int? = nil
    ) -> Bool {
        if oldestPendingPolicyEntry(for: clientName) != nil {
            return true
        }
        if preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) != nil {
            return true
        }
        return preferredExpectedPIDRunAffinity(for: clientName, clientPid: clientPid) != nil
    }

    private func hasPendingAgentBootstrapIntent(
        clientName: String,
        sessionKey: String?,
        clientPid: Int? = nil
    ) -> Bool {
        oldestPendingPolicyEntry(for: clientName) != nil
            || !expectedAgentPIDs(for: clientName).isEmpty
            || preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) != nil
            || preferredExpectedPIDRunAffinity(for: clientName, clientPid: clientPid) != nil
    }

    private func clearLiveRunAffinity(for runID: UUID) {
        let clientNames = Array(liveRunAffinityByClientSession.keys)
        for clientName in clientNames {
            guard var sessionMap = liveRunAffinityByClientSession[clientName] else { continue }
            sessionMap = sessionMap.filter { $0.value.runID != runID }
            if sessionMap.isEmpty {
                liveRunAffinityByClientSession.removeValue(forKey: clientName)
            } else {
                liveRunAffinityByClientSession[clientName] = sessionMap
            }
        }
    }

    private func applyRunPolicyStateIfAvailable(
        runID: UUID,
        connectionID: UUID,
        persistWindowBinding: Bool = true
    ) async {
        guard let cached = runPolicyStateByRunID[runID] else { return }

        restrictedToolsByConnection[connectionID] = cached.restrictedTools
        if let additional = cached.additionalTools {
            additionalToolsByConnection[connectionID] = additional
        } else {
            additionalToolsByConnection.removeValue(forKey: connectionID)
        }
        runPurposeByConnection[connectionID] = cached.purpose
        preassignedConnections.insert(connectionID)
        if persistWindowBinding {
            runIDByConnectionID[connectionID] = runID
        }

        if persistWindowBinding, connectionWindowMap[connectionID] != cached.windowID {
            setConnectionWindowMapping(connectionID, windowID: cached.windowID)
        }
        updateLiveRunAffinity(
            clientName: clientIdentifier(forConnection: connectionID) ?? "",
            sessionKey: connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID],
            runID: runID,
            windowID: cached.windowID,
            purpose: cached.purpose
        )

        _ = await ensureTabBoundForRunIfPossible(
            connectionID: connectionID,
            clientName: clientIdentifier(forConnection: connectionID),
            runID: runID,
            windowID: cached.windowID
        )

        if connections[connectionID] != nil {
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    func connectionID(for clientName: String, windowID: Int) -> UUID? {
        // Use canonical connectionWindowMap for consistency
        if let active = activeConnectionsByClient[clientName] {
            for id in active {
                if connectionWindowMap[id] == windowID {
                    return id
                }
            }
        }
        for (id, pendingName) in pendingConnections where pendingName == clientName {
            if connectionWindowMap[id] == windowID {
                return id
            }
        }
        return nil
    }

    func runPolicyPurpose(for runID: UUID) -> MCPRunPurpose? {
        runPolicyStateByRunID[runID]?.purpose
    }

    @discardableResult
    func rehydrateRunTabContextForConnectionIfPossible(_ connectionID: UUID) async -> Bool {
        guard let runID = await runIDForConnection(connectionID),
              let cached = runPolicyStateByRunID[runID],
              cached.purpose == .agentModeRun,
              cached.tabID != nil
        else {
            return false
        }
        await applyRunPolicyStateIfAvailable(runID: runID, connectionID: connectionID)
        return await ensureTabBoundForRunIfPossible(
            connectionID: connectionID,
            clientName: clientIdentifier(forConnection: connectionID),
            runID: runID,
            windowID: cached.windowID
        )
    }

    typealias ConnectionApprovalHandler = @Sendable (UUID, MCP.Client.Info) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    private var serviceBindings: [String: Binding<Bool>] = [:]

    func isRunning() -> Bool {
        isRunningState
    }

    func setConnectionApprovalHandler(_ handler: @escaping ConnectionApprovalHandler) {
        connectionLog("Setting connection approval handler")
        connectionApprovalHandler = handler
    }

    /// Register a tool call observer for a specific discovery run (by runID, survives connection handovers)
    /// Returns a token that can be used for targeted unregistration (optional)
    @discardableResult
    func registerToolCallObserver(for runID: UUID, observer: @escaping @Sendable (String) -> Void) -> UUID {
        let token = UUID()
        toolCallObservers[runID, default: [:]][token] = observer
        connectionLog("Registered tool call observer for runID: \(runID) token: \(token)")
        return token
    }

    /// Unregister a specific tool call observer by token
    func unregisterToolCallObserver(for runID: UUID, token: UUID) async {
        toolCallObservers[runID]?.removeValue(forKey: token)
        if toolCallObservers[runID]?.isEmpty ?? false {
            toolCallObservers.removeValue(forKey: runID)
        }
        connectionLog("Unregistered tool call observer token \(token) for runID: \(runID)")
    }

    /// Unregister all tool observers for a specific run.
    /// This only removes observers and does not mutate run routing state.
    func unregisterToolObservers(for runID: UUID) async {
        toolCallObservers.removeValue(forKey: runID)
        toolEventObservers.removeValue(forKey: runID)
        connectionLog("Unregistered all tool observers for runID: \(runID)")
    }

    /// Explicitly clears run-scoped routing/policy state.
    /// Use this at true end-of-scope boundaries (session deletion, tab/window close),
    /// not for normal observer lifecycle teardown.
    func cleanupRunRoutingState(for runID: UUID, windowID: Int? = nil) async {
        runPolicyStateByRunID.removeValue(forKey: runID)
        admittedPolicyRunIDs.remove(runID)
        windowIDByRunID.removeValue(forKey: runID)
        clearLiveRunAffinity(for: runID)
        let connectionIDsForRun = runIDByConnectionID.compactMap { connectionID, mappedRunID in
            mappedRunID == runID ? connectionID : nil
        }
        for connectionID in connectionIDsForRun {
            runIDByConnectionID.removeValue(forKey: connectionID)
        }

        await MainActor.run {
            let windows = WindowStatesManager.shared.allWindows.filter { window in
                guard let windowID else { return true }
                return window.windowID == windowID
            }
            for window in windows {
                if let connectionID = window.mcpServer.connectionID(forRunID: runID) {
                    window.mcpServer.cleanupRunIDMapping(runID: runID, connectionID: connectionID)
                    connectionLog("Cleaned up runID mapping for runID \(runID) in window \(window.windowID)")
                }
            }
        }
    }

    /// Explicitly clears cached run routing/policy state for any runs associated with a closed tab.
    /// Preserves window affinity while dropping tab-scoped run state.
    func cleanupRunRoutingState(forTabID tabID: UUID, windowID: Int? = nil) async {
        let targetRunIDs = runPolicyStateByRunID.compactMap { runID, state -> UUID? in
            guard state.tabID == tabID else { return nil }
            if let windowID, state.windowID != windowID {
                return nil
            }
            return runID
        }

        guard !targetRunIDs.isEmpty else { return }
        for runID in targetRunIDs {
            await cleanupRunRoutingState(for: runID, windowID: windowID)
        }
    }

    /// Unregister all tool call observers for a specific discovery run.
    /// By default this preserves legacy behavior and also clears run routing state.
    func unregisterToolCallObserver(for runID: UUID, cleanupRouting: Bool = true) async {
        await unregisterToolObservers(for: runID)
        guard cleanupRouting else { return }
        await cleanupRunRoutingState(for: runID)
    }

    /// Notify all observers registered for a runID that a tool was invoked.
    /// Returns how many observers were fired.
    @discardableResult
    func fireToolCallObservers(runID: UUID, toolName: String) async -> Int {
        guard let observers = toolCallObservers[runID], !observers.isEmpty else {
            return 0
        }
        for (_, callback) in observers {
            callback(toolName)
        }
        connectionLog("Tool call observer fired for runID \(runID) tool \(toolName) count \(observers.count)")
        return observers.count
    }

    // MARK: - Enhanced Tool Event Observers (with args and results)

    /// Register an enhanced tool event observer that receives args on call and result on completion
    @discardableResult
    func registerToolEventObserver(for runID: UUID, observer: ToolEventObserver) -> UUID {
        let token = UUID()
        toolEventObservers[runID, default: [:]][token] = observer
        connectionLog("Registered tool event observer for runID: \(runID) token: \(token)")
        return token
    }

    /// Unregister all tool event observers for a specific run
    func unregisterToolEventObservers(for runID: UUID) async {
        toolEventObservers.removeValue(forKey: runID)
        connectionLog("Unregistered all tool event observers for runID: \(runID)")
    }

    func toolCallObserverCount(for runID: UUID? = nil) -> Int {
        if let runID {
            return toolCallObservers[runID]?.count ?? 0
        }
        return toolCallObservers.values.reduce(into: 0) { partialResult, observers in
            partialResult += observers.count
        }
    }

    func toolEventObserverCount(for runID: UUID? = nil) -> Int {
        if let runID {
            return toolEventObservers[runID]?.count ?? 0
        }
        return toolEventObservers.values.reduce(into: 0) { partialResult, observers in
            partialResult += observers.count
        }
    }

    /// Notify observers when a tool is called (with args).
    /// Deliver synchronously to preserve ordering with completion callbacks in the same turn.
    @discardableResult
    func fireToolCalledObservers(runID: UUID, invocationID: UUID, toolName: String, args: [String: Value]?) async -> Int {
        guard let observers = toolEventObservers[runID], !observers.isEmpty else {
            if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
                mcpToolTrackingDiagnostic(
                    "MCP observer call skipped no event observers runID=\(runID.uuidString) " +
                        "tool=\(toolName) invocation=\(invocationID.uuidString)"
                )
            }
            return 0
        }
        for (_, observer) in observers {
            await observer.onCalled(invocationID, toolName, args)
        }
        connectionLog("Tool called observers fired for runID \(runID) tool \(toolName) count \(observers.count)")
        return observers.count
    }

    /// Notify observers when a tool completes (with result).
    /// Deliver synchronously so tool cards can finalize before run-end fallback logic executes.
    @discardableResult
    func fireToolCompletedObservers(runID: UUID, invocationID: UUID, toolName: String, args: [String: Value]?, resultJSON: String, isError: Bool) async -> Int {
        guard let observers = toolEventObservers[runID], !observers.isEmpty else {
            if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
                mcpToolTrackingDiagnostic(
                    "MCP observer completion skipped no event observers runID=\(runID.uuidString) " +
                        "tool=\(toolName) invocation=\(invocationID.uuidString) isError=\(isError) resultChars=\(resultJSON.count)"
                )
            }
            return 0
        }
        for (_, observer) in observers {
            guard let onCompleted = observer.onCompleted else { continue }
            await onCompleted(invocationID, toolName, args, resultJSON, isError)
        }
        connectionLog("Tool completed observers fired for runID \(runID) tool \(toolName) count \(observers.count)")
        return observers.count
    }

    // MARK: - Connection Waiter Helpers (event-driven, replaces 100ms polling)

    /// Find a matching connection among current connections, excluding those in the exclude set.
    /// Checks both admitted (clientIDByConnection) and pending (pendingConnections) names.
    private func findMatchingConnection(excluding: Set<UUID>, clientName: String?) -> UUID? {
        for (id, _) in connections {
            guard !excluding.contains(id) else { continue }

            if let nameFilter = clientName {
                // Prefer authoritative admission mapping
                if MCPClientIdentity.matches(clientIDByConnection[id], nameFilter) {
                    return id
                }
                // Also accept pre-admission handshake name
                if MCPClientIdentity.matches(pendingConnections[id], nameFilter) {
                    return id
                }
                // No name yet or mismatched
                continue
            } else {
                // No filter - return first new connection
                return id
            }
        }
        return nil
    }

    /// Resume a waiter with a result (connection ID or nil for timeout/cancel).
    /// Ensures single-shot resumption by removing waiter before resuming.
    private func resumeWaiter(_ waiterID: UUID, with connectionID: UUID?) {
        guard let waiter = connectionWaiters.removeValue(forKey: waiterID) else { return }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: connectionID)
    }

    /// Cancel a waiter (called from task cancellation handler).
    /// Note: Intentionally no logging here to avoid actor hop complexity during cancellation
    /// which can cause resource starvation/deadlock.
    private func cancelWaiter(_ waiterID: UUID) {
        guard let waiter = connectionWaiters.removeValue(forKey: waiterID) else { return }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: nil)
    }

    /// Notify waiters when a new connection arrives. Resumes the first matching waiter (FIFO).
    /// Called from handleBootstrapConnection after adding to connections.
    private func notifyConnectionWaiters(connectionID: UUID, clientName: String?) {
        let actualName = clientName ?? "unknown"
        var matchedWaiterID: UUID?

        for (waiterID, waiter) in connectionWaiters {
            guard !waiter.excludeExisting.contains(connectionID) else {
                mcpACPLog("[MCP-ACP] waiter=\(waiterID) connection=\(connectionID) skipped existing expected=\(waiter.clientName ?? "<any>") actual=\(actualName)")
                continue
            }
            let isMatch = waiter.clientName == nil || MCPClientIdentity.matches(waiter.clientName, clientName)
            mcpACPLog("[MCP-ACP] waiter=\(waiterID) connection=\(connectionID) expected=\(waiter.clientName ?? "<any>") actual=\(actualName) match=\(isMatch)")
            if isMatch {
                matchedWaiterID = waiterID
                break
            }
        }

        guard let matchID = matchedWaiterID else {
            mcpACPLog("[MCP-ACP] no waiter matched connection=\(connectionID) actual=\(actualName)")
            return
        }

        let waiter = connectionWaiters[matchID]
        connectionLog("Found new connection \(connectionID) for waiting client: \(waiter?.clientName ?? "any") (actual: \(actualName))")
        resumeWaiter(matchID, with: connectionID)
    }

    /// Wait for a new connection from a specific client (for Context Builder).
    /// Uses event-driven continuations instead of polling for efficiency.
    /// Returns the connection ID once established, or nil if timeout/cancelled.
    ///
    /// For name-filtered waits, we only exclude connections that already have the target
    /// client name. This allows bootstrap connections (which exist before MCP initialize)
    /// to satisfy waiters once their MCP client name is established.
    func waitForNewConnection(clientName: String?, timeout: TimeInterval = 10.0) async -> UUID? {
        // Compute exclusion set based on whether we're filtering by name
        let existing: Set<UUID>
        if let targetName = clientName {
            // Only exclude connections that already match this client name.
            // This allows bootstrap connections to satisfy waiters once MCP initialize arrives.
            let alreadyMatching = connections.keys.filter { id in
                let admitted = clientIDByConnection[id]
                let pending = pendingConnections[id]
                return admitted == targetName || pending == targetName
            }
            existing = Set(alreadyMatching)
        } else {
            // Unfiltered waiter: exclude all existing connections
            existing = Set(connections.keys)
        }

        // Fast path: check if a matching connection already exists
        if let match = findMatchingConnection(excluding: existing, clientName: clientName) {
            let label = clientIDByConnection[match] ?? pendingConnections[match] ?? "unknown"
            connectionLog("Found existing connection \(match) for client: \(label)")
            return match
        }

        // Generate waiter ID before entering continuation so cancellation handler can capture it
        let waiterID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UUID?, Never>) in
                // Schedule timeout task
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.handleWaiterTimeout(waiterID, clientName: clientName)
                }

                // Register the waiter
                let waiter = ConnectionWaiter(
                    clientName: clientName,
                    excludeExisting: existing,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                connectionWaiters[waiterID] = waiter

                // Recheck after registration to close race window:
                // A connection may have arrived between fast-path check and registration
                if let match = findMatchingConnection(excluding: existing, clientName: clientName) {
                    let label = clientIDByConnection[match] ?? pendingConnections[match] ?? "unknown"
                    connectionLog("Found connection \(match) for client: \(label) (post-registration recheck)")
                    resumeWaiter(waiterID, with: match)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(waiterID)
            }
        }
    }

    /// Handle waiter timeout - resume with nil if waiter still exists.
    private func handleWaiterTimeout(_ waiterID: UUID, clientName: String?) {
        guard connectionWaiters[waiterID] != nil else { return } // Already resolved
        if let clientName {
            connectionLog("Timed out waiting for connection from client: \(clientName)")
        } else {
            connectionLog("Timed out waiting for connection without client hint")
        }
        resumeWaiter(waiterID, with: nil)
    }

    /// Backwards-compatible overload that preserves previous call sites.
    func waitForNewConnection(clientName: String, timeout: TimeInterval = 10.0) async -> UUID? {
        await waitForNewConnection(clientName: Optional(clientName), timeout: timeout)
    }

    func start() async {
        #if DEBUG
            print("[MCPStartup] ServerNetworkManager.start entered")
        #endif
        connectionLog("Starting network manager")
        isRunningState = true

        // Start bootstrap socket server for UNIX socket connections before maintenance
        // health checks can observe and restart a not-yet-created socket.
        bootstrapSocketTask?.cancel()
        await startBootstrapSocketServer()

        // Start periodic maintenance loop for cleanup tasks
        startMaintenanceLoop()
    }

    /// Starts the periodic maintenance loop for cleanup tasks.
    private func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await maintenanceTick()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
        }
    }

    // Throttle kill signal cleanup (filesystem operations) to reduce overhead
    private var lastKillSignalCleanupAt: Date = .distantPast
    private let killSignalCleanupInterval: TimeInterval = 60.0

    /// Performs periodic maintenance: cleans up expired reservations, cooldowns, policies, and stale kill signals.
    private func maintenanceTick() async {
        // Safety-net cleanup for edge cases / crashy mid-flight states.
        cleanupExpiredBootstrapReservations()
        cleanupExpiredKilledSessions()
        cleanupExpiredUserKilledClients()
        cleanupExpiredClientConnectionPolicies()
        await pruneNonViableConnections()
        await pressureEvictIdleConnectionsIfNeeded()
        await ensureBootstrapHealthy()

        // Throttle kill signal cleanup (involves filesystem operations)
        let now = Date()
        if now.timeIntervalSince(lastKillSignalCleanupAt) >= killSignalCleanupInterval {
            lastKillSignalCleanupAt = now
            MCPKillSignal.cleanupStaleSignals()
        }
    }

    /// Removes expired queued ClientConnectionPolicy entries so they don't accumulate.
    /// Policies have TTL but were never pruned, causing unbounded growth over long runs.
    private func cleanupExpiredClientConnectionPolicies() {
        let now = Date()
        var removedCount = 0
        for (clientID, policies) in pendingPoliciesByClient {
            let filtered = policies.filter { now.timeIntervalSince($0.createdAt) < $0.ttl }
            if filtered.isEmpty {
                pendingPoliciesByClient.removeValue(forKey: clientID)
                removedCount += policies.count
            } else if filtered.count != policies.count {
                removedCount += policies.count - filtered.count
                pendingPoliciesByClient[clientID] = filtered
            }
        }
        if removedCount > 0 {
            connectionLog("Cleaned up \(removedCount) expired client connection policies")
        }
    }

    /// Prune connections that are no longer viable or have been stuck connecting too long.
    private func pruneNonViableConnections() async {
        guard !connections.isEmpty else { return }
        let now = Date()
        let connectingTimeout = TimeInterval(connectingTimeoutSeconds)
        var toRemove: [UUID] = []

        for (id, mgr) in connections {
            let state = await mgr.connectionState()
            if case .failed = state {
                toRemove.append(id)
                continue
            }
            if case .cancelled = state {
                toRemove.append(id)
                continue
            }
            let viable = await mgr.isViableForRetention()
            if !viable {
                toRemove.append(id)
                continue
            }
            if connectingTimeout > 0, state == .connecting {
                if let createdAt = connectionStats[id]?.createdAt,
                   now.timeIntervalSince(createdAt) > connectingTimeout
                {
                    log.warning("Pruning connection \(id) stuck in connecting for \(Int(now.timeIntervalSince(createdAt)))s")
                    toRemove.append(id)
                }
            }
        }

        for id in toRemove {
            await removeConnection(id)
        }
    }

    /// Under pressure, evict idle connections that exceed pressureEvictIdleSeconds.
    private func pressureEvictIdleConnectionsIfNeeded() async {
        guard pressureEvictIdleSeconds > 0 else { return }
        guard bootstrapLoad() >= maxGlobalConnections else { return }
        if let victim = await oldestEvictableConnectionID() {
            log.warning("Pressure eviction: evicting idle connection \(victim)")
            await removeConnection(victim)
        }
    }

    // MARK: - Bootstrap Socket Server

    /// Ensures the bootstrap socket listener is present and healthy.
    /// Intended as a periodic self-heal for stale sockets or failed startups.
    func ensureBootstrapHealthy(force: Bool = false) async {
        guard isRunningState else { return }
        guard isEnabledState else { return }
        guard !bootstrapStartInProgress else { return }
        guard !bootstrapRestartInProgress else { return }

        let now = Date()
        if !force, now.timeIntervalSince(lastBootstrapHealthCheckAt) < bootstrapHealthCheckInterval {
            return
        }
        lastBootstrapHealthCheckAt = now

        let socketPath = resolvedBootstrapSocketURL().path
        let exists = FileManager.default.fileExists(atPath: socketPath)

        if !exists {
            log.warning("Bootstrap socket path missing: \(socketPath). Restarting listener.")
            restartBootstrapSocketServer(reason: "socket_path_missing")
            return
        }

        if !isUnixDomainSocket(atPath: socketPath) {
            log.warning("Bootstrap socket path is not a socket: \(socketPath). Restarting listener.")
            restartBootstrapSocketServer(reason: "socket_path_not_socket")
            return
        }

        guard let server = bootstrapSocketServer else {
            connectionLog("BootstrapSocketServer nil while running. Restarting.")
            restartBootstrapSocketServer(reason: "server_nil")
            return
        }

        await server.ensureAccepting()

        let diagnostics = await server.diagnostics()
        if !diagnostics.listenFDValid {
            log.warning("Bootstrap listen FD invalid; restarting.")
            restartBootstrapSocketServer(reason: "listen_fd_invalid")
            return
        }

        if !diagnostics.acceptSourceExists {
            log.warning("Bootstrap accept source missing; restarting.")
            restartBootstrapSocketServer(reason: "accept_source_missing")
            return
        }

        let listening = await server.isListening()
        if !listening {
            log.warning("BootstrapSocketServer not listening (but should be). Restarting.")
            restartBootstrapSocketServer(reason: "not_listening")
        }
    }

    private func bootstrapBackoffDelay(for failures: Int) -> TimeInterval {
        let capped = min(failures, 4)
        return min(10.0, pow(2.0, Double(capped)))
    }

    private func isUnixDomainSocket(atPath path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func restartBootstrapSocketServer(reason: String, delay: TimeInterval = 0) {
        guard isRunningState else { return }
        guard !bootstrapRestartInProgress else { return }

        let now = Date()
        guard now.timeIntervalSince(lastBootstrapRestartAt) >= bootstrapRestartMinInterval else { return }

        bootstrapRestartInProgress = true
        lastBootstrapRestartAt = now
        let token = UUID()
        bootstrapRestartToken = token

        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            await self?.performBootstrapRestart(reason: reason, token: token)
        }
    }

    private func performBootstrapRestart(reason: String, token: UUID) async {
        defer { bootstrapRestartInProgress = false }

        guard bootstrapRestartToken == token else {
            connectionLog("Skipping bootstrap restart (reason=\(reason)) - superseded")
            return
        }
        bootstrapRestartToken = nil

        guard isRunningState else {
            connectionLog("Skipping bootstrap restart (reason=\(reason)) - manager not running")
            return
        }

        let socketPath = resolvedBootstrapSocketURL().path
        connectionLog("Restarting bootstrap socket server (reason=\(reason), socket=\(socketPath), failures=\(bootstrapStartFailures))")
        await stopBootstrapSocketServer()
        await startBootstrapSocketServer()
    }

    /// Starts the bootstrap socket server for UNIX socket connections.
    private func startBootstrapSocketServer() async {
        #if DEBUG
            print("[MCPStartup] startBootstrapSocketServer entered running=\(isRunningState) enabled=\(isEnabledState) inProgress=\(bootstrapStartInProgress)")
        #endif
        guard isRunningState else { return }
        guard !bootstrapStartInProgress else { return }
        bootstrapStartInProgress = true
        defer { bootstrapStartInProgress = false }

        connectionLog("Starting bootstrap socket server...")

        let socketURL = resolvedBootstrapSocketURL()
        let server = BootstrapSocketServer(socketURL: socketURL, logger: log)
        bootstrapSocketServer = server

        do {
            #if DEBUG
                print("[MCPStartup] calling BootstrapSocketServer.start socket=\(socketURL.path)")
            #endif
            try await server.start { [weak self] clientFD, sessionToken, clientPid, clientName async -> BootstrapSocketServer.Admission in
                guard let self else {
                    return .reject(.rejected(reason: "Server unavailable", errorCode: "server_unavailable"))
                }
                return await handleBootstrapConnection(
                    clientFD: clientFD,
                    sessionToken: sessionToken,
                    clientPid: clientPid,
                    clientName: clientName
                )
            }
            #if DEBUG
                print("[MCPStartup] BootstrapSocketServer.start succeeded socket=\(socketURL.path)")
            #endif
            bootstrapStartFailures = 0
            bootstrapRestartToken = nil
            bootstrapRestartInProgress = false
        } catch {
            #if DEBUG
                print("[MCPStartup] BootstrapSocketServer.start failed: \(error)")
            #endif
            bootstrapStartFailures += 1
            bootstrapSocketServer = nil
            log.error("Failed to start bootstrap socket server: \(error) (failures=\(bootstrapStartFailures))")
            let delay = bootstrapBackoffDelay(for: bootstrapStartFailures)
            restartBootstrapSocketServer(reason: "start_failed", delay: delay)
        }
    }

    /// Handles a new connection from the bootstrap socket.
    /// Returns an Admission with postAccept closure for MCP server startup.
    ///
    /// IMPORTANT: Connection registration is deferred to postAccept to avoid "ghost" connections
    /// if the "accepted" response fails to send. Capacity is reserved here and released on
    /// commit (postAccept) or rollback (onAcceptWriteFailed).
    private func handleBootstrapConnection(
        clientFD: Int32,
        sessionToken: String,
        clientPid: Int,
        clientName: String?
    ) async -> BootstrapSocketServer.Admission {
        let connectionID = UUID()
        connectionLog("Bootstrap socket connection: \(connectionID) from '\(clientName ?? "unknown")' (pid=\(clientPid), session=\(sessionToken.prefix(8))...)")
        mcpACPLog("[MCP-ACP] bootstrap connection connection=\(connectionID) bootstrapClientName=\(clientName ?? "unknown") pid=\(clientPid)")

        // Clean up any expired reservations (safety net)
        cleanupExpiredBootstrapReservations()

        // Early rejection if session is blocked (avoids pointless reservation)
        if isSessionBlocked(sessionToken) {
            let reason = "Session blocked"
            log.warning("Rejecting bootstrap connection \(connectionID) - session in cooldown")
            return .reject(.rejected(reason: reason, errorCode: MCPBootstrapErrorCode.sessionBlocked.rawValue))
        }

        // Brief cooldown for user-killed clientIDs (prevents auto-reconnect race)
        if let clientName, isClientInUserKillCooldown(clientName) {
            let remaining = remainingUserKillCooldown(clientName).map { Int($0) } ?? 0
            let reason = "Client temporarily blocked (retry in ~\(remaining)s)"
            log.warning("Rejecting bootstrap connection \(connectionID) - client '\(clientName)' in cooldown")
            return .reject(.rejected(reason: reason, errorCode: MCPBootstrapErrorCode.clientCooldown.rawValue))
        }

        // If this session token already has a live connection, we will replace it after accept.
        let replacedIDForCapacity = existingConnectionID(forSessionToken: sessionToken)

        _ = await awaitAgentBootstrapPolicyBeforeAcceptIfNeeded(
            bootstrapClientName: clientName,
            connectionID: connectionID,
            sessionKey: sessionToken,
            clientPid: clientPid,
            isReplacementForSession: replacedIDForCapacity != nil
        )

        // Enforce capacity against bootstrapLoad() (connections + reservations)
        // Loop eviction until we have space or no candidates remain
        while bootstrapLoad() - (replacedIDForCapacity != nil ? 1 : 0) >= maxGlobalConnections {
            let evicted = await evictLeastValuableGlobalForAdmission(preserveOnePerClient: preserveOnePerClient)
            if !evicted {
                log.warning("At global capacity and no evictable candidate; rejecting bootstrap connection \(connectionID)")
                return .reject(.rejected(reason: "Server at capacity", errorCode: MCPBootstrapErrorCode.capacityExceeded.rawValue))
            }
        }

        // Reserve capacity BEFORE returning .accept
        reserveBootstrapSlot(connectionID: connectionID)

        connectionLog("handleBootstrapConnection: returning Admission.accept for \(connectionID)")

        // Return acceptance with:
        // - postAccept: commit path (release reservation, then register connection)
        // - onAcceptWriteFailed: rollback path (release reservation only)
        // NOTE: Using strong capture [self] to ensure reservation is always released.
        // These closures are short-lived and not stored long-term.
        return .accept(
            postAccept: { [self] in
                // Commit: release reservation (connection will be added to connections[])
                await releaseBootstrapReservation(connectionID: connectionID)
                if let replacedNow = await existingConnectionID(forSessionToken: sessionToken) {
                    await softDisconnectConnection(replacedNow, reason: .connectionReplaced, message: "Replaced by new connection for same session")
                }
                await registerAndStartBootstrapConnection(
                    connectionID: connectionID,
                    sessionToken: sessionToken,
                    clientPid: clientPid,
                    clientName: clientName,
                    clientFD: clientFD
                )
            },
            onAcceptWriteFailed: { [self] in
                // Rollback: release reservation without registering
                await releaseBootstrapReservation(connectionID: connectionID)
                connectionLog("Bootstrap connection \(connectionID) rolled back (accept write failed)")
            }
        )
    }

    /// Registers a bootstrap connection and starts its MCP server.
    /// Called from postAccept AFTER the "accepted" response has been successfully sent.
    private func registerAndStartBootstrapConnection(
        connectionID: UUID,
        sessionToken: String,
        clientPid: Int,
        clientName: String?,
        clientFD: Int32
    ) async {
        // Initialize identity context
        let identityContext = ConnectionIdentityContext(
            clientName: clientName,
            capabilityToken: sessionToken,
            source: .handshake,
            hasHandshake: false,
            lastUpdated: Date()
        )
        identityContextByConnection[connectionID] = identityContext

        if let name = clientName, !name.isEmpty {
            pendingConnections[connectionID] = name
        }
        mcpACPLog("[MCP-ACP] registered bootstrap connection connection=\(connectionID) pendingClientName=\(clientName ?? "unknown")")

        let purpose = purposeForNewBootstrapConnection(
            clientName: clientName,
            sessionToken: sessionToken
        )

        // Do not block first-frame MCP startup on MainActor/global settings during bootstrap.
        // The instructions resource path reads the live Code Maps setting later; defaulting
        // the initial server instructions to enabled keeps CLI initialize responsive.
        let codeMapsDisabled = false

        // Create connection manager
        let manager = BootstrapSocketConnectionManager(
            connectionID: connectionID,
            sessionToken: sessionToken,
            clientPid: clientPid,
            clientName: clientName,
            purpose: purpose,
            codeMapsDisabled: codeMapsDisabled,
            connectedFD: clientFD,
            parentManager: self
        )

        connections[connectionID] = manager
        bindSessionToken(sessionToken, to: connectionID)
        if connectionStats[connectionID] == nil {
            connectionStats[connectionID] = ConnectionStats(
                createdAt: Date(),
                totalToolCalls: 0,
                lastToolCallAt: nil
            )
        }
        #if DEBUG
            debugRecordConnectionEvent(
                "registered",
                connectionID: connectionID,
                reason: "bootstrap",
                clientName: clientName,
                sessionToken: sessionToken
            )
        #endif

        // Notify dashboard
        emitDashboardUpdate()

        // Start MCP server FIRST to minimize time-to-first-MCP-frame
        // (CLI may send MCP frames immediately after receiving "accepted")
        startMCPServerForConnection(
            connectionID: connectionID,
            sessionToken: sessionToken,
            clientPid: clientPid,
            manager: manager
        )

        // Capture window count concurrently (don't block MCP server startup on MainActor).
        // Note: There's a brief window where windowCountAtConnectionTime[id] is nil.
        // Routing logic treats nil as unknown and falls back to current window topology.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let count = WindowStatesManager.shared.allWindows.count
            await setWindowCountAtConnectionTime(connectionID: connectionID, count: count)
        }
    }

    /// Sets the window count at connection time (called from MainActor task)
    private func setWindowCountAtConnectionTime(connectionID: UUID, count: Int) {
        windowCountAtConnectionTime[connectionID] = count
    }

    private func purposeForNewBootstrapConnection(
        clientName: String?,
        sessionToken: String
    ) -> MCPRunPurpose {
        if let existingConnectionID = existingConnectionID(forSessionToken: sessionToken),
           let existingPurpose = runPurposeByConnection[existingConnectionID],
           existingPurpose != .unknown
        {
            return existingPurpose
        }

        guard let clientName,
              !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .unknown
        }

        pruneExpiredPolicies(for: clientName)
        let matchingKeys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        let pendingPurpose = matchingKeys
            .compactMap { key -> (key: String, createdAt: Date, purpose: MCPRunPurpose)? in
                guard let policy = pendingPoliciesByClient[key]?.first else { return nil }
                return (key: key, createdAt: policy.createdAt, purpose: policy.purpose)
            }
            .min { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.key < rhs.key
                }
                return lhs.createdAt < rhs.createdAt
            }?
            .purpose
        if let pendingPurpose {
            return pendingPurpose
        }

        if let livePurpose = preferredLiveRunAffinity(for: clientName, sessionKey: sessionToken)?.purpose {
            return livePurpose
        }

        return .unknown
    }

    /// Starts the MCP server for a bootstrap connection.
    /// Called from postAccept after the "accepted" response has been sent to the CLI.
    private func startMCPServerForConnection(
        connectionID: UUID,
        sessionToken: String,
        clientPid: Int,
        manager: BootstrapSocketConnectionManager
    ) {
        // Spawn the MCP server task - this runs after CLI has received "accepted"
        connectionTasks[connectionID] = Task {
            defer {
                self.connectionTasks.removeValue(forKey: connectionID)
            }
            do {
                guard let approvalHandler = self.connectionApprovalHandler else {
                    log.error("No connection approval handler set, rejecting bootstrap connection")
                    await removeConnection(connectionID)
                    return
                }

                connectionLog("Starting MCP server for bootstrap connection \(connectionID)")
                mcpACPLog("[MCP-ACP] starting MCP server connection=\(connectionID)")
                try await manager.start { clientInfo in
                    connectionLog("MCP handshake callback for \(connectionID): clientName='\(clientInfo.name)'")
                    mcpACPLog("[MCP-ACP] handshake connection=\(connectionID) clientName=\(clientInfo.name)")

                    // Update identity context
                    if var ctx = self.identityContextByConnection[connectionID] {
                        ctx.clientName = clientInfo.name
                        ctx.hasHandshake = true
                        ctx.source = .handshake
                        ctx.lastUpdated = Date()
                        self.identityContextByConnection[connectionID] = ctx
                    }

                    let bootstrapClientName = self.pendingConnections[connectionID]
                    self.pendingConnections[connectionID] = clientInfo.name
                    self.emitDashboardUpdate()

                    // Validate client name
                    let trimmedName = clientInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedName.isEmpty {
                        await self.recordIdentityFailure(for: connectionID, source: .filesystem, reason: "Bootstrap handshake provided empty client name")
                        return false
                    }

                    // Check cooldown
                    if self.isSessionBlocked(sessionToken) {
                        log.warning("Rejecting bootstrap connection \(connectionID) - session in cooldown")
                        return false
                    }

                    connectionLog("Calling approval handler for \(connectionID) client='\(clientInfo.name)'")
                    let approved = await approvalHandler(connectionID, clientInfo)
                    connectionLog("Approval handler returned \(approved) for \(connectionID)")
                    if approved {
                        let readiness = await self.awaitAgentPolicyAdmissionIfNeeded(
                            clientName: clientInfo.name,
                            bootstrapClientName: bootstrapClientName,
                            connectionID: connectionID,
                            sessionKey: sessionToken,
                            clientPid: clientPid
                        )
                        if readiness == .timedOut {
                            self.pendingConnections.removeValue(forKey: connectionID)
                            return false
                        }

                        await self.applyPendingPolicyIfAvailable(
                            clientName: clientInfo.name,
                            connectionID: connectionID,
                            clientPid: clientPid,
                            bootstrapClientName: bootstrapClientName
                        )
                        self.notifyConnectionWaiters(connectionID: connectionID, clientName: clientInfo.name)

                        // Do not block MCP initialize on window binding/readiness/cache warming.
                        // Policy admission and waiter notification are complete; finish catalog prep opportunistically.
                        Task {
                            let windowID = await self.ensureWindowBindingIfUnambiguous(connectionID: connectionID, reason: "handshake")
                            let ready = await MCPToolCatalogReadiness.shared.awaitReady(
                                windowID: windowID,
                                timeout: MCPToolCatalogReadiness.defaultTimeout
                            )
                            if !ready {
                                log.warning("Tool catalog not ready for connection \(connectionID) window=\(windowID.map(String.init) ?? "nil") - proceeding anyway")
                            }

                            if let windowID {
                                await MCPToolCatalogReadiness.shared.warmToolCache(windowID: windowID)
                            }
                        }
                    } else {
                        self.pendingConnections.removeValue(forKey: connectionID)
                    }
                    return approved
                }

                // Update identity after successful start
                if var ctx = self.identityContextByConnection[connectionID] {
                    ctx.hasHandshake = true
                    self.identityContextByConnection[connectionID] = ctx
                }
                self.emitDashboardUpdate()

            } catch {
                log.error("Bootstrap connection \(connectionID) start failed: \(error)")
                await removeConnection(connectionID)
            }
        }
    }

    /// Stops the bootstrap socket server.
    private func stopBootstrapSocketServer() async {
        bootstrapSocketTask?.cancel()
        bootstrapSocketTask = nil
        await bootstrapSocketServer?.stop()
        bootstrapSocketServer = nil
    }

    func stop() async {
        connectionLog("Stopping network manager")
        isRunningState = false

        // Stop maintenance loop
        maintenanceTask?.cancel()
        maintenanceTask = nil

        // Stop bootstrap socket server
        await stopBootstrapSocketServer()

        // Clear any pending reservations
        bootstrapReservations.removeAll()

        // Stop all connections
        for (id, connectionManager) in connections {
            connectionLog("Stopping connection: \(id)")
            #if DEBUG
                debugRecordConnectionEvent("removed", connectionID: id, reason: "serverShutdown")
            #endif
            await connectionManager.stop()
            connectionTasks[id]?.cancel()
        }

        connections.removeAll()
        connectionTasks.removeAll()
        pendingConnections.removeAll()
        identityContextByConnection.removeAll()
        capabilityTokenByConnection.removeAll()
        connectionIDBySessionToken.removeAll()
        resetInMemoryRoutingCachesForRestart()
    }

    private func resetInMemoryRoutingCachesForRestart() {
        connectionWindowMap.removeAll()
        runIDByConnectionID.removeAll()
        windowAssignmentByConnection.removeAll()
        restrictedToolsByConnection.removeAll()
        additionalToolsByConnection.removeAll()
        runPurposeByConnection.removeAll()
        windowCountAtConnectionTime.removeAll()
        preassignedConnections.removeAll()
        pendingPoliciesByClient.removeAll()
        expectedAgentPIDsByClient.removeAll()
        expectedAgentPIDsByRunID.removeAll()
        runPolicyStateByRunID.removeAll()
        admittedPolicyRunIDs.removeAll()
        windowIDByRunID.removeAll()
        activeConnectionsByClient.removeAll()
        clientIDByConnection.removeAll()
        callLimiters.removeAll()
        capabilityTokenByConnection.removeAll()
        connectionIDBySessionToken.removeAll()
        lastWindowByClientSession.removeAll()
        liveRunAffinityByClientSession.removeAll()
        activeToolOwnerByWindow.removeAll()
        activeToolNameByWindow.removeAll()
        connectionStats.removeAll()
    }

    // MARK: - Termination & Kill Semantics

    /// Controls which termination side-effects are applied.
    /// Used to differentiate between hard kills (user boot) and soft disconnects (reconnection churn).
    private struct TerminationSemantics {
        var writeKillSignal: Bool
        var markSessionKilled: Bool
        var markClientUserKilled: Bool

        static let hardKill = TerminationSemantics(
            writeKillSignal: true,
            markSessionKilled: true,
            markClientUserKilled: true
        )

        static let softDisconnect = TerminationSemantics(
            writeKillSignal: false,
            markSessionKilled: false,
            markClientUserKilled: false
        )
    }

    /// Returns the default termination semantics for a given reason.
    private func defaultSemantics(for reason: TerminationReason) -> TerminationSemantics {
        switch reason {
        case .userBootFromDashboard:
            // User explicitly killed - full blocking
            TerminationSemantics(
                writeKillSignal: true,
                markSessionKilled: true,
                markClientUserKilled: true
            )
        case .runCompleted, .runCancelled, .serverShutdown, .approvalDenied:
            // Expected terminations - kill signal but no client cooldown
            TerminationSemantics(
                writeKillSignal: true,
                markSessionKilled: true,
                markClientUserKilled: false
            )
        case .idleTimeout:
            // Hygiene cleanup - allow clean reconnects
            .softDisconnect
        case .connectionReplaced:
            // Default to hard behavior; caller can override for same-session replacement
            TerminationSemantics(
                writeKillSignal: true,
                markSessionKilled: true,
                markClientUserKilled: false
            )
        }
    }

    /// Checks if a session token is in termination cooldown (recently killed).
    /// Sessions in cooldown should be rejected on reconnect attempt.
    private func isSessionInTerminationCooldown(_ sessionToken: String?) -> Bool {
        guard let token = sessionToken,
              let killedAt = killedSessionTimestamps[token]
        else { return false }

        let elapsed = Date().timeIntervalSince(killedAt)
        if elapsed >= killedSessionTTL {
            // Expired - clean up
            killedSessionTokens.remove(token)
            killedSessionTimestamps.removeValue(forKey: token)
            return false
        }
        return true
    }

    /// Marks a session as killed (for cooldown deny on reconnect).
    private func markSessionAsKilled(_ sessionToken: String) {
        killedSessionTokens.insert(sessionToken)
        killedSessionTimestamps[sessionToken] = Date()
    }

    /// Cleans up expired killed session entries.
    private func cleanupExpiredKilledSessions() {
        let now = Date()
        for (token, killedAt) in killedSessionTimestamps {
            if now.timeIntervalSince(killedAt) >= killedSessionTTL {
                killedSessionTokens.remove(token)
                killedSessionTimestamps.removeValue(forKey: token)
            }
        }
    }

    /// Checks if a session token is blocked (killed and in cooldown).
    /// Called during admission to reject reconnection attempts from killed sessions.
    func isSessionBlocked(_ sessionToken: String?) -> Bool {
        isSessionInTerminationCooldown(sessionToken)
    }

    /// Checks if a clientID is in user-initiated kill cooldown.
    /// Returns true if the client was killed by user action within the cooldown period.
    private func isClientInUserKillCooldown(_ clientID: String) -> Bool {
        guard let killedAt = userKilledClientIDs[clientID] else { return false }

        let elapsed = Date().timeIntervalSince(killedAt)
        if elapsed >= userKilledClientCooldown {
            // Expired - clean up
            userKilledClientIDs.removeValue(forKey: clientID)
            return false
        }
        return true
    }

    /// Returns remaining TTL for a killed session, or nil if not blocked.
    private func remainingKilledSessionTTL(_ token: String) -> TimeInterval? {
        guard let killedAt = killedSessionTimestamps[token] else { return nil }
        let elapsed = Date().timeIntervalSince(killedAt)
        let remaining = killedSessionTTL - elapsed
        return remaining > 0 ? remaining : nil
    }

    /// Returns remaining TTL for a user-killed client, or nil if not in cooldown.
    private func remainingUserKillCooldown(_ clientID: String) -> TimeInterval? {
        guard let killedAt = userKilledClientIDs[clientID] else { return nil }
        let elapsed = Date().timeIntervalSince(killedAt)
        let remaining = userKilledClientCooldown - elapsed
        return remaining > 0 ? remaining : nil
    }

    /// Marks a clientID as killed by user action (for brief reconnection cooldown).
    private func markClientAsUserKilled(_ clientID: String) {
        userKilledClientIDs[clientID] = Date()
        connectionLog("Marked clientID '\(clientID)' for \(Int(userKilledClientCooldown))s reconnection cooldown")
    }

    /// Cleans up expired user-killed client entries.
    private func cleanupExpiredUserKilledClients() {
        let now = Date()
        for (clientID, killedAt) in userKilledClientIDs {
            if now.timeIntervalSince(killedAt) >= userKilledClientCooldown {
                userKilledClientIDs.removeValue(forKey: clientID)
            }
        }
    }

    /// Terminates a connection with explicit kill semantics.
    /// - Writes a kill signal file (filesystem side-channel) so CLI exits without retry
    /// - Marks the session for cooldown deny to block immediate reconnection
    /// - Terminates and removes the connection
    /// - Parameters:
    ///   - id: The connection UUID to terminate
    ///   - reason: Why the connection is being terminated
    ///   - message: Optional human-readable message
    func terminateConnection(_ id: UUID, reason: TerminationReason, message: String? = nil) async {
        await terminateConnection(id, reason: reason, message: message, semanticsOverride: nil)
    }

    /// Internal termination with configurable semantics.
    private func terminateConnection(
        _ id: UUID,
        reason: TerminationReason,
        message: String?,
        semanticsOverride: TerminationSemantics?
    ) async {
        guard let connection = connections[id] else {
            log.warning("terminateConnection: connection \(id) not found in connections dictionary")
            return
        }

        let sem = semanticsOverride ?? defaultSemantics(for: reason)
        let sessionToken = capabilityTokenByConnection[id] ?? connection.capabilityToken
        connectionLog("Terminating connection \(id) with reason: \(reason.rawValue), session: \(sessionToken?.prefix(8) ?? "nil")..., semantics: killSignal=\(sem.writeKillSignal), markSession=\(sem.markSessionKilled), markClient=\(sem.markClientUserKilled)")
        #if DEBUG
            debugRecordConnectionEvent("terminated", connectionID: id, reason: reason.rawValue, sessionToken: sessionToken)
        #endif

        // 1. Write kill signal file (works for both transport types)
        if sem.writeKillSignal, let token = sessionToken {
            do {
                try MCPKillSignal.writeKillSignal(
                    sessionToken: token,
                    reason: reason,
                    message: message
                )
                connectionLog("Wrote kill signal for session \(token.prefix(8))...")
            } catch {
                log.warning("Failed to write kill signal: \(error)")
            }
        }

        // 2. Mark session for cooldown deny (only if semantics require it)
        if sem.markSessionKilled, let token = sessionToken {
            markSessionAsKilled(token)
        }

        // 2b. Mark clientID for brief cooldown (only if semantics require it)
        if sem.markClientUserKilled, let clientID = clientIDByConnection[id] {
            markClientAsUserKilled(clientID)
        }

        // 3. Terminate the connection (writes "killed" to meta.json for filesystem)
        await connection.terminate(reason: reason, message: message)

        // 4. Clean up connection state
        await removeConnection(id)

        connectionLog("Successfully terminated and removed connection \(id)")

        // Periodic cleanup of expired entries
        cleanupExpiredKilledSessions()
        cleanupExpiredUserKilledClients()
        MCPKillSignal.cleanupStaleSignals()
    }

    /// Soft-disconnects a connection without kill signals or cooldowns.
    /// Used for internal connection churn (e.g., same-session reconnection).
    private func softDisconnectConnection(_ id: UUID, reason: TerminationReason, message: String?) async {
        guard let connection = connections[id] else {
            connectionLog("softDisconnectConnection: connection \(id) not found")
            return
        }
        connectionLog("Soft-disconnecting connection \(id) reason=\(reason.rawValue)")
        #if DEBUG
            debugRecordConnectionEvent("soft_disconnected", connectionID: id, reason: reason.rawValue)
        #endif
        await connection.stop()
        await removeConnection(id)
    }

    /// Returns the existing connection ID for a given session token, if any.
    private func existingConnectionID(forSessionToken token: String) -> UUID? {
        if let id = connectionIDBySessionToken[token],
           let mgr = connections[id],
           !mgr.isFilesystemBacked
        {
            return id
        }
        // Fallback scan in case mapping got out of sync.
        for (id, mgr) in connections {
            if mgr.isFilesystemBacked { continue }
            let stored = capabilityTokenByConnection[id] ?? mgr.capabilityToken
            if stored == token {
                connectionIDBySessionToken[token] = id
                return id
            }
        }
        connectionIDBySessionToken.removeValue(forKey: token)
        return nil
    }

    /// Binds a session token to a connection for fast lookup and routing persistence.
    private func bindSessionToken(_ token: String, to connectionID: UUID) {
        connectionIDBySessionToken[token] = connectionID
        capabilityTokenByConnection[connectionID] = token
    }

    /// Removes session-token mappings for a connection.
    private func unbindSessionToken(_ token: String?, forConnectionID id: UUID) {
        guard let token else {
            capabilityTokenByConnection.removeValue(forKey: id)
            return
        }
        if connectionIDBySessionToken[token] == id {
            connectionIDBySessionToken.removeValue(forKey: token)
        }
        capabilityTokenByConnection.removeValue(forKey: id)
    }

    /// Returns the session token for a connection (from capability token cache or connection itself).
    func sessionToken(for connectionID: UUID) -> String? {
        capabilityTokenByConnection[connectionID] ?? connections[connectionID]?.capabilityToken
    }

    /// Handles connection replacement when a new connection registers with the same runID.
    /// Uses soft-disconnect for same-session replacements to avoid blocking legitimate reconnects.
    func handleConnectionReplaced(
        existing oldID: UUID,
        by newID: UUID,
        runID: UUID,
        message: String? = nil
    ) async {
        let oldToken = sessionToken(for: oldID)
        let newToken = sessionToken(for: newID)

        // If both tokens exist and are equal, this is a reconnect churn from the same CLI.
        // Soft-disconnect the old connection without kill signals or session blocking.
        if let oldToken, let newToken, oldToken == newToken {
            connectionLog("RunID \(runID) collision: same session (\(oldToken.prefix(8))…) - soft-disconnect old=\(oldID) for new=\(newID)")
            await softDisconnectConnection(oldID, reason: .connectionReplaced, message: message)
            return
        }

        // Different session or unknown: treat as true replacement (kill old session)
        connectionLog("RunID \(runID) collision: different session - hard-terminate old=\(oldID) (token=\(oldToken?.prefix(8) ?? "nil")) for new=\(newID) (token=\(newToken?.prefix(8) ?? "nil"))")
        let hardSemantics = TerminationSemantics(
            writeKillSignal: true,
            markSessionKilled: true,
            markClientUserKilled: false
        )
        await terminateConnection(oldID, reason: .connectionReplaced, message: message, semanticsOverride: hardSemantics)
    }

    func removeConnection(_ id: UUID) async {
        // Always drop any lingering bootstrap reservation (commit/rollback should handle it,
        // but this is a leak safety-net for edge cases)
        _ = bootstrapReservations.removeValue(forKey: id)

        // Idempotent guard – if already gone, do nothing (and do not log)
        guard connections[id] != nil
            || connectionTasks[id] != nil
            || pendingConnections[id] != nil
        else {
            connectionLog("removeConnection: \(id) already removed; ignoring duplicate call")
            return
        }

        connectionLog("Removing connection: \(id)")

        let assignedWindowID = connectionWindowMap[id]
        let cleanupClientID = clientIDByConnection[id]
        let cleanupClientName = pendingConnections[id] ?? cleanupClientID
        let sessionToken = capabilityTokenByConnection[id] ?? connections[id]?.capabilityToken
        #if DEBUG
            debugRecordConnectionEvent(
                "removed",
                connectionID: id,
                reason: "connectionRemoved",
                clientName: cleanupClientName,
                sessionToken: sessionToken,
                windowID: assignedWindowID
            )
        #endif

        restrictedToolsByConnection.removeValue(forKey: id)
        additionalToolsByConnection.removeValue(forKey: id)
        runPurposeByConnection.removeValue(forKey: id)
        runIDByConnectionID.removeValue(forKey: id)
        windowAssignmentByConnection.removeValue(forKey: id)
        preassignedConnections.remove(id)
        windowCountAtConnectionTime.removeValue(forKey: id)
        identityContextByConnection.removeValue(forKey: id)

        let cancelledToolCount = await cancelActiveToolsOwnedByConnection(
            id,
            reason: "connectionRemoved"
        )
        if cancelledToolCount > 0 {
            connectionLog("Cancelled \(cancelledToolCount) active tool execution(s) owned by disconnected connection \(id)")
        }

        await MainActor.run {
            let windows = WindowStatesManager.shared.allWindows
            let nameForCleanup = cleanupClientName
            if let windowID = assignedWindowID,
               let windowState = windows.first(where: { $0.windowID == windowID })
            {
                windowState.mcpServer.removeTabContext(
                    forConnectionID: id,
                    clientName: nameForCleanup,
                    windowID: windowID,
                    runID: nil
                )
            } else {
                for state in windows {
                    state.mcpServer.removeTabContext(
                        forConnectionID: id,
                        clientName: nameForCleanup,
                        windowID: nil,
                        runID: nil
                    )
                }
            }
        }
        connectionWindowMap[id] = nil

        // Stop the connection manager
        if let connectionManager = connections[id] {
            await connectionManager.stop()
        }

        // Cancel any associated tasks
        if let task = connectionTasks[id] {
            task.cancel()
        }

        // Remove from all collections
        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
        pendingConnections.removeValue(forKey: id)
        connectionStats.removeValue(forKey: id)
        // Note: toolCallObservers are now keyed by runID, not connectionID
        // They are cleaned up when the discovery run completes, not when connection is removed
        // Note: connectionIDToRunID mapping is managed by MCPServerViewModel, not here

        // Release admission slot & limiter
        if let clientID = clientIDByConnection[id] {
            var set = activeConnectionsByClient[clientID] ?? []
            set.remove(id)
            if set.isEmpty { activeConnectionsByClient.removeValue(forKey: clientID) }
            else { activeConnectionsByClient[clientID] = set }
            clientIDByConnection.removeValue(forKey: id)
        }
        callLimiters[id] = nil

        // Clean up routing metadata
        unbindSessionToken(sessionToken, forConnectionID: id)

        // Notify dashboard of connection removal
        emitDashboardUpdate()
    }

    /// Reads the cached TCP client name from all CLI instance cache files.
    /// (Legacy TCP transport has been removed; this helper now returns nil.)
    /// - Parameter remotePort: The remote port from the incoming connection for precise matching
    /// - Returns: Always nil now that TCP transport and cache files are deprecated
    // MARK: - Identity Failure Recording & Escalation

    /// Transport type for identity failure tracking
    private enum IdentityFailureSource {
        /// Identity failures observed on filesystem/bootstrap-socket connections
        case filesystem
    }

    /// Records an identity recovery failure and potentially escalates diagnostics.
    /// With TCP transport removed, this is only used for filesystem/bootstrap-socket failures.
    /// - Parameters:
    ///   - connectionID: The connection that failed identity recovery
    ///   - source: Where the failure was observed (currently always `.filesystem`)
    ///   - reason: Human-readable description of the failure
    private func recordIdentityFailure(for connectionID: UUID, source: IdentityFailureSource, reason: String) async {
        log.error("Identity recovery failed for connection \(connectionID): \(reason)")

        let now = Date()
        if let start = identityFailureWindowStart,
           now.timeIntervalSince(start) <= identityFailureWindow
        {
            identityFailureCount += 1
        } else {
            identityFailureWindowStart = now
            identityFailureCount = 1
        }

        // Escalate after threshold
        if identityFailureCount >= identityFailureThreshold {
            await escalateIdentityFailures(reason: reason)
        }
    }

    /// Escalates repeated identity failures - placeholder for future handling.
    private func escalateIdentityFailures(reason: String) async {
        // Log the escalation for diagnostics
        log.error("Identity failure escalation (count=\(identityFailureCount)): \(reason)")
    }

    /// Maximum entries in toolSchemaCache to prevent unbounded growth
    private let maxToolSchemaCacheEntries = 256

    private var bindingResolver: MCPBindingResolver {
        MCPBindingResolver(
            collectMatchesForContextID: { contextID in
                await MainActor.run {
                    WindowStatesManager.shared.allWindows.compactMap { windowState in
                        guard let candidate = windowState.workspaceManager.bindingCandidate(forContextID: contextID) else {
                            return nil
                        }
                        return MCPContextBindingMatch(
                            windowID: windowState.windowID,
                            tabID: candidate.tabID,
                            workspaceID: candidate.workspaceID,
                            workspaceName: candidate.workspaceName,
                            repoPaths: candidate.repoPaths
                        )
                    }
                }
            },
            collectMatchesForWorkingDirs: { workingDirs in
                await MainActor.run {
                    WindowStatesManager.shared.allWindows.flatMap { windowState in
                        windowState.workspaceManager.bindingCandidates(matchingWorkingDirs: workingDirs, includeHidden: false).map { candidate in
                            MCPContextBindingMatch(
                                windowID: windowState.windowID,
                                tabID: candidate.tabID,
                                workspaceID: candidate.workspaceID,
                                workspaceName: candidate.workspaceName,
                                repoPaths: candidate.repoPaths
                            )
                        }
                    }
                }
            },
            existingWindowIDForConnection: { [self] connectionID in
                connectionWindowMap[connectionID]
            },
            clientIdentifier: { [self] connectionID in
                clientIdentifier(forConnection: connectionID)
            },
            reusableWindowForClient: { [self] connectionID, clientName in
                await reusableWindowForClient(newConnectionID: connectionID, clientName: clientName)
            },
            sessionKeyForConnection: { [self] connectionID in
                connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
            },
            preferredLiveRunWindowID: { [self] clientName, sessionKey in
                preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey)?.windowID
            },
            preferredWindowID: { [self] clientName, sessionKey in
                await preferredWindowID(for: clientName, sessionKey: sessionKey)
            }
        )
    }

    private func cachedSchema(for name: String, schema: JSONSchema, purpose: MCPRunPurpose) async throws -> Value {
        let cacheKey = ToolSchemaCacheKey(name: name, purpose: purpose)
        if let cached = toolSchemaCache[cacheKey] {
            return cached
        }

        var schemaValue = try Value(schema)

        if case var .object(dict) = schemaValue,
           dict["type"]?.stringValue == "object",
           dict["properties"] == nil
        {
            dict["properties"] = Value.object([:])
            schemaValue = .object(dict)
        }

        schemaValue = Self.augmentSchemaWithCanonicalBindingParams(schemaValue, toolName: name, purpose: purpose)

        // Prevent unbounded cache growth (safety net for buggy/malicious clients)
        if toolSchemaCache.count >= maxToolSchemaCacheEntries {
            connectionLog("toolSchemaCache flushed (exceeded cap=\(maxToolSchemaCacheEntries))")
            toolSchemaCache.removeAll(keepingCapacity: true)
        }

        toolSchemaCache[cacheKey] = schemaValue
        return schemaValue
    }

    private func invalidateToolSchemaCache() {
        toolSchemaCache.removeAll(keepingCapacity: false)
    }

    nonisolated static func augmentSchemaWithCanonicalBindingParams(
        _ schemaValue: Value,
        toolName: String,
        purpose: MCPRunPurpose
    ) -> Value {
        guard case var .object(dict) = schemaValue,
              dict["type"]?.stringValue == "object"
        else {
            return schemaValue
        }

        var properties = dict["properties"]?.objectValue ?? [:]

        let shouldAdvertiseCanonicalBindingParams = shouldAdvertiseCanonicalBindingParams(for: toolName)
        let shouldKeepContextID = shouldRehydrateContextID(for: toolName)
        if !shouldAdvertiseCanonicalBindingParams {
            if !shouldKeepContextID {
                properties.removeValue(forKey: "context_id")
            }
            properties.removeValue(forKey: "working_dirs")
        }

        dict["properties"] = .object(properties)

        if var required = dict["required"]?.arrayValue {
            if !shouldAdvertiseCanonicalBindingParams {
                required.removeAll { value in
                    guard let stringValue = value.stringValue else { return false }
                    if stringValue == "context_id" { return !shouldKeepContextID }
                    return stringValue == "working_dirs"
                }
            }
            dict["required"] = .array(required)
        }

        return .object(dict)
    }

    private nonisolated func advertisedToolDescription(
        for name: String,
        baseDescription: String,
        purpose: MCPRunPurpose
    ) -> String {
        baseDescription
    }

    /// Checks if a tool's schema declares a `window_id` parameter.
    /// Pure function - doesn't access actor state.
    private nonisolated func schemaDeclaresWindowID(schema: JSONSchema) -> Bool {
        // Convert schema to Value and check for window_id in properties
        guard let schemaValue = try? Value(schema),
              case let .object(dict) = schemaValue,
              let props = dict["properties"]?.objectValue
        else {
            return false
        }
        return props.keys.contains("window_id")
    }

    /// Injects `window_id` into tool arguments if:
    /// 1. The tool schema declares a `window_id` parameter
    /// 2. The caller provided `_windowID` for routing
    /// 3. The caller didn't explicitly provide `window_id`
    /// Pure function - doesn't access actor state.
    private nonisolated func injectWindowIDIfNeeded(
        schemaDeclaresWindowID: Bool,
        routingWindowID: Int?,
        args: [String: Value]
    ) -> [String: Value] {
        // Priority 1: explicit window_id in args -> keep unchanged
        if args["window_id"] != nil { return args }

        // Priority 2: _windowID routing + schema has window_id -> inject
        guard let windowID = routingWindowID,
              schemaDeclaresWindowID
        else {
            return args
        }

        var mutableArgs = args
        mutableArgs["window_id"] = .int(windowID)
        return mutableArgs
    }

    func registerExpectedAgentPID(_ pid: pid_t, for clientName: String, runID: UUID? = nil) {
        let storageKey = Self.clientStorageKey(clientName)
        var pids = expectedAgentPIDsByClient[storageKey] ?? []
        pids.insert(pid)
        expectedAgentPIDsByClient[storageKey] = pids
        if let runID {
            var runPIDs = expectedAgentPIDsByRunID[runID] ?? []
            runPIDs.insert(pid)
            expectedAgentPIDsByRunID[runID] = runPIDs
        }
        mcpPolicyLog(
            "registered expected agent pid client=\(clientName) storageKey=\(storageKey) pid=\(pid) runID=\(runID?.uuidString ?? "nil") count=\(pids.count)"
        )
    }

    func clearExpectedAgentPID(_ pid: pid_t, for clientName: String, runID: UUID? = nil) {
        let keys = matchingClientKeys(for: clientName, in: Array(expectedAgentPIDsByClient.keys))
        guard !keys.isEmpty || runID != nil else { return }
        var removedCount = 0
        for key in keys {
            guard var pids = expectedAgentPIDsByClient[key] else { continue }
            if pids.remove(pid) != nil {
                removedCount += 1
            }
            if pids.isEmpty {
                expectedAgentPIDsByClient.removeValue(forKey: key)
            } else {
                expectedAgentPIDsByClient[key] = pids
            }
        }
        if let runID {
            removeExpectedAgentPID(pid, forRunID: runID)
        } else {
            for candidateRunID in Array(expectedAgentPIDsByRunID.keys) {
                removeExpectedAgentPID(pid, forRunID: candidateRunID)
            }
        }
        guard removedCount > 0 else { return }
        mcpPolicyLog(
            "cleared expected agent pid client=\(clientName) pid=\(pid) runID=\(runID?.uuidString ?? "nil") removed=\(removedCount)"
        )
    }

    private func removeExpectedAgentPID(_ pid: pid_t, forRunID runID: UUID) {
        guard var pids = expectedAgentPIDsByRunID[runID] else { return }
        pids.remove(pid)
        if pids.isEmpty {
            expectedAgentPIDsByRunID.removeValue(forKey: runID)
        } else {
            expectedAgentPIDsByRunID[runID] = pids
        }
    }

    private func expectedAgentPIDs(for clientName: String, runID: UUID? = nil) -> Set<pid_t> {
        if let runID {
            return expectedAgentPIDsByRunID[runID] ?? []
        }
        let keys = matchingClientKeys(for: clientName, in: Array(expectedAgentPIDsByClient.keys))
        return keys.reduce(into: Set<pid_t>()) { partialResult, key in
            partialResult.formUnion(expectedAgentPIDsByClient[key] ?? [])
        }
    }

    private func hasPIDGatedPendingPolicy(for clientName: String) -> Bool {
        oldestPendingPolicyEntry(for: clientName) { $0.requiresExpectedAgentPID } != nil
    }

    private func oldestPIDGatedPendingPolicyEntry(
        for clientName: String,
        matching clientPid: Int
    ) -> (key: String, index: Int, policy: ClientConnectionPolicy)? {
        oldestPendingPolicyEntry(for: clientName) { policy in
            policy.requiresExpectedAgentPID
                && canConsumePendingPolicy(policy, clientName: clientName, clientPid: clientPid)
        }
    }

    private func directAgentBootstrapAdmissionStatus(
        clientName: String,
        sessionKey: String?,
        clientPid: Int,
        isReplacementForSession: Bool
    ) -> AgentPolicyAdmissionReadiness? {
        if oldestPIDGatedPendingPolicyEntry(for: clientName, matching: clientPid) != nil {
            return .ready
        }

        let descendantStatus = isExpectedAgentDescendant(clientName: clientName, clientPid: clientPid)
        if isReplacementForSession,
           preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) != nil,
           descendantStatus != false
        {
            return .ready
        }

        let hasReservedPIDGatedPolicy = hasPIDGatedPendingPolicy(for: clientName)
        switch descendantStatus {
        case true:
            return hasReservedPIDGatedPolicy ? nil : .ready
        case false:
            return hasReservedPIDGatedPolicy ? nil : .notRequired
        case nil:
            return nil
        }
    }

    private func awaitAgentBootstrapPolicyBeforeAcceptIfNeeded(
        bootstrapClientName: String?,
        connectionID: UUID,
        sessionKey: String?,
        clientPid: Int,
        isReplacementForSession: Bool,
        timeout: TimeInterval = 2.0
    ) async -> AgentPolicyAdmissionReadiness {
        guard let bootstrapClientName,
              Self.isKnownAgentClientName(bootstrapClientName)
        else {
            return .notRequired
        }
        if let readiness = directAgentBootstrapAdmissionStatus(
            clientName: bootstrapClientName,
            sessionKey: sessionKey,
            clientPid: clientPid,
            isReplacementForSession: isReplacementForSession
        ) {
            return readiness
        }
        guard hasPIDGatedPendingPolicy(for: bootstrapClientName)
            || preferredLiveRunAffinity(for: bootstrapClientName, sessionKey: sessionKey) != nil
        else {
            return .notRequired
        }

        let expectedDescription = expectedAgentPIDs(for: bootstrapClientName).map(String.init).sorted().joined(separator: ",")
        let ancestorDescription = pidAncestorChainDescription(from: pid_t(clientPid))
        mcpPolicyLog(
            "holding direct agent bootstrap client=\(bootstrapClientName) connection=\(connectionID) clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] expectedAgentPIDs=[\(expectedDescription)] timeout=\(timeout)s"
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return .timedOut
            }
            try? await Task.sleep(for: .milliseconds(50))
            if let readiness = directAgentBootstrapAdmissionStatus(
                clientName: bootstrapClientName,
                sessionKey: sessionKey,
                clientPid: clientPid,
                isReplacementForSession: isReplacementForSession
            ) {
                return readiness
            }
        }

        mcpPolicyLog(
            "allowing direct agent bootstrap without pending pid-owned policy client=\(bootstrapClientName) connection=\(connectionID) clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] timeout=\(timeout)s"
        )
        return .notRequired
    }

    private func awaitAgentPolicyAdmissionIfNeeded(
        clientName: String,
        bootstrapClientName: String?,
        connectionID: UUID,
        sessionKey: String?,
        clientPid: Int,
        timeout: TimeInterval = 2.0
    ) async -> AgentPolicyAdmissionReadiness {
        guard Self.isKnownAgentClientName(clientName) else {
            return .notRequired
        }

        let isDirectAgentBootstrap = bootstrapClientName.map { bootstrapName in
            Self.isKnownAgentClientName(bootstrapName) && MCPClientIdentity.matches(bootstrapName, clientName)
        } ?? false
        if isDirectAgentBootstrap,
           hasPIDGatedPendingPolicy(for: clientName),
           oldestPIDGatedPendingPolicyEntry(for: clientName, matching: clientPid) == nil
        {
            return await waitForDirectAgentBootstrapOwnership(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: clientPid,
                timeout: timeout,
                holdReason: "direct_agent_mcp_initialize"
            )
        }

        if hasAgentPolicyAdmissionTarget(clientName: clientName, sessionKey: sessionKey, clientPid: clientPid) {
            return .ready
        }

        switch isExpectedAgentDescendant(clientName: clientName, clientPid: clientPid) {
        case true:
            break
        case false, nil:
            return .notRequired
        }
        return await waitForAgentPolicyAdmission(
            clientName: clientName,
            connectionID: connectionID,
            sessionKey: sessionKey,
            clientPid: clientPid,
            timeout: timeout,
            holdReason: "mcp_initialize"
        )
    }

    private func waitForDirectAgentBootstrapOwnership(
        clientName: String,
        connectionID: UUID,
        clientPid: Int,
        timeout: TimeInterval,
        holdReason: String
    ) async -> AgentPolicyAdmissionReadiness {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return .timedOut
            }
            if oldestPIDGatedPendingPolicyEntry(for: clientName, matching: clientPid) != nil {
                return .ready
            }
            if !hasPIDGatedPendingPolicy(for: clientName),
               expectedAgentPIDs(for: clientName).isEmpty
            {
                return .notRequired
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let ancestorDescription = pidAncestorChainDescription(from: pid_t(clientPid))
        mcpPolicyLog(
            "allowing direct agent MCP initialize without pid-owned policy client=\(clientName) connection=\(connectionID) holdReason=\(holdReason) clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] timeout=\(timeout)s"
        )
        return .notRequired
    }

    private func waitForAgentPolicyAdmission(
        clientName: String,
        connectionID: UUID,
        sessionKey: String?,
        clientPid: Int,
        timeout: TimeInterval,
        holdReason: String
    ) async -> AgentPolicyAdmissionReadiness {
        let expectedPIDs = expectedAgentPIDs(for: clientName)
        let expectedDescription = expectedPIDs.map(String.init).sorted().joined(separator: ",")
        let ancestorDescription = pidAncestorChainDescription(from: pid_t(clientPid))
        mcpPolicyLog(
            "holding bootstrap for agent policy client=\(clientName) connection=\(connectionID) reason=\(holdReason) clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] expectedAgentPIDs=[\(expectedDescription)] timeout=\(timeout)s"
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return .timedOut
            }
            try? await Task.sleep(for: .milliseconds(50))
            if hasAgentPolicyAdmissionTarget(clientName: clientName, sessionKey: sessionKey, clientPid: clientPid) {
                mcpPolicyLog(
                    "agent policy admission ready client=\(clientName) connection=\(connectionID) reason=\(holdReason)"
                )
                return .ready
            }
        }

        log.warning(
            "Rejecting bootstrap connection \(connectionID) for known agent client '\(clientName)' - no pending policy or live run affinity appeared within \(timeout)s (\(holdReason))"
        )
        mcpPolicyLog(
            "rejected bootstrap client=\(clientName) connection=\(connectionID) reason=policy_admission_timeout holdReason=\(holdReason) clientPid=\(clientPid) ancestorChain=[\(ancestorDescription)] expectedAgentPIDs=[\(expectedDescription)]"
        )
        return .timedOut
    }

    /// Returns nil when no expected PID is registered yet; otherwise checks whether
    /// the trusted peer pid belongs to one of the currently expected agent processes.
    private func isExpectedAgentDescendant(clientName: String, clientPid: Int, runID: UUID? = nil) -> Bool? {
        let expectedAgentPIDs = expectedAgentPIDs(for: clientName, runID: runID)
        guard !expectedAgentPIDs.isEmpty else { return nil }
        return isAncestor(expectedPIDs: expectedAgentPIDs, ofPid: pid_t(clientPid))
    }

    /// Walks the process ancestor chain from `pid` upward, checking if any ancestor
    /// matches one of the expected PIDs. Stops at PID 1 (launchd) or after a
    /// reasonable depth limit to avoid infinite loops on broken process tables.
    private nonisolated func isAncestor(expectedPIDs: Set<pid_t>, ofPid startPid: pid_t) -> Bool {
        var current = startPid
        for _ in 0 ..< 16 {
            if expectedPIDs.contains(current) {
                return true
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else {
                return false
            }
            current = parent
        }
        return false
    }

    private nonisolated func pidAncestorChainDescription(from startPid: pid_t) -> String {
        var chain = [String(startPid)]
        var current = startPid
        for _ in 0 ..< 16 {
            guard let parent = parentPID(of: current), parent > 1, parent != current else {
                break
            }
            chain.append(String(parent))
            current = parent
        }
        return chain.joined(separator: "<-")
    }

    private nonisolated func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout.stride(ofValue: info)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }

    func installClientConnectionPolicy(
        for clientName: String,
        windowID: Int,
        restrictedTools: Set<String>,
        oneShot: Bool = true,
        reason: String? = nil,
        ttl: TimeInterval = 15,
        tabID: UUID? = nil,
        runID: UUID? = nil,
        additionalTools: Set<String>? = nil,
        purpose: MCPRunPurpose = .unknown,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        requiresExpectedAgentPID: Bool = false
    ) async {
        let storageKey = Self.clientStorageKey(clientName)
        pruneExpiredPolicies(for: clientName)
        let sanitizedRestricted = Self.sanitizedRoutingRestrictedTools(restrictedTools)
        let policy = ClientConnectionPolicy(
            windowID: windowID,
            restrictedTools: sanitizedRestricted,
            oneShot: oneShot,
            reason: reason,
            createdAt: Date(),
            ttl: ttl,
            tabID: tabID,
            runID: runID,
            additionalTools: additionalTools,
            purpose: purpose,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            requiresExpectedAgentPID: requiresExpectedAgentPID
        )
        let grantDescription = Self.describeGrantedTools(restricted: sanitizedRestricted)
        let restrictedDescription = Self.describeToolList(sanitizedRestricted)
        connectionLog(
            "Installing connection policy for client \(clientName) window=\(windowID) grants=\(grantDescription) restricted=\(restrictedDescription) oneShot=\(oneShot) ttl=\(ttl) reason=\(reason ?? "-") role=\(taskLabelKind?.rawValue ?? "-")"
        )
        if let runID {
            seedRunPolicyState(
                runID: runID,
                windowID: windowID,
                workspaceID: nil,
                tabID: tabID,
                restrictedTools: sanitizedRestricted,
                additionalTools: additionalTools,
                purpose: purpose,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools,
                updatedAt: policy.createdAt
            )
        }
        var queue = pendingPoliciesByClient[storageKey] ?? []
        // Agent-mode runs can enqueue policies frequently (e.g. warmup/send/reconnect loops).
        // Keep only the newest pending one-shot agent-mode policy for the same tab/run.
        // Do NOT collapse policies across different tabs in the same window; staggered tab starts
        // must retain independent pending policies until each connection is admitted.
        if oneShot, purpose == .agentModeRun {
            let beforeCount = queue.count
            queue.removeAll {
                guard
                    $0.oneShot,
                    $0.purpose == .agentModeRun,
                    $0.windowID == windowID
                else {
                    return false
                }

                if let newRunID = policy.runID,
                   let existingRunID = $0.runID,
                   existingRunID == newRunID
                {
                    return true
                }
                if let newTabID = policy.tabID,
                   let existingTabID = $0.tabID,
                   existingTabID == newTabID
                {
                    return true
                }

                // Legacy fallback when tab/run context is unavailable: only collapse other
                // legacy policies lacking tab/run context.
                if policy.runID == nil,
                   policy.tabID == nil,
                   $0.runID == nil,
                   $0.tabID == nil
                {
                    return true
                }

                return false
            }
            let removedCount = beforeCount - queue.count
            if removedCount > 0 {
                connectionLog(
                    "Collapsed \(removedCount) stale pending agent-mode policy entries for client \(clientName) storageKey=\(storageKey) window=\(windowID) tabID=\(policy.tabID?.uuidString ?? "nil") runID=\(policy.runID?.uuidString ?? "nil")"
                )
                mcpPolicyLog(
                    "collapsed stale pending policies client=\(clientName) storageKey=\(storageKey) window=\(windowID) tabID=\(policy.tabID?.uuidString ?? "nil") runID=\(policy.runID?.uuidString ?? "nil") removed=\(removedCount)"
                )
            }
        }
        queue.append(policy)
        pendingPoliciesByClient[storageKey] = queue
        mcpPolicyLog(
            "installed policy client=\(clientName) storageKey=\(storageKey) window=\(windowID) purpose=\(purpose.rawValue) oneShot=\(oneShot) ttl=\(ttl)s runID=\(runID?.uuidString ?? "nil") tabID=\(tabID?.uuidString ?? "nil") requiresExpectedPID=\(requiresExpectedAgentPID) queueCount=\(queue.count)"
        )
    }

    func requireExpectedAgentPIDForPendingPolicy(
        for clientName: String,
        runID: UUID,
        windowID: Int? = nil
    ) {
        pruneExpiredPolicies(for: clientName)
        let keys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        var updatedCount = 0
        for key in keys {
            guard var queue = pendingPoliciesByClient[key] else { continue }
            for index in queue.indices {
                guard queue[index].runID == runID else { continue }
                if let windowID, queue[index].windowID != windowID { continue }
                if !queue[index].requiresExpectedAgentPID {
                    queue[index].requiresExpectedAgentPID = true
                    updatedCount += 1
                }
            }
            pendingPoliciesByClient[key] = queue
        }
        mcpPolicyLog(
            "marked policy requires expected pid client=\(clientName) runID=\(runID.uuidString) window=\(windowID.map(String.init) ?? "any") updated=\(updatedCount)"
        )
    }

    #if DEBUG
        func debugPendingPolicySnapshot(for clientName: String) -> [(windowID: Int, tabID: UUID?, runID: UUID?, oneShot: Bool, purpose: MCPRunPurpose)] {
            pruneExpiredPolicies(for: clientName)
            let keys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
            let queue = keys.flatMap { pendingPoliciesByClient[$0] ?? [] }.sorted { $0.createdAt < $1.createdAt }
            return queue.map {
                (
                    windowID: $0.windowID,
                    tabID: $0.tabID,
                    runID: $0.runID,
                    oneShot: $0.oneShot,
                    purpose: $0.purpose
                )
            }
        }

        func debugApplyPendingPolicy(
            clientName: String,
            connectionID: UUID,
            clientPid: Int? = nil,
            bootstrapClientName: String? = nil
        ) async -> (restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, windowID: Int?) {
            pendingConnections[connectionID] = clientName
            await applyPendingPolicyIfAvailable(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: clientPid,
                bootstrapClientName: bootstrapClientName
            )
            return debugConnectionPolicyState(for: connectionID)
        }

        func debugAgentPolicyAdmissionStatus(
            clientName: String,
            bootstrapClientName: String? = nil,
            connectionID: UUID,
            sessionKey: String? = nil,
            clientPid: Int,
            timeout: TimeInterval = 0.05
        ) async -> String {
            let readiness = await awaitAgentPolicyAdmissionIfNeeded(
                clientName: clientName,
                bootstrapClientName: bootstrapClientName,
                connectionID: connectionID,
                sessionKey: sessionKey,
                clientPid: clientPid,
                timeout: timeout
            )
            switch readiness {
            case .notRequired:
                return "notRequired"
            case .ready:
                return "ready"
            case .timedOut:
                return "timedOut"
            }
        }

        func debugRunPolicyState(for runID: UUID) -> (windowID: Int, workspaceID: UUID?, restrictedTools: Set<String>, additionalTools: Set<String>?, purpose: MCPRunPurpose)? {
            guard let cached = runPolicyStateByRunID[runID] else { return nil }
            return (
                windowID: cached.windowID,
                workspaceID: cached.workspaceID,
                restrictedTools: cached.restrictedTools,
                additionalTools: cached.additionalTools,
                purpose: cached.purpose
            )
        }

        func debugSeedRunPolicyState(
            runID: UUID,
            windowID: Int = 1,
            workspaceID: UUID? = nil,
            tabID: UUID? = nil,
            restrictedTools: Set<String>,
            additionalTools: Set<String>?,
            purpose: MCPRunPurpose,
            updatedAt: Date = Date()
        ) {
            seedRunPolicyState(
                runID: runID,
                windowID: windowID,
                workspaceID: workspaceID,
                tabID: tabID,
                restrictedTools: restrictedTools,
                additionalTools: additionalTools,
                purpose: purpose,
                updatedAt: updatedAt
            )
        }

        func debugConnectionPolicyState(for connectionID: UUID) -> (restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, windowID: Int?) {
            (
                restrictedTools: restrictedToolsByConnection[connectionID] ?? [],
                additionalTools: additionalToolsByConnection[connectionID] ?? [],
                purpose: runPurposeByConnection[connectionID] ?? .unknown,
                windowID: connectionWindowMap[connectionID]
            )
        }

        func debugSeedConnectionRunRouting(
            connectionID: UUID,
            runID: UUID,
            purpose: MCPRunPurpose = .unknown,
            windowID: Int? = nil
        ) {
            runIDByConnectionID[connectionID] = runID
            if purpose != .unknown || runPurposeByConnection[connectionID] == nil {
                runPurposeByConnection[connectionID] = purpose
            }
            if let windowID {
                connectionWindowMap[connectionID] = windowID
                windowIDByRunID[runID] = windowID
            }
        }

        func debugRestorePersistedAgentModePolicy(
            clientName: String,
            connectionID: UUID,
            windowID: Int,
            runID: UUID?,
            runPurpose _: MCPRunPurpose?
        ) async -> (didRestore: Bool, restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, cachedPolicyPurpose: MCPRunPurpose?) {
            setConnectionWindowMapping(connectionID, windowID: windowID)
            let cachedPurpose = runID.flatMap { runPolicyStateByRunID[$0]?.purpose }
            let didRestore: Bool
            if let runID,
               runPolicyStateByRunID[runID] != nil,
               shouldAllowPersistedAgentModeRestore(clientName: clientName, purpose: cachedPurpose ?? .unknown)
            {
                updateLiveRunAffinity(
                    clientName: clientName,
                    sessionKey: capabilityTokenByConnection[connectionID],
                    runID: runID,
                    windowID: windowID,
                    purpose: cachedPurpose
                )
                didRestore = await mapConnectionToRunID(connectionID, runID: runID, windowID: windowID)
            } else {
                didRestore = false
            }
            let state = debugConnectionPolicyState(for: connectionID)
            return (
                didRestore: didRestore,
                restrictedTools: state.restrictedTools,
                additionalTools: state.additionalTools,
                purpose: state.purpose,
                cachedPolicyPurpose: cachedPurpose
            )
        }

        func debugEffectivePolicyState(for connectionID: UUID) -> (restrictedTools: Set<String>, additionalTools: Set<String>, purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind?) {
            let policy = effectivePolicyState(for: connectionID)
            return (
                restrictedTools: policy.restricted,
                additionalTools: policy.additional,
                purpose: policy.purpose,
                taskLabelKind: policy.taskLabelKind
            )
        }

        func debugCanRestoreLiveRunAffinity(hasCachedPolicy: Bool) -> Bool {
            let runID = UUID()
            if hasCachedPolicy {
                seedRunPolicyState(
                    runID: runID,
                    windowID: 1,
                    workspaceID: nil,
                    tabID: nil,
                    restrictedTools: [],
                    additionalTools: nil,
                    purpose: .agentModeRun,
                    updatedAt: Date()
                )
            }
            let canRestore = runPolicyStateByRunID[runID] != nil
            runPolicyStateByRunID.removeValue(forKey: runID)
            return canRestore
        }

        #if DEBUG
            private nonisolated func debugDateMilliseconds(_ date: Date) -> Int {
                Int((date.timeIntervalSince1970 * 1000).rounded())
            }

            private nonisolated func debugConnectionStateString(_ state: ConnectionStateSnapshot) -> String {
                switch state {
                case .connecting: "connecting"
                case .ready: "ready"
                case .failed: "failed"
                case .cancelled: "cancelled"
                }
            }

            private nonisolated func debugBindingKindString(_ kind: MCPServerViewModel.ConnectionBindingSnapshot.BindingKind) -> String {
                switch kind {
                case .tabContext: "tab_context"
                case .windowOnly: "window_only"
                case .unbound: "unbound"
                }
            }

            func debugSessionFingerprint(forToken token: String?) -> String? {
                guard let token, !token.isEmpty else { return nil }
                let salted = "RepoPrompt.DEBUG.MCP.session:\(token)"
                let digest = SHA256.hash(data: Data(salted.utf8))
                let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
                return "sha256:\(hex)"
            }

            func debugSessionFingerprint(forConnection connectionID: UUID) -> String? {
                debugSessionFingerprint(forToken: sessionToken(for: connectionID))
            }

            func debugNormalizedClientID(for clientName: String?) -> String? {
                guard let clientName, !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return Self.clientStorageKey(clientName)
            }

            private func debugRecordConnectionEvent(
                _ event: String,
                connectionID: UUID? = nil,
                restartID: UUID? = nil,
                reason: String? = nil,
                state: String? = nil,
                clientName overrideClientName: String? = nil,
                sessionToken overrideSessionToken: String? = nil,
                windowID overrideWindowID: Int? = nil
            ) {
                debugConnectionHistorySeq &+= 1
                let resolvedClientName = overrideClientName ?? connectionID.flatMap { clientIdentifier(forConnection: $0) }
                let resolvedSessionToken = overrideSessionToken ?? connectionID.flatMap { sessionToken(for: $0) }
                let resolvedState: String? = state
                let entry = DebugConnectionEvent(
                    seq: debugConnectionHistorySeq,
                    timestamp: Date(),
                    event: event,
                    restartID: restartID,
                    connectionID: connectionID,
                    clientName: resolvedClientName,
                    normalizedClientID: debugNormalizedClientID(for: resolvedClientName),
                    sessionFingerprint: debugSessionFingerprint(forToken: resolvedSessionToken),
                    windowID: overrideWindowID ?? connectionID.flatMap { connectionWindowMap[$0] },
                    state: resolvedState,
                    reason: reason
                )
                debugConnectionHistory.append(entry)
                if debugConnectionHistory.count > debugConnectionHistoryLimit {
                    debugConnectionHistory.removeFirst(debugConnectionHistory.count - debugConnectionHistoryLimit)
                }
            }

            private func debugHistoryObject(_ event: DebugConnectionEvent) -> [String: Any] {
                [
                    "seq": Int(event.seq),
                    "timestamp_ms": debugDateMilliseconds(event.timestamp),
                    "event": event.event,
                    "restart_id": event.restartID?.uuidString ?? NSNull(),
                    "connection_id": event.connectionID?.uuidString ?? NSNull(),
                    "client_name": event.clientName ?? NSNull(),
                    "normalized_client_id": event.normalizedClientID ?? NSNull(),
                    "session_key_present": event.sessionFingerprint != nil,
                    "session_fingerprint": event.sessionFingerprint ?? NSNull(),
                    "window_id": event.windowID ?? NSNull(),
                    "state": event.state ?? NSNull(),
                    "reason": event.reason ?? NSNull()
                ]
            }

            private func debugConnectionObject(for entry: ConnectionDashboardEntry) -> [String: Any] {
                let identity = identityContext(for: entry.id)
                let clientName = identity?.clientName ?? clientIdentifier(forConnection: entry.id) ?? (entry.clientName.isEmpty ? nil : entry.clientName)
                let fingerprint = debugSessionFingerprint(forToken: entry.sessionKey)
                return [
                    "id": entry.id.uuidString,
                    "client_name": clientName ?? NSNull(),
                    "normalized_client_id": debugNormalizedClientID(for: clientName) ?? NSNull(),
                    "session_key_present": entry.sessionKey != nil,
                    "session_fingerprint": fingerprint ?? NSNull(),
                    "window_id": entry.windowID ?? NSNull(),
                    "state": entry.state.rawValue,
                    "transport": entry.transport.rawValue,
                    "created_at_ms": debugDateMilliseconds(entry.createdAt),
                    "last_tool_call_at_ms": entry.lastToolCallAt.map(debugDateMilliseconds) ?? NSNull(),
                    "total_tool_calls": entry.totalToolCalls,
                    "idle_seconds": entry.idleSeconds ?? NSNull(),
                    "has_in_flight_calls": entry.hasInFlightCalls,
                    "active_tool_name": entry.activeToolName ?? NSNull(),
                    "identity": [
                        "client_name": identity?.clientName ?? NSNull(),
                        "source": identity?.source.rawValue ?? "unknown",
                        "has_handshake": identity?.hasHandshake ?? false,
                        "session_key_present": identity?.capabilityToken != nil,
                        "session_fingerprint": debugSessionFingerprint(forToken: identity?.capabilityToken) ?? NSNull()
                    ] as [String: Any]
                ]
            }

            private func debugBindingSnapshot(for connectionID: UUID, selectedWindowID: Int?) async -> MCPServerViewModel.ConnectionBindingSnapshot {
                await MainActor.run {
                    let windows = WindowStatesManager.shared.allWindows
                    let snapshots = windows.map { $0.mcpServer.connectionBindingSnapshot(forConnection: connectionID) }
                    if let explicit = snapshots.first(where: { $0.bindingKind == .tabContext && $0.explicitlyBound && $0.runID == nil }) {
                        return explicit
                    }
                    if let runScoped = snapshots.first(where: { $0.bindingKind == .tabContext && $0.runID != nil }) {
                        return runScoped
                    }
                    if let context = snapshots.first(where: { $0.bindingKind == .tabContext }) {
                        return context
                    }
                    if let selectedWindowID,
                       let selectedWindow = windows.first(where: { $0.windowID == selectedWindowID })
                    {
                        let workspace = selectedWindow.workspaceManager.activeWorkspace
                        return MCPServerViewModel.ConnectionBindingSnapshot(
                            windowID: selectedWindowID,
                            tabID: nil,
                            workspaceID: workspace?.id,
                            workspaceName: workspace?.isSystemWorkspace == true ? "Default (no workspace loaded)" : workspace?.name,
                            tabName: nil,
                            repoPaths: workspace.map { WorkspaceManagerViewModel.loadableRepoPaths(for: $0) } ?? [],
                            explicitlyBound: false,
                            runID: nil
                        )
                    }
                    return MCPServerViewModel.ConnectionBindingSnapshot(
                        windowID: nil,
                        tabID: nil,
                        workspaceID: nil,
                        workspaceName: nil,
                        tabName: nil,
                        repoPaths: [],
                        explicitlyBound: false,
                        runID: nil
                    )
                }
            }

            private func debugBindingObject(_ snapshot: MCPServerViewModel.ConnectionBindingSnapshot) -> [String: Any] {
                [
                    "binding_kind": debugBindingKindString(snapshot.bindingKind),
                    "window_id": snapshot.windowID ?? NSNull(),
                    "context_id": snapshot.tabID?.uuidString ?? NSNull(),
                    "workspace_id": snapshot.workspaceID?.uuidString ?? NSNull(),
                    "workspace_name": snapshot.workspaceName ?? NSNull(),
                    "tab_name": snapshot.tabName ?? NSNull(),
                    "repo_paths": snapshot.repoPaths,
                    "explicit": snapshot.explicitlyBound,
                    "run_scoped": snapshot.runID != nil,
                    "run_id": snapshot.runID?.uuidString ?? NSNull()
                ]
            }

            private func debugWindowObjects() async -> [[String: Any]] {
                await MainActor.run {
                    WindowStatesManager.shared.allWindows.map { window in
                        let workspace = window.workspaceManager.activeWorkspace
                        let activeTabID = window.promptManager.activeComposeTabID
                        let workspaceID: Any = workspace?.id.uuidString ?? NSNull()
                        let workspaceName: Any = if workspace?.isSystemWorkspace == true {
                            "Default (no workspace loaded)"
                        } else {
                            workspace?.name ?? NSNull()
                        }
                        let workspaceInstanceNumber: Any = window.workspaceInstanceNumber ?? NSNull()
                        let activeContextID: Any = activeTabID?.uuidString ?? NSNull()
                        let activeContextName: Any = activeTabID.flatMap { window.workspaceManager.composeTabName(with: $0) } ?? NSNull()
                        let repoPaths: [String] = workspace.map { WorkspaceManagerViewModel.loadableRepoPaths(for: $0) } ?? []
                        return [
                            "window_id": window.windowID,
                            "workspace_id": workspaceID,
                            "workspace_name": workspaceName,
                            "workspace_instance_number": workspaceInstanceNumber,
                            "active_context_id": activeContextID,
                            "active_context_name": activeContextName,
                            "repo_paths": repoPaths
                        ] as [String: Any]
                    }
                }
            }

            private func debugPersistedRecordObjects(clientNameFilter: String?, sessionFingerprint: String?) -> [[String: Any]] {
                let keys: [String] = if let clientNameFilter, !clientNameFilter.isEmpty {
                    matchingClientKeys(for: clientNameFilter, in: Array(routingState.records.keys))
                } else {
                    Array(routingState.records.keys).sorted()
                }
                return keys.flatMap { key in
                    (routingState.records[key] ?? []).compactMap { record -> [String: Any]? in
                        let fingerprint = debugSessionFingerprint(forToken: record.sessionKey)
                        if let sessionFingerprint, fingerprint != sessionFingerprint {
                            return nil
                        }
                        return [
                            "client_id": key,
                            "last_transport": record.lastTransport.rawValue,
                            "session_key_present": record.sessionKey != nil,
                            "session_fingerprint": fingerprint ?? NSNull(),
                            "last_window_id": record.lastWindowID ?? NSNull(),
                            "last_workspace_id": record.lastWorkspaceID?.uuidString ?? NSNull(),
                            "last_workspace_instance_number": record.lastWorkspaceInstanceNumber ?? NSNull(),
                            "last_connection_uuid": record.lastConnectionUUID?.uuidString ?? NSNull(),
                            "last_seen_at_ms": debugDateMilliseconds(record.lastSeenAt)
                        ]
                    }
                }
            }

            func debugBindingKind(for connectionID: UUID) async -> String {
                let snapshot = await debugBindingSnapshot(for: connectionID, selectedWindowID: connectionWindowMap[connectionID])
                return debugBindingKindString(snapshot.bindingKind)
            }

            private func debugLiveAffinityObject(clientName: String?, sessionKey: String?) -> [String: Any] {
                guard let clientName, let sessionKey else {
                    return ["present": false, "window_id": NSNull(), "run_id": NSNull(), "purpose": NSNull()]
                }
                let keys = matchingClientKeys(for: clientName, in: Array(liveRunAffinityByClientSession.keys))
                guard let key = keys.first,
                      let affinity = liveRunAffinityByClientSession[key]?[sessionKey]
                else {
                    return ["present": false, "window_id": NSNull(), "run_id": NSNull(), "purpose": NSNull()]
                }
                return [
                    "present": true,
                    "window_id": affinity.windowID,
                    "run_id": affinity.runID.uuidString,
                    "purpose": affinity.purpose.rawValue,
                    "last_seen_at_ms": debugDateMilliseconds(affinity.lastSeenAt)
                ]
            }

            func debugConnectionSnapshotPayload(
                currentConnectionID: UUID,
                requestedConnectionID: UUID?,
                includeHistory: Bool,
                historyLimit: Int
            ) async -> [String: Any] {
                let targetID = requestedConnectionID ?? currentConnectionID
                let snapshot = await dashboardSnapshot()
                let entry = snapshot.connections.first { $0.id == targetID }
                var payload: [String: Any] = [
                    "ok": true,
                    "op": "connection_snapshot",
                    "current_connection_id": currentConnectionID.uuidString,
                    "requested_connection_id": targetID.uuidString,
                    "connection": entry.map(debugConnectionObject) ?? NSNull(),
                    "missing": entry == nil
                ]
                if includeHistory {
                    payload["history"] = debugConnectionHistoryPayload(limit: historyLimit, clientName: nil, sessionFingerprint: nil, connectionID: targetID)["events"] ?? []
                }
                return payload
            }

            func debugRoutingSnapshotPayload(
                currentConnectionID: UUID,
                requestedConnectionID: UUID?,
                clientNameFilter: String?,
                includeRecords: Bool,
                includeWindows: Bool
            ) async -> [String: Any] {
                let targetID = requestedConnectionID ?? currentConnectionID
                let snapshot = await dashboardSnapshot()
                let entry = snapshot.connections.first { $0.id == targetID }
                let clientName = clientNameFilter ?? entry?.clientName ?? clientIdentifier(forConnection: targetID)
                let sessionKey = entry?.sessionKey ?? sessionToken(for: targetID)
                let fingerprint = debugSessionFingerprint(forToken: sessionKey)
                let selectedWindowID = entry?.windowID ?? connectionWindowMap[targetID]
                let binding = await debugBindingSnapshot(for: targetID, selectedWindowID: selectedWindowID)
                let liveAffinity = debugLiveAffinityObject(clientName: clientName, sessionKey: sessionKey)
                var payload: [String: Any] = [
                    "ok": true,
                    "op": "routing_snapshot",
                    "current_connection_id": currentConnectionID.uuidString,
                    "connection": entry.map(debugConnectionObject) ?? [
                        "id": targetID.uuidString,
                        "client_name": clientName ?? NSNull(),
                        "normalized_client_id": debugNormalizedClientID(for: clientName) ?? NSNull(),
                        "session_key_present": fingerprint != nil,
                        "session_fingerprint": fingerprint ?? NSNull(),
                        "selected_window_id": selectedWindowID ?? NSNull(),
                        "run_id": runIDByConnectionID[targetID]?.uuidString ?? NSNull(),
                        "purpose": runPurposeByConnection[targetID]?.rawValue ?? "unknown"
                    ] as [String: Any],
                    "binding": debugBindingObject(binding),
                    "live_affinity": liveAffinity
                ]
                if includeRecords {
                    payload["persisted_records"] = debugPersistedRecordObjects(clientNameFilter: clientName, sessionFingerprint: fingerprint)
                }
                if includeWindows {
                    payload["windows"] = await debugWindowObjects()
                }
                return payload
            }

            func debugConnectionHistoryPayload(limit: Int, clientName: String?, sessionFingerprint: String?, connectionID: UUID?) -> [String: Any] {
                var events = debugConnectionHistory
                if let connectionID {
                    events = events.filter { $0.connectionID == connectionID }
                }
                if let clientName, !clientName.isEmpty {
                    events = events.filter { event in
                        guard let eventClientName = event.clientName else { return false }
                        return MCPClientIdentity.matches(eventClientName, clientName)
                    }
                }
                if let sessionFingerprint, !sessionFingerprint.isEmpty {
                    events = events.filter { $0.sessionFingerprint == sessionFingerprint }
                }
                events = Array(events.suffix(limit))
                return [
                    "ok": true,
                    "op": "connection_history",
                    "events": events.map(debugHistoryObject)
                ]
            }

            func debugClearConnectionHistoryPayload() -> [String: Any] {
                let removed = debugConnectionHistory.count
                debugConnectionHistory.removeAll()
                return [
                    "ok": true,
                    "op": "clear_connection_history",
                    "cleared": true,
                    "removed_count": removed
                ]
            }

            func debugWaitForReconnectPayload(
                currentConnectionID: UUID,
                clientName requestedClientName: String?,
                sessionFingerprint requestedFingerprint: String?,
                excludeConnectionIDs: Set<UUID>,
                timeoutMS: Int,
                pollMS: Int,
                requireReady: Bool
            ) async -> [String: Any] {
                let start = Date()
                let fallbackClientName = clientIdentifier(forConnection: currentConnectionID) ?? identityContext(for: currentConnectionID)?.clientName
                let clientName = requestedClientName ?? fallbackClientName
                let fingerprint = requestedFingerprint ?? debugSessionFingerprint(forConnection: currentConnectionID)
                guard let clientName, let fingerprint else {
                    return [
                        "ok": false,
                        "op": "wait_for_reconnect",
                        "code": "invalid_params",
                        "error": "client_name and session_fingerprint must be provided or resolvable from the current connection."
                    ]
                }

                let deadline = start.addingTimeInterval(Double(timeoutMS) / 1000.0)
                var found: ConnectionDashboardEntry?
                repeat {
                    let snapshot = await dashboardSnapshot()
                    found = snapshot.connections.first { entry in
                        guard !excludeConnectionIDs.contains(entry.id) else { return false }
                        guard MCPClientIdentity.matches(entry.clientName, clientName) else { return false }
                        guard debugSessionFingerprint(forToken: entry.sessionKey) == fingerprint else { return false }
                        if requireReady, entry.state != .ready { return false }
                        return true
                    }
                    if found != nil { break }
                    try? await Task.sleep(for: .milliseconds(pollMS))
                } while Date() < deadline

                let elapsed = debugDateMilliseconds(Date()) - debugDateMilliseconds(start)
                return [
                    "ok": true,
                    "op": "wait_for_reconnect",
                    "found": found != nil,
                    "elapsed_ms": elapsed,
                    "connection": found.map(debugConnectionObject) ?? NSNull()
                ]
            }

            func debugClearRoutingStatePayload(currentConnectionID: UUID, clientName: String?, allClients: Bool) -> [String: Any] {
                let resolvedClientName = clientName ?? clientIdentifier(forConnection: currentConnectionID) ?? identityContext(for: currentConnectionID)?.clientName
                let removedCount: Int
                if allClients {
                    removedCount = routingState.records.values.reduce(0) { $0 + $1.count }
                    routingState.records.removeAll()
                    lastWindowByClientSession.removeAll()
                    liveRunAffinityByClientSession.removeAll()
                } else if let resolvedClientName {
                    let keys = matchingClientKeys(for: resolvedClientName, in: Array(routingState.records.keys))
                    removedCount = keys.reduce(0) { $0 + (routingState.records[$1]?.count ?? 0) }
                    for key in keys {
                        routingState.records.removeValue(forKey: key)
                    }
                    for key in matchingClientKeys(for: resolvedClientName, in: Array(lastWindowByClientSession.keys)) {
                        lastWindowByClientSession.removeValue(forKey: key)
                    }
                    for key in matchingClientKeys(for: resolvedClientName, in: Array(liveRunAffinityByClientSession.keys)) {
                        liveRunAffinityByClientSession.removeValue(forKey: key)
                    }
                } else {
                    return [
                        "ok": false,
                        "op": "clear_routing_state",
                        "code": "invalid_params",
                        "error": "client_name must be provided or resolvable unless all_clients=true."
                    ]
                }
                saveRoutingState()
                return [
                    "ok": true,
                    "op": "clear_routing_state",
                    "cleared": true,
                    "client_name": resolvedClientName ?? NSNull(),
                    "all_clients": allClients,
                    "removed_record_count": removedCount
                ]
            }

            struct DebugExactRoutingSessionFixtureSession {
                let sessionFingerprint: String
                let expectedLastConnectionID: UUID
                let rawSessionToken: String
            }

            struct DebugExactRoutingSessionFixture {
                let restoreID: UUID
                let sessionA: DebugExactRoutingSessionFixtureSession
                let sessionB: DebugExactRoutingSessionFixtureSession
                let reboundConnectionID: UUID
            }

            struct DebugExactRoutingSessionFixtureState: Equatable {
                let persistedRecordCountByFingerprint: [String: Int]
                let lastWindowEntryCountByFingerprint: [String: Int]
                let liveRunAffinityEntryCountByFingerprint: [String: Int]
            }

            private struct DebugExactRoutingSessionFixtureRestorePoint {
                let routingState: MCPRoutingState
                let lastWindowByClientSession: [String: [String: Int]]
                let liveRunAffinityByClientSession: [String: [String: LiveRunAffinity]]
                let pendingConnections: [UUID: String]
                let activeConnectionsByClient: [String: Set<UUID>]
                let clientIDByConnection: [UUID: String]
                let capabilityTokenByConnection: [UUID: String]
                let connectionIDBySessionToken: [String: UUID]
            }

            func debugClearPersistedRoutingSessionPayload(
                sessionFingerprint: String,
                expectedLastConnectionID: UUID
            ) -> [String: Any] {
                guard !debugHasActiveOrPendingRuntimeResidue(for: expectedLastConnectionID) else {
                    return debugExactRoutingSessionCleanupError(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        code: "target_connection_active_or_pending",
                        message: "expected_last_connection_id remains active or pending."
                    )
                }

                var matchingRawSessionKeys = Set<String>()
                for records in routingState.records.values {
                    for record in records {
                        guard let sessionKey = record.sessionKey, !sessionKey.isEmpty else { continue }
                        if debugSessionFingerprint(forToken: sessionKey) == sessionFingerprint {
                            matchingRawSessionKeys.insert(sessionKey)
                        }
                    }
                }
                for sessionMap in lastWindowByClientSession.values {
                    for sessionKey in sessionMap.keys where !sessionKey.isEmpty {
                        if debugSessionFingerprint(forToken: sessionKey) == sessionFingerprint {
                            matchingRawSessionKeys.insert(sessionKey)
                        }
                    }
                }
                for sessionMap in liveRunAffinityByClientSession.values {
                    for sessionKey in sessionMap.keys where !sessionKey.isEmpty {
                        if debugSessionFingerprint(forToken: sessionKey) == sessionFingerprint {
                            matchingRawSessionKeys.insert(sessionKey)
                        }
                    }
                }

                guard !matchingRawSessionKeys.isEmpty else {
                    return debugExactRoutingSessionCleanupSuccess(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        alreadyAbsent: true,
                        removedPersistedRecordCount: 0,
                        removedLastWindowEntryCount: 0,
                        removedLiveRunAffinityEntryCount: 0
                    )
                }
                guard matchingRawSessionKeys.count == 1, let rawSessionKey = matchingRawSessionKeys.first else {
                    return debugExactRoutingSessionCleanupError(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        code: "ambiguous_session_fingerprint",
                        message: "session_fingerprint resolves to multiple persisted routing sessions."
                    )
                }

                let matchedRecords = routingState.records.flatMap { clientID, records in
                    records.compactMap { record -> (clientID: String, record: MCPRoutingState.ClientRecord)? in
                        record.sessionKey == rawSessionKey ? (clientID, record) : nil
                    }
                }
                guard !matchedRecords.isEmpty else {
                    return debugExactRoutingSessionCleanupError(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        code: "unexpected_routing_state_shape",
                        message: "session_fingerprint resolved only to map residue without a persisted record."
                    )
                }
                for matchedRecord in matchedRecords {
                    guard matchedRecord.record.sessionKey == rawSessionKey,
                          !rawSessionKey.isEmpty,
                          matchedRecord.record.clientID == matchedRecord.clientID
                    else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "unexpected_routing_state_shape",
                            message: "Persisted routing record shape is inconsistent."
                        )
                    }
                    guard let lastConnectionUUID = matchedRecord.record.lastConnectionUUID else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "unexpected_routing_state_shape",
                            message: "Persisted routing record is missing last_connection_id corroboration."
                        )
                    }
                    guard lastConnectionUUID == expectedLastConnectionID else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "last_connection_id_mismatch",
                            message: "Persisted routing record does not match expected_last_connection_id."
                        )
                    }
                }

                let reverseConnectionID = connectionIDBySessionToken[rawSessionKey]
                let forwardConnectionIDs = Set(capabilityTokenByConnection.compactMap { connectionID, sessionKey in
                    sessionKey == rawSessionKey ? connectionID : nil
                })
                let activeConnectionTokenIDs = Set(connections.compactMap { connectionID, connection in
                    connection.capabilityToken == rawSessionKey ? connectionID : nil
                })
                if reverseConnectionID != nil || !forwardConnectionIDs.isEmpty || !activeConnectionTokenIDs.isEmpty {
                    guard let reverseConnectionID,
                          forwardConnectionIDs == Set([reverseConnectionID]),
                          activeConnectionTokenIDs.isEmpty || activeConnectionTokenIDs == Set([reverseConnectionID])
                    else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "unexpected_routing_state_shape",
                            message: "Session token caches are stale or inconsistent."
                        )
                    }
                    guard debugHasActiveOrPendingRuntimeResidue(for: reverseConnectionID) else {
                        return debugExactRoutingSessionCleanupError(
                            sessionFingerprint: sessionFingerprint,
                            expectedLastConnectionID: expectedLastConnectionID,
                            code: "unexpected_routing_state_shape",
                            message: "Session token caches reference a non-live connection."
                        )
                    }
                    return debugExactRoutingSessionCleanupError(
                        sessionFingerprint: sessionFingerprint,
                        expectedLastConnectionID: expectedLastConnectionID,
                        code: "session_rebound_active",
                        message: "Persisted routing session is rebound to a live connection."
                    )
                }

                var nextRecords = routingState.records
                var removedPersistedRecordCount = 0
                for clientID in Array(nextRecords.keys) {
                    guard let records = nextRecords[clientID] else { continue }
                    let retainedRecords = records.filter { $0.sessionKey != rawSessionKey }
                    removedPersistedRecordCount += records.count - retainedRecords.count
                    if retainedRecords.isEmpty {
                        nextRecords.removeValue(forKey: clientID)
                    } else {
                        nextRecords[clientID] = retainedRecords
                    }
                }

                var nextLastWindowByClientSession = lastWindowByClientSession
                var removedLastWindowEntryCount = 0
                for clientID in Array(nextLastWindowByClientSession.keys) {
                    guard var sessionMap = nextLastWindowByClientSession[clientID] else { continue }
                    if sessionMap.removeValue(forKey: rawSessionKey) != nil {
                        removedLastWindowEntryCount += 1
                    }
                    if sessionMap.isEmpty {
                        nextLastWindowByClientSession.removeValue(forKey: clientID)
                    } else {
                        nextLastWindowByClientSession[clientID] = sessionMap
                    }
                }

                var nextLiveRunAffinityByClientSession = liveRunAffinityByClientSession
                var removedLiveRunAffinityEntryCount = 0
                for clientID in Array(nextLiveRunAffinityByClientSession.keys) {
                    guard var sessionMap = nextLiveRunAffinityByClientSession[clientID] else { continue }
                    if sessionMap.removeValue(forKey: rawSessionKey) != nil {
                        removedLiveRunAffinityEntryCount += 1
                    }
                    if sessionMap.isEmpty {
                        nextLiveRunAffinityByClientSession.removeValue(forKey: clientID)
                    } else {
                        nextLiveRunAffinityByClientSession[clientID] = sessionMap
                    }
                }

                routingState.records = nextRecords
                lastWindowByClientSession = nextLastWindowByClientSession
                liveRunAffinityByClientSession = nextLiveRunAffinityByClientSession
                if removedPersistedRecordCount > 0 {
                    saveRoutingState()
                }
                return debugExactRoutingSessionCleanupSuccess(
                    sessionFingerprint: sessionFingerprint,
                    expectedLastConnectionID: expectedLastConnectionID,
                    alreadyAbsent: false,
                    removedPersistedRecordCount: removedPersistedRecordCount,
                    removedLastWindowEntryCount: removedLastWindowEntryCount,
                    removedLiveRunAffinityEntryCount: removedLiveRunAffinityEntryCount
                )
            }

            private func debugHasActiveOrPendingRuntimeResidue(for connectionID: UUID) -> Bool {
                connections[connectionID] != nil
                    || connectionTasks[connectionID] != nil
                    || pendingConnections[connectionID] != nil
                    || bootstrapReservations[connectionID] != nil
                    || clientIDByConnection[connectionID] != nil
                    || activeConnectionsByClient.values.contains { $0.contains(connectionID) }
                    || callLimiters[connectionID] != nil
            }

            private func debugExactRoutingSessionCleanupSuccess(
                sessionFingerprint: String,
                expectedLastConnectionID: UUID,
                alreadyAbsent: Bool,
                removedPersistedRecordCount: Int,
                removedLastWindowEntryCount: Int,
                removedLiveRunAffinityEntryCount: Int
            ) -> [String: Any] {
                let removedTotalCount = removedPersistedRecordCount
                    + removedLastWindowEntryCount
                    + removedLiveRunAffinityEntryCount
                return [
                    "ok": true,
                    "op": "clear_persisted_routing_session",
                    "session_fingerprint": sessionFingerprint,
                    "expected_last_connection_id": expectedLastConnectionID.uuidString,
                    "already_absent": alreadyAbsent,
                    "changed": removedTotalCount > 0,
                    "removed_persisted_record_count": removedPersistedRecordCount,
                    "removed_last_window_entry_count": removedLastWindowEntryCount,
                    "removed_live_run_affinity_entry_count": removedLiveRunAffinityEntryCount,
                    "removed_total_count": removedTotalCount
                ]
            }

            private func debugExactRoutingSessionCleanupError(
                sessionFingerprint: String,
                expectedLastConnectionID: UUID,
                code: String,
                message: String
            ) -> [String: Any] {
                [
                    "ok": false,
                    "op": "clear_persisted_routing_session",
                    "session_fingerprint": sessionFingerprint,
                    "expected_last_connection_id": expectedLastConnectionID.uuidString,
                    "code": code,
                    "error": message
                ]
            }

            func debugSeedExactRoutingSessionFixture() -> DebugExactRoutingSessionFixture {
                let clientID = AgentProviderKind.codexMCPClientID
                let sessionAToken = "debug-exact-routing-session-a"
                let sessionBToken = "debug-exact-routing-session-b"
                let sessionAConnectionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
                let sessionBConnectionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
                let reboundConnectionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
                let restoreID = UUID()
                debugExactRoutingSessionRestorePoints[restoreID] = DebugExactRoutingSessionFixtureRestorePoint(
                    routingState: routingState,
                    lastWindowByClientSession: lastWindowByClientSession,
                    liveRunAffinityByClientSession: liveRunAffinityByClientSession,
                    pendingConnections: pendingConnections,
                    activeConnectionsByClient: activeConnectionsByClient,
                    clientIDByConnection: clientIDByConnection,
                    capabilityTokenByConnection: capabilityTokenByConnection,
                    connectionIDBySessionToken: connectionIDBySessionToken
                )

                debugRemoveExactRoutingSessionFixtureToken(sessionAToken)
                debugRemoveExactRoutingSessionFixtureToken(sessionBToken)
                debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: sessionAConnectionID)
                debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: sessionBConnectionID)
                debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: reboundConnectionID)

                routingState.records[clientID, default: []].append(contentsOf: [
                    MCPRoutingState.ClientRecord(
                        clientID: clientID,
                        lastTransport: .network,
                        sessionKey: sessionAToken,
                        lastWindowID: 9101,
                        lastWorkspaceID: nil,
                        lastWorkspaceInstanceNumber: nil,
                        lastConnectionUUID: sessionAConnectionID,
                        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_001)
                    ),
                    MCPRoutingState.ClientRecord(
                        clientID: clientID,
                        lastTransport: .network,
                        sessionKey: sessionBToken,
                        lastWindowID: 9102,
                        lastWorkspaceID: nil,
                        lastWorkspaceInstanceNumber: nil,
                        lastConnectionUUID: sessionBConnectionID,
                        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_002)
                    )
                ])
                lastWindowByClientSession[clientID, default: [:]][sessionAToken] = 9101
                lastWindowByClientSession[clientID, default: [:]][sessionBToken] = 9102
                liveRunAffinityByClientSession[clientID, default: [:]][sessionAToken] = LiveRunAffinity(
                    windowID: 9101,
                    runID: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
                    purpose: .agentModeRun,
                    lastSeenAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
                liveRunAffinityByClientSession[clientID, default: [:]][sessionBToken] = LiveRunAffinity(
                    windowID: 9102,
                    runID: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
                    purpose: .agentModeRun,
                    lastSeenAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
                saveRoutingState()

                return DebugExactRoutingSessionFixture(
                    restoreID: restoreID,
                    sessionA: DebugExactRoutingSessionFixtureSession(
                        sessionFingerprint: debugSessionFingerprint(forToken: sessionAToken)!,
                        expectedLastConnectionID: sessionAConnectionID,
                        rawSessionToken: sessionAToken
                    ),
                    sessionB: DebugExactRoutingSessionFixtureSession(
                        sessionFingerprint: debugSessionFingerprint(forToken: sessionBToken)!,
                        expectedLastConnectionID: sessionBConnectionID,
                        rawSessionToken: sessionBToken
                    ),
                    reboundConnectionID: reboundConnectionID
                )
            }

            func debugSetExactRoutingSessionFixtureTargetActive(
                _ session: DebugExactRoutingSessionFixtureSession,
                active: Bool
            ) {
                let clientID = AgentProviderKind.codexMCPClientID
                if active {
                    clientIDByConnection[session.expectedLastConnectionID] = clientID
                    activeConnectionsByClient[clientID, default: []].insert(session.expectedLastConnectionID)
                } else {
                    debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: session.expectedLastConnectionID)
                }
            }

            func debugSetExactRoutingSessionFixtureTargetPending(
                _ session: DebugExactRoutingSessionFixtureSession,
                pending: Bool
            ) {
                if pending {
                    pendingConnections[session.expectedLastConnectionID] = AgentProviderKind.codexMCPClientID
                } else {
                    pendingConnections.removeValue(forKey: session.expectedLastConnectionID)
                }
            }

            func debugSetExactRoutingSessionFixtureReboundActive(
                _ fixture: DebugExactRoutingSessionFixture,
                active: Bool
            ) {
                let clientID = AgentProviderKind.codexMCPClientID
                let reboundConnectionID = fixture.reboundConnectionID
                if active {
                    debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: reboundConnectionID)
                    debugRemoveExactRoutingSessionFixtureTokenBindings(fixture.sessionA.rawSessionToken)
                    clientIDByConnection[reboundConnectionID] = clientID
                    activeConnectionsByClient[clientID, default: []].insert(reboundConnectionID)
                    capabilityTokenByConnection[reboundConnectionID] = fixture.sessionA.rawSessionToken
                    connectionIDBySessionToken[fixture.sessionA.rawSessionToken] = reboundConnectionID
                } else {
                    debugRemoveExactRoutingSessionFixtureRuntimeResidue(for: reboundConnectionID)
                    debugRemoveExactRoutingSessionFixtureTokenBindings(fixture.sessionA.rawSessionToken)
                }
            }

            func debugExactRoutingSessionFixtureState() -> DebugExactRoutingSessionFixtureState {
                var persistedRecordCountByFingerprint: [String: Int] = [:]
                var lastWindowEntryCountByFingerprint: [String: Int] = [:]
                var liveRunAffinityEntryCountByFingerprint: [String: Int] = [:]
                func increment(_ sessionToken: String?, counts: inout [String: Int]) {
                    guard let sessionToken,
                          !sessionToken.isEmpty,
                          let fingerprint = debugSessionFingerprint(forToken: sessionToken)
                    else { return }
                    counts[fingerprint, default: 0] += 1
                }
                for records in routingState.records.values {
                    for record in records {
                        increment(record.sessionKey, counts: &persistedRecordCountByFingerprint)
                    }
                }
                for sessionMap in lastWindowByClientSession.values {
                    for sessionToken in sessionMap.keys {
                        increment(sessionToken, counts: &lastWindowEntryCountByFingerprint)
                    }
                }
                for sessionMap in liveRunAffinityByClientSession.values {
                    for sessionToken in sessionMap.keys {
                        increment(sessionToken, counts: &liveRunAffinityEntryCountByFingerprint)
                    }
                }
                return DebugExactRoutingSessionFixtureState(
                    persistedRecordCountByFingerprint: persistedRecordCountByFingerprint,
                    lastWindowEntryCountByFingerprint: lastWindowEntryCountByFingerprint,
                    liveRunAffinityEntryCountByFingerprint: liveRunAffinityEntryCountByFingerprint
                )
            }

            func debugRestoreExactRoutingSessionFixture(_ fixture: DebugExactRoutingSessionFixture) -> Bool {
                guard let restorePoint = debugExactRoutingSessionRestorePoints.removeValue(forKey: fixture.restoreID) else {
                    return false
                }
                routingState = restorePoint.routingState
                lastWindowByClientSession = restorePoint.lastWindowByClientSession
                liveRunAffinityByClientSession = restorePoint.liveRunAffinityByClientSession
                pendingConnections = restorePoint.pendingConnections
                activeConnectionsByClient = restorePoint.activeConnectionsByClient
                clientIDByConnection = restorePoint.clientIDByConnection
                capabilityTokenByConnection = restorePoint.capabilityTokenByConnection
                connectionIDBySessionToken = restorePoint.connectionIDBySessionToken
                saveRoutingState()
                return debugEncodedRoutingState(routingState) == debugEncodedRoutingState(restorePoint.routingState)
                    && lastWindowByClientSession == restorePoint.lastWindowByClientSession
                    && debugLiveRunAffinitiesEqual(liveRunAffinityByClientSession, restorePoint.liveRunAffinityByClientSession)
                    && pendingConnections == restorePoint.pendingConnections
                    && activeConnectionsByClient == restorePoint.activeConnectionsByClient
                    && clientIDByConnection == restorePoint.clientIDByConnection
                    && capabilityTokenByConnection == restorePoint.capabilityTokenByConnection
                    && connectionIDBySessionToken == restorePoint.connectionIDBySessionToken
            }

            private func debugRemoveExactRoutingSessionFixtureToken(_ sessionToken: String) {
                for clientID in Array(routingState.records.keys) {
                    guard let records = routingState.records[clientID] else { continue }
                    let retainedRecords = records.filter { $0.sessionKey != sessionToken }
                    if retainedRecords.isEmpty {
                        routingState.records.removeValue(forKey: clientID)
                    } else {
                        routingState.records[clientID] = retainedRecords
                    }
                }
                for clientID in Array(lastWindowByClientSession.keys) {
                    lastWindowByClientSession[clientID]?.removeValue(forKey: sessionToken)
                    if lastWindowByClientSession[clientID]?.isEmpty == true {
                        lastWindowByClientSession.removeValue(forKey: clientID)
                    }
                }
                for clientID in Array(liveRunAffinityByClientSession.keys) {
                    liveRunAffinityByClientSession[clientID]?.removeValue(forKey: sessionToken)
                    if liveRunAffinityByClientSession[clientID]?.isEmpty == true {
                        liveRunAffinityByClientSession.removeValue(forKey: clientID)
                    }
                }
                debugRemoveExactRoutingSessionFixtureTokenBindings(sessionToken)
            }

            private func debugRemoveExactRoutingSessionFixtureTokenBindings(_ sessionToken: String) {
                connectionIDBySessionToken.removeValue(forKey: sessionToken)
                for connectionID in capabilityTokenByConnection.compactMap({ connectionID, token in
                    token == sessionToken ? connectionID : nil
                }) {
                    capabilityTokenByConnection.removeValue(forKey: connectionID)
                }
            }

            private func debugRemoveExactRoutingSessionFixtureRuntimeResidue(for connectionID: UUID) {
                pendingConnections.removeValue(forKey: connectionID)
                clientIDByConnection.removeValue(forKey: connectionID)
                capabilityTokenByConnection.removeValue(forKey: connectionID)
                for sessionToken in connectionIDBySessionToken.compactMap({ sessionToken, mappedConnectionID in
                    mappedConnectionID == connectionID ? sessionToken : nil
                }) {
                    connectionIDBySessionToken.removeValue(forKey: sessionToken)
                }
                for clientID in Array(activeConnectionsByClient.keys) {
                    activeConnectionsByClient[clientID]?.remove(connectionID)
                    if activeConnectionsByClient[clientID]?.isEmpty == true {
                        activeConnectionsByClient.removeValue(forKey: clientID)
                    }
                }
            }

            private func debugEncodedRoutingState(_ state: MCPRoutingState) -> Data? {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                return try? encoder.encode(state)
            }

            private func debugLiveRunAffinitiesEqual(
                _ lhs: [String: [String: LiveRunAffinity]],
                _ rhs: [String: [String: LiveRunAffinity]]
            ) -> Bool {
                guard Set(lhs.keys) == Set(rhs.keys) else { return false }
                for clientID in lhs.keys {
                    guard let leftSessions = lhs[clientID], let rightSessions = rhs[clientID] else { return false }
                    guard Set(leftSessions.keys) == Set(rightSessions.keys) else { return false }
                    for sessionToken in leftSessions.keys {
                        guard let left = leftSessions[sessionToken], let right = rightSessions[sessionToken] else { return false }
                        guard left.windowID == right.windowID,
                              left.runID == right.runID,
                              left.purpose == right.purpose,
                              left.lastSeenAt == right.lastSeenAt
                        else { return false }
                    }
                }
                return true
            }

            func debugSeedRoutingAffinityPayload(connectionID: UUID, windowID: Int) async -> [String: Any] {
                let exists = await MainActor.run { WindowStatesManager.shared.hasWindow(id: windowID) }
                guard exists else {
                    return ["ok": false, "op": "seed_routing_affinity", "code": "invalid_params", "error": "No window found for window_id \(windowID)."]
                }
                guard connections[connectionID] != nil else {
                    return ["ok": false, "op": "seed_routing_affinity", "code": "invalid_params", "error": "connection_id is not an active connection."]
                }
                setConnectionWindowMapping(connectionID, windowID: windowID)
                let clientID = clientIdentifier(forConnection: connectionID)
                let sessionPresent = sessionToken(for: connectionID) != nil
                let didPersist = clientID != nil && sessionPresent
                if let clientID {
                    await updateRoutingRecordForConnection(connectionID, clientID: clientID)
                }
                return [
                    "ok": true,
                    "op": "seed_routing_affinity",
                    "connection_id": connectionID.uuidString,
                    "window_id": windowID,
                    "session_fingerprint": debugSessionFingerprint(forConnection: connectionID) ?? NSNull(),
                    "client_name": clientID ?? NSNull(),
                    "persisted": didPersist,
                    "persist_reason": didPersist ? "updated" : (sessionPresent ? "missing_client_id" : "missing_session_key")
                ]
            }

            private func debugSetRestartStatus(_ restartID: UUID, state: String, error: String? = nil) {
                debugRestartStatesByID[restartID] = DebugRestartStatus(
                    restartID: restartID,
                    state: state,
                    lastError: error,
                    updatedAt: Date()
                )
                if debugRestartStatesByID.count > debugRestartStatusLimit {
                    let oldest = debugRestartStatesByID.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(debugRestartStatesByID.count - debugRestartStatusLimit).map(\.restartID)
                    for id in oldest {
                        debugRestartStatesByID.removeValue(forKey: id)
                    }
                }
            }

            func debugScheduleShutdownAndRestartPayload(restartID: UUID, delayMS: Int, downMS: Int, mode: String) -> [String: Any] {
                debugSetRestartStatus(restartID, state: "scheduled")
                debugRecordConnectionEvent("restart_scheduled", restartID: restartID, reason: mode)
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .milliseconds(delayMS))
                    await debugSetRestartStatus(restartID, state: "stopping")
                    await debugRecordConnectionEvent("restart_stop_begin", restartID: restartID, reason: mode)
                    await stop()
                    await debugSetRestartStatus(restartID, state: "down")
                    await debugRecordConnectionEvent("restart_stop_end", restartID: restartID, reason: mode)
                    if downMS > 0 {
                        try? await Task.sleep(for: .milliseconds(downMS))
                    }
                    await debugSetRestartStatus(restartID, state: "starting")
                    await debugRecordConnectionEvent("restart_start_begin", restartID: restartID, reason: mode)
                    await start()
                    try? await Task.sleep(for: .milliseconds(100))
                    await ensureBootstrapHealthy(force: true)
                    await debugSetRestartStatus(restartID, state: "completed")
                    await debugRecordConnectionEvent("restart_start_end", restartID: restartID, reason: mode)
                }
                return [
                    "ok": true,
                    "op": "shutdown_and_restart",
                    "scheduled": true,
                    "restart_id": restartID.uuidString,
                    "mode": mode,
                    "delay_ms": delayMS,
                    "down_ms": downMS,
                    "socket_path": resolvedBootstrapSocketURL().path,
                    "scheduled_at_ms": debugDateMilliseconds(Date())
                ]
            }

            func debugRestartStatusPayload(restartID: UUID?) -> [String: Any] {
                let status: DebugRestartStatus? = if let restartID {
                    debugRestartStatesByID[restartID]
                } else {
                    debugRestartStatesByID.values.sorted { $0.updatedAt > $1.updatedAt }.first
                }
                return [
                    "ok": true,
                    "op": "restart_status",
                    "restart_id": status?.restartID.uuidString ?? restartID?.uuidString ?? NSNull(),
                    "state": status?.state ?? "none",
                    "last_error": status?.lastError ?? NSNull(),
                    "updated_at_ms": status.map { debugDateMilliseconds($0.updatedAt) } ?? NSNull()
                ]
            }
        #endif

        func debugClearPersistedRoutingState() {
            routingState.records.removeAll()
            lastWindowByClientSession.removeAll()
            saveRoutingState()
        }

        func debugClearPersistedRoutingState(for clientName: String) {
            for key in matchingClientKeys(for: clientName, in: Array(routingState.records.keys)) {
                routingState.records.removeValue(forKey: key)
            }
            for key in matchingClientKeys(for: clientName, in: Array(lastWindowByClientSession.keys)) {
                lastWindowByClientSession.removeValue(forKey: key)
            }
            for key in matchingClientKeys(for: clientName, in: Array(liveRunAffinityByClientSession.keys)) {
                liveRunAffinityByClientSession.removeValue(forKey: key)
            }
            saveRoutingState()
        }

        func debugRemoveConnection(_ id: UUID) async {
            await removeConnection(id)
        }

        func debugMarkActiveToolOwner(windowID: Int, connectionID: UUID, toolName: String) {
            markActiveToolOwner(windowID: windowID, connectionID: connectionID, toolName: toolName)
        }

        func debugCancelActiveToolsOwnedByConnection(
            _ connectionID: UUID,
            assignedWindowID: Int? = nil,
            reason: String = "test"
        ) async -> Int {
            _ = assignedWindowID
            return await cancelActiveToolsOwnedByConnection(
                connectionID,
                reason: reason
            )
        }

        func debugSetAdditionalTools(for connectionID: UUID, additionalTools: Set<String>?) async {
            if let additionalTools {
                additionalToolsByConnection[connectionID] = additionalTools
            } else {
                additionalToolsByConnection.removeValue(forKey: connectionID)
            }
            if connections[connectionID] != nil {
                await notifyToolListChanged(connectionID: connectionID)
            }
        }

        func debugListToolNames(
            for connectionID: UUID,
            hydratePersistedPolicy: Bool = true
        ) async throws -> [String] {
            let windowID = await ensureWindowBindingIfUnambiguous(connectionID: connectionID, reason: "debug/tools/list")
            let isReady = await MCPToolCatalogReadiness.shared.awaitReady(
                windowID: windowID,
                timeout: 5.0
            )
            if !isReady, windowID != nil {
                throw MCPError.internalError("Tool catalog not ready. Please retry.")
            }
            if let windowID {
                await MCPToolCatalogReadiness.shared.warmToolCache(windowID: windowID)
            }

            if hydratePersistedPolicy {
                _ = await hydratePersistedAgentModePolicyForConnectionIfNeeded(
                    connectionID: connectionID,
                    reason: "debug/tools/list"
                )
            }

            let (disabled, registeredServices) = await MainActor.run {
                (
                    ToolAvailabilityStore.shared.effectiveDisabledTools,
                    ServiceRegistry.services
                )
            }
            let policy = effectivePolicyState(for: connectionID)
            let restricted = policy.restricted
            let additionalTools = policy.additional
            var seenNames = Set<String>()
            var names: [String] = []

            if isEnabledState {
                for service in registeredServices {
                    for tool in await service.tools {
                        guard !disabled.contains(tool.name) else { continue }
                        guard !restricted.contains(tool.name) else { continue }

                        if MCPPolicyGatedTools.names.contains(tool.name),
                           !additionalTools.contains(tool.name)
                        {
                            continue
                        }

                        if !AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                            toolName: tool.name,
                            taskLabelKind: policy.taskLabelKind,
                            allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools
                        ) { continue }

                        guard seenNames.insert(tool.name).inserted else { continue }
                        names.append(tool.name)
                    }
                }
            }

            return names.sorted()
        }

        @discardableResult
        func debugFireToolCalledObservers(
            runID: UUID,
            invocationID: UUID,
            toolName: String,
            args: [String: Value]? = nil
        ) async -> Int {
            await fireToolCalledObservers(
                runID: runID,
                invocationID: invocationID,
                toolName: toolName,
                args: args
            )
        }

        @discardableResult
        func debugFireToolCompletedObservers(
            runID: UUID,
            invocationID: UUID,
            toolName: String,
            args: [String: Value]? = nil,
            resultJSON: String,
            isError: Bool
        ) async -> Int {
            await fireToolCompletedObservers(
                runID: runID,
                invocationID: invocationID,
                toolName: toolName,
                args: args,
                resultJSON: resultJSON,
                isError: isError
            )
        }

        func debugClearActiveToolOwner(windowID: Int) {
            if let owner = activeToolOwnerByWindow[windowID] {
                clearActiveToolOwner(windowID: windowID, connectionID: owner)
            } else {
                activeToolNameByWindow.removeValue(forKey: windowID)
            }
        }
    #endif

    func clearClientConnectionPolicy(
        for clientName: String,
        windowID: Int? = nil,
        runID: UUID? = nil
    ) async {
        pruneExpiredPolicies(for: clientName)
        let keys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        guard !keys.isEmpty else { return }
        var removedCount = 0
        var remainingCount = 0
        for key in keys {
            guard var queue = pendingPoliciesByClient[key] else { continue }
            let beforeCount = queue.count
            if let targetRunID = runID, let targetWindow = windowID {
                queue.removeAll { $0.windowID == targetWindow && $0.runID == targetRunID }
            } else if let targetRunID = runID {
                queue.removeAll { $0.runID == targetRunID }
            } else if let targetWindow = windowID {
                queue.removeAll { $0.windowID == targetWindow }
            } else {
                queue.removeAll()
            }
            removedCount += beforeCount - queue.count
            remainingCount += queue.count
            if queue.isEmpty {
                pendingPoliciesByClient.removeValue(forKey: key)
            } else {
                pendingPoliciesByClient[key] = queue
            }
        }
        mcpPolicyLog(
            "cleared policy client=\(clientName) window=\(windowID.map(String.init) ?? "all") runID=\(runID?.uuidString ?? "all") removed=\(removedCount) remaining=\(remainingCount)"
        )
    }

    func setRestrictedTools(for connectionID: UUID, tools: Set<String>) async {
        let sanitized = Self.sanitizedRoutingRestrictedTools(tools)
        restrictedToolsByConnection[connectionID] = sanitized
        if connections[connectionID] != nil {
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    func addRestrictedTools(for connectionID: UUID, names: [String]) async {
        let sanitized = Self.sanitizedRoutingRestrictedTools(Set(names))
        guard !sanitized.isEmpty else { return }
        var existing = restrictedToolsByConnection[connectionID] ?? []
        existing.formUnion(sanitized)
        restrictedToolsByConnection[connectionID] = existing
        if connections[connectionID] != nil {
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    func clearRestrictedTools(for connectionID: UUID) async {
        if restrictedToolsByConnection.removeValue(forKey: connectionID) != nil,
           connections[connectionID] != nil
        {
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    func notifyToolListChanged(connectionID: UUID) async {
        if let mgr = connections[connectionID] {
            await mgr.notifyToolListChanged()
        }
    }

    /// Sends a progress notification to a specific connection.
    /// Used during long-running tool calls to prevent agent timeouts.
    func sendProgress(
        for connectionID: UUID,
        tool: String,
        kind: RepoPromptProgressKind,
        stage: String,
        message: String
    ) async {
        guard supportsControlNotifications(connectionID: connectionID) else { return }
        #if DEBUG
            let clientName = clientIdentifier(forConnection: connectionID) ?? "unknown"
            connectionLog("progress client=\(clientName) connection=\(connectionID) tool=\(tool) kind=\(kind.rawValue) stage=\(stage) message=\(message)")
        #endif
        if let mgr = connections[connectionID] {
            await mgr.sendProgress(tool: tool, kind: kind, stage: stage, message: message)
        }
    }

    /// RepoPrompt control notifications are only supported by the bundled CLI.
    func supportsControlNotifications(connectionID: UUID) -> Bool {
        guard let clientName = clientIdentifier(forConnection: connectionID) else { return false }
        return clientName.hasPrefix(Self.repoCLIPrefix)
    }

    private func pruneExpiredPolicies(for clientName: String) {
        let keys = matchingClientKeys(for: clientName, in: Array(pendingPoliciesByClient.keys))
        let now = Date()
        for key in keys {
            guard var queue = pendingPoliciesByClient[key], !queue.isEmpty else { continue }
            queue.removeAll { now.timeIntervalSince($0.createdAt) > $0.ttl }
            if queue.isEmpty {
                pendingPoliciesByClient.removeValue(forKey: key)
            } else {
                pendingPoliciesByClient[key] = queue
            }
        }
    }

    @discardableResult
    private func hydratePersistedAgentModePolicyForConnectionIfNeeded(
        connectionID: UUID,
        reason: String
    ) async -> Bool {
        let existingRestricted = restrictedToolsByConnection[connectionID] ?? []
        let existingAdditional = additionalToolsByConnection[connectionID] ?? []
        let existingPurpose = runPurposeByConnection[connectionID] ?? .unknown
        if !existingRestricted.isEmpty || !existingAdditional.isEmpty || existingPurpose != .unknown {
            return false
        }

        guard let clientName = clientIdentifier(forConnection: connectionID) else { return false }
        let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
        if let liveAffinity = preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) {
            guard shouldAllowPersistedAgentModeRestore(clientName: clientName, purpose: liveAffinity.purpose) else {
                return false
            }
            setConnectionWindowMapping(connectionID, windowID: liveAffinity.windowID)
            let restored = await mapConnectionToRunID(
                connectionID,
                runID: liveAffinity.runID,
                windowID: liveAffinity.windowID
            )
            if restored {
                await updateRoutingRecordForConnection(connectionID, clientID: clientName)
                await notifyToolListChanged(connectionID: connectionID)
                mcpPolicyLog(
                    "hydrated live run affinity reason=\(reason) client=\(clientName) connection=\(connectionID) window=\(liveAffinity.windowID) runID=\(liveAffinity.runID.uuidString)"
                )
            }
            return restored
        }

        if let preferredWindowID = await preferredWindowID(for: clientName, sessionKey: sessionKey) {
            setConnectionWindowMapping(connectionID, windowID: preferredWindowID)
            await updateRoutingRecordForConnection(connectionID, clientID: clientName)
        }
        return false
    }

    private func applyLiveRunAffinity(
        _ liveAffinity: LiveRunAffinity,
        clientName: String,
        connectionID: UUID,
        reason: String
    ) async {
        connectionLog("Applying live run affinity (\(reason)): client \(clientName) → window \(liveAffinity.windowID) runID=\(liveAffinity.runID)")
        setConnectionWindowMapping(connectionID, windowID: liveAffinity.windowID)
        let mapped = await mapConnectionToRunID(
            connectionID,
            runID: liveAffinity.runID,
            windowID: liveAffinity.windowID
        )
        if !mapped {
            await applyRunPolicyStateIfAvailable(runID: liveAffinity.runID, connectionID: connectionID)
        }
        await updateRoutingRecordForConnection(connectionID, clientID: clientName)
        await notifyToolListChanged(connectionID: connectionID)
    }

    private func applyRoutingFallback(
        clientName: String,
        connectionID: UUID,
        clientPid: Int? = nil,
        pendingPolicyWasReserved: Bool = false
    ) async {
        if pendingPolicyWasReserved {
            mcpPolicyLog("pending policy reserved for different pid client=\(clientName) connection=\(connectionID)")
        } else {
            mcpRoutingLog("No pending policy for client=\(clientName) connectionID=\(connectionID)")
            mcpPolicyLog("no pending policy client=\(clientName) connection=\(connectionID)")
        }

        let sessionKey = connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID]
        if let liveAffinity = preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) {
            await applyLiveRunAffinity(liveAffinity, clientName: clientName, connectionID: connectionID, reason: "session-token")
            return
        }

        if let liveAffinity = preferredExpectedPIDRunAffinity(for: clientName, clientPid: clientPid) {
            await applyLiveRunAffinity(liveAffinity, clientName: clientName, connectionID: connectionID, reason: "expected-pid")
            return
        }

        if let preferredWindowID = await preferredWindowID(for: clientName, sessionKey: sessionKey) {
            connectionLog("Applying persisted routing affinity: client \(clientName) → window \(preferredWindowID)")
            setConnectionWindowMapping(connectionID, windowID: preferredWindowID)
            await updateRoutingRecordForConnection(connectionID, clientID: clientName)
            await notifyToolListChanged(connectionID: connectionID)
        }
    }

    private func canConsumePendingPolicy(
        _ policy: ClientConnectionPolicy,
        clientName: String,
        clientPid: Int?
    ) -> Bool {
        guard policy.requiresExpectedAgentPID else { return true }
        guard let clientPid else { return false }
        return isExpectedAgentDescendant(clientName: clientName, clientPid: clientPid, runID: policy.runID) == true
    }

    private func logReservedPendingPolicy(
        _ policy: ClientConnectionPolicy,
        clientName: String,
        connectionID: UUID,
        clientPid: Int?,
        bootstrapClientName: String?
    ) {
        mcpPolicyLog(
            "reserved pid-gated policy client=\(clientName) bootstrapClient=\(bootstrapClientName ?? "nil") connection=\(connectionID) clientPid=\(clientPid.map(String.init) ?? "nil") runID=\(policy.runID?.uuidString ?? "nil")"
        )
    }

    private func applyPendingPolicyIfAvailable(
        clientName: String,
        connectionID: UUID,
        clientPid: Int? = nil,
        bootstrapClientName: String? = nil
    ) async {
        let matchedQueueEntry = oldestPendingPolicyEntry(for: clientName) { policy in
            canConsumePendingPolicy(policy, clientName: clientName, clientPid: clientPid)
        }
        guard let matchedQueueEntry else {
            #if DEBUG
                debugPolicyDiagnostic("pendingPolicyMiss", connectionID: connectionID, extra: [
                    "clientName": clientName,
                    "clientPid": clientPid.map(String.init) ?? "nil",
                    "bootstrapClientName": bootstrapClientName ?? "nil",
                    "reason": oldestPendingPolicyEntry(for: clientName) == nil ? "no_pending_policy" : "pending_policy_not_consumable"
                ])
            #endif
            if let reservedEntry = oldestPendingPolicyEntry(for: clientName) {
                logReservedPendingPolicy(
                    reservedEntry.policy,
                    clientName: clientName,
                    connectionID: connectionID,
                    clientPid: clientPid,
                    bootstrapClientName: bootstrapClientName
                )
                await applyRoutingFallback(clientName: clientName, connectionID: connectionID, clientPid: clientPid, pendingPolicyWasReserved: true)
            } else {
                await applyRoutingFallback(clientName: clientName, connectionID: connectionID, clientPid: clientPid)
            }
            return
        }
        var queue = pendingPoliciesByClient[matchedQueueEntry.key] ?? []
        mcpRoutingLog("Applying FIFO policy client=\(clientName) matchedKey=\(matchedQueueEntry.key) connectionID=\(connectionID) queueLength=\(queue.count) policyWindow=\(matchedQueueEntry.policy.windowID)")
        let policy = queue.remove(at: matchedQueueEntry.index)
        let remainingAfterPop = queue.count
        if !policy.oneShot {
            queue.append(policy)
        }
        let remainingAfterRequeue = queue.count
        if queue.isEmpty {
            pendingPoliciesByClient.removeValue(forKey: matchedQueueEntry.key)
        } else {
            pendingPoliciesByClient[matchedQueueEntry.key] = queue
        }

        let grantDescription = Self.describeGrantedTools(restricted: policy.restrictedTools)
        let restrictedDescription = Self.describeToolList(policy.restrictedTools)
        connectionLog(
            "Applying connection policy to \(connectionID) client=\(clientName) window=\(policy.windowID) grants=\(grantDescription) restricted=\(restrictedDescription) reason=\(policy.reason ?? "-") tabID=\(policy.tabID?.uuidString ?? "nil") runID=\(policy.runID?.uuidString ?? "nil")"
        )
        mcpPolicyLog(
            "applied policy client=\(clientName) matchedKey=\(matchedQueueEntry.key) connection=\(connectionID) window=\(policy.windowID) purpose=\(policy.purpose.rawValue) oneShot=\(policy.oneShot) runID=\(policy.runID?.uuidString ?? "nil") tabID=\(policy.tabID?.uuidString ?? "nil") queueAfterPop=\(remainingAfterPop) queueAfterStore=\(remainingAfterRequeue)"
        )
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.policy.pendingPolicyApplied", fields: [
                "connectionID": connectionID.uuidString,
                "clientName": clientName,
                "clientPid": clientPid.map(String.init) ?? "nil",
                "bootstrapClientName": bootstrapClientName ?? "nil",
                "matchedKey": matchedQueueEntry.key,
                "windowID": String(policy.windowID),
                "tabID": policy.tabID?.uuidString ?? "nil",
                "runID": policy.runID?.uuidString ?? "nil",
                "purpose": policy.purpose.rawValue,
                "taskLabel": policy.taskLabelKind?.rawValue ?? "nil",
                "additionalTools": Self.debugDescribeToolSet(policy.additionalTools ?? []),
                "restrictedTools": Self.debugDescribeToolSet(policy.restrictedTools),
                "allowsAgentExternalControlTools": String(policy.allowsAgentExternalControlTools),
                "requiresExpectedAgentPID": String(policy.requiresExpectedAgentPID),
                "queueAfterPop": String(remainingAfterPop),
                "queueAfterStore": String(remainingAfterRequeue)
            ])
        #endif
        restrictedToolsByConnection[connectionID] = policy.restrictedTools
        preassignedConnections.insert(connectionID)

        // Install run purpose/cache first so persisted routing snapshots capture purpose.
        runPurposeByConnection[connectionID] = policy.purpose
        cacheRunPolicyStateIfNeeded(policy)
        if let runID = policy.runID {
            admittedPolicyRunIDs.insert(runID)
            runIDByConnectionID[connectionID] = runID
            updateLiveRunAffinity(
                clientName: clientName,
                sessionKey: connections[connectionID]?.capabilityToken ?? capabilityTokenByConnection[connectionID],
                runID: runID,
                windowID: policy.windowID,
                purpose: policy.purpose
            )
        }

        // Install additional tools (policy-gated tools like ask_user)
        if let additional = policy.additionalTools {
            additionalToolsByConnection[connectionID] = additional
        } else {
            additionalToolsByConnection.removeValue(forKey: connectionID)
        }

        setConnectionWindowMapping(connectionID, windowID: policy.windowID)
        mcpRoutingLog("Set window mapping connectionID=\(connectionID) → window=\(policy.windowID)")

        // If policy includes tab context, install it directly
        if let tabID = policy.tabID, let runID = policy.runID {
            mcpRoutingLog("Policy includes tab context - installing for tab=\(tabID) run=\(runID)")
            // Note: runID mapping is stored in MCPServerViewModel.connectionIDToRunID by installTabContext
            await installTabContextFromPolicy(
                clientID: connectionID.uuidString,
                clientName: clientName,
                windowID: policy.windowID,
                tabID: tabID,
                runID: runID
            )
        }

        await updateRoutingRecordForConnection(connectionID, clientID: clientName)
        await notifyToolListChanged(connectionID: connectionID)
    }

    /// Install tab context from a connection policy (for Context Builder agents)
    private func installTabContextFromPolicy(
        clientID: String,
        clientName: String,
        windowID: Int,
        tabID: UUID,
        runID: UUID
    ) async {
        let resolved = await MainActor.run { () -> (workspaceID: UUID, snapshot: ComposeTabState)? in
            guard let windowState = WindowStatesManager.shared.window(withID: windowID) else {
                return nil
            }
            guard let resolved = windowState.workspaceManager.resolveComposeTabRoutingSnapshot(for: tabID) else {
                return nil
            }
            windowState.mcpServer.installTabContext(
                clientID: clientID,
                clientName: clientName,
                windowID: windowID,
                workspaceID: resolved.workspaceID,
                snapshot: resolved.snapshot,
                runID: runID
            )
            return (resolved.workspaceID, resolved.snapshot)
        }

        guard let resolved else {
            log.warning("installTabContextFromPolicy: tab \(tabID) could not resolve routing snapshot in window \(windowID)")
            return
        }

        if let cached = runPolicyStateByRunID[runID] {
            seedRunPolicyState(
                runID: runID,
                windowID: windowID,
                workspaceID: resolved.workspaceID,
                tabID: resolved.snapshot.id,
                restrictedTools: cached.restrictedTools,
                additionalTools: cached.additionalTools,
                purpose: cached.purpose,
                taskLabelKind: cached.taskLabelKind,
                allowsAgentExternalControlTools: cached.allowsAgentExternalControlTools,
                updatedAt: Date()
            )
        }
        connectionLog("Installed tab context from policy: tab=\(tabID) run=\(runID) window=\(windowID) workspace=\(resolved.workspaceID) client=\(clientName)")
    }

    @discardableResult
    private func ensureTabBoundForRunIfPossible(
        connectionID: UUID,
        clientName: String?,
        runID: UUID,
        windowID: Int
    ) async -> Bool {
        guard
            let cached = runPolicyStateByRunID[runID],
            let tabID = cached.tabID
        else {
            return false
        }
        let resolvedClientName = clientName ?? clientIdentifier(forConnection: connectionID)
        do {
            let bindingResult = try await MainActor.run { () throws -> (didBind: Bool, workspaceID: UUID?) in
                guard let windowState = WindowStatesManager.shared.window(withID: windowID) else {
                    throw MCPError.invalidParams("Window \(windowID) not found")
                }
                // Fast path: already bound to this exact tab+run in this window.
                let alreadyBoundTab = windowState.mcpServer.boundTabID(forConnection: connectionID) == tabID
                let alreadyBoundRun = windowState.mcpServer.connectionIDToRunID[connectionID] == runID
                if alreadyBoundTab, alreadyBoundRun {
                    return (false, cached.workspaceID)
                }
                let resolvedWorkspaceID = cached.workspaceID ?? windowState.workspaceManager.resolveComposeTabRoutingSnapshot(for: tabID)?.workspaceID
                guard let workspaceID = resolvedWorkspaceID else {
                    throw MCPError.invalidParams("Tab \(tabID) not found in any workspace for window \(windowID)")
                }
                try windowState.mcpServer.bindTabForConnection(
                    connectionID: connectionID,
                    clientName: resolvedClientName,
                    tabID: tabID,
                    workspaceID: workspaceID,
                    windowID: windowID,
                    runID: runID,
                    explicitlyBound: false
                )
                return (true, workspaceID)
            }
            if let workspaceID = bindingResult.workspaceID, workspaceID != cached.workspaceID {
                seedRunPolicyState(
                    runID: runID,
                    windowID: cached.windowID,
                    workspaceID: workspaceID,
                    tabID: cached.tabID,
                    restrictedTools: cached.restrictedTools,
                    additionalTools: cached.additionalTools,
                    purpose: cached.purpose,
                    taskLabelKind: cached.taskLabelKind,
                    allowsAgentExternalControlTools: cached.allowsAgentExternalControlTools,
                    updatedAt: Date()
                )
            }
            if bindingResult.didBind {
                connectionLog("Tab binding: rebound connection \(connectionID) to cached run tab \(tabID) for run \(runID) in window \(windowID)")
            }
            return true
        } catch {
            log.warning("ensureTabBoundForRunIfPossible: failed run=\(runID) tab=\(tabID) window=\(windowID) connection=\(connectionID) error=\(error.localizedDescription)")
            return false
        }
    }

    func registerHandlers(for server: MCP.Server, connectionID: UUID) async {
        // ------------------------------------------------------------------
        //  prompts/list
        // ------------------------------------------------------------------
        await server.withMethodHandler(ListPrompts.self) { _ in
            connectionLog("Handling ListPrompts request for \(connectionID)")
            return ListPrompts.Result(prompts: MCPPromptRegistry.listPrompts())
        }

        // ------------------------------------------------------------------
        //  prompts/get
        // ------------------------------------------------------------------
        await server.withMethodHandler(GetPrompt.self) { params in
            connectionLog("Handling GetPrompt request name=\(params.name) for \(connectionID)")
            let promptArguments = params.arguments?.mapValues { Value.string($0) }
            return try MCPPromptRegistry.getPrompt(named: params.name, arguments: promptArguments)
        }

        // ------------------------------------------------------------------
        //  resources/list
        // ------------------------------------------------------------------
        await server.withMethodHandler(ListResources.self) { _ in
            connectionLog("Handling ListResources request for \(connectionID)")
            return ListResources.Result(
                resources: [
                    Resource(
                        name: "RepoPrompt Instructions",
                        uri: "repoprompt://instructions",
                        description: "Usage instructions for RepoPrompt MCP tools - read this to understand how to effectively use the available tools",
                        mimeType: "text/plain"
                    )
                ],
                nextCursor: nil
            )
        }

        // ------------------------------------------------------------------
        //  resources/templates/list
        // ------------------------------------------------------------------
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            connectionLog("Handling ListResourceTemplates request for \(connectionID)")
            return ListResourceTemplates.Result(templates: [], nextCursor: nil)
        }

        // ------------------------------------------------------------------
        //  resources/read
        // ------------------------------------------------------------------
        await server.withMethodHandler(ReadResource.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("Server unavailable") }
            connectionLog("Handling ReadResource request for \(connectionID), uri=\(params.uri)")

            switch params.uri {
            case "repoprompt://instructions":
                let hydratedPolicy = await hydratePersistedAgentModePolicyForConnectionIfNeeded(
                    connectionID: connectionID,
                    reason: "resources/read-instructions"
                )
                let purpose = await effectivePolicyState(for: connectionID).purpose
                if hydratedPolicy {
                    mcpPolicyLog("hydrated policy before resources/read instructions connection=\(connectionID) purpose=\(purpose.rawValue)")
                }
                let codeMapsDisabled = await MainActor.run { GlobalSettingsStore.shared.globalCodeMapsDisabled() }
                return ReadResource.Result(
                    contents: [
                        .text(RepoPromptMCPInstructions.text(for: purpose, codeMapsDisabled: codeMapsDisabled), uri: params.uri, mimeType: "text/plain")
                    ]
                )
            default:
                throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
            }
        }

        // ------------------------------------------------------------------
        //  tools/list  (UPDATED)
        // ------------------------------------------------------------------
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { return ListTools.Result(tools: []) }

            connectionLog("Handling ListTools request for \(connectionID)")

            // Safety net: ensure tool catalog is ready before returning list.
            // The primary readiness wait happens during handshake, but this catches edge cases.
            // Use ensureWindowBindingIfUnambiguous to treat nil as single-window fallback,
            // preventing failures for clients that call tools/list before explicit window selection.
            let windowID = await ensureWindowBindingIfUnambiguous(connectionID: connectionID, reason: "tools/list")
            let isReady = await MCPToolCatalogReadiness.shared.awaitReady(
                windowID: windowID,
                timeout: 2.0 // Shorter timeout here since handshake should have waited
            )
            if !isReady {
                // Only fail closed if we had a specific window to wait for.
                // If windowID is nil (true multi-window ambiguity), log warning but proceed
                // with whatever tools are available - the client will need to select a window.
                if windowID != nil {
                    log.warning("Tool catalog not ready for tools/list - failing closed for connection \(connectionID) window \(windowID!)")
                    throw MCPError.internalError("Tool catalog not ready. Please retry.")
                } else {
                    connectionLog("Tool catalog readiness skipped for multi-window ambiguous connection \(connectionID)")
                }
            }

            // Warm tool cache if we have a bound window
            if let windowID {
                await MCPToolCatalogReadiness.shared.warmToolCache(windowID: windowID)
            }

            // Opportunistic persisted hydration for resumed agent-mode sessions.
            // Persisted routing metadata may restore window/run mapping, and cached
            // run policy (if available) can restore gated tool visibility.
            _ = await hydratePersistedAgentModePolicyForConnectionIfNeeded(
                connectionID: connectionID,
                reason: "tools/list"
            )

            // Get all MainActor-isolated data in one hop
            let (disabled, registeredServices) = await MainActor.run {
                (
                    ToolAvailabilityStore.shared.effectiveDisabledTools,
                    ServiceRegistry.services
                )
            }
            let policy = await effectivePolicyState(for: connectionID)
            let restricted = policy.restricted
            let additionalTools = policy.additional
            #if DEBUG
                var hiddenToolReasons: [String: Int] = [:]
                var hiddenToolSamples: [String] = []
                func recordHiddenTool(_ toolName: String, reason: String) {
                    hiddenToolReasons[reason, default: 0] += 1
                    guard hiddenToolSamples.count < 20 else { return }
                    hiddenToolSamples.append("\(toolName):\(reason)")
                }
            #endif

            var seenNames = Set<String>() // ✱ 2. Deduplication helper
            var tools: [MCP.Tool] = []

            // Only proceed when the global MCP switch is ON
            if await isEnabledState {
                // Enumerate every registered Service
                for service in registeredServices {
                    // Walk through the service's declared tools
                    for tool in await service.tools {
                        if disabled.contains(tool.name) {
                            #if DEBUG
                                recordHiddenTool(tool.name, reason: "disabled")
                            #endif
                            continue
                        }
                        if restricted.contains(tool.name) {
                            #if DEBUG
                                recordHiddenTool(tool.name, reason: "restricted")
                            #endif
                            continue
                        }

                        // • hide policy-gated tools unless explicitly granted via additionalTools
                        if MCPPolicyGatedTools.names.contains(tool.name),
                           !additionalTools.contains(tool.name)
                        {
                            #if DEBUG
                                recordHiddenTool(tool.name, reason: "missing_additional_tool_grant")
                            #endif
                            continue
                        }

                        // • role-based advertisement filtering (advertisement-only, not execution-time)
                        if !AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                            toolName: tool.name,
                            taskLabelKind: policy.taskLabelKind,
                            allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools
                        ) {
                            #if DEBUG
                                recordHiddenTool(tool.name, reason: "role_advertisement_policy")
                            #endif
                            continue
                        }

                        // • skip duplicates coming from other windows
                        guard seenNames.insert(tool.name).inserted else { continue }

                        // OK – advertise the tool
                        let schemaValue = try await cachedSchema(
                            for: tool.name,
                            schema: tool.inputSchema,
                            purpose: policy.purpose
                        )
                        let description = advertisedToolDescription(
                            for: tool.name,
                            baseDescription: tool.description,
                            purpose: policy.purpose
                        )

                        tools.append(
                            .init(
                                name: tool.name,
                                description: description,
                                inputSchema: schemaValue,
                                annotations: tool.annotations
                            )
                        )
                    }
                }
            }

            #if DEBUG
                await debugPolicyDiagnostic("toolsList", connectionID: connectionID, policy: policy, extra: [
                    "advertisedToolCount": String(tools.count),
                    "hiddenReasons": hiddenToolReasons.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","),
                    "hiddenSamples": hiddenToolSamples.joined(separator: ",")
                ])
            #endif
            connectionLog("Returning \(tools.count) available tools for \(connectionID)")
            return ListTools.Result(tools: tools)
        }

        // ------------------------------------------------------------------
        //  tools/call  (UPDATED)
        // ------------------------------------------------------------------
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return CallTool.Result(
                    content: [MCP.Tool.Content.text(text: "Server unavailable", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            let originalName = params.name
            let toolName = Self.canonicalToolName(for: originalName)
            connectionLog("tools/call received original=\(originalName) canonical=\(toolName) connection=\(connectionID)")
            #if DEBUG
                await debugPolicyDiagnostic("toolsCallReceived", connectionID: connectionID, extra: [
                    "toolName": toolName,
                    "originalName": originalName
                ])
                if Self.isDebugDiagnosticsToolName(toolName) {
                    let limiter = await self.limiter(for: connectionID)
                    return await limiter.withPermit {
                        await self.handleDebugDiagnosticsTool(
                            connectionID: connectionID,
                            arguments: params.arguments ?? [:]
                        )
                    }
                }
            #endif
            // CE exposes all MCP tools that are registered for the current connection.
            // Avoid calling the MainActor-backed ToolAvailabilityStore from this hot path;
            // it can block tool responses while settings/UI work is in flight.
            connectionLog("tools/call \(toolName): tool availability gate skipped for CE")
            let totalState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.total,
                EditFlowPerf.Dimensions(toolName: toolName)
            )
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.total, totalState) }
            let preLimiterEnvelopeState = EditFlowPerf.begin(
                EditFlowPerf.Stage.MCPToolCall.preLimiterEnvelope,
                EditFlowPerf.Dimensions(toolName: toolName)
            )
            var didEndPreLimiterEnvelope = false
            func endPreLimiterEnvelopeIfNeeded() {
                guard !didEndPreLimiterEnvelope else { return }
                didEndPreLimiterEnvelope = true
                EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.preLimiterEnvelope, preLimiterEnvelopeState)
            }
            defer { endPreLimiterEnvelopeIfNeeded() }

            // Normalize arguments using shared module
            connectionLog("tools/call \(toolName): normalizing args")
            let normalized = EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.normalizeArgs,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                MCPToolArgsNormalizer.normalize(
                    params: params.arguments,
                    originalToolName: originalName,
                    canonicalToolName: toolName
                )
            }

            // Log any warnings from normalization
            for warning in normalized.warnings {
                connectionLog("Argument normalization: \(warning)")
            }

            let extractedTabID = normalized.tabID
            let extractedWindowID = normalized.windowID
            let extractedContextID = normalized.contextID
            let extractedWorkingDirs = normalized.workingDirs
            let extractedRawJSON = normalized.rawJSON
            let cleanedArguments = normalized.payload
            let capturedRawJSON = extractedRawJSON
            connectionLog("tools/call \(toolName): args normalized keys=\(cleanedArguments.keys.sorted().joined(separator: ","))")

            // tools/list already performs any needed persisted routing hydration.
            // Do not repeat it on each tools/call; it can re-enter routing notifications
            // while the call is waiting for a response.

            var dispatchTabContextHint: MCPServerViewModel.TabContextHint? = nil
            var preResolvedWindowID: Int? = nil
            do {
                let logicalContextState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPToolCall.logicalContextResolution,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.logicalContextResolution, logicalContextState) }
                if !Self.shouldBypassLogicalContextPreResolution(for: toolName) {
                    do {
                        if let logicalBinding = try await bindingResolver.resolveLogicalContextBinding(
                            connectionID: connectionID,
                            explicitContextID: extractedContextID,
                            legacyTabID: extractedTabID,
                            workingDirs: [],
                            requestedWindowID: extractedWindowID
                        ) {
                            dispatchTabContextHint = MCPServerViewModel.TabContextHint(
                                tabID: logicalBinding.logicalContext.tabID,
                                workspaceID: logicalBinding.logicalContext.workspaceID,
                                windowID: logicalBinding.windowID
                            )
                            preResolvedWindowID = logicalBinding.windowID
                            if Self.shouldPersistResolvedLogicalContextWindowMapping(for: toolName) {
                                await setConnectionWindowMapping(connectionID, windowID: logicalBinding.windowID)
                            }
                            connectionLog(
                                "Tool call: resolved logical context_id=\(logicalBinding.logicalContext.tabID) workspace=\(logicalBinding.logicalContext.workspaceName) window=\(logicalBinding.windowID)"
                            )
                        }
                    } catch {
                        let routePolicy = await effectivePolicyState(for: connectionID)
                        if routePolicy.purpose == .agentModeRun || routePolicy.restricted.contains("bind_context") {
                            return Self.toolErrorResult(
                                rawJSON: capturedRawJSON,
                                message: "Unable to resolve the requested RepoPrompt context for this restricted connection. " +
                                    Self.multiWindowSelectionGuidance(
                                        purpose: routePolicy.purpose,
                                        restrictedTools: routePolicy.restricted
                                    )
                            )
                        }
                        return Self.toolErrorResult(rawJSON: capturedRawJSON, message: error.localizedDescription)
                    }
                }
            }

            do {
                let policyState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPToolCall.policyGating,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.policyGating, policyState) }

                // tools/list already performs any needed persisted routing hydration.
                // Avoid repeating that work while a tool call is in-flight.

                // Block policy-gated tools unless explicitly granted via additionalTools
                if MCPPolicyGatedTools.names.contains(toolName) {
                    let effectivePolicy = await effectivePolicyState(for: connectionID)
                    if !effectivePolicy.additional.contains(toolName) {
                        #if DEBUG
                            await debugPolicyDiagnostic("toolsCallRejected", connectionID: connectionID, policy: effectivePolicy, extra: [
                                "toolName": toolName,
                                "reason": "missing_additional_tool_grant"
                            ])
                        #endif
                        return CallTool.Result.err("Tool '\(toolName)' is only available during discovery or agent mode runs.")
                    }
                }
            }

            // Rehydrate canonical binding fields only when the tool explicitly accepts
            // them. For migrated tools, context_id/_tabID has already become a one-shot
            // tab-context hint instead of hidden sticky binding args.
            var dispatchArguments = cleanedArguments
            if let contextID = extractedContextID, Self.shouldRehydrateContextID(for: toolName) {
                dispatchArguments["context_id"] = .string(contextID.uuidString)
            }
            if let legacyTabID = extractedTabID, Self.shouldRehydrateLegacyTabID(for: toolName) {
                dispatchArguments["_tabID"] = .string(legacyTabID.uuidString)
            }
            if let windowID = extractedWindowID, Self.shouldRehydrateExplicitWindowID(for: toolName) {
                dispatchArguments["window_id"] = .int(windowID)
            }
            if toolName == "bind_context", !extractedWorkingDirs.isEmpty {
                dispatchArguments["working_dirs"] = .array(extractedWorkingDirs.map { .string($0) })
            }

            // Prepare args for formatter. Hidden _tabID is injected only for explicit
            // compatibility paths that still inspect legacy args directly.
            var argsForFormatter = dispatchArguments
            if Self.shouldInjectLegacyTabIDForCompatibility(for: toolName),
               let tabID = dispatchTabContextHint?.tabID ?? extractedTabID
            {
                argsForFormatter["_tabID"] = .string(tabID.uuidString)
            }
            if !Self.shouldBypassWindowRouting(for: toolName),
               let windowID = extractedWindowID ?? preResolvedWindowID
            {
                argsForFormatter["_windowID"] = .int(windowID)
            }
            if extractedRawJSON {
                argsForFormatter["_rawJSON"] = .bool(true)
            }

            connectionLog("tools/call \(toolName): computing effective policy")
            let policy = await EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.effectivePolicySnapshot,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                await self.effectivePolicyState(for: connectionID)
            }
            connectionLog("tools/call \(toolName): policy ready")
            do {
                let policyState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPToolCall.policyGating,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.policyGating, policyState) }
                if policy.restricted.contains(toolName) {
                    log.notice("Connection \(connectionID) attempted to call restricted tool \(toolName)")
                    return Self.toolErrorResult(rawJSON: capturedRawJSON, message: "Tool '\(toolName)' is disabled for this connection.")
                }
                if MCPToolCapabilities.capabilities(for: toolName).contains(.agentExploreControl),
                   !AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                       toolName: toolName,
                       taskLabelKind: policy.taskLabelKind,
                       allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools
                   )
                {
                    return Self.toolErrorResult(
                        rawJSON: capturedRawJSON,
                        message: "Tool 'agent_explore' is only available to MCP-started non-explore Agent Mode runs."
                    )
                }
            }

            // Create immutable copies for Swift 6 concurrency safety
            let capturedTabContextHint = dispatchTabContextHint
            let capturedTabID = Self.shouldUseGenericTabBindingCompatibility(for: toolName)
                ? (dispatchTabContextHint?.tabID ?? extractedTabID)
                : nil
            let capturedWindowID = extractedWindowID
            let capturedPreResolvedWindowID = preResolvedWindowID
            let capturedArguments = dispatchArguments
            let capturedArgsForFormatter = argsForFormatter

            // Snapshot routing state before entering the per-connection limiter.
            // Keep the snapshot local to this call so app-wide tools do not share
            // mutable cross-connection service state.
            let bypassWindowRoutingForSnapshot = Self.shouldBypassWindowRouting(for: toolName)
            connectionLog("tools/call \(toolName): reading MainActor routing state")
            let routingSnapshot: (Int, [any Service], Bool) = await EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.routingSnapshot,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                await MainActor.run {
                    let services = ServiceRegistry.services
                    guard !bypassWindowRoutingForSnapshot else {
                        return (0, services, false)
                    }
                    let windows = WindowStatesManager.shared.allWindows
                    let effectiveMode = WindowStatesManager.shared.isMultiWindowModeEffectivelyActive
                    return (windows.count, services, effectiveMode)
                }
            }
            connectionLog("tools/call \(toolName): routing state windowCount=\(routingSnapshot.0) services=\(routingSnapshot.1.count) multi=\(routingSnapshot.2)")

            // Per-connection concurrency limiter with safe release pattern
            connectionLog("tools/call \(toolName): acquiring limiter")
            let limiter = await EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.limiterResolution,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                await self.limiter(for: connectionID)
            }
            endPreLimiterEnvelopeIfNeeded()
            connectionLog("tools/call \(toolName): entering limiter")
            return await EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.limiterEnvelope,
                EditFlowPerf.Dimensions(toolName: toolName)
            ) {
                let limiterWaitState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.MCPToolCall.limiterWait,
                    EditFlowPerf.Dimensions(toolName: toolName)
                )
                return await limiter.withPermit {
                    EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.limiterWait, limiterWaitState)
                    return await EditFlowPerf.measure(
                        EditFlowPerf.Stage.MCPToolCall.permitBodyEnvelope,
                        EditFlowPerf.Dimensions(toolName: toolName)
                    ) {
                        // Wrap entire call so inner services can query current routing hints.
                        await Self.$currentConnectionID.withValue(connectionID) {
                            await Self.$currentTabContextHint.withValue(capturedTabContextHint) {
                                let permitPreDispatchEnvelopeState = EditFlowPerf.begin(
                                    EditFlowPerf.Stage.MCPToolCall.permitPreDispatchEnvelope,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                )
                                var didEndPermitPreDispatchEnvelope = false
                                func endPermitPreDispatchEnvelopeIfNeeded() {
                                    guard !didEndPermitPreDispatchEnvelope else { return }
                                    didEndPermitPreDispatchEnvelope = true
                                    EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPreDispatchEnvelope, permitPreDispatchEnvelopeState)
                                }
                                defer { endPermitPreDispatchEnvelopeIfNeeded() }

                                // Global enable flag
                                let isEnabled = await EditFlowPerf.measure(
                                    EditFlowPerf.Stage.MCPToolCall.enabledStateSnapshot,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                ) {
                                    await self.isEnabledState
                                }
                                guard isEnabled else {
                                    log.notice("Tool call rejected: RepoPrompt MCP is disabled")
                                    return Self.toolErrorResult(rawJSON: capturedRawJSON, message: "RepoPrompt MCP is currently disabled.")
                                }

                                // ────────────────────────────────────────────────────────
                                // Window-selection with explicit override support
                                // ────────────────────────────────────────────────────────
                                // Hidden params like `_windowID` can explicitly redirect a call even
                                // when the connection already has a preferred window binding.

                                let (windowCount, allServices, multiWindowModeEffective) = routingSnapshot
                                var chosenID: Int?
                                let windowStr: String
                                let observerRunIDForCallbacksFinal: UUID?
                                do {
                                    let windowRunResolutionState = EditFlowPerf.begin(
                                        EditFlowPerf.Stage.MCPToolCall.windowRunResolution,
                                        EditFlowPerf.Dimensions(toolName: toolName)
                                    )
                                    defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.windowRunResolution, windowRunResolutionState) }

                                    let bypassWindowRouting = Self.shouldBypassWindowRouting(for: toolName)
                                    let existingMapping = bypassWindowRouting ? nil : await self.connectionWindowMap[connectionID]
                                    chosenID = bypassWindowRouting ? nil : capturedPreResolvedWindowID
                                    let preassigned = await self.preassignedConnections.contains(connectionID)
                                    if let cid = existingMapping {
                                        mcpRoutingLog("Tool=\(toolName) conn=\(connectionID) has existingWindow=\(cid) preassigned=\(preassigned)")
                                    }

                                    // ═══════════════════════════════════════════════════════════════
                                    // PRIORITY 0: _windowID is a strong per-call override
                                    // ═══════════════════════════════════════════════════════════════
                                    // When provided, _windowID always takes precedence, even over
                                    // existing connection mappings. This enables explicit window targeting.
                                    if !bypassWindowRouting, let requestedWindowID = capturedWindowID {
                                        let windowValid = await WindowStatesManager.shared.hasWindowWithMCPEnabled(requestedWindowID)
                                        guard windowValid else {
                                            return Self.toolErrorResult(
                                                rawJSON: capturedRawJSON,
                                                message: Self.invalidWindowSelectionGuidance(
                                                    windowID: requestedWindowID,
                                                    purpose: policy.purpose,
                                                    restrictedTools: policy.restricted
                                                )
                                            )
                                        }

                                        chosenID = requestedWindowID
                                        if existingMapping == nil {
                                            await self.setConnectionWindowMapping(connectionID, windowID: requestedWindowID)
                                            connectionLog("Tool call: bound unassigned connection \(connectionID) to window \(requestedWindowID) via _windowID")
                                        } else if let prev = existingMapping, prev != requestedWindowID {
                                            connectionLog("Tool call: applying per-call _windowID override \(prev) → \(requestedWindowID) for connection \(connectionID) (default binding unchanged)")
                                        } else {
                                            connectionLog("Tool call: routed connection \(connectionID) to window \(requestedWindowID) via _windowID")
                                        }
                                    }

                                    // ═══════════════════════════════════════════════════════════════
                                    // PRIORITY 1: Use existing connection mapping (no override requested)
                                    // ═══════════════════════════════════════════════════════════════
                                    if !bypassWindowRouting, chosenID == nil, let mapped = existingMapping {
                                        chosenID = mapped
                                        mcpRoutingLog("Tool=\(toolName) using existing mapping conn=\(connectionID) window=\(mapped)")
                                    }

                                    // PRIORITY 2: Use clientName to find existing window assignment (for same client, new connection)
                                    if !bypassWindowRouting,
                                       chosenID == nil,
                                       let clientName = await self.clientIdentifier(forConnection: connectionID),
                                       let windowID = await self.reusableWindowForClient(newConnectionID: connectionID, clientName: clientName)
                                    {
                                        chosenID = windowID
                                        await self.setConnectionWindowMapping(connectionID, windowID: windowID)
                                        connectionLog("Tool call: auto-routed connection \(connectionID) to window \(windowID) via clientName '\(clientName)' reuse")
                                    }

                                    // PRIORITY 2b: Same-process live run affinity, then persisted window affinity.
                                    if !bypassWindowRouting,
                                       chosenID == nil,
                                       let clientName = await self.clientIdentifier(forConnection: connectionID)
                                    {
                                        let managerToken = await self.connections[connectionID]?.capabilityToken
                                        let cachedToken = await self.capabilityTokenByConnection[connectionID]
                                        let sessionKey = managerToken ?? cachedToken
                                        mcpRoutingInternalDebugLog("[PRIORITY 2b] client='\(clientName)' managerToken=\(managerToken?.prefix(8) ?? "nil") cachedToken=\(cachedToken?.prefix(8) ?? "nil") sessionKey=\(sessionKey?.prefix(8) ?? "nil")")
                                        if let liveAffinity = await self.preferredLiveRunAffinity(for: clientName, sessionKey: sessionKey) {
                                            chosenID = liveAffinity.windowID
                                            await self.setConnectionWindowMapping(connectionID, windowID: liveAffinity.windowID)
                                            _ = await self.mapConnectionToRunID(
                                                connectionID,
                                                runID: liveAffinity.runID,
                                                windowID: liveAffinity.windowID
                                            )
                                            connectionLog("Tool call: restored live run affinity for connection \(connectionID) → runID \(liveAffinity.runID)")
                                        } else if let preferredWindowID = await self.preferredWindowID(for: clientName, sessionKey: sessionKey) {
                                            chosenID = preferredWindowID
                                            await self.setConnectionWindowMapping(connectionID, windowID: preferredWindowID)
                                            connectionLog("Tool call: auto-routed connection \(connectionID) to window \(preferredWindowID) via persisted routing affinity for client '\(clientName)'")
                                        }
                                    }

                                    // PRIORITY 3: Auto-route to active window when:
                                    // - Currently in single-window mode, OR
                                    // - Connection was established during single-window mode (stays bound even when more windows open)
                                    let connectedDuringSingleWindow: Bool
                                    if let recordedWindowCount = await self.windowCountAtConnectionTime[connectionID] {
                                        connectedDuringSingleWindow = recordedWindowCount == 1
                                    } else if multiWindowModeEffective {
                                        mcpRoutingLog("Auto-routing conn=\(connectionID): connect-time window count unavailable; treating as multi-window")
                                        connectedDuringSingleWindow = false
                                    } else {
                                        connectedDuringSingleWindow = windowCount == 1
                                    }
                                    if !bypassWindowRouting && chosenID == nil && (!multiWindowModeEffective || connectedDuringSingleWindow) {
                                        // Find the window with active MCP tools
                                        let activeWindowID = await WindowStatesManager.shared.firstMCPEnabledWindow()?.windowID
                                        if let activeID = activeWindowID {
                                            let reason = connectedDuringSingleWindow && multiWindowModeEffective
                                                ? "single-window-at-connect"
                                                : "no policy"
                                            mcpRoutingLog("Auto-routing conn=\(connectionID) to active window=\(activeID) (\(reason))")
                                            chosenID = activeID
                                            // Store the mapping for this connection
                                            await self.setConnectionWindowMapping(connectionID, windowID: activeID)
                                        }
                                    }

                                    // Only require explicit window selection when multi-window mode is effectively active.
                                    // bind_context is exempt because it is the public routing/binding entry point.
                                    if !bypassWindowRouting,
                                       multiWindowModeEffective,
                                       chosenID == nil,
                                       !Self.isWindowSelectionExempt(toolName: toolName, args: capturedArguments)
                                    {
                                        return Self.toolErrorResult(
                                            rawJSON: capturedRawJSON,
                                            message: Self.multiWindowSelectionGuidance(
                                                purpose: policy.purpose,
                                                restrictedTools: policy.restricted
                                            )
                                        )
                                    }

                                    // Log the call - one notice for the call, debug for the end
                                    windowStr = chosenID.map(String.init) ?? "-"
                                    let logName = (originalName == toolName) ? toolName : "\(originalName)→\(toolName)"
                                    connectionLog("Tool call: \(logName) [conn=\(connectionID) window=\(windowStr)]")

                                    // Notify tool call observers using the connection's resolved run mapping.
                                    // Coordination/app-wide routing tools run before a stable window/run context may
                                    // exist, so avoid re-entering MainActor run lookup on that hot path.
                                    observerRunIDForCallbacksFinal = Self.shouldBypassWindowRouting(for: toolName)
                                        ? nil
                                        : await self.runIDForConnection(connectionID)
                                }
                                let invocationID = UUID()
                                if let runID = observerRunIDForCallbacksFinal {
                                    let observerState = EditFlowPerf.begin(
                                        EditFlowPerf.Stage.MCPToolCall.observerCallbacks,
                                        EditFlowPerf.Dimensions(toolName: toolName)
                                    )
                                    let legacyObserverCount = await self.fireToolCallObservers(runID: runID, toolName: toolName)
                                    let eventObserverCount = await self.fireToolCalledObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments)
                                    EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.observerCallbacks, observerState)
                                    #if DEBUG
                                        if toolName == "agent_run" {
                                            print("[ACPAgentRunToolTracking] MCP observer call tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) legacyObservers=\(legacyObserverCount) eventObservers=\(eventObserverCount)")
                                        }
                                    #endif
                                } else {
                                    if MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName) {
                                        mcpToolTrackingDiagnostic(
                                            "MCP observer call skipped no runID conn=\(connectionID.uuidString) " +
                                                "tool=\(toolName) invocation=\(invocationID.uuidString)"
                                        )
                                    }
                                    #if DEBUG
                                        if toolName == "agent_run" {
                                            print("[ACPAgentRunToolTracking] MCP observer call skipped no-run tool=\(toolName) conn=\(connectionID.uuidString)")
                                        }
                                    #endif
                                }

                                let shouldTrackToolOwnership = await EditFlowPerf.measure(
                                    EditFlowPerf.Stage.MCPToolCall.ownershipPurposeResolution,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                ) {
                                    await self.runPurpose(for: connectionID) != .agentModeRun
                                }

                                // Record value signal for admission fairness and history
                                await EditFlowPerf.measure(
                                    EditFlowPerf.Stage.MCPToolCall.toolCallRecording,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                ) {
                                    await self.recordToolCall(for: connectionID, toolName: toolName)
                                }
                                defer { connectionLog("CALL end   conn=\(connectionID) tool=\(toolName) window=\(windowStr)") }

                                // ────────────────────────────────────────────────────────
                                // Run-scoped tab rebind fallback on reconnect handovers
                                // ────────────────────────────────────────────────────────
                                let shouldAttemptRunScopedTabRebindFallback = capturedTabID == nil
                                    && observerRunIDForCallbacksFinal != nil
                                    && chosenID != nil
                                    && !Self.shouldSkipPerCallRunScopedTabRebindFallback(
                                        toolName: toolName,
                                        purpose: policy.purpose
                                    )
                                do {
                                    let runScopedTabRebindFallbackState = EditFlowPerf.begin(
                                        EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback,
                                        EditFlowPerf.Dimensions(
                                            toolName: toolName,
                                            outcome: shouldAttemptRunScopedTabRebindFallback ? "attempted" : "skipped"
                                        )
                                    )
                                    defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback, runScopedTabRebindFallbackState) }
                                    if shouldAttemptRunScopedTabRebindFallback,
                                       let runID = observerRunIDForCallbacksFinal,
                                       let windowID = chosenID
                                    {
                                        let clientName = await self.clientIdentifier(forConnection: connectionID)
                                        _ = await self.ensureTabBoundForRunIfPossible(
                                            connectionID: connectionID,
                                            clientName: clientName,
                                            runID: runID,
                                            windowID: windowID
                                        )
                                    }
                                }

                                // ────────────────────────────────────────────────────────
                                // Legacy compatibility: sticky tab binding via hidden _tabID for unmigrated tools only
                                // ────────────────────────────────────────────────────────
                                let shouldAttemptLegacyTabBindingCompatibility = capturedTabID != nil
                                    && !Self.shouldSkipGenericTabBinding(for: toolName)
                                do {
                                    let legacyTabBindingCompatibilityState = EditFlowPerf.begin(
                                        EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility,
                                        EditFlowPerf.Dimensions(
                                            toolName: toolName,
                                            outcome: shouldAttemptLegacyTabBindingCompatibility ? "attempted" : "skipped"
                                        )
                                    )
                                    defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility, legacyTabBindingCompatibilityState) }
                                    if shouldAttemptLegacyTabBindingCompatibility, let tabID = capturedTabID {
                                        // Guard: _tabID requires a resolved window
                                        guard let windowID = chosenID else {
                                            let msg = ToolOutputFormatter.operationFailed(
                                                title: "Tab Binding Failed",
                                                issue: "Cannot bind to tab \(tabID.uuidString.prefix(8))... - no window is selected.",
                                                troubleshooting: Self.tabBindingTroubleshooting(
                                                    purpose: policy.purpose,
                                                    restrictedTools: policy.restricted
                                                )
                                            )
                                            return CallTool.Result(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: true)
                                        }

                                        let clientName = await self.clientIdentifier(forConnection: connectionID)

                                        do {
                                            try await MainActor.run {
                                                guard let windowState = WindowStatesManager.shared.window(withID: windowID) else {
                                                    throw MCPError.invalidParams("Window \(windowID) not found")
                                                }
                                                let resolvedWorkspaceID = capturedTabContextHint?.workspaceID
                                                    ?? windowState.workspaceManager.resolveComposeTabRoutingSnapshot(for: tabID)?.workspaceID
                                                    ?? windowState.workspaceManager.activeWorkspace?.id
                                                guard let workspaceID = resolvedWorkspaceID else {
                                                    throw MCPError.invalidParams("No workspace containing tab \(tabID) is available in window \(windowID). Use bind_context op='list' to verify context_id/window routing.")
                                                }
                                                try windowState.mcpServer.bindTabForConnection(
                                                    connectionID: connectionID,
                                                    clientName: clientName,
                                                    tabID: tabID,
                                                    workspaceID: workspaceID,
                                                    windowID: windowID
                                                )
                                            }
                                            await self.setConnectionWindowMapping(connectionID, windowID: windowID)
                                            connectionLog("Tab binding: bound connection \(connectionID) to tab \(tabID) in window \(windowID)")
                                        } catch {
                                            // Tab binding failed - provide detailed error with window context
                                            let shortTabID = tabID.uuidString.prefix(8)
                                            let issue = "Tab \(shortTabID)... not found in window \(windowID)."
                                            let msg = ToolOutputFormatter.operationFailed(
                                                title: "Tab Binding Failed",
                                                issue: issue,
                                                troubleshooting: Self.tabBindingTroubleshooting(
                                                    purpose: policy.purpose,
                                                    restrictedTools: policy.restricted,
                                                    windowID: windowID
                                                )
                                            )
                                            return CallTool.Result(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: true)
                                        }
                                    }
                                }

                                // ────────────────────────────────────────────────────────
                                // Tool dispatch with window filtering
                                // ────────────────────────────────────────────────────────
                                let serviceToolLookupState = EditFlowPerf.begin(
                                    EditFlowPerf.Stage.MCPToolCall.serviceToolLookup,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                )
                                for service in allServices {
                                    // App-wide coordination tools have a single owning service. Avoid probing
                                    // unrelated window-scoped services for their tool lists during startup,
                                    // because some of those lists hop through UI/window state.
                                    if toolName == "bind_context", !(service is WindowRoutingService) { continue }
                                    if toolName == AppSettingsMCPService.toolName, !(service is AppSettingsMCPService) { continue }

                                    let wsSvc = service as? WindowScopedService

                                    // Skip window-scoped services that don't match this connection
                                    if let wsSvc, windowCount > 1 {
                                        guard let wID = chosenID, wID == wsSvc.windowID else { continue }
                                    }

                                    // Get the tool definition (need schema for window_id injection)
                                    connectionLog("tools/call \(toolName): inspecting service \(String(describing: type(of: service)))")
                                    #if DEBUG || EDIT_FLOW_PERF
                                        let serviceToolsAwaitState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait)
                                    #endif
                                    let serviceTools = await service.tools
                                    #if DEBUG || EDIT_FLOW_PERF
                                        EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait, serviceToolsAwaitState)
                                    #endif
                                    connectionLog("tools/call \(toolName): service \(String(describing: type(of: service))) exposes \(serviceTools.count) tools")
                                    #if DEBUG || EDIT_FLOW_PERF
                                        let toolDefinitionScanState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan)
                                    #endif
                                    guard let toolDef = serviceTools.first(where: { $0.name == toolName }) else {
                                        #if DEBUG || EDIT_FLOW_PERF
                                            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan, toolDefinitionScanState)
                                        #endif
                                        continue
                                    }
                                    #if DEBUG || EDIT_FLOW_PERF
                                        EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan, toolDefinitionScanState)
                                    #endif
                                    connectionLog("tools/call \(toolName): dispatching via service \(String(describing: type(of: service))) windowScoped=\(wsSvc != nil)")

                                    // Inject window_id from routing if tool schema declares it and caller didn't provide it.
                                    // bind_context manages its own window_id semantics and must not be auto-injected.
                                    let effectiveArgs: [String: Value]
                                    let effectiveArgsForFormatter: [String: Value]
                                    if Self.shouldAutoInjectPublicWindowID(for: toolName) {
                                        #if DEBUG || EDIT_FLOW_PERF
                                            let publicWindowIDInjectionState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection)
                                        #endif
                                        let routingWindowID: Int? = {
                                            if let wsSvc {
                                                return capturedWindowID ?? chosenID ?? wsSvc.windowID
                                            }
                                            return capturedWindowID ?? chosenID
                                        }()
                                        let selectedSchemaDeclaresWindowID = routingWindowID != nil
                                            && (
                                                capturedArguments["window_id"] == nil
                                                    || capturedArgsForFormatter["window_id"] == nil
                                            )
                                            && self.schemaDeclaresWindowID(schema: toolDef.inputSchema)
                                        effectiveArgs = self.injectWindowIDIfNeeded(
                                            schemaDeclaresWindowID: selectedSchemaDeclaresWindowID,
                                            routingWindowID: routingWindowID,
                                            args: capturedArguments
                                        )
                                        effectiveArgsForFormatter = self.injectWindowIDIfNeeded(
                                            schemaDeclaresWindowID: selectedSchemaDeclaresWindowID,
                                            routingWindowID: routingWindowID,
                                            args: capturedArgsForFormatter
                                        )
                                        #if DEBUG || EDIT_FLOW_PERF
                                            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection, publicWindowIDInjectionState)
                                        #endif
                                    } else {
                                        effectiveArgs = capturedArguments
                                        effectiveArgsForFormatter = capturedArgsForFormatter
                                    }
                                    EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookup, serviceToolLookupState)
                                    endPermitPreDispatchEnvelopeIfNeeded()

                                    // Now dispatch. If window-scoped, wrap in ownership scope (fallback to service window).
                                    if let wsSvc, shouldTrackToolOwnership {
                                        let ownershipWindowID = chosenID ?? wsSvc.windowID
                                        do {
                                            return try await self.withWindowToolOwnership(
                                                windowID: ownershipWindowID,
                                                connectionID: connectionID,
                                                toolName: toolName
                                            ) {
                                                let value = try await EditFlowPerf.measure(
                                                    EditFlowPerf.Stage.MCPToolCall.dispatch,
                                                    EditFlowPerf.Dimensions(toolName: toolName)
                                                ) {
                                                    try await toolDef.callAsFunction(effectiveArgs)
                                                }
                                                let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                                    EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                                    EditFlowPerf.Dimensions(toolName: toolName, outcome: "success")
                                                )
                                                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }

                                                // Build well‑structured, human‑readable content blocks for the result
                                                let contentBlocks = EditFlowPerf.measure(
                                                    EditFlowPerf.Stage.MCPToolCall.formatResult,
                                                    EditFlowPerf.Dimensions(toolName: toolName)
                                                ) {
                                                    Self.formatToolResult(
                                                        toolName: toolName,
                                                        args: effectiveArgsForFormatter,
                                                        value: value
                                                    )
                                                }

                                                // Fire completion observer with result for detailed UI rendering
                                                await EditFlowPerf.measure(
                                                    EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                                    EditFlowPerf.Dimensions(toolName: toolName)
                                                ) {
                                                    if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "window-scoped success") {
                                                        let resultJSON = ToolOutputFormatter.rawJSONString(value)
                                                        let eventObserverCount = await self.fireToolCompletedObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments, resultJSON: resultJSON, isError: false)
                                                        #if DEBUG
                                                            if toolName == "agent_run" {
                                                                print("[ACPAgentRunToolTracking] MCP observer completion tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount) isError=false resultChars=\(resultJSON.count)")
                                                            }
                                                        #endif
                                                    }
                                                }

                                                // Note: context_builder caller termination is NOT done here.
                                                // The spawned agent connection is terminated by ContextBuilderAgentViewModel
                                                // when the run completes. This prevents killing the host MCP client
                                                // (e.g., Claude Desktop) that invoked context_builder.

                                                return CallTool.Result(content: contentBlocks, isError: false)
                                            }
                                        } catch {
                                            let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                                EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                                EditFlowPerf.Dimensions(toolName: toolName, outcome: "dispatchError")
                                            )
                                            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }
                                            log.error("Error executing tool \(toolName): \(error.localizedDescription)")
                                            await EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "window-scoped error") {
                                                    let errorJSON = ToolOutputFormatter.rawJSONString(.object(["error": .string(error.localizedDescription), "tool": .string(toolName)]))
                                                    let eventObserverCount = await self.fireToolCompletedObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments, resultJSON: errorJSON, isError: true)
                                                    #if DEBUG
                                                        if toolName == "agent_run" {
                                                            print("[ACPAgentRunToolTracking] MCP observer completion tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount) isError=true resultChars=\(errorJSON.count)")
                                                        }
                                                    #endif
                                                }
                                            }
                                            return Self.toolErrorResult(rawJSON: capturedRawJSON, message: "Error: \(error)")
                                        }
                                    } else {
                                        // Not window-scoped → no ownership tracking needed
                                        do {
                                            let value = try await EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.dispatch,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                try await toolDef.callAsFunction(effectiveArgs)
                                            }
                                            let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                                EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                                EditFlowPerf.Dimensions(toolName: toolName, outcome: "success")
                                            )
                                            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }

                                            // Build well‑structured, human‑readable content blocks for the result
                                            let contentBlocks = EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.formatResult,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                Self.formatToolResult(
                                                    toolName: toolName,
                                                    args: effectiveArgsForFormatter,
                                                    value: value
                                                )
                                            }

                                            // Fire completion observer with result for detailed UI rendering
                                            await EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "global success") {
                                                    let resultJSON = ToolOutputFormatter.rawJSONString(value)
                                                    let eventObserverCount = await self.fireToolCompletedObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments, resultJSON: resultJSON, isError: false)
                                                    #if DEBUG
                                                        if toolName == "agent_run" {
                                                            print("[ACPAgentRunToolTracking] MCP observer completion tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount) isError=false resultChars=\(resultJSON.count)")
                                                        }
                                                    #endif
                                                }
                                            }

                                            // Note: context_builder caller termination is NOT done here.
                                            // See comment in window-scoped branch above.

                                            return CallTool.Result(content: contentBlocks, isError: false)
                                        } catch {
                                            let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                                EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                                EditFlowPerf.Dimensions(toolName: toolName, outcome: "dispatchError")
                                            )
                                            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }
                                            log.error("Error executing tool \(toolName): \(error.localizedDescription)")
                                            await EditFlowPerf.measure(
                                                EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                                EditFlowPerf.Dimensions(toolName: toolName)
                                            ) {
                                                if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "global error") {
                                                    let errorJSON = ToolOutputFormatter.rawJSONString(.object(["error": .string(error.localizedDescription), "tool": .string(toolName)]))
                                                    let eventObserverCount = await self.fireToolCompletedObservers(runID: runID, invocationID: invocationID, toolName: toolName, args: capturedArguments, resultJSON: errorJSON, isError: true)
                                                    #if DEBUG
                                                        if toolName == "agent_run" {
                                                            print("[ACPAgentRunToolTracking] MCP observer completion tool=\(toolName) conn=\(connectionID.uuidString) runID=\(runID.uuidString) invocation=\(invocationID.uuidString) eventObservers=\(eventObserverCount) isError=true resultChars=\(errorJSON.count)")
                                                        }
                                                    #endif
                                                }
                                            }
                                            return Self.toolErrorResult(rawJSON: capturedRawJSON, message: "Error: \(error)")
                                        }
                                    }
                                }

                                EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookup, serviceToolLookupState)
                                endPermitPreDispatchEnvelopeIfNeeded()
                                let permitPostDispatchEnvelopeState = EditFlowPerf.begin(
                                    EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                                    EditFlowPerf.Dimensions(toolName: toolName, outcome: "toolNotFound")
                                )
                                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope, permitPostDispatchEnvelopeState) }
                                await EditFlowPerf.measure(
                                    EditFlowPerf.Stage.MCPToolCall.completionObservers,
                                    EditFlowPerf.Dimensions(toolName: toolName)
                                ) {
                                    let finalToolNotFoundErrorJSON = ToolOutputFormatter.rawJSONString(.object(["error": .string("Tool not found: \(toolName)"), "tool": .string(toolName)]))
                                    if let runID = await self.toolTrackingRunIDForCompletion(callTimeRunID: observerRunIDForCallbacksFinal, connectionID: connectionID, toolName: toolName, invocationID: invocationID, context: "final tool-not-found fallthrough") {
                                        let eventObserverCount = await self.fireToolCompletedObservers(
                                            runID: runID,
                                            invocationID: invocationID,
                                            toolName: toolName,
                                            args: capturedArguments,
                                            resultJSON: finalToolNotFoundErrorJSON,
                                            isError: true
                                        )
                                        mcpToolTrackingDiagnostic(
                                            "MCP observer completion final tool-not-found fallthrough conn=\(connectionID.uuidString) " +
                                                "runID=\(runID.uuidString) tool=\(toolName) invocation=\(invocationID.uuidString) " +
                                                "eventObservers=\(eventObserverCount)"
                                        )
                                    }
                                }
                                log.error("Tool not found: \(toolName)")
                                return Self.toolErrorResult(rawJSON: capturedRawJSON, message: "Tool not found: \(toolName)")
                            } // TabContextHint TaskLocal wrapper
                        } // ConnectionID TaskLocal wrapper
                    } // PermitBodyEnvelope wrapper
                } // withPermit wrapper
            } // LimiterEnvelope wrapper
        }
    }

    /// Update the enabled state and notify clients
    func setEnabled(_ enabled: Bool) async {
        // Only do something if the state actually changes
        guard isEnabledState != enabled else { return }

        isEnabledState = enabled
        log.notice("RepoPrompt MCP enabled state changed to: \(enabled)")

        // Notify all connected clients that the tool list has changed
        for (_, connectionManager) in connections {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    /// Notify every connected client that the advertised tool catalogue
    /// has changed (e.g. user enabled/disabled a tool in Settings).
    func broadcastToolListChanged() async {
        connectionLog("Broadcasting ToolListChanged notification to all clients")
        invalidateToolSchemaCache()
        for (_, connectionManager) in connections {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    // MARK: - Dashboard Snapshot

    /// Creates a snapshot of the current network state for the dashboard UI.
    /// This provides a comprehensive view of all connections and their status.
    /// Connections without identity (haven't completed MCP handshake) are excluded.
    func dashboardSnapshot() async -> NetworkDashboardSnapshot {
        var entries: [ConnectionDashboardEntry] = []

        for (id, manager) in connections {
            // Use known client name or placeholder for connections still completing handshake
            let admittedName = clientIDByConnection[id]
            let pendingName = pendingConnections[id]
            let clientName = admittedName ?? pendingName ?? "Connecting..."

            if admittedName == nil && pendingName == nil {
                log.warning("Dashboard: Connection \(id) has no client name (admitted=nil, pending=nil)")
            }

            let windowID = connectionWindowMap[id]
            let stats = connectionStats[id]

            // Get connection state
            let rawState = await manager.connectionState()
            let stateSummary: ConnectionStateSummary = switch rawState {
            case .ready: .ready
            case .connecting: .setup
            case .failed: .failed
            case .cancelled: .cancelled
            }

            // Get idle time
            let idle = await manager.secondsSinceLastActivity()
            let hasInFlight = await hasInFlightCalls(for: id)

            // Get active tool name if this connection owns one
            let activeToolName: String? = if let winID = windowID, activeToolOwnerByWindow[winID] == id {
                activeToolNameByWindow[winID]
            } else if let ownedWindow = activeToolOwnerByWindow.first(where: { $0.value == id })?.key {
                activeToolNameByWindow[ownedWindow]
            } else {
                nil
            }

            // Determine transport type
            let transport: ConnectionTransport = manager.isFilesystemBacked ? .filesystem : .network

            // Get routing metadata (no longer track per-connection remote TCP port)
            let sessionKey = manager.capabilityToken ?? capabilityTokenByConnection[id]

            entries.append(
                ConnectionDashboardEntry(
                    id: id,
                    clientName: clientName,
                    windowID: windowID,
                    transport: transport,
                    state: stateSummary,
                    createdAt: stats?.createdAt ?? Date.distantPast,
                    lastToolCallAt: stats?.lastToolCallAt,
                    totalToolCalls: stats?.totalToolCalls ?? 0,
                    idleSeconds: idle > 0 ? idle : nil,
                    hasInFlightCalls: hasInFlight,
                    activeToolName: activeToolName,
                    sessionKey: sessionKey
                )
            )
        }

        return NetworkDashboardSnapshot(
            isRunning: isRunningState,
            connections: entries.sorted { $0.createdAt < $1.createdAt },
            recentToolCalls: recentToolCallHistory
        )
    }

    // MARK: - Identity Context Debug Inspection

    /// Returns debug snapshots of identity context for all active connections.
    /// Useful for dashboard debugging to understand how identity was derived.
    func identityContextSnapshots() -> [IdentityContextSnapshot] {
        identityContextByConnection.map { connectionID, ctx in
            let source: IdentityContextSnapshot.Source = switch ctx.source {
            case .unknown: .unknown
            case .filesystemMeta: .filesystemMeta
            case .handshake: .handshake
            }

            return IdentityContextSnapshot(
                connectionID: connectionID,
                clientName: ctx.clientName,
                capabilityToken: ctx.capabilityToken,
                source: source,
                hasHandshake: ctx.hasHandshake,
                lastUpdated: ctx.lastUpdated
            )
        }.sorted { $0.lastUpdated < $1.lastUpdated }
    }

    /// Returns identity context for a specific connection, if available.
    func identityContext(for connectionID: UUID) -> IdentityContextSnapshot? {
        guard let ctx = identityContextByConnection[connectionID] else { return nil }

        let source: IdentityContextSnapshot.Source = switch ctx.source {
        case .unknown: .unknown
        case .filesystemMeta: .filesystemMeta
        case .handshake: .handshake
        }

        return IdentityContextSnapshot(
            connectionID: connectionID,
            clientName: ctx.clientName,
            capabilityToken: ctx.capabilityToken,
            source: source,
            hasHandshake: ctx.hasHandshake,
            lastUpdated: ctx.lastUpdated
        )
    }

    /// Returns the verified peer PID for a bootstrap socket connection, if available.
    func peerPID(for connectionID: UUID) async -> Int? {
        guard let connection = connections[connectionID] else { return nil }
        guard let bootstrap = connection as? BootstrapSocketConnectionManager else { return nil }
        return await bootstrap.peerPID()
    }

    /// Update service bindings - no longer needed but kept for compatibility
    func updateServiceBindings(_ newBindings: [String: Binding<Bool>]) async {
        // No-op since we don't use individual service bindings anymore
        // All services are controlled by the master enabled state
    }

    // MARK: - Admission helpers

    private static var emitResourceContent: Bool {
        UserDefaults.standard.bool(forKey: "mcp.emitResourceContent")
    }

    private static func formatToolResult(
        toolName: String,
        args: [String: Value],
        value: Value
    ) -> [MCP.Tool.Content] {
        let emit = Self.emitResourceContent
        return ToolOutputFormatter.buildContentBlocks(
            toolName: toolName,
            args: args,
            result: value,
            emitResources: emit
        )
    }

    /// Extract text content from tool result content blocks for observer callbacks
    static func extractTextFromContentBlocks(_ blocks: [MCP.Tool.Content]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .text(text: let text, annotations: _, _meta: _):
                return text
            default:
                return nil
            }
        }.joined(separator: "\n")
    }

    private static func languageTag(forPath path: String) -> String {
        // Deprecated: use ToolOutputFormatter.languageTag(forPath:) instead
        ToolOutputFormatter.languageTag(forPath: path)
    }

    private static func prettyJSON(_ value: Value) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }

    // MARK: - Admission helpers

    func tryReserveConnectionSlot(connectionID: UUID, clientID: String) async -> Bool {
        // 0a) Check if this clientID is in user-kill cooldown (prevents auto-reconnect race)
        if isClientInUserKillCooldown(clientID) {
            let remainingTTL = remainingUserKillCooldown(clientID) ?? 0
            log.notice("Rejecting connection \(connectionID) from '\(clientID)' - in user-kill cooldown (remaining: \(String(format: "%.1f", remainingTTL))s of \(Int(userKilledClientCooldown))s)")
            return false
        }

        // 0b) Prune dead slots for this client (defensive cleanup)
        pruneDeadSlots(for: clientID)
        // Ensure the handshake name is visible even if admission blocks briefly.
        pendingConnections[connectionID] = clientID

        // Ensure global headroom. Under pressure, run one explicit hygiene pass
        // before giving up on admission.
        if connections.count >= maxGlobalConnections {
            await pruneNonViableConnections()
        }
        if connections.count >= maxGlobalConnections {
            let evicted = await evictLeastValuableGlobalForAdmission(preserveOnePerClient: preserveOnePerClient)
            if !evicted {
                pendingConnections.removeValue(forKey: connectionID)
                log.notice("Rejecting connection \(connectionID) from '\(clientID)' - global capacity full (active=\(connections.count), cap=\(maxGlobalConnections))")
                return false
            }
        }

        // Enforce per-client cap with hygiene + eviction.
        var set = activeConnectionsByClient[clientID, default: []]
        while set.count >= maxConnectionsPerClient {
            await pruneNonViableConnections()
            pruneDeadSlots(for: clientID)
            set = activeConnectionsByClient[clientID, default: []]
            if set.count < maxConnectionsPerClient { break }

            let evicted = await evictLeastValuable(for: clientID)
            if !evicted {
                pendingConnections.removeValue(forKey: connectionID)
                log.notice("Rejecting connection \(connectionID) from '\(clientID)' - per-client capacity full (active=\(set.count), cap=\(maxConnectionsPerClient))")
                return false
            }
            set = activeConnectionsByClient[clientID, default: []]
        }

        // Reserve & index
        set.insert(connectionID)
        activeConnectionsByClient[clientID] = set
        clientIDByConnection[connectionID] = clientID
        connectionLog("Admitted connection \(connectionID) with clientID='\(clientID)'")
        // Once admitted, the authoritative map is set — we can drop the pending label.
        pendingConnections.removeValue(forKey: connectionID)

        // 4) Initialize stats if not already present
        if connectionStats[connectionID] == nil {
            connectionStats[connectionID] = ConnectionStats(
                createdAt: Date(),
                totalToolCalls: 0,
                lastToolCallAt: nil
            )
        }
        return true
    }

    func releaseConnectionSlot(connectionID: UUID) async {
        if let clientID = clientIDByConnection[connectionID] {
            var set = activeConnectionsByClient[clientID] ?? []
            set.remove(connectionID)
            if set.isEmpty { activeConnectionsByClient.removeValue(forKey: clientID) }
            else { activeConnectionsByClient[clientID] = set }
            clientIDByConnection.removeValue(forKey: connectionID)
        }
    }

    // MARK: - Routing Persistence Helpers

    /// Removes routing records older than routingRecordTTL, purges token-less records,
    /// and cleans up stale in-memory session map entries.
    private func pruneRoutingRecords() async {
        let now = Date()
        let keys = Array(routingState.records.keys)

        // Get live windows to also prune records pointing to closed windows
        let liveWindows: Set<Int> = await MainActor.run {
            Set(WindowStatesManager.shared.allWindows.map(\.windowID))
        }

        for clientID in keys {
            guard let records = routingState.records[clientID] else { continue }
            // Keep only fresh, token-backed records; drop expired, nil-sessionKey, and invalid window entries
            let filtered = records.filter {
                $0.sessionKey != nil &&
                    now.timeIntervalSince($0.lastSeenAt) < routingRecordTTL &&
                    ($0.lastWindowID == nil || liveWindows.contains($0.lastWindowID!))
            }
            if filtered.isEmpty {
                routingState.records.removeValue(forKey: clientID)
                lastWindowByClientSession.removeValue(forKey: clientID)
            } else {
                routingState.records[clientID] = filtered
                // Keep in-memory fast path aligned to surviving sessionKeys
                let validSessionKeys = Set(filtered.compactMap(\.sessionKey))
                if var sessionMap = lastWindowByClientSession[clientID] {
                    sessionMap = sessionMap.filter { validSessionKeys.contains($0.key) }
                    if sessionMap.isEmpty {
                        lastWindowByClientSession.removeValue(forKey: clientID)
                    } else {
                        lastWindowByClientSession[clientID] = sessionMap
                    }
                }
            }
        }
    }

    /// Persists routing state to disk synchronously to avoid race conditions.
    /// Called on the actor so state is always consistent.
    private func saveRoutingState() {
        MCPRoutingStateStore.save(routingState)
    }

    /// Updates the routing record for a connection after window assignment.
    /// Only persists routing/window affinity for token-backed clients; token-less clients are skipped
    /// to avoid incorrectly merging distinct client instances.
    private func updateRoutingRecordForConnection(_ connectionID: UUID, clientID: String) async {
        guard let manager = connections[connectionID] else { return }

        let capability = manager.capabilityToken ?? capabilityTokenByConnection[connectionID]
        guard let sessionKey = capability else {
            connectionLog("Skipping routing persistence for token-less client: \(clientID)")
            return
        }

        let transport: MCPRoutingState.ClientRecord.Transport = manager.isFilesystemBacked ? .filesystem : .network
        let windowID = connectionWindowMap[connectionID]
        let runID = if let mappedRunID = runIDByConnectionID[connectionID] {
            mappedRunID
        } else {
            await runIDForConnection(connectionID)
        }
        let runPurpose = runID.flatMap { runPolicyStateByRunID[$0]?.purpose } ?? runPurposeByConnection[connectionID]
        updateLiveRunAffinity(
            clientName: clientID,
            sessionKey: sessionKey,
            runID: runID,
            windowID: windowID,
            purpose: runPurpose
        )

        let (workspaceID, instanceNumber): (UUID?, Int?) = await MainActor.run {
            guard
                let windowID,
                let win = WindowStatesManager.shared.window(withID: windowID)
            else { return (nil, nil) }
            return (win.workspaceManager.activeWorkspace?.id, win.workspaceInstanceNumber)
        }

        await pruneRoutingRecords()

        let storageKey = bestStorageKey(
            for: clientID,
            in: Array(Set(routingState.records.keys).union(lastWindowByClientSession.keys))
        )
        var records = routingState.records[storageKey] ?? []
        let now = Date()
        let matchedIdx = records.firstIndex(where: {
            $0.lastTransport == transport && $0.sessionKey == sessionKey
        })

        if let idx = matchedIdx {
            records[idx].lastWindowID = windowID
            records[idx].lastWorkspaceID = workspaceID
            records[idx].lastWorkspaceInstanceNumber = instanceNumber
            records[idx].lastConnectionUUID = connectionID
            records[idx].lastSeenAt = now
        } else {
            let record = MCPRoutingState.ClientRecord(
                clientID: storageKey,
                lastTransport: transport,
                sessionKey: sessionKey,
                lastWindowID: windowID,
                lastWorkspaceID: workspaceID,
                lastWorkspaceInstanceNumber: instanceNumber,
                lastConnectionUUID: connectionID,
                lastSeenAt: now
            )
            records.append(record)
        }

        routingState.records[storageKey] = records
        if let windowID {
            lastWindowByClientSession[storageKey, default: [:]][sessionKey] = windowID
        }
        saveRoutingState()
    }

    /// Returns the preferred window ID for a token-backed client session.
    /// Persisted routing is an affinity hint only; live run ownership is resolved separately
    /// from in-memory `liveRunAffinityByClientSession`.
    private func preferredWindowID(for clientName: String, sessionKey: String?) async -> Int? {
        guard sessionKey != nil else {
            mcpRoutingInternalDebugLog("[preferredWindowID] no sessionKey for client '\(clientName)' - returning nil")
            return nil
        }

        mcpRoutingInternalDebugLog("[preferredWindowID] looking up client '\(clientName)' sessionKey '\(sessionKey!.prefix(8))...'")

        await pruneRoutingRecords()

        for key in matchingClientKeys(for: clientName, in: Array(lastWindowByClientSession.keys)) {
            if let sessionKey, let win = lastWindowByClientSession[key]?[sessionKey] {
                let exists = await WindowStatesManager.shared.hasWindow(id: win)
                if exists {
                    mcpRoutingInternalDebugLog("[preferredWindowID] fast path hit: client '\(clientName)' matchedKey '\(key)' window \(win)")
                    return win
                }
            }
        }

        let matchedRecordKeys = matchingClientKeys(for: clientName, in: Array(routingState.records.keys))
        let records = matchedRecordKeys.flatMap { routingState.records[$0] ?? [] }
        guard !records.isEmpty else {
            mcpRoutingInternalDebugLog("[preferredWindowID] no records for client '\(clientName)' - returning nil")
            return nil
        }

        let now = Date()
        let freshRecords = records.filter { record in
            guard record.sessionKey != nil, now.timeIntervalSince(record.lastSeenAt) < routingRecordTTL else {
                return false
            }
            if let sk = sessionKey {
                return record.sessionKey == sk
            }
            return true
        }

        guard !freshRecords.isEmpty else {
            mcpRoutingInternalDebugLog("[preferredWindowID] no fresh records matching sessionKey - returning nil")
            return nil
        }

        let sortedRecords = freshRecords.sorted { $0.lastSeenAt > $1.lastSeenAt }
        let windowSnapshot: [(workspaceID: UUID?, instanceNumber: Int?, windowID: Int)] = await MainActor.run {
            WindowStatesManager.shared.allWindows.map {
                ($0.workspaceManager.activeWorkspace?.id, $0.workspaceInstanceNumber, $0.windowID)
            }
        }

        for record in sortedRecords {
            guard let ws = record.lastWorkspaceID, let inst = record.lastWorkspaceInstanceNumber else { continue }
            if let match = windowSnapshot.first(where: { $0.workspaceID == ws && $0.instanceNumber == inst }) {
                return match.windowID
            }
        }

        for record in sortedRecords {
            guard let ws = record.lastWorkspaceID else { continue }
            let candidates = windowSnapshot.filter { $0.workspaceID == ws }
            if candidates.count == 1 {
                return candidates[0].windowID
            }
        }

        for record in sortedRecords {
            guard let wid = record.lastWindowID else { continue }
            if windowSnapshot.contains(where: { $0.windowID == wid }) {
                return wid
            }
        }

        for record in sortedRecords {
            guard let inst = record.lastWorkspaceInstanceNumber else { continue }
            let candidates = windowSnapshot.filter { $0.instanceNumber == inst }
            if candidates.count == 1 {
                return candidates[0].windowID
            }
        }

        return nil
    }

    /// Record a tool call occurrence for value scoring and history
    func recordToolCall(for connectionID: UUID, toolName: String) {
        // Hidden coordination calls should not appear in dashboards/histories.
        let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        if canonicalToolName == "set_status" || canonicalToolName == "bind_context" { return }

        // If this connection dropped out of the active sets (e.g., after transport toggles),
        // re-associate it now that we have a live tool call.
        if let clientID = clientIdentifier(forConnection: connectionID),
           connections[connectionID] != nil
        {
            var set = activeConnectionsByClient[clientID] ?? []
            if !set.contains(connectionID) {
                set.insert(connectionID)
                activeConnectionsByClient[clientID] = set
                log.notice("Re-associated connection \(connectionID) for client \(clientID) after successful tool call")
            }
        }

        if var s = connectionStats[connectionID] {
            s.totalToolCalls += 1
            s.lastToolCallAt = Date()
            connectionStats[connectionID] = s
        } else {
            connectionStats[connectionID] = ConnectionStats(
                createdAt: Date(),
                totalToolCalls: 1,
                lastToolCallAt: Date()
            )
        }

        // Record in history for dashboard display
        let clientName = clientIdentifier(forConnection: connectionID) ?? "Unknown"
        let entry = ToolCallHistoryEntry(
            timestamp: Date(),
            toolName: toolName,
            clientName: clientName,
            connectionID: connectionID
        )
        recentToolCallHistory.insert(entry, at: 0)
        if recentToolCallHistory.count > maxToolCallHistoryCount {
            recentToolCallHistory.removeLast()
        }

        // Notify dashboard of tool call update
        emitDashboardUpdate()
    }

    /// Returns recent tool call history for dashboard display
    func getRecentToolCallHistory() -> [ToolCallHistoryEntry] {
        recentToolCallHistory
    }

    private func limiterLimit(for connectionID: UUID) -> Int {
        // Always serialize RepoPrompt MCP tool calls per connection.
        // This avoids race conditions where parallel calls can produce duplicate/mis-tracked
        // tool cards (for example identical file_action create calls showing mixed statuses).
        _ = connectionID
        return 1
    }

    func limiter(for connectionID: UUID) -> AsyncLimiter {
        if let l = callLimiters[connectionID] { return l }
        let l = AsyncLimiter(limit: limiterLimit(for: connectionID))
        callLimiters[connectionID] = l
        return l
    }

    func hasInFlightCalls(for connectionID: UUID) async -> Bool {
        guard let limiter = callLimiters[connectionID] else { return false }
        return await limiter.activeCount() > 0
    }

    private func oldestEvictableConnectionID() async -> UUID? {
        let threshold = pressureEvictIdleSeconds
        guard threshold > 0 else { return nil }
        var best: (id: UUID, idle: TimeInterval)? = nil
        for (id, mgr) in connections {
            // Skip connections doing work
            if let lim = callLimiters[id], await lim.activeCount() > 0 {
                continue
            }
            let idle = await mgr.secondsSinceLastActivity()
            if idle >= TimeInterval(threshold) {
                if best == nil || idle > best!.idle {
                    best = (id, idle)
                }
            }
        }
        return best?.id
    }

    /// ─────────────  Admission fairness helpers  ─────────────
    /// Remove client slots that are no longer backed by a live connection entry.
    private func pruneDeadSlots(for clientID: String) {
        guard var set = activeConnectionsByClient[clientID] else { return }
        let live = Set(connections.keys)
        set = set.filter { live.contains($0) }
        if set.isEmpty { activeConnectionsByClient.removeValue(forKey: clientID) }
        else { activeConnectionsByClient[clientID] = set }
    }

    /// Connection is evictable if it has no in-flight calls and does not own an active tool.
    private func isEvictable(_ id: UUID) async -> Bool {
        if let lim = callLimiters[id], await lim.activeCount() > 0 { return false }
        if activeToolOwnerByWindow.values.contains(id) { return false }
        return true
    }

    private struct EvictionCandidate {
        let id: UUID
        let clientID: String
        let everCalled: Bool
        let totalCalls: Int
        let idleSeconds: TimeInterval
        let createdAt: Date
    }

    private func makeCandidate(for id: UUID) async -> EvictionCandidate? {
        guard let clientID = clientIDByConnection[id], let mgr = connections[id] else { return nil }
        let stats = connectionStats[id]

        // If not viable, force to the front by giving infinite idle
        let viable = await mgr.isViableForRetention()
        if !viable {
            return EvictionCandidate(
                id: id,
                clientID: clientID,
                everCalled: (stats?.totalToolCalls ?? 0) > 0,
                totalCalls: stats?.totalToolCalls ?? 0,
                idleSeconds: .infinity,
                createdAt: stats?.createdAt ?? Date.distantPast
            )
        }

        let idle = await mgr.secondsSinceLastActivity()
        return EvictionCandidate(
            id: id,
            clientID: clientID,
            everCalled: (stats?.totalToolCalls ?? 0) > 0,
            totalCalls: stats?.totalToolCalls ?? 0,
            idleSeconds: idle,
            createdAt: stats?.createdAt ?? Date.distantPast
        )
    }

    /// Sort ascending by value (least valuable first)
    private func isLessValuable(_ a: EvictionCandidate, than b: EvictionCandidate) -> Bool {
        if a.everCalled != b.everCalled { return a.everCalled == false }
        if a.idleSeconds != b.idleSeconds { return a.idleSeconds > b.idleSeconds }
        if a.totalCalls != b.totalCalls { return a.totalCalls < b.totalCalls }
        return a.createdAt < b.createdAt
    }

    /// Evict least valuable eligible connection for this client.
    private func evictLeastValuable(for clientID: String) async -> Bool {
        guard let set = activeConnectionsByClient[clientID], !set.isEmpty else { return false }
        var candidates: [EvictionCandidate] = []
        for id in set {
            guard await isEvictable(id) else { continue }
            if let c = await makeCandidate(for: id) { candidates.append(c) }
        }
        guard let victim = candidates.sorted(by: isLessValuable).first else { return false }
        log.warning("Per-client eviction: evicting \(victim.id) for client \(clientID) to admit a new connection.")
        await removeConnection(victim.id)
        return true
    }

    /// Evict least valuable eligible connection across all clients.
    private func evictLeastValuableGlobalForAdmission(preserveOnePerClient: Bool) async -> Bool {
        var countsByClient: [String: Int] = [:]
        for (cid, set) in activeConnectionsByClient {
            countsByClient[cid] = set.count
        }

        var candidates: [EvictionCandidate] = []
        for (id, _) in connections {
            guard await isEvictable(id) else { continue }
            if preserveOnePerClient, let cid = clientIDByConnection[id], (countsByClient[cid] ?? 0) <= 1 {
                continue
            }
            if let c = await makeCandidate(for: id) { candidates.append(c) }
        }

        if candidates.isEmpty, preserveOnePerClient {
            var anyHasMoreThanOne = false
            for (_, cnt) in countsByClient {
                if cnt > 1 { anyHasMoreThanOne = true
                    break
                }
            }
            if !anyHasMoreThanOne {
                return await evictLeastValuableGlobalForAdmission(preserveOnePerClient: false)
            }
        }

        guard let victim = candidates.sorted(by: isLessValuable).first else { return false }
        log.warning("Global eviction: evicting \(victim.id) (client \(victim.clientID)) to admit a new connection.")
        await removeConnection(victim.id)
        return true
    }
}

/// Simple async semaphore (backpressure per connection)
actor AsyncLimiter {
    private let limit: Int
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Tracks the number of tasks currently inside withPermit (including queued ones)
    private var inFlight: Int = 0

    init(limit: Int) {
        self.limit = max(1, limit)
        permits = max(1, limit)
    }

    /// Acquires a permit, waiting if none are available.
    private func acquirePermit() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // When resumed, the caller now has a permit (recycled from a release)
    }

    /// Releases a permit, resuming a waiter if any are queued.
    private func releasePermit() {
        if !waiters.isEmpty {
            let c = waiters.removeFirst()
            c.resume()
            // No permit count change: we just hand the freed permit to the next waiter
        } else {
            permits = min(permits + 1, limit)
        }
    }

    /// Number of in-flight operations (0 means idle).
    /// This counts all tasks inside withPermit, including those waiting for a permit.
    func activeCount() -> Int {
        inFlight
    }

    /// Executes an operation with a permit, limiting concurrency.
    func withPermit<T>(
        _ op: @Sendable () async throws -> T
    ) async rethrows -> T {
        inFlight += 1
        defer { inFlight -= 1 }
        await acquirePermit()
        defer { releasePermit() }
        return try await op()
    }
}
