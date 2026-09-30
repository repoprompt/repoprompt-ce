import Foundation
@testable import RepoPromptApp
import XCTest

final class FigmaMCPProviderLoginDescriptorTests: XCTestCase {
    func testClaudeUsesFixedTargetAndProviderCommand() {
        let descriptor = ClaudeCodeFigmaMCPLoginDescriptor()
        XCTAssertEqual(descriptor.executableProfile, CLILaunchProfiles.claudeCode)
        XCTAssertEqual(descriptor.launchSpec(targetIdentifier: ClaudeCodeFigmaMCPLoginDescriptor.targetIdentifier).arguments, ["mcp", "login", "plugin:figma:figma"])
        XCTAssertFalse(descriptor.isSupportedVersion(nil))
        XCTAssertTrue(descriptor.isSupportedVersion("2.1.186"))
        XCTAssertFalse(descriptor.isSupportedVersion("2.1.185"))
        XCTAssertFalse(descriptor.isSupportedVersion("2.1.186.1"))
        XCTAssertFalse(descriptor.isSupportedVersion("2.1.x"))
        XCTAssertFalse(descriptor.isSupportedVersion("2.1.186-extra"))
        XCTAssertEqual(descriptor.evidence.provider, .claudeCode)
        XCTAssertEqual(descriptor.evidence.evidenceID, ClaudeCodeFigmaMCPLoginDescriptor.evidenceID)
        XCTAssertEqual(descriptor.evidence.capabilityRevision, ClaudeCodeFigmaMCPLoginDescriptor.capabilityRevision)
    }

    func testLaunchSpecCarriesDescriptorVersionGate() {
        let descriptor = ClaudeCodeFigmaMCPLoginDescriptor()
        let spec = descriptor.launchSpec(targetIdentifier: ClaudeCodeFigmaMCPLoginDescriptor.targetIdentifier)
        XCTAssertEqual(spec.minimumSupportedVersion, "2.1.186")
        XCTAssertTrue(descriptor.isSupportedVersion("2.1.186"))
        XCTAssertFalse(descriptor.isSupportedVersion("2.1.185"))
    }

    func testClaudeResolverDoesNotReadConfiguration() async {
        let resolution = await ClaudeCodeFigmaMCPTargetResolver().resolveTarget(for: .figma)
        XCTAssertEqual(resolution, .resolved(providerTargetIdentifier: "plugin:figma:figma", source: .reviewedFixedIdentifier, credentialContext: .providerDefaultUserProfile))
    }

    func testOpenCodeParserAndResolverRequireExactlyOneFigmaURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("opencode.json")
        let data = try OpenCodeFigmaMCPFixture.data(serverURLs: [
            "design": OpenCodeFigmaMCPFixture.remoteURL,
            "other": "https://example.com/mcp"
        ])
        try data.write(to: url)
        XCTAssertEqual(OpenCodeFigmaMCPConfigParser.matchingServerNames(in: data), ["design"])
        let resolution = await OpenCodeFigmaMCPTargetResolver(configURL: url).resolveTarget(for: .figma)
        XCTAssertEqual(resolution, .untrustedCredentialContext(reason: .customHomeOrConfig))
        let descriptor = OpenCodeFigmaMCPLoginDescriptor()
        XCTAssertEqual(descriptor.executableProfile, CLILaunchProfiles.openCode)
        XCTAssertEqual(descriptor.launchSpec(targetIdentifier: "design").arguments, ["mcp", "auth", "design"])
        XCTAssertTrue(descriptor.isSupportedVersion("1.0.0"))
        XCTAssertFalse(descriptor.isSupportedVersion(nil))
        XCTAssertFalse(descriptor.isSupportedVersion("not-a-version"))
        XCTAssertEqual(descriptor.evidence.provider, .openCode)
    }

    func testOpenCodeMalformedAndMissingCasesFailClosed() async {
        XCTAssertEqual(OpenCodeFigmaMCPConfigParser.matchingServerNames(in: Data("not json".utf8)), [])
        XCTAssertEqual(OpenCodeFigmaMCPConfigParser.matchingServerNames(in: Data(#"{}"#.utf8)), [])
        XCTAssertEqual(
            OpenCodeFigmaMCPConfigParser.matchingServerNames(in: Data(#"{"mcp":{"figma":{"url":"https://mcp.figma.com/mcp?oauth=1"}}}"#.utf8)),
            []
        )
        XCTAssertEqual(
            OpenCodeFigmaMCPConfigParser.matchingServerNames(in: Data(#"{"mcp":{"figma":{"url":true},"valid":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8)),
            []
        )

        let resolver = OpenCodeFigmaMCPTargetResolver(
            configURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let resolution = await resolver.resolveTarget(for: .figma)
        XCTAssertEqual(resolution, .untrustedCredentialContext(reason: .customHomeOrConfig))
    }

    func testOpenCodeAmbiguousAndUntrustedCasesFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("opencode.json")
        let data = try OpenCodeFigmaMCPFixture.data(serverURLs: [
            "a": OpenCodeFigmaMCPFixture.remoteURL,
            "b": OpenCodeFigmaMCPFixture.remoteURL
        ])
        try data.write(to: url)
        XCTAssertEqual(OpenCodeFigmaMCPConfigParser.matchingServerNames(in: data), ["a", "b"])
        let ambiguous = await OpenCodeFigmaMCPTargetResolver(configURL: url).resolveTarget(for: .figma)
        XCTAssertEqual(ambiguous, .untrustedCredentialContext(reason: .customHomeOrConfig))
        let untrusted = await OpenCodeFigmaMCPTargetResolver(configURL: url).resolveTarget(for: .figma)
        XCTAssertEqual(untrusted, .untrustedCredentialContext(reason: .customHomeOrConfig))
    }

    func testCursorMalformedAndStrictURLCasesFailClosed() async throws {
        XCTAssertEqual(CursorFigmaMCPConfigParser.matchingServerNames(in: Data("not json".utf8)), [])
        XCTAssertEqual(CursorFigmaMCPConfigParser.matchingServerNames(in: Data(#"{}"#.utf8)), [])
        XCTAssertEqual(
            CursorFigmaMCPConfigParser.matchingServerNames(in: Data(#"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/mcp/"}}}"#.utf8)),
            []
        )
        XCTAssertEqual(
            CursorFigmaMCPConfigParser.matchingServerNames(in: Data(#"{"mcpServers":{"figma":{"url":false},"valid":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8)),
            []
        )

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        try Data(#"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8).write(to: url)
        let resolution = await CursorFigmaMCPTargetResolver(configURL: url).resolveTarget(for: .figma)
        XCTAssertEqual(resolution, .untrustedCredentialContext(reason: .customHomeOrConfig))
    }

    func testCursorParserAndResolverUseStandardUserMCPServers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        let data = Data(#"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/mcp"},"other":{"url":"https://example.com/mcp"}}}"#.utf8)
        try data.write(to: url)
        XCTAssertEqual(CursorFigmaMCPConfigParser.matchingServerNames(in: data), ["figma"])
        let resolution = await CursorFigmaMCPTargetResolver(configURL: url).resolveTarget(for: .figma)
        XCTAssertEqual(resolution, .untrustedCredentialContext(reason: .customHomeOrConfig))
        let descriptor = CursorFigmaMCPLoginDescriptor()
        XCTAssertEqual(descriptor.executableProfile, CLILaunchProfiles.cursor)
        XCTAssertEqual(descriptor.launchSpec(targetIdentifier: "figma").arguments, ["mcp", "login", "figma"])
        XCTAssertTrue(descriptor.isSupportedVersion("1.0.0"))
        XCTAssertFalse(descriptor.isSupportedVersion(nil))
        XCTAssertFalse(descriptor.isSupportedVersion("not-a-version"))
        XCTAssertEqual(descriptor.evidence.provider, .cursor)
    }
}

private enum OpenCodeFigmaMCPFixture {
    static let remoteURL = OpenCodeFigmaMCPLoginDescriptor.remoteURL

    static func data(serverURLs: [String: String]) throws -> Data {
        let servers = serverURLs.mapValues { url in
            ["type": "remote", "url": url]
        }
        return try JSONSerialization.data(withJSONObject: ["mcp": servers])
    }
}
