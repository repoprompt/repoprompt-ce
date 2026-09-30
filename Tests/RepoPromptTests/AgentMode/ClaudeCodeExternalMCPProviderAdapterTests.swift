import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeCodeExternalMCPProviderAdapterTests: XCTestCase {
    func testExactFigmaPluginOutputReportsConnected() {
        let output = "plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected"

        XCTAssertEqual(
            ClaudeCodeExternalMCPProviderAdapter.parseMCPListOutput(output, exitStatus: 0),
            .init(status: .connected)
        )
    }

    func testStatusProbeUsesNormalCLIEnvironmentPolicy() {
        let configuration = ClaudeCodeExternalMCPProviderAdapter.statusProbeConfiguration(
            executableIdentity: "claude"
        )

        XCTAssertEqual(configuration.launchPurpose, .cliRunner)
        XCTAssertEqual(
            ClaudeCodeExternalMCPProviderAdapter.logoutConfiguration(executableIdentity: "claude").launchPurpose,
            .cliRunner
        )
        XCTAssertEqual(
            ClaudeCodeExternalMCPProviderAdapter.figmaLogoutArguments,
            ["mcp", "logout", "plugin:figma:figma"]
        )

        let terminalHome = "/tmp/terminal-home"
        let terminalConfig = "/tmp/terminal-config"
        let composed = ProcessEnvironmentBuilder.composedEnvironment(
            for: configuration.launchPurpose,
            base: [
                "HOME": terminalHome,
                "CLAUDE_CONFIG_DIR": terminalConfig,
                "CLAUDE_HOME": terminalHome + "/.claude",
                "XDG_CONFIG_HOME": terminalHome + "/.config"
            ],
            inherited: [:]
        )

        XCTAssertEqual(composed["HOME"], terminalHome)
        XCTAssertEqual(composed["CLAUDE_CONFIG_DIR"], terminalConfig)
        XCTAssertEqual(composed["CLAUDE_HOME"], terminalHome + "/.claude")
        XCTAssertEqual(composed["XDG_CONFIG_HOME"], terminalHome + "/.config")
        XCTAssertTrue(ProcessEnvironmentSanitizer.removedKeys(for: configuration.launchPurpose).isEmpty)
    }

    func testANSIFormattingIsIgnoredButRecordMustRemainExact() {
        let output = "\u{001B}[32mplugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected\u{001B}[0m"

        XCTAssertEqual(
            ClaudeCodeExternalMCPProviderAdapter.parseMCPListOutput(output, exitStatus: 0),
            .init(status: .connected)
        )
    }

    func testParserRejectsNonCanonicalOrAmbiguousStatus() {
        let absentCases = [
            "figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected",
            "plugin:figma:other: https://mcp.figma.com/mcp (HTTP) - ✔ Connected",
            "plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ! Needs authentication",
            "plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ✘ Failed"
        ]

        for output in absentCases {
            XCTAssertEqual(
                ClaudeCodeExternalMCPProviderAdapter.parseMCPListOutput(output, exitStatus: 0),
                .init(status: .notConnected),
                output
            )
        }

        let malformedCases = [
            "plugin:figma:figma: https://mcp.figma.com/mcp?token=secret (HTTP) - ✔ Connected",
            "plugin:figma:figma: http://mcp.figma.com/mcp (HTTP) - ✔ Connected",
            "plugin:figma:figma: https://mcp.figma.com/mcp (SSE) - ✔ Connected"
        ]
        for output in malformedCases {
            XCTAssertEqual(
                ClaudeCodeExternalMCPProviderAdapter.parseMCPListOutput(output, exitStatus: 0),
                .init(status: .unavailable),
                output
            )
        }

        let duplicate = """
        plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected
        plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected
        """
        XCTAssertEqual(
            ClaudeCodeExternalMCPProviderAdapter.parseMCPListOutput(duplicate, exitStatus: 0),
            .init(status: .unavailable)
        )
        XCTAssertEqual(
            ClaudeCodeExternalMCPProviderAdapter.parseMCPListOutput(
                "plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected",
                exitStatus: 1
            ),
            .init(status: .connected)
        )
    }

    func testCapabilityMatrixIncludesProviderOwnedStatusAndCredentialLogoutOnly() async {
        let recorder = ProbeRecorder()
        let adapter = ClaudeCodeExternalMCPProviderAdapter(
            statusProbe: { _, _ in
                recorder.record()
                return .init(status: .connected)
            },
            logoutOperation: { _, _ in
                .init(outcome: .completed, detail: "provider-owned logout")
            }
        )
        let context = context()

        let capabilities = await adapter.capabilities(in: context)
        XCTAssertEqual(capabilities.statusVerification, .providerNative)
        XCTAssertEqual(capabilities.discovery, .unsupported)
        XCTAssertEqual(capabilities.interactiveAuthentication, .unsupported)
        XCTAssertEqual(capabilities.managedConfigurationInstallation, .unsupported)
        XCTAssertEqual(capabilities.adoptedImport, .unsupported)
        XCTAssertEqual(capabilities.credentialLogout, .providerNative)
        XCTAssertEqual(capabilities.runtimeInjection, .unsupported)
        XCTAssertEqual(capabilities.childSessionInheritance, .unsupported)

        let authentication = await adapter.authenticate(in: context, integration: .figma())
        XCTAssertEqual(authentication.status, .unsupported)
        XCTAssertNil(authentication.handoffURL)
        XCTAssertEqual(recorder.count, 0)

        let disconnect = await adapter.disconnect(in: context, integration: .figma())
        XCTAssertEqual(disconnect.receipt.outcome, .completed)
        XCTAssertEqual(disconnect.snapshot.connection, .disconnected)
        XCTAssertEqual(recorder.count, 0)

        let decision = ExternalMCPAccessDecision(
            integrationID: ExternalMCPIntegrationDefinition.figma().integrationID,
            runtimeIdentity: context.identity,
            revision: context.coordinatorRevision,
            isAllowed: true,
            reason: .granted
        )
        let binding = await adapter.applyRuntimeAccess(in: context, decision: decision)
        XCTAssertNil(binding.lease)
        XCTAssertFalse(binding.decision.isAllowed)
        XCTAssertEqual(binding.decision.reason, .unsupported)
        XCTAssertEqual(recorder.count, 0)

        _ = await adapter.refreshStatus(in: context, integration: .figma())
        XCTAssertEqual(recorder.count, 1)
    }

    func testRejectsRuntimeContextsOutsideStatusDiscovery() async {
        let recorder = ProbeRecorder()
        let adapter = ClaudeCodeExternalMCPProviderAdapter(statusProbe: { _, _ in
            recorder.record()
            return .init(status: .connected)
        })

        for invalidContext in [
            context(runtimeKind: .acp),
            context(sessionClass: .topLevel),
            context(isolation: .ceIsolated),
            context(executableIdentity: "/tmp/not-claude"),
            context(executableIdentity: "claude-versioned")
        ] {
            let result = await adapter.refreshStatus(in: invalidContext, integration: .figma())
            XCTAssertEqual(result.connection, .unavailable)
        }
        XCTAssertEqual(recorder.count, 0)
    }

    func testAcceptsAbsoluteCanonicalClaudeExecutableIdentityAndProbes() async {
        let recorder = ProbeRecorder()
        let adapter = ClaudeCodeExternalMCPProviderAdapter(statusProbe: { _, _ in
            recorder.record()
            return .init(status: .connected)
        })

        let result = await adapter.refreshStatus(
            in: context(executableIdentity: "/Users/test/.claude/local/claude"),
            integration: .figma()
        )

        XCTAssertEqual(result.connection, .connected)
        XCTAssertEqual(recorder.count, 1)
    }

    func testAcceptsOfficialVersionedCanonicalClaudeExecutableIdentityAndProbes() async {
        let recorder = ProbeRecorder()
        let adapter = ClaudeCodeExternalMCPProviderAdapter(statusProbe: { _, _ in
            recorder.record()
            return .init(status: .connected)
        })

        let result = await adapter.refreshStatus(
            in: context(executableIdentity: "/Users/test/.local/share/claude/versions/2.1.252"),
            integration: .figma()
        )

        XCTAssertEqual(result.connection, .connected)
        XCTAssertEqual(recorder.count, 1)
    }

    private func context(
        runtimeKind: ExternalMCPRuntimeKind = .nativeCLI,
        sessionClass: ExternalMCPSessionClass = .discovery,
        isolation: ExternalMCPIsolationMode = .userNative,
        executableIdentity: String = AgentProviderKind.claudeCode.commandName,
        cancellationToken: ExternalMCPCancellationToken = ExternalMCPCancellationToken()
    ) -> ExternalMCPProviderRuntimeContext {
        .init(
            identity: .init(
                provider: .claudeCode,
                runtimeKind: runtimeKind,
                executableIdentity: executableIdentity
            ),
            sessionClass: sessionClass,
            isolation: isolation,
            coordinatorRevision: 7,
            cancellationToken: cancellationToken
        )
    }
}

private final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
