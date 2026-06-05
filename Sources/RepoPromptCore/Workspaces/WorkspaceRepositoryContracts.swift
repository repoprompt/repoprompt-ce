import Foundation

package protocol WorkspaceRepositoryLayout: Sendable {
    var repositoryRoot: URL { get }
    var indexURL: URL { get }

    func workspaceDirectory(id: UUID, name: String) -> URL
    func workspaceDocumentURL(id: UUID, name: String) -> URL
}

package enum WorkspaceRepositoryDiagnostic: Equatable {
    case warning(code: String, message: String)
    case recovery(code: String, message: String)
}

package protocol WorkspaceRepositoryDiagnosticsSink: Sendable {
    func record(_ diagnostic: WorkspaceRepositoryDiagnostic)
}

/// Persistence boundary adopted when the canonical app workspace domain moves into Core.
/// Existing app and headless repositories remain unchanged during Phase 1.
package protocol WorkspaceRepositoryContract: Sendable {
    associatedtype Document: Identifiable & Sendable where Document.ID == UUID

    func list() async throws -> [Document]
    func load(id: UUID) async throws -> Document?
    func save(_ document: Document) async throws
    func delete(id: UUID) async throws
    func migrateLegacyHeadlessProfileIfNeeded() async throws -> WorkspaceLegacyMigrationResult
}
