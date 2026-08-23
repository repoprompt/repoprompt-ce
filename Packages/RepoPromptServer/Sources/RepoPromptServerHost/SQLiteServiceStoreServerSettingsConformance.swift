import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence

extension SQLiteServiceStore: ServerSettingsProjectCatalogProviding {
    public func serverSettingsRootIDs(projectID: UUID) async throws -> Set<UUID> {
        try await AuthorityStoreProjectCatalog(store: self)
            .serverSettingsRootIDs(projectID: projectID)
    }
}
