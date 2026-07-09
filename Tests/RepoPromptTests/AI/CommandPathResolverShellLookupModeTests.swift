import Foundation
@testable import RepoPrompt
import XCTest

final class CommandPathResolverShellLookupModeTests: XCTestCase {
    func testFallbackOnlyPrefersPathBeforeShellLookup() throws {
        let fixture = try makeResolverFixture(prefix: "resolver-fallback-only")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = CommandPathResolver.resolve(
            "codex",
            environment: fixture.environment,
            additionalPaths: [],
            preferredBasenames: ["codex"],
            shellLookupMode: .fallbackOnly
        )

        XCTAssertEqual(resolved, fixture.pathExecutable.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.shellInvocationMarker.path),
            "fallbackOnly should not invoke the shell when PATH already contains the command"
        )
    }

    func testPreferShellPreservesShellFirstResolution() throws {
        let fixture = try makeResolverFixture(prefix: "resolver-prefer-shell")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = CommandPathResolver.resolve(
            "codex",
            environment: fixture.environment,
            additionalPaths: [],
            preferredBasenames: ["codex"],
            shellLookupMode: .preferShell
        )

        XCTAssertEqual(resolved, fixture.shellExecutable.path)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.shellInvocationMarker.path),
            "preferShell should query the shell before PATH search"
        )
    }

    private struct ResolverFixture {
        let root: URL
        let pathExecutable: URL
        let shellExecutable: URL
        let shellInvocationMarker: URL
        let environment: [String: String]
    }

    private func makeResolverFixture(prefix: String) throws -> ResolverFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests-")
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
        let shellBin = root.appendingPathComponent("shell-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shellBin, withIntermediateDirectories: true)

        let pathExecutable = pathBin.appendingPathComponent("codex")
        let shellExecutable = shellBin.appendingPathComponent("codex")
        let shellInvocationMarker = root.appendingPathComponent("shell-was-invoked")
        let fakeShell = root.appendingPathComponent("fake-shell")

        try writeExecutable(pathExecutable, contents: "#!/bin/sh\nexit 0\n")
        try writeExecutable(shellExecutable, contents: "#!/bin/sh\nexit 0\n")
        try writeExecutable(
            fakeShell,
            contents: """
            #!/bin/sh
            printf invoked > "\(shellInvocationMarker.path)"
            printf '__RP_BEGIN__\\n'
            printf '%s\\n' "\(shellExecutable.path)"
            printf '__RP_END__\\n'
            exit 0
            """
        )

        return ResolverFixture(
            root: root,
            pathExecutable: pathExecutable,
            shellExecutable: shellExecutable,
            shellInvocationMarker: shellInvocationMarker,
            environment: [
                "HOME": root.path,
                "PATH": pathBin.path,
                "SHELL": fakeShell.path
            ]
        )
    }

    private func writeExecutable(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}
