//
//  WorkspaceApprovalTypes.swift
//  RepoPrompt
//
//  Created by RepoPrompt – Workspace MCP approval integration
//

import Foundation

// MARK: - Workspace Approval Operation Types

/// The type of workspace operation requiring approval.
public enum WorkspaceApprovalOperation: String, Codable, Sendable, CaseIterable {
    case createWorkspace = "create_workspace"
    case deleteWorkspace = "delete_workspace"
    case addFolder = "add_folder"
    case removeFolder = "remove_folder"

    /// Human-readable action verb for display.
    var actionVerb: String {
        switch self {
        case .createWorkspace: "create"
        case .deleteWorkspace: "delete"
        case .addFolder: "add a folder to"
        case .removeFolder: "remove a folder from"
        }
    }

    /// Human-readable operation name for display.
    var displayName: String {
        switch self {
        case .createWorkspace: "Create Workspace"
        case .deleteWorkspace: "Delete Workspace"
        case .addFolder: "Add Folder"
        case .removeFolder: "Remove Folder"
        }
    }

    /// Icon name for the operation.
    var iconName: String {
        switch self {
        case .createWorkspace: "folder.badge.plus"
        case .deleteWorkspace: "folder.badge.minus"
        case .addFolder: "folder.fill.badge.plus"
        case .removeFolder: "folder.fill.badge.minus"
        }
    }

    /// Risk level for the operation.
    var riskLevel: WorkspaceApprovalRiskLevel {
        switch self {
        case .createWorkspace: .low
        case .deleteWorkspace: .high
        case .addFolder: .medium
        case .removeFolder: .medium
        }
    }
}

// MARK: - Risk Levels

/// Risk classification for workspace operations.
public enum WorkspaceApprovalRiskLevel: String, Codable, Sendable {
    case low
    case medium
    case high

    /// Warning message for the risk level.
    var warningMessage: String {
        switch self {
        case .low:
            "This is a low-risk operation that can be easily undone."
        case .medium:
            "This operation modifies your workspace configuration."
        case .high:
            "⚠️ This operation cannot be undone. Workspace data may be permanently deleted."
        }
    }

    /// Color indicator for the risk level.
    var colorName: String {
        switch self {
        case .low: "green"
        case .medium: "orange"
        case .high: "red"
        }
    }
}

// MARK: - Approval Request

/// A pending workspace operation approval request.
public struct WorkspaceApprovalRequest: Identifiable, Sendable {
    public let id: UUID
    public let clientID: String
    public let operation: WorkspaceApprovalOperation
    public let timestamp: Date

    // Operation-specific details
    public let workspaceName: String?
    public let workspaceID: UUID?
    public let folderPath: String?
    public let windowID: Int?

    /// The target window ID for the operation.
    public var targetWindowID: Int? {
        windowID
    }

    public init(
        id: UUID = UUID(),
        clientID: String,
        operation: WorkspaceApprovalOperation,
        workspaceName: String? = nil,
        workspaceID: UUID? = nil,
        folderPath: String? = nil,
        windowID: Int? = nil
    ) {
        self.id = id
        self.clientID = clientID
        self.operation = operation
        timestamp = Date()
        self.workspaceName = workspaceName
        self.workspaceID = workspaceID
        self.folderPath = folderPath
        self.windowID = windowID
    }

    /// Human-readable summary of what's being requested.
    public var summary: String {
        switch operation {
        case .createWorkspace:
            let name = workspaceName ?? "unnamed"
            return "Create workspace \"\(name)\""
        case .deleteWorkspace:
            let name = workspaceName ?? "unknown"
            return "Delete workspace \"\(name)\""
        case .addFolder:
            let folder = (folderPath as NSString?)?.lastPathComponent ?? "folder"
            let ws = workspaceName ?? "current workspace"
            return "Add \"\(folder)\" to \"\(ws)\""
        case .removeFolder:
            let folder = (folderPath as NSString?)?.lastPathComponent ?? "folder"
            let ws = workspaceName ?? "current workspace"
            return "Remove \"\(folder)\" from \"\(ws)\""
        }
    }

    /// Detailed description of the operation for the approval dialog.
    public var detailedDescription: String {
        switch operation {
        case .createWorkspace:
            "A new workspace named \"\(workspaceName ?? "unnamed")\" will be created."
        case .deleteWorkspace:
            "The workspace \"\(workspaceName ?? "unknown")\" and all its saved state will be permanently deleted."
        case .addFolder:
            "The folder at \"\(folderPath ?? "unknown path")\" will be added to the workspace."
        case .removeFolder:
            "The folder \"\(folderPath ?? "unknown")\" will be removed from the workspace. The actual folder on disk will NOT be deleted."
        }
    }
}

// MARK: - Approval Policies

/// Per-client auto-approval policy for workspace operations.
public struct WorkspaceApprovalClientPolicy: Codable, Sendable, Identifiable {
    public var id: String {
        clientID
    }

    public let clientID: String
    public var allowedOperations: Set<WorkspaceApprovalOperation>
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(clientID: String, allowedOperations: Set<WorkspaceApprovalOperation> = []) {
        self.clientID = clientID
        self.allowedOperations = allowedOperations
        createdAt = Date()
        lastUsedAt = nil
    }

    /// Check if an operation is allowed for this client.
    public func allows(_ operation: WorkspaceApprovalOperation) -> Bool {
        allowedOperations.contains(operation)
    }
}

// MARK: - Global Approval Settings

/// Global settings for workspace operation approvals.
public struct WorkspaceApprovalSettings: Codable, Sendable {
    /// When true, all workspace operations from all clients are auto-approved.
    public var autoApproveAll: Bool

    /// Per-operation global auto-approve settings.
    public var autoApproveOperations: Set<WorkspaceApprovalOperation>

    /// Per-client policies.
    public var clientPolicies: [String: WorkspaceApprovalClientPolicy]

    public init(
        autoApproveAll: Bool = false,
        autoApproveOperations: Set<WorkspaceApprovalOperation> = [],
        clientPolicies: [String: WorkspaceApprovalClientPolicy] = [:]
    ) {
        self.autoApproveAll = autoApproveAll
        self.autoApproveOperations = autoApproveOperations
        self.clientPolicies = clientPolicies
    }

    /// Check if an operation should be auto-approved.
    public func shouldAutoApprove(operation: WorkspaceApprovalOperation, clientID: String) -> Bool {
        // Global auto-approve
        if autoApproveAll {
            return true
        }

        // Per-operation global setting
        if autoApproveOperations.contains(operation) {
            return true
        }

        return clientPolicies.contains { storedClientID, policy in
            MCPClientIdentity.matches(storedClientID, clientID) && policy.allows(operation)
        }
    }
}

// MARK: - Approval Result

/// The result of an approval request.
public enum WorkspaceApprovalResult: Sendable {
    case approved(alwaysAllow: Bool)
    case denied
    case timeout

    public var isApproved: Bool {
        if case .approved = self {
            return true
        }
        return false
    }
}

// MARK: - Hashable Conformance

extension WorkspaceApprovalOperation: Hashable {}

extension WorkspaceApprovalClientPolicy: Hashable {
    public static func == (lhs: WorkspaceApprovalClientPolicy, rhs: WorkspaceApprovalClientPolicy) -> Bool {
        lhs.clientID == rhs.clientID && lhs.allowedOperations == rhs.allowedOperations
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(clientID)
        hasher.combine(allowedOperations)
    }
}
