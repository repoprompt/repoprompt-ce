import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import XCTest

final class AntigravityACPProviderTests: XCTestCase {
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

    func testHarnessDiagnosticsAreFilteredExceptFailures() {
        let provider = AntigravityACPAgentProvider(
            executablePath: "fallback", harnessPath: nil, installedRuntime: { nil },
            prepareSessionHome: { URL(fileURLWithPath: "/tmp") }, toolNames: toolNames
        )
        XCTAssertFalse(provider.shouldEmitStderrLine("I0906 123 local_connection.py RAW WS MSG"))
        XCTAssertTrue(provider.shouldEmitStderrLine("I0906 123 local_connection.py failed"))
        XCTAssertTrue(provider.shouldEmitStderrLine("ordinary stderr"))
    }
}
