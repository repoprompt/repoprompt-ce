import Foundation

package protocol WorkspaceRepositoryRootProviding: Sendable {
    func repositoryRoot() async -> URL
}

package protocol WorkspaceRepositoryLayout: Sendable {
    var repositoryRoot: URL { get }
    var indexURL: URL { get }

    func workspaceDirectory(id: UUID, name: String) -> URL
    func workspaceDocumentURL(id: UUID, name: String) -> URL
}

package struct FixedWorkspaceRepositoryLayout: WorkspaceRepositoryLayout {
    package let repositoryRoot: URL
    package var indexURL: URL {
        repositoryRoot.appendingPathComponent("workspacesIndex.json")
    }

    package init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot
    }

    package func workspaceDirectory(id: UUID, name: String) -> URL {
        repositoryRoot.appendingPathComponent("Workspace-\(name)-\(id.uuidString)", isDirectory: true)
    }

    package func workspaceDocumentURL(id: UUID, name: String) -> URL {
        workspaceDirectory(id: id, name: name).appendingPathComponent("workspace.json")
    }
}

package enum WorkspaceRepositoryDiagnostic: Equatable {
    case warning(code: String, message: String)
    case recovery(code: String, message: String)
    case event(name: String, fields: [String: String])
}

package protocol WorkspaceRepositoryDiagnosticsSink: Sendable {
    func record(_ diagnostic: WorkspaceRepositoryDiagnostic)
}

package struct NoopWorkspaceRepositoryDiagnosticsSink: WorkspaceRepositoryDiagnosticsSink {
    package init() {}
    package func record(_: WorkspaceRepositoryDiagnostic) {}
}

package struct WorkspaceIndexEntry: Codable, Equatable {
    package let id: UUID
    package var name: String
    package var customStoragePath: URL?
    package var isSystemWorkspace: Bool
    package var isHiddenInMenus: Bool

    package init(
        id: UUID,
        name: String,
        customStoragePath: URL?,
        isSystemWorkspace: Bool,
        isHiddenInMenus: Bool
    ) {
        self.id = id
        self.name = name
        self.customStoragePath = customStoragePath
        self.isSystemWorkspace = isSystemWorkspace
        self.isHiddenInMenus = isHiddenInMenus
    }

    package init(workspace: WorkspaceModel) {
        self.init(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath,
            isSystemWorkspace: workspace.isSystemWorkspace,
            isHiddenInMenus: workspace.isHiddenInMenus
        )
    }
}

package struct WorkspaceRepositoryInventory {
    package let entries: [WorkspaceIndexEntry]
    package let workspaces: [WorkspaceModel]
    package let decodeResults: [UUID: WorkspaceDocumentDecodeResult<WorkspaceModel>]

    package init(
        entries: [WorkspaceIndexEntry],
        workspaces: [WorkspaceModel],
        decodeResults: [UUID: WorkspaceDocumentDecodeResult<WorkspaceModel>] = [:]
    ) {
        self.entries = entries
        self.workspaces = workspaces
        self.decodeResults = decodeResults
    }
}

package struct WorkspaceWriteReceipt: Hashable {
    package let url: URL
    package let sequence: UInt64

    package init(url: URL, sequence: UInt64) {
        self.url = url
        self.sequence = sequence
    }
}

package struct WorkspaceWriteCompletion {
    package let receipt: WorkspaceWriteReceipt
    package let errorDescription: String?

    package var succeeded: Bool {
        errorDescription == nil
    }

    package init(receipt: WorkspaceWriteReceipt, errorDescription: String?) {
        self.receipt = receipt
        self.errorDescription = errorDescription
    }
}

/// Persistence boundary adopted by the canonical app workspace domain.
package protocol WorkspaceRepositoryContract: Sendable {
    associatedtype Document: Identifiable & Sendable where Document.ID == UUID

    func list() async throws -> [Document]
    func load(id: UUID) async throws -> Document?
    func save(_ document: Document) async throws
    func delete(id: UUID) async throws
    func migrateLegacyHeadlessProfileIfNeeded() async throws -> WorkspaceLegacyMigrationResult
}
