import Foundation
@testable import RepoPrompt
import XCTest

final class ServerControllerAdmissionTests: XCTestCase {
    func testRepoPromptCLIClientNamesAreRecognizedForVerificationOnly() {
        #if DEBUG
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName("RepoPrompt CLI"))
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName(" RepoPrompt CLI (Exec) "))
            XCTAssertTrue(ServerController.test_isRepoPromptCLIClientName("RepoPrompt CLI 1.2.3"))
            XCTAssertFalse(ServerController.test_isRepoPromptCLIClientName("Spoofed RepoPrompt CLI"))
            XCTAssertFalse(ServerController.test_isRepoPromptCLIClientName("repoPrompt CLI"))
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testDefaultAllowListDoesNotIncludeRepoPromptCLI() {
        #if DEBUG
            XCTAssertFalse(
                ServerController.test_defaultAlwaysAllowedClients.contains {
                    ServerController.test_isRepoPromptCLIClientName($0)
                }
            )
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testSanitizerRemovesPersistedRepoPromptCLIAllowListEntries() {
        #if DEBUG
            let sanitized = ServerController.test_sanitizedAlwaysAllowedClients([
                "RepoPrompt CLI",
                "RepoPrompt CLI (Exec)",
                " RepoPrompt CLI 1.2.3 ",
                "claude-code",
                "custom-client",
                "Spoofed RepoPrompt CLI"
            ])

            XCTAssertEqual(sanitized, ["claude-code", "custom-client", "Spoofed RepoPrompt CLI"])
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testBundledHelperPathVerificationAcceptsSymlinkEquivalentPath() throws {
        #if DEBUG
            let fixture = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let expected = fixture.appendingPathComponent("repoprompt-mcp")
            let symlink = fixture.appendingPathComponent("rpce-cli-debug")
            XCTAssertTrue(FileManager.default.createFile(atPath: expected.path, contents: Data("helper".utf8)))
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: expected)

            XCTAssertTrue(ServerController.test_bundledHelperPathMatches(
                expectedURL: expected,
                actualPath: symlink.path
            ))
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testBundledHelperPathVerificationRejectsAlternateExecutablePath() throws {
        #if DEBUG
            let fixture = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let expected = fixture.appendingPathComponent("repoprompt-mcp")
            let alternate = fixture.appendingPathComponent("alternate-repoprompt-mcp")
            XCTAssertTrue(FileManager.default.createFile(atPath: expected.path, contents: Data("same bytes".utf8)))
            XCTAssertTrue(FileManager.default.createFile(atPath: alternate.path, contents: Data("same bytes".utf8)))

            XCTAssertFalse(ServerController.test_bundledHelperPathMatches(
                expectedURL: expected,
                actualPath: alternate.path
            ))
        #else
            throw XCTSkip("DEBUG-only ServerController admission seams are unavailable in release builds")
        #endif
    }

    func testBundledHelperAdmissionRetainsTrustedPeerExecutablePathChain() throws {
        let source = try String(
            contentsOf: RepoRoot.url()
                .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift"),
            encoding: .utf8
        )
        var cursor = source.startIndex
        for marker in [
            "Bundle.main.url(forAuxiliaryExecutable: \"repoprompt-mcp\")",
            "await networkManager.peerPID(for: connectionID)",
            "bundledHelperPeerVerifier.matches(BundledHelperPeerVerificationInput(",
            "expectedExecutableURL: expectedURL",
            "peerPID: peerPID"
        ] {
            let range = try XCTUnwrap(source.range(of: marker, range: cursor ..< source.endIndex))
            cursor = range.upperBound
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerControllerAdmissionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
