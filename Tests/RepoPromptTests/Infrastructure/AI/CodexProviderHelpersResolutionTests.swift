import Foundation
@testable import RepoPromptApp
import XCTest

/// Characterization coverage for `CodexProviderHelpers.resolveCodexExecutable`.
///
/// Spec: docs/spec/codex-nvm-path-resolution.md — S-1 (a codex on the captured PATH
/// resolves) and S-3 (env PATH precedence over a stale supplemental hint). These are
/// deterministic resolver-ordering properties the capture-mode fix (WI-2) relies on;
/// they already hold today, so this file is regression/characterization coverage, not
/// a TDD red.
final class CodexProviderHelpersResolutionTests: XCTestCase {
    private func makeExecutable(in dir: URL, named name: String, marker: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho \(marker)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testCodexOnCapturedPATHResolves() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pathDir = tmp.appendingPathComponent("pathbin", isDirectory: true)
        let expected = try makeExecutable(in: pathDir, named: "codex", marker: "on-path")

        let resolution = CodexProviderHelpers.resolveCodexExecutable(
            commandName: "codex",
            environment: ["HOME": tmp.path, "PATH": pathDir.path],
            additionalPathHints: []
        )
        XCTAssertEqual(resolution.status, .available)
        XCTAssertEqual(resolution.resolvedCommand, expected.path)
    }

    func testEnvPATHShadowsStaleSupplementalHint() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pathDir = tmp.appendingPathComponent("pathbin", isDirectory: true)
        let hintDir = tmp.appendingPathComponent("hintbin", isDirectory: true)
        let onPath = try makeExecutable(in: pathDir, named: "codex", marker: "newer-on-path")
        _ = try makeExecutable(in: hintDir, named: "codex", marker: "stale-hint")

        let resolution = CodexProviderHelpers.resolveCodexExecutable(
            commandName: "codex",
            environment: ["HOME": tmp.path, "PATH": pathDir.path],
            additionalPathHints: [hintDir.path]
        )
        XCTAssertEqual(resolution.status, .available)
        XCTAssertEqual(resolution.resolvedCommand, onPath.path, "env PATH must be searched before supplemental hints")
    }
}
