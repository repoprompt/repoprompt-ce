import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Covers the Devin permission mode end to end: the level enum, its provider-binding
/// identity, the persisted store binding, the launch argument the provider emits, and the
/// controller reuse key that forces a fresh process when the launch flag changes.
final class DevinPermissionLevelTests: XCTestCase {
    private typealias Level = DevinAgentToolPreferences.PermissionLevel

    // MARK: - PermissionLevel

    func testPickerOrderIsProviderDefaultFirstAndFullApprovalLast() {
        XCTAssertEqual(
            Level.allCases,
            [.providerDefault, .normal, .acceptEdits, .smart, .fullApproval]
        )
    }

    func testStoredRawValueParsingFailsClosedToProviderDefault() {
        XCTAssertEqual(Level.from(rawValue: nil), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: ""), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: "   "), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: "garbage"), .providerDefault)
        // The pre-ship draft persisted this raw value; it must not resolve to a broader mode.
        XCTAssertEqual(Level.from(rawValue: "providerManaged"), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: "  fullApproval "), .fullApproval)
        for level in Level.allCases {
            XCTAssertEqual(Level.from(rawValue: level.rawValue), level)
        }
    }

    func testCLIPermissionModeRoundTripsAndFailsClosed() {
        XCTAssertEqual(Level.from(cliPermissionMode: "auto"), .normal)
        XCTAssertEqual(Level.from(cliPermissionMode: "accept-edits"), .acceptEdits)
        XCTAssertEqual(Level.from(cliPermissionMode: "smart"), .smart)
        XCTAssertEqual(Level.from(cliPermissionMode: "dangerous"), .fullApproval)
        XCTAssertEqual(Level.from(cliPermissionMode: nil), .providerDefault)
        XCTAssertEqual(Level.from(cliPermissionMode: "bogus"), .providerDefault)
        // `autonomous` requires `--sandbox` and is deliberately not offered.
        XCTAssertEqual(Level.from(cliPermissionMode: "autonomous"), .providerDefault)
    }

    func testLaunchArgumentsMatchTheInstalledCLIVocabulary() {
        XCTAssertEqual(Level.providerDefault.launchArguments, [])
        XCTAssertEqual(Level.normal.launchArguments, ["--permission-mode", "auto"])
        XCTAssertEqual(Level.acceptEdits.launchArguments, ["--permission-mode", "accept-edits"])
        XCTAssertEqual(Level.smart.launchArguments, ["--permission-mode", "smart"])
        XCTAssertEqual(Level.fullApproval.launchArguments, ["--permission-mode", "dangerous"])
    }

    func testOnlyFullApprovalIsAWarningLevel() {
        for level in Level.allCases {
            XCTAssertEqual(level.isWarning, level == .fullApproval, "unexpected warning flag for \(level)")
        }
    }

    // MARK: - Provider binding identity

    func testPermissionLevelIDExposesAllFiveDevinOptions() {
        let options = AgentProviderPermissionLevelID.options(for: .devin)
        XCTAssertEqual(options.count, 5)
        XCTAssertEqual(options.map(\.subagentRawValue), Level.allCases.map(\.rawValue))
        XCTAssertEqual(options.map(\.providerID), Array(repeating: .devin, count: 5))
    }

    func testSubagentDefaultPinsNormal() {
        XCTAssertEqual(AgentProviderPermissionLevelID.subagentDefault(for: .devin), .devin(.normal))
    }

    func testSubagentRawValueInitializerAcceptsKnownLevelsOnly() {
        XCTAssertEqual(
            AgentProviderPermissionLevelID(providerID: .devin, subagentRawValue: "smart"),
            .devin(.smart)
        )
        XCTAssertNil(AgentProviderPermissionLevelID(providerID: .devin, subagentRawValue: "providerManaged"))
        XCTAssertNil(AgentProviderPermissionLevelID(providerID: .devin, subagentRawValue: "dangerous"))
    }

    // MARK: - Snapshot store

    @MainActor
    func testRuntimeBindingCarriesTheLaunchPermissionModeForEachProfile() throws {
        let (store, _) = try makeStore()

        XCTAssertNil(store.runtimePermission(for: .devin, profile: .userConfigured).acpLaunchPermissionMode)

        store.setPermissionLevel(.devin(.acceptEdits))
        let configured = store.runtimePermission(for: .devin, profile: .userConfigured)
        XCTAssertEqual(configured.acpLaunchPermissionMode, "accept-edits")

        // Safe Managed ignores the stored direct preference and pins an explicit floor
        // rather than delegating to Devin's own configured default.
        XCTAssertEqual(
            store.runtimePermission(for: .devin, profile: .mcpSafeDefaults).acpLaunchPermissionMode,
            "auto"
        )

        // An override aimed at a different provider falls back to the same pinned floor.
        XCTAssertEqual(
            store.runtimePermission(for: .devin, profile: .providerOverride(.grokBuild(.fullAccess))).acpLaunchPermissionMode,
            "auto"
        )

        let override = store.runtimePermission(for: .devin, profile: .providerOverride(.devin(.fullApproval)))
        XCTAssertEqual(override.acpLaunchPermissionMode, "dangerous")

        // RepoPrompt never answers Devin's own permission requests, whatever the mode is.
        for binding in [configured, override] {
            XCTAssertFalse(binding.autoApproveAllACPToolPermissions)
            XCTAssertFalse(binding.acceptsPendingACPApprovalWhenActivated)
            XCTAssertNil(binding.acpSessionModeID)
        }
    }

    @MainActor
    func testPermissionLevelPersistsSecurelyAndIgnoresDefaultsEscalation() throws {
        let secureStrings = DevinPermissionFakeSecureStringStore()
        let secureStore = AgentPermissionSecureStore(
            secureStrings: secureStrings,
            notificationCenter: NotificationCenter()
        )
        let (store, defaults) = try makeStore(securePermissions: secureStore)

        store.setPermissionLevel(.devin(.smart))
        defaults.set(Level.fullApproval.rawValue, forKey: "devinPermissionLevel")

        XCTAssertEqual(
            DevinAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
            .smart
        )
        XCTAssertNotNil(secureStrings.plainValues[AgentPermissionSecureDomain.devin.storageKey])
    }

    @MainActor
    func testSecurePermissionReadFailureFailsClosedToProviderDefault() throws {
        let secureStore = AgentPermissionSecureStore(
            secureStrings: DevinPermissionFailingSecureStringStore(),
            notificationCenter: NotificationCenter()
        )
        let (_, defaults) = try makeStore(securePermissions: secureStore)
        defaults.set(Level.fullApproval.rawValue, forKey: "devinPermissionLevel")

        XCTAssertEqual(
            DevinAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
            .providerDefault
        )
    }

    @MainActor
    func testChromeBindingRendersFiveEnabledRowsWithTheStoredSelection() throws {
        let (store, _) = try makeStore()
        store.setPermissionLevel(.devin(.smart))

        let binding = store.topLevelSettingsControlsBinding(providerID: .devin)
        XCTAssertEqual(binding.permission.options.count, 5)
        XCTAssertEqual(binding.permission.displayName, Level.smart.displayName)
        XCTAssertFalse(binding.permission.isWarning)
        XCTAssertTrue(binding.permission.options.allSatisfy(\.isEnabled))
        XCTAssertEqual(binding.permission.options.filter(\.isSelected).map(\.id), [.devin(.smart)])
        XCTAssertEqual(binding.permission.options.filter(\.isWarning).map(\.id), [.devin(.fullApproval)])
        XCTAssertNil(binding.codexTools)
        XCTAssertNil(binding.claudeTools)
    }

    @MainActor
    func testChromeBindingUnderSafeManagedShowsThePinnedFloor() throws {
        let (store, _) = try makeStore()
        store.setPermissionLevel(.devin(.fullApproval))

        let binding = store.controlsBinding(
            selectedAgent: .devin,
            permissionProfile: .mcpSafeDefaults,
            isSubagent: true,
            externallyManagedReason: nil
        )
        XCTAssertEqual(binding.permission.displayName, Level.normal.displayName)
        XCTAssertEqual(binding.permission.options.filter(\.isSelected).map(\.id), [.devin(.normal)])
        XCTAssertFalse(binding.permission.isWarning)
        XCTAssertEqual(binding.runtimePermission.acpLaunchPermissionMode, "auto")
    }

    @MainActor
    func testExternallyManagedReasonDisablesEveryDevinOption() throws {
        let (store, _) = try makeStore()
        let binding = store.controlsBinding(
            selectedAgent: .devin,
            permissionProfile: .userConfigured,
            isSubagent: false,
            externallyManagedReason: "Managed by MCP policy"
        )
        XCTAssertEqual(binding.permission.externallyManagedReason, "Managed by MCP policy")
        XCTAssertTrue(binding.permission.options.allSatisfy { !$0.isEnabled })
    }

    @MainActor
    func testProductionRequestBuilderPropagatesLaunchPermissionModeForNewAndFollowUpRuns() throws {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .devin
        let runtimePermission = AgentProviderRuntimePermissionBinding(acpLaunchPermissionMode: "smart")

        let newRun = try XCTUnwrap(AgentModeRunService.makeACPRunRequest(
            session: session,
            workspacePath: "/tmp/workspace",
            attachments: [],
            runtimePermission: runtimePermission
        ))
        XCTAssertEqual(newRun.launchPermissionMode, "smart")
        XCTAssertNil(newRun.resumeSessionID)

        session.providerSessionID = "devin-session"
        let followUp = try XCTUnwrap(AgentModeRunService.makeACPRunRequest(
            session: session,
            workspacePath: "/tmp/workspace",
            attachments: [],
            runtimePermission: runtimePermission
        ))
        XCTAssertEqual(followUp.launchPermissionMode, "smart")
        XCTAssertEqual(followUp.resumeSessionID, "devin-session")
    }

    // MARK: - Provider launch arguments

    func testLaunchPrependsThePermissionModeBeforeTheACPSubcommand() throws {
        let (provider, directory) = try makeProvider()
        let launch = try provider.makeLaunchConfiguration(
            for: makeRequest(workspacePath: directory.path, launchPermissionMode: "dangerous")
        )
        XCTAssertEqual(launch.arguments, ["--permission-mode", "dangerous", "acp"])
        XCTAssertEqual(launch.providerID, .devin)
    }

    func testLaunchWithoutAModePassesNoPermissionFlag() throws {
        let (provider, directory) = try makeProvider()
        let launch = try provider.makeLaunchConfiguration(
            for: makeRequest(workspacePath: directory.path, launchPermissionMode: nil)
        )
        XCTAssertEqual(launch.arguments, ["acp"])
    }

    func testLaunchNormalizesTheCarrierToTheCanonicalCLIVocabulary() throws {
        let (provider, directory) = try makeProvider()
        let launch = try provider.makeLaunchConfiguration(
            for: makeRequest(workspacePath: directory.path, launchPermissionMode: "ACCEPT-EDITS")
        )
        XCTAssertEqual(launch.arguments, ["--permission-mode", "accept-edits", "acp"])
    }

    func testResolvedLaunchAlwaysHoldsTheBareACPSubcommand() throws {
        // `makeLaunchConfiguration` prepends the permission flag to the resolver's argv, so
        // the resolver must never emit a wrapper/shim invocation ahead of `acp`.
        let directory = try makeTestDirectory(name: "DevinResolvedLaunchInvariant")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = try DevinACPLaunchResolver().resolvedLaunch(
            for: DevinAgentConfig(commandName: executable.path)
        )
        XCTAssertEqual(resolved.arguments, ["acp"])
        XCTAssertEqual((resolved.command as NSString).lastPathComponent, "devin")
    }

    func testLaunchDropsAnUnrecognizedPermissionMode() throws {
        let (provider, directory) = try makeProvider()
        let launch = try provider.makeLaunchConfiguration(
            for: makeRequest(workspacePath: directory.path, launchPermissionMode: "bogus")
        )
        XCTAssertEqual(launch.arguments, ["acp"], "an unknown carrier value must never reach the CLI")
    }

    func testBareCommandSupportPreflightWarmsTheProductionLaunch() async throws {
        let directory = try makeTestDirectory(name: "DevinBareCommandLaunch")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\necho 'Run as an ACP server over stdio'\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let resolver = DevinACPLaunchResolver(launchEnvironmentProvider: { _ in
            ACPLaunchEnvironment(environment: ["PATH": directory.path])
        })
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(commandName: "devin", includeRepoPromptMCPServer: false),
            launchResolver: resolver
        )
        let request = makeRequest(workspacePath: directory.path, launchPermissionMode: "auto")

        let support = try await provider.support(for: request)
        XCTAssertEqual(support, .supported)
        let launch = try provider.makeLaunchConfiguration(for: request)

        XCTAssertEqual(
            launch.command,
            try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path).canonicalPath
        )
        XCTAssertEqual(launch.arguments, ["--permission-mode", "auto", "acp"])
    }

    // MARK: - Controller reuse key

    func testControllerReuseKeysOnTheLaunchPermissionMode() async throws {
        let workspace = try makeTestDirectory(name: "DevinPermissionReuseKeyTests")
        let controller = try ACPAgentSessionController(
            provider: ReuseKeyFakeDevinProvider(),
            runRequest: makeRequest(workspacePath: workspace.path, launchPermissionMode: nil)
        )

        let sameMode = await controller.isCompatibleWith(
            request: makeRequest(workspacePath: workspace.path, launchPermissionMode: nil)
        )
        let changedMode = await controller.isCompatibleWith(
            request: makeRequest(workspacePath: workspace.path, launchPermissionMode: "smart")
        )
        let changedModel = await controller.isCompatibleWith(
            request: makeRequest(workspacePath: workspace.path, launchPermissionMode: nil, modelString: "opus")
        )

        let unrecognizedMode = await controller.isCompatibleWith(
            request: makeRequest(workspacePath: workspace.path, launchPermissionMode: "bogus")
        )

        XCTAssertTrue(sameMode)
        XCTAssertFalse(changedMode, "a launch-time permission mode change must build a fresh Devin process")
        XCTAssertTrue(
            unrecognizedMode,
            "an unrecognized carrier normalizes to the same flagless launch as provider default"
        )
        XCTAssertTrue(changedModel, "Devin model switching stays live; it must not recycle the controller")

        await controller.shutdown()
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(
        securePermissions: AgentPermissionSecureStore? = nil
    ) throws -> (AgentProviderPreferenceSnapshotStore, UserDefaults) {
        let suiteName = "DevinPermissionLevelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: securePermissions,
            codexMCPServerEntries: { [] }
        )
        return (store, defaults)
    }

    private func makeProvider() throws -> (DevinACPAgentProvider, URL) {
        let directory = try makeTestDirectory(name: "DevinPermissionLevelTests")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(
                commandName: executable.path,
                includeRepoPromptMCPServer: false
            )
        )
        return (provider, directory)
    }

    private func makeRequest(
        workspacePath: String,
        launchPermissionMode: String?,
        modelString: String? = nil
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .devin,
            modelString: modelString,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil,
            launchPermissionMode: launchPermissionMode
        )
    }
}

final class DevinIntegrationConfigurationTests: XCTestCase {
    func testOverlayPreservesXDGEntriesAndDevinWritesThroughCleanup() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationSource")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        let ghSource = sourceRoot.appendingPathComponent("gh", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ghSource, withIntermediateDirectories: true)
        try "native gh config".write(
            to: ghSource.appendingPathComponent("hosts.yml"),
            atomically: true,
            encoding: .utf8
        )
        try "native config".write(
            to: devinSource.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "untouched state".write(
            to: devinSource.appendingPathComponent("state.bin"),
            atomically: true,
            encoding: .utf8
        )
        let sourceMCP: [String: Any] = [
            "mcpServers": [
                "Existing": ["transport": "stdio", "command": "existing"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: sourceMCP).write(
            to: devinSource.appendingPathComponent("mcp_config.json")
        )
        let executable = sourceRoot.appendingPathComponent("repoprompt-mcp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(
                command: executable.path,
                args: ["--backend", "app"]
            ),
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayDevin = overlayRoot.appendingPathComponent("devin", isDirectory: true)
        let ghDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: overlayRoot.appendingPathComponent("gh").path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: ghDestination).resolvingSymlinksInPath(),
            ghSource.resolvingSymlinksInPath()
        )
        let mergedData = try Data(contentsOf: overlayDevin.appendingPathComponent("mcp_config.json"))
        let mergedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: mergedData) as? [String: Any])
        let mergedServers = try XCTUnwrap(mergedRoot["mcpServers"] as? [String: Any])
        XCTAssertNotNil(mergedServers["Existing"])
        XCTAssertNotNil(mergedServers[RepoPromptMCPServerConfiguration.defaultServerName])

        let replacedConfig = overlayDevin.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: replacedConfig)
        try "updated config".write(to: replacedConfig, atomically: true, encoding: .utf8)
        try "new state".write(
            to: overlayDevin.appendingPathComponent("new-state.json"),
            atomically: true,
            encoding: .utf8
        )

        DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)

        XCTAssertEqual(
            try String(contentsOf: devinSource.appendingPathComponent("config.json"), encoding: .utf8),
            "updated config"
        )
        XCTAssertEqual(
            try String(contentsOf: devinSource.appendingPathComponent("new-state.json"), encoding: .utf8),
            "new state"
        )
        let untouchedState = devinSource.appendingPathComponent("state.bin")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: untouchedState.path))
        XCTAssertEqual(try String(contentsOf: untouchedState, encoding: .utf8), "untouched state")
        XCTAssertEqual(
            try Data(contentsOf: devinSource.appendingPathComponent("mcp_config.json")),
            try JSONSerialization.data(withJSONObject: sourceMCP)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlayRoot.path))
    }

    func testMalformedSourceMCPDoesNotLeaveAnOverlay() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationMalformed")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        try "[]".write(
            to: devinSource.appendingPathComponent("mcp_config.json"),
            atomically: true,
            encoding: .utf8
        )
        let executable = sourceRoot.appendingPathComponent("repoprompt-mcp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let before = try overlayNames()

        XCTAssertThrowsError(
            try DevinIntegrationConfiguration.prepare(
                workingDirectory: sourceRoot.path,
                repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: executable.path),
                sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path]
            )
        )

        XCTAssertEqual(try overlayNames(), before)
    }

    private func overlayNames() throws -> Set<String> {
        try Set(
            FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            )
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("RepoPromptDevinACP-") }
        )
    }
}

private extension String {
    var asFileURL: URL {
        URL(fileURLWithPath: self, isDirectory: true)
    }
}

private final class DevinPermissionFakeSecureStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true
    var plainValues: [String: String] = [:]

    func getPlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws -> String? {
        plainValues[account.identifier]
    }

    func savePlainValue(
        _ value: String,
        for account: SecureStorageAccount,
        accessMode _: KeychainAccessMode
    ) throws {
        plainValues[account.identifier] = value
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        plainValues.removeValue(forKey: account.identifier)
    }
}

private final class DevinPermissionFailingSecureStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true

    func getPlainValue(for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws -> String? {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func savePlainValue(_: String, for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func deletePlainValue(for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }
}

/// Minimal Devin provider double for controller-lifecycle tests (no launch resolution).
private struct ReuseKeyFakeDevinProvider: ACPAgentProvider {
    var providerID: ACPProviderID {
        .devin
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
