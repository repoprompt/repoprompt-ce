import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildPermissionAndIdentityTests: XCTestCase {
    // MARK: - Permission option policy

    func testEnableAlwaysApproveIsNeverAutoSelectableForGrok() {
        XCTAssertFalse(
            ACPPermissionOptionPolicy.isAutoSelectable(optionID: "enable-always-approve", for: .grokBuild)
        )
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow-once", for: .grokBuild))
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow-edits-session", for: .grokBuild))
    }

    func testOtherProvidersHaveNoDenylistedOptions() {
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "enable-always-approve", for: .cursor))
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "anything", for: .openCode))
    }

    func testDenylistMatchingNormalizesCaseAndWhitespace() {
        XCTAssertFalse(
            ACPPermissionOptionPolicy.isAutoSelectable(optionID: "  Enable-Always-Approve ", for: .grokBuild)
        )
    }

    // MARK: - MCP client identity

    func testGrokShellFamilyMatchesLiveObservedClientName() {
        // Frozen fixture: captured from grok 1.0.3 connecting to an ACP-injected MCP server
        // named "RepoPromptCE" on 2026-08-13.
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok-shell-RepoPromptCE"), "grok-shell")
        XCTAssertTrue(MCPClientIdentity.matches("grok-shell-RepoPromptCE", AgentProviderKind.grokBuild.mcpClientNameHint))
    }

    func testGrokShellFamilyRequiresSeparatorBoundary() {
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("grok-shellx"))
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("grok-shel"))
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok-shell"), "grok-shell")
    }

    // MARK: - Controller reuse key

    func testGrokControllerReuseKeysOnPermissionAndModel() async throws {
        let workspace = try makeTestDirectory(name: "GrokBuildReuseKeyTests")
        func makeController(autoApprove: Bool, model: String?) throws -> ACPAgentSessionController {
            try ACPAgentSessionController(
                provider: ReuseKeyFakeGrokProvider(),
                runRequest: ACPRunRequest(
                    agentKind: .grokBuild,
                    modelString: model,
                    workspacePath: workspace.path,
                    resumeSessionID: nil,
                    attachments: [],
                    taskLabelKind: nil,
                    autoApproveAllToolPermissions: autoApprove
                )
            )
        }
        func request(autoApprove: Bool, model: String?) -> ACPRunRequest {
            ACPRunRequest(
                agentKind: .grokBuild,
                modelString: model,
                workspacePath: workspace.path,
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil,
                autoApproveAllToolPermissions: autoApprove
            )
        }

        let managed = try makeController(autoApprove: false, model: nil)
        let managedCompatible = await managed.isCompatibleWith(request: request(autoApprove: false, model: nil))
        let managedPermissionMismatch = await managed.isCompatibleWith(request: request(autoApprove: true, model: nil))
        let managedModelMismatch = await managed.isCompatibleWith(request: request(autoApprove: false, model: "grok-4.5"))
        XCTAssertTrue(managedCompatible)
        XCTAssertFalse(managedPermissionMismatch, "permission change must force a fresh Grok process")
        XCTAssertFalse(managedModelMismatch, "concrete→default/model change must force a fresh Grok process")

        let explicit = try makeController(autoApprove: false, model: "grok-4.5")
        let explicitSame = await explicit.isCompatibleWith(request: request(autoApprove: false, model: "grok-4.5"))
        let explicitCaseVariant = await explicit.isCompatibleWith(request: request(autoApprove: false, model: "GROK-4.5"))
        XCTAssertTrue(explicitSame)
        XCTAssertTrue(explicitCaseVariant, "normalized model raw comparison is case-insensitive")

        await managed.shutdown()
        await explicit.shutdown()
    }
}

/// Minimal Grok provider double for controller-lifecycle tests (no launch resolution).
private struct ReuseKeyFakeGrokProvider: ACPAgentProvider {
    var providerID: ACPProviderID {
        .grokBuild
    }

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: "/bin/echo",
            arguments: [],
            environment: [:],
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        try ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
