import Foundation
@_spi(TestSupport) @testable import RepoPrompt
import XCTest

final class ACPAgentSessionControllerModeConfigTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testSessionOpenRoutesInjectMCPAndUseModernModeConfiguration() async throws {
        let cases = [
            SessionOpenRouteCase(
                label: "new",
                shape: "custom_id",
                resumeSessionID: nil,
                expectedRoute: "session/new",
                oppositeRoute: "session/load",
                requestedMode: "PLAN",
                expectedConfigID: "permission_mode"
            ),
            SessionOpenRouteCase(
                label: "load",
                shape: "modern",
                resumeSessionID: "loaded-session",
                expectedRoute: "session/load",
                oppositeRoute: "session/new",
                requestedMode: "plan",
                expectedConfigID: "mode"
            )
        ]

        for route in cases {
            let fixture = try makeFixture(
                shape: route.shape,
                resumeSessionID: route.resumeSessionID,
                mcpServers: [makeFixtureMCPServer()]
            )
            try await withBootstrappedController(fixture.controller) { controller in
                try await controller.setSessionMode(route.requestedMode)
            }

            let routeRequests = recordedRequests(at: fixture.recordURL, method: route.expectedRoute)
            XCTAssertEqual(routeRequests.count, 1, route.label)
            XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: route.oppositeRoute).count, 0, route.label)
            try assertFixtureMCPServer(in: XCTUnwrap(routeRequests.first), label: route.label)

            let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
            let mutation = try XCTUnwrap(mutations.first, route.label)
            XCTAssertEqual(mutations.count, 1, route.label)
            XCTAssertEqual(mutation.params["configId"] as? String, route.expectedConfigID, route.label)
            XCTAssertEqual(mutation.params["value"] as? String, "plan", route.label)
        }
    }

    func testModeAdvertisementPrefersModernAndRejectsLegacyOnlyMetadata() async throws {
        do {
            let fixture = try makeFixture(shape: "dual")
            try await withBootstrappedController(fixture.controller) { controller in
                try await controller.setSessionMode("plan")
            }

            let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
            let mutation = try XCTUnwrap(mutations.first, "dual")
            XCTAssertEqual(mutations.count, 1, "dual")
            XCTAssertEqual(mutation.params["value"] as? String, "plan", "dual")
        }

        do {
            let diagnostics = LockedStrings()
            let fixture = try makeFixture(shape: "legacy", diagnostics: diagnostics)
            try await withBootstrappedController(fixture.controller) { controller in
                await assertThrows(
                    containing: "does not advertise a modern session mode configOptions selector",
                    label: "legacy-only"
                ) {
                    try await controller.setSessionMode("plan")
                }
            }

            XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, "legacy-only")
            XCTAssertTrue(
                diagnostics.values.contains { $0.contains("Ignoring legacy ACP modes metadata") },
                "legacy-only"
            )
        }
    }

    func testAbsentModernModeAllowsImplicitDefaultButRejectsExplicitMode() async throws {
        let fixture = try makeFixture(shape: "none")
        try await withBootstrappedController(fixture.controller) { controller in
            try await controller.setSessionMode("default")
            XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, "implicit default")
            await assertThrows(
                containing: "does not advertise a modern session mode configOptions selector",
                label: "explicit plan"
            ) {
                try await controller.setSessionMode("plan")
            }
            XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, "explicit plan")
        }
    }

    func testInvalidModernModeSelectorShapesFailWithoutMutation() async throws {
        let cases = [
            ModeSelectorFailureCase(
                label: "malformed",
                shape: "malformed",
                requestedValues: ["plan", "default"],
                expectedError: "malformed modern session mode config option",
                expectedDiagnostic: "malformed modern mode config option"
            ),
            ModeSelectorFailureCase(
                label: "duplicate",
                shape: "duplicate_mode",
                requestedValues: ["plan"],
                expectedError: "multiple mode config options",
                expectedDiagnostic: nil
            ),
            ModeSelectorFailureCase(
                label: "conflicting",
                shape: "conflicting_mode",
                requestedValues: ["plan"],
                expectedError: "conflicting id/category semantics",
                expectedDiagnostic: nil
            )
        ]

        for selectorCase in cases {
            let diagnostics = LockedStrings()
            let fixture = try makeFixture(shape: selectorCase.shape, diagnostics: diagnostics)
            try await withBootstrappedController(fixture.controller) { controller in
                for value in selectorCase.requestedValues {
                    let label = "\(selectorCase.label):\(value)"
                    await assertThrows(containing: selectorCase.expectedError, label: label) {
                        try await controller.setSessionMode(value)
                    }
                    XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, label)
                }
            }
            if let expectedDiagnostic = selectorCase.expectedDiagnostic {
                XCTAssertTrue(
                    diagnostics.values.contains { $0.contains(expectedDiagnostic) },
                    selectorCase.label
                )
            }
        }
    }

    func testModeCanonicalizationHandlesGroupedAndCaseCollidingChoices() async throws {
        do {
            let fixture = try makeFixture(shape: "grouped")
            try await withBootstrappedController(fixture.controller) { controller in
                try await controller.setSessionMode("PLAN")
            }

            let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
            let mutation = try XCTUnwrap(mutations.first, "grouped")
            XCTAssertEqual(mutations.count, 1, "grouped")
            XCTAssertEqual(mutation.params["value"] as? String, "Plan", "grouped")
        }

        do {
            let fixture = try makeFixture(shape: "case_collision")
            try await withBootstrappedController(fixture.controller) { controller in
                await assertThrows(containing: "case-colliding", label: "case-collision ambiguous") {
                    try await controller.setSessionMode("PLAN")
                }
                XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, "case-collision ambiguous")
                try await controller.setSessionMode("plan")
            }

            let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
            let mutation = try XCTUnwrap(mutations.first, "case-collision exact")
            XCTAssertEqual(mutations.count, 1, "case-collision exact")
            XCTAssertEqual(mutation.params["value"] as? String, "plan", "case-collision exact")
        }
    }

    func testModernModeValidationListsChoicesAndDeduplicatesConfirmedMutation() async throws {
        let fixture = try makeFixture(shape: "modern")
        try await withBootstrappedController(fixture.controller) { controller in
            await assertThrows(containing: "Available modes: ask, plan", label: "invalid choice") {
                try await controller.setSessionMode("unknown")
            }
            XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, "invalid choice")
            try await controller.setSessionMode("plan")
            try await controller.setSessionMode("plan")
        }

        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
        let mutation = try XCTUnwrap(mutations.first)
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutation.params["value"] as? String, "plan")
    }

    func testModernMutationRequiresCompleteMatchingResponseAndNeverRetriesLegacy() async throws {
        for behavior in ["empty", "missing_mode", "mismatch", "malformed"] {
            let fixture = try makeFixture(
                shape: "dual",
                extraEnvironment: ["ACP_SET_RESPONSE": behavior]
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "session/set_config_option response") {
                try await fixture.controller.setSessionMode("plan")
            }
            await fixture.controller.shutdown()

            XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: "session/set_config_option").count, 1, behavior)
        }
    }

    func testAuthoritativeConfigUpdateSurvivesTurnReuseAndSkipsConfirmedValue() async throws {
        let diagnostics = LockedStrings()
        let normalizedUpdates = LockedStrings()
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: ["ACP_NOTIFICATION_MODE": "plan"],
            diagnostics: diagnostics,
            normalizedUpdates: normalizedUpdates
        )
        _ = try await fixture.controller.bootstrap()
        try await waitUntil("authoritative config update") {
            diagnostics.values.contains("Processed authoritative config_option_update snapshot.")
        }

        try await fixture.controller.setSessionMode("plan")
        XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, "before turn reuse")
        let didPrepare = await fixture.controller.prepareForNextTurn()
        XCTAssertTrue(didPrepare)
        try await fixture.controller.setSessionMode("plan")
        XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, "after turn reuse")
        try await fixture.controller.setSessionMode("ask")
        await fixture.controller.shutdown()

        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
        let mutation = try XCTUnwrap(mutations.first)
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutation.params["value"] as? String, "ask")
        XCTAssertFalse(normalizedUpdates.values.contains("config_option_update"))
    }

    func testNonAuthoritativeConfigUpdatesAreIgnored() async throws {
        let cases = [
            IgnoredConfigUpdateCase(
                label: "missing-payload",
                environment: [
                    "ACP_NOTIFICATION_MODE": "plan",
                    "ACP_NOTIFICATION_BEHAVIOR": "missing"
                ],
                expectedDiagnostic: "config_option_update"
            ),
            IgnoredConfigUpdateCase(
                label: "wrong-session",
                environment: [
                    "ACP_NOTIFICATION_MODE": "plan",
                    "ACP_NOTIFICATION_SESSION_ID": "other-session"
                ],
                expectedDiagnostic: nil
            )
        ]

        for updateCase in cases {
            let diagnostics = LockedStrings()
            let fixture = try makeFixture(
                shape: "modern",
                extraEnvironment: updateCase.environment,
                diagnostics: diagnostics
            )
            try await withBootstrappedController(fixture.controller) { controller in
                if let expectedDiagnostic = updateCase.expectedDiagnostic {
                    try await waitUntil("\(updateCase.label) config update rejection") {
                        diagnostics.values.contains {
                            $0.contains("Ignoring") && $0.contains(expectedDiagnostic)
                        }
                    }
                }
                try await controller.setSessionMode("plan")
            }

            let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
            XCTAssertEqual(mutations.count, 1, updateCase.label)
            XCTAssertEqual(mutations.first?.params["value"] as? String, "plan", updateCase.label)
            if let expectedDiagnostic = updateCase.expectedDiagnostic {
                XCTAssertTrue(
                    diagnostics.values.contains { $0.contains("Ignoring") && $0.contains(expectedDiagnostic) },
                    updateCase.label
                )
            }
        }
    }

    func testMalformedConfigUpdatesInvalidateModeAuthorityBeforeAndAfterMutation() async throws {
        for phase in MalformedAuthorityPhase.allCases {
            let diagnostics = LockedStrings()
            var environment = [
                "ACP_NOTIFICATION_MODE": "plan",
                "ACP_NOTIFICATION_BEHAVIOR": "malformed"
            ]
            if phase == .afterMutation {
                environment = [
                    "ACP_AFTER_SET_NOTIFICATION_MODE": "ask",
                    "ACP_AFTER_SET_NOTIFICATION_BEHAVIOR": "malformed",
                    "ACP_AFTER_SET_NOTIFICATION_DELAY": "0.05"
                ]
            }
            let fixture = try makeFixture(
                shape: "modern",
                extraEnvironment: environment,
                diagnostics: diagnostics
            )
            _ = try await fixture.controller.bootstrap()

            if phase == .afterMutation {
                try await fixture.controller.setSessionMode("plan")
            }
            try await waitUntil("\(phase.label) malformed config update invalidation") {
                diagnostics.values.contains { $0.contains("Invalidated session mode authority") }
            }
            await assertThrows(
                containing: "malformed modern session mode config option",
                label: phase.label
            ) {
                try await fixture.controller.setSessionMode(phase == .beforeMutation ? "ask" : "plan")
            }
            await fixture.controller.shutdown()

            let mutations = recordedMutationRequests(at: fixture.recordURL)
            XCTAssertEqual(mutations.count, phase == .beforeMutation ? 0 : 1, phase.label)
            if phase == .afterMutation {
                XCTAssertEqual(mutations.first?.params["value"] as? String, "plan", phase.label)
            }
            XCTAssertTrue(
                diagnostics.values.contains { $0.contains("Invalidated session mode authority") },
                phase.label
            )
        }
    }

    func testNewerNotificationRemainsAuthoritativeAfterMutationResponse() async throws {
        let diagnostics = LockedStrings()
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: [
                "ACP_AFTER_SET_NOTIFICATION_MODE": "ask",
                "ACP_AFTER_SET_NOTIFICATION_DELAY": "0.05"
            ],
            diagnostics: diagnostics
        )
        _ = try await fixture.controller.bootstrap()
        try await fixture.controller.setSessionMode("plan")
        try await waitUntil("authoritative config update") {
            diagnostics.values.contains("Processed authoritative config_option_update snapshot.")
        }
        try await fixture.controller.setSessionMode("ask")
        await fixture.controller.shutdown()

        XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: "session/set_config_option").count, 1)
    }

    func testNewerCaseDistinctModeNotificationInvalidatesExactConfirmedMode() async throws {
        #if DEBUG
            let diagnostics = LockedStrings()
            let fixture = try makeFixture(
                shape: "case_collision",
                extraEnvironment: ["ACP_AFTER_SET_NOTIFICATION_MODE": "plan"],
                diagnostics: diagnostics
            )
            _ = try await fixture.controller.bootstrap()
            await fixture.controller.debugSuspendNextConfigurationMutationPostcheck()
            addTeardownBlock {
                await fixture.controller.debugResumeConfigurationMutationPostcheck()
            }

            let mutation = Task {
                try await fixture.controller.setSessionMode("Plan")
            }
            try await waitUntilAsync("configuration mutation postcheck suspension") {
                await fixture.controller.debugIsConfigurationMutationPostcheckSuspended()
            }
            try await waitUntil("newer authoritative config update") {
                diagnostics.values.contains("Processed authoritative config_option_update snapshot.")
            }
            await fixture.controller.debugResumeConfigurationMutationPostcheck()

            await assertThrows(containing: "newer ACP configuration state no longer confirms requested mode 'Plan'") {
                try await mutation.value
            }
            await fixture.controller.shutdown()
            XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: "session/set_config_option").count, 1)
        #else
            throw XCTSkip("Configuration mutation suspension is DEBUG-only.")
        #endif
    }

    func testModernModelSelectorOverridesConflictingLegacyModels() async throws {
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: [
                "ACP_INCLUDE_MODEL": "1",
                "ACP_MODEL_CONFIG_ID": "model_selector",
                "ACP_INCLUDE_LEGACY_MODELS": "1"
            ]
        )
        try await withBootstrappedController(fixture.controller) { controller in
            try await controller.setSessionModel("model-b")
        }

        let mutation = try XCTUnwrap(recordedRequests(at: fixture.recordURL, method: "session/set_config_option").first)
        XCTAssertEqual(mutation.params["configId"] as? String, "model_selector")
        XCTAssertEqual(mutation.params["value"] as? String, "model-b")
    }

    func testCursorAutoWithoutModernModelSelectorUsesProviderDefault() async throws {
        let fixture = try makeFixture(shape: "none", providerID: .cursor)

        try await withBootstrappedController(fixture.controller) { controller in
            try await controller.setSessionModel(AgentModel.cursorAuto.rawValue)
        }

        XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty)
    }

    func testMalformedModernModelRejectsCursorDefaultAndLegacyFallbackWithoutMutation() async throws {
        let diagnostics = LockedStrings()
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: [
                "ACP_INCLUDE_MODEL": "1",
                "ACP_MALFORMED_MODEL": "1",
                "ACP_INCLUDE_LEGACY_MODELS": "1"
            ],
            diagnostics: diagnostics,
            providerID: .cursor
        )
        try await withBootstrappedController(fixture.controller) { controller in
            for requestedModel in [AgentModel.cursorAuto.rawValue, "legacy-model"] {
                await assertThrows(
                    containing: "malformed modern model config option",
                    label: requestedModel
                ) {
                    try await controller.setSessionModel(requestedModel)
                }
                XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty, requestedModel)
            }
        }

        XCTAssertTrue(diagnostics.values.contains { $0.contains("legacy fallback is disabled") })
    }

    func testLegacyOnlyModelAdvertisementIsIgnored() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        }
        let diagnostics = LockedStrings()
        let fixture = try makeFixture(
            shape: "none",
            extraEnvironment: ["ACP_INCLUDE_LEGACY_MODELS": "1"],
            diagnostics: diagnostics
        )

        try await withBootstrappedController(fixture.controller) { controller in
            XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: .openCode))
            await assertThrows(containing: "does not advertise model switching through configOptions") {
                try await controller.setSessionModel("legacy-model")
            }
        }

        XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty)
        XCTAssertTrue(diagnostics.values.contains { $0.contains("Ignoring legacy ACP models metadata") })
    }

    func testModelCanonicalizationRejectsAmbiguityAndRequiresExactResponse() async throws {
        do {
            let fixture = try makeFixture(
                shape: "modern",
                extraEnvironment: [
                    "ACP_INCLUDE_MODEL": "1",
                    "ACP_MODEL_CASE_COLLISION": "1"
                ]
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "case-colliding models") {
                try await fixture.controller.setSessionModel("FOO")
            }
            await fixture.controller.shutdown()
            XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty)
        }

        do {
            let fixture = try makeFixture(
                shape: "modern",
                extraEnvironment: [
                    "ACP_INCLUDE_MODEL": "1",
                    "ACP_MODEL_CASE_COLLISION": "1",
                    "ACP_MODEL_RESPONSE_MISMATCH": "1"
                ]
            )
            _ = try await fixture.controller.bootstrap()
            await assertThrows(containing: "did not confirm requested model 'foo'") {
                try await fixture.controller.setSessionModel("foo")
            }
            await fixture.controller.shutdown()

            let mutation = try XCTUnwrap(recordedRequests(at: fixture.recordURL, method: "session/set_config_option").first)
            XCTAssertEqual(mutation.params["value"] as? String, "foo")
        }
    }

    func testModelAndModeMutationsAreSerializedAndModeRunsLast() async throws {
        let releaseURL = try makeTemporaryDirectory().appendingPathComponent("release-model")
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: [
                "ACP_INCLUDE_MODEL": "1",
                "ACP_MODEL_RELEASE_PATH": releaseURL.path,
                "ACP_MODEL_CHANGES_MODE_CONFIG_ID": "1"
            ],
            modelString: "model-b"
        )
        _ = try await fixture.controller.bootstrap()

        let modelTask = Task { try await fixture.controller.setSessionModel("model-b") }
        try await waitUntil("model mutation request") {
            self.recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
                .contains { $0.params["configId"] as? String == "model" }
        }
        let modeTask = Task { try await fixture.controller.setSessionMode("plan") }
        try Data().write(to: releaseURL)
        try await modelTask.value
        try await modeTask.value
        await fixture.controller.shutdown()

        let mutations = recordedRequests(at: fixture.recordURL, method: "session/set_config_option")
        XCTAssertEqual(mutations.compactMap { $0.params["configId"] as? String }, ["model", "mode_after_model"])
    }

    func testLoadFallbackToNewSessionDoesNotLeakModeConfiguration() async throws {
        let fixture = try makeFixture(
            shape: "none",
            resumeSessionID: "missing-session",
            extraEnvironment: ["ACP_FAIL_LOAD": "1"]
        )
        _ = try await fixture.controller.bootstrap()
        await assertThrows(containing: "does not advertise a modern session mode configOptions selector") {
            try await fixture.controller.setSessionMode("plan")
        }
        await fixture.controller.shutdown()

        XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: "session/load").count, 1)
        XCTAssertEqual(recordedRequests(at: fixture.recordURL, method: "session/new").count, 1)
        XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty)
    }

    func testShutdownClearsSessionConfigurationAndRejectsFurtherMutation() async throws {
        let fixture = try makeFixture(shape: "modern")
        _ = try await fixture.controller.bootstrap()
        await fixture.controller.shutdown()
        await assertThrows(containing: "expected sessionOpen or promptRunning") {
            try await fixture.controller.setSessionMode("plan")
        }
        XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty)
    }

    func testHeadlessProvidersApplyModelBeforeMode() async throws {
        do {
            let workspace = try makeTemporaryDirectory()
            let scriptURL = try makeFakeACPServerScript()
            let recordURL = workspace.appendingPathComponent("opencode-headless.jsonl")
            let fakeProvider = ModeConfigFakeACPProvider(
                commandPath: scriptURL.path,
                launchArguments: [],
                environment: ["ACP_RECORD_PATH": recordURL.path, "ACP_SHAPE": "headless", "ACP_INCLUDE_MODEL": "1"],
                mcpServers: []
            )
            let provider = OpenCodeACPHeadlessAgentProvider(
                config: OpenCodeAgentConfig(
                    modelString: "model-b",
                    includeRepoPromptMCPServer: false,
                    includeManagedConfigOverlay: false,
                    cleanupLegacyPersistentConfig: false,
                    toolProfile: .headless
                ),
                workspacePath: workspace.path,
                providerFactory: { _ in fakeProvider }
            )
            try await drain(provider.streamAgentMessage(AgentMessage(userMessage: "OpenCode headless")))
            await provider.dispose()

            let relevant = recordedRequests(at: recordURL).filter {
                $0.method == "session/set_config_option" || $0.method == "session/prompt"
            }
            XCTAssertEqual(relevant.map(\.method), ["session/set_config_option", "session/set_config_option", "session/prompt"])
            let modelMutation = try XCTUnwrap(relevant.first)
            let modeMutation = try XCTUnwrap(relevant.dropFirst().first)
            XCTAssertEqual(modelMutation.params["configId"] as? String, "model")
            XCTAssertEqual(modeMutation.params["configId"] as? String, "mode")
            XCTAssertEqual(modeMutation.params["value"] as? String, OpenCodeAgentConfig.managedHeadlessSessionModeID)
        }

        do {
            let workspace = try makeTemporaryDirectory()
            let scriptURL = try makeFakeACPServerScript()
            let recordURL = workspace.appendingPathComponent("cursor-headless.jsonl")
            let fakeProvider = ModeConfigFakeACPProvider(
                commandPath: scriptURL.path,
                launchArguments: [],
                environment: ["ACP_RECORD_PATH": recordURL.path, "ACP_SHAPE": "headless", "ACP_INCLUDE_MODEL": "1"],
                mcpServers: [],
                providerID: .cursor
            )
            let provider = CursorACPHeadlessAgentProvider(
                config: CursorAgentConfig(
                    modelString: "model-b",
                    includeRepoPromptMCPServer: false,
                    cleanupProjectMCPApproval: false,
                    sessionModeID: CursorAgentConfig.promptOnlySessionModeID
                ),
                workspacePath: workspace.path,
                providerFactory: { _ in fakeProvider }
            )
            try await drain(provider.streamAgentMessage(AgentMessage(userMessage: "Cursor headless")))
            await provider.dispose()

            let relevant = recordedRequests(at: recordURL).filter {
                $0.method == "session/set_config_option" || $0.method == "session/prompt"
            }
            XCTAssertEqual(relevant.map(\.method), ["session/set_config_option", "session/set_config_option", "session/prompt"])
            let modelMutation = try XCTUnwrap(relevant.first)
            let modeMutation = try XCTUnwrap(relevant.dropFirst().first)
            XCTAssertEqual(modelMutation.params["configId"] as? String, "model")
            XCTAssertEqual(modeMutation.params["configId"] as? String, "mode")
            XCTAssertEqual(modeMutation.params["value"] as? String, CursorAgentConfig.promptOnlySessionModeID)
        }
    }

    func testTransportTerminationDrainsPromptSettlementWaiters() async throws {
        #if DEBUG
            for termination in TransportTerminationKind.allCases {
                let releaseURL = try makeTemporaryDirectory().appendingPathComponent("exit-release")
                var environment = ["ACP_HANG_PROMPT": "1"]
                if termination == .processExit {
                    environment["ACP_EXIT_ON_CANCEL_RELEASE_PATH"] = releaseURL.path
                }
                let fixture = try makeFixture(
                    shape: "modern",
                    extraEnvironment: environment
                )
                _ = try await fixture.controller.bootstrap()
                let promptTask = Task {
                    try await fixture.controller.prompt(AgentMessage(userMessage: "hang"))
                }
                try await waitUntil("\(termination.label) prompt request") {
                    self.recordedRequests(at: fixture.recordURL, method: "session/prompt").count == 1
                }

                let interruptTask = Task {
                    try await fixture.controller.interruptActivePromptForSteering(timeoutSeconds: 30)
                }
                try await waitUntilAsync("\(termination.label) prompt settlement waiter") {
                    await fixture.controller.debugPromptSettlementWaiterCount() == 1
                }
                let waiterCount = await fixture.controller.debugPromptSettlementWaiterCount()
                XCTAssertEqual(waiterCount, 1, termination.label)

                switch termination {
                case .shutdown:
                    await fixture.controller.shutdown()
                case .processExit:
                    try Data().write(to: releaseURL)
                }

                await assertTransportClosed(interruptTask, label: "\(termination.label) steering interrupt")
                await assertTransportClosed(promptTask, label: "\(termination.label) prompt")
                if termination == .processExit {
                    await fixture.controller.shutdown()
                }
            }
        #else
            throw XCTSkip("Prompt settlement waiter inspection is DEBUG-only.")
        #endif
    }

    func testLaunchConfigurationDiagnosticsRedactSecretFlagsAndJSONFields() throws {
        #if DEBUG
            let launchConfiguration = ACPLaunchConfiguration(
                providerID: .openCode,
                command: "/bin/echo",
                arguments: [
                    "acp",
                    "--api-key",
                    "flag-secret",
                    "--password=inline-secret",
                    #"{"token":"json-token","nested":{"password":"json-password","apiKey":"json-key","key":"generic-json-key","label":"visible"}}"#
                ],
                environment: [:],
                workingDirectory: "/tmp",
                additionalPathHints: [],
                enableDebugLogging: false
            )

            let payload = ACPAgentSessionController.debugLaunchConfigurationTracePayloadForTesting(launchConfiguration)
            let arguments = try XCTUnwrap(payload["arguments"] as? [String])
            XCTAssertEqual(Array(arguments[0 ... 3]), ["acp", "--api-key", "<redacted>", "--password=<redacted>"])
            let jsonArgument = try XCTUnwrap(arguments.last)
            XCTAssertTrue(jsonArgument.contains(#""label":"visible""#))
            XCTAssertEqual(jsonArgument.components(separatedBy: "<redacted>").count - 1, 4)
            for secret in ["flag-secret", "inline-secret", "json-token", "json-password", "json-key", "generic-json-key"] {
                XCTAssertFalse(String(describing: payload).contains(secret), secret)
            }
        #else
            throw XCTSkip("Launch configuration diagnostics are DEBUG-only.")
        #endif
    }

    func testRawDebugCaptureRedactsNestedContentAndUsesOwnerOnlyPermissions() throws {
        #if DEBUG
            let directory = try makeTemporaryDirectory()
            let captureURL = directory.appendingPathComponent("raw-acp.jsonl")
            try Data().write(to: captureURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: captureURL.path)
            let payload: [String: Any] = [
                "method": "session/update",
                "safeLabel": "visible",
                "params": [
                    "token": "token-secret",
                    "nested": [
                        "password": "password-secret",
                        "text": "private prompt text",
                        "label": "nested-visible"
                    ],
                    "authorization": "Bearer header-secret"
                ]
            ]

            let sanitized = ACPAgentSessionController.debugSanitizedRawCapturePayloadForTesting(payload)
            let description = String(describing: sanitized)
            XCTAssertTrue(description.contains("visible"))
            for secret in ["token-secret", "password-secret", "private prompt text", "header-secret"] {
                XCTAssertFalse(description.contains(secret), secret)
            }

            ACPAgentSessionController.debugWriteRawACPEventForTesting(to: captureURL, payload: payload)
            let contents = try String(contentsOf: captureURL, encoding: .utf8)
            for secret in ["token-secret", "password-secret", "private prompt text", "header-secret"] {
                XCTAssertFalse(contents.contains(secret), secret)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: captureURL.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(permissions & 0o777, 0o600)
        #else
            throw XCTSkip("Raw ACP capture is DEBUG-only.")
        #endif
    }

    func testControllerPersistsRedactedRunCorrelatedLaunchContract() async throws {
        #if DEBUG
            let runID = UUID()
            await ServerNetworkManager.shared.debugClearRunRoutingHistoryForTesting()
            addTeardownBlock {
                await ServerNetworkManager.shared.debugClearRunRoutingHistoryForTesting()
            }
            let injectedServer = RepoPromptMCPServerConfiguration(
                name: "RepoPromptFixture",
                command: "/bin/echo",
                args: [
                    "API_TOKEN=helper-secret",
                    "--header",
                    "Authorization: Bearer helper-header-secret",
                    "tools"
                ]
            )
            let openCodeOverlay: [String: Any] = [
                "mcp": [
                    RepoPromptMCPServerConfiguration.defaultServerName: [
                        "enabled": true,
                        "command": ["/bin/echo", "--header", "Authorization: Bearer overlay-secret", "tools"]
                    ],
                    "UnrelatedServer": [
                        "enabled": true,
                        "command": ["/bin/echo", "UNRELATED_SECRET=do-not-record"]
                    ]
                ]
            ]
            let overlayData = try JSONSerialization.data(withJSONObject: openCodeOverlay)
            let overlayJSON = try XCTUnwrap(String(data: overlayData, encoding: .utf8))
            let fixture = try makeFixture(
                shape: "modern",
                extraEnvironment: ["OPENCODE_CONFIG_CONTENT": overlayJSON],
                launchArguments: [
                    "OPENAI_API_KEY=launch-secret",
                    "--header",
                    "Authorization: Bearer launch-header-secret",
                    "--prompt",
                    "private user prompt",
                    #"{"accessToken":"launch-json-token","nested":{"password":"launch-json-password","label":"visible"}}"#,
                    String(repeating: "x", count: 600)
                ],
                mcpServers: [injectedServer]
            )
            await fixture.controller.setExpectedMCPRunID(runID)
            try await withBootstrappedController(fixture.controller) { _ in }

            let payload = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(runID: runID, limit: 20)
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            let resolved = try XCTUnwrap(events.first { $0["event"] as? String == "acp_launch_contract_resolved" })
            let spawned = try XCTUnwrap(events.first { $0["event"] as? String == "acp_process_spawned" })
            let fields = try XCTUnwrap(resolved["fields"] as? [String: String])
            let spawnedFields = try XCTUnwrap(spawned["fields"] as? [String: String])

            XCTAssertEqual(fields["provider_id"], ACPProviderID.openCode.rawValue)
            XCTAssertEqual(fields["configured_command"], fixture.scriptURL.path)
            XCTAssertEqual(fields["resolved_executable"], fixture.scriptURL.path)
            XCTAssertTrue(fields["final_args"]?.contains("OPENAI_API_KEY=<redacted>") == true)
            XCTAssertTrue(fields["final_args"]?.contains("--header <redacted>") == true)
            XCTAssertTrue(fields["final_args"]?.contains("--prompt <redacted>") == true)
            XCTAssertLessThanOrEqual(fields["final_args"]?.count ?? .max, 481)
            XCTAssertTrue(fields["injected_mcp_command"]?.contains("API_TOKEN=<redacted>") == true)
            XCTAssertTrue(fields["injected_mcp_command"]?.contains("--header <redacted> tools") == true)
            XCTAssertTrue(fields["injected_mcp_command"]?.contains(RepoPromptMCPServerConfiguration.defaultServerName) == true)
            XCTAssertFalse(fields["injected_mcp_command"]?.contains("UnrelatedServer") == true)
            XCTAssertNotNil(Int(spawnedFields["acp_pid"] ?? ""))
            for secret in [
                "launch-secret",
                "launch-header-secret",
                "private user prompt",
                "launch-json-token",
                "launch-json-password",
                "helper-secret",
                "helper-header-secret",
                "overlay-secret",
                "do-not-record"
            ] {
                XCTAssertFalse(String(describing: events).contains(secret), secret)
            }
        #else
            throw XCTSkip("Run-correlated launch history is DEBUG-only.")
        #endif
    }

    private struct SessionOpenRouteCase {
        let label: String
        let shape: String
        let resumeSessionID: String?
        let expectedRoute: String
        let oppositeRoute: String
        let requestedMode: String
        let expectedConfigID: String
    }

    private struct ModeSelectorFailureCase {
        let label: String
        let shape: String
        let requestedValues: [String]
        let expectedError: String
        let expectedDiagnostic: String?
    }

    private struct IgnoredConfigUpdateCase {
        let label: String
        let environment: [String: String]
        let expectedDiagnostic: String?
    }

    private enum MalformedAuthorityPhase: CaseIterable {
        case beforeMutation
        case afterMutation

        var label: String {
            switch self {
            case .beforeMutation: "before-mutation"
            case .afterMutation: "after-mutation"
            }
        }
    }

    private enum TransportTerminationKind: CaseIterable {
        case shutdown
        case processExit

        var label: String {
            switch self {
            case .shutdown: "shutdown"
            case .processExit: "process-exit"
            }
        }
    }

    private struct Fixture {
        let controller: ACPAgentSessionController
        let recordURL: URL
        let scriptURL: URL
    }

    private struct RecordedRequest {
        let method: String
        let params: [String: Any]
    }

    private func makeFixtureMCPServer() -> RepoPromptMCPServerConfiguration {
        RepoPromptMCPServerConfiguration(
            name: "RepoPromptFixture",
            command: "/bin/echo",
            args: ["--window", "4"],
            env: [.init(name: "RPCE_TEST", value: "1")]
        )
    }

    private func assertFixtureMCPServer(in request: RecordedRequest, label: String) throws {
        let mcpServers = try XCTUnwrap(request.params["mcpServers"] as? [[String: Any]], label)
        let server = try XCTUnwrap(mcpServers.first, label)
        XCTAssertEqual(mcpServers.count, 1, label)
        XCTAssertEqual(server["type"] as? String, "stdio", label)
        XCTAssertEqual(server["name"] as? String, "RepoPromptFixture", label)
        XCTAssertEqual(server["command"] as? String, "/bin/echo", label)
        XCTAssertEqual(server["args"] as? [String], ["--window", "4"], label)
        let environment = try XCTUnwrap(server["env"] as? [[String: String]], label)
        XCTAssertEqual(environment, [["name": "RPCE_TEST", "value": "1"]], label)
    }

    private func makeFixture(
        shape: String,
        resumeSessionID: String? = nil,
        extraEnvironment: [String: String] = [:],
        modelString: String? = nil,
        launchArguments: [String] = [],
        mcpServers: [RepoPromptMCPServerConfiguration] = [],
        diagnostics: LockedStrings? = nil,
        normalizedUpdates: LockedStrings? = nil,
        providerID: ACPProviderID = .openCode
    ) throws -> Fixture {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try makeFakeACPServerScript()
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        var environment = extraEnvironment
        environment["ACP_RECORD_PATH"] = recordURL.path
        environment["ACP_SHAPE"] = shape
        let request = ACPRunRequest(
            agentKind: providerID == .cursor ? .cursor : .openCode,
            modelString: modelString,
            workspacePath: workspace.path,
            resumeSessionID: resumeSessionID,
            attachments: [],
            taskLabelKind: nil
        )
        let provider = ModeConfigFakeACPProvider(
            commandPath: scriptURL.path,
            launchArguments: launchArguments,
            environment: environment,
            mcpServers: mcpServers,
            providerID: providerID,
            normalizedUpdates: normalizedUpdates
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            diagnosticSink: { event in
                if case let .info(message) = event {
                    diagnostics?.append(message)
                }
            }
        )
        addTeardownBlock {
            await controller.shutdown()
        }
        return Fixture(controller: controller, recordURL: recordURL, scriptURL: scriptURL)
    }

    private func drain(_ stream: AsyncThrowingStream<AIStreamResult, Error>) async throws {
        for try await _ in stream {}
    }

    private func withBootstrappedController(
        _ controller: ACPAgentSessionController,
        operation: (ACPAgentSessionController) async throws -> Void
    ) async throws {
        do {
            _ = try await controller.bootstrap()
            try await operation(controller)
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private func assertThrows(
        containing expectedText: String,
        label: String? = nil,
        operation: () async throws -> Void
    ) async {
        let context = label.map { " [\($0)]" } ?? ""
        do {
            try await operation()
            XCTFail("Expected operation\(context) to throw an error containing: \(expectedText)")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(expectedText),
                "Expected '\(error.localizedDescription)'\(context) to contain '\(expectedText)'"
            )
        }
    }

    private func assertTransportClosed(_ task: Task<Void, Error>, label: String) async {
        do {
            try await task.value
            XCTFail("Expected \(label) to fail when the ACP transport closed")
        } catch {
            XCTAssertEqual(error.localizedDescription, "ACP transport closed unexpectedly.", label)
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func waitUntilAsync(
        _ description: String,
        timeout: TimeInterval = 3,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func recordedMutationRequests(at url: URL) -> [RecordedRequest] {
        recordedRequests(at: url).filter { request in
            request.method == "session/set_config_option"
        }
    }

    private func recordedRequests(at url: URL, method: String? = nil) -> [RecordedRequest] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recordedMethod = object["method"] as? String,
                  method == nil || method == recordedMethod
            else { return nil }
            return RecordedRequest(
                method: recordedMethod,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPAgentSessionControllerModeConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeFakeACPServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_mode_config_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys
        import threading
        import time

        record_path = os.environ.get("ACP_RECORD_PATH")
        shape = os.environ.get("ACP_SHAPE", "modern")
        session_id = os.environ.get("ACP_SESSION_ID", "mode-config-session")
        current_mode = "base" if shape == "headless" else "ask"
        current_model = "Foo" if os.environ.get("ACP_MODEL_CASE_COLLISION") == "1" else "model-a"
        mode_config_id = "permission_mode" if shape == "custom_id" else "mode"
        output_lock = threading.Lock()

        def record(method, params):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\n")

        def send(payload):
            with output_lock:
                print(json.dumps(payload), flush=True)

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result if result is not None else {}
            send(payload)

        def choices():
            if shape == "grouped":
                return [{"name": "Workflow", "options": [
                    {"value": "ask", "name": "Ask"},
                    {"value": "Plan", "name": "Plan"}
                ]}]
            if shape == "headless":
                return [
                    {"value": "base", "name": "Base"},
                    {"value": "ask", "name": "Ask"},
                    {"value": "repoprompt_headless", "name": "RepoPrompt Headless"}
                ]
            if shape == "case_collision":
                return [
                    {"value": "ask", "name": "Ask"},
                    {"value": "Plan", "name": "Plan Upper"},
                    {"value": "plan", "name": "Plan Lower"}
                ]
            return [
                {"value": "ask", "name": "Ask"},
                {"value": "plan", "name": "Plan"}
            ]

        def mode_option(value=None, malformed=False):
            option = {
                "id": mode_config_id,
                "name": "Session Mode",
                "category": "mode",
                "type": "text" if malformed else "select",
                "currentValue": value if value is not None else current_mode,
                "options": choices()
            }
            return option

        def model_option(value=None):
            model_choices = [
                {"value": "Foo", "name": "Foo Upper"},
                {"value": "foo", "name": "Foo Lower"}
            ] if os.environ.get("ACP_MODEL_CASE_COLLISION") == "1" else [
                {"value": "model-a", "name": "Model A"},
                {"value": "model-b", "name": "Model B"}
            ]
            return {
                "id": os.environ.get("ACP_MODEL_CONFIG_ID", "model"),
                "name": "Model",
                "category": "model",
                "type": "text" if os.environ.get("ACP_MALFORMED_MODEL") == "1" else "select",
                "currentValue": value if value is not None else current_model,
                "options": model_choices
            }

        def config_options(mode_value=None, include_mode=True, malformed_mode=False, model_value=None):
            result = []
            if os.environ.get("ACP_INCLUDE_MODEL") == "1":
                result.append(model_option(model_value))
            if include_mode:
                result.append(mode_option(mode_value, malformed_mode))
            return result

        def session_result(result_session_id):
            result = {"sessionId": result_session_id}
            if shape in ("modern", "custom_id", "grouped", "case_collision", "headless"):
                result["configOptions"] = config_options()
            elif shape == "duplicate_mode":
                result["configOptions"] = [mode_option(), mode_option()]
            elif shape == "conflicting_mode":
                conflicting = mode_option()
                conflicting["id"] = "mode"
                conflicting["category"] = "model"
                result["configOptions"] = [conflicting]
            elif shape == "dual":
                result["configOptions"] = config_options()
                result["modes"] = {
                    "currentModeId": "legacy-only",
                    "availableModes": [{"id": "legacy-only", "name": "Legacy Only"}]
                }
            elif shape == "legacy":
                result["modes"] = {
                    "currentModeId": current_mode,
                    "availableModes": [
                        {"id": "ask", "name": "Ask"},
                        {"id": "plan", "name": "Plan"}
                    ]
                }
            elif shape == "malformed":
                result["configOptions"] = config_options(malformed_mode=True)
                result["modes"] = {
                    "currentModeId": current_mode,
                    "availableModes": ["ask", "plan"]
                }
            if os.environ.get("ACP_INCLUDE_MODEL") == "1" and "configOptions" not in result:
                result["configOptions"] = [model_option()]
            if os.environ.get("ACP_INCLUDE_LEGACY_MODELS") == "1":
                result["models"] = {
                    "currentModelId": "legacy-model",
                    "availableModels": [{"modelId": "legacy-model", "name": "Legacy Model"}]
                }
            return result

        def notification_payload(mode, notify_session_id=None, behavior_override=None):
            update = {"sessionUpdate": "config_option_update"}
            behavior = behavior_override or os.environ.get("ACP_NOTIFICATION_BEHAVIOR", "valid")
            if behavior == "malformed":
                update["configOptions"] = config_options(mode_value=mode, malformed_mode=True)
            elif behavior != "missing":
                update["configOptions"] = config_options(mode_value=mode)
            return {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": notify_session_id or session_id,
                    "update": update
                }
            }

        def notify(mode, notify_session_id=None):
            send(notification_payload(mode, notify_session_id))

        def respond_then_notify(request_id, result, mode, notify_session_id=None, behavior_override=None):
            response_payload = {"jsonrpc": "2.0", "id": request_id, "result": result}
            update_payload = notification_payload(mode, notify_session_id, behavior_override)
            with output_lock:
                sys.stdout.write(json.dumps(response_payload) + "\n" + json.dumps(update_payload) + "\n")
                sys.stdout.flush()

        def set_config_response():
            behavior = os.environ.get("ACP_SET_RESPONSE", "valid")
            if behavior == "empty":
                return {}
            if behavior == "missing_mode":
                return {"configOptions": [model_option()]}
            if behavior == "mismatch":
                return {"configOptions": config_options(mode_value="ask")}
            if behavior == "malformed":
                return {"configOptions": config_options(malformed_mode=True)}
            if os.environ.get("ACP_MODEL_RESPONSE_MISMATCH") == "1":
                return {"configOptions": config_options(model_value="Foo")}
            return {"configOptions": config_options()}

        def delayed_model_response(request_id):
            release_path = os.environ.get("ACP_MODEL_RELEASE_PATH")
            while release_path and not os.path.exists(release_path):
                time.sleep(0.005)
            respond(request_id, {"configOptions": config_options()})

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            record(method, params)
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True}, "authMethods": []})
            elif method == "session/load":
                if os.environ.get("ACP_FAIL_LOAD") == "1":
                    respond(request.get("id"), error={"code": -32602, "message": "session not found"})
                else:
                    opened_session_id = params.get("sessionId") or session_id
                    notification_mode = os.environ.get("ACP_NOTIFICATION_MODE")
                    if notification_mode:
                        respond_then_notify(
                            request.get("id"),
                            session_result(opened_session_id),
                            notification_mode,
                            os.environ.get("ACP_NOTIFICATION_SESSION_ID") or opened_session_id
                        )
                    else:
                        respond(request.get("id"), session_result(opened_session_id))
            elif method == "session/new":
                notification_mode = os.environ.get("ACP_NOTIFICATION_MODE")
                if notification_mode:
                    respond_then_notify(
                        request.get("id"),
                        session_result(session_id),
                        notification_mode,
                        os.environ.get("ACP_NOTIFICATION_SESSION_ID") or session_id
                    )
                else:
                    respond(request.get("id"), session_result(session_id))
            elif method == "session/set_config_option":
                config_id = params.get("configId")
                if config_id == os.environ.get("ACP_MODEL_CONFIG_ID", "model"):
                    current_model = params.get("value")
                    if os.environ.get("ACP_MODEL_CHANGES_MODE_CONFIG_ID") == "1":
                        mode_config_id = "mode_after_model"
                    if os.environ.get("ACP_MODEL_RELEASE_PATH"):
                        threading.Thread(target=delayed_model_response, args=(request.get("id"),), daemon=True).start()
                        continue
                else:
                    current_mode = params.get("value")
                after_mode = os.environ.get("ACP_AFTER_SET_NOTIFICATION_MODE")
                if after_mode:
                    response_result = set_config_response()
                    current_mode = after_mode
                    delay = float(os.environ.get("ACP_AFTER_SET_NOTIFICATION_DELAY", "0"))
                    after_behavior = os.environ.get("ACP_AFTER_SET_NOTIFICATION_BEHAVIOR")
                    if delay > 0:
                        respond(request.get("id"), response_result)
                        time.sleep(delay)
                        send(notification_payload(after_mode, behavior_override=after_behavior))
                    else:
                        respond_then_notify(
                            request.get("id"),
                            response_result,
                            after_mode,
                            behavior_override=after_behavior
                        )
                else:
                    respond(request.get("id"), set_config_response())
            elif method == "session/cancel":
                exit_release_path = os.environ.get("ACP_EXIT_ON_CANCEL_RELEASE_PATH")
                if exit_release_path:
                    while not os.path.exists(exit_release_path):
                        time.sleep(0.01)
                    sys.exit(0)
                continue
            elif method == "session/prompt":
                if os.environ.get("ACP_HANG_PROMPT") == "1":
                    continue
                respond(request.get("id"), {"stopReason": "end_turn", "usage": {"inputTokens": 1, "outputTokens": 1}})
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private struct ModeConfigFakeACPProvider: ACPAgentProvider {
    let commandPath: String
    let launchArguments: [String]
    let environment: [String: String]
    let mcpServers: [RepoPromptMCPServerConfiguration]
    var providerID: ACPProviderID = .openCode
    var normalizedUpdates: LockedStrings?

    func support(for request: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: launchArguments,
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return ACPSessionConfiguration(
            mode: mode,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: mcpServers
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID: String
    ) -> [NormalizedAgentRuntimeEvent] {
        normalizedUpdates?.append(payload["sessionUpdate"] as? String ?? "unknown")
        return []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
