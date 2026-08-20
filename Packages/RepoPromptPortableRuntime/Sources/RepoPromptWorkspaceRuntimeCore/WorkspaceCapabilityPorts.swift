import Foundation
import RepoPromptRuntimeModel

public enum WorkspaceCapabilityError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case invalidArtifactName(String)
}

public struct WorkspaceRelativePath: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(validating rawValue: String) throws {
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawValue.hasPrefix("/"),
              !rawValue.contains("\0"),
              !components.contains("..")
        else {
            throw WorkspaceCapabilityError.invalidRelativePath(rawValue)
        }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        guard let value = try? Self(validating: rawValue) else { return nil }
        self = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct WorkspaceFileSnapshot: Sendable {
    public let path: WorkspaceRelativePath
    public let contents: Data

    public init(path: WorkspaceRelativePath, contents: Data) {
        self.path = path
        self.contents = contents
    }
}

public struct WorkspaceCheckoutSnapshot: Codable, Hashable, Sendable {
    public let canonicalPath: String
    public let revision: String?

    public init(canonicalPath: String, revision: String? = nil) {
        self.canonicalPath = canonicalPath
        self.revision = revision
    }
}

public struct WorkspaceArtifactSnapshot: Sendable {
    public let name: String
    public let contents: Data

    public init(name: String, contents: Data) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            throw WorkspaceCapabilityError.invalidArtifactName(name)
        }
        self.name = name
        self.contents = contents
    }
}

public struct ProjectSourceSnapshot: Codable, Hashable, Sendable {
    public let files: [WorkspaceRelativePath]

    public init(files: [WorkspaceRelativePath]) {
        self.files = files
    }
}

public protocol WorkspaceFilesystemPort: Sendable {
    func readFile(
        grant: ResourceGrant,
        path: WorkspaceRelativePath
    ) async throws -> WorkspaceFileSnapshot
}

public protocol WorkspaceWorktreePort: Sendable {
    func checkout(grant: ResourceGrant) async throws -> WorkspaceCheckoutSnapshot
}

public protocol WorkspaceArtifactPort: Sendable {
    func loadArtifact(grant: ResourceGrant, name: String) async throws -> WorkspaceArtifactSnapshot
}

public protocol WorkspaceProjectSourcePort: Sendable {
    func projectSource(grant: ResourceGrant) async throws -> ProjectSourceSnapshot
}

public actor WorkspaceCapabilityRuntime {
    private let authority: WorkspaceRuntime
    private let filesystem: any WorkspaceFilesystemPort
    private let worktrees: any WorkspaceWorktreePort
    private let artifacts: any WorkspaceArtifactPort
    private let projectSources: any WorkspaceProjectSourcePort

    public init(
        authority: WorkspaceRuntime,
        filesystem: any WorkspaceFilesystemPort,
        worktrees: any WorkspaceWorktreePort,
        artifacts: any WorkspaceArtifactPort,
        projectSources: any WorkspaceProjectSourcePort
    ) {
        self.authority = authority
        self.filesystem = filesystem
        self.worktrees = worktrees
        self.artifacts = artifacts
        self.projectSources = projectSources
    }

    public func readFile(
        _ reference: OwnedResourceReference,
        path: WorkspaceRelativePath,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws -> WorkspaceFileSnapshot {
        let grant = try await authority.authorize(reference, requestedBy: ownerID)
        return try await filesystem.readFile(grant: grant, path: path)
    }

    public func readFile(
        grant: ResourceGrant,
        path: WorkspaceRelativePath,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws -> WorkspaceFileSnapshot {
        try await authority.validate(grant, requestedBy: ownerID)
        return try await filesystem.readFile(grant: grant, path: path)
    }

    public func checkout(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws -> WorkspaceCheckoutSnapshot {
        let grant = try await authority.authorize(reference, requestedBy: ownerID)
        return try await worktrees.checkout(grant: grant)
    }

    public func loadArtifact(
        _ reference: OwnedResourceReference,
        name: String,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws -> WorkspaceArtifactSnapshot {
        let grant = try await authority.authorize(reference, requestedBy: ownerID)
        return try await artifacts.loadArtifact(grant: grant, name: name)
    }

    public func projectSource(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws -> ProjectSourceSnapshot {
        let grant = try await authority.authorize(reference, requestedBy: ownerID)
        return try await projectSources.projectSource(grant: grant)
    }
}
