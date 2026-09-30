import Foundation
@testable import RepoPromptApp
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

    func testPreferShellDoesNotExecuteInheritedShell() throws {
        // Keep the command name out of the host login shell's PATH so this test remains isolated.
        let command = "repoprompt-test-codex-\(UUID().uuidString.lowercased())"
        let fixture = try makeResolverFixture(prefix: "resolver-prefer-shell", command: command)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = CommandPathResolver.resolve(
            command,
            environment: fixture.environment,
            additionalPaths: [],
            preferredBasenames: [command],
            shellLookupMode: .preferShell
        )

        XCTAssertEqual(resolved, fixture.pathExecutable.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.shellInvocationMarker.path),
            "preferShell must not execute an inherited SHELL value"
        )
    }

    func testPreferShellUsesTrustedLoginShellBeforePathSearch() throws {
        let fixture = try makeResolverFixture(prefix: "resolver-trusted-login-shell", command: "cd")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = CommandPathResolver.resolve(
            "cd",
            environment: fixture.environment,
            additionalPaths: [],
            preferredBasenames: ["cd"],
            shellLookupMode: .preferShell
        )

        XCTAssertEqual(resolved, "cd", "preferShell should preserve the login shell builtin resolution")
        XCTAssertNotEqual(resolved, fixture.pathExecutable.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shellInvocationMarker.path))
    }

    func testShellLookupDoesNotInterpretPositionalCommandSyntax() throws {
        let fixture = try makeResolverFixture(prefix: "resolver-command-injection")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let marker = fixture.root.appendingPathComponent("command-injected").path
        let commands = [
            "codex`touch \(marker)`",
            "codex; touch \(marker)",
            "codex\n touch \(marker)",
            "-codex touch \(marker)"
        ]

        for command in commands {
            let resolved = CommandPathResolver.resolve(
                command,
                environment: fixture.environment,
                additionalPaths: [],
                preferredBasenames: [command],
                shellLookupMode: .preferShell
            )

            XCTAssertEqual(resolved, command)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("command-injected").path),
            "positional command arguments must not be interpreted as shell source"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shellInvocationMarker.path))
    }

    private struct ResolverFixture {
        let root: URL
        let pathExecutable: URL
        let shellExecutable: URL
        let shellInvocationMarker: URL
        let environment: [String: String]
    }

    private func makeResolverFixture(prefix: String, command: String = "codex") throws -> ResolverFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests-")
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
        let shellBin = root.appendingPathComponent("shell-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shellBin, withIntermediateDirectories: true)

        let pathExecutable = pathBin.appendingPathComponent(command)
        let shellExecutable = shellBin.appendingPathComponent(command)
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
