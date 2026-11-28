import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import XCTest

final class AntigravityACPProviderTests: XCTestCase {
    func testFailedPollingRetainsWarmedRegistrySnapshot() async {
        struct FailingClient: AntigravityACPModelDiscoveryClient {
            func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
                throw NSError(domain: "fixture", code: 1)
            }
        }
        let registry = AgentACPModelRegistry(dependencies: .init(loadAll: { [:] }, load: { _ in nil }, save: { _, _ in }, remove: { _ in }, invalidate: { _ in }))
        let model = AgentModelOption(rawValue: "retained-model", displayName: "Retained", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
        _ = registry.updateDiscoveredModels(.init(options: [model], currentModelRaw: model.rawValue), for: .antigravity)
        let service = AntigravityACPModelPollingService(client: FailingClient(), registry: registry, logFailure: { _ in })
        let outcome = await service.refreshNow(workspacePath: nil)
        if case let .failed(error) = outcome {
            XCTAssertEqual((error as NSError).domain, "fixture")
            XCTAssertEqual((error as NSError).code, 1)
        } else {
            XCTFail("Expected discovery failure, got \(outcome)")
        }
        let snapshot = await service.latestSnapshot()
        XCTAssertEqual(snapshot?.models.options.map(\.rawValue), ["retained-model"])
        XCTAssertEqual(snapshot?.isLiveDiscovery, false)
        await service.shutdown()
    }

    private var toolNames: ACPToolNameResolution {
        ACPToolNameResolution(isRepoPromptServerIdentifier: { _ in false }, canonicalRepoPromptToolName: { _ in nil }, isRepoPromptToolNameWithServerPrefix: { _ in false })
    }

    func testUnmanagedLaunchKeepsFallbackAndOmitsEmptyHarness() async throws {
        let home = URL(fileURLWithPath: "/tmp/antigravity-owner-home", isDirectory: true)
        let provider = AntigravityACPAgentProvider(
            executablePath: "/usr/bin/true", harnessPath: "", installedRuntime: { nil },
            prepareSessionHome: { home }, toolNames: toolNames
        )
        let request = ACPRunRequest(agentKind: .antigravity, modelString: nil, workspacePath: nil, resumeSessionID: "", attachments: [], taskLabelKind: nil)
        let support = try await provider.support(for: request)
        XCTAssertEqual(support, .supported)
        let launch = try provider.makeLaunchConfiguration(for: request)
        XCTAssertEqual(launch.command, "/usr/bin/true")
        XCTAssertEqual(launch.environment["GEMINI_HOME"], home.path)
        XCTAssertNil(launch.environment["ANTIGRAVITY_HARNESS_PATH"])
        let server = RepoPromptMCPServerConfiguration(command: "/usr/bin/true")
        let session = try provider.makeSessionConfiguration(for: request, mcpServer: server)
        XCTAssertEqual(session.mode, .new)
        XCTAssertEqual(session.mcpServers, [server])
    }

    func testIsolatedChatUsesInstalledCLIWithoutStartingGoogleOAuthOrInjectingMCP() throws {
        let profile = URL(fileURLWithPath: "/tmp/antigravity-chat-profile", isDirectory: true)
        let provider = AntigravityACPAgentProvider(
            executablePath: "/usr/bin/true",
            harnessPath: nil,
            installedRuntime: { ("/usr/bin/false", "/usr/bin/true") },
            prepareSessionHome: { throw CocoaError(.fileWriteNoPermission) },
            toolNames: toolNames,
            installedCLI: { "/usr/bin/true" },
            includeRepoPromptMCPServer: false,
            isolatedProfile: profile,
            customAgentName: "repoprompt-chat"
        )
        let request = ACPRunRequest(agentKind: .antigravity, modelString: "fixture-low", workspacePath: "/tmp", resumeSessionID: nil, attachments: [], taskLabelKind: nil)
        let launch = try provider.makeLaunchConfiguration(for: request)
        XCTAssertEqual(launch.command, "/usr/bin/true")
        XCTAssertEqual(launch.arguments, ["acp", "--gemini-dir", profile.path, "--include-default-customizations=false", "--agent", "repoprompt-chat"])
        XCTAssertTrue(launch.environment.isEmpty)
        XCTAssertNil(provider.preferredAuthMethodID(context: .init(authMethodIDs: ["oauth-personal"], environment: [:])))
        let session = try provider.makeSessionConfiguration(for: request, mcpServer: .init(command: "/usr/bin/true"))
        XCTAssertTrue(session.mcpServers.isEmpty)
    }

    func testProcessStderrIsDiagnosticOnlyExceptDiscardedRawFrames() {
        let provider = AntigravityACPAgentProvider(
            executablePath: "fallback", harnessPath: nil, installedRuntime: { nil },
            prepareSessionHome: { URL(fileURLWithPath: "/tmp") }, toolNames: toolNames
        )

        let rawFrameLines = [
            "I0906 123 local_connection.py RAW WS MSG"
        ] + ["D", "I", "W", "E", "F"].map { level in
            #"\#(level)0906 12:34:56.000000 123 local_connection.py:42] RAW WS MSG: {"text":"error: failed with exception and traceback"}"#
        }
        for line in rawFrameLines {
            XCTAssertEqual(provider.stderrLineDisposition(line), .discard, line)
            XCTAssertFalse(provider.shouldEmitStderrLine(line), line)
        }

        let startupInfoLines = [
            "I1121 13:38:11.713540 8556827392 main.py:80] Starting AGY ACP Server...",
            "I1121 13:38:11.713613 8556827392 main.py:81] Gemini home resolved to /Users/example/Library/Application Support/RepoPrompt CE/Antigravity/Profiles/default (from $GEMINI_HOME)",
            "I1121 13:38:11.713823 8556827392 settings.py:302] settings: path=/Users/example/Library/Application Support/RepoPrompt CE/Antigravity/Profiles/default/antigravity-acp/settings.json status=ok auth.type=oauth-personal gcp.project=<unspecified> gcp.location=<unspecified>",
            "I1121 13:38:11.715337 8556827392 server.py:2390] Authenticate called with method_id='oauth-personal', kwargs={}",
            "I1121 13:38:11.715403 8556827392 credential_store.py:235] AGY_ACP_FORCE_FILE_STORAGE set; using file credential storage.",
            "I1121 13:38:11.716142 6187495424 credential_manager.py:521] Access token expired. Refreshing silently...",
            "I1121 13:38:11.806113 6187495424 oauth_manager.py:282] Resolving Google Cloud project ID and endpoint...",
            "I1121 13:38:11.806205 6187495424 onboard.py:126] Running CCPA loadCodeAssist to verify onboarding state..."
        ]

        let diagnosticOnlyEdgeCases = [
            "W1121 13:38:11.810000 6187495424 credential_manager.py:540] Retrying token refresh",
            "E0906 123 local_connection.py:42] Connection closed",
            "F1121 13:38:11.900000 6187495424 main.py:99] Unrecoverable startup failure",
            "I1121 13:38:11.811000 6187495424 workspace.py:18] Opened /Users/example/error-handling with errors=0",
            "I0906 123 local_connection.py failed",
            "ordinary stderr",
            "UserWarning: deprecated option enabled",
            "  File \"server.py\", line 2390, in authenticate",
            "Traceback (most recent call last):\n  File \"main.py\", line 80, in main\nRuntimeError: oauth refresh failed"
        ]

        for line in startupInfoLines + diagnosticOnlyEdgeCases {
            XCTAssertEqual(provider.stderrLineDisposition(line), .diagnosticsOnly, line)
            XCTAssertFalse(provider.shouldEmitStderrLine(line), line)
        }
    }
}
