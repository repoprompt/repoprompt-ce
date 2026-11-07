import Foundation
import RepoPromptACPProviders
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSettingsCore
import XCTest

final class CursorProductionFactoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    func testProductionFactoriesUseAutomaticCommandSelection() async throws {
        let interactiveProvider = try await ACPAgentProviderFactory.makeProvider(
            for: .cursor,
            modelString: "cursor-model"
        )
        let interactiveCursorProvider = try XCTUnwrap(
            interactiveProvider as? CursorACPAgentProvider
        )
        let headlessProvider = AgentRuntimeProviderService.shared.makeProvider(
            for: .cursor,
            modelString: "cursor-model"
        )
        let headlessCursorProvider = try XCTUnwrap(
            headlessProvider as? CursorACPHeadlessAgentProvider
        )
        let chatConfig = CursorCLIProvider.test_makeHeadlessConfig(modelName: "cursor-model")
        let pollingProvider = CursorACPControllerModelDiscoveryClient.test_makeCursorProvider(
            modelString: "cursor-model"
        )

        XCTAssertEqual(interactiveCursorProvider.test_config.commandSelection, .automatic)
        XCTAssertEqual(headlessCursorProvider.test_config.commandSelection, .automatic)
        XCTAssertEqual(chatConfig.commandSelection, .automatic)
        XCTAssertEqual(pollingProvider.test_config.commandSelection, .automatic)
    }

    func testPhysicalApprovalUsesResolvedEnvironmentAndGuardedLeaseCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CursorApprovalBoundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("cursor-agent")
        try "#!/bin/sh\nprintf 'Cursor Agent ACP support\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let mcp = RepoPromptMCPServerConfiguration(command: "/fixture/repoprompt-mcp", args: ["--mcp"])

        for (index, flags) in [(true, true), (true, false), (false, true)].enumerated() {
            let cwd = root.appendingPathComponent("case-\(index)")
            try FileManager.default.createDirectory(at: cwd.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let environment = ["PATH": root.path, "SHELL": "/bin/false", "HOME": root.path, "CURSOR_DATA_DIR": "relative-cursor-data"]
            let resolver = CursorACPLaunchResolver(environmentProvider: { _ in environment }, supplementalPathProvider: { $0 })
            let config = CursorAgentConfig(commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: flags.0, cleanupProjectMCPApproval: flags.1)
            let provider = CursorACPAgentProvider(config: config, repoPromptMCPConfiguration: mcp, launchResolver: resolver)
            let request = ACPRunRequest(agentKind: .cursor, modelString: nil, workspacePath: cwd.path, resumeSessionID: " resume ", attachments: [], taskLabelKind: nil)
            let dataDirectory = cwd.appendingPathComponent("relative-cursor-data")
            let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await provider.support(for: request) }
            XCTAssertEqual(support, .supported)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.path), "Support must not prepare approvals")
            let approvalURL = CursorIntegrationConfiguration.projectMCPApprovalURL(workingDirectory: cwd.path, cursorDataDirectory: dataDirectory)
            if flags.0 {
                try FileManager.default.createDirectory(at: approvalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["user-owned"]).write(to: approvalURL)
            }
            let launch = try provider.makeLaunchConfiguration(for: request)
            let resolved = try resolver.resolvedLaunch(for: config)
            XCTAssertEqual(launch.command, resolved.command)
            XCTAssertEqual(launch.arguments, resolved.arguments)
            XCTAssertEqual(launch.expectedExecutableIdentity, resolved.executableIdentity)
            XCTAssertEqual(launch.environment, flags.0 ? ["CURSOR_DATA_DIR": dataDirectory.path] : [:])
            XCTAssertEqual(launch.explicitEnvironmentKeys, flags.0 ? ["CURSOR_DATA_DIR"] : [])
            let session = try provider.makeSessionConfiguration(for: request, mcpServer: mcp)
            XCTAssertEqual(session.mode, .load(existingSessionID: "resume"))
            XCTAssertEqual(session.mcpServers, flags.0 ? [mcp] : [])
            guard flags.0 else {
                XCTAssertNil(launch.cleanupArtifact)
                XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.path))
                continue
            }
            let approvalID = try CursorIntegrationConfiguration.approvalIdentifier(projectRoot: CursorIntegrationConfiguration.projectRootURL(workingDirectory: cwd.path).path, repoPromptMCPConfiguration: mcp)
            func approvals() throws -> [String] {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: approvalURL)) as? [String])
            }
            XCTAssertEqual(try approvals(), ["user-owned", approvalID])
            if flags.1 {
                let artifact = try XCTUnwrap(launch.cleanupArtifact)
                XCTAssertEqual(artifact.providerID, .cursor)
                XCTAssertEqual(artifact.kind, CursorIntegrationConfiguration.cleanupArtifactKind)
                for invalid in [
                    ACPLaunchCleanupArtifact(providerID: .openCode, id: artifact.id, kind: artifact.kind),
                    ACPLaunchCleanupArtifact(providerID: .cursor, id: artifact.id, kind: "wrong-kind"),
                    ACPLaunchCleanupArtifact(providerID: .cursor, id: UUID(), kind: artifact.kind)
                ] {
                    let forged = ACPLaunchConfiguration(providerID: launch.providerID, command: launch.command, arguments: launch.arguments, environment: launch.environment, workingDirectory: launch.workingDirectory, additionalPathHints: launch.additionalPathHints, enableDebugLogging: launch.enableDebugLogging, cleanupArtifact: invalid, expectedExecutableIdentity: launch.expectedExecutableIdentity, explicitEnvironmentKeys: launch.explicitEnvironmentKeys)
                    await provider.cleanupLaunchArtifacts(for: forged)
                    XCTAssertEqual(try approvals(), ["user-owned", approvalID])
                }
                await provider.cleanupLaunchArtifacts(for: launch)
                XCTAssertEqual(try approvals(), ["user-owned"])
            } else {
                XCTAssertNil(launch.cleanupArtifact)
                await provider.cleanupLaunchArtifacts(for: launch)
                XCTAssertEqual(try approvals(), ["user-owned", approvalID])
            }
        }
    }
}
