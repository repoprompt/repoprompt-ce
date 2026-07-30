@testable import RepoPromptApp
import XCTest

final class PathMatchingRecoveryTests: XCTestCase {
    func testAliasAndAbsoluteResolutionStayScopedToTheMatchingRoot() {
        let snapshot = makeSnapshot(files: [
            ("src/App.swift", "/Users/test/web"),
            ("src/App.swift", "/Users/test/mobile"),
            ("src/OnlyWeb.swift", "/Users/test/web")
        ])

        let aliasHit = PathMatcher.locate(userPath: "web/src/App.swift", snapshot: snapshot)
        XCTAssertEqual(aliasHit?.rootPath, "/Users/test/web")
        XCTAssertEqual(aliasHit?.correctedPath, "src/App.swift")

        let absoluteHit = PathMatcher.locate(userPath: "/Users/test/mobile/src/App.swift", snapshot: snapshot)
        XCTAssertEqual(absoluteHit?.rootPath, "/Users/test/mobile")
        XCTAssertEqual(absoluteHit?.correctedPath, "src/App.swift")
    }

    func testUnicodeAndCaseInsensitiveLookupPreserveStoredRelativePath() {
        let snapshot = makeSnapshot(files: [
            ("Sources/Ångström.swift", "/Users/test/project"),
            ("Sources/文件.swift", "/Users/test/project")
        ])

        let caseFolded = PathMatcher.locate(userPath: "ångström.swift", snapshot: snapshot)
        XCTAssertEqual(caseFolded?.rootPath, "/Users/test/project")
        XCTAssertEqual(caseFolded?.correctedPath, "Sources/Ångström.swift")

        let absoluteUnicode = PathMatcher.locate(userPath: "/Users/test/project/Sources/文件.swift", snapshot: snapshot)
        XCTAssertEqual(absoluteUnicode?.correctedPath, "Sources/文件.swift")
    }

    func testMovePathResolverRejectsAmbiguousAndCrossRootAliases() throws {
        let source = makeRoot(id: UUID(), name: "AppA", fullPath: "/Users/test/AppA")
        let other = makeRoot(id: UUID(), name: "AppB", fullPath: "/Users/test/AppB")

        XCTAssertThrowsError(
            try MovePathResolver.resolveRelativePathInRoot(
                userPath: "AppB/Sources/File.swift",
                sourceRoot: source,
                visibleRoots: [source, other]
            )
        ) { error in
            guard case let MovePathResolver.Error.crossRootAlias(alias, resolvedRoot) = error else {
                return XCTFail("Expected crossRootAlias, got \(error)")
            }
            XCTAssertEqual(alias, "AppB")
            XCTAssertEqual(resolvedRoot, other)
        }

        let duplicateA = makeRoot(id: UUID(), name: "App", fullPath: "/Users/test/AppOne")
        let duplicateB = makeRoot(id: UUID(), name: "App", fullPath: "/Users/test/AppTwo")
        XCTAssertThrowsError(
            try MovePathResolver.resolveRelativePathInRoot(
                userPath: "App/Sources/File.swift",
                sourceRoot: duplicateA,
                visibleRoots: [duplicateA, duplicateB]
            )
        ) { error in
            guard case let MovePathResolver.Error.ambiguousAlias(alias, matchingRoots) = error else {
                return XCTFail("Expected ambiguousAlias, got \(error)")
            }
            XCTAssertEqual(alias, "App")
            XCTAssertEqual(Set(matchingRoots), Set([duplicateA, duplicateB]))
        }
    }

    private func makeRoot(id: UUID = UUID(), name: String, fullPath: String) -> MovePathResolver.Root {
        MovePathResolver.Root(id: id, name: name, fullPath: fullPath)
    }

    private func makeSnapshot(
        files: [(relativePath: String, rootPath: String)],
        selectedFiles: Set<String> = []
    ) -> PathMatchSnapshot {
        var filesByFullPath: [String: FileRecord] = [:]
        var foldersByFullPath: [String: FolderRecord] = [:]
        var rootFoldersByPath: [String: FolderRecord] = [:]

        for file in files {
            let rootPath = StandardizedPath.absolute(file.rootPath)
            let relativePath = StandardizedPath.relative(file.relativePath)
            let rootName = (rootPath as NSString).lastPathComponent
            rootFoldersByPath[rootPath] = FrozenFolderRecord(
                name: rootName,
                relativePath: "",
                fullPath: rootPath,
                rootPath: rootPath
            )

            let fullPath = StandardizedPath.join(
                standardizedRoot: rootPath,
                standardizedRelativePath: relativePath
            )
            filesByFullPath[fullPath] = FrozenFileRecord(
                name: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                fullPath: fullPath,
                rootFolderPath: rootPath
            )

            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for depth in 1 ..< components.count {
                let folderRelativePath = components.prefix(depth).joined(separator: "/")
                let folderFullPath = StandardizedPath.join(
                    standardizedRoot: rootPath,
                    standardizedRelativePath: folderRelativePath
                )
                foldersByFullPath[folderFullPath] = FrozenFolderRecord(
                    name: components[depth - 1],
                    relativePath: folderRelativePath,
                    fullPath: folderFullPath,
                    rootPath: rootPath
                )
            }
        }

        return PathMatchSnapshot(
            filesByFullPath: filesByFullPath,
            foldersByFullPath: foldersByFullPath,
            rootFolders: rootFoldersByPath.keys.sorted().compactMap { rootFoldersByPath[$0] },
            selectedFileFullPaths: selectedFiles
        )
    }
}
