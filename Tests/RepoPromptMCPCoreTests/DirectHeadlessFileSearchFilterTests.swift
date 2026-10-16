import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

final class DirectHeadlessFileSearchFilterTests: XCTestCase {
    private static let sentinel = "HEADLESS_ABSOLUTE_FILTER_SENTINEL"

    func testAbsoluteRootFilterRetainsReadableSentinel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = Self.service(roots: [fixture.root])
        let read = try await service.readFile(Self.request(["path": .string(fixture.file.path)]))
        XCTAssertEqual(try Self.value(read), .string(Self.sentinel + "\n"))

        let result = try await Self.search(service, paths: [fixture.root.path])
        XCTAssertEqual(result, Self.expected(["fixture.txt"]))
    }

    func testAbsoluteFileFolderAndGlobFiltersPreserveComponentBoundaries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nested = fixture.root.appendingPathComponent("nested", isDirectory: true)
        try fixture.write("nested/leaf.txt")
        try fixture.write("nested-extra/leaf.txt")
        let service = Self.service(roots: [fixture.root])
        let cases: [(String, [String])] = [
            (fixture.file.path, ["fixture.txt"]),
            (nested.path + "/", ["nested/leaf.txt"]),
            (nested.appendingPathComponent("leaf.txt").path, ["nested/leaf.txt"]),
            (nested.path + "/*.txt", ["nested/leaf.txt"])
        ]
        for (path, expected) in cases {
            let result = try await Self.search(service, paths: [path])
            XCTAssertEqual(result, Self.expected(expected), path)
        }
        let aliasResult = try await Self.search(service, arguments: ["path": .string(nested.path)])
        XCTAssertEqual(aliasResult, Self.expected(["nested/leaf.txt"]))
        let pathOnly = try await service.searchFiles(Self.request([
            "pattern": .string("*.txt"), "regex": .bool(false), "mode": .string("path"),
            "filter": .object(["paths": .array([.string(nested.path)])])
        ]))
        XCTAssertEqual(try Self.value(pathOnly), .object([
            "count": .int(1), "matches": .array([.object(["path": .string("nested/leaf.txt")])])
        ]))
        let countOnly = try await Self.search(service, paths: [nested.path], arguments: ["count_only": .bool(true)])
        XCTAssertEqual(countOnly, .object(["count": .int(1)]))
    }

    func testAbsoluteFiltersResolveSymlinkAndDotComponentAliases() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("nested/leaf.txt")
        let alias = fixture.container.appendingPathComponent("root-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let service = Self.service(roots: [fixture.root])
        for path in [
            alias.appendingPathComponent("fixture.txt").path,
            fixture.root.path + "/nested/../fixture.txt"
        ] {
            let result = try await Self.search(service, paths: [path])
            XCTAssertEqual(result, Self.expected(["fixture.txt"]), path)
        }
    }

    func testAbsoluteFiltersStayRootScopedWithDuplicateRelativePaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secondRoot = fixture.container.appendingPathComponent("second-root", isDirectory: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let secondFile = secondRoot.appendingPathComponent("fixture.txt")
        let secondSentinel = Self.sentinel + "_SECOND_ROOT"
        try (secondSentinel + "\n").write(to: secondFile, atomically: true, encoding: .utf8)
        let service = Self.service(roots: [fixture.root, secondRoot])
        for (path, text) in [
            (fixture.root.path, Self.sentinel), (fixture.file.path, Self.sentinel),
            (secondRoot.path, secondSentinel), (secondFile.path, secondSentinel)
        ] {
            let result = try await Self.search(service, paths: [path])
            XCTAssertEqual(result, Self.expected(["fixture.txt"], text: text), path)
        }
        let relative = try await Self.search(service, paths: ["fixture.txt"])
        XCTAssertEqual(relative, .object([
            "count": .int(2),
            "matches": .array([
                Self.match("fixture.txt", text: Self.sentinel),
                Self.match("fixture.txt", text: secondSentinel)
            ])
        ]))
    }

    func testRelativeFiltersKeepLiteralGlobAndUnionSemantics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("nested/leaf.txt")
        try fixture.write("nested-extra/leaf.txt")
        let service = Self.service(roots: [fixture.root])
        for path in ["nested", "nested/", "NESTED", "nested/*.txt"] {
            let result = try await Self.search(service, paths: [path])
            XCTAssertEqual(result, Self.expected(["nested/leaf.txt"]), path)
        }
        let alias = try await Self.search(service, arguments: ["path": .string("fixture.txt")])
        XCTAssertEqual(alias, Self.expected(["fixture.txt"]))
        let union = try await Self.search(service, paths: [fixture.file.path, "missing"])
        XCTAssertEqual(union, Self.expected(["fixture.txt"]))
    }

    func testCanonicalAbsoluteMatcherPreservesCaseDistinctRootAndFileIdentity() throws {
        let roots = ["/canonical/Repo", "/canonical/repo"]
        for root in roots {
            let otherRoot = try XCTUnwrap(roots.first { $0 != root })
            for suffix in ["", "/fixture.txt", "/nested/*.txt"] {
                let filter = try XCTUnwrap(MCPDomainCanonicalWorkspaceService.AbsoluteSearchPathFilter(
                    canonicalPath: root + suffix, canonicalRoots: roots
                ))
                let file = suffix.contains("nested") ? "/nested/fixture.txt" : "/fixture.txt"
                XCTAssertTrue(filter.matches(canonicalFilePath: root + file))
                XCTAssertFalse(filter.matches(canonicalFilePath: otherRoot + file))
                if suffix.contains("nested") {
                    XCTAssertFalse(filter.matches(canonicalFilePath: root + "/Nested/fixture.txt"))
                    XCTAssertFalse(filter.matches(canonicalFilePath: root + "/nested/fixture.TXT"))
                }
            }
            let literal = try XCTUnwrap(MCPDomainCanonicalWorkspaceService.AbsoluteSearchPathFilter(
                canonicalPath: root + "/fixture.txt", canonicalRoots: roots
            ))
            XCTAssertFalse(literal.matches(canonicalFilePath: root + "/Fixture.txt"))
        }
    }

    func testCanonicalAbsoluteMatcherKeepsRootMetacharactersLiteral() throws {
        for name in ["repo[1]", "repo?", "repo*"] {
            let root = "/canonical/" + name
            // The most-specific loaded root is literal, even under another loaded root.
            let roots = ["/canonical", root]
            for suffix in ["", "/*.txt", "/nested/*.txt"] {
                let filter = try XCTUnwrap(MCPDomainCanonicalWorkspaceService.AbsoluteSearchPathFilter(
                    canonicalPath: root + suffix, canonicalRoots: roots
                ))
                let file = suffix.contains("nested") ? "/nested/fixture.txt" : "/fixture.txt"
                XCTAssertTrue(filter.matches(canonicalFilePath: root + file))
                XCTAssertFalse(filter.matches(canonicalFilePath: "/canonical/repo1" + file))
                XCTAssertFalse(filter.matches(canonicalFilePath: root + "-sibling" + file))
            }
        }
    }

    func testAbsoluteRootAndSuffixGlobFiltersWithLiteralRootMetacharacters() async throws {
        for name in ["repo[1]", "repo?", "repo*"] {
            let fixture = try Fixture(rootName: name)
            defer { fixture.remove() }
            let service = Self.service(roots: [fixture.root])
            let rootResult = try await Self.search(service, paths: [fixture.root.path])
            XCTAssertEqual(rootResult, Self.expected(["fixture.txt"]), name)
            try fixture.write("nested/leaf.txt")
            let rootGlob = try await Self.search(service, paths: [fixture.root.path + "/fixture*.txt"])
            XCTAssertEqual(rootGlob, Self.expected(["fixture.txt"]), name)
            let suffixGlob = try await Self.search(service, paths: [fixture.root.path + "/nested/*.txt"])
            XCTAssertEqual(suffixGlob, Self.expected(["nested/leaf.txt"]), name)
        }
    }

    func testOutsideMissingAndEscapingAbsoluteFiltersNeverBecomeUnfilteredSearches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try (Self.sentinel + "\n").write(
            to: outside.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8
        )
        let escape = fixture.root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        let service = Self.service(roots: [fixture.root])
        for path in [
            outside.path, fixture.container.path, "/", fixture.root.path + "-sibling",
            fixture.root.path + "/../outside", escape.path,
            fixture.root.path + "/missing", fixture.file.path + "\0/ignored"
        ] {
            let result = try await Self.search(service, paths: [path])
            XCTAssertEqual(result, Self.expected([]), path)
        }
    }

    private static func service(roots: [URL]) -> MCPDomainCanonicalWorkspaceService {
        let identity = DomainContextIdentity(workspaceID: UUID(), contextID: UUID())
        let snapshot: @Sendable () -> DomainCanonicalWorkspaceSnapshot = {
            DomainCanonicalWorkspaceSnapshot(identity: identity, roots: roots, prompt: "", selection: [])
        }
        return MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
            toolSnapshot: { _ in snapshot() },
            readSnapshot: { _ in snapshot() },
            mutate: { _, _ in snapshot() },
            resolvePath: { rawPath, roots, allowMissingLeaf in
                try DirectHeadlessDomainContext.resolvePath(rawPath, roots: roots, allowMissingLeaf: allowMissingLeaf)
            }
        ))
    }

    private static func request(_ arguments: [String: Value]) throws -> DomainPhysicalReadRequest {
        try DomainPhysicalReadRequest(
            request: DomainPhysicalToolRequest(argumentsJSON: JSONEncoder().encode(arguments), securityContext: nil),
            context: DomainReadInvocationContext(handle: nil, connectionID: nil),
            sideEffects: MCPDomainReadSideEffectEmitter(submit: { _, _, _, _, _ in })
        )
    }

    private static func value(_ result: DomainPhysicalToolResult) throws -> Value {
        try JSONDecoder().decode(Value.self, from: result.json)
    }

    private static func search(
        _ service: MCPDomainCanonicalWorkspaceService,
        paths: [String]? = nil,
        arguments: [String: Value] = [:]
    ) async throws -> Value {
        var arguments = arguments
        arguments["pattern"] = .string(sentinel)
        arguments["regex"] = .bool(false)
        arguments["max_results"] = .int(5)
        if let paths { arguments["filter"] = .object(["paths": .array(paths.map(Value.string))]) }
        return try await value(service.searchFiles(request(arguments)))
    }

    private static func expected(_ paths: [String], text: String = sentinel) -> Value {
        .object([
            "count": .int(paths.count),
            "matches": .array(paths.map { match($0, text: text) })
        ])
    }

    private static func match(_ path: String, text: String) -> Value {
        .object(["path": .string(path), "line": .int(1), "text": .string(text)])
    }

    private struct Fixture {
        let container: URL
        let root: URL
        var file: URL {
            root.appendingPathComponent("fixture.txt")
        }

        init(rootName: String = "root") throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("rp-headless-search-filter-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            root = container.appendingPathComponent(rootName, isDirectory: true)
            try write("fixture.txt")
        }

        func write(_ relativePath: String) throws {
            let file = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (DirectHeadlessFileSearchFilterTests.sentinel + "\n").write(to: file, atomically: true, encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: container)
        }
    }
}
