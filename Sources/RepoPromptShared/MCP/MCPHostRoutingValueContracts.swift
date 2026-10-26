import Foundation

/// Summary info for a workspace across the app.
/// Returned by manage_workspaces with action == "list".
public struct MCPWorkspaceSummary: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    /// Total number of root folders in this workspace
    public let rootCount: Int
    /// First 3 root folder paths (full paths for context)
    public let repoPaths: [String]
    /// Window IDs currently showing this workspace (active in those windows)
    public let showingWindowIDs: [Int]
    /// True when this workspace is recoverable but hidden from default menus/lists.
    public let isHidden: Bool

    public init(id: UUID, name: String, allRepoPaths: [String], showingWindowIDs: [Int], isHidden: Bool = false) {
        self.id = id
        self.name = name
        rootCount = allRepoPaths.count
        // Include first 3 paths for preview
        repoPaths = Array(allRepoPaths.prefix(3))
        self.showingWindowIDs = showingWindowIDs
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case rootCount = "root_count"
        case repoPaths = "repo_paths"
        case showingWindowIDs = "showing_window_ids"
        case isHidden = "is_hidden"
    }
}

/// Summary info for a compose tab.
/// Returned by manage_workspaces tab lifecycle actions.
public struct MCPComposeTabSummary: Codable, Hashable, Sendable {
    public let id: UUID
    public let contextID: UUID
    public let name: String
    public let workspaceID: UUID
    public let workspaceName: String
    public let windowID: Int
    public let isActive: Bool // active tab in that window's workspace
    public let isBoundForClient: Bool // is this tab currently bound for the calling connection
    public let totalFileCount: Int // total unique files in selection
    public let sampleFileNames: [String] // up to 3 sample file names (basename only)

    public init(
        id: UUID,
        contextID: UUID? = nil,
        name: String,
        workspaceID: UUID,
        workspaceName: String,
        windowID: Int,
        isActive: Bool,
        isBoundForClient: Bool,
        totalFileCount: Int,
        sampleFileNames: [String]
    ) {
        self.id = id
        self.contextID = contextID ?? id
        self.name = name
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.windowID = windowID
        self.isActive = isActive
        self.isBoundForClient = isBoundForClient
        self.totalFileCount = totalFileCount
        self.sampleFileNames = sampleFileNames
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case contextID = "context_id"
        case name
        case workspaceID = "workspace_id"
        case workspaceName = "workspace_name"
        case windowID = "window_id"
        case isActive = "is_active"
        case isBoundForClient = "is_bound_for_client"
        case totalFileCount = "total_file_count"
        case sampleFileNames = "sample_file_names"
    }
}

/// Unified response for the manage_workspaces tool.
public struct ManageWorkspacesResponse: Codable, Sendable {
    public let action: String
    public let workspaces: [MCPWorkspaceSummary]?
    public let tabs: [MCPComposeTabSummary]? // For create_tab / close_tab actions
    public let status: String?
    public let windowID: Int? // For switch/create with open_in_new_window
    public let closedWindowID: Int? // For delete with close_window

    public init(
        action: String,
        workspaces: [MCPWorkspaceSummary]?,
        tabs: [MCPComposeTabSummary]? = nil,
        status: String?,
        windowID: Int? = nil,
        closedWindowID: Int? = nil
    ) {
        self.action = action
        self.workspaces = workspaces
        self.tabs = tabs
        self.status = status
        self.windowID = windowID
        self.closedWindowID = closedWindowID
    }

    private enum CodingKeys: String, CodingKey {
        case action, workspaces, tabs, status
        case windowID = "window_id"
        case closedWindowID = "closed_window_id"
    }
}

public struct MCPBindContextWorkspaceSummary: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String

    package init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MCPBindContextTabSummary: Codable, Hashable, Sendable {
    public let contextID: UUID
    public let name: String
    public let workspaceID: UUID
    public let workspaceName: String
    public let isActive: Bool
    public let isBound: Bool
    public let repoPaths: [String]

    package init(
        contextID: UUID,
        name: String,
        workspaceID: UUID,
        workspaceName: String,
        isActive: Bool,
        isBound: Bool,
        repoPaths: [String]
    ) {
        self.contextID = contextID
        self.name = name
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.isActive = isActive
        self.isBound = isBound
        self.repoPaths = repoPaths
    }

    private enum CodingKeys: String, CodingKey {
        case contextID = "context_id"
        case name
        case workspaceID = "workspace_id"
        case workspaceName = "workspace_name"
        case isActive = "is_active"
        case isBound = "is_bound"
        case repoPaths = "repo_paths"
    }
}

public struct MCPBindContextWindowSummary: Codable, Hashable, Sendable {
    public let windowID: Int
    public let isCurrentWindow: Bool
    public let workspace: MCPBindContextWorkspaceSummary?
    public let activeContextID: UUID?
    public let tabs: [MCPBindContextTabSummary]

    package init(
        windowID: Int,
        isCurrentWindow: Bool,
        workspace: MCPBindContextWorkspaceSummary?,
        activeContextID: UUID?,
        tabs: [MCPBindContextTabSummary]
    ) {
        self.windowID = windowID
        self.isCurrentWindow = isCurrentWindow
        self.workspace = workspace
        self.activeContextID = activeContextID
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case isCurrentWindow = "is_current_window"
        case workspace
        case activeContextID = "active_context_id"
        case tabs
    }
}

public struct MCPBindContextBindingSummary: Codable, Equatable, Sendable {
    public let bindingKind: String
    public let windowID: Int?
    public let contextID: UUID?
    public let workspaceID: UUID?
    public let workspaceName: String?
    public let tabName: String?
    public let repoPaths: [String]
    public let explicit: Bool
    public let runScoped: Bool

    package init(
        bindingKind: String,
        windowID: Int?,
        contextID: UUID?,
        workspaceID: UUID?,
        workspaceName: String?,
        tabName: String?,
        repoPaths: [String],
        explicit: Bool,
        runScoped: Bool
    ) {
        self.bindingKind = bindingKind
        self.windowID = windowID
        self.contextID = contextID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.tabName = tabName
        self.repoPaths = repoPaths
        self.explicit = explicit
        self.runScoped = runScoped
    }

    private enum CodingKeys: String, CodingKey {
        case bindingKind = "binding_kind"
        case windowID = "window_id"
        case contextID = "context_id"
        case workspaceID = "workspace_id"
        case workspaceName = "workspace_name"
        case tabName = "tab_name"
        case repoPaths = "repo_paths"
        case explicit
        case runScoped = "run_scoped"
    }
}

public struct BindContextResponse: Codable, Sendable {
    public let windows: [MCPBindContextWindowSummary]?
    public let binding: MCPBindContextBindingSummary
    public let changed: Bool?
    public let previousBinding: MCPBindContextBindingSummary?
    public let matchedBy: String?
    public let createdTab: Bool?
    public let createdWorkspace: Bool?
    public let normalizedWorkingDirs: [String]?
    public let note: String?
    public let error: String?
    public let errorCode: String?
    public let retryable: Bool?
    public let retryAfterMilliseconds: Int?

    private enum CodingKeys: String, CodingKey {
        case windows
        case binding
        case changed
        case previousBinding = "previous_binding"
        case matchedBy = "matched_by"
        case createdTab = "created_tab"
        case createdWorkspace = "created_workspace"
        case normalizedWorkingDirs = "normalized_working_dirs"
        case note
        case error
        case errorCode = "error_code"
        case retryable
        case retryAfterMilliseconds = "retry_after_ms"
    }

    public init(
        windows: [MCPBindContextWindowSummary]? = nil,
        binding: MCPBindContextBindingSummary,
        changed: Bool? = nil,
        previousBinding: MCPBindContextBindingSummary? = nil,
        matchedBy: String? = nil,
        createdTab: Bool? = nil,
        createdWorkspace: Bool? = nil,
        normalizedWorkingDirs: [String]? = nil,
        note: String? = nil,
        error: String? = nil,
        errorCode: String? = nil,
        retryable: Bool? = nil,
        retryAfterMilliseconds: Int? = nil
    ) {
        self.windows = windows
        self.binding = binding
        self.changed = changed
        self.previousBinding = previousBinding
        self.matchedBy = matchedBy
        self.createdTab = createdTab
        self.createdWorkspace = createdWorkspace
        self.normalizedWorkingDirs = normalizedWorkingDirs
        self.note = note
        self.error = error
        self.errorCode = errorCode
        self.retryable = retryable
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }
}

/// One-shot, admitted routing evidence; never a lookup of the current presentation tab.
package struct MCPTabContextHint: Equatable {
    package let tabID: UUID
    package let workspaceID: UUID?
    package let windowID: Int?

    package init(tabID: UUID, workspaceID: UUID?, windowID: Int?) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.windowID = windowID
    }
}

package struct MCPRequestMetadata {
    package let connectionID: UUID?
    package let clientName: String?
    package let windowID: Int?
    package let runPurpose: MCPRunPurpose?
    package let tabContextHint: MCPTabContextHint?
    package let explicitWindowRoutingHint: MCPExplicitWindowRoutingHint?
    package let invocationID: UUID?
    package let requestID: JSONRPCBridgeID?

    package init(
        connectionID: UUID?,
        clientName: String?,
        windowID: Int?,
        runPurpose: MCPRunPurpose? = nil,
        tabContextHint: MCPTabContextHint? = nil,
        explicitWindowRoutingHint: MCPExplicitWindowRoutingHint? = nil,
        invocationID: UUID? = nil,
        requestID: JSONRPCBridgeID? = nil
    ) {
        self.connectionID = connectionID
        self.clientName = clientName
        self.windowID = windowID
        self.runPurpose = runPurpose
        self.tabContextHint = tabContextHint
        self.explicitWindowRoutingHint = explicitWindowRoutingHint
        self.invocationID = invocationID
        self.requestID = requestID
    }
}

package struct MCPConnectionBindingSnapshot: Equatable {
    package enum BindingKind: Equatable {
        case unbound
        case tabContext
    }

    package let windowID: Int?
    package let tabID: UUID?
    package let workspaceID: UUID?
    package let workspaceName: String?
    package let tabName: String?
    package let repoPaths: [String]
    package let explicitlyBound: Bool
    package let runID: UUID?

    package init(
        windowID: Int?,
        tabID: UUID?,
        workspaceID: UUID?,
        workspaceName: String?,
        tabName: String?,
        repoPaths: [String],
        explicitlyBound: Bool,
        runID: UUID?
    ) {
        self.windowID = windowID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.tabName = tabName
        self.repoPaths = repoPaths
        self.explicitlyBound = explicitlyBound
        self.runID = runID
    }

    package var bindingKind: BindingKind {
        tabID == nil ? .unbound : .tabContext
    }
}

package enum MCPTabContextSnapshotSource: String, Equatable {
    case explicitBinding
    case runInstall
    case runHandover
    case pendingRunScoped
    case explicitHint
}

/// Purpose of an MCP connection's run, used to route UI (e.g., ask_user) to the correct surface.
public enum MCPRunPurpose: String, Sendable, Codable {
    case discoverRun // Context Builder agent exploring codebase
    case agentModeRun // Agent mode interactive session
    case unknown // No policy or unspecified
}

/// Dispatcher-validated provenance for a one-shot hidden `_windowID` tool argument.
/// This value is request-scoped only and must never be synthesized from sticky,
/// persisted, or automatically selected window affinity.
package struct MCPExplicitWindowRoutingHint: @unchecked Sendable, Equatable {
    package enum Provenance: Equatable {
        case hiddenWindowArgument
    }

    package let connectionID: UUID
    package let toolName: String
    package let windowID: Int
    package let windowStateIdentity: ObjectIdentifier
    package let serverViewModelIdentity: ObjectIdentifier
    package let provenance: Provenance

    package init(
        connectionID: UUID,
        toolName: String,
        windowID: Int,
        windowStateIdentity: ObjectIdentifier,
        serverViewModelIdentity: ObjectIdentifier,
        provenance: Provenance
    ) {
        self.connectionID = connectionID
        self.toolName = toolName
        self.windowID = windowID
        self.windowStateIdentity = windowStateIdentity
        self.serverViewModelIdentity = serverViewModelIdentity
        self.provenance = provenance
    }
}

package struct MCPBindContextRequest: Equatable {
    package enum Operation: String {
        case list
        case status
        case bind
    }

    package enum MatchKind: String {
        case contextID = "context_id"
        case workingDirs = "working_dirs"
        case windowID = "window_id"
    }

    package let op: Operation
    package let contextID: UUID?
    package let workingDirs: [String]
    package let windowID: Int?
    package let createIfMissing: Bool
    package let tabName: String?

    package init(
        op: Operation,
        contextID: UUID?,
        workingDirs: [String],
        windowID: Int?,
        createIfMissing: Bool,
        tabName: String?
    ) {
        self.op = op
        self.contextID = contextID
        self.workingDirs = workingDirs
        self.windowID = windowID
        self.createIfMissing = createIfMissing
        self.tabName = tabName
    }

    package var matchKind: MatchKind? {
        if contextID != nil { return .contextID }
        if !workingDirs.isEmpty { return .workingDirs }
        if windowID != nil { return .windowID }
        return nil
    }
}

package struct MCPWorkingDirsBindResolution {
    package let windowID: Int
    package let workspaceID: UUID
    package let workspaceName: String
    package let repoPaths: [String]
    package let matchedBy: String
    package let createdWorkspace: Bool
    package let normalizedWorkingDirs: [String]

    package init(
        windowID: Int,
        workspaceID: UUID,
        workspaceName: String,
        repoPaths: [String],
        matchedBy: String,
        createdWorkspace: Bool,
        normalizedWorkingDirs: [String]
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.repoPaths = repoPaths
        self.matchedBy = matchedBy
        self.createdWorkspace = createdWorkspace
        self.normalizedWorkingDirs = normalizedWorkingDirs
    }
}

package enum MCPWorkingDirsWorkspaceMatchKind: Equatable {
    case exact
    case superset

    package var isSupersetFallback: Bool {
        self == .superset
    }

    package var matchedByDescription: String {
        switch self {
        case .exact:
            "working_dirs"
        case .superset:
            "working_dirs (matched by workspace repo_paths superset)"
        }
    }

    package var ambiguityDescription: String {
        switch self {
        case .exact:
            "exactly matched"
        case .superset:
            "matched by workspace repo_paths superset"
        }
    }

    package var ambiguityGuidanceSubject: String {
        switch self {
        case .exact:
            "exact matching workspaces"
        case .superset:
            "superset matching workspaces"
        }
    }
}
