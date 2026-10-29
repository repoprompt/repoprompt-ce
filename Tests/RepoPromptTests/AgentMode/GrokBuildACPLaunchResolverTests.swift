import Foundation
import RepoPromptACPProviders
@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptProcess
import XCTest

final class GrokBuildACPLaunchResolverTests: XCTestCase {
    func testMakeLaunchConfigurationResolvesExactPathWithoutPriorProbe() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grok", in: directory)
        let resolver = GrokBuildACPLaunchResolver()
        let provider = GrokBuildACPAgentProvider(
            config: GrokBuildAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false
            ),
            launchResolver: resolver
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
        XCTAssertEqual(launch.arguments, ["agent", "--no-leader", "stdio"])
        XCTAssertEqual(launch.expectedExecutableIdentity?.canonicalPath, launch.command)
    }

    func testProviderPathHintsIncludeDotGrokBin() {
        XCTAssertTrue(CLIPathHints.grokBuild.contains("~/.grok/bin"))
        XCTAssertEqual(CLILaunchProfiles.grokBuild.commandName, "grok")
        XCTAssertTrue(CLILaunchProfiles.grokBuild.supplementalSearchPaths.contains("~/.grok/bin"))
        XCTAssertEqual(GrokBuildAgentConfig().additionalPathHints, CLIPathHints.grokBuild)
    }

    func testSharedResolverKeepsApprovalIntentPerRequest() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grok", in: directory)
        let resolver = GrokBuildACPLaunchResolver()
        for (configFullAccess, requestFullAccess) in [(false, false), (false, true), (false, false), (true, false), (true, true), (false, false)] {
            let provider = GrokBuildACPAgentProvider(
                config: GrokBuildAgentConfig(
                    commandName: executable.path,
                    additionalPathHints: [],
                    includeRepoPromptMCPServer: false,
                    alwaysApproveTools: configFullAccess
                ),
                launchResolver: resolver
            )
            let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path, autoApprove: requestFullAccess))
            XCTAssertEqual(launch.arguments, configFullAccess || requestFullAccess ? ["agent", "--always-approve", "--no-leader", "stdio"] : ["agent", "--no-leader", "stdio"])
        }
    }

    // MARK: - Helpers

    private func makeRunRequest(workspacePath: String, autoApprove: Bool = false) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil,
            autoApproveAllToolPermissions: autoApprove
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "GrokBuildACPLaunchResolverTests")
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try "#!/bin/sh\nprintf '%s\\n' 'grok agent stdio support'\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
