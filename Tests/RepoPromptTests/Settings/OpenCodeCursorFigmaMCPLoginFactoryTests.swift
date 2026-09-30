import Foundation
@testable import RepoPromptApp
import XCTest

final class OpenCodeCursorFigmaMCPLoginFactoryTests: XCTestCase {
    func testOpenCodeFactoryBuildsProviderSpecificLoginComponents() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("opencode.json")
        try Data(#"{"mcp":{"design":{"type":"remote","url":"https://mcp.figma.com/mcp"}}}"#.utf8).write(to: configURL)

        let components = OpenCodeFigmaMCPLoginFactory.makeComponents(configURL: configURL, timeout: 42)
        let resolution = await components.targetResolver.resolveTarget(for: .figma)

        XCTAssertEqual(resolution, .untrustedCredentialContext(reason: .customHomeOrConfig))
        XCTAssertEqual(OpenCodeFigmaMCPConfigParser.matchingServerNames(in: Data(#"{"mcp":{"design":{"type":"remote","url":"https://mcp.figma.com/mcp"}}}"#.utf8)), ["design"])
        XCTAssertEqual(components.descriptor.provider, .openCode)
        XCTAssertEqual(components.descriptor.executableProfile, CLILaunchProfiles.openCode)
        XCTAssertNil(components.descriptor.minimumSupportedVersion)
        XCTAssertEqual(components.subprocessDescriptor.provider, .openCode)
        XCTAssertEqual(components.subprocessDescriptor.command, "opencode")
        XCTAssertEqual(components.subprocessDescriptor.timeout, 42)
        XCTAssertEqual(components.subprocessDescriptor.arguments("design"), ["mcp", "auth", "design"])
    }

    func testOpenCodeParserRequiresRemoteEntryType() {
        XCTAssertEqual(
            OpenCodeFigmaMCPConfigParser.matchingServerNames(in: Data(#"{"mcp":{"figma":{"type":"local","url":"https://mcp.figma.com/mcp"}}}"#.utf8)),
            []
        )
    }

    func testCursorParserRequiresRemoteURLEntryShape() {
        XCTAssertEqual(
            CursorFigmaMCPConfigParser.matchingServerNames(in: Data(#"{"mcpServers":{"figma":{"command":"cursor-local","url":"https://mcp.figma.com/mcp"}}}"#.utf8)),
            []
        )
    }

    func testOpenCodeFactoryTargetResolutionFailsClosedForAmbiguousAndUntrustedMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("opencode.json")
        try Data(#"{"mcp":{"a":{"type":"remote","url":"https://mcp.figma.com/mcp"},"b":{"type":"remote","url":"https://mcp.figma.com/mcp"}}}"#.utf8).write(to: configURL)

        let components = OpenCodeFigmaMCPLoginFactory.makeComponents(configURL: configURL)
        let ambiguous = await components.targetResolver.resolveTarget(for: .figma)
        XCTAssertEqual(ambiguous, .untrustedCredentialContext(reason: .customHomeOrConfig))
    }

    func testCursorFactoryBuildsProviderSpecificLoginComponents() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("mcp.json")
        try Data(#"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8).write(to: configURL)

        let components = CursorFigmaMCPLoginFactory.makeComponents(sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }), configURL: configURL, timeout: 43)
        let resolution = await components.targetResolver.resolveTarget(for: .figma)

        XCTAssertEqual(resolution, .untrustedCredentialContext(reason: .customHomeOrConfig))
        XCTAssertEqual(CursorFigmaMCPConfigParser.matchingServerNames(in: Data(#"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8)), ["figma"])
        XCTAssertEqual(components.descriptor.provider, .cursor)
        XCTAssertEqual(components.descriptor.executableProfile, CLILaunchProfiles.cursor)
        XCTAssertNil(components.descriptor.minimumSupportedVersion)
        XCTAssertEqual(components.subprocessDescriptor.provider, .cursor)
        XCTAssertEqual(components.subprocessDescriptor.command, "cursor-agent")
        XCTAssertEqual(components.subprocessDescriptor.timeout, 43)
        XCTAssertEqual(
            components.subprocessDescriptor.requiredExecutableVersion,
            CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild
        )
        XCTAssertEqual(components.subprocessDescriptor.arguments("figma"), ["mcp", "login", "figma"])
    }

    func testCursorTerminalHandoffBuildsOneVisibleLoginCommand() {
        let command = CursorFigmaTerminalHandoff.shellCommand(
            executablePath: "/opt/Cursor/bin/cursor-agent",
            arguments: ["mcp", "login", "figma"],
            resultPath: "/tmp/cursor figma status"
        )

        XCTAssertEqual(
            command,
            #"'/opt/Cursor/bin/cursor-agent' 'mcp' 'login' 'figma'; rp_exit_status=$?; printf '%s\n' "$rp_exit_status" > '/tmp/cursor figma status'"#
        )
        XCTAssertEqual(CursorFigmaTerminalHandoff.terminalScript, ClaudeCodeFigmaTerminalHandoff.terminalScript)
    }

    func testCursorFactoryPreflightUsesReviewedTargetEvidenceAndExactBuildGate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("cursor-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let targetData = Data(#"{"mcpServers":{"reviewed-target":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8)
        let acceptedProbe = CursorExecutableVersionProbe(processRunner: { _ in
            .init(
                stdout: Data("\(CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild)\n".utf8),
                stderr: Data(),
                status: 0,
                timedOut: false
            )
        })
        let components = CursorFigmaMCPLoginFactory.makeComponents(
            sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }),
            targetDataLoader: { _ in targetData },
            executableVersionProbe: acceptedProbe
        )
        let driver = components.makeLoginDriver(
            inheritedEnvironment: ["PATH": directory.path, "TERM": "xterm-256color"],
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            processRunner: { _ in .init(status: 0, timedOut: false) }
        )

        let preflight = await components.evaluatePreflight(using: driver)

        XCTAssertTrue(preflight.permitsLogin)
        XCTAssertEqual(
            preflight.targetResolution,
            .resolved(
                providerTargetIdentifier: "reviewed-target",
                source: .providerStandardUserMetadata,
                credentialContext: .providerDefaultUserProfile
            )
        )
        XCTAssertEqual(components.descriptor.evidence.provider, .cursor)
        XCTAssertEqual(components.descriptor.evidence.evidenceID, CursorFigmaMCPLoginDescriptor.evidenceID)
    }

    func testCursorFactoryPreflightRejectsUnsupportedBuildWithoutPresentingLogin() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("cursor-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let components = CursorFigmaMCPLoginFactory.makeComponents(
            sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }),
            targetDataLoader: { _ in
                Data(#"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8)
            },
            executableVersionProbe: CursorExecutableVersionProbe(processRunner: { _ in
                .init(stdout: Data("2026.08.26-abcdef0\n".utf8), stderr: Data(), status: 0, timedOut: false)
            })
        )
        let driver = components.makeLoginDriver(
            inheritedEnvironment: ["PATH": directory.path],
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            processRunner: { _ in .init(status: 0, timedOut: false) }
        )

        let preflight = await components.evaluatePreflight(using: driver)

        XCTAssertFalse(preflight.permitsLogin)
        XCTAssertEqual(
            preflight.availability,
            .unavailable("The provider executable is unavailable or unsupported.")
        )
    }

    func testCursorFactoryTargetResolutionRejectsMalformedAndNonstandardMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("mcp.json")
        try Data(#"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/mcp/"}}}"#.utf8).write(to: configURL)

        let components = CursorFigmaMCPLoginFactory.makeComponents(sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }), configURL: configURL)
        let missing = await components.targetResolver.resolveTarget(for: .figma)
        XCTAssertEqual(missing, .untrustedCredentialContext(reason: .customHomeOrConfig))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
