import Foundation
@testable import RepoPrompt
import XCTest

final class GrokACPLaunchResolverTests: XCTestCase {
    func testMakeLaunchConfigurationResolvesExactPathWithoutPriorProbe() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "grok", in: directory)
        let resolver = GrokACPLaunchResolver()
        let provider = GrokACPAgentProvider(
            config: GrokAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false
            ),
            launchResolver: resolver
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.command, executable.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(launch.arguments, ["agent", "--always-approve", "stdio"])
        XCTAssertEqual(launch.expectedExecutableIdentity?.canonicalPath, launch.command)
    }

    func testBareGrokUsesCapturedEnvironmentAndCachesCanonicalPathForSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let probePathRecord = directory.appendingPathComponent("probe-path")
        let executable = try makeExecutable(named: "grok", in: directory, marker: probePathRecord)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let testEnvironment = environment
        let resolver = GrokACPLaunchResolver(environmentProvider: { _ in testEnvironment })
        let config = GrokAgentConfig(
            commandName: "grok",
            additionalPathHints: [],
            includeRepoPromptMCPServer: false
        )

        let support = try await resolver.probeSupport(for: config)
        let provider = GrokACPAgentProvider(config: config, launchResolver: resolver)
        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))
        let probedPath = try String(contentsOf: probePathRecord, encoding: .utf8)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, executable.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(probedPath, launch.command)
        XCTAssertEqual(launch.arguments, ["agent", "--always-approve", "stdio"])
    }
}

private extension GrokACPLaunchResolverTests {
    func makeRunRequest(workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .grok,
            modelString: AgentModel.grokComposer25Fast.rawValue,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil,
            sessionModeID: nil,
            autoApproveAllToolPermissions: true
        )
    }

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokACPLaunchResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @discardableResult
    func makeExecutable(
        named name: String,
        in directory: URL,
        marker: URL? = nil,
        output: String = "grok agent stdio ACP support",
        exitStatus: Int32 = 0
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        var lines = ["#!/bin/sh"]
        if let marker {
            lines.append("printf '%s' \"$0\" > '\(marker.path)'")
        }
        lines.append("printf '%s\\n' '\(output)'")
        lines.append("exit \(exitStatus)")
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}