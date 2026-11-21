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
        let success = await service.refreshNow(workspacePath: nil)
        let snapshot = await service.latestSnapshot()
        XCTAssertFalse(success)
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

    func testHarnessDiagnosticsAreFilteredExceptFailures() {
        let provider = AntigravityACPAgentProvider(
            executablePath: "fallback", harnessPath: nil, installedRuntime: { nil },
            prepareSessionHome: { URL(fileURLWithPath: "/tmp") }, toolNames: toolNames
        )
        XCTAssertFalse(provider.shouldEmitStderrLine("I0906 123 local_connection.py RAW WS MSG"))
        for level in ["D", "I", "W", "E", "F"] {
            XCTAssertFalse(provider.shouldEmitStderrLine(
                #"\#(level)0906 12:34:56.000000 123 local_connection.py:42] RAW WS MSG: {"text":"error: failed with exception and traceback"}"#
            ))
        }
        XCTAssertTrue(provider.shouldEmitStderrLine("E0906 123 local_connection.py:42] Connection closed"))
        XCTAssertTrue(provider.shouldEmitStderrLine("I0906 123 local_connection.py failed"))
        XCTAssertTrue(provider.shouldEmitStderrLine("ordinary stderr"))
    }
}
