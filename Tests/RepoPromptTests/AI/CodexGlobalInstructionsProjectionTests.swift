import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// User-home compatibility bridges share this file to avoid growing the app-test import footprint.
final class CodexUserMCPImportTests: XCTestCase {
    func testImportsOnlyMCPDefinitionsAndPreservesManagedAndReservedServers() throws {
        let source = """
        model = "not-imported"
        [mcp_servers.RepoPromptCE]
        command = "not-imported"
        [mcp_servers.existing]
        command = "not-imported"
        [mcp_servers.'new.server']
        command = "fixture-tool"
        args = ["--fixture"]
        enabled = true
        [mcp_servers.'new.server'.env]
        FIXTURE_TOKEN = "synthetic-secret"
        [hooks]
        command = "not-imported"
        """
        let destination = """
        model = "managed"
        [mcp_servers.RepoPromptCE]
        command = "managed-rpce"
        [mcp_servers.existing]
        command = "managed-existing"
        """
        let result = try CodexUserMCPImport.merge(source: source, destination: destination)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertTrue(result.content.hasPrefix(destination))
        XCTAssertTrue(result.content.contains("command = \"fixture-tool\""))
        XCTAssertTrue(result.content.contains("FIXTURE_TOKEN = \"synthetic-secret\""))
        XCTAssertTrue(result.content.contains("enabled = false"))
        XCTAssertFalse(result.content.contains("enabled = true"))
        XCTAssertFalse(result.content.contains("not-imported"))
        let repeated = try CodexUserMCPImport.merge(source: source, destination: result.content)
        XCTAssertEqual(repeated.importedCount, 0)
        XCTAssertEqual(repeated.content, result.content)
    }

    func testMultilineValuesCannotInjectNonMCPConfiguration() throws {
        let source = #"""
        instructions = '''
        [mcp_servers.not_a_server]
        command = "not-imported"
        '''
        [mcp_servers.real]
        command = "fixture"
        args = [
          "--fixture",
        ]
        [mcp_servers.real.env]
        FIXTURE_TEXT = '''
        enabled = true
        ordinary value
        '''
        """#
        let result = try CodexUserMCPImport.merge(source: source, destination: "")
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertFalse(result.content.contains("not_a_server"))
        XCTAssertTrue(result.content.contains("enabled = true\nordinary value"))
        XCTAssertTrue(result.content.contains("args = [\n  \"--fixture\","))
    }

    func testRejectsAmbiguousOrIncompleteLayouts() throws {
        let sources = [
            "mcp_servers.fixture.command = 'fixture'",
            "[mcp_servers]\nfixture = {command = 'fixture'}",
            "[[mcp_servers.fixture]]\ncommand = 'fixture'",
            "[mcp_servers.fixture]\ncommand = '''unterminated",
            "[mcp_servers.fixture]\ncommand = 'fixture'\n[mcp_servers.fixture]\nurl = 'fixture'",
            "[mcp_servers.fixture]\ncommand = '''\n[features.code_mode]\n'''",
            "[mcp_servers.fixture]\ncommand = 'fixture'\n[mcp_servers.FIXTURE]\ncommand = 'other'"
        ]
        for (index, source) in sources.enumerated() {
            XCTAssertEqual(try CodexUserMCPImport.merge(source: source, destination: "# managed").importedCount, 0, "case \(index)")
        }
    }

    func testUnicodeEscapedAliasesCannotModifyProtectedOrExistingServers() throws {
        let source = #"""
        [mcp_servers."\U00000052epoPromptCE".env]
        FIXTURE_INJECTION = "not-imported"
        [mcp_servers."\u0065xisting"]
        command = "not-imported"
        [mcp_servers."\u0065xisting".env]
        FIXTURE_INJECTION = "not-imported"
        """#
        let destination = "[mcp_servers.RepoPromptCE]\ncommand = 'managed'\n[mcp_servers.existing]\ncommand = 'existing'\n"
        let result = try CodexUserMCPImport.merge(source: source, destination: destination)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.content, destination)
        XCTAssertEqual(try CodexUserMCPImport.merge(source: #"[mcp_servers."\U00110000"]"#, destination: destination).importedCount, 0)
        XCTAssertEqual(try CodexUserMCPImport.merge(source: #"[mcp_servers."\q"]"#, destination: destination).importedCount, 0)
    }

    func testCRLFHTTPServerAndInlineHeadersImport() throws {
        let source = "\u{FEFF}[mcp_servers.http]\r\nurl = 'https://example.invalid/mcp'\r\nenabled = true\r\nhttp_headers = { 'X-Fixture' = 'synthetic' }\r\nenv_http_headers = { Authorization = 'FIXTURE_TOKEN' }\r\n"
        let result = try CodexUserMCPImport.merge(source: source, destination: "")
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertTrue(result.content.contains("enabled = false"))
        XCTAssertTrue(result.content.contains("url = 'https://example.invalid/mcp'"))
        XCTAssertTrue(result.content.contains("http_headers = { 'X-Fixture' = 'synthetic' }"))
        XCTAssertFalse(result.content.contains("\r"))
    }

    func testReservedAndCaseInsensitiveExistingNamesAreNeverImported() throws {
        let source = """
        [mcp_servers.repopromptce]
        command = "untrusted"
        [mcp_servers."\(MCPIntegrationHelper.computerUseMCPServerName)"]
        command = "untrusted"
        [mcp_servers.EXISTING]
        command = "untrusted"
        """
        let destination = "[mcp_servers.existing]\ncommand = 'managed'\n"
        let result = try CodexUserMCPImport.merge(source: source, destination: destination)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.content, destination)
    }

    func testImportUsesPrivateFilePreservesSourceAndIsIdempotent() throws {
        try withImportFiles { source, destination in
            let original = "[mcp_servers.fixture]\ncommand = 'fixture'\n[mcp_servers.fixture.env]\nFIXTURE_TOKEN = 'synthetic-secret'\n"
            try original.write(to: source, atomically: true, encoding: .utf8)
            let result = try CodexIntegrationConfiguration.importUserMCPServers(sourceURL: source, destinationURL: destination, resetPermissions: { _ in })
            XCTAssertEqual(result.importedCount, 1)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), original)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), result.content)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let repeated = try CodexIntegrationConfiguration.importUserMCPServers(sourceURL: source, destinationURL: destination, resetPermissions: { _ in })
            XCTAssertEqual(repeated.importedCount, 0)
            let after = try FileManager.default.attributesOfItem(atPath: destination.path)
            XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(CodexIntegrationConfiguration.mcpServerEntries(from: result.content).map(\.normalizedName), ["fixture"])
        }
    }

    func testUnreadableOrAmbiguousSourceAndSymlinkDestinationArePreserved() throws {
        try withImportFiles { source, destination in
            try "managed-original".write(to: destination, atomically: true, encoding: .utf8)
            let invalid = [
                "mcp_servers.fixture = {command = 'fixture'}",
                "[mcp_servers.fixture]\ncommand =",
                "[mcp_servers.fixture]\ncommand = 'one'\ncommand = 'two'",
                "[mcp_servers.fixture]\ncommand = 42",
                "[mcp_servers.fixture]\ncommand = 'fixture'\ntool_timeout_sec = -1",
                "[mcp_servers.fixture]\ncommand = 'fixture'\nstartup_timeout_ms = 1.5",
                "[mcp_servers.fixture]\ncommand\u{00A0}= 'fixture'",
                "[mcp_servers.fixture]\ncommand = 'fixture'\n[mcp_servers.\u{00A0}fixture.env]\nKEY = 'value'",
                "[mcp_servers.fixture]\ncommand = 'fixture'\n# invalid\u{0000}comment",
                "[mcp_servers.fixture]\ncommand = 'fixture'\nargs = ['one' 'two']",
                "[mcp_servers.fixture]\ncommand = 'fixture'\nenv = { KEY = 'one', KEY = 'two' }",
                "[mcp_servers.fixture]\ncommand = 'fixture'\nenv = {}\n[mcp_servers.fixture.env]\nKEY = 'two'",
                "[mcp_servers.fixture]\ncommand = 'fixture'\nenv = { FIRST = 'one' }\nenv.SECOND = 'two'",
                "[mcp_servers.fixture]\ncommand = 'fixture'\n[mcp_servers.fixture.tools.read]\napproval_mode = 'not-a-mode'",
                "[mcp_servers.fixture]\ncommand = 'fixture'\nenv_vars = [{ source = 'local' }]",
                "[mcp_servers.fixture]\ncommand = 'fixture'\nurl = 'https://example.invalid'",
                #"""
                [mcp_servers.fixture]
                command = "fixture\q"
                """#
            ]
            for (index, content) in invalid.enumerated() {
                try "managed-original".write(to: destination, atomically: true, encoding: .utf8)
                try content.write(to: source, atomically: true, encoding: .utf8)
                XCTAssertEqual(try CodexIntegrationConfiguration.importUserMCPServers(sourceURL: source, destinationURL: destination, resetPermissions: { _ in }).importedCount, 0, "case \(index)")
                XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "managed-original", "case \(index)")
            }
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: destination)
            XCTAssertThrowsError(try CodexIntegrationConfiguration.importUserMCPServers(sourceURL: source, destinationURL: destination, resetPermissions: { _ in }))
            try FileManager.default.removeItem(at: source)
            try "[mcp_servers.fixture]\ncommand = 'fixture'".write(to: source, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            XCTAssertThrowsError(try CodexIntegrationConfiguration.importUserMCPServers(sourceURL: source, destinationURL: destination, resetPermissions: { _ in }))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), source.path)
        }
    }

    private func withImportFiles(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("codex-mcp-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("source.toml"), root.appendingPathComponent("managed.toml"))
    }

    func testPartialImportReportsOnlyServerAndKeyNames() throws {
        let source = """
        [mcp_servers.bad]
        command = "synthetic-secret"
        unknown_option = "never-echo-this-value"
        [mcp_servers.good]
        command = "fixture"
        [unrelated broken section]
        api_key = "never-echo-this-value"
        [mcp_servers.other]
        url = "https://example.invalid"
        auth = "oauth"
        oauth_resource = "fixture"
        scopes = ["read"]
        environment_id = "local"
        http_headers_helper = "fixture-helper"
        [mcp_servers.other.oauth]
        client_id = "fixture"
        """
        let result = try CodexUserMCPImport.merge(source: source, destination: "")
        XCTAssertEqual(result.importedNames, ["good", "other"])
        XCTAssertTrue(result.skipped.joined().contains("unknown_option"))
        XCTAssertTrue(result.skipped.joined().contains("section at line"))
        XCTAssertFalse(result.summary.contains("never-echo-this-value"))
        XCTAssertFalse(result.summary.contains("synthetic-secret"))
        XCTAssertFalse(result.content.contains("never-echo-this-value"))
    }

    func testReservedAliasesAndControlCharacterNamesAreNotImported() throws {
        for name in ["RepoPromptCEGrokRuntime", "REPOPROMPTCE", "computer_use", "Computer-Use", #"bad\bname"#, #"bad\fname"#, #"bad\u0001name"#, #"bad\u007Fname"#] {
            let source = "[mcp_servers.\"\(name)\"]\ncommand = 'untrusted'\n"
            let result = try CodexUserMCPImport.merge(source: source, destination: "")
            XCTAssertEqual(result.importedCount, 0, name)
        }
        XCTAssertTrue(MCPIntegrationHelper.isReservedMCPServerIdentifier("computer_use"))
        XCTAssertTrue(MCPIntegrationHelper.isReservedMCPServerIdentifier("RepoPromptCEGrokRuntime"))
        XCTAssertFalse(MCPIntegrationHelper.isReservedMCPServerIdentifier("not-RepoPromptCE"))
    }

    func testSourceSymlinkAndCodexHomeAndStalePermissionReset() throws {
        let suite = "CodexMCPImport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try withImportFiles { source, destination in
            let target = source.deletingLastPathComponent().appendingPathComponent("dotfiles.toml")
            try "[mcp_servers.Fixture]\ncommand = 'fixture'\n[[mcp_servers.Fixture.env_vars]]\nname = 'FIXTURE_TOKEN'\nsource = 'local'\n".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            CodexAgentToolPreferences.setMCPServerEnabled(normalizedName: "fixture", isEnabled: true, defaults: defaults)
            let result = try CodexIntegrationConfiguration.importUserMCPServers(sourceURL: source, destinationURL: destination) { names in
                XCTAssertEqual(names, ["Fixture"])
                XCTAssertTrue(CodexAgentToolPreferences.disableImportedMCPServers(names, defaults: defaults))
            }
            XCTAssertEqual(result.importedCount, 1)
            XCTAssertFalse(CodexAgentToolPreferences.mcpServerEnabled(normalizedName: "FIXTURE", defaults: defaults))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), target.path)
            XCTAssertNil(try CodexUserMCPImport.pendingSummary(sourceURL: source, destinationURL: destination))
            XCTAssertEqual(CodexUserMCPImport.sourceConfigURL(environment: ["CODEX_HOME": target.deletingLastPathComponent().path], home: URL(fileURLWithPath: "/fixture-home")).lastPathComponent, "config.toml")
            XCTAssertEqual(CodexUserMCPImport.sourceConfigURL(environment: [:], home: URL(fileURLWithPath: "/fixture-home")).path, "/fixture-home/.codex/config.toml")
            XCTAssertEqual(CodexUserMCPImport.sourceConfigURL(environment: ["CODEX_HOME": "~/custom"], home: URL(fileURLWithPath: "/fixture-home")).path, "/fixture-home/custom/config.toml")
        }
    }

    func testPermissionPersistenceFailureDoesNotPublishDefinitions() throws {
        try withImportFiles { source, destination in
            try "[mcp_servers.fixture]\ncommand = 'fixture'\n".write(to: source, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try CodexIntegrationConfiguration.importUserMCPServers(sourceURL: source, destinationURL: destination) { _ in throw CodexUserMCPImport.Failure.writeFailed })
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let hint = try CodexUserMCPImport.pendingSummary(sourceURL: source, destinationURL: destination)
            XCTAssertTrue(try XCTUnwrap(hint).contains("fixture"))
            XCTAssertFalse(try XCTUnwrap(hint).contains("command"))
        }
    }

    func testSharedQuotedKeyAndCommandParsingAndTimeoutRepair() throws {
        let content = #"[mcp_servers."\U00000066ixture"]"# + "\ncommand = 'fixture'\n" + #"[mcp_servers."invalid\q"]"#
        XCTAssertEqual(CodexIntegrationConfiguration.mcpServerEntries(from: content).map(\.normalizedName), ["fixture"])
        for scalar in [8, 12, 1, 31, 127] {
            let name = try "fixture" + String(XCTUnwrap(UnicodeScalar(scalar)))
            let key = CodexIntegrationConfiguration.cliPathComponent(forNormalizedServerName: name)
            XCTAssertEqual(CodexIntegrationConfiguration.importTableHeader("[mcp_servers.\(key)]")?.path, ["mcp_servers", name])
            XCTAssertTrue(key.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 })
        }
        let command = MCPIntegrationHelper.serverCommand.replacingOccurrences(of: "/", with: #"\u002F"#)
        let managed = #"[mcp_servers."\U00000052epoPromptCE"]"# + "\ncommand = \"\(command)\"\ntool_timeout_sec = 1\n"
        let repaired = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: managed)
        XCTAssertTrue(repaired.foundTarget)
        XCTAssertTrue(repaired.changed)
        XCTAssertFalse(CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: managed.replacingOccurrences(of: "\\u002F", with: "\\q")).foundTarget)
    }

    func testPinnedCodexToolApprovalAndEnvironmentDeclarationsImport() throws {
        let source = """
        [mcp_servers.fixture]
        command = "fixture"
        startup_readiness = "catalog"
        default_tools_approval_mode = "prompt"
        env_vars = [{ name = "FIXTURE_TOKEN", source = "local" }]
        omit_tools_from = ["deferred"]
        [mcp_servers.fixture.tools.read]
        approval_mode = "approve"
        output_token_limit = 100
        """
        let result = try CodexUserMCPImport.merge(source: source, destination: "")
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertTrue(result.content.contains("approval_mode = \"approve\""))
    }

    func testMissingMCPDefinitionsDoNotChangeDestination() throws {
        let result = try CodexUserMCPImport.merge(source: "model = 'fixture'", destination: "# managed\n")
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.content, "# managed\n")
    }
}

final class CodexGlobalInstructionsProjectionTests: XCTestCase {
    private var root: URL!
    private var ordinaryHome: URL!
    private var managedHome: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexGlobalInstructionsProjectionTests-\(UUID().uuidString)")
        ordinaryHome = root.appendingPathComponent("ordinary", isDirectory: true)
        managedHome = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPrepareCopiesBothFilesIncludingEmptyOverride() throws {
        try write(Data(), to: ordinary("AGENTS.override.md"))
        try write(Data("fallback".utf8), to: ordinary("AGENTS.md"))

        try project()

        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), Data())
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("fallback".utf8))
        assertRegularFile(managed("AGENTS.override.md"))
        assertRegularFile(managed("AGENTS.md"))
        let hashes = try manifestHashes()
        XCTAssertEqual(hashes["AGENTS.override.md"], hash(Data()))
        XCTAssertEqual(hashes["AGENTS.md"], hash(Data("fallback".utf8)))

        try project()
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("fallback".utf8))
    }

    func testPrepareRefreshesOwnedFilesAndRemovesOwnedMissingSources() throws {
        try write(Data("first override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("fallback".utf8), to: ordinary("AGENTS.md"))
        try project()

        try write(Data("second override".utf8), to: ordinary("AGENTS.override.md"))
        try FileManager.default.removeItem(at: ordinary("AGENTS.md"))
        try project()

        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), Data("second override".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.md").path))
        XCTAssertEqual(try Set(manifestHashes().keys), ["AGENTS.override.md"])
        try project()

        try FileManager.default.removeItem(at: ordinary("AGENTS.override.md"))
        try project()
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.override.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testPrepareRejectsUnmanifestedDestinationWithoutMutatingEitherFile() throws {
        let cases = [
            (name: "foreign-content", data: Data("foreign".utf8)),
            (name: "matching-content-without-ownership", data: Data("source".utf8))
        ]

        for testCase in cases {
            try resetManagedHome()
            try write(Data("source".utf8), to: ordinary("AGENTS.override.md"))
            try write(Data("fallback".utf8), to: ordinary("AGENTS.md"))
            try write(testCase.data, to: managed("AGENTS.override.md"))

            XCTAssertThrowsError(try project(), "case=\(testCase.name)") { error in
                guard case CodexGlobalInstructionsProjection.Failure.unownedDestination = error else {
                    return XCTFail("Expected unowned destination failure for \(testCase.name), got \(error)")
                }
            }
            XCTAssertEqual(
                try Data(contentsOf: managed("AGENTS.override.md")),
                testCase.data,
                "case=\(testCase.name)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: managed("AGENTS.md").path),
                "case=\(testCase.name)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: manifestURL.path),
                "case=\(testCase.name)"
            )
        }
    }

    func testPrepareRejectsModifiedOwnedDestinationWithoutMutatingEitherFile() throws {
        try write(Data("override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("old fallback".utf8), to: ordinary("AGENTS.md"))
        try project()
        let originalManifest = try Data(contentsOf: manifestURL)

        try write(Data("manual edit".utf8), to: managed("AGENTS.override.md"))
        try write(Data("new fallback".utf8), to: ordinary("AGENTS.md"))

        XCTAssertThrowsError(try project()) { error in
            guard case CodexGlobalInstructionsProjection.Failure.modifiedDestination = error else {
                return XCTFail("Expected modified destination failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), Data("manual edit".utf8))
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("old fallback".utf8))
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
    }

    func testPrepareRejectsDestinationSymlinkWithoutFollowingIt() throws {
        let external = root.appendingPathComponent("external")
        try write(Data("external".utf8), to: external)
        try write(Data("override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("fallback".utf8), to: ordinary("AGENTS.md"))
        try FileManager.default.createSymbolicLink(at: managed("AGENTS.override.md"), withDestinationURL: external)

        XCTAssertThrowsError(try project())
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
        assertSymbolicLink(managed("AGENTS.override.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testPrepareFollowsSourceSymlinkAndCreatesRegularDestination() throws {
        let external = root.appendingPathComponent("source")
        try write(Data("first".utf8), to: external)
        try FileManager.default.createSymbolicLink(at: ordinary("AGENTS.md"), withDestinationURL: external)

        try project()

        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("first".utf8))
        assertRegularFile(managed("AGENTS.md"))

        try write(Data("second".utf8), to: external)
        try project()
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("second".utf8))
    }

    func testPrepareReconcilesEstablishedInterruptedUpdate() throws {
        try write(Data("old override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("old fallback".utf8), to: ordinary("AGENTS.md"))
        try project()

        try write(Data("new override".utf8), to: ordinary("AGENTS.override.md"))
        try write(Data("new fallback".utf8), to: ordinary("AGENTS.md"))
        try write(Data("new override".utf8), to: managed("AGENTS.override.md"))

        try project()

        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.override.md")), Data("new override".utf8))
        XCTAssertEqual(try Data(contentsOf: managed("AGENTS.md")), Data("new fallback".utf8))
        let hashes = try manifestHashes()
        XCTAssertEqual(hashes["AGENTS.override.md"], hash(Data("new override".utf8)))
        XCTAssertEqual(hashes["AGENTS.md"], hash(Data("new fallback".utf8)))
    }

    func testPrepareRejectsInvalidManifestBeforeMutation() throws {
        try write(Data("source".utf8), to: ordinary("AGENTS.md"))
        let unicodeDigits = String(repeating: "١", count: 64)
        let invalidManifests = [
            (name: "malformed-json", data: Data("not json".utf8)),
            (name: "unsupported-schema", data: Data(#"{"schemaVersion":2,"projectedFileHashes":{}}"#.utf8)),
            (name: "unknown-file", data: Data(#"{"schemaVersion":1,"projectedFileHashes":{"OTHER.md":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#.utf8)),
            (name: "invalid-hash", data: Data(#"{"schemaVersion":1,"projectedFileHashes":{"AGENTS.md":"invalid"}}"#.utf8)),
            (
                name: "non-ascii-hex-digits",
                data: Data("{\"schemaVersion\":1,\"projectedFileHashes\":{\"AGENTS.md\":\"\(unicodeDigits)\"}}".utf8)
            )
        ]

        for testCase in invalidManifests {
            try resetManagedHome()
            try write(testCase.data, to: manifestURL)
            XCTAssertThrowsError(try project(), "case=\(testCase.name)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: managed("AGENTS.md").path),
                "case=\(testCase.name)"
            )
        }

        try resetManagedHome()
        let external = root.appendingPathComponent("external-manifest")
        try write(Data("{}".utf8), to: external)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: external)
        XCTAssertThrowsError(try project())
        assertSymbolicLink(manifestURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed("AGENTS.md").path))
    }

    private var manifestURL: URL {
        managed(".repoprompt-agents-projection.json")
    }

    private func ordinary(_ name: String) -> URL {
        ordinaryHome.appendingPathComponent(name)
    }

    private func managed(_ name: String) -> URL {
        managedHome.appendingPathComponent(name)
    }

    private func project() throws {
        try CodexGlobalInstructionsProjection.prepare(
            ordinaryCodexHome: ordinaryHome,
            managedCodexHome: managedHome
        )
    }

    private func resetManagedHome() throws {
        try? FileManager.default.removeItem(at: managedHome)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func manifestHashes() throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(dictionary["projectedFileHashes"] as? [String: String])
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertRegularFile(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        var metadata = Darwin.stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0, file: file, line: line)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG, file: file, line: line)
    }

    private func assertSymbolicLink(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        var metadata = Darwin.stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0, file: file, line: line)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK, file: file, line: line)
    }
}
