import Foundation

/// Desktop `WorkspaceApprovalOperation` raw values. MCP `manage_workspaces` uses
/// the short action names `create` / `delete` / `add_folder` / `remove_folder`.
public enum WorkspaceApprovalOperation: String, Codable, CaseIterable, Sendable, Hashable {
    case createWorkspace = "create_workspace"
    case deleteWorkspace = "delete_workspace"
    case addFolder = "add_folder"
    case removeFolder = "remove_folder"

    public init?(mcpAction: String) {
        switch mcpAction {
        case "create", "create_workspace": self = .createWorkspace
        case "delete", "delete_workspace": self = .deleteWorkspace
        case "add_folder": self = .addFolder
        case "remove_folder": self = .removeFolder
        default: return nil
        }
    }

    public var deniedByUserMessage: String {
        switch self {
        case .createWorkspace: "Workspace creation was denied by the user."
        case .deleteWorkspace: "Workspace deletion was denied by the user."
        case .addFolder: "Folder addition was denied by the user."
        case .removeFolder: "Folder removal was denied by the user."
        }
    }
}

public struct WorkspaceApprovalClientPolicy: Codable, Hashable, Sendable {
    public var clientID: String
    public var allowedOperations: Set<WorkspaceApprovalOperation>
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(
        clientID: String,
        allowedOperations: Set<WorkspaceApprovalOperation> = [],
        createdAt: Date = Date(timeIntervalSince1970: 0),
        lastUsedAt: Date? = nil
    ) {
        self.clientID = clientID
        self.allowedOperations = allowedOperations
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public func allows(_ operation: WorkspaceApprovalOperation) -> Bool {
        allowedOperations.contains(operation)
    }
}

/// Desktop `WorkspaceApprovalSettings` persisted as JSON in UserDefaults
/// `workspace.approvalSettings`. Missing document → `autoApproveAll` false.
public struct WorkspaceApprovalSettings: Codable, Hashable, Sendable {
    public var autoApproveAll: Bool
    public var autoApproveOperations: Set<WorkspaceApprovalOperation>
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoApproveAll = try container.decodeIfPresent(Bool.self, forKey: .autoApproveAll) ?? false
        autoApproveOperations = try container.decodeIfPresent(Set<WorkspaceApprovalOperation>.self, forKey: .autoApproveOperations) ?? []
        clientPolicies = try container.decodeIfPresent([String: WorkspaceApprovalClientPolicy].self, forKey: .clientPolicies) ?? [:]
    }

    public func shouldAutoApprove(operation: WorkspaceApprovalOperation, clientID: String) -> Bool {
        if autoApproveAll { return true }
        if autoApproveOperations.contains(operation) { return true }
        return clientPolicies.contains { storedClientID, policy in
            MCPClientIdentity.matches(storedClientID, clientID) && policy.allows(operation)
        }
    }

    /// Desktop `WorkspaceApprovalManager.setAutoApproveOperation`.
    public mutating func setAutoApproveOperation(_ operation: WorkspaceApprovalOperation, enabled: Bool) {
        if enabled {
            autoApproveOperations.insert(operation)
        } else {
            autoApproveOperations.remove(operation)
        }
    }

    /// Desktop `WorkspaceApprovalManager.addAutoApproval` (Always Allow).
    public mutating func addAutoApproval(
        clientID: String,
        operation: WorkspaceApprovalOperation,
        now: Date = Date()
    ) {
        let storageKey = matchingPolicyKeys(for: clientID).first ?? clientID
        var policy = clientPolicies[storageKey] ?? WorkspaceApprovalClientPolicy(
            clientID: storageKey,
            createdAt: now
        )
        policy.allowedOperations.insert(operation)
        policy.lastUsedAt = now
        clientPolicies[storageKey] = policy
    }

    /// Desktop `WorkspaceApprovalManager.matchingPolicyKeys(for:)`.
    public func matchingPolicyKeys(for clientID: String) -> [String] {
        let exactMatches = clientPolicies.keys.filter { $0 == clientID }
        let familyMatches = clientPolicies.keys
            .filter { $0 != clientID && MCPClientIdentity.matches($0, clientID) }
            .sorted()
        return exactMatches + familyMatches
    }
}

public struct WorkspaceApprovalSettingsSnapshot: Codable, Hashable, Sendable {
    public let settings: WorkspaceApprovalSettings
    public let revision: Int64
    public let updatedAt: Date

    public init(settings: WorkspaceApprovalSettings, revision: Int64, updatedAt: Date) {
        self.settings = settings
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct ReplaceWorkspaceApprovalSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let settings: WorkspaceApprovalSettings

    public init(expectedRevision: Int64, settings: WorkspaceApprovalSettings) {
        self.expectedRevision = expectedRevision
        self.settings = settings
    }
}
