import Foundation
import JSONSchema
import MCP
import Ontology
import SwiftUI

#if DEBUG
    private func routingLog(_ message: @autoclosure () -> String) {
        // print("[WindowRouting] \(message())")
    }
#else
    private func routingLog(_ message: @autoclosure () -> String) {}
#endif

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
}

public struct MCPBindContextTabSummary: Codable, Hashable, Sendable {
    public let contextID: UUID
    public let name: String
    public let workspaceID: UUID
    public let workspaceName: String
    public let isActive: Bool
    public let isBound: Bool
    public let repoPaths: [String]

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
        note: String? = nil
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
    }
}

// Global service exposing bind_context and workspace/tab lifecycle helpers.
//
// # Tools
// • bind_context      – list, inspect, and bind sticky window/tab context.
// • manage_workspaces – manage workspaces and compose-tab lifecycle across windows.
//
// # Hidden Parameter Semantics
// All MCP tools support hidden routing parameters that are extracted and stripped
// before the tool receives its arguments. These parameters control window and tab
// routing for the call:
//
// ## `_windowID` (Int)
// Explicit per-call window override. When provided:
// - Always takes precedence over existing connection→window mappings
// - Updates the connection's preferred window for future calls
// - Returns an error if the window doesn't exist or has MCP disabled
//
// ## `_tabID` (UUID)
// Binds the connection to a specific compose tab:
// - Evaluated after the final window is determined
// - Tab must exist in the target window's active workspace
// - Returns detailed error if tab not found, including window context
// - Persists for subsequent calls until explicitly changed
//
// # Routing Priority Order
// 1. `_windowID` (explicit override)
// 2. Existing connection→window mapping
// 3. Client name reuse (same client, different connection)
// 4. Persisted routing (token-backed sessions)
// 5. Auto-route to active window (single-window mode)

/// Simple actor for thread-safe tools storage
private actor ToolsCache {
    private var tools: [Tool] = []

    func update(_ newTools: [Tool]) {
        tools = newTools
    }

    func get() -> [Tool] {
        #if DEBUG || EDIT_FLOW_PERF
            let actorBodyState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowRoutingToolsCacheActorBody)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowRoutingToolsCacheActorBody, actorBodyState) }
        #endif
        return tools
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

@MainActor
final class WindowRoutingService: Service {
    nonisolated static func validateAddFolderWorkspace(_ workspace: WorkspaceModel) throws {
        guard workspace.isSystemWorkspace == false else {
            throw MCPError.invalidParams("Cannot add folders to system workspace '\(workspace.name)'. Create or switch to a regular workspace first.")
        }
    }

    nonisolated static func workspaceDeleteCloseAuthorization() -> WindowCloseAuthorization {
        WindowCloseAuthorization(
            source: .workspaceDelete,
            bypassConfirmation: true,
            bypassBackgroundPreservation: true
        )
    }

    nonisolated static func shouldBindConnectionAfterStandardWorkspaceSwitch(explicitWindowIDProvided: Bool) -> Bool {
        explicitWindowIDProvided
    }

    // ---------------------------------------------------------------------
    // MARK: Stored references

    // ---------------------------------------------------------------------
    private let windowStates: WindowStatesManager
    private let networkMgr: ServerNetworkManager
    private var previousDisabledTools: Set<String>

    /// Thread-safe tools storage
    private let toolsCache = ToolsCache()

    // NotificationCenter observer tokens for cleanup
    private var userDefaultsObserver: NSObjectProtocol?
    private var windowCountObserver: NSObjectProtocol?

    // ---------------------------------------------------------------------
    // MARK: Init & registration

    /// ---------------------------------------------------------------------
    init(
        windowStates: WindowStatesManager,
        networkMgr: ServerNetworkManager
    ) {
        self.windowStates = windowStates
        self.networkMgr = networkMgr
        previousDisabledTools = Set(UserDefaults.standard.stringArray(forKey: "mcp.disabledTools") ?? [])

        // Initialize cached tools and register service
        Task {
            await updateCachedTools()

            // Register only after tools are cached
            ServiceRegistry.register(self)
        }

        // Listen for changes to relevant MCP settings
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                let currentDisabledTools = Set(UserDefaults.standard.stringArray(forKey: "mcp.disabledTools") ?? [])

                guard currentDisabledTools != self.previousDisabledTools else { return }
                self.previousDisabledTools = currentDisabledTools

                let previousTools = await self.tools
                let previousToolNames = Set(previousTools.map(\.name))

                await self.updateCachedTools()

                let newTools = await self.tools
                let newToolNames = Set(newTools.map(\.name))

                let addedTools = newTools.filter { !previousToolNames.contains($0.name) }
                if !addedTools.isEmpty {
                    ToolAvailabilityStore.shared.registerTools(addedTools)
                }

                let removedToolNames = previousToolNames.subtracting(newToolNames)
                if !removedToolNames.isEmpty {
                    ToolAvailabilityStore.shared.unregisterTools(Array(removedToolNames))
                }

                await networkMgr.broadcastToolListChanged()
            }
        }

        // Listen for window count changes
        windowCountObserver = NotificationCenter.default.addObserver(
            forName: .windowCountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                let previousTools = await self.tools
                let previousToolNames = Set(previousTools.map(\.name))

                // Update cached tools based on new window count
                await self.updateCachedTools()

                // Update tool availability store
                let newTools = await self.tools
                let newToolNames = Set(newTools.map(\.name))

                // Register newly available tools
                let addedTools = newTools.filter { !previousToolNames.contains($0.name) }
                if !addedTools.isEmpty {
                    ToolAvailabilityStore.shared.registerTools(addedTools)
                }

                // Unregister tools that are no longer available
                let removedToolNames = previousToolNames.subtracting(newToolNames)
                if !removedToolNames.isEmpty {
                    ToolAvailabilityStore.shared.unregisterTools(Array(removedToolNames))
                }

                // Notify connected clients that the tool list has changed
                await networkMgr.broadcastToolListChanged()
            }
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Cleanup

    /// ---------------------------------------------------------------------
    deinit {
        // Remove NotificationCenter observers to prevent crashes
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowCountObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Workspace Resolution Helpers

    // ---------------------------------------------------------------------

    private enum WorkspaceReferenceMode {
        case visibleNameByDefault(action: String, includeHidden: Bool)
        case hide
        case unhide
    }

    private func loadWorkspaceDiskSnapshot() async throws -> [WorkspaceModel] {
        guard let referenceManager = await MainActor.run(body: {
            self.windowStates.allWindows.first?.workspaceManager
        }) else {
            throw MCPError.invalidParams("No windows available to load workspace list. Open at least one window first.")
        }
        return await referenceManager.loadWorkspaceSnapshotFromDisk()
    }

    private nonisolated static func availableWorkspaceSuggestion(_ workspaces: [WorkspaceModel], includeHidden: Bool) -> String {
        let availableNames = workspaces
            .filter { !$0.isSystemWorkspace && (includeHidden || !$0.isHiddenInMenus) }
            .map { workspace in
                workspace.isHiddenInMenus ? "\(workspace.name) (hidden)" : workspace.name
            }
            .sorted()
        return availableNames.isEmpty
            ? "No workspaces exist. Use action 'create' to create one."
            : "Available workspaces: \(availableNames.joined(separator: ", "))"
    }

    private nonisolated static func ambiguousWorkspaceMessage(name: String, matches: [WorkspaceModel]) -> String {
        let ids = matches
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.name) (\($0.id.uuidString)\($0.isHiddenInMenus ? ", hidden" : ""))" }
            .joined(separator: ", ")
        return "Workspace name '\(name)' matches multiple workspaces: \(ids). Use a workspace UUID."
    }

    private nonisolated static func resolveWorkspaceReference(
        _ rawWorkspaceParam: String,
        in diskWorkspaces: [WorkspaceModel],
        mode: WorkspaceReferenceMode
    ) throws -> WorkspaceModel {
        if let targetID = UUID(uuidString: rawWorkspaceParam) {
            if let found = diskWorkspaces.first(where: { $0.id == targetID }) {
                return found
            }
            throw MCPError.invalidParams("Unknown workspace id '\(rawWorkspaceParam)'")
        }

        let name = rawWorkspaceParam
        let nameMatches = diskWorkspaces.filter { $0.name == name }
        let visibleMatches = nameMatches.filter { !$0.isHiddenInMenus }
        let hiddenMatches = nameMatches.filter(\.isHiddenInMenus)

        switch mode {
        case let .visibleNameByDefault(action, includeHidden):
            if includeHidden {
                guard nameMatches.count != 1 else { return nameMatches[0] }
                if nameMatches.count > 1 {
                    throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: nameMatches))
                }
            } else {
                if visibleMatches.count == 1 {
                    return visibleMatches[0]
                }
                if visibleMatches.count > 1 {
                    throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: visibleMatches))
                }
                if !hiddenMatches.isEmpty {
                    throw MCPError.invalidParams("Workspace '\(name)' is hidden and is excluded from name-based \(action) by default. Use include_hidden=true or address it by UUID.")
                }
            }
            throw MCPError.invalidParams("Unknown workspace name '\(name)'. \(availableWorkspaceSuggestion(diskWorkspaces, includeHidden: includeHidden))")

        case .hide:
            if visibleMatches.count == 1 { return visibleMatches[0] }
            if visibleMatches.count > 1 {
                throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: visibleMatches))
            }
            if hiddenMatches.count == 1 { return hiddenMatches[0] }
            if hiddenMatches.count > 1 {
                throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: hiddenMatches))
            }
            throw MCPError.invalidParams("Unknown workspace name '\(name)'. \(availableWorkspaceSuggestion(diskWorkspaces, includeHidden: true))")

        case .unhide:
            guard nameMatches.count != 1 else { return nameMatches[0] }
            if nameMatches.count > 1 {
                throw MCPError.invalidParams(ambiguousWorkspaceMessage(name: name, matches: nameMatches))
            }
            throw MCPError.invalidParams("Unknown workspace name '\(name)'. \(availableWorkspaceSuggestion(diskWorkspaces, includeHidden: true))")
        }
    }

    private func resolveWorkspaceForSwitch(rawWorkspaceParam: String, includeHidden: Bool) async throws -> WorkspaceModel {
        let diskWorkspaces = try await loadWorkspaceDiskSnapshot()
        return try Self.resolveWorkspaceReference(
            rawWorkspaceParam,
            in: diskWorkspaces,
            mode: .visibleNameByDefault(action: "switch", includeHidden: includeHidden)
        )
    }

    private func resolveWorkspaceForDelete(rawWorkspaceParam: String, includeHidden: Bool) async throws -> WorkspaceModel {
        let diskWorkspaces = try await loadWorkspaceDiskSnapshot()
        return try Self.resolveWorkspaceReference(
            rawWorkspaceParam,
            in: diskWorkspaces,
            mode: .visibleNameByDefault(action: "delete", includeHidden: includeHidden)
        )
    }

    private func resolveWorkspaceForHiddenMutation(rawWorkspaceParam: String, hidden: Bool) async throws -> WorkspaceModel {
        let diskWorkspaces = try await loadWorkspaceDiskSnapshot()
        return try Self.resolveWorkspaceReference(
            rawWorkspaceParam,
            in: diskWorkspaces,
            mode: hidden ? .hide : .unhide
        )
    }

    nonisolated static func test_resolveWorkspaceReference(
        _ rawWorkspaceParam: String,
        workspaces: [WorkspaceModel],
        includeHiddenForName: Bool,
        action: String = "switch"
    ) throws -> WorkspaceModel {
        try resolveWorkspaceReference(
            rawWorkspaceParam,
            in: workspaces,
            mode: .visibleNameByDefault(action: action, includeHidden: includeHiddenForName)
        )
    }

    nonisolated static func test_resolveWorkspaceHiddenMutationReference(
        _ rawWorkspaceParam: String,
        workspaces: [WorkspaceModel],
        hidden: Bool
    ) throws -> WorkspaceModel {
        try resolveWorkspaceReference(
            rawWorkspaceParam,
            in: workspaces,
            mode: hidden ? .hide : .unhide
        )
    }

    private func resolveTargetWindow(windowID: Int?) async throws -> WindowState {
        let windows = await MainActor.run { self.windowStates.allWindows }
        let targetWindow: WindowState? = {
            if let windowID {
                return windows.first(where: { $0.windowID == windowID })
            }
            return windows.only
        }()

        if let windowID, targetWindow == nil {
            let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
            throw MCPError.invalidParams("Unknown window_id \(windowID). Valid window IDs: \(validIDs)")
        }
        if windowID == nil, windows.count != 1 {
            throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
        }
        guard let targetWindow else {
            throw MCPError.invalidParams("No valid target window found")
        }
        return targetWindow
    }

    private func resolveComposeTab(rawTabParam: String, tabs: [ComposeTabState]) throws -> ComposeTabState {
        if let tabID = UUID(uuidString: rawTabParam),
           let exactIDMatch = tabs.first(where: { $0.id == tabID })
        {
            return exactIDMatch
        }

        if let exact = tabs.first(where: { $0.name == rawTabParam }) {
            return exact
        }

        let lowerParam = rawTabParam.lowercased()
        let caseInsensitiveMatches = tabs.filter { $0.name.lowercased() == lowerParam }
        if caseInsensitiveMatches.count == 1, let match = caseInsensitiveMatches.first {
            return match
        }

        let prefixMatches = tabs.filter { $0.name.lowercased().hasPrefix(lowerParam) }
        if prefixMatches.count == 1, let match = prefixMatches.first {
            return match
        }

        let availableNames = tabs.map(\.name).joined(separator: ", ")
        throw MCPError.invalidParams("Unknown compose tab '\(rawTabParam)'. Available tabs: \(availableNames)")
    }

    private nonisolated static func parseContextID(_ value: Value?, action: String) throws -> UUID? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let contextID = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("Invalid context_id '\(raw)' for \(action). Expected a UUID.")
        }
        return contextID
    }

    private func resolveComposeTab(
        rawTabParam: String?,
        contextID: UUID?,
        tabs: [ComposeTabState],
        action: String
    ) throws -> ComposeTabState {
        if let contextID {
            if let rawTabParam, !rawTabParam.isEmpty {
                let tabFromRaw = try resolveComposeTab(rawTabParam: rawTabParam, tabs: tabs)
                guard tabFromRaw.id == contextID else {
                    throw MCPError.invalidParams("'tab' and 'context_id' target different compose tabs for '\(action)'.")
                }
                return tabFromRaw
            }

            guard let tab = tabs.first(where: { $0.id == contextID }) else {
                throw MCPError.invalidParams("Unknown compose tab context_id '\(contextID.uuidString)'.")
            }
            return tab
        }

        guard let rawTabParam, !rawTabParam.isEmpty else {
            throw MCPError.invalidParams("Missing required 'tab' or 'context_id' parameter for '\(action)' action.")
        }
        return try resolveComposeTab(rawTabParam: rawTabParam, tabs: tabs)
    }

    private func makeComposeTabSummary(
        tab: ComposeTabState,
        workspace: WorkspaceModel,
        windowID: Int,
        activeTabID: UUID?,
        boundTabID: UUID?
    ) -> MCPComposeTabSummary {
        let sel = tab.selection
        let sampleK = 3
        var allPaths = Set<String>()
        allPaths.reserveCapacity(sel.selectedPaths.count + sel.slices.count + sel.autoCodemapPaths.count)

        var samplePaths: [String] = []
        samplePaths.reserveCapacity(sampleK)

        @inline(__always)
        func considerForSample(_ path: String) {
            if samplePaths.count < sampleK {
                samplePaths.append(path)
                samplePaths.sort()
                return
            }
            guard let last = samplePaths.last, path < last else { return }
            let insertIndex = samplePaths.firstIndex(where: { path < $0 }) ?? samplePaths.count
            samplePaths.insert(path, at: insertIndex)
            samplePaths.removeLast()
        }

        for path in sel.selectedPaths where allPaths.insert(path).inserted {
            considerForSample(path)
        }
        for path in sel.slices.keys where allPaths.insert(path).inserted {
            considerForSample(path)
        }
        for path in sel.autoCodemapPaths where allPaths.insert(path).inserted {
            considerForSample(path)
        }

        let sampleNames = samplePaths.map { ($0 as NSString).lastPathComponent }
        return MCPComposeTabSummary(
            id: tab.id,
            contextID: tab.id,
            name: tab.name,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            windowID: windowID,
            isActive: activeTabID == tab.id,
            isBoundForClient: boundTabID == tab.id,
            totalFileCount: allPaths.count,
            sampleFileNames: sampleNames
        )
    }

    struct BindContextRequest: Equatable {
        enum Operation: String {
            case list
            case status
            case bind
        }

        enum MatchKind: String {
            case contextID = "context_id"
            case workingDirs = "working_dirs"
            case windowID = "window_id"
        }

        let op: Operation
        let contextID: UUID?
        let workingDirs: [String]
        let windowID: Int?
        let createIfMissing: Bool
        let tabName: String?

        var matchKind: MatchKind? {
            if contextID != nil { return .contextID }
            if !workingDirs.isEmpty { return .workingDirs }
            if windowID != nil { return .windowID }
            return nil
        }
    }

    private struct ResolvedBindTarget {
        let windowID: Int
        let workspaceID: UUID
        let workspaceName: String
        let tabID: UUID
        let tabName: String
        let repoPaths: [String]
        let matchedBy: String
        let createdTab: Bool
        let normalizedWorkingDirs: [String]?
    }

    private struct WorkingDirsBindResolution {
        let windowID: Int
        let workspaceID: UUID
        let workspaceName: String
        let repoPaths: [String]
        let matchedBy: String
        let createdWorkspace: Bool
        let normalizedWorkingDirs: [String]
    }

    private enum WorkingDirsWorkspaceMatchKind: Equatable {
        case exact
        case superset

        var isSupersetFallback: Bool {
            self == .superset
        }

        var matchedByDescription: String {
            switch self {
            case .exact:
                "working_dirs"
            case .superset:
                "working_dirs (matched by workspace repo_paths superset)"
            }
        }

        var ambiguityDescription: String {
            switch self {
            case .exact:
                "exactly matched"
            case .superset:
                "matched by workspace repo_paths superset"
            }
        }

        var ambiguityGuidanceSubject: String {
            switch self {
            case .exact:
                "exact matching workspaces"
            case .superset:
                "superset matching workspaces"
            }
        }
    }

    private struct ActiveWorkspaceWindowSnapshot {
        let windowID: Int
        let isFocused: Bool
        let workspace: WorkspaceModel
    }

    private struct WorkspaceMatch {
        let workspace: WorkspaceModel
        let showingWindowIDs: [Int]
        let kind: WorkingDirsWorkspaceMatchKind
        let normalizedRepoPaths: [String]
        let equivalentWorkspaceIDs: Set<UUID>
        let activeWorkspaceByWindowID: [Int: WorkspaceModel]

        init(
            workspace: WorkspaceModel,
            showingWindowIDs: [Int],
            kind: WorkingDirsWorkspaceMatchKind,
            normalizedRepoPaths: [String]? = nil,
            equivalentWorkspaceIDs: Set<UUID>? = nil,
            activeWorkspaceByWindowID: [Int: WorkspaceModel] = [:]
        ) {
            self.workspace = workspace
            self.showingWindowIDs = showingWindowIDs.sorted()
            self.kind = kind
            self.normalizedRepoPaths = normalizedRepoPaths ?? WorkspaceRootSetKey(paths: workspace.repoPaths).normalizedPaths
            self.equivalentWorkspaceIDs = equivalentWorkspaceIDs ?? [workspace.id]
            self.activeWorkspaceByWindowID = activeWorkspaceByWindowID
        }
    }

    private struct WorkingDirsMatchSelection {
        let match: WorkspaceMatch
        let disambiguatedByWindowID: Bool
    }

    private struct LogicalContextKey: Hashable {
        let workspaceID: UUID
        let tabID: UUID
    }

    private nonisolated static let bindContextWindowSelectionMessage = "Multiple windows open. Supply 'window_id' or call 'bind_context' first."

    private nonisolated static func normalizeBindingPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private nonisolated static func parseWorkingDirs(_ value: Value?) throws -> [String] {
        guard let value else { return [] }
        let rawItems: [String]
        switch value {
        case let .array(values):
            rawItems = values.compactMap(\.stringValue)
        case let .string(raw):
            rawItems = raw
                .split(separator: ",", omittingEmptySubsequences: true)
                .map(String.init)
        default:
            throw MCPError.invalidParams("working_dirs must be an array of strings or a comma-separated string.")
        }

        var seen = Set<String>()
        var normalized: [String] = []
        for rawItem in rawItems {
            let normalizedPath = Self.normalizeBindingPath(rawItem)
            guard !normalizedPath.isEmpty else { continue }
            if seen.insert(normalizedPath).inserted {
                normalized.append(normalizedPath)
            }
        }
        return normalized
    }

    nonisolated static func parseBindContextRequest(_ args: [String: Value]) throws -> BindContextRequest {
        guard let rawOperation = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let op = BindContextRequest.Operation(rawValue: rawOperation)
        else {
            throw MCPError.invalidParams("bind_context requires op='list', 'status', or 'bind'.")
        }

        let contextID = try parseContextID(args["context_id"], action: "bind_context")
        let workingDirs = try parseWorkingDirs(args["working_dirs"])
        let windowID = args["window_id"]?.intValue
        let createIfMissing = args["create_if_missing"]?.boolValue ?? false
        let tabName = args["tab_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        if op == .bind {
            if contextID != nil, !workingDirs.isEmpty {
                throw MCPError.invalidParams("bind_context op='bind' accepts exactly one primary selector: context_id, working_dirs, or window_id.")
            }
            if createIfMissing, workingDirs.isEmpty {
                throw MCPError.invalidParams("create_if_missing is only valid when binding by working_dirs.")
            }
            if tabName != nil, workingDirs.isEmpty || !createIfMissing {
                throw MCPError.invalidParams("tab_name is only valid when bind_context creates a blank tab via working_dirs + create_if_missing=true.")
            }
            let selectorCount = (contextID != nil ? 1 : 0) + (!workingDirs.isEmpty ? 1 : 0) + ((windowID != nil && contextID == nil && workingDirs.isEmpty) ? 1 : 0)
            guard selectorCount == 1 else {
                throw MCPError.invalidParams("bind_context op='bind' requires exactly one primary selector: context_id, working_dirs, or window_id.")
            }
        }

        return BindContextRequest(
            op: op,
            contextID: contextID,
            workingDirs: workingDirs,
            windowID: windowID,
            createIfMissing: createIfMissing,
            tabName: tabName
        )
    }

    private static func bindingKindString(_ kind: MCPServerViewModel.ConnectionBindingSnapshot.BindingKind) -> String {
        switch kind {
        case .tabContext:
            "tab_context"
        case .windowOnly:
            "window"
        case .unbound:
            "unbound"
        }
    }

    private static func unboundBindingSnapshot() -> MCPServerViewModel.ConnectionBindingSnapshot {
        MCPServerViewModel.ConnectionBindingSnapshot(
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

    private static func bindContextBindingSummary(from snapshot: MCPServerViewModel.ConnectionBindingSnapshot) -> MCPBindContextBindingSummary {
        MCPBindContextBindingSummary(
            bindingKind: bindingKindString(snapshot.bindingKind),
            windowID: snapshot.windowID,
            contextID: snapshot.tabID,
            workspaceID: snapshot.workspaceID,
            workspaceName: snapshot.workspaceName,
            tabName: snapshot.tabName,
            repoPaths: snapshot.repoPaths,
            explicit: snapshot.explicitlyBound,
            runScoped: snapshot.runID != nil
        )
    }

    private static func bindContextWorkspaceDisplayName(_ workspace: WorkspaceModel?) -> String? {
        guard let workspace else { return nil }
        return workspace.isSystemWorkspace ? "Default (no workspace loaded)" : workspace.name
    }

    private static func bindContextWorkspaceNote(windowID: Int, workspace: WorkspaceModel?) -> String? {
        guard let workspace, workspace.isSystemWorkspace else { return nil }
        return "Bound to window \(windowID) but no workspace is loaded. Use manage_workspaces action='switch' to load a workspace."
    }

    private func currentBindingSnapshot(for connectionID: UUID?) async -> MCPServerViewModel.ConnectionBindingSnapshot {
        guard let connectionID else {
            return Self.unboundBindingSnapshot()
        }

        let windows = windowStates.allWindows
        let snapshots = windows.map { ($0.windowID, $0.mcpServer.connectionBindingSnapshot(forConnection: connectionID)) }

        if let explicit = snapshots.first(where: { $0.1.bindingKind == .tabContext && $0.1.explicitlyBound && $0.1.runID == nil }) {
            return explicit.1
        }
        if let runScoped = snapshots.first(where: { $0.1.bindingKind == .tabContext && $0.1.runID != nil }) {
            return runScoped.1
        }
        if let context = snapshots.first(where: { $0.1.bindingKind == .tabContext }) {
            return context.1
        }

        if let selectedWindowID = await networkMgr.selectedWindow(for: connectionID),
           let selectedWindow = windows.first(where: { $0.windowID == selectedWindowID })
        {
            let workspace = selectedWindow.workspaceManager.activeWorkspace
            return MCPServerViewModel.ConnectionBindingSnapshot(
                windowID: selectedWindowID,
                tabID: nil,
                workspaceID: workspace?.id,
                workspaceName: Self.bindContextWorkspaceDisplayName(workspace),
                tabName: nil,
                repoPaths: workspace.map { WorkspaceManagerViewModel.loadableRepoPaths(for: $0) } ?? [],
                explicitlyBound: false,
                runID: nil
            )
        }

        return Self.unboundBindingSnapshot()
    }

    private func currentBindingSummary(for connectionID: UUID?) async -> MCPBindContextBindingSummary {
        await Self.bindContextBindingSummary(from: currentBindingSnapshot(for: connectionID))
    }

    private func bindContextWindowNote(windowID: Int?) -> String? {
        guard let windowID,
              let window = windowStates.allWindows.first(where: { $0.windowID == windowID }) else { return nil }
        return Self.bindContextWorkspaceNote(windowID: windowID, workspace: window.workspaceManager.activeWorkspace)
    }

    private nonisolated static func workspaceMatches(
        forNormalizedWorkingDirs normalizedWorkingDirs: [String],
        workspaces: [WorkspaceModel],
        kind: WorkingDirsWorkspaceMatchKind,
        includeHidden: Bool
    ) -> [WorkspaceModel] {
        switch kind {
        case .exact:
            WorkspaceManagerViewModel.exactWorkspaceMatches(
                forNormalizedWorkingDirs: normalizedWorkingDirs,
                workspaces: workspaces,
                includeHidden: includeHidden
            )
        case .superset:
            WorkspaceManagerViewModel.supersetWorkspaceMatches(
                forNormalizedWorkingDirs: normalizedWorkingDirs,
                workspaces: workspaces,
                includeHidden: includeHidden
            )
        }
    }

    private static func activeWorkspaceSnapshots(from windows: [WindowState]) -> [ActiveWorkspaceWindowSnapshot] {
        windows.compactMap { window in
            guard let workspace = window.workspaceManager.activeWorkspace else { return nil }
            return ActiveWorkspaceWindowSnapshot(
                windowID: window.windowID,
                isFocused: window.isCurrentlyFocused,
                workspace: workspace
            )
        }
    }

    private nonisolated static func workspaceSort(_ lhs: WorkspaceModel, _ rhs: WorkspaceModel) -> Bool {
        let lhsKey = lhs.name.lowercased()
        let rhsKey = rhs.name.lowercased()
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func preferredWorkspaceByRecencyAndName(_ lhs: WorkspaceModel, _ rhs: WorkspaceModel) -> Bool {
        if lhs.isHiddenInMenus != rhs.isHiddenInMenus {
            return !lhs.isHiddenInMenus
        }
        if lhs.lastUsed != rhs.lastUsed {
            return lhs.lastUsed > rhs.lastUsed
        }
        if lhs.dateModified != rhs.dateModified {
            return lhs.dateModified > rhs.dateModified
        }
        return workspaceSort(lhs, rhs)
    }

    private nonisolated static func canonicalWorkspace(
        for rootSetKey: WorkspaceRootSetKey,
        candidates: [WorkspaceModel],
        activeWindowSnapshots: [ActiveWorkspaceWindowSnapshot]
    ) -> WorkspaceModel? {
        let activeEquivalentSnapshots = activeWindowSnapshots
            .filter {
                !$0.workspace.isSystemWorkspace
                    && !$0.workspace.isEphemeral
                    && WorkspaceRootSetKey(paths: $0.workspace.repoPaths) == rootSetKey
            }
        if let focused = activeEquivalentSnapshots
            .filter(\.isFocused)
            .sorted(by: { $0.windowID < $1.windowID })
            .first
        {
            return focused.workspace
        }
        if let active = activeEquivalentSnapshots
            .sorted(by: { $0.windowID < $1.windowID })
            .first
        {
            return active.workspace
        }
        return candidates.sorted(by: preferredWorkspaceByRecencyAndName).first
    }

    private nonisolated static func collapsedWorkspaceMatches(
        normalizedWorkingDirs: [String],
        kind: WorkingDirsWorkspaceMatchKind,
        diskWorkspaces: [WorkspaceModel],
        activeWindowSnapshots: [ActiveWorkspaceWindowSnapshot],
        includeActiveWindowWorkspaces: Bool,
        includeHidden: Bool
    ) -> [WorkspaceMatch] {
        var groupedCandidates: [WorkspaceRootSetKey: [UUID: WorkspaceModel]] = [:]
        for workspace in workspaceMatches(forNormalizedWorkingDirs: normalizedWorkingDirs, workspaces: diskWorkspaces, kind: kind, includeHidden: includeHidden) {
            let key = WorkspaceRootSetKey(paths: workspace.repoPaths)
            guard !key.isEmpty else { continue }
            groupedCandidates[key, default: [:]][workspace.id] = workspace
        }

        let reusableActiveSnapshots = activeWindowSnapshots.filter { snapshot in
            !snapshot.workspace.isSystemWorkspace
                && !snapshot.workspace.isEphemeral
                && (includeHidden || !snapshot.workspace.isHiddenInMenus)
        }

        if includeActiveWindowWorkspaces {
            for snapshot in reusableActiveSnapshots {
                let activeWorkspace = snapshot.workspace
                guard workspaceMatches(forNormalizedWorkingDirs: normalizedWorkingDirs, workspaces: [activeWorkspace], kind: kind, includeHidden: includeHidden).contains(where: { $0.id == activeWorkspace.id }) else {
                    continue
                }
                let key = WorkspaceRootSetKey(paths: activeWorkspace.repoPaths)
                guard !key.isEmpty else { continue }
                groupedCandidates[key, default: [:]][activeWorkspace.id] = activeWorkspace
            }
        }

        return groupedCandidates.compactMap { key, candidatesByID -> WorkspaceMatch? in
            let candidates = Array(candidatesByID.values)
            guard !candidates.isEmpty,
                  let representative = canonicalWorkspace(
                      for: key,
                      candidates: candidates,
                      activeWindowSnapshots: reusableActiveSnapshots
                  ) else { return nil }
            let activeWorkspaceByWindowID = Dictionary(uniqueKeysWithValues: reusableActiveSnapshots.compactMap { snapshot -> (Int, WorkspaceModel)? in
                guard WorkspaceRootSetKey(paths: snapshot.workspace.repoPaths) == key else { return nil }
                return (snapshot.windowID, snapshot.workspace)
            })
            let equivalentWorkspaceIDs = Set(candidates.map(\.id)).union(activeWorkspaceByWindowID.values.map(\.id))
            return WorkspaceMatch(
                workspace: representative,
                showingWindowIDs: Array(activeWorkspaceByWindowID.keys).sorted(),
                kind: kind,
                normalizedRepoPaths: key.normalizedPaths,
                equivalentWorkspaceIDs: equivalentWorkspaceIDs,
                activeWorkspaceByWindowID: activeWorkspaceByWindowID
            )
        }.sorted { lhs, rhs in
            workspaceSort(lhs.workspace, rhs.workspace)
        }
    }

    private func workspaceMatchesFromDisk(
        normalizedWorkingDirs: [String],
        kind: WorkingDirsWorkspaceMatchKind
    ) async throws -> [WorkspaceMatch] {
        let windows = windowStates.allWindows
        guard let inventoryWindow = windows.first else {
            throw MCPError.invalidParams("No windows available to load workspace list. Open at least one window first.")
        }
        let activeWindowSnapshots = Self.activeWorkspaceSnapshots(from: windows)
        let diskWorkspaces = await inventoryWindow.workspaceManager.loadWorkspaceSnapshotFromDisk()
        return Self.collapsedWorkspaceMatches(
            normalizedWorkingDirs: normalizedWorkingDirs,
            kind: kind,
            diskWorkspaces: diskWorkspaces,
            activeWindowSnapshots: activeWindowSnapshots,
            includeActiveWindowWorkspaces: false,
            includeHidden: false
        )
    }

    private func workspaceMatchesIncludingActiveWindows(
        normalizedWorkingDirs: [String],
        kind: WorkingDirsWorkspaceMatchKind
    ) async throws -> [WorkspaceMatch] {
        let windows = windowStates.allWindows
        guard let inventoryWindow = windows.first else {
            throw MCPError.invalidParams("No windows available to load workspace list. Open at least one window first.")
        }
        let activeWindowSnapshots = Self.activeWorkspaceSnapshots(from: windows)
        let diskWorkspaces = await inventoryWindow.workspaceManager.loadWorkspaceSnapshotFromDisk()
        return Self.collapsedWorkspaceMatches(
            normalizedWorkingDirs: normalizedWorkingDirs,
            kind: kind,
            diskWorkspaces: diskWorkspaces,
            activeWindowSnapshots: activeWindowSnapshots,
            includeActiveWindowWorkspaces: true,
            includeHidden: false
        )
    }

    private func exactWorkspaceMatchesIncludingActiveWindows(
        normalizedWorkingDirs: [String]
    ) async throws -> [WorkspaceMatch] {
        try await workspaceMatchesIncludingActiveWindows(normalizedWorkingDirs: normalizedWorkingDirs, kind: .exact)
    }

    private func supersetWorkspaceMatchesIncludingActiveWindows(
        normalizedWorkingDirs: [String]
    ) async throws -> [WorkspaceMatch] {
        try await workspaceMatchesIncludingActiveWindows(normalizedWorkingDirs: normalizedWorkingDirs, kind: .superset)
    }

    private nonisolated static func workspaceMatch(
        inRequestedWindow windowID: Int,
        matches: [WorkspaceMatch]
    ) -> WorkspaceMatch? {
        matches.filter { $0.showingWindowIDs.contains(windowID) }.only
    }

    private nonisolated static func selectedWorkingDirsMatch(
        in matches: [WorkspaceMatch],
        requestedWindowID windowID: Int?
    ) -> WorkingDirsMatchSelection? {
        if let windowID,
           let windowDisambiguatedMatch = workspaceMatch(inRequestedWindow: windowID, matches: matches)
        {
            return WorkingDirsMatchSelection(match: windowDisambiguatedMatch, disambiguatedByWindowID: matches.count > 1)
        }
        if let onlyMatch = matches.only {
            return WorkingDirsMatchSelection(match: onlyMatch, disambiguatedByWindowID: false)
        }
        return nil
    }

    private nonisolated static func workingDirsMatchCandidates(
        exactMatches: [WorkspaceMatch],
        supersetMatches: [WorkspaceMatch]
    ) -> [WorkspaceMatch] {
        exactMatches.isEmpty ? supersetMatches : exactMatches
    }

    nonisolated static func test_exactWorkspaceMatchForWindowID(
        _ windowID: Int,
        matches: [(workspace: WorkspaceModel, showingWindowIDs: [Int])]
    ) -> WorkspaceModel? {
        workspaceMatch(
            inRequestedWindow: windowID,
            matches: matches.map { match in
                WorkspaceMatch(workspace: match.workspace, showingWindowIDs: match.showingWindowIDs, kind: .exact)
            }
        )?.workspace
    }

    nonisolated static func test_selectedWorkingDirsWorkspaceMatch(
        windowID: Int?,
        exactMatches: [(workspace: WorkspaceModel, showingWindowIDs: [Int])],
        supersetMatches: [(workspace: WorkspaceModel, showingWindowIDs: [Int])]
    ) -> (workspace: WorkspaceModel, kind: String, matchedBy: String)? {
        let matches = workingDirsMatchCandidates(
            exactMatches: exactMatches.map { match in
                WorkspaceMatch(workspace: match.workspace, showingWindowIDs: match.showingWindowIDs, kind: .exact)
            },
            supersetMatches: supersetMatches.map { match in
                WorkspaceMatch(workspace: match.workspace, showingWindowIDs: match.showingWindowIDs, kind: .superset)
            }
        )
        guard let selection = selectedWorkingDirsMatch(in: matches, requestedWindowID: windowID) else { return nil }
        let kindDescription = switch selection.match.kind {
        case .exact:
            "exact"
        case .superset:
            "superset"
        }
        let matchedBy = workingDirsMatchedBy(
            matchKind: selection.match.kind,
            candidateCount: matches.count,
            disambiguatedByWindowID: selection.disambiguatedByWindowID
        )
        return (selection.match.workspace, kindDescription, matchedBy)
    }

    nonisolated static func test_collapsedWorkingDirsWorkspaceMatches(
        workingDirs: [String],
        diskWorkspaces: [WorkspaceModel],
        activeWindows: [(windowID: Int, workspace: WorkspaceModel, isFocused: Bool)],
        kind: String = "exact",
        includeActiveWindowWorkspaces: Bool = true,
        includeHidden: Bool = false
    ) -> [(workspace: WorkspaceModel, showingWindowIDs: [Int], equivalentWorkspaceIDs: [UUID], activeWorkspaceIDsByWindowID: [Int: UUID], normalizedRepoPaths: [String])] {
        let matchKind: WorkingDirsWorkspaceMatchKind = kind == "superset" ? .superset : .exact
        let normalizedWorkingDirs = WorkspaceManagerViewModel.normalizedExactWorkspaceDirectorySet(workingDirs)
        let snapshots = activeWindows.map { activeWindow in
            ActiveWorkspaceWindowSnapshot(
                windowID: activeWindow.windowID,
                isFocused: activeWindow.isFocused,
                workspace: activeWindow.workspace
            )
        }
        return collapsedWorkspaceMatches(
            normalizedWorkingDirs: normalizedWorkingDirs,
            kind: matchKind,
            diskWorkspaces: diskWorkspaces,
            activeWindowSnapshots: snapshots,
            includeActiveWindowWorkspaces: includeActiveWindowWorkspaces,
            includeHidden: includeHidden
        ).map { match in
            (
                workspace: match.workspace,
                showingWindowIDs: match.showingWindowIDs,
                equivalentWorkspaceIDs: match.equivalentWorkspaceIDs.sorted { $0.uuidString < $1.uuidString },
                activeWorkspaceIDsByWindowID: match.activeWorkspaceByWindowID.mapValues(\.id),
                normalizedRepoPaths: match.normalizedRepoPaths
            )
        }
    }

    nonisolated static func preferredOpenWindowID(
        showingWindowIDs: [Int],
        selectedWindowID: Int?,
        focusedWindowID: Int?
    ) -> Int? {
        if let selectedWindowID, showingWindowIDs.contains(selectedWindowID) {
            return selectedWindowID
        }
        if let focusedWindowID, showingWindowIDs.contains(focusedWindowID) {
            return focusedWindowID
        }
        return showingWindowIDs.sorted().first
    }

    nonisolated static func test_preferredOpenWindowID(
        showingWindowIDs: [Int],
        selectedWindowID: Int?,
        focusedWindowID: Int?
    ) -> Int? {
        preferredOpenWindowID(
            showingWindowIDs: showingWindowIDs,
            selectedWindowID: selectedWindowID,
            focusedWindowID: focusedWindowID
        )
    }

    private func openRoutingWindow(deferringInitialAgentSystemWorkspaceRefresh: Bool = false) async throws -> WindowState {
        do {
            return try await windowStates.openNewMainWindow(
                deferringInitialAgentSystemWorkspaceRefresh: deferringInitialAgentSystemWorkspaceRefresh
            )
        } catch let error as WindowOpenError {
            throw MCPError.internalError("Failed to open new window: \(error.localizedDescription)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPError.internalError("Failed to open new window: \(error)")
        }
    }

    private func openInitializedWindow() async throws -> WindowState {
        let newWindow = try await openRoutingWindow()
        await newWindow.workspaceManager.awaitInitialized()
        return newWindow
    }

    private func openNewWindowShowingWorkspace(_ workspace: WorkspaceModel) async throws -> WindowState {
        let newWindow = try await openRoutingWindow(deferringInitialAgentSystemWorkspaceRefresh: true)
        defer { newWindow.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral() }
        await newWindow.workspaceManager.awaitInitialized()
        let switchResult = await newWindow.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: true)
        if !switchResult.didSwitch {
            throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
        }
        return newWindow
    }

    private func resolveWorkspaceApprovalWindow(
        requestedWindowID: Int?,
        openInNewWindow: Bool
    ) async throws -> WindowState {
        let windows = windowStates.allWindows
        let focusedWindowID = windows.first(where: { $0.isCurrentlyFocused })?.windowID
        let approvalWindow: WindowState? = {
            if let requestedWindowID {
                return windows.first(where: { $0.windowID == requestedWindowID })
            }
            if openInNewWindow {
                if let focusedWindowID {
                    return windows.first(where: { $0.windowID == focusedWindowID })
                }
                return windows.last ?? windows.first
            }
            return windows.only
        }()
        if let requestedWindowID, approvalWindow == nil {
            let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
            throw MCPError.invalidParams("Unknown window_id \(requestedWindowID). Valid window IDs: \(validIDs)")
        }
        if !openInNewWindow, requestedWindowID == nil, windows.count != 1 {
            throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
        }
        guard let approvalWindow else {
            throw MCPError.invalidParams("No windows available to create workspace. Open at least one window first.")
        }
        return approvalWindow
    }

    private func createWorkspace(
        in window: WindowState,
        name: String,
        repoPaths: [String],
        switchToCreated: Bool
    ) async throws -> WorkspaceModel {
        let newWorkspace = window.workspaceManager.createWorkspace(name: name, repoPaths: repoPaths)
        if switchToCreated {
            let switchResult = await window.workspaceManager.requestWorkspaceSwitch(to: newWorkspace, saveState: true)
            if !switchResult.didSwitch {
                throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
            }
        }
        return newWorkspace
    }

    private func derivedWorkspaceName(
        normalizedWorkingDirs: [String],
        creationNameHint: String?,
        existingWorkspaces: [WorkspaceModel]
    ) -> String {
        let trimmedHint = creationNameHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let derivedBaseName = normalizedWorkingDirs
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
        let baseName = trimmedHint.isEmpty ? derivedBaseName : trimmedHint
        let resolvedBaseName = baseName.isEmpty ? "Workspace" : baseName
        if !existingWorkspaces.contains(where: { $0.name == resolvedBaseName }) {
            return resolvedBaseName
        }
        var counter = 1
        var candidate = "\(resolvedBaseName) (\(counter))"
        while existingWorkspaces.contains(where: { $0.name == candidate }) {
            counter += 1
            candidate = "\(resolvedBaseName) (\(counter))"
        }
        return candidate
    }

    private func describeWorkspaceMatches(_ matches: [WorkspaceMatch]) -> String {
        matches.map { match in
            let windows = match.showingWindowIDs.isEmpty ? "none" : match.showingWindowIDs.map(String.init).joined(separator: ", ")
            return "workspace=\(match.workspace.name) (\(match.workspace.id.uuidString)) • windows=[\(windows)]"
        }.joined(separator: "\n- ")
    }

    private func workingDirsAmbiguityMessage(
        normalizedWorkingDirs: [String],
        matches: [WorkspaceMatch],
        windowID: Int?,
        afterApproval: Bool = false
    ) -> String {
        let phaseSuffix = afterApproval ? " after approval" : ""
        let kind = matches.first?.kind ?? .exact
        let guidance = switch (kind, windowID) {
        case let (.superset, windowID?):
            "window_id=\(windowID) did not disambiguate because that window is not showing exactly one of the superset matching workspaces. Supply window_id for a window showing the intended workspace, bind by context_id, or pass the full workspace repo_paths set to get an exact match."
        case (.superset, nil):
            "Supply window_id for a window showing the intended workspace, bind by context_id, or pass the full workspace repo_paths set to get an exact match."
        case let (.exact, windowID?):
            "window_id=\(windowID) did not disambiguate because that window is not showing exactly one of the \(kind.ambiguityGuidanceSubject). Delete the duplicate workspace with manage_workspaces action='delete'."
        case (.exact, nil):
            "Supply window_id to disambiguate, or delete the duplicate workspace with manage_workspaces action='delete'."
        }
        return "working_dirs [\(normalizedWorkingDirs.joined(separator: ", "))] \(kind.ambiguityDescription) multiple workspaces\(phaseSuffix):\n- \(describeWorkspaceMatches(matches))\n\(guidance)"
    }

    private nonisolated static func workingDirsMatchedBy(
        matchKind: WorkingDirsWorkspaceMatchKind,
        candidateCount: Int,
        disambiguatedByWindowID: Bool
    ) -> String {
        let baseDescription = matchKind.matchedByDescription
        guard disambiguatedByWindowID else { return baseDescription }
        let disambiguationDescription = "disambiguated by window_id from \(candidateCount) candidates"
        switch matchKind {
        case .exact:
            return "working_dirs (\(disambiguationDescription))"
        case .superset:
            return "working_dirs (matched by workspace repo_paths superset; \(disambiguationDescription))"
        }
    }

    nonisolated static func test_workingDirsMatchedBy(candidateCount: Int, disambiguatedByWindowID: Bool) -> String {
        workingDirsMatchedBy(matchKind: .exact, candidateCount: candidateCount, disambiguatedByWindowID: disambiguatedByWindowID)
    }

    nonisolated static func test_supersetWorkingDirsMatchedBy(candidateCount: Int, disambiguatedByWindowID: Bool) -> String {
        workingDirsMatchedBy(matchKind: .superset, candidateCount: candidateCount, disambiguatedByWindowID: disambiguatedByWindowID)
    }

    private func workingDirsResolution(
        windowID: Int,
        workspace: WorkspaceModel,
        normalizedWorkingDirs: [String],
        matchedBy: String,
        createdWorkspace: Bool
    ) -> WorkingDirsBindResolution {
        WorkingDirsBindResolution(
            windowID: windowID,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            repoPaths: workspace.repoPaths,
            matchedBy: matchedBy,
            createdWorkspace: createdWorkspace,
            normalizedWorkingDirs: normalizedWorkingDirs
        )
    }

    private func resolveMatchToWindow(
        _ match: WorkspaceMatch,
        connectionID: UUID?,
        normalizedWorkingDirs: [String],
        matchedBy: String,
        createdWorkspace: Bool
    ) async throws -> WorkingDirsBindResolution {
        let selectedWindowID: Int? = if let connectionID {
            await networkMgr.selectedWindow(for: connectionID)
        } else {
            nil
        }
        let focusedWindowID = windowStates.allWindows.first(where: { $0.isCurrentlyFocused })?.windowID
        if let preferredWindowID = Self.preferredOpenWindowID(
            showingWindowIDs: match.showingWindowIDs,
            selectedWindowID: selectedWindowID,
            focusedWindowID: focusedWindowID
        ) {
            if let activeEquivalentWorkspace = match.activeWorkspaceByWindowID[preferredWindowID] {
                return workingDirsResolution(
                    windowID: preferredWindowID,
                    workspace: activeEquivalentWorkspace,
                    normalizedWorkingDirs: normalizedWorkingDirs,
                    matchedBy: matchedBy,
                    createdWorkspace: createdWorkspace
                )
            }

            if let targetWindow = windowStates.allWindows.first(where: { $0.windowID == preferredWindowID }) {
                if targetWindow.workspaceManager.activeWorkspace?.id != match.workspace.id {
                    let switchResult = await targetWindow.workspaceManager.requestWorkspaceSwitch(to: match.workspace, saveState: true)
                    if !switchResult.didSwitch {
                        throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
                    }
                }
                return workingDirsResolution(
                    windowID: targetWindow.windowID,
                    workspace: match.workspace,
                    normalizedWorkingDirs: normalizedWorkingDirs,
                    matchedBy: matchedBy,
                    createdWorkspace: createdWorkspace
                )
            }
        }

        let newWindow = try await openNewWindowShowingWorkspace(match.workspace)
        return workingDirsResolution(
            windowID: newWindow.windowID,
            workspace: match.workspace,
            normalizedWorkingDirs: normalizedWorkingDirs,
            matchedBy: matchedBy,
            createdWorkspace: createdWorkspace
        )
    }

    private func resolveExistingWorkingDirsMatch(
        _ match: WorkspaceMatch,
        requestedWindowID: Int?,
        connectionID: UUID?,
        normalizedWorkingDirs: [String],
        matchedBy: String,
        createdWorkspace: Bool
    ) async throws -> WorkingDirsBindResolution {
        if let requestedWindowID {
            let windows = windowStates.allWindows
            guard let requestedWindow = windows.first(where: { $0.windowID == requestedWindowID }) else {
                let validIDs = windows.map(\.windowID).sorted().map(String.init).joined(separator: ", ")
                throw MCPError.invalidParams("Requested window_id \(requestedWindowID) is no longer available. Valid window IDs: \(validIDs)")
            }
            if let activeEquivalentWorkspace = match.activeWorkspaceByWindowID[requestedWindowID] {
                return workingDirsResolution(
                    windowID: requestedWindow.windowID,
                    workspace: activeEquivalentWorkspace,
                    normalizedWorkingDirs: normalizedWorkingDirs,
                    matchedBy: matchedBy,
                    createdWorkspace: createdWorkspace
                )
            }
            if requestedWindow.workspaceManager.activeWorkspace?.id != match.workspace.id {
                let switchResult = await requestedWindow.workspaceManager.requestWorkspaceSwitch(to: match.workspace, saveState: true)
                if !switchResult.didSwitch {
                    throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
                }
            }
            return workingDirsResolution(
                windowID: requestedWindow.windowID,
                workspace: match.workspace,
                normalizedWorkingDirs: normalizedWorkingDirs,
                matchedBy: matchedBy,
                createdWorkspace: createdWorkspace
            )
        }

        return try await resolveMatchToWindow(
            match,
            connectionID: connectionID,
            normalizedWorkingDirs: normalizedWorkingDirs,
            matchedBy: matchedBy,
            createdWorkspace: createdWorkspace
        )
    }

    private func ensureResolvedWorkspaceIsLoaded(_ resolution: WorkingDirsBindResolution) throws {
        guard let targetWindow = windowStates.allWindows.first(where: { $0.windowID == resolution.windowID }),
              let activeWorkspace = targetWindow.workspaceManager.activeWorkspace,
              activeWorkspace.id == resolution.workspaceID
        else {
            throw MCPError.invalidRequest(
                "Workspace '\(resolution.workspaceName)' was matched but is not loaded in window \(resolution.windowID). Use manage_workspaces action='switch' workspace='\(resolution.workspaceName)' window_id=\(resolution.windowID) to load it."
            )
        }
    }

    private func resolveExistingWorkingDirsBindResolution(
        normalizedWorkingDirs: [String],
        windowID: Int?,
        connectionID: UUID?,
        afterApproval: Bool
    ) async throws -> WorkingDirsBindResolution? {
        let exactMatches = try await exactWorkspaceMatchesIncludingActiveWindows(normalizedWorkingDirs: normalizedWorkingDirs)
        let supersetMatches = exactMatches.isEmpty
            ? try await supersetWorkspaceMatchesIncludingActiveWindows(normalizedWorkingDirs: normalizedWorkingDirs)
            : []
        let matches = Self.workingDirsMatchCandidates(exactMatches: exactMatches, supersetMatches: supersetMatches)
        let matchSelection = Self.selectedWorkingDirsMatch(in: matches, requestedWindowID: windowID)
        if matches.count > 1,
           matchSelection == nil
        {
            throw MCPError.invalidParams(
                workingDirsAmbiguityMessage(
                    normalizedWorkingDirs: normalizedWorkingDirs,
                    matches: matches,
                    windowID: windowID,
                    afterApproval: afterApproval
                )
            )
        }

        guard let matchSelection else { return nil }
        let match = matchSelection.match
        let matchedBy = Self.workingDirsMatchedBy(
            matchKind: match.kind,
            candidateCount: matches.count,
            disambiguatedByWindowID: matchSelection.disambiguatedByWindowID
        )
        let resolution = try await resolveExistingWorkingDirsMatch(
            match,
            requestedWindowID: windowID,
            connectionID: connectionID,
            normalizedWorkingDirs: normalizedWorkingDirs,
            matchedBy: matchedBy,
            createdWorkspace: false
        )
        try ensureResolvedWorkspaceIsLoaded(resolution)
        return resolution
    }

    private func createBlankBindTarget(
        in window: WindowState,
        tabName: String?,
        matchedBy: String,
        normalizedWorkingDirs: [String]? = nil
    ) async throws -> ResolvedBindTarget {
        guard let workspace = window.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace in target window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
        }
        guard let createdTab = await window.promptManager.createBackgroundComposeTab(strategy: .blank, name: tabName) else {
            throw MCPError.internalError("Failed to create a blank compose tab in window \(window.windowID).")
        }
        return ResolvedBindTarget(
            windowID: window.windowID,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            tabID: createdTab.id,
            tabName: createdTab.name,
            repoPaths: workspace.repoPaths,
            matchedBy: matchedBy,
            createdTab: true,
            normalizedWorkingDirs: normalizedWorkingDirs
        )
    }

    private func resolveWindowForBinding(windowID: Int?) throws -> WindowState {
        let windows = windowStates.allWindows
        let targetWindow: WindowState? = {
            if let windowID {
                return windows.first(where: { $0.windowID == windowID })
            }
            return windows.only
        }()

        if let windowID, targetWindow == nil {
            let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
            throw MCPError.invalidParams("Unknown window_id \(windowID). Valid window IDs: \(validIDs)")
        }
        if windowID == nil, windows.count != 1 {
            throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
        }
        guard let targetWindow else {
            throw MCPError.invalidParams("No valid target window found")
        }
        return targetWindow
    }

    private func resolveContextIDBindTarget(contextID: UUID, windowID: Int?, connectionPreferredWindowID: Int?) throws -> ResolvedBindTarget {
        let windows = windowStates.allWindows
        if let windowID, !windows.contains(where: { $0.windowID == windowID }) {
            let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
            throw MCPError.invalidParams("Unknown window_id \(windowID). Valid window IDs: \(validIDs)")
        }

        let matches = windows.compactMap { window -> ResolvedBindTarget? in
            guard windowID == nil || window.windowID == windowID else { return nil }
            guard let candidate = window.workspaceManager.bindingCandidate(forContextID: contextID) else { return nil }
            let tabName = window.workspaceManager.composeTabName(with: candidate.tabID) ?? contextID.uuidString
            return ResolvedBindTarget(
                windowID: window.windowID,
                workspaceID: candidate.workspaceID,
                workspaceName: candidate.workspaceName,
                tabID: candidate.tabID,
                tabName: tabName,
                repoPaths: candidate.repoPaths,
                matchedBy: "context_id",
                createdTab: false,
                normalizedWorkingDirs: nil
            )
        }

        guard !matches.isEmpty else {
            if let windowID {
                throw MCPError.invalidParams("Window \(windowID) does not host context_id '\(contextID.uuidString)'.")
            }
            throw MCPError.invalidParams("No RepoPrompt context matches context_id '\(contextID.uuidString)'. Use bind_context op=list to discover available context_id values.")
        }

        if matches.count == 1 {
            return matches[0]
        }

        // Same logical tab visible in multiple windows.
        // Prefer the connection's current window to avoid silently rebinding.
        if let connectionPreferredWindowID,
           let preferred = matches.first(where: { $0.windowID == connectionPreferredWindowID })
        {
            return preferred
        }

        // Fall back to deterministic selection (lowest window ID).
        return matches.sorted(by: { $0.windowID < $1.windowID })[0]
    }

    private func resolveWorkingDirsBindTarget(
        workingDirs: [String],
        windowID: Int?,
        createIfMissing: Bool,
        tabName: String?,
        connectionID: UUID?
    ) async throws -> WorkingDirsBindResolution {
        let windows = windowStates.allWindows
        if let windowID, !windows.contains(where: { $0.windowID == windowID }) {
            let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
            throw MCPError.invalidParams("Unknown window_id \(windowID). Valid window IDs: \(validIDs)")
        }

        let normalizedWorkingDirs = WorkspaceManagerViewModel.normalizedExactWorkspaceDirectorySet(workingDirs)
        guard !normalizedWorkingDirs.isEmpty else {
            throw MCPError.invalidParams("working_dirs must contain at least one valid absolute directory path.")
        }

        if let resolution = try await resolveExistingWorkingDirsBindResolution(
            normalizedWorkingDirs: normalizedWorkingDirs,
            windowID: windowID,
            connectionID: connectionID,
            afterApproval: false
        ) {
            return resolution
        }

        guard createIfMissing else {
            throw MCPError.invalidParams(
                "No existing workspace exactly matches working_dirs [\(normalizedWorkingDirs.joined(separator: ", "))] and no workspace repo_paths superset contains those roots. Exact matching uses the full workspace repo_paths set (order-insensitive); superset fallback uses root-set membership only, not descendant paths. Retry with create_if_missing=true to create one."
            )
        }

        let approvalWindow = try await resolveWorkspaceApprovalWindow(requestedWindowID: windowID, openInNewWindow: true)
        let existingWorkspaces = await approvalWindow.workspaceManager.loadWorkspaceSnapshotFromDisk()
        let workspaceName = derivedWorkspaceName(
            normalizedWorkingDirs: normalizedWorkingDirs,
            creationNameHint: tabName,
            existingWorkspaces: existingWorkspaces
        )
        let clientID = await networkMgr.currentClientIdentifier() ?? "unknown-client"
        let approvalResult = await WorkspaceApprovalManager.shared.requestCreateWorkspaceApproval(
            clientID: clientID,
            workspaceName: workspaceName,
            windowID: approvalWindow.windowID
        )
        guard approvalResult.isApproved else {
            throw MCPError.invalidRequest("Workspace creation was denied by the user.")
        }

        if let resolution = try await resolveExistingWorkingDirsBindResolution(
            normalizedWorkingDirs: normalizedWorkingDirs,
            windowID: windowID,
            connectionID: connectionID,
            afterApproval: true
        ) {
            return resolution
        }

        let newWindow = try await openRoutingWindow(deferringInitialAgentSystemWorkspaceRefresh: true)
        defer { newWindow.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral() }
        await newWindow.workspaceManager.awaitInitialized()
        let newWorkspace = try await createWorkspace(
            in: newWindow,
            name: workspaceName,
            repoPaths: normalizedWorkingDirs,
            switchToCreated: true
        )
        return WorkingDirsBindResolution(
            windowID: newWindow.windowID,
            workspaceID: newWorkspace.id,
            workspaceName: newWorkspace.name,
            repoPaths: newWorkspace.repoPaths,
            matchedBy: "working_dirs",
            createdWorkspace: true,
            normalizedWorkingDirs: normalizedWorkingDirs
        )
    }

    private func resolveCreationTargetWindow(windowID: Int?, connectionID: UUID?) async throws -> WindowState {
        let windows = windowStates.allWindows
        if let windowID {
            guard let exactWindow = windows.first(where: { $0.windowID == windowID }) else {
                let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
                throw MCPError.invalidParams("Unknown window_id \(windowID). Valid window IDs: \(validIDs)")
            }
            return exactWindow
        }

        if let connectionID,
           let selectedWindowID = await networkMgr.selectedWindow(for: connectionID),
           let selectedWindow = windows.first(where: { $0.windowID == selectedWindowID })
        {
            return selectedWindow
        }

        if let onlyWindow = windows.only {
            return onlyWindow
        }
        let available = windows.map(\.windowID).sorted().map(String.init).joined(separator: ", ")
        throw MCPError.invalidParams("Ambiguous window choice for bind_context tab creation. Supply window_id. Available windows: \(available)")
    }

    private func clearNonRunScopedBindingsAcrossWindows(for connectionID: UUID) {
        for window in windowStates.allWindows {
            _ = window.mcpServer.clearNonRunScopedBinding(forConnection: connectionID)
        }
    }

    private func bindTarget(
        _ target: ResolvedBindTarget,
        connectionID: UUID,
        clientName: String?
    ) async throws {
        guard let targetWindow = windowStates.allWindows.first(where: { $0.windowID == target.windowID }) else {
            throw MCPError.invalidParams("Window \(target.windowID) not found")
        }
        clearNonRunScopedBindingsAcrossWindows(for: connectionID)
        try targetWindow.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: clientName,
            tabID: target.tabID,
            workspaceID: target.workspaceID,
            windowID: target.windowID
        )
        try await networkMgr.setActiveWindowForCurrentConnection(target.windowID)
    }

    private func bindWindowOnly(windowID: Int, connectionID: UUID) async throws {
        _ = try resolveWindowForBinding(windowID: windowID)
        clearNonRunScopedBindingsAcrossWindows(for: connectionID)
        try await networkMgr.setActiveWindowForCurrentConnection(windowID)
    }

    private func listBindContextWindows(
        filterWindowID: Int?,
        currentWindowID: Int?,
        bindingSummary: MCPBindContextBindingSummary
    ) throws -> [MCPBindContextWindowSummary] {
        let windows = windowStates.allWindows
        if let filterWindowID, !windows.contains(where: { $0.windowID == filterWindowID }) {
            let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
            throw MCPError.invalidParams("Unknown window_id \(filterWindowID). Valid window IDs: \(validIDs)")
        }

        return windows.compactMap { window in
            guard filterWindowID == nil || window.windowID == filterWindowID else { return nil }
            let workspace = window.workspaceManager.activeWorkspace
            let tabs = workspace?.composeTabs ?? []
            let activeContextID = workspace?.activeComposeTabID
            let workspaceID = workspace?.id
            let workspaceName = Self.bindContextWorkspaceDisplayName(workspace) ?? ""
            let repoPaths = workspace.map { WorkspaceManagerViewModel.loadableRepoPaths(for: $0) } ?? []
            let tabSummaries = tabs.compactMap { tab -> MCPBindContextTabSummary? in
                guard let workspaceID else { return nil }
                return MCPBindContextTabSummary(
                    contextID: tab.id,
                    name: tab.name,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    isActive: activeContextID == tab.id,
                    isBound: bindingSummary.bindingKind == "tab_context" && bindingSummary.windowID == window.windowID && bindingSummary.contextID == tab.id,
                    repoPaths: repoPaths
                )
            }
            return MCPBindContextWindowSummary(
                windowID: window.windowID,
                isCurrentWindow: currentWindowID == window.windowID,
                workspace: workspace.map { MCPBindContextWorkspaceSummary(id: $0.id, name: Self.bindContextWorkspaceDisplayName($0) ?? $0.name) },
                activeContextID: activeContextID,
                tabs: tabSummaries
            )
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Private Helpers

    /// ---------------------------------------------------------------------
    private func updateCachedTools() async {
        var newTools: [Tool] = []

        newTools.append(
            Tool(
                name: "bind_context",
                description: """
                List, inspect, and bind sticky RepoPrompt window/tab context for this MCP connection.

                Operations:
                • list    – return **all** open windows, their compose tabs, and this connection's current binding
                • status  – return this connection's current binding only
                • bind    – bind by working_dirs (preferred), context_id, or window_id

                **Recommended binding flow:**
                Bind by `working_dirs` using absolute workspace root paths:
                	`{"op":"bind","working_dirs":["/path/to/root1","/path/to/root2"]}`
                RepoPrompt first looks for an exact workspace `repo_paths` set match (order-insensitive). If no exact match exists, RepoPrompt may fall back to a workspace whose `repo_paths` is a strict superset of the requested roots. Both modes match workspace roots only — not descendant paths.
                If the matching workspace is already open, RepoPrompt prefers that window. If it exists but is not open, RepoPrompt opens a window and switches to it. Add `create_if_missing=true` to create a new workspace after approval when neither exact nor superset workspace matches.

                Parameters:
                - op: "list" | "status" | "bind" (required)
                - working_dirs: string | string[]         (for bind: preferred — absolute workspace roots; exact match first, repo_paths superset fallback)
                - context_id: string                      (for bind: canonical compose-tab context UUID from a previous list)
                - window_id: integer                      (for list: filter to one window; for bind with working_dirs: disambiguate when multiple workspaces match; for bind alone: set window affinity)
                - create_if_missing: boolean              (for bind with working_dirs; create a new workspace after approval when no exact or superset workspace matches)
                - tab_name: string                        (optional workspace name hint when creating via working_dirs + create_if_missing)

                **Binding modes:**
                - **Window affinity** (from working_dirs or window_id): routes tool calls to whichever tab is currently active in that window. Most agents should use this.
                - **Tab binding** (from context_id): pins tool calls to a specific compose tab, even if you switch to another tab. Use when you need a stable context that won't change.

                **Discovery:**
                - Use `bind_context list` to see what's currently open (windows, active workspaces, tabs, context_ids)
                - Use `manage_workspaces list` to see saved visible workspaces, or `include_hidden=true` to include recoverable hidden workspaces
                """,
                inputSchema: .object(
                    properties: [
                        "op": .string(description: "Operation: 'list', 'status', or 'bind'", enum: ["list", "status", "bind"]),
                        "window_id": .integer(description: "For list: filter to one window. For bind with working_dirs: disambiguate when multiple workspaces match. For bind alone: set window affinity."),
                        "context_id": .string(description: "For bind: canonical compose-tab context UUID"),
                        "working_dirs": .string(description: "For bind: comma-separated absolute workspace root paths; exact match first, then repo_paths superset fallback"),
                        "create_if_missing": .boolean(description: "For bind with working_dirs: create a new workspace after approval if no exact or superset workspace matches"),
                        "tab_name": .string(description: "Optional workspace name when creating via working_dirs + create_if_missing")
                    ],
                    required: ["op"]
                ),
                annotations: .repoPromptLocalEphemeralState
            ) { [weak self] args -> BindContextResponse in
                guard let self else {
                    throw MCPError.internalError("Service unavailable")
                }

                let request = try Self.parseBindContextRequest(args)
                let connectionID = await networkMgr.currentConnectionUUID()

                switch request.op {
                case .list:
                    let binding = await currentBindingSummary(for: connectionID)
                    let selectedWindowID: Int? = if let connectionID {
                        await networkMgr.selectedWindow(for: connectionID)
                    } else {
                        nil
                    }
                    let focusedWindowID = await MainActor.run {
                        self.windowStates.allWindows.first(where: { $0.isCurrentlyFocused })?.windowID
                    }
                    let currentWindowID = binding.windowID ?? selectedWindowID ?? focusedWindowID
                    let windows = try await MainActor.run {
                        try self.listBindContextWindows(
                            filterWindowID: request.windowID,
                            currentWindowID: currentWindowID,
                            bindingSummary: binding
                        )
                    }
                    return BindContextResponse(windows: windows, binding: binding)

                case .status:
                    return await BindContextResponse(binding: currentBindingSummary(for: connectionID))

                case .bind:
                    guard let connectionID else {
                        throw MCPError.internalError("No active connection context")
                    }
                    let previousBinding = await currentBindingSummary(for: connectionID)
                    let clientName = await networkMgr.currentClientIdentifier()
                    switch request.matchKind {
                    case .contextID:
                        let connectionPreferredWindow = await networkMgr.selectedWindow(for: connectionID)
                        let target = try await MainActor.run {
                            try self.resolveContextIDBindTarget(contextID: request.contextID!, windowID: request.windowID, connectionPreferredWindowID: connectionPreferredWindow)
                        }
                        let unchanged = previousBinding.bindingKind == "tab_context"
                            && previousBinding.windowID == target.windowID
                            && previousBinding.contextID == target.tabID
                            && previousBinding.explicit
                            && !previousBinding.runScoped

                        if !unchanged {
                            try await bindTarget(target, connectionID: connectionID, clientName: clientName)
                        } else {
                            try await networkMgr.setActiveWindowForCurrentConnection(target.windowID)
                        }

                        let binding = await currentBindingSummary(for: connectionID)
                        let note = await MainActor.run { self.bindContextWindowNote(windowID: binding.windowID) }
                        return BindContextResponse(
                            binding: binding,
                            changed: !unchanged,
                            matchedBy: target.matchedBy,
                            createdTab: target.createdTab,
                            normalizedWorkingDirs: target.normalizedWorkingDirs,
                            note: note
                        )
                    case .workingDirs:
                        let target = try await resolveWorkingDirsBindTarget(
                            workingDirs: request.workingDirs,
                            windowID: request.windowID,
                            createIfMissing: request.createIfMissing,
                            tabName: request.tabName,
                            connectionID: connectionID
                        )

                        let unchanged = previousBinding.bindingKind == "window"
                            && previousBinding.windowID == target.windowID
                            && previousBinding.contextID == nil
                            && !previousBinding.runScoped
                        if !unchanged {
                            try await bindWindowOnly(windowID: target.windowID, connectionID: connectionID)
                        } else {
                            try await networkMgr.setActiveWindowForCurrentConnection(target.windowID)
                        }

                        let binding = await currentBindingSummary(for: connectionID)
                        let note = await MainActor.run { self.bindContextWindowNote(windowID: binding.windowID) }
                        return BindContextResponse(
                            binding: binding,
                            changed: binding != previousBinding,
                            matchedBy: target.matchedBy,
                            createdTab: false,
                            createdWorkspace: target.createdWorkspace,
                            normalizedWorkingDirs: target.normalizedWorkingDirs,
                            note: note
                        )
                    case .windowID:
                        let windowID = request.windowID!
                        let unchanged = previousBinding.bindingKind == "window"
                            && previousBinding.windowID == windowID
                            && previousBinding.contextID == nil
                            && !previousBinding.runScoped

                        if !unchanged {
                            try await bindWindowOnly(windowID: windowID, connectionID: connectionID)
                        } else {
                            try await networkMgr.setActiveWindowForCurrentConnection(windowID)
                        }

                        let binding = await currentBindingSummary(for: connectionID)
                        let note = await MainActor.run { self.bindContextWindowNote(windowID: binding.windowID) }
                        return BindContextResponse(
                            binding: binding,
                            changed: !unchanged,
                            matchedBy: BindContextRequest.MatchKind.windowID.rawValue,
                            createdTab: false,
                            note: note
                        )
                    case .none:
                        throw MCPError.invalidParams("bind_context op='bind' requires context_id, working_dirs, or window_id.")
                    }
                }
            }
        )

        // Always register manage_workspaces so clients can route workspaces/windows.
        // Per-connection policy in ServerNetworkManager may still filter it.
        newTools.append(
            // 3️⃣ manage_workspaces ---------------------------------------------
            Tool(
                name: "manage_workspaces",
                description: """
                Manage workspaces and compose-tab lifecycle across RepoPrompt windows.

                **This is the workspace inventory view.** `bind_context` remains the canonical API for per-window tab routing and context_id discovery. Legacy-compatible `list_tabs` and `select_tab` actions are restored for older clients, but new integrations should prefer `bind_context`.

                Actions:
                • list         – Return known visible workspaces by default (id, name, repoPaths, showing window IDs, is_hidden)
                • switch       – Switch a window to a specified workspace
                • create       – Create a new workspace (optional folder_path)
                • hide         – Hide a workspace from default workspace lists without deleting it
                • unhide       – Restore a hidden workspace to default workspace lists
                • delete       – Delete a workspace permanently (optionally close window)
                • add_folder   – Add a folder to a workspace (defaults to active workspace)
                • remove_folder – Remove a folder from a workspace (defaults to active workspace)
                • list_tabs    – List compose tabs in one window (Legacy compatibility — prefer bind_context op=list)
                • select_tab   – Bind this connection to a compose tab (Legacy compatibility — prefer bind_context op=bind context_id=<id>)
                • create_tab   – Create a new compose tab in the background
                • close_tab    – Close a compose tab safely

                Parameters:
                - action: "list" | "switch" | "create" | "hide" | "unhide" | "delete" | "add_folder" | "remove_folder" | "list_tabs" | "select_tab" | "create_tab" | "close_tab" (required)
                - workspace: string                             (required for 'switch', 'hide', 'unhide', 'delete'; optional for 'add_folder', 'remove_folder' - defaults to active workspace; UUID or name)
                - name: string                                  (required for 'create'; optional for 'create_tab')
                - folder_path: string                           (required for 'add_folder', 'remove_folder'; optional for 'create' to initialize with a root folder; absolute path)
                - tab: string                                   (required for 'select_tab'; optional for 'close_tab'; UUID or name)
                - mode: "blank" | "fork"                      (optional for 'create_tab'; default "blank")
                - source_tab: string                            (optional for 'create_tab' when mode="fork"; UUID or name)
                - bind: boolean                                 (optional for 'create_tab'; default true)
                - focus: boolean                                (optional for 'select_tab' or 'create_tab'; if true, also switches the UI to show the tab)
                - allow_active: boolean                         (optional for 'close_tab'; default false)
                - window_id: integer                            (optional; target window, defaults to selected or only window)
                - open_in_new_window: boolean                   (optional for 'switch' or 'create'; when true, opens workspace in a new window and binds the connection to it)
                - switch_to_created: boolean                    (optional for 'create'; when true, switches to the newly created workspace)
                - close_window: boolean                         (optional for 'delete'; when true, switches away without saving, deletes the workspace, then requests window close)
                - include_hidden: boolean                       (optional; default false. For 'list', includes hidden workspaces. For name-based 'switch'/'delete', allows hidden matches. UUID lookup remains explicit and can resolve hidden workspaces.)

                Hidden workspaces remain persisted/recoverable. Default 'list' and name-based 'switch'/'delete' exclude hidden workspaces unless include_hidden=true; 'hide'/'unhide' are non-destructive. Explicit UUID switch/delete can target hidden workspaces without unhiding them.

                **Relationship with bind_context:**
                - `manage_workspaces.list` returns workspace inventory: names, folder paths, and which windows show each workspace
                - `bind_context.list` returns per-window routing state: windows, active tabs, context_ids, and current binding
                - When the same workspace is open in multiple windows, compose tabs are shared — use `bind_context` to discover per-window context_ids

                create_tab defaults to bind=true and focus=false so automation can create isolated background tabs without stealing UI focus.

                IMPORTANT: The 'focus' parameter switches the visible tab in the UI, which can be disruptive to the user's workflow. Only set focus=true when the user explicitly requests to see or switch to a specific tab. For background operations, omit focus or set it to false. The 'close_tab' action refuses to close the last remaining tab, the active visible tab unless allow_active=true, or any tab with a live bound run.
                """,
                inputSchema: .object(
                    properties: [
                        "action": .string(description: "Action to perform. Legacy compatibility: prefer bind_context for list_tabs/select_tab when building new integrations.", enum: ["list", "switch", "create", "hide", "unhide", "delete", "add_folder", "remove_folder", "list_tabs", "select_tab", "create_tab", "close_tab"]),
                        "workspace": .string(description: "Workspace UUID or name (required for 'switch', 'hide', 'unhide', 'delete'; optional for 'add_folder', 'remove_folder' - defaults to active workspace)"),
                        "name": .string(description: "Name for new workspace (required for 'create'; optional for 'create_tab')"),
                        "folder_path": .string(description: "Absolute folder path (required for 'add_folder', 'remove_folder'; optional for 'create' to initialize with a root folder)"),
                        "tab": .string(description: "Compose tab UUID or name (required for 'select_tab'; optional for 'close_tab')"),
                        "mode": .string(description: "For 'create_tab': creation mode ('blank' or 'fork')"),
                        "source_tab": .string(description: "For 'create_tab' with mode='fork': source compose tab UUID or name"),
                        "bind": .boolean(description: "For 'create_tab': if true, bind this MCP connection to the new tab (default true)"),
                        "window_id": .integer(description: "Optional window ID; defaults to selected or only window"),
                        "focus": .boolean(description: "For 'select_tab' or 'create_tab': if true, also switches the UI to show the tab"),
                        "allow_active": .boolean(description: "For 'close_tab': allow closing the currently active visible tab"),
                        "open_in_new_window": .boolean(description: "For 'switch' or 'create': when true, opens workspace in a new window and binds connection to it. Returns window_id in response."),
                        "switch_to_created": .boolean(description: "For 'create': when true, switches to the newly created workspace in the target window."),
                        "close_window": .boolean(description: "For 'delete': when true, switches away without saving, deletes the workspace, then requests window close."),
                        "include_hidden": .boolean(description: "Default false. For list, includes hidden workspaces. For name-based switch/delete, allows hidden matches; UUID lookup remains explicit.")
                    ],
                    required: ["action"]
                ),
                annotations: .repoPromptLocalDestructive
            ) { [weak self] args -> ManageWorkspacesResponse in
                guard let self else {
                    throw MCPError.internalError("Service unavailable")
                }

                guard let action = args["action"]?.stringValue?.lowercased() else {
                    throw MCPError.invalidParams("Missing or invalid 'action' parameter")
                }

                switch action {
                case "list":
                    let includeHidden = args["include_hidden"]?.boolValue ?? false
                    // Load fresh workspace data from disk to ensure accurate repoPaths
                    // Then overlay window visibility information from in-memory state

                    // Get a workspace manager to load disk snapshot
                    guard let referenceManager = await MainActor.run(body: {
                        self.windowStates.allWindows.first?.workspaceManager
                    }) else {
                        return ManageWorkspacesResponse(action: "list", workspaces: [], status: "ok")
                    }

                    // Load authoritative workspace data from disk
                    let diskWorkspaces = await referenceManager.loadWorkspaceSnapshotFromDisk()

                    // Build map of which windows are showing each workspace
                    let windowsByWorkspaceID: [UUID: Set<Int>] = await MainActor.run {
                        var result: [UUID: Set<Int>] = [:]
                        for ws in self.windowStates.allWindows {
                            if let activeID = ws.workspaceManager.activeWorkspace?.id {
                                result[activeID, default: []].insert(ws.windowID)
                            }
                        }
                        return result
                    }

                    // Build summaries from disk data with window visibility overlay.
                    // Hidden workspaces remain persisted/recoverable, but are excluded unless explicitly requested.
                    let summaries: [MCPWorkspaceSummary] = diskWorkspaces.filter { model in
                        includeHidden || !model.isHiddenInMenus
                    }.map { model in
                        MCPWorkspaceSummary(
                            id: model.id,
                            name: model.name,
                            allRepoPaths: model.repoPaths,
                            showingWindowIDs: Array(windowsByWorkspaceID[model.id] ?? []).sorted(),
                            isHidden: model.isHiddenInMenus
                        )
                    }.sorted { lhs, rhs in
                        let lhsKey = lhs.name.lowercased()
                        let rhsKey = rhs.name.lowercased()
                        if lhsKey != rhsKey {
                            return lhsKey < rhsKey
                        }
                        if lhs.name != rhs.name {
                            return lhs.name < rhs.name
                        }
                        return lhs.id.uuidString < rhs.id.uuidString
                    }

                    return ManageWorkspacesResponse(action: "list", workspaces: summaries, status: "ok")

                case "switch":
                    // Validate required 'workspace' param for switch
                    guard let rawWorkspaceParam = args["workspace"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawWorkspaceParam.isEmpty
                    else {
                        throw MCPError.invalidParams("Missing required 'workspace' parameter (UUID or name) for 'switch' action.")
                    }

                    // Check if we should open in a new window
                    let openInNewWindow = args["open_in_new_window"]?.boolValue ?? false
                    let includeHidden = args["include_hidden"]?.boolValue ?? false

                    if openInNewWindow {
                        // ═══════════════════════════════════════════════════════════════
                        // OPEN IN NEW WINDOW MODE
                        // ═══════════════════════════════════════════════════════════════

                        // First, resolve the workspace model from disk (don't require an existing window)
                        let targetWorkspace = try await resolveWorkspaceForSwitch(rawWorkspaceParam: rawWorkspaceParam, includeHidden: includeHidden)

                        // Open a new window
                        let newWindow: WindowState
                        do {
                            newWindow = try await openRoutingWindow(deferringInitialAgentSystemWorkspaceRefresh: true)
                        } catch let error as WindowOpenError {
                            throw MCPError.internalError("Failed to open new window: \(error.localizedDescription)")
                        } catch {
                            throw MCPError.internalError("Failed to open new window: \(error)")
                        }

                        defer {
                            Task { @MainActor [newWindow] in
                                newWindow.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral()
                            }
                        }

                        // Wait for initial workspace setup before switching
                        await newWindow.workspaceManager.awaitInitialized()

                        // Switch the new window to the target workspace
                        let switchResult = await newWindow.workspaceManager.requestWorkspaceSwitch(to: targetWorkspace, saveState: true)
                        if !switchResult.didSwitch {
                            throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
                        }

                        // Bind this MCP connection to the new window
                        try await networkMgr.setActiveWindowForCurrentConnection(newWindow.windowID)

                        // Return success with the new window ID
                        return ManageWorkspacesResponse(
                            action: "switch",
                            workspaces: nil,
                            status: "ok",
                            windowID: newWindow.windowID
                        )
                    }

                    // ═══════════════════════════════════════════════════════════════
                    // STANDARD SWITCH MODE (switch existing window)
                    // ═══════════════════════════════════════════════════════════════

                    // Determine target window
                    let targetWindowIDArg = args["window_id"]?.intValue
                    let windows = await MainActor.run { self.windowStates.allWindows }

                    // Safe target window selection (no force-unwrap)
                    let targetWindowOpt: WindowState? = if let wid = targetWindowIDArg {
                        windows.first(where: { $0.windowID == wid })
                    } else {
                        windows.only
                    }

                    // Validate window selection or guide the client
                    if let wid = targetWindowIDArg, targetWindowOpt == nil {
                        let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
                        throw MCPError.invalidParams("Unknown window_id \(wid). Valid window IDs: \(validIDs)")
                    }
                    if targetWindowIDArg == nil, windows.count != 1 {
                        throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
                    }
                    guard let targetWindow = targetWindowOpt else {
                        throw MCPError.invalidParams("No valid target window found")
                    }

                    // Resolve the target workspace model using hidden-aware UUID-or-name logic.
                    let targetModel = try await resolveWorkspaceForSwitch(rawWorkspaceParam: rawWorkspaceParam, includeHidden: includeHidden)

                    // Perform the switch on the target window
                    let switchResult = await targetWindow.workspaceManager.requestWorkspaceSwitch(to: targetModel, saveState: true)
                    if !switchResult.didSwitch {
                        throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
                    }

                    if Self.shouldBindConnectionAfterStandardWorkspaceSwitch(explicitWindowIDProvided: targetWindowIDArg != nil) {
                        try await networkMgr.setActiveWindowForCurrentConnection(targetWindow.windowID)
                    }

                    return ManageWorkspacesResponse(action: "switch", workspaces: nil, status: "ok")

                case "create":
                    // Create a new workspace
                    guard let workspaceName = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !workspaceName.isEmpty
                    else {
                        throw MCPError.invalidParams("Missing required 'name' parameter for 'create' action.")
                    }

                    let rawFolderPath = args["folder_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let initialRepoPaths: [String]
                    if let rawFolderPath, !rawFolderPath.isEmpty {
                        let expandedPath = (rawFolderPath as NSString).expandingTildeInPath
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
                              isDirectory.boolValue
                        else {
                            throw MCPError.invalidParams("Folder does not exist or is not a directory: \(expandedPath)")
                        }
                        let normalizedPath = (expandedPath as NSString).standardizingPath
                        initialRepoPaths = [normalizedPath]
                    } else {
                        initialRepoPaths = []
                    }

                    // Check if we should open in a new window
                    let openInNewWindow = args["open_in_new_window"]?.boolValue ?? false
                    let switchToCreated = args["switch_to_created"]?.boolValue ?? true

                    // Determine target window for approval
                    let targetWindowIDArg = args["window_id"]?.intValue
                    let (windows, focusedWindowID) = await MainActor.run { () -> ([WindowState], Int?) in
                        let allWindows = self.windowStates.allWindows
                        let focusedID = allWindows.first(where: { $0.isCurrentlyFocused })?.windowID
                        return (allWindows, focusedID)
                    }

                    let approvalWindowOpt: WindowState? = {
                        if let wid = targetWindowIDArg {
                            return windows.first(where: { $0.windowID == wid })
                        }
                        if openInNewWindow {
                            if let focusedID = focusedWindowID {
                                return windows.first(where: { $0.windowID == focusedID })
                            }
                            return windows.last ?? windows.first
                        }
                        return windows.only
                    }()

                    if let wid = targetWindowIDArg, approvalWindowOpt == nil {
                        let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
                        throw MCPError.invalidParams("Unknown window_id \(wid). Valid window IDs: \(validIDs)")
                    }
                    if !openInNewWindow, targetWindowIDArg == nil, windows.count != 1 {
                        throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
                    }
                    guard let approvalWindow = approvalWindowOpt else {
                        throw MCPError.invalidParams("No windows available to create workspace. Open at least one window first.")
                    }

                    // Get client ID for approval
                    let clientID = await networkMgr.currentClientIdentifier() ?? "unknown-client"

                    // Request approval
                    let approvalResult = await WorkspaceApprovalManager.shared.requestCreateWorkspaceApproval(
                        clientID: clientID,
                        workspaceName: workspaceName,
                        windowID: approvalWindow.windowID
                    )

                    guard approvalResult.isApproved else {
                        throw MCPError.invalidRequest("Workspace creation was denied by the user.")
                    }

                    if openInNewWindow {
                        // Open a new window for the workspace
                        let newWindow: WindowState
                        do {
                            newWindow = try await openRoutingWindow(deferringInitialAgentSystemWorkspaceRefresh: switchToCreated)
                        } catch let error as WindowOpenError {
                            throw MCPError.internalError("Failed to open new window: \(error.localizedDescription)")
                        } catch {
                            throw MCPError.internalError("Failed to open new window: \(error)")
                        }
                        defer {
                            Task { @MainActor [newWindow] in
                                newWindow.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral()
                            }
                        }

                        // Wait for initial workspace setup before creating
                        await newWindow.workspaceManager.awaitInitialized()

                        // Create the workspace in the new window
                        let newWorkspace = await MainActor.run {
                            newWindow.workspaceManager.createWorkspace(name: workspaceName, repoPaths: initialRepoPaths)
                        }
                        if switchToCreated {
                            let switchResult = await newWindow.workspaceManager.requestWorkspaceSwitch(to: newWorkspace, saveState: true)
                            if !switchResult.didSwitch {
                                throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
                            }
                        }

                        // Bind this MCP connection to the new window
                        try await networkMgr.setActiveWindowForCurrentConnection(newWindow.windowID)

                        let summary = MCPWorkspaceSummary(
                            id: newWorkspace.id,
                            name: newWorkspace.name,
                            allRepoPaths: newWorkspace.repoPaths,
                            showingWindowIDs: switchToCreated ? [newWindow.windowID] : []
                        )

                        return ManageWorkspacesResponse(
                            action: "create",
                            workspaces: [summary],
                            status: "ok",
                            windowID: newWindow.windowID
                        )
                    }

                    // Create the workspace in the target window
                    let newWorkspace = await MainActor.run {
                        approvalWindow.workspaceManager.createWorkspace(name: workspaceName, repoPaths: initialRepoPaths)
                    }

                    if switchToCreated {
                        let switchResult = await approvalWindow.workspaceManager.requestWorkspaceSwitch(to: newWorkspace, saveState: true)
                        if !switchResult.didSwitch {
                            throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
                        }
                    }

                    let summary = MCPWorkspaceSummary(
                        id: newWorkspace.id,
                        name: newWorkspace.name,
                        allRepoPaths: newWorkspace.repoPaths,
                        showingWindowIDs: switchToCreated ? [approvalWindow.windowID] : []
                    )

                    return ManageWorkspacesResponse(action: "create", workspaces: [summary], status: "ok")

                case "hide", "unhide":
                    guard let rawWorkspaceParam = args["workspace"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawWorkspaceParam.isEmpty
                    else {
                        throw MCPError.invalidParams("Missing required 'workspace' parameter (UUID or name) for '\(action)' action.")
                    }

                    let shouldHide = action == "hide"
                    let resolvedWorkspace = try await resolveWorkspaceForHiddenMutation(rawWorkspaceParam: rawWorkspaceParam, hidden: shouldHide)
                    guard !resolvedWorkspace.isSystemWorkspace else {
                        throw MCPError.invalidParams("Cannot \(action) system workspace '\(resolvedWorkspace.name)'.")
                    }
                    let mutationManagers = await MainActor.run {
                        self.windowStates.allWindows.map(\.workspaceManager)
                    }
                    guard let writerManager = mutationManagers.first else {
                        throw MCPError.invalidParams("No windows available to update workspace hidden state. Open at least one window first.")
                    }

                    let updatedWorkspace = try await writerManager.setWorkspaceHiddenFromSnapshot(resolvedWorkspace, hidden: shouldHide)
                    await MainActor.run {
                        for manager in mutationManagers {
                            manager.applyWorkspaceHiddenStateInMemory(
                                workspaceID: updatedWorkspace.id,
                                hidden: updatedWorkspace.isHiddenInMenus,
                                dateModified: updatedWorkspace.dateModified
                            )
                        }
                    }

                    let showingWindowIDs = await MainActor.run { () -> [Int] in
                        self.windowStates.allWindows.compactMap { window in
                            guard window.workspaceManager.activeWorkspace?.id == updatedWorkspace.id else { return nil }
                            return window.windowID
                        }.sorted()
                    }
                    let summary = MCPWorkspaceSummary(
                        id: updatedWorkspace.id,
                        name: updatedWorkspace.name,
                        allRepoPaths: updatedWorkspace.repoPaths,
                        showingWindowIDs: showingWindowIDs,
                        isHidden: updatedWorkspace.isHiddenInMenus
                    )
                    return ManageWorkspacesResponse(action: action, workspaces: [summary], status: "ok")

                case "delete":
                    // Delete a workspace
                    guard let rawWorkspaceParam = args["workspace"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawWorkspaceParam.isEmpty
                    else {
                        throw MCPError.invalidParams("Missing required 'workspace' parameter (UUID or name) for 'delete' action.")
                    }

                    let closeWindow = args["close_window"]?.boolValue ?? false
                    let includeHidden = args["include_hidden"]?.boolValue ?? false

                    // Determine target window
                    let targetWindowIDArg = args["window_id"]?.intValue
                    let windows = await MainActor.run { self.windowStates.allWindows }

                    let targetWindowOpt: WindowState? = if let wid = targetWindowIDArg {
                        windows.first(where: { $0.windowID == wid })
                    } else {
                        windows.only
                    }

                    if let wid = targetWindowIDArg, targetWindowOpt == nil {
                        let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
                        throw MCPError.invalidParams("Unknown window_id \(wid). Valid window IDs: \(validIDs)")
                    }
                    if targetWindowIDArg == nil, windows.count != 1 {
                        throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
                    }
                    guard let targetWindow = targetWindowOpt else {
                        throw MCPError.invalidParams("No valid target window found")
                    }

                    let workspace = try await resolveWorkspaceForDelete(rawWorkspaceParam: rawWorkspaceParam, includeHidden: includeHidden)

                    await MainActor.run {
                        targetWindow.workspaceManager.reloadWorkspacesFromDisk()
                    }

                    let showingWindowIDs = await MainActor.run { () -> [Int] in
                        self.windowStates.allWindows.compactMap { window in
                            guard window.workspaceManager.activeWorkspace?.id == workspace.id else { return nil }
                            return window.windowID
                        }.sorted()
                    }

                    if closeWindow {
                        guard showingWindowIDs.contains(targetWindow.windowID) else {
                            let detail = showingWindowIDs.isEmpty
                                ? "Workspace '\(workspace.name)' is not active in any window."
                                : "Workspace '\(workspace.name)' is active in windows: \(showingWindowIDs.map(String.init).joined(separator: ", "))"
                            throw MCPError.invalidParams("close_window requires the workspace to be active in the target window. \(detail)")
                        }
                        if showingWindowIDs.count > 1 {
                            throw MCPError.invalidParams("Workspace '\(workspace.name)' is active in multiple windows: \(showingWindowIDs.map(String.init).joined(separator: ", ")). Close those windows or switch them away before deleting.")
                        }
                    } else {
                        let isActive = await MainActor.run {
                            targetWindow.workspaceManager.activeWorkspace?.id == workspace.id
                        }
                        if isActive {
                            throw MCPError.invalidParams("Cannot delete the currently active workspace. Switch to another workspace first.")
                        }
                    }

                    // Get client ID for approval
                    let clientID = await networkMgr.currentClientIdentifier() ?? "unknown-client"

                    // Request approval
                    let approvalResult = await WorkspaceApprovalManager.shared.requestDeleteWorkspaceApproval(
                        clientID: clientID,
                        workspaceName: workspace.name,
                        workspaceID: workspace.id,
                        windowID: targetWindow.windowID
                    )

                    guard approvalResult.isApproved else {
                        throw MCPError.invalidRequest("Workspace deletion was denied by the user.")
                    }

                    if closeWindow {
                        let fallback = await MainActor.run {
                            targetWindow.workspaceManager.getOrCreateSystemWorkspace()
                        }
                        let switchResult = await targetWindow.workspaceManager.requestWorkspaceSwitch(to: fallback, saveState: false)
                        if !switchResult.didSwitch {
                            throw MCPError.invalidRequest(switchResult.message ?? "Workspace switch was cancelled.")
                        }
                    }

                    // Delete the workspace
                    await MainActor.run {
                        targetWindow.workspaceManager.deleteWorkspace(workspace)
                    }

                    if closeWindow {
                        let authorization = Self.workspaceDeleteCloseAuthorization()
                        try await MainActor.run {
                            try self.windowStates.requestCloseWindow(
                                windowID: targetWindow.windowID,
                                authorization: authorization
                            )
                        }
                    }

                    return ManageWorkspacesResponse(
                        action: "delete",
                        workspaces: nil,
                        status: "ok",
                        closedWindowID: closeWindow ? targetWindow.windowID : nil
                    )

                case "add_folder":
                    // Add a folder to a workspace
                    // workspace param is optional - defaults to active workspace
                    let rawWorkspaceParam = args["workspace"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

                    guard let folderPath = args["folder_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !folderPath.isEmpty
                    else {
                        throw MCPError.invalidParams("Missing required 'folder_path' parameter for 'add_folder' action.")
                    }

                    // Validate folder exists
                    let folderURL = URL(fileURLWithPath: folderPath)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory),
                          isDirectory.boolValue
                    else {
                        throw MCPError.invalidParams("Folder does not exist or is not a directory: \(folderPath)")
                    }

                    // Determine target window
                    let targetWindowIDArg = args["window_id"]?.intValue
                    let windows = await MainActor.run { self.windowStates.allWindows }

                    let targetWindowOpt: WindowState? = if let wid = targetWindowIDArg {
                        windows.first(where: { $0.windowID == wid })
                    } else {
                        windows.only
                    }

                    if let wid = targetWindowIDArg, targetWindowOpt == nil {
                        let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
                        throw MCPError.invalidParams("Unknown window_id \(wid). Valid window IDs: \(validIDs)")
                    }
                    if targetWindowIDArg == nil, windows.count != 1 {
                        throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
                    }
                    guard let targetWindow = targetWindowOpt else {
                        throw MCPError.invalidParams("No valid target window found")
                    }

                    // Resolve workspace: explicit param, or default to active workspace
                    var targetWorkspace: WorkspaceModel? = nil
                    if let param = rawWorkspaceParam, !param.isEmpty {
                        if let targetID = UUID(uuidString: param) {
                            targetWorkspace = await MainActor.run {
                                targetWindow.workspaceManager.workspace(withID: targetID)
                            }
                        } else {
                            targetWorkspace = await MainActor.run {
                                targetWindow.workspaceManager.workspaces.first(where: { $0.name == param })
                            }
                        }
                        guard targetWorkspace != nil else {
                            throw MCPError.invalidParams("Unknown workspace '\(param)'")
                        }
                    } else {
                        // Default to active workspace
                        targetWorkspace = await MainActor.run {
                            targetWindow.workspaceManager.activeWorkspace
                        }
                        guard targetWorkspace != nil else {
                            throw MCPError.invalidParams("No active workspace in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
                        }
                    }

                    let workspace = targetWorkspace!
                    try Self.validateAddFolderWorkspace(workspace)

                    // Get client ID for approval
                    let clientID = await networkMgr.currentClientIdentifier() ?? "unknown-client"

                    // Request approval
                    let approvalResult = await WorkspaceApprovalManager.shared.requestAddFolderApproval(
                        clientID: clientID,
                        folderPath: folderPath,
                        workspaceName: workspace.name,
                        workspaceID: workspace.id,
                        windowID: targetWindow.windowID
                    )

                    guard approvalResult.isApproved else {
                        throw MCPError.invalidRequest("Folder addition was denied by the user.")
                    }

                    // Add the folder to the workspace
                    do {
                        try await targetWindow.workspaceManager.addFolder(folderURL, to: workspace)
                    } catch {
                        if let addError = error as? WorkspaceManagerViewModel.AddFolderError {
                            throw MCPError.invalidParams(addError.agentMessage)
                        }
                        throw MCPError.internalError("Failed to add folder: \(error.localizedDescription)")
                    }

                    // Return updated workspace info
                    let updatedWorkspace = await MainActor.run {
                        targetWindow.workspaceManager.workspace(withID: workspace.id)
                    }

                    if let updated = updatedWorkspace {
                        let summary = MCPWorkspaceSummary(
                            id: updated.id,
                            name: updated.name,
                            allRepoPaths: updated.repoPaths,
                            showingWindowIDs: [],
                            isHidden: updated.isHiddenInMenus
                        )
                        return ManageWorkspacesResponse(action: "add_folder", workspaces: [summary], status: "ok")
                    }

                    return ManageWorkspacesResponse(action: "add_folder", workspaces: nil, status: "ok")

                case "remove_folder":
                    // Remove a folder from a workspace
                    // workspace param is optional - defaults to active workspace
                    let rawWorkspaceParam = args["workspace"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

                    guard let folderPath = args["folder_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !folderPath.isEmpty
                    else {
                        throw MCPError.invalidParams("Missing required 'folder_path' parameter for 'remove_folder' action.")
                    }

                    // Determine target window
                    let targetWindowIDArg = args["window_id"]?.intValue
                    let windows = await MainActor.run { self.windowStates.allWindows }

                    let targetWindowOpt: WindowState? = if let wid = targetWindowIDArg {
                        windows.first(where: { $0.windowID == wid })
                    } else {
                        windows.only
                    }

                    if let wid = targetWindowIDArg, targetWindowOpt == nil {
                        let validIDs = windows.map { String($0.windowID) }.joined(separator: ", ")
                        throw MCPError.invalidParams("Unknown window_id \(wid). Valid window IDs: \(validIDs)")
                    }
                    if targetWindowIDArg == nil, windows.count != 1 {
                        throw MCPError.invalidParams(Self.bindContextWindowSelectionMessage)
                    }
                    guard let targetWindow = targetWindowOpt else {
                        throw MCPError.invalidParams("No valid target window found")
                    }

                    // Resolve workspace: explicit param, or default to active workspace
                    var targetWorkspace: WorkspaceModel? = nil
                    if let param = rawWorkspaceParam, !param.isEmpty {
                        if let targetID = UUID(uuidString: param) {
                            targetWorkspace = await MainActor.run {
                                targetWindow.workspaceManager.workspace(withID: targetID)
                            }
                        } else {
                            targetWorkspace = await MainActor.run {
                                targetWindow.workspaceManager.workspaces.first(where: { $0.name == param })
                            }
                        }
                        guard targetWorkspace != nil else {
                            throw MCPError.invalidParams("Unknown workspace '\(param)'")
                        }
                    } else {
                        // Default to active workspace
                        targetWorkspace = await MainActor.run {
                            targetWindow.workspaceManager.activeWorkspace
                        }
                        guard targetWorkspace != nil else {
                            throw MCPError.invalidParams("No active workspace in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
                        }
                    }

                    let workspace = targetWorkspace!

                    // Verify folder is in the workspace
                    let normalizedPath = (folderPath as NSString).standardizingPath
                    let folderInWorkspace = workspace.repoPaths.contains { path in
                        let normalized = (path as NSString).standardizingPath
                        return normalized.caseInsensitiveCompare(normalizedPath) == .orderedSame
                    }

                    guard folderInWorkspace else {
                        throw MCPError.invalidParams("Folder '\(folderPath)' is not in workspace '\(workspace.name)'")
                    }

                    // Get client ID for approval
                    let clientID = await networkMgr.currentClientIdentifier() ?? "unknown-client"

                    // Request approval
                    let approvalResult = await WorkspaceApprovalManager.shared.requestRemoveFolderApproval(
                        clientID: clientID,
                        folderPath: folderPath,
                        workspaceName: workspace.name,
                        workspaceID: workspace.id,
                        windowID: targetWindow.windowID
                    )

                    guard approvalResult.isApproved else {
                        throw MCPError.invalidRequest("Folder removal was denied by the user.")
                    }

                    // Remove the folder from the workspace
                    await targetWindow.workspaceManager.removeFolder(folderPath, from: workspace)

                    // Return updated workspace info
                    let updatedWorkspace = await MainActor.run {
                        targetWindow.workspaceManager.workspace(withID: workspace.id)
                    }

                    if let updated = updatedWorkspace {
                        let summary = MCPWorkspaceSummary(
                            id: updated.id,
                            name: updated.name,
                            allRepoPaths: updated.repoPaths,
                            showingWindowIDs: [],
                            isHidden: updated.isHiddenInMenus
                        )
                        return ManageWorkspacesResponse(action: "remove_folder", workspaces: [summary], status: "ok")
                    }

                    return ManageWorkspacesResponse(action: "remove_folder", workspaces: nil, status: "ok")

                case "list_tabs":
                    let targetWindow = try await resolveTargetWindow(windowID: args["window_id"]?.intValue)
                    let connectionID = await networkMgr.currentConnectionUUID()
                    let (workspace, activeTabID, tabs, boundTabID): (WorkspaceModel?, UUID?, [ComposeTabState], UUID?) = await MainActor.run {
                        let workspace = targetWindow.workspaceManager.activeWorkspace
                        return (
                            workspace,
                            workspace?.activeComposeTabID,
                            workspace?.composeTabs ?? [],
                            targetWindow.mcpServer.boundTabID(forConnection: connectionID)
                        )
                    }

                    guard let workspace else {
                        throw MCPError.invalidParams("No active workspace loaded in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
                    }

                    let summaries = await MainActor.run {
                        tabs.map {
                            self.makeComposeTabSummary(
                                tab: $0,
                                workspace: workspace,
                                windowID: targetWindow.windowID,
                                activeTabID: activeTabID,
                                boundTabID: boundTabID
                            )
                        }
                    }
                    return ManageWorkspacesResponse(action: "list_tabs", workspaces: nil, tabs: summaries, status: "ok")

                case "select_tab":
                    guard let rawTabParam = args["tab"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawTabParam.isEmpty
                    else {
                        throw MCPError.invalidParams("Missing required 'tab' parameter (UUID or name) for 'select_tab' action.")
                    }

                    let targetWindow = try await resolveTargetWindow(windowID: args["window_id"]?.intValue)
                    let shouldFocus = args["focus"]?.boolValue ?? false
                    let connectionID = await networkMgr.currentConnectionUUID()
                    let clientName = await networkMgr.currentClientIdentifier()
                    let (workspace, tabs): (WorkspaceModel?, [ComposeTabState]) = await MainActor.run {
                        let workspace = targetWindow.workspaceManager.activeWorkspace
                        return (workspace, workspace?.composeTabs ?? [])
                    }

                    guard let workspace else {
                        throw MCPError.invalidParams("No active workspace loaded in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
                    }
                    guard let connectionID else {
                        throw MCPError.internalError("No active connection context")
                    }

                    let tab = try await MainActor.run {
                        try self.resolveComposeTab(rawTabParam: rawTabParam, tabs: tabs)
                    }

                    try await networkMgr.setActiveWindowForCurrentConnection(targetWindow.windowID)
                    try await MainActor.run {
                        try targetWindow.mcpServer.bindTabForConnection(
                            connectionID: connectionID,
                            clientName: clientName,
                            tabID: tab.id,
                            workspaceID: workspace.id,
                            windowID: targetWindow.windowID
                        )
                    }

                    if shouldFocus {
                        await targetWindow.promptManager.switchComposeTab(tab.id)
                    }

                    return ManageWorkspacesResponse(action: "select_tab", workspaces: nil, status: "ok")

                case "create_tab":
                    let targetWindow = try await resolveTargetWindow(windowID: args["window_id"]?.intValue)
                    let connectionID = await networkMgr.currentConnectionUUID()
                    let clientName = await networkMgr.currentClientIdentifier()
                    let mode = args["mode"]?.stringValue?.lowercased() ?? "blank"
                    let shouldBind = args["bind"]?.boolValue ?? true
                    let shouldFocus = args["focus"]?.boolValue ?? false
                    let requestedName = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

                    let (workspace, activeTabID, tabs, boundTabID): (WorkspaceModel?, UUID?, [ComposeTabState], UUID?) = await MainActor.run {
                        let workspace = targetWindow.workspaceManager.activeWorkspace
                        return (
                            workspace,
                            workspace?.activeComposeTabID,
                            workspace?.composeTabs ?? [],
                            targetWindow.mcpServer.boundTabID(forConnection: connectionID)
                        )
                    }

                    guard let workspace else {
                        throw MCPError.invalidParams("No active workspace loaded in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
                    }

                    let newTab: ComposeTabState
                    switch mode {
                    case "blank":
                        guard let created = await targetWindow.promptManager.createBackgroundComposeTab(strategy: .blank, name: requestedName) else {
                            throw MCPError.internalError("Failed to create compose tab")
                        }
                        newTab = created
                    case "fork":
                        let sourceRaw = args["source_tab"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let sourceTab: ComposeTabState
                        if let sourceRaw, !sourceRaw.isEmpty {
                            sourceTab = try await MainActor.run {
                                try self.resolveComposeTab(rawTabParam: sourceRaw, tabs: tabs)
                            }
                        } else if let boundTabID, let boundTab = tabs.first(where: { $0.id == boundTabID }) {
                            sourceTab = boundTab
                        } else if let activeTabID, let activeTab = tabs.first(where: { $0.id == activeTabID }) {
                            sourceTab = activeTab
                        } else {
                            throw MCPError.invalidParams("create_tab mode='fork' requires a source tab or an active/bound tab")
                        }
                        guard let created = await targetWindow.promptManager.createBackgroundForkComposeTab(sourceTabID: sourceTab.id, named: requestedName) else {
                            throw MCPError.internalError("Failed to fork compose tab")
                        }
                        newTab = created
                    default:
                        throw MCPError.invalidParams("Unsupported create_tab mode '\(mode)'. Use 'blank' or 'fork'.")
                    }

                    try await networkMgr.setActiveWindowForCurrentConnection(targetWindow.windowID)

                    if shouldBind, let connectionID {
                        try await MainActor.run {
                            try targetWindow.mcpServer.bindTabForConnection(
                                connectionID: connectionID,
                                clientName: clientName,
                                tabID: newTab.id,
                                workspaceID: workspace.id,
                                windowID: targetWindow.windowID
                            )
                        }
                    }

                    if shouldFocus {
                        await targetWindow.promptManager.switchComposeTab(newTab.id)
                    }

                    let summary = await MainActor.run {
                        self.makeComposeTabSummary(
                            tab: newTab,
                            workspace: workspace,
                            windowID: targetWindow.windowID,
                            activeTabID: shouldFocus ? newTab.id : activeTabID,
                            boundTabID: shouldBind ? newTab.id : boundTabID
                        )
                    }
                    return ManageWorkspacesResponse(action: "create_tab", workspaces: nil, tabs: [summary], status: "ok")

                case "close_tab":
                    let rawTabParam = args["tab"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let contextID = try Self.parseContextID(args["context_id"], action: "close_tab")

                    let targetWindow = try await resolveTargetWindow(windowID: args["window_id"]?.intValue)
                    let allowActive = args["allow_active"]?.boolValue ?? false
                    let connectionID = await networkMgr.currentConnectionUUID()
                    let (workspace, activeTabID, tabs, boundTabID): (WorkspaceModel?, UUID?, [ComposeTabState], UUID?) = await MainActor.run {
                        let workspace = targetWindow.workspaceManager.activeWorkspace
                        return (
                            workspace,
                            workspace?.activeComposeTabID,
                            workspace?.composeTabs ?? [],
                            targetWindow.mcpServer.boundTabID(forConnection: connectionID)
                        )
                    }

                    guard let workspace, !tabs.isEmpty else {
                        throw MCPError.invalidParams("No active workspace with compose tabs loaded in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
                    }

                    let tab = try await MainActor.run {
                        try self.resolveComposeTab(
                            rawTabParam: rawTabParam,
                            contextID: contextID,
                            tabs: tabs,
                            action: "close_tab"
                        )
                    }
                    guard tabs.count > 1 else {
                        throw MCPError.invalidParams("Cannot close the last remaining compose tab.")
                    }
                    if activeTabID == tab.id, !allowActive {
                        throw MCPError.invalidParams("Refusing to close the active visible tab. Pass allow_active=true to close it explicitly.")
                    }

                    let liveRunIDs = await MainActor.run {
                        targetWindow.mcpServer.liveRunIDsBound(toTabID: tab.id)
                    }
                    if !liveRunIDs.isEmpty {
                        let joined = liveRunIDs.map(\.uuidString).joined(separator: ", ")
                        throw MCPError.invalidParams("Refusing to close tab '\(tab.name)' because it has live bound runs: \(joined)")
                    }

                    let summary = await MainActor.run {
                        self.makeComposeTabSummary(
                            tab: tab,
                            workspace: workspace,
                            windowID: targetWindow.windowID,
                            activeTabID: activeTabID,
                            boundTabID: boundTabID
                        )
                    }

                    await targetWindow.promptManager.closeComposeTab(tab.id)

                    return ManageWorkspacesResponse(action: "close_tab", workspaces: nil, tabs: [summary], status: "ok")

                default:
                    throw MCPError.invalidParams("Unsupported action '\(action)'. Use 'list', 'switch', 'create', 'hide', 'unhide', 'delete', 'add_folder', 'remove_folder', 'list_tabs', 'select_tab', 'create_tab', or 'close_tab'.")
                }
            }
        )

        // Update the cache with the new tools
        await toolsCache.update(newTools)
    }

    // ---------------------------------------------------------------------
    // MARK: Tools

    /// ---------------------------------------------------------------------
    nonisolated var tools: [Tool] {
        get async {
            await toolsCache.get()
        }
    }
}
