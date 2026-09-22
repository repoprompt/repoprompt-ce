@testable import RepoPromptWorkspaceCore
import XCTest

final class WorkspacePathPolicyTests: XCTestCase {
    func testStandardizedPathsNormalizeAndPreserveContainmentBoundaries() {
        XCTAssertEqual(StandardizedPath.relative("/Sources/./Models/../App.swift/"), "Sources/App.swift")
        XCTAssertEqual(StandardizedPath.join(standardizedRoot: "/repo", standardizedRelativePath: "Sources/App.swift"), "/repo/Sources/App.swift")
        XCTAssertTrue(StandardizedPath.isDescendant("/repo/Sources/App.swift", of: "/repo"))
        XCTAssertFalse(StandardizedPath.isDescendant("/repository/App.swift", of: "/repo"))
        XCTAssertEqual(StandardizedPath.diagnosticEscaped("bad\0path\n"), "bad\\0path\\n")
    }

    func testAliasResolutionUsesDeterministicGeneratedAliasesForDuplicateNames() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/Clients/One/App")
        let second = makeRoot(name: "App", fullPath: "/Users/test/Clients/Two/App")
        let roots = [first, second]

        XCTAssertEqual(ClientPathFormatter.nonAbsoluteRootAlias(root: first, visibleRoots: roots), "One/App")
        XCTAssertEqual(ClientPathFormatter.nonAbsoluteRootAlias(root: second, visibleRoots: roots), "Two/App")

        XCTAssertEqual(
            WorkspaceAliasResolver.resolve(
                userPath: "Two/App/Sources/File.swift",
                roots: roots,
                options: RootAliasOptions(requireRemainder: true)
            ),
            .prefixed(root: second, alias: "Two/App", remainder: "Sources/File.swift")
        )
    }

    func testExactFileInputParsesLiteralExplicitAndAbsoluteForms() throws {
        XCTAssertEqual(try WorkspaceExactFileInput.parse("mimic/session.py"), .relative("mimic/session.py"))
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("One/App//Sources/./File.swift"),
            .explicitRoot(alias: "One/App", relativePath: "Sources/File.swift")
        )
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("~/Sources/../File.swift"),
            .absolute(StandardizedPath.absolute(("~/Sources/../File.swift" as NSString).expandingTildeInPath))
        )
        XCTAssertEqual(try WorkspaceExactFileInput.parse("App:Sources/File.swift"), .relative("App:Sources/File.swift"))
        XCTAssertEqual(try WorkspaceExactFileInput.parse(" Target.swift"), .relative(" Target.swift"))
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("~/Project//File.swift"),
            .explicitRoot(alias: "~/Project", relativePath: "File.swift")
        )
    }

    func testExactFileInputRejectsMalformedExplicitQualifier() {
        for input in ["App//", "App///File.swift", "App//Dir//File.swift", "../File.swift"] {
            XCTAssertThrowsError(try WorkspaceExactFileInput.parse(input), "Expected rejection for \(input)")
        }
    }

    func testExplicitWorkspaceFilePathUsesCanonicalGeneratedAlias() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/Clients/One/App")
        let second = makeRoot(name: "App", fullPath: "/Users/test/Clients/Two/App")

        XCTAssertEqual(
            ClientPathFormatter.explicitWorkspaceFilePath(
                root: second,
                relativePath: "Sources/File.swift",
                visibleRoots: [first, second]
            ),
            "root@\(second.id.uuidString.lowercased())//Sources/File.swift"
        )
    }

    func testExactRootAliasesRemainUniqueAcrossDisplayAliasCollisions() {
        let first = makeRoot(name: "Project", fullPath: "/Docs")
        let second = makeRoot(name: "Project", fullPath: "/tmp/Project")
        let canonicalNameCollision = makeRoot(name: "Docs", fullPath: "/else/Docs")
        let generatedAliasCollision = makeRoot(
            name: "root@\(first.id.uuidString.lowercased())",
            fullPath: "/natural/collision"
        )
        let roots = [first, second, canonicalNameCollision, generatedAliasCollision]
        let aliases = ClientPathFormatter.exactRootAliases(visibleRoots: roots)

        XCTAssertEqual(Set(aliases.values.map { $0.lowercased() }).count, roots.count)
        XCTAssertNotEqual(aliases[first.id]?.lowercased(), aliases[canonicalNameCollision.id]?.lowercased())
        XCTAssertTrue(
            ClientPathFormatter.explicitWorkspaceFilePath(
                root: first,
                relativePath: "shared.txt",
                visibleRoots: roots
            ).hasSuffix("//shared.txt")
        )
    }

    func testAmbiguousRootMessageUsesExplicitQualifier() {
        let root = makeRoot(name: "App", fullPath: "/Users/test/App")
        let message = PathResolutionIssueRenderer.message(
            for: .ambiguousRootMatch(input: "Sources/File.swift", candidateRoots: [root])
        )

        XCTAssertTrue(message.contains("<root-alias>//<relative-path>"))
    }

    func testCreatePreflightRejectsAmbiguousAndImplicitMultiRootPaths() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/AppOne")
        let second = makeRoot(name: "App", fullPath: "/Users/test/AppTwo")

        XCTAssertThrowsError(
            try CreatePathPreflight.validate(
                userPath: "App/Sources/File.swift",
                visibleRoots: [first, second]
            )
        ) { error in
            guard case let CreatePathPreflight.Error.ambiguousAlias(alias, matchingRoots) = error else {
                return XCTFail("Expected ambiguousAlias, got \(error)")
            }
            XCTAssertEqual(alias, "App")
            XCTAssertEqual(Set(matchingRoots), Set([first, second]))
        }

        let distinct = makeRoot(name: "Docs", fullPath: "/Users/test/Docs")
        XCTAssertThrowsError(
            try CreatePathPreflight.validate(
                userPath: "Sources/File.swift",
                visibleRoots: [first, distinct]
            )
        ) { error in
            guard case let CreatePathPreflight.Error.missingAliasWithMultipleRoots(loadedRoots) = error else {
                return XCTFail("Expected missingAliasWithMultipleRoots, got \(error)")
            }
            XCTAssertEqual(loadedRoots, [first, distinct])
        }
    }

    func testMovePathResolverRejectsAmbiguousAndCrossRootAliases() throws {
        let source = makeRoot(name: "AppA", fullPath: "/Users/test/AppA")
        let other = makeRoot(name: "AppB", fullPath: "/Users/test/AppB")

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

        let duplicateA = makeRoot(name: "App", fullPath: "/Users/test/AppOne")
        let duplicateB = makeRoot(name: "App", fullPath: "/Users/test/AppTwo")
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

    private func makeRoot(id: UUID = UUID(), name: String, fullPath: String) -> WorkspaceRootRef {
        WorkspaceRootRef(id: id, name: name, fullPath: fullPath)
    }
}
