@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

/// Temporary Phase 4 parity coverage. Remove after the legacy app projection is
/// retired. This compares fixed immutable inputs only; it constructs no store,
/// watcher, persistence path, revision allocator, or writable backend.
@MainActor
final class WorkspaceFileContextCoreParityTests: XCTestCase {
    func testImmutableLegacyFileProjectionMatchesDirectCorePathSearchSnapshot() async throws {
        let rootID = try XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        let rootPath = "/immutable/parity/Repo"
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let inputs: [(UUID, String, String)] = try [
            (XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000001")), "Beta.swift", "Sources/Nested/Beta.swift"),
            (XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000002")), "Alpha.swift", "Sources/Alpha.swift"),
            (XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000003")), "Notes.md", "Docs/Notes.md")
        ]

        let legacyFiles = inputs.map { id, name, relativePath in
            FileViewModel(
                file: File(
                    id: id,
                    name: name,
                    path: "\(rootPath)/\(relativePath)",
                    modificationDate: modificationDate
                ),
                rootPath: rootPath,
                rootIdentifier: rootID,
                rootFolderPath: rootPath,
                fileSystemService: nil,
                relativePathOverride: relativePath
            )
        }
        let directCoreFiles = inputs.map { id, name, relativePath in
            SearchFileDescriptor(
                id: id,
                name: name,
                relativePath: relativePath,
                standardizedRelativePath: StandardizedPath.relative(relativePath),
                fullPath: "\(rootPath)/\(relativePath)",
                standardizedFullPath: StandardizedPath.absolute("\(rootPath)/\(relativePath)"),
                standardizedRootFolderPath: StandardizedPath.absolute(rootPath),
                fileExtension: (name as NSString).pathExtension,
                contentSnapshot: { _ in
                    FileSearchContentSnapshot(
                        content: nil,
                        contentRevision: nil,
                        modificationDate: modificationDate,
                        isFresh: true
                    )
                }
            )
        }

        let search = FileSearchActor()
        let aliases = [StandardizedPath.absolute(rootPath): "RepoAlias"]
        let legacySnapshot = try await search.searchPaths(
            pattern: "RepoAlias/Sources/*.swift",
            limit: 100,
            in: legacyFiles,
            caseInsensitive: true,
            aliasByRootPath: aliases
        )
        let coreSnapshot = try await search.searchPaths(
            pattern: "RepoAlias/Sources/*.swift",
            limit: 100,
            in: directCoreFiles,
            caseInsensitive: true,
            aliasByRootPath: aliases
        )

        XCTAssertEqual(coreSnapshot, legacySnapshot)
        XCTAssertEqual(coreSnapshot, [
            "\(rootPath)/Sources/Alpha.swift",
            "\(rootPath)/Sources/Nested/Beta.swift"
        ])
    }
}
