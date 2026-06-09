import Foundation

struct WorkspaceRootSetKey: Hashable {
    let normalizedPaths: [String]

    var isEmpty: Bool {
        normalizedPaths.isEmpty
    }

    init(paths: [String]) {
        var canonicalByLowercasedPath: [String: String] = [:]
        for rawPath in paths {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let normalizedPath = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard !normalizedPath.isEmpty else { continue }
            let lowercasedPath = normalizedPath.lowercased()
            if let existing = canonicalByLowercasedPath[lowercasedPath] {
                canonicalByLowercasedPath[lowercasedPath] = min(existing, normalizedPath)
            } else {
                canonicalByLowercasedPath[lowercasedPath] = normalizedPath
            }
        }
        normalizedPaths = canonicalByLowercasedPath.values.sorted {
            let lhsKey = $0.lowercased()
            let rhsKey = $1.lowercased()
            return lhsKey == rhsKey ? $0 < $1 : lhsKey < rhsKey
        }
    }

    static func == (lhs: WorkspaceRootSetKey, rhs: WorkspaceRootSetKey) -> Bool {
        lhs.normalizedPaths.map { $0.lowercased() } == rhs.normalizedPaths.map { $0.lowercased() }
    }

    func hash(into hasher: inout Hasher) {
        for path in normalizedPaths {
            hasher.combine(path.lowercased())
        }
    }
}

struct WorkspaceDuplicateGroupSummary: Identifiable, Equatable {
    let id: String
    let normalizedRepoPaths: [String]
    let canonicalWorkspaceID: UUID
    let canonicalWorkspaceName: String
    let duplicateWorkspaceIDs: [UUID]
    let duplicateWorkspaceNames: [String]
    let windowIDsByWorkspaceID: [UUID: [Int]]
}

struct WorkspaceDuplicateCleanupSkippedItem: Equatable {
    let workspaceID: UUID
    let workspaceName: String
    let windowID: Int?
    let reason: String
}

struct WorkspaceDuplicateCleanupResult: Equatable {
    let groupsDetected: Int
    let groupsConsolidated: Int
    let reassignedWindowIDs: [Int]
    let deletedWorkspaceIDs: [UUID]
    let skipped: [WorkspaceDuplicateCleanupSkippedItem]
    let backupURL: URL?
}

struct WorkspaceDuplicateCleanupBackup: Codable {
    struct BackupGroup: Codable {
        let canonicalBeforeMerge: WorkspaceModel
        let duplicatesBeforeDelete: [WorkspaceModel]
    }

    let createdAt: Date
    let groups: [BackupGroup]
}
