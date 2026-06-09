import Foundation
@testable import RepoPrompt
import XCTest

final class CursorACPLaunchResolverTests: XCTestCase {
    func testMakeLaunchConfigurationResolvesExactPathWithoutPriorProbe() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let resolver = CursorACPLaunchResolver()
        let provider = CursorACPAgentProvider(
            config: CursorAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: false
            ),
            launchResolver: resolver
        )

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.command, executable.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(launch.arguments, ["--approve-mcps", "acp"])
        XCTAssertEqual(launch.expectedExecutableIdentity?.canonicalPath, launch.command)
    }

    func testBareCursorAgentUsesCapturedEnvironmentAndCachesCanonicalPathForSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let probePathRecord = directory.appendingPathComponent("probe-path")
        let executable = try makeExecutable(named: "cursor-agent", in: directory, marker: probePathRecord)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let testEnvironment = environment
        let resolver = CursorACPLaunchResolver(environmentProvider: { _ in testEnvironment })
        let config = CursorAgentConfig(
            commandName: "cursor-agent",
            additionalPathHints: [],
            includeRepoPromptMCPServer: false
        )

        let support = try await resolver.probeSupport(for: config)
        let provider = CursorACPAgentProvider(config: config, launchResolver: resolver)
        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))
        let probedPath = try String(contentsOf: probePathRecord, encoding: .utf8)

        XCTAssertEqual(support, .supported)
        XCTAssertEqual(launch.command, executable.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(probedPath, launch.command)
    }

    func testLaunchConfigurationLeasesCursorApprovalForModernSessionMCPInjection() async throws {
        let workspace = try makeTemporaryDirectory()
        let executableDirectory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: executableDirectory)
        let cursorDataDirectory = try makeTemporaryDirectory()
        let mcpConfiguration = RepoPromptMCPServerConfiguration(
            command: "/tmp/repoprompt-mcp-fixture",
            args: ["--fixture"],
            env: [
                .init(name: "RP_FIXTURE", value: "1")
            ]
        )
        let approvalURL = CursorIntegrationConfiguration.projectMCPApprovalURL(
            workingDirectory: workspace.path,
            cursorDataDirectory: cursorDataDirectory
        )
        try FileManager.default.createDirectory(
            at: approvalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalData = Data(#"["existing-approval"]"#.utf8)
        try originalData.write(to: approvalURL)

        let capturedEnvironment = [
            "CURSOR_DATA_DIR": cursorDataDirectory.path,
            "HOME": "/ignored-by-explicit-cursor-data-dir",
            "PATH": executableDirectory.path
        ]
        let provider = CursorACPAgentProvider(
            config: CursorAgentConfig(
                commandName: executable.path,
                additionalPathHints: []
            ),
            repoPromptMCPConfiguration: mcpConfiguration,
            launchResolver: CursorACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        )
        let request = makeRunRequest(workspacePath: workspace.path)

        let support = try await provider.support(for: request)
        XCTAssertEqual(support, .supported)
        let launch = try provider.makeLaunchConfiguration(for: request)
        let artifact = try XCTUnwrap(launch.cleanupArtifact)
        addTeardownBlock {
            await provider.cleanupLaunchArtifacts(for: launch)
        }
        let approvalsData = try Data(contentsOf: approvalURL)
        let approvals = try XCTUnwrap(
            JSONSerialization.jsonObject(with: approvalsData) as? [String]
        )
        let expectedApproval = try CursorIntegrationConfiguration.approvalIdentifier(
            projectRoot: CursorIntegrationConfiguration.projectRootURL(
                workingDirectory: workspace.path
            ).path,
            repoPromptMCPConfiguration: mcpConfiguration
        )
        let session = try provider.makeSessionConfiguration(
            for: makeRunRequest(workspacePath: workspace.path),
            mcpServer: .repoPrompt
        )

        XCTAssertEqual(launch.environment["CURSOR_DATA_DIR"], cursorDataDirectory.path)
        XCTAssertEqual(artifact.kind, CursorIntegrationConfiguration.cleanupArtifactKind)
        XCTAssertEqual(approvals, ["existing-approval", expectedApproval])
        XCTAssertEqual(session.mcpServers, [mcpConfiguration])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent(".cursor/mcp.json").path
            )
        )

        await provider.cleanupLaunchArtifacts(for: launch)
        let retainedApprovals = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: approvalURL)) as? [String]
        )
        XCTAssertEqual(retainedApprovals, ["existing-approval"])
    }

    func testApprovalIdentifierMatchesCursorCLIHashContract() throws {
        let configuration = RepoPromptMCPServerConfiguration(
            command: "/tmp/repoprompt mcp",
            args: ["--flag", "value"],
            env: [
                .init(name: "A", value: "1"),
                .init(name: "B", value: "two")
            ]
        )

        XCTAssertEqual(
            try CursorIntegrationConfiguration.approvalIdentifier(
                projectRoot: "/tmp/rpce cursor",
                repoPromptMCPConfiguration: configuration
            ),
            "RepoPromptCE-d23f237662b1345f"
        )

        let numericAndDuplicateEnvironmentConfiguration = RepoPromptMCPServerConfiguration(
            command: #"/tmp/repo"prompt\mcp"#,
            args: ["--path", "a/b", "line\nvalue"],
            env: [
                .init(name: "B", value: "first"),
                .init(name: "2", value: "two"),
                .init(name: "01", value: "leading"),
                .init(name: "1", value: "one"),
                .init(name: "B", value: "last"),
                .init(name: "A", value: "line\nvalue")
            ]
        )
        XCTAssertEqual(
            try CursorIntegrationConfiguration.approvalIdentifier(
                projectRoot: #"/tmp/rpce "cursor""#,
                repoPromptMCPConfiguration: numericAndDuplicateEnvironmentConfiguration
            ),
            "RepoPromptCE-05aa1995d1d02aa0"
        )
    }

    func testTmpAliasUsesCursorPhysicalProjectPathForApprovalDirectoryAndHash() throws {
        let workspaceName = "CursorACPLaunchResolverTests-\(UUID().uuidString)"
        let aliasWorkspace = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(workspaceName, isDirectory: true)
        let physicalWorkspace = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(workspaceName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: aliasWorkspace,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: physicalWorkspace)
        }
        XCTAssertNotEqual(aliasWorkspace.path, physicalWorkspace.path)

        let cursorDataDirectory = try makeTemporaryDirectory()
        let configuration = RepoPromptMCPServerConfiguration(command: "/tmp/repoprompt-mcp")
        let aliasProjectRoot = CursorIntegrationConfiguration.projectRootURL(
            workingDirectory: aliasWorkspace.path
        )
        let physicalProjectRoot = CursorIntegrationConfiguration.projectRootURL(
            workingDirectory: physicalWorkspace.path
        )
        let aliasApprovalURL = CursorIntegrationConfiguration.projectMCPApprovalURL(
            workingDirectory: aliasWorkspace.path,
            cursorDataDirectory: cursorDataDirectory
        )
        let physicalApprovalURL = CursorIntegrationConfiguration.projectMCPApprovalURL(
            workingDirectory: physicalWorkspace.path,
            cursorDataDirectory: cursorDataDirectory
        )

        XCTAssertEqual(aliasProjectRoot, physicalWorkspace)
        XCTAssertEqual(aliasProjectRoot, physicalProjectRoot)
        XCTAssertEqual(aliasApprovalURL, physicalApprovalURL)
        XCTAssertEqual(
            aliasApprovalURL.deletingLastPathComponent().lastPathComponent,
            "private-tmp-\(workspaceName)"
        )

        try CursorIntegrationConfiguration.prepareProjectMCPApproval(
            workingDirectory: aliasWorkspace.path,
            cursorDataDirectory: cursorDataDirectory,
            repoPromptMCPConfiguration: configuration,
            cleanupAfterRun: false
        )

        let approvals = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: aliasApprovalURL)) as? [String]
        )
        let physicalApproval = try CursorIntegrationConfiguration.approvalIdentifier(
            projectRoot: physicalWorkspace.path,
            repoPromptMCPConfiguration: configuration
        )
        let aliasApproval = try CursorIntegrationConfiguration.approvalIdentifier(
            projectRoot: aliasWorkspace.path,
            repoPromptMCPConfiguration: configuration
        )
        XCTAssertNotEqual(aliasApproval, physicalApproval)
        XCTAssertEqual(approvals, [physicalApproval])
    }

    func testApprovalCleanupPreservesConcurrentEntriesAndRemovesTemporaryApproval() throws {
        let workspace = try makeTemporaryDirectory()
        let cursorDataDirectory = try makeTemporaryDirectory()
        let configuration = RepoPromptMCPServerConfiguration(command: "/tmp/repoprompt-mcp")
        let approvalURL = CursorIntegrationConfiguration.projectMCPApprovalURL(
            workingDirectory: workspace.path,
            cursorDataDirectory: cursorDataDirectory
        )
        try FileManager.default.createDirectory(
            at: approvalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"["existing-approval"]"#.utf8).write(to: approvalURL)
        let artifact = try XCTUnwrap(
            CursorIntegrationConfiguration.prepareProjectMCPApproval(
                workingDirectory: workspace.path,
                cursorDataDirectory: cursorDataDirectory,
                repoPromptMCPConfiguration: configuration
            )
        )
        let temporaryApproval = try CursorIntegrationConfiguration.approvalIdentifier(
            projectRoot: CursorIntegrationConfiguration.projectRootURL(
                workingDirectory: workspace.path
            ).path,
            repoPromptMCPConfiguration: configuration
        )
        let concurrentData = try JSONSerialization.data(
            withJSONObject: ["existing-approval", temporaryApproval, "cursor-added-approval"],
            options: [.prettyPrinted]
        )
        try concurrentData.write(to: approvalURL, options: .atomic)

        CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: artifact.id)

        let retainedApprovals = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: approvalURL)) as? [String]
        )
        XCTAssertEqual(retainedApprovals, ["existing-approval", "cursor-added-approval"])
    }

    func testConcurrentApprovalLeasesRemoveOnlyRepoPromptInsertionsAfterFinalCleanup() throws {
        for cleanupFirstLeaseFirst in [true, false] {
            let workspace = try makeTemporaryDirectory()
            let cursorDataDirectory = try makeTemporaryDirectory()
            let approvalURL = CursorIntegrationConfiguration.projectMCPApprovalURL(
                workingDirectory: workspace.path,
                cursorDataDirectory: cursorDataDirectory
            )
            try FileManager.default.createDirectory(
                at: approvalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let originalData = Data(#"["existing-approval"]"#.utf8)
            try originalData.write(to: approvalURL)

            let first = try XCTUnwrap(
                CursorIntegrationConfiguration.prepareProjectMCPApproval(
                    workingDirectory: workspace.path,
                    cursorDataDirectory: cursorDataDirectory,
                    repoPromptMCPConfiguration: .init(command: "/tmp/repoprompt-mcp-one")
                )
            )
            let afterFirstLease = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: approvalURL)) as? [String]
            )
            try JSONSerialization.data(
                withJSONObject: afterFirstLease + ["cursor-added-between-leases"],
                options: [.prettyPrinted]
            ).write(to: approvalURL, options: .atomic)

            let second = try XCTUnwrap(
                CursorIntegrationConfiguration.prepareProjectMCPApproval(
                    workingDirectory: workspace.path,
                    cursorDataDirectory: cursorDataDirectory,
                    repoPromptMCPConfiguration: .init(command: "/tmp/repoprompt-mcp-two")
                )
            )
            defer {
                CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: first.id)
                CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: second.id)
            }

            let firstCleanup = cleanupFirstLeaseFirst ? first : second
            let finalCleanup = cleanupFirstLeaseFirst ? second : first
            CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: firstCleanup.id)
            XCTAssertNotEqual(try Data(contentsOf: approvalURL), originalData)

            CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: finalCleanup.id)
            let retainedApprovals = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: approvalURL)) as? [String]
            )
            XCTAssertEqual(retainedApprovals, ["existing-approval", "cursor-added-between-leases"])
        }
    }

    func testFailedFinalApprovalCleanupRetainsRetryBookkeeping() throws {
        let workspace = try makeTemporaryDirectory()
        let cursorDataDirectory = try makeTemporaryDirectory()
        let configuration = RepoPromptMCPServerConfiguration(command: "/tmp/repoprompt-mcp")
        let approvalURL = CursorIntegrationConfiguration.projectMCPApprovalURL(
            workingDirectory: workspace.path,
            cursorDataDirectory: cursorDataDirectory
        )
        let artifact = try XCTUnwrap(
            CursorIntegrationConfiguration.prepareProjectMCPApproval(
                workingDirectory: workspace.path,
                cursorDataDirectory: cursorDataDirectory,
                repoPromptMCPConfiguration: configuration
            )
        )
        let temporaryApproval = try CursorIntegrationConfiguration.approvalIdentifier(
            projectRoot: CursorIntegrationConfiguration.projectRootURL(
                workingDirectory: workspace.path
            ).path,
            repoPromptMCPConfiguration: configuration
        )
        defer {
            CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: artifact.id)
        }

        try FileManager.default.removeItem(at: approvalURL)
        try FileManager.default.createDirectory(at: approvalURL, withIntermediateDirectories: false)
        CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: artifact.id)

        try FileManager.default.removeItem(at: approvalURL)
        try JSONSerialization.data(
            withJSONObject: [temporaryApproval, "cursor-added-after-failure"],
            options: [.prettyPrinted]
        ).write(to: approvalURL, options: .atomic)
        CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: artifact.id)

        let retainedApprovals = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: approvalURL)) as? [String]
        )
        XCTAssertEqual(retainedApprovals, ["cursor-added-after-failure"])
    }

    func testRepeatedProbeRefreshesCurrentEnvironmentBeforeSpawn() async throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        let firstExecutable = try makeExecutable(named: "cursor-agent", in: firstDirectory)
        let secondExecutable = try makeExecutable(named: "cursor-agent", in: secondDirectory)
        let environmentBox = TestEnvironmentBox(environment: [
            "PATH": firstDirectory.path,
            "SHELL": "/bin/false"
        ])
        let resolver = CursorACPLaunchResolver(environmentProvider: { _ in
            await environmentBox.current()
        })
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])

        let firstSupport = try await resolver.probeSupport(for: config)
        let firstLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(firstSupport, .supported)
        XCTAssertEqual(firstLaunch.command, firstExecutable.resolvingSymlinksInPath().path)

        await environmentBox.set([
            "PATH": secondDirectory.path,
            "SHELL": "/bin/false"
        ])
        let secondSupport = try await resolver.probeSupport(for: config)
        let secondLaunch = try resolver.resolvedLaunch(for: config)
        XCTAssertEqual(secondSupport, .supported)
        XCTAssertEqual(secondLaunch.command, secondExecutable.resolvingSymlinksInPath().path)
    }

    func testBareCursorAgentWithoutCapturedDiscoveryFailsClosed() {
        let resolver = CursorACPLaunchResolver(environmentProvider: { _ in [:] })

        XCTAssertThrowsError(
            try resolver.resolvedLaunch(
                for: CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])
            )
        ) { error in
            guard case CursorACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAbsoluteConfiguredPathIgnoresDecoyCursorAgentEarlierInPath() throws {
        let trustedDirectory = try makeTemporaryDirectory()
        let decoyDirectory = try makeTemporaryDirectory()
        let trusted = try makeExecutable(named: "cursor-agent", in: trustedDirectory)
        _ = try makeExecutable(named: "cursor-agent", in: decoyDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = decoyDirectory.path
        environment["SHELL"] = "/bin/false"
        let testEnvironment = environment
        let resolver = CursorACPLaunchResolver(environmentProvider: { _ in testEnvironment })
        let config = CursorAgentConfig(
            commandName: trusted.path,
            additionalPathHints: []
        )

        let launch = try resolver.resolvedLaunch(for: config)

        XCTAssertEqual(launch.command, trusted.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testSymlinkIsCanonicalizedAndCanonicalWrapperBasenameIsAllowed() throws {
        let directory = try makeTemporaryDirectory()
        let target = try makeExecutable(named: "cursor-agent-wrapper", in: directory)
        let link = directory.appendingPathComponent("cursor-agent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let launch = try CursorACPLaunchResolver().resolvedLaunch(
            for: CursorAgentConfig(commandName: link.path, additionalPathHints: [])
        )

        XCTAssertEqual(launch.command, target.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testSymlinkWhoseCanonicalBasenameIsCursorIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let target = try makeExecutable(named: "cursor", in: directory)
        let link = directory.appendingPathComponent("cursor-agent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try CursorACPLaunchResolver().resolvedLaunch(
                for: CursorAgentConfig(commandName: link.path, additionalPathHints: [])
            )
        ) { error in
            guard case CursorACPLaunchResolutionError.unsafeCanonicalBasename = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSymlinkIntoApplicationBundleIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let appExecutableDirectory = directory
            .appendingPathComponent("Cursor.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: appExecutableDirectory, withIntermediateDirectories: true)
        let target = try makeExecutable(named: "cursor-agent-wrapper", in: appExecutableDirectory)
        let link = directory.appendingPathComponent("cursor-agent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try CursorACPLaunchResolver().resolvedLaunch(
                for: CursorAgentConfig(commandName: link.path, additionalPathHints: [])
            )
        ) { error in
            guard case CursorACPLaunchResolutionError.unsafeApplicationPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCachedIdentityDriftFailsClosed() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let resolver = CursorACPLaunchResolver()
        let config = CursorAgentConfig(commandName: executable.path, additionalPathHints: [])

        let support = try await resolver.probeSupport(for: config)
        XCTAssertEqual(support, .supported)
        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(named: "cursor-agent", in: directory, output: "replacement ACP")

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case ExecutableFileIdentityError.identityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMissingExecutableFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        let missing = directory.appendingPathComponent("cursor-agent")

        XCTAssertThrowsError(
            try CursorACPLaunchResolver().resolvedLaunch(
                for: CursorAgentConfig(commandName: missing.path, additionalPathHints: [])
            )
        ) { error in
            guard case CursorACPLaunchResolutionError.exactPathNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCursorTokenIsRejectedWithoutExecution() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("cursor-ran")
        _ = try makeExecutable(named: "cursor", in: directory, marker: marker)
        let config = CursorAgentConfig(commandName: "cursor", additionalPathHints: [directory.path])

        let support = try await CursorACPLaunchResolver().probeSupport(for: config)

        guard case let .unsupported(reason) = support else {
            return XCTFail("Expected unsupported result")
        }
        XCTAssertTrue(reason.contains("Refusing unsafe Cursor ACP command"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancelledSupportProbePropagatesCancellationAndLeavesNoBareCommandCache() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("probe-started")
        _ = try makeExecutable(named: "cursor-agent", in: directory, marker: marker, sleepSeconds: 30)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let capturedEnvironment = environment
        let resolver = CursorACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])

        let probe = Task { try await resolver.probeSupport(for: config) }
        let didStartProbe = await waitUntilFileExists(marker)
        XCTAssertTrue(didStartProbe)
        probe.cancel()
        do {
            _ = try await probe.value
            XCTFail("Expected support probe cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not converted into an unsupported result.
        }

        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case CursorACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWorldWritableExecutableDirectoryIsRejectedWithoutExecution() async throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("probe-ran")
        let executable = try makeExecutable(named: "cursor-agent", in: directory, marker: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)

        let support = try await CursorACPLaunchResolver().probeSupport(
            for: CursorAgentConfig(commandName: executable.path, additionalPathHints: [])
        )

        guard case .unsupported = support else {
            return XCTFail("Expected unsafe launch path to be unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFailedBareProbeDoesNotLeaveSpawnableCacheAndReplacementCanRecover() async throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(named: "cursor-agent", in: directory, exitStatus: 2)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["SHELL"] = "/bin/false"
        let capturedEnvironment = environment
        let resolver = CursorACPLaunchResolver(environmentProvider: { _ in capturedEnvironment })
        let config = CursorAgentConfig(commandName: "cursor-agent", additionalPathHints: [])

        guard case .unsupported = try await resolver.probeSupport(for: config) else {
            return XCTFail("Expected failed support probe")
        }
        XCTAssertThrowsError(try resolver.resolvedLaunch(for: config)) { error in
            guard case CursorACPLaunchResolutionError.environmentDiscoveryRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try FileManager.default.removeItem(at: executable)
        let replacement = try makeExecutable(named: "cursor-agent", in: directory)
        let replacementSupport = try await resolver.probeSupport(for: config)
        XCTAssertEqual(replacementSupport, .supported)
        XCTAssertEqual(
            try resolver.resolvedLaunch(for: config).command,
            replacement.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func testFailedExactProbeDoesNotExecuteCursorFallback() async throws {
        let directory = try makeTemporaryDirectory()
        let probeMarker = directory.appendingPathComponent("cursor-agent-probed")
        let fallbackMarker = directory.appendingPathComponent("cursor-fallback-ran")
        let cursorAgent = try makeExecutable(
            named: "cursor-agent",
            in: directory,
            marker: probeMarker,
            exitStatus: 2
        )
        _ = try makeExecutable(named: "cursor", in: directory, marker: fallbackMarker)
        let config = CursorAgentConfig(
            commandName: cursorAgent.path,
            additionalPathHints: [directory.path]
        )

        let support = try await CursorACPLaunchResolver().probeSupport(for: config)

        guard case .unsupported = support else {
            return XCTFail("Expected unsupported result")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: probeMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackMarker.path))
    }

    func testControllerRejectsIdentityDriftBeforeSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        let spawnMarker = directory.appendingPathComponent("spawned")
        let executable = try makeExecutable(named: "cursor-agent", in: directory)
        let identity = try ExecutableFileIdentity.capture(atPath: executable.path)
        let launch = ACPLaunchConfiguration(
            providerID: .cursor,
            command: identity.canonicalPath,
            arguments: ["--approve-mcps", "acp"],
            environment: [:],
            workingDirectory: directory.path,
            additionalPathHints: [],
            enableDebugLogging: false,
            expectedExecutableIdentity: identity
        )
        let provider = FixedLaunchACPProvider(launchConfiguration: launch, workingDirectory: directory.path)
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeRunRequest(workspacePath: directory.path)
        )
        #if DEBUG
            let runID = UUID()
            await ServerNetworkManager.shared.debugClearRunRoutingHistoryForTesting()
            await controller.setExpectedMCPRunID(runID)
        #endif

        try FileManager.default.removeItem(at: executable)
        _ = try makeExecutable(named: "cursor-agent", in: directory, marker: spawnMarker)

        do {
            _ = try await controller.bootstrap()
            XCTFail("Expected launch identity validation to fail")
        } catch {
            guard case ExecutableFileIdentityError.identityChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spawnMarker.path))
        #if DEBUG
            let payload = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(runID: runID, limit: 20)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            let failed = try XCTUnwrap(events.first { $0["event"] as? String == "acp_launch_validation_failed" })
            let fields = try XCTUnwrap(failed["fields"] as? [String: String])
            XCTAssertEqual(fields["configured_command"], identity.canonicalPath)
            XCTAssertEqual(fields["resolved_executable"], identity.canonicalPath)
            XCTAssertEqual(fields["error_kind"], "executable_identity")
            XCTAssertNotNil(fields["error_type"])
            XCTAssertNotNil(Int(fields["error_code"] ?? ""))
            XCTAssertFalse(events.contains { $0["event"] as? String == "acp_process_spawned" })
        #endif
        await controller.shutdown()
    }

    func testModernModeErrorNormalizationPreservesRawDetail() {
        let provider = makeProviderForNormalization()
        let rawDetail = "ACP request session/set_config_option failed for mode ask: upstream detail 42"
        let rawError = NSError(
            domain: "CursorACP",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: rawDetail]
        )

        let normalized = provider.normalizeError(rawError)

        guard case let AIProviderError.invalidConfiguration(detail) = normalized else {
            return XCTFail("Unexpected normalized error: \(normalized)")
        }
        XCTAssertEqual(detail, rawDetail)
    }

    func testUnclassifiedProviderErrorRetainsUnderlyingError() {
        let provider = makeProviderForNormalization()
        let rawError = NSError(
            domain: "CursorACP.Raw",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "unclassified upstream detail"]
        )

        let normalized = provider.normalizeError(rawError)

        guard case let AIProviderError.apiError(source) = normalized else {
            return XCTFail("Unexpected normalized error: \(normalized)")
        }
        let sourceError = source as NSError?
        XCTAssertEqual(sourceError?.domain, rawError.domain)
        XCTAssertEqual(sourceError?.code, rawError.code)
        XCTAssertEqual(sourceError?.localizedDescription, rawError.localizedDescription)
    }

    private func makeProviderForNormalization() -> CursorACPAgentProvider {
        CursorACPAgentProvider(
            config: CursorAgentConfig(commandName: "cursor-agent"),
            launchResolver: CursorACPLaunchResolver()
        )
    }

    private func makeRunRequest(workspacePath: String) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .cursor,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorACPLaunchResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @discardableResult
    private func makeExecutable(
        named name: String,
        in directory: URL,
        marker: URL? = nil,
        output: String = "Cursor Agent ACP support",
        exitStatus: Int32 = 0,
        sleepSeconds: Int? = nil
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        var lines = ["#!/bin/sh"]
        if let marker {
            lines.append("printf '%s' \"$0\" > '\(marker.path)'")
        }
        if let sleepSeconds {
            lines.append("exec /bin/sleep \(sleepSeconds)")
        }
        lines.append("printf '%s\\n' '\(output)'")
        lines.append("exit \(exitStatus)")
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func waitUntilFileExists(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            await Task.yield()
        } while Date() < deadline
        return false
    }
}

private actor TestEnvironmentBox {
    private var environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    func current() -> [String: String] {
        environment
    }

    func set(_ environment: [String: String]) {
        self.environment = environment
    }
}

private struct FixedLaunchACPProvider: ACPAgentProvider {
    let launchConfiguration: ACPLaunchConfiguration
    let workingDirectory: String

    var providerID: ACPProviderID {
        .cursor
    }

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
        launchConfiguration
    }

    func makeSessionConfiguration(
        for _: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: workingDirectory,
            mcpServers: []
        )
    }

    func buildPromptBlocks(
        for _: AgentMessage,
        request _: ACPRunRequest
    ) throws -> [[String: Any]] {
        []
    }

    func normalizeSessionUpdate(
        _: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
