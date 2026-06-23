import Foundation

struct HeadlessConfigurationDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var allowedRoots: [HeadlessAllowedRoot]
    var activeWorkspaceID: UUID?
    var permissions: HeadlessPermissions
    var createdAt: Date
    var updatedAt: Date

    init(now: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        allowedRoots = []
        activeWorkspaceID = nil
        permissions = HeadlessPermissions()
        createdAt = now
        updatedAt = now
    }

    mutating func touch(now: Date = Date()) {
        updatedAt = now
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case allowedRoots = "allowed_roots"
        case activeWorkspaceID = "active_workspace_id"
        case permissions
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HeadlessAllowedRoot: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var path: String
    var resolvedPath: String
    var addedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case resolvedPath = "resolved_path"
        case addedAt = "added_at"
    }
}

struct HeadlessPermissions: Codable, Equatable {
    static let supportedNames = [
        "write_files",
        "vcs_write",
        "launch_agents",
        "export_outside_state_directory"
    ]

    var writeFiles: Bool
    var vcsWrite: Bool
    var launchAgents: Bool
    var exportOutsideStateDirectory: Bool

    init(
        writeFiles: Bool = false,
        vcsWrite: Bool = false,
        launchAgents: Bool = false,
        exportOutsideStateDirectory: Bool = false
    ) {
        self.writeFiles = writeFiles
        self.vcsWrite = vcsWrite
        self.launchAgents = launchAgents
        self.exportOutsideStateDirectory = exportOutsideStateDirectory
    }

    func value(for name: String) throws -> Bool {
        switch name {
        case "write_files": writeFiles
        case "vcs_write": vcsWrite
        case "launch_agents": launchAgents
        case "export_outside_state_directory": exportOutsideStateDirectory
        default:
            throw HeadlessCommandError("Unknown permission '\(name)'. Supported permissions: \(Self.supportedNames.joined(separator: ", "))", exitCode: 2)
        }
    }

    mutating func set(_ name: String, to value: Bool) throws {
        switch name {
        case "write_files": writeFiles = value
        case "vcs_write": vcsWrite = value
        case "launch_agents": launchAgents = value
        case "export_outside_state_directory": exportOutsideStateDirectory = value
        default:
            throw HeadlessCommandError("Unknown permission '\(name)'. Supported permissions: \(Self.supportedNames.joined(separator: ", "))", exitCode: 2)
        }
    }

    enum CodingKeys: String, CodingKey {
        case writeFiles = "write_files"
        case vcsWrite = "vcs_write"
        case launchAgents = "launch_agents"
        case exportOutsideStateDirectory = "export_outside_state_directory"
    }
}

struct HeadlessRootsListOutput: Codable {
    let allowedRoots: [HeadlessAllowedRoot]

    enum CodingKeys: String, CodingKey {
        case allowedRoots = "allowed_roots"
    }
}

struct HeadlessRootMutationOutput: Codable {
    let action: String
    let root: HeadlessAllowedRoot
}

struct HeadlessPermissionsOutput: Codable {
    let permissions: HeadlessPermissions
}
