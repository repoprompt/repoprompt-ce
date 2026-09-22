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

    func testStoredRawValueParsingKeepsAbsenceDefaultAndFailsUnknownClosedToNormal() {
        XCTAssertEqual(Level.from(rawValue: nil), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: ""), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: "   "), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: "garbage"), .normal)
        // The pre-ship draft persisted this raw value; it must not resolve to a broader mode.
        XCTAssertEqual(Level.from(rawValue: "providerManaged"), .normal)
        XCTAssertEqual(Level.from(rawValue: "  fullApproval "), .fullApproval)
        for level in Level.allCases {
            XCTAssertEqual(Level.from(rawValue: level.rawValue), level)
        }
    }

    func testCLIPermissionModeRoundTripsAndIdentifiesUnsupportedModes() {
        XCTAssertEqual(Level.from(cliPermissionMode: "auto"), .normal)
        XCTAssertEqual(Level.from(cliPermissionMode: "accept-edits"), .acceptEdits)
        XCTAssertEqual(Level.from(cliPermissionMode: "smart"), .smart)
        XCTAssertEqual(Level.from(cliPermissionMode: "dangerous"), .fullApproval)
        XCTAssertEqual(Level.from(cliPermissionMode: nil), .providerDefault)
        XCTAssertTrue(Level.isRecognizedCLIPermissionMode(nil))
        XCTAssertTrue(Level.isRecognizedCLIPermissionMode("ACCEPT-EDITS"))
        XCTAssertFalse(Level.isRecognizedCLIPermissionMode("bogus"))
        // `autonomous` requires `--sandbox` and is deliberately not offered.
        XCTAssertFalse(Level.isRecognizedCLIPermissionMode("autonomous"))
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
    func testSecurePermissionReadFailureFailsClosedToNormal() throws {
        let secureStore = AgentPermissionSecureStore(
            secureStrings: DevinPermissionFailingSecureStringStore(),
            notificationCenter: NotificationCenter()
        )
        let (_, defaults) = try makeStore(securePermissions: secureStore)
        defaults.set(Level.fullApproval.rawValue, forKey: "devinPermissionLevel")

        XCTAssertEqual(
            DevinAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
            .normal
        )
        XCTAssertEqual(secureStore.diagnostic(for: .devin)?.kind, .keychainInteractionNotAllowed)
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

    func testLaunchRejectsAnUnrecognizedPermissionMode() throws {
        let (provider, directory) = try makeProvider()
        XCTAssertThrowsError(
            try provider.makeLaunchConfiguration(
                for: makeRequest(workspacePath: directory.path, launchPermissionMode: "bogus")
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported Devin permission mode"))
        }
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
        let overlayRoot = try XCTUnwrap(launch.environment["XDG_CONFIG_HOME"])
        let overlayMCP = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: URL(fileURLWithPath: overlayRoot)
                        .appendingPathComponent("devin/mcp_config.json")
                )
            ) as? [String: Any]
        )
        XCTAssertEqual((overlayMCP["mcpServers"] as? [String: Any])?.count, 0)
        let cleanupArtifact = try XCTUnwrap(launch.cleanupArtifact)
        DevinIntegrationConfiguration.cleanupReportingFailures(artifact: cleanupArtifact)
    }

    func testConcurrentProbeDoesNotInvalidateAResolvedBareCommandLaunch() async throws {
        let directory = try makeTestDirectory(name: "DevinConcurrentBareCommandLaunch")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\necho 'Run as an ACP server over stdio'\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let gate = DevinProbeEnvironmentGate(environment: ["PATH": directory.path])
        let resolver = DevinACPLaunchResolver(launchEnvironmentProvider: { _ in
            await gate.nextEnvironment()
        })
        let config = DevinAgentConfig(commandName: "devin", includeRepoPromptMCPServer: false)

        let initialSupport = try await resolver.probeSupport(for: config)
        XCTAssertEqual(initialSupport, .supported)
        let secondProbe = Task { try await resolver.probeSupport(for: config) }
        await gate.waitForSecondCall()
        let resolved = Result { try resolver.resolvedLaunch(for: config) }
        await gate.releaseSecondCall()
        let secondSupport = try await secondProbe.value
        XCTAssertEqual(secondSupport, .supported)

        XCTAssertEqual(
            try resolved.get().command,
            try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path).canonicalPath
        )
    }

    func testRoutineInfoStderrIsHiddenWhileActionableOutputRemainsVisible() throws {
        let (provider, _) = try makeProvider()

        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-14T09:52:20.134260Z  INFO chisel: elapsed_since_main_ms=4 logging initialized"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-14T09:52:20Z INFO chisel: logging initialized"
        ))
        XCTAssertTrue(provider.shouldEmitStderrLine("2026-09-14T09:52:20Z ERROR chisel: startup failed"))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-15T11:10:05.047288Z  WARN message_forest: MessageChain tree duplication: system prefix changed"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-17T09:10:27.520189Z  WARN windsurf_api_client::remote_config: remote config revalidation failed, keeping last-good value: error sending request for url (https://unleash.codeium.com/api/client/features): operation timed out"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-17T09:11:36Z WARN windsurf_api_client::remote_config: remote config revalidation failed, keeping last-good value: error decoding response body"
        ))
        XCTAssertTrue(provider.shouldEmitStderrLine("2026-09-14T09:52:20Z  WARN chisel: retrying"))
        XCTAssertTrue(provider.shouldEmitStderrLine("permission denied while reading config"))
    }

    func testOracleOneShotArgumentsUseSelectedModelAndPromptFile() {
        XCTAssertEqual(
            DevinCLIProvider.test_arguments(
                modelName: "claude-opus-4-6",
                promptFilePath: "/tmp/prompt.md"
            ),
            [
                "--model", "claude-opus-4-6",
                "--respect-workspace-trust", "false",
                "--permission-mode", "auto",
                "--prompt-file", "/tmp/prompt.md",
                "-p"
            ]
        )
    }

    func testOracleOneShotPromptRequestsOnePlainAnswerWithoutTools() {
        let prompt = DevinCLIProvider.test_promptText(from: AIMessage(
            systemPrompt: "Return Markdown.",
            userMessage: "Summarize this."
        ))

        XCTAssertTrue(prompt.contains("Return Markdown."))
        XCTAssertTrue(prompt.contains("Summarize this."))
        XCTAssertTrue(prompt.contains("Do not use any tools"))
    }

    func testOracleModelIdentityPreservesRawDevinModelID() {
        let model = AIModel.devinCustom(name: "anthropic/claude-opus-4.6")

        XCTAssertEqual(model.rawValue, "devin_custom_anthropic/claude-opus-4.6")
        XCTAssertEqual(model.modelName, "anthropic/claude-opus-4.6")
        XCTAssertEqual(model.providerType, .devin)
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
    }

    func testDevinPickersExposeOnlyAdvertisedModels() {
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
        addTeardownBlock { AgentACPModelRegistry.shared.test_reset(providerID: .devin) }
        let availability = AgentModelCatalog.AvailabilityContext(devinAvailable: true)

        XCTAssertTrue(AgentModelCatalog.options(for: .devin, availability: availability).isEmpty)
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "default", for: .devin, availability: availability))

        let options = [
            AgentModelOption(rawValue: "swe-2-high", displayName: "SWE-2 High", description: nil, isDefault: true),
            AgentModelOption(rawValue: "gpt-5-6-sol-medium", displayName: "GPT-5.6 Sol Medium Thinking", description: nil, isDefault: false)
        ]
        AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(options: options, currentModelRaw: "swe-2-high"),
            for: .devin
        )

        XCTAssertEqual(Set(AgentModelCatalog.options(for: .devin, availability: availability)), Set(options))
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .devin, availability: availability), "swe-2-high")
        XCTAssertEqual(Set(ACPAIModelCatalog.devinModelsFromStore().map(\.modelName)), Set(options.map(\.rawValue)))
        XCTAssertFalse(ACPAIModelCatalog.devinModelsFromStore().contains(.devinCustom(name: "default")))
    }

    func testHeadlessMCPRunPinsAutoWhileOracleKeepsProviderDefault() {
        let message = AgentMessage(systemPrompt: "system", userMessage: "prompt")
        let headless = DevinACPHeadlessAgentProvider.makeRunRequest(
            config: DevinAgentConfig(includeRepoPromptMCPServer: true),
            workspacePath: "/tmp/workspace",
            message: message
        )
        let oracle = DevinACPHeadlessAgentProvider.makeRunRequest(
            config: DevinAgentConfig(includeRepoPromptMCPServer: false),
            workspacePath: nil,
            message: message
        )

        XCTAssertEqual(headless.launchPermissionMode, "auto")
        XCTAssertNil(oracle.launchPermissionMode)
        XCTAssertTrue(AgentModelCatalog.AgentSelectionSurface.headless.allows(.devin))
        XCTAssertTrue(
            AgentRuntimeProviderService.shared.makeProvider(
                for: .devin,
                modelString: "swe-2-high",
                workspacePath: "/tmp/workspace"
            ) is DevinACPHeadlessAgentProvider
        )
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
        XCTAssertFalse(
            unrecognizedMode,
            "an unrecognized Devin permission carrier must not reuse a Provider Default process"
        )
        XCTAssertTrue(changedModel, "Devin model switching stays live; it must not recycle the controller")

        await controller.shutdown()
    }

    func testCancelledDiscoveryDoesNotCacheFailure() async throws {
        final class RunCounter: @unchecked Sendable {
            var value = 0
        }
        let runs = RunCounter()
        let service = DevinModelDiscoveryService(
            isInstalled: { true },
            runSession: { _ in
                runs.value += 1
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        )

        let first = Task { await service.discoverIfNeeded() }
        try await Task.sleep(for: .milliseconds(80))
        first.cancel()
        _ = await first.value

        let second = Task { await service.discoverIfNeeded() }
        try await Task.sleep(for: .milliseconds(80))
        second.cancel()
        _ = await second.value

        XCTAssertEqual(runs.value, 2)
    }

    func testFailedDiscoveryDoesNotCacheFailure() async {
        final class RunCounter: @unchecked Sendable {
            var value = 0
        }
        let runs = RunCounter()
        let service = DevinModelDiscoveryService(
            isInstalled: { true },
            runSession: { _ in
                runs.value += 1
                throw AIProviderError.invalidConfiguration(detail: "transient")
            }
        )

        let first = await service.discoverIfNeeded()
        let second = await service.discoverIfNeeded()

        guard case .failed = first, case .failed = second else {
            return XCTFail("expected uncached failures, got \(first) then \(second)")
        }
        XCTAssertEqual(runs.value, 2)
    }

    func testStaleDiscoveryCancelDoesNotCancelALaterAttempt() async {
        final class RunCounter: @unchecked Sendable {
            var value = 0
        }
        let runs = RunCounter()
        let firstStarted = expectation(description: "first discovery started")
        let service = DevinModelDiscoveryService(
            isInstalled: { true },
            runSession: { _ in
                runs.value += 1
                if runs.value == 1 {
                    firstStarted.fulfill()
                    try await Task.sleep(for: .seconds(30))
                    return 1
                }
                return 2
            }
        )

        let first = Task { await service.discoverIfNeeded() }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        _ = await first.value

        let second = await service.discoverIfNeeded()
        XCTAssertEqual(second, .discovered(modelCount: 2))
        XCTAssertEqual(runs.value, 2)
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

private actor DevinProbeEnvironmentGate {
    private let environment: [String: String]
    private var callCount = 0
    private var secondCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseSecondCallContinuation: CheckedContinuation<Void, Never>?

    init(environment: [String: String]) {
        self.environment = environment
    }

    func nextEnvironment() async -> ACPLaunchEnvironment {
        callCount += 1
        if callCount == 2 {
            let waiters = secondCallWaiters
            secondCallWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseSecondCallContinuation = continuation
            }
        }
        return ACPLaunchEnvironment(environment: environment)
    }

    func waitForSecondCall() async {
        guard callCount < 2 else { return }
        await withCheckedContinuation { continuation in
            secondCallWaiters.append(continuation)
        }
    }

    func releaseSecondCall() {
        releaseSecondCallContinuation?.resume()
        releaseSecondCallContinuation = nil
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
        let existing = try XCTUnwrap(mergedServers["Existing"] as? [String: Any])
        XCTAssertEqual((existing["env"] as? [String: String])?["XDG_CONFIG_HOME"], sourceRoot.path)

        let replacedConfig = overlayDevin.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: replacedConfig)
        try "updated config".write(to: replacedConfig, atomically: true, encoding: .utf8)
        try "new state".write(
            to: overlayDevin.appendingPathComponent("new-state.json"),
            atomically: true,
            encoding: .utf8
        )

        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)

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

    func testCleanupPreservesNewerNativeConfigAndRetainsRecoveryOverlay() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationConcurrentNativeWrite")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        let nativeConfig = devinSource.appendingPathComponent("config.json")
        try "original".write(to: nativeConfig, atomically: true, encoding: .utf8)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            mcpServers: .disableAll,
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayConfig = overlayRoot
            .appendingPathComponent("devin", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: overlayConfig)
        try "overlay update".write(to: overlayConfig, atomically: true, encoding: .utf8)
        try "newer native update".write(to: nativeConfig, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery data remains at \(overlayRoot.path)"))
        }
        XCTAssertEqual(try String(contentsOf: nativeConfig, encoding: .utf8), "newer native update")
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot.path))
        try? FileManager.default.removeItem(at: overlayRoot)
    }

    func testCleanupRestoresNativeConfigWhenItChangesDuringPublication() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationPublicationRace")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        let nativeConfig = devinSource.appendingPathComponent("config.json")
        try "original".write(to: nativeConfig, atomically: true, encoding: .utf8)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            mcpServers: .disableAll,
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayConfig = overlayRoot
            .appendingPathComponent("devin", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: overlayConfig)
        try "overlay update".write(to: overlayConfig, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DevinIntegrationConfiguration.cleanup(
            artifact: prepared.cleanupArtifact,
            beforeReplacing: { sourceEntry in
                try "newer native update".write(to: sourceEntry, atomically: true, encoding: .utf8)
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery data remains at \(overlayRoot.path)"))
        }
        XCTAssertEqual(try String(contentsOf: nativeConfig, encoding: .utf8), "newer native update")
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot.path))
        try? FileManager.default.removeItem(at: overlayRoot)
    }

    func testOverlayRestoresNativeXDGForCommandOnlyStdioEntries() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationCommandOnlyStdio")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        let executable = sourceRoot.appendingPathComponent("repoprompt-mcp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try JSONSerialization.data(withJSONObject: [
            "mcpServers": [
                "CommandOnly": ["command": "existing", "args": []],
                "HTTP": ["url": "https://example.invalid"]
            ]
        ]).write(to: devinSource.appendingPathComponent("mcp_config.json"))

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: executable.path),
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayMCP = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: overlayRoot
                        .appendingPathComponent("devin")
                        .appendingPathComponent("mcp_config.json")
                )
            ) as? [String: Any]
        )
        let servers = try XCTUnwrap(overlayMCP["mcpServers"] as? [String: Any])
        let commandOnly = try XCTUnwrap(servers["CommandOnly"] as? [String: Any])
        XCTAssertEqual((commandOnly["env"] as? [String: String])?["XDG_CONFIG_HOME"], sourceRoot.path)
        let http = try XCTUnwrap(servers["HTTP"] as? [String: Any])
        XCTAssertNil(http["env"])

        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)
    }

    func testCleanupRejectsPermissionOnlyNativeChange() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationPermissionOnlyNativeWrite")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        let nativeConfig = devinSource.appendingPathComponent("config.json")
        try "original".write(to: nativeConfig, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nativeConfig.path)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            mcpServers: .disableAll,
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayConfig = overlayRoot
            .appendingPathComponent("devin", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: overlayConfig)
        try "overlay update".write(to: overlayConfig, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DevinIntegrationConfiguration.cleanup(
            artifact: prepared.cleanupArtifact,
            beforeReplacing: { sourceEntry in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: sourceEntry.path
                )
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery data remains at \(overlayRoot.path)"))
        }
        XCTAssertEqual(try String(contentsOf: nativeConfig, encoding: .utf8), "original")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: nativeConfig.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.uint16Value, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot.path))
        try? FileManager.default.removeItem(at: overlayRoot)
    }

    func testDisableAllMCPOverlayPreservesConfigWithoutNativeServers() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationNoMCP")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        try "native config".write(
            to: devinSource.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        let sourceMCP: [String: Any] = [
            "mcpServers": ["Existing": ["transport": "stdio", "command": "existing"]]
        ]
        let sourceMCPURL = devinSource.appendingPathComponent("mcp_config.json")
        try JSONSerialization.data(withJSONObject: sourceMCP).write(to: sourceMCPURL)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            mcpServers: .disableAll,
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayDevin = overlayRoot.appendingPathComponent("devin", isDirectory: true)
        let overlayMCP = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: overlayDevin.appendingPathComponent("mcp_config.json"))
            ) as? [String: Any]
        )

        XCTAssertEqual((overlayMCP["mcpServers"] as? [String: Any])?.count, 0)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: overlayDevin.appendingPathComponent("config.json").path
        ))

        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)
        XCTAssertEqual(
            try Data(contentsOf: sourceMCPURL),
            try JSONSerialization.data(withJSONObject: sourceMCP)
        )
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

    func testCleanupFailureKeepsRecoveryOverlayAndReportsItsPath() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationCleanupFailure")
        let executable = sourceRoot.appendingPathComponent("repoprompt-mcp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: executable.path),
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        try FileManager.default.removeItem(
            at: overlayRoot.appendingPathComponent(".repoprompt-source-devin-path")
        )

        XCTAssertThrowsError(try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery data remains at \(overlayRoot.path)"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot.path))
        try? FileManager.default.removeItem(at: overlayRoot)
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
