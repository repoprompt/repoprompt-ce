import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorFigmaMCPToolSurfaceProbeTests: XCTestCase {
    func testExactCommandsDocumentedOutputAndFiveMinuteCache() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let executable = try makeExecutable()
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path)
        let script = CursorFigmaProbeScript(
            versionOutput: "2026.08.25-3e8eec8\n",
            toolsOutput: Self.documentedToolOutput
        )
        let probe = CursorFigmaMCPToolSurfaceProbe(
            processRunner: { invocation in await script.run(invocation) },
            now: { now }
        )

        // A completed login must enable before its first tool verification. A cached passive
        // recheck skips all commands, a fresh passive test bypasses the cache without enabling,
        // and reconnect forces enable again after RepoPrompt Disconnect.
        let first = await probe.observe(
            executableIdentity: identity,
            environment: ["PATH": "/usr/local/bin"],
            requiresEnable: true
        )
        let second = await probe.observe(
            executableIdentity: identity,
            environment: ["PATH": "/usr/local/bin"]
        )
        let freshPassive = await probe.observe(
            executableIdentity: identity,
            environment: ["PATH": "/usr/local/bin"],
            cachePolicy: .requireFreshObservation
        )
        let reconnect = await probe.observe(
            executableIdentity: identity,
            environment: ["PATH": "/usr/local/bin"],
            requiresEnable: true,
            cachePolicy: .requireFreshObservation
        )

        let expected = CursorFigmaMCPToolSurfaceCandidate(
            observedAt: now,
            expiresAt: now.addingTimeInterval(5 * 60),
            executableBuild: "2026.08.25-3e8eec8",
            targetIdentifier: "figma"
        )
        XCTAssertEqual(first, .candidate(expected))
        XCTAssertEqual(second, .candidate(expected))
        XCTAssertEqual(freshPassive, .candidate(expected))
        XCTAssertEqual(reconnect, .candidate(expected))
        let invocations = await script.invocations
        XCTAssertEqual(invocations.map(\.arguments), [
            ["--version"],
            ["mcp", "enable", "figma"],
            ["mcp", "list-tools", "figma"],
            ["--version"],
            ["mcp", "list-tools", "figma"],
            ["--version"],
            ["mcp", "enable", "figma"],
            ["mcp", "list-tools", "figma"]
        ])
        XCTAssertTrue(invocations[1].configuration.discardOutput)
        XCTAssertEqual(invocations[1].configuration.captureStdoutTailBytes, 0)
        XCTAssertEqual(invocations[1].configuration.captureStderrTailBytes, 0)
        XCTAssertTrue(invocations.allSatisfy { $0.configuration.command == identity.canonicalPath })
        XCTAssertTrue(invocations.allSatisfy(\.configuration.requiresAbsoluteExecutable))
        XCTAssertTrue(invocations.allSatisfy { $0.configuration.shellLookupMode == .disabled })
        XCTAssertFalse(invocations.flatMap(\.arguments).contains("whoami"))

        let beforeExpiry = await probe.cachedCandidate(
            for: identity,
            at: expected.expiresAt.addingTimeInterval(-0.001)
        )
        let atExpiry = await probe.cachedCandidate(
            for: identity,
            at: expected.expiresAt
        )
        XCTAssertNotNil(beforeExpiry)
        XCTAssertNil(atExpiry)
    }

    func testFreshPassiveObservationListsToolsWithoutEnabling() async throws {
        let executable = try makeExecutable()
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path)
        let script = CursorFigmaProbeScript(
            versionOutput: "2026.08.25-3e8eec8\n",
            toolsOutput: Self.documentedToolOutput
        )
        let probe = CursorFigmaMCPToolSurfaceProbe(
            processRunner: { invocation in await script.run(invocation) }
        )

        let outcome = await probe.observe(executableIdentity: identity, environment: [:])
        let invocations = await script.invocations

        guard case .candidate = outcome else {
            return XCTFail("A passive Settings observation should accept the verified tool surface.")
        }
        XCTAssertEqual(invocations.map(\.arguments), [
            ["--version"],
            ["mcp", "list-tools", "figma"]
        ])
    }

    func testProbeRequiresExactBuildAndUniqueRequiredTools() async throws {
        let executable = try makeExecutable()
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path)
        let unsupportedScript = CursorFigmaProbeScript(
            versionOutput: "2026.08.25-0000000\n",
            toolsOutput: Self.documentedToolOutput
        )
        let unsupportedProbe = CursorFigmaMCPToolSurfaceProbe(
            processRunner: { invocation in await unsupportedScript.run(invocation) }
        )
        let unsupported = await unsupportedProbe.observe(
            executableIdentity: identity,
            environment: [:]
        )
        let unsupportedInvocations = await unsupportedScript.invocations
        XCTAssertEqual(unsupported, .unavailable(.unsupportedBuild))
        XCTAssertEqual(unsupportedInvocations.map(\.arguments), [["--version"]])

        let duplicateScript = CursorFigmaProbeScript(
            versionOutput: "2026.08.25-3e8eec8\n",
            toolsOutput: """
            Tools for figma (4):
            - whoami ()
            - whoami ()
            - get_design_context (fileKey, nodeId)
            - get_variable_defs (fileKey, nodeId)

            """
        )
        let duplicateProbe = CursorFigmaMCPToolSurfaceProbe(
            processRunner: { invocation in await duplicateScript.run(invocation) }
        )
        let duplicate = await duplicateProbe.observe(
            executableIdentity: identity,
            environment: [:]
        )
        XCTAssertEqual(duplicate, .unavailable(.duplicateTool))

        let missingScript = CursorFigmaProbeScript(
            versionOutput: "2026.08.25-3e8eec8\n",
            toolsOutput: """
            Tools for figma (2):
            - whoami ()
            - get_design_context (fileKey, nodeId)

            """
        )
        let missingProbe = CursorFigmaMCPToolSurfaceProbe(
            processRunner: { invocation in await missingScript.run(invocation) }
        )
        let missing = await missingProbe.observe(
            executableIdentity: identity,
            environment: [:]
        )
        XCTAssertEqual(missing, .unavailable(.missingRequiredTool))

        let enableFailureScript = CursorFigmaProbeScript(
            versionOutput: "2026.08.25-3e8eec8\n",
            toolsOutput: Self.documentedToolOutput,
            enableStatus: 1
        )
        let enableFailureProbe = CursorFigmaMCPToolSurfaceProbe(
            processRunner: { invocation in await enableFailureScript.run(invocation) }
        )
        let enableFailure = await enableFailureProbe.observe(
            executableIdentity: identity,
            environment: [:],
            requiresEnable: true
        )
        XCTAssertEqual(enableFailure, .unavailable(.nonzeroExit))
        let enableFailureInvocations = await enableFailureScript.invocations
        XCTAssertEqual(enableFailureInvocations.map(\.arguments), [
            ["--version"],
            ["mcp", "enable", "figma"]
        ])

        let enableTimeoutScript = CursorFigmaProbeScript(
            versionOutput: "2026.08.25-3e8eec8\n",
            toolsOutput: Self.documentedToolOutput,
            enableTimedOut: true
        )
        let enableTimeoutProbe = CursorFigmaMCPToolSurfaceProbe(
            processRunner: { invocation in await enableTimeoutScript.run(invocation) }
        )
        let enableTimeout = await enableTimeoutProbe.observe(
            executableIdentity: identity,
            environment: [:],
            requiresEnable: true
        )
        XCTAssertEqual(enableTimeout, .unavailable(.timedOut))
        let enableTimeoutInvocations = await enableTimeoutScript.invocations
        XCTAssertEqual(enableTimeoutInvocations.map(\.arguments), [
            ["--version"],
            ["mcp", "enable", "figma"]
        ])
    }

    func testRejectsReplacementBetweenVersionAndToolListingAndDoesNotReusePathCache() async throws {
        let executable = try makeExecutable()
        let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path)
        let replacement = executable.deletingLastPathComponent().appendingPathComponent("replacement")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replacement.path)
        let script = CursorFigmaReplacementProbeScript(replacement: replacement, executable: executable)
        let probe = CursorFigmaMCPToolSurfaceProbe(processRunner: { invocation in
            try await script.run(invocation)
        })

        let outcome = await probe.observe(executableIdentity: identity, environment: [:])
        let invocations = await script.invocations

        XCTAssertEqual(outcome, .unavailable(.executableUnavailable))
        XCTAssertEqual(invocations, [["--version"]])
        let replacementIdentity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path)
        XCTAssertNotEqual(identity, replacementIdentity)
        let cachedReplacement = await probe.cachedCandidate(for: replacementIdentity, at: Date())
        XCTAssertNil(cachedReplacement)
    }

    private func makeExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CursorFigmaMCPToolSurfaceProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("cursor-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private static let documentedToolOutput = """
    Tools for figma (3):
    - whoami ()
    - get_design_context (fileKey, nodeId)
    - get_variable_defs (fileKey, nodeId)

    """
}

@MainActor
final class CursorFigmaMCPSettingsObservationTests: XCTestCase {
    func testFreshObservationIsSettingsOnlyConnectedAfterLogin() async throws {
        let observedAt = Date()
        let observer = CursorFigmaSettingsObservationScript(outcomes: [
            .candidate(.init(
                observedAt: observedAt,
                expiresAt: observedAt.addingTimeInterval(60),
                executableBuild: CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild,
                targetIdentifier: CursorFigmaMCPToolSurfaceDescriptor.targetIdentifier
            )),
            .unavailable(.unsupportedBuild)
        ])
        let model = try makeModel(observer: observer)

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.cursorRow(in: model)?.actions.map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .cursor, action: .connect)
        try await waitUntil {
            self.cursorRow(in: model)?.status == .connected
        }

        let observedRow = try XCTUnwrap(cursorRow(in: model))
        XCTAssertEqual(observedRow.status, .connected)
        XCTAssertEqual(observedRow.verifiedAt, observedAt)
        XCTAssertEqual(
            observedRow.timestampPresentation,
            .observed(validUntil: observedAt.addingTimeInterval(60))
        )
        XCTAssertEqual(observedRow.actions.map(\.id), [.testConnection])
        XCTAssertEqual(observedRow.message, "Figma is connected.")
        XCTAssertEqual(observedRow.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Figma sign-in not independently verified by RepoPrompt CE"),
            .credentialOwner("Managed by Cursor CLI")
        ])
        XCTAssertEqual(model.integrationCardStatus, .connected)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Connected")
        XCTAssertNil(model.figmaProviderConnectionCoordinator.state(for: .cursor))

        model.updateCLIAvailability(.none)
        let retainedRow = try XCTUnwrap(cursorRow(in: model))
        XCTAssertEqual(retainedRow.status, .connected)
        XCTAssertEqual(retainedRow.connectionSummary, observedRow.connectionSummary)
        XCTAssertFalse(retainedRow.canExpand)
        XCTAssertTrue(retainedRow.actions.allSatisfy(\.isDisabled))
        XCTAssertTrue(model.providerRowGroups.notConnected.contains { $0.id == .cursor })
        model.performProviderRowAction(provider: .cursor, action: .testConnection)
        model.updateCLIAvailability(FigmaSettingsTestCLIAvailability.withoutCodex)
        XCTAssertTrue(try XCTUnwrap(cursorRow(in: model)).canExpand)
        XCTAssertTrue(model.providerRowGroups.connected.contains { $0.id == .cursor })

        let requiresEnableRequests = await observer.requiresEnableRequests
        let cachePolicyRequests = await observer.cachePolicyRequests
        XCTAssertEqual(requiresEnableRequests, [true])
        XCTAssertEqual(cachePolicyRequests, [.requireFreshObservation])
    }

    func testDeactivationCancelsAndClearsSettingsObservation() async throws {
        let observer = BlockingCursorFigmaSettingsObserver()
        let model = try makeModel(observer: observer)

        model.activateAndLoad()
        try await waitUntil { self.cursorRow(in: model)?.actions.map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .cursor, action: .connect)
        try await waitUntil { await observer.callCount == 1 }
        XCTAssertTrue(model.isObservingCursorFigmaToolSurface)

        model.deactivate()

        try await waitUntil { await observer.cancellationCount == 1 }
        XCTAssertFalse(model.isObservingCursorFigmaToolSurface)
        XCTAssertNil(model.cursorFigmaToolSurfaceObservation)
    }

    private func makeModel(
        observer: any CursorFigmaMCPToolSurfaceObserving
    ) throws -> MCPIntegrationsSettingsViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CursorFigmaMCPSettingsObservationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "CursorFigmaMCPSettingsObservationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: directory.appendingPathComponent("globalSettings.json")
            )
        )
        let providerCoordinator = FigmaMCPProviderConnectionCoordinator(
            registry: ExternalMCPAdapterRegistry(), sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }),
            terminationObserver: CursorFigmaSettingsTerminationObserver()
        )
        let executable = directory.appendingPathComponent("cursor-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let components = CursorFigmaMCPLoginFactory.makeComponents(
            sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }),
            targetDataLoader: { _ in
                Data(#"{"mcpServers":{"figma":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8)
            }
        )
        let driver = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: components.subprocessDescriptor,
            inheritedEnvironment: ["PATH": directory.path, "TERM": "xterm-256color"],
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            executableVersionResolver: {
                CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild
            },
            processRunner: { _ in .init(status: 0, timedOut: false) }
        )
        return MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            providerConnectionCoordinator: providerCoordinator,
            cursorFigmaToolSurfaceObserver: observer,
            cursorFigmaLoginComponents: components,
            cursorFigmaLoginDriver: driver
        )
    }

    private func cursorRow(
        in model: MCPIntegrationsSettingsViewModel
    ) -> FigmaMCPProviderRowPresentation? {
        model.providerRows.first(where: { $0.id == .cursor })
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let step: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while await !condition(), waited < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
        let result = await condition()
        XCTAssertTrue(result, "Condition did not become true before timeout")
    }
}

private actor CursorFigmaProbeScript {
    private(set) var invocations: [CursorFigmaMCPToolSurfaceProbe.Invocation] = []
    let versionOutput: String
    let toolsOutput: String
    let enableStatus: Int32
    let enableTimedOut: Bool

    init(
        versionOutput: String,
        toolsOutput: String,
        enableStatus: Int32 = 0,
        enableTimedOut: Bool = false
    ) {
        self.versionOutput = versionOutput
        self.toolsOutput = toolsOutput
        self.enableStatus = enableStatus
        self.enableTimedOut = enableTimedOut
    }

    func run(
        _ invocation: CursorFigmaMCPToolSurfaceProbe.Invocation
    ) -> CursorFigmaMCPToolSurfaceProbeProcessResult {
        invocations.append(invocation)
        let isEnable = invocation.arguments == ["mcp", "enable", "figma"]
        let stdout = invocation.arguments == ["--version"] ? versionOutput : toolsOutput
        return .init(
            stdout: Data(stdout.utf8),
            stderr: Data(),
            status: isEnable ? enableStatus : 0,
            timedOut: isEnable && enableTimedOut
        )
    }
}

private actor CursorFigmaSettingsObservationScript: CursorFigmaMCPToolSurfaceObserving {
    private var outcomes: [CursorFigmaMCPToolSurfaceProbeOutcome]
    private(set) var callCount = 0
    private(set) var requiresEnableRequests: [Bool] = []
    private(set) var cachePolicyRequests: [CursorFigmaMCPToolSurfaceCachePolicy] = []

    init(outcomes: [CursorFigmaMCPToolSurfaceProbeOutcome]) {
        self.outcomes = outcomes
    }

    func observe(
        launch _: FigmaMCPProviderResolvedLoginLaunch,
        requiresEnable: Bool,
        cachePolicy: CursorFigmaMCPToolSurfaceCachePolicy
    ) async -> CursorFigmaMCPToolSurfaceProbeOutcome {
        callCount += 1
        requiresEnableRequests.append(requiresEnable)
        cachePolicyRequests.append(cachePolicy)
        guard !outcomes.isEmpty else { return .unavailable(.processFailed) }
        return outcomes.removeFirst()
    }
}

private actor BlockingCursorFigmaSettingsObserver: CursorFigmaMCPToolSurfaceObserving {
    private(set) var callCount = 0
    private(set) var cancellationCount = 0

    func observe(
        launch _: FigmaMCPProviderResolvedLoginLaunch,
        requiresEnable _: Bool,
        cachePolicy _: CursorFigmaMCPToolSurfaceCachePolicy
    ) async -> CursorFigmaMCPToolSurfaceProbeOutcome {
        callCount += 1
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .unavailable(.processFailed)
        } catch {
            cancellationCount += 1
            return .unavailable(.cancelled)
        }
    }
}

@MainActor
private final class CursorFigmaSettingsTerminationObserver: ApplicationTerminationObserving {
    func observeApplicationTermination(_: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NSObject()
    }

    func removeApplicationTerminationObserver(_: NSObjectProtocol) {}
}

private actor CursorFigmaReplacementProbeScript {
    private let replacement: URL
    private let executable: URL
    private(set) var invocations: [[String]] = []

    init(replacement: URL, executable: URL) {
        self.replacement = replacement
        self.executable = executable
    }

    func run(_ invocation: CursorFigmaMCPToolSurfaceProbe.Invocation) throws -> CursorFigmaMCPToolSurfaceProbeProcessResult {
        invocations.append(invocation.arguments)
        if invocation.arguments == ["--version"] {
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.moveItem(at: replacement, to: executable)
        }
        return .init(
            stdout: Data("2026.08.25-3e8eec8\n".utf8),
            stderr: Data(),
            status: 0,
            timedOut: false
        )
    }
}
