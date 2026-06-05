import Foundation

package struct WorkspaceLegacyMigrationRequest {
    package let profileRoot: URL
    package let destinationRoot: URL

    package init(profileRoot: URL, destinationRoot: URL) {
        self.profileRoot = profileRoot
        self.destinationRoot = destinationRoot
    }
}

package enum WorkspaceLegacyMigrationAssessment: Equatable {
    case notRequired
    case ready(documentCount: Int)
    case blocked(reason: String)
}

package enum WorkspaceLegacyMigrationResult: Equatable {
    case notRequired
    case migrated(documentCount: Int, backupURL: URL)
    case repairedStorageVersionMarker
}

package protocol WorkspaceLegacyMigrationServicing: Sendable {
    func assess(_ request: WorkspaceLegacyMigrationRequest) async throws -> WorkspaceLegacyMigrationAssessment
    func migrate(_ request: WorkspaceLegacyMigrationRequest) async throws -> WorkspaceLegacyMigrationResult
}
