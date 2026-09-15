import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class MCPWorkspaceScopedCursorModelParameterTests: XCTestCase {
    func testFixtureRootsUseUniqueUUIDPaths() throws {
        let first = try makeFixture()
        defer { first.cleanup() }
        let second = try makeFixture()
        defer { second.cleanup() }

        XCTAssertNotEqual(first.root, second.root)
    }

    /// [P2-f] A worktree-bound session's resume must acquire OpenCode metadata for the
    /// session's effective working directory, not the workspace repo root — the two can carry
    /// different OpenCode configs. The injected provider captures the workspace it was asked
    /// about, proving resume routes the right path all the way to acquisition.
    /// One consolidated full resume integration: a worktree-bound resumed session acquires
    /// OpenCode metadata for the session's EFFECTIVE working directory (not the repo root) AND
    /// persists the validated selection. The worktree is a REAL git worktree (deterministic,
    /// not an empty `.git` directory that needs a skip), and the catalog is seeded so the
    /// validation/serialization gate sees the selected model.
    func testResumeAcquiresForEffectiveWorktreeAndPersistsSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // Deterministic real worktree: a genuine repo + `git worktree add` (resolvable identity),
        // not an empty `.git` that may or may not resolve.
        let git = try ReviewGitRepositoryFixture()
        let logicalRoot = try git.makeRepository(named: "logical", files: ["README.md": "fixture"])
        let worktree = fixture.root.appendingPathComponent("linked-worktree", isDirectory: true)
        try git.runGit(["worktree", "add", "--detach", worktree.path, "HEAD"], at: logicalRoot)
        let identity = try XCTUnwrap(
            GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: worktree),
            "A real `git worktree add` must resolve a linked-worktree identity"
        )
        XCTAssertFalse(identity.isMain, "The bound fixture must exercise a linked worktree")

        let window = try await makeWindow(name: "OpenCode worktree resume", root: logicalRoot)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            compareAndSetInWorkspaceID: workspace.id
        ))
        // Bind the session to the worktree whose logical root is the workspace repo path; the
        // effective workspace path must then be the worktree root, not `repoPaths.first`.
        session.worktreeBindings = [
            AgentSessionWorktreeBinding(
                id: UUID().uuidString,
                repositoryID: identity.repository.repositoryID,
                repoKey: workspace.repoPaths.first ?? logicalRoot.path,
                logicalRootPath: logicalRoot.path,
                worktreeID: identity.worktreeID,
                worktreeRootPath: worktree.path,
                commonGitDir: identity.repository.commonGitDir,
                isMainWorktree: identity.isMain,
                source: "test"
            )
        ]

        // Seed the catalog with the OpenCode model so validation/serialization see it.
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    .init(
                        rawValue: "ollama-cloud/kimi-k3",
                        displayName: "Kimi K3",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: "ollama-cloud/kimi-k3",
                modelParameterSets: []
            ),
            for: .openCode
        )

        // The injected provider captures the workspace path it was invoked with.
        actor WorkspaceCapture {
            var paths: [String?] = []

            func record(_ path: String?) {
                paths.append(path)
            }
        }
        let capture = WorkspaceCapture()
        let provider: AgentMCPModelParameterSupport.OneShotObservationProvider = { workspacePath, modelRaw, _ in
            await capture.record(workspacePath)
            return OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: modelRaw),
                state: .available(ACPModelParameterSet(
                    baseModelRaw: modelRaw,
                    parameters: [
                        .init(
                            kind: .thinking,
                            configID: "effort",
                            displayName: "Effort",
                            choices: [
                                .init(rawValue: "low", displayName: "Low"),
                                .init(rawValue: "high", displayName: "High")
                            ],
                            currentValueRaw: "low"
                        )
                    ]
                )),
                updatedAt: Date()
            )
        }
        let service = makeManageService(
            window: window,
            openCodeOneShotObservationProvider: provider
        )

        _ = try await service.execute(args: [
            "op": .string("resume_session"),
            "session_id": .string(sessionID.uuidString),
            "model_parameters": .array([
                .object([
                    "config_id": .string("effort"),
                    "value": .string("high")
                ])
            ])
        ])

        // (1) The acquired directory: validation-stage acquisition must use the session's
        //     effective worktree root, never the repo root.
        let capturedPaths = await capture.paths
        XCTAssertEqual(
            capturedPaths.compactMap(\.self),
            [worktree.standardizedFileURL.path],
            "resume must acquire OpenCode metadata for the session's effective worktree root"
        )
        // (2) The persisted selection: the store gate then accepts and stores it.
        XCTAssertEqual(
            session.acpModelParameterSelections,
            [
                ACPModelParameterSelection(
                    providerID: .openCode,
                    baseModelRaw: "ollama-cloud/kimi-k3",
                    kind: .thinking,
                    configID: "effort",
                    valueRaw: "high"
                )
            ]
        )
    }

    /// The store-time gate (previously Cursor-only) must accept an OpenCode selection for the
    /// selected OpenCode model: discovery + the explicit resolver + store now give one coherent
    /// answer about which providers may carry model parameters.
    func testOpenCodeSelectionForSelectedModelIsAcceptedAndStored() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "OpenCode parameter store", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"

        let openCodeSelection = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        try viewModel.mcpApplyModelParameterSelections(tabID: tabID, selections: [openCodeSelection])

        XCTAssertEqual(session.acpModelParameterSelections, [openCodeSelection])
    }

    /// The widened gate still rejects the mismatches it exists to catch: a selection whose
    /// provider differs from the selected agent, or whose base model differs from the selected
    /// model, is never stored. Non-ACP agents remain rejected outright.
    func testOpenCodeSelectionProviderAndModelMismatchesAreRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "OpenCode parameter store rejects", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"

        // Provider mismatch: a Cursor selection on an OpenCode session is rejected.
        XCTAssertThrowsError(
            try viewModel.mcpApplyModelParameterSelections(
                tabID: tabID,
                selections: [selection(value: "high")]
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("base model"))
        }
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)

        // Model mismatch: an OpenCode selection for ANOTHER OpenCode model is rejected too.
        XCTAssertThrowsError(
            try viewModel.mcpApplyModelParameterSelections(
                tabID: tabID,
                selections: [
                    ACPModelParameterSelection(
                        providerID: .openCode,
                        baseModelRaw: "anthropic/claude-sonnet",
                        kind: .thinking,
                        configID: "effort",
                        valueRaw: "high"
                    )
                ]
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("base model"))
        }
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)

        // Non-ACP agent: rejected outright, with wording naming the actual provider.
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5"
        XCTAssertThrowsError(
            try viewModel.mcpApplyModelParameterSelections(
                tabID: tabID,
                selections: [
                    ACPModelParameterSelection(
                        providerID: .openCode,
                        baseModelRaw: "ollama-cloud/kimi-k3",
                        kind: .thinking,
                        configID: "effort",
                        valueRaw: "high"
                    )
                ]
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("ACP providers"))
            XCTAssertTrue(String(describing: error).contains(AgentProviderKind.codexExec.displayName))
        }
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)
    }

    /// A failed OpenCode parameter acquisition on a target-creating path must discard the
    /// target it allocated, not leave it outstanding. The injected provider throws mid-setup,
    /// AFTER the target exists: asserting the provider ran and the error is the injected one
    /// proves the throw came from acquisition (not a pre-allocation rejection, which would also
    /// leave the count at zero without exercising the discard scope).
    func testCreateDiscardsTargetWhenParameterAcquisitionFails() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "OpenCode create discard", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        // OpenCode must be available for its compound model_id to resolve; the default
        // availability context has it unavailable.
        window.apiSettingsViewModel.isOpenCodeConnected = true
        // Seed the OpenCode catalog so `model_id` validation resolves an OpenCode model rather
        // than rejecting it before the target is allocated.
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    .init(
                        rawValue: "ollama-cloud/kimi-k3",
                        displayName: "Kimi K3",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: "ollama-cloud/kimi-k3",
                modelParameterSets: []
            ),
            for: .openCode
        )
        actor AcquisitionProbe {
            var providerRuns = 0
            var allocations = 0

            func recordProviderRun() {
                providerRuns += 1
            }

            func recordAllocation() {
                allocations += 1
            }
        }
        let acquisitionProbe = AcquisitionProbe()
        let provider: AgentMCPModelParameterSupport.OneShotObservationProvider = { _, _, _ in
            await acquisitionProbe.recordProviderRun()
            throw MCPError.invalidParams("simulated OpenCode acquisition failure")
        }
        var service = makeManageService(
            window: window,
            openCodeOneShotObservationProvider: provider
        )
        // PROOF that a target was allocated before the acquisition threw: this hook fires only
        // after `mcpResolveOrCreateSessionTarget` creates the provisional target, so observing
        // it here decouples "allocated" from the trivially-true "count is zero after cleanup".
        service.testAfterTargetResolution = { _ in
            await acquisitionProbe.recordAllocation()
        }
        do {
            _ = try await service.execute(args: [
                "op": .string("create_session"),
                "model_id": .string(AgentModelSelectionID(
                    agentRaw: AgentProviderKind.openCode.rawValue,
                    modelRaw: "ollama-cloud/kimi-k3"
                ).rawValue),
                "model_parameters": .array([
                    .object(["config_id": .string("effort"), "value": .string("high")])
                ])
            ])
            XCTFail("create_session should have thrown")
        } catch {
            // The throw is the INJECTED acquisition error (so the failure came from parameter
            // acquisition, not a pre-allocation rejection)...
            XCTAssertTrue(
                error.localizedDescription.contains("simulated OpenCode acquisition failure"),
                "Expected the injected acquisition error, got \(error)"
            )
            // ...the provider actually ran for this request...
            let runs = await acquisitionProbe.providerRuns
            XCTAssertEqual(runs, 1, "The injected provider must have run for this create")
            // ...and a target WAS allocated (the hook fired) before the throw...
            let allocations = await acquisitionProbe.allocations
            XCTAssertEqual(allocations, 1, "A provisional target must have been allocated before acquisition")
            // ...and then discarded by the scope (not a rejection before allocation, which
            // likewise leaves zero but proves nothing about cleanup).
            XCTAssertEqual(viewModel.test_outstandingProvisionalMCPSessionTargetCount, 0)
        }
    }

    func testResumeRejectsModelParameterChangesWhileRunIsActive() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor active resume", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            compareAndSetInWorkspaceID: workspace.id
        ))
        session.runState = .running

        let service = makeManageService(window: window)
        do {
            _ = try await service.execute(args: [
                "op": .string("resume_session"),
                "session_id": .string(sessionID.uuidString),
                "model_parameters": .array([
                    .object([
                        "config_id": .string("effort"),
                        "value": .string("high")
                    ])
                ])
            ])
            XCTFail("Expected active resume configuration to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("actively running"))
        }
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)
    }

    func testParameterWriteRejectsSessionThatBecameActiveAfterSetup() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor late admission", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        try viewModel.mcpApplyModelParameterSelections(tabID: tabID, selections: [selection(value: "low")])

        // Setup admitted an idle session; a run starts before the final write.
        session.runState = .running
        do {
            try viewModel.mcpApplyModelParameterSelections(tabID: tabID, selections: [selection(value: "high")])
            XCTFail("The final write must recheck run activity")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("actively running"))
        }
        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["low"])
    }

    func testConfigurationRejectsRunActivatedDuringHydrationBeforeChangingModelOrParameters() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor configuration admission", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        try viewModel.mcpApplyModelParameterSelections(tabID: tabID, selections: [selection(value: "low")])
        session.hasLoadedPersistedState = false
        session.persistedLoadTask = Task { @MainActor in
            session.hasLoadedPersistedState = true
            session.runState = .running
        }
        defer { session.persistedLoadTask = nil }
        do {
            try await viewModel.mcpConfigureSession(
                tabID: tabID, agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "composer-2.5", reasoningEffortRaw: nil,
                modelParameterSelections: [.init(
                    providerID: .cursor, baseModelRaw: "composer-2.5", kind: .speed,
                    configID: "fast", valueRaw: "true"
                )],
                requireInactiveRunState: true
            )
            XCTFail("Configuration must recheck activity after hydration")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("actively running"))
        }
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.selectedModelRaw, "grok-4.6")
        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["low"])
    }

    func testExplicitResumeRejectsCompetingRunBeforeAndAfterActivationAndPreservesControl() async throws {
        for afterActivation in [false, true] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let window = try await makeWindow(name: "Cursor resume barrier", root: fixture.root)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let viewModel = window.agentModeViewModel
            var service = makeManageService(window: window)
            let created = try await service.execute(args: [
                "op": .string("create_session"), "model_id": .string(cursorModelID),
                "model_parameters": request([("effort", "high"), ("fast", "false")])
            ])
            let sessionID = try XCTUnwrap(created.objectValue?["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: sessionID, createIfNeeded: false, sessionName: nil
            )
            let session = try XCTUnwrap(viewModel.session(for: target.tabID, createIfNeeded: false))
            await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
            let reached = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            service.test_resumeSetupBoundary = { boundary in
                guard boundary == afterActivation else { return }
                reached.continuation.yield(())
                for await _ in release.stream {
                    break
                }
            }
            let barrierService = service
            let resume = Task { @MainActor in
                try await barrierService.execute(args: [
                    "op": .string("resume_session"), "session_id": .string(sessionID.uuidString),
                    "model_parameters": request([("effort", "low")])
                ])
            }
            for await _ in reached.stream {
                break
            }
            if !afterActivation {
                try await viewModel.mcpActivateControlContext(
                    forTabID: target.tabID, sessionID: sessionID, originatingConnectionID: UUID()
                )
            }
            let competingControl = try XCTUnwrap(session.mcpControlContext?.activationID)
            let capturedSelections = session.acpModelParameterSelections
            session.runState = .running
            release.continuation.yield(())
            do {
                _ = try await resume.value
                XCTFail("Explicit resume must lose to the competing run")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("active") || error.localizedDescription.contains("running"))
            }
            XCTAssertTrue(viewModel.session(for: target.tabID, createIfNeeded: false) === session)
            XCTAssertEqual(session.runState, .running)
            XCTAssertEqual(session.acpModelParameterSelections, capturedSelections)
            XCTAssertEqual(session.selectedModelRaw, "grok-4.6")
            XCTAssertEqual(session.mcpControlContext?.activationID, competingControl)

            service.test_resumeSetupBoundary = nil
            _ = try await service.execute(args: [
                "op": .string("resume_session"), "session_id": .string(sessionID.uuidString)
            ])
            XCTAssertEqual(session.mcpControlContext?.activationID, competingControl)
            XCTAssertEqual(session.acpModelParameterSelections, capturedSelections)
        }
    }

    func testResumeFailureSettlesProvisionalClaimAfterPublicSteerStartsNewerRun() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor resume public ownership", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let sessionID = UUID()
        viewModel.upsertSessionIndex(
            sessionID: sessionID,
            tabID: UUID(),
            name: "Cursor public ownership",
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastRunStateRaw: AgentSessionRunState.completed.rawValue,
            itemCount: 1,
            agentKindRaw: AgentProviderKind.cursor.rawValue,
            agentModelRaw: "grok-4.6",
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false
        )

        let activationReached = expectation(description: "Resume published MCP control")
        let releaseActivation = AsyncStream<Void>.makeStream()
        var activatedSession: AgentModeViewModel.TabSession?
        viewModel.test_afterMCPControlActivation = { session in
            activatedSession = session
            activationReached.fulfill()
            for await _ in releaseActivation.stream {
                break
            }
        }
        defer {
            releaseActivation.continuation.yield(())
            viewModel.test_afterMCPControlActivation = nil
        }

        let resumeService = makeManageService(window: window)
        let resume = Task { @MainActor in
            try await resumeService.execute(args: [
                "op": .string("resume_session"),
                "session_id": .string(sessionID.uuidString),
                "model_id": .string(cursorModelID),
                "model_parameters": request([("effort", "high")])
            ])
        }
        defer { resume.cancel() }
        await fulfillment(of: [activationReached], timeout: 5)

        let session = try XCTUnwrap(activatedSession)
        XCTAssertEqual(session.activeAgentSessionID, sessionID)
        var steerService = makeRunService(window: window)
        steerService.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            XCTAssertEqual(dispatchedSessionID, sessionID)
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            XCTAssertTrue(controlledSession.mcpFollowUpRunPending)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }
        _ = try await steerService.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("start the newer public run")
        ])
        XCTAssertTrue(session.runState.isActive)
        XCTAssertNotNil(session.mcpControlContext)

        releaseActivation.continuation.yield(())
        do {
            _ = try await resume.value
            XCTFail("The older resume must lose to the public steer run")
        } catch {
            XCTAssertTrue(String(describing: error).contains("actively running"), String(describing: error))
        }

        let settledTarget = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: true,
            sessionName: nil,
            expectedWorkspaceID: workspace.id
        )
        XCTAssertEqual(settledTarget.origin, .existingSession)
        viewModel.mcpAcceptSessionTarget(settledTarget)
        XCTAssertTrue(session.runState.isActive)
        XCTAssertNotNil(session.mcpControlContext)

        session.runState = .completed
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    func testConfigurationRejectsStaleTargetBeforeChangingReplacementSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor stale target", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let original = await viewModel.ensureSessionReady(tabID: tabID)
        let expected = original.persistentBindingTransitionToken()
        let replacement = AgentModeViewModel.TabSession(tabID: tabID)
        replacement.hasLoadedPersistedState = true
        replacement.selectedAgent = .cursor
        replacement.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(replacement)
        do {
            try await viewModel.mcpConfigureSession(
                tabID: tabID, agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "composer-2.5", reasoningEffortRaw: nil,
                requireInactiveRunState: true, expectedTarget: expected
            )
            XCTFail("A stale target cannot configure its replacement")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("binding changed"))
        }
        XCTAssertEqual(replacement.selectedModelRaw, "grok-4.6")
        XCTAssertTrue(replacement.acpModelParameterSelections.isEmpty)
    }

    func testLosingResumePreservesNewerInactiveActivationOnSameBinding() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor activation ownership", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let service = makeManageService(window: window)
        let created = try await service.execute(args: [
            "op": .string("create_session"), "model_id": .string(cursorModelID),
            "model_parameters": request([("effort", "high")])
        ])
        let sessionID = try XCTUnwrap(created.objectValue?["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil, sessionID: sessionID, createIfNeeded: false, sessionName: nil
        )
        let session = try XCTUnwrap(viewModel.session(for: target.tabID, createIfNeeded: false))
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
        let reached = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var holdFirstActivation = true
        viewModel.test_afterMCPControlRegistration = { _ in
            guard holdFirstActivation else { return }
            holdFirstActivation = false
            reached.continuation.yield(())
            for await _ in release.stream {
                break
            }
        }
        defer { viewModel.test_afterMCPControlRegistration = nil }
        let losingResume = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("resume_session"), "session_id": .string(sessionID.uuidString),
                "model_parameters": request([("effort", "low")])
            ])
        }
        for await _ in reached.stream {
            break
        }
        _ = try await service.execute(args: [
            "op": .string("resume_session"), "session_id": .string(sessionID.uuidString),
            "model_parameters": request([("effort", "medium")])
        ])
        let winningContext = try XCTUnwrap(session.mcpControlContext)
        XCTAssertFalse(session.runState.isActive)
        release.continuation.yield(())
        do {
            _ = try await losingResume.value
            XCTFail("Superseded activation must reject its older resume")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("control activation"))
        }
        XCTAssertTrue(viewModel.session(for: target.tabID, createIfNeeded: false) === session)
        XCTAssertFalse(session.runState.isActive)
        XCTAssertEqual(session.mcpControlContext?.activationID, winningContext.activationID)
        XCTAssertEqual(session.mcpControlContext?.registration, winningContext.registration)
        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["medium"])
    }

    func testOwnedDeactivationCannotRemoveSuccessorActivation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor owned cleanup", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: nil
        )
        let sessionID = try XCTUnwrap(target.sessionID)
        let oldContext = try await viewModel.mcpActivateControlContext(
            forTabID: target.tabID, sessionID: sessionID, originatingConnectionID: UUID()
        )
        let successor = try await viewModel.mcpActivateControlContext(
            forTabID: target.tabID, sessionID: sessionID, originatingConnectionID: UUID()
        )
        let didRemove = await viewModel.mcpDeactivateOwnedControlContext(
            sessionID: sessionID, expectedContext: oldContext
        )
        XCTAssertFalse(didRemove)
        let session = try XCTUnwrap(viewModel.session(for: target.tabID, createIfNeeded: false))
        XCTAssertEqual(session.mcpControlContext?.activationID, successor.activationID)
        XCTAssertEqual(session.mcpControlContext?.registration, successor.registration)
        let removedOwnedSuccessor = await viewModel.mcpDeactivateOwnedControlContext(
            sessionID: sessionID, expectedContext: successor
        )
        XCTAssertTrue(removedOwnedSuccessor)
        XCTAssertNil(session.mcpControlContext)
    }

    func testAgentManageListCreateAndResumeUseReleaseCatalogMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let service = makeManageService(window: window)
        let listed = try await service.execute(args: ["op": .string("list_agents")])
        XCTAssertEqual(
            listedParameterConfigIDs(listed, modelRaw: "grok-4.6"),
            ["effort", "fast"]
        )

        let modelID = cursorModelID
        let created = try await service.execute(args: [
            "op": .string("create_session"),
            "model_id": .string(modelID),
            "model_parameters": request([
                ("effort", "high"),
                ("fast", "true")
            ])
        ])
        XCTAssertEqual(effectiveParameterConfigIDs(created), ["effort", "fast"])
        let createdParameters = try XCTUnwrap(created.objectValue?["agent"]?.objectValue?["model_parameters"]?.arrayValue)
        XCTAssertEqual(createdParameters.compactMap { $0.objectValue?["value"]?.stringValue }, ["high", "true"])
        XCTAssertEqual(createdParameters.compactMap { $0.objectValue?["base_model"]?.stringValue }, ["grok-4.6", "grok-4.6"])
        let sessionID = try XCTUnwrap(created.objectValue?["session_id"]?.stringValue)

        let resumed = try await service.execute(args: [
            "op": .string("resume_session"),
            "session_id": .string(sessionID),
            "model_id": .string(modelID),
            "model_parameters": request([
                ("effort", "low"),
                ("fast", "false")
            ])
        ])
        XCTAssertEqual(effectiveParameterConfigIDs(resumed), ["effort", "fast"])
        let resumedParameters = try XCTUnwrap(resumed.objectValue?["agent"]?.objectValue?["model_parameters"]?.arrayValue)
        XCTAssertEqual(resumedParameters.compactMap { $0.objectValue?["value"]?.stringValue }, ["low", "false"])
        XCTAssertEqual(resumedParameters.compactMap { $0.objectValue?["base_model"]?.stringValue }, ["grok-4.6", "grok-4.6"])
    }

    func testAgentRunStartRejectsUnknownReleaseCatalogParameter() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Run", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeRunService(window: window)

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Reject stale metadata."),
                "model_id": .string(cursorModelID),
                "model_parameters": request([("workspace_effort", "high")])
            ])
            XCTFail("Expected stale parameter metadata to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("workspace_effort"))
        }
    }

    func testAgentRunSuccessfulStartStagesLegacyComposerAliasWithCanonicalSpeedSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Successful Run", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        var stagedSelections: [ACPModelParameterSelection] = []
        let service = makeRunService(
            window: window,
            successfulStart: true,
            observeSuccessfulStart: { selections in
                stagedSelections = selections
            }
        )

        _ = try await service.execute(args: [
            "op": .string("start"),
            "message": .string("Use the configured Cursor speed."),
            "model_id": .string(AgentModelSelectionID(
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "composer-2"
            ).rawValue),
            "model_parameters": request([("fast", "true")]),
            "detach": .bool(true)
        ])

        XCTAssertEqual(stagedSelections.map(\.baseModelRaw), ["composer-2.5"])
        XCTAssertEqual(stagedSelections.map(\.configID), ["fast"])
        XCTAssertEqual(stagedSelections.map(\.valueRaw), ["true"])
    }

    func testAgentRunFailedStartRestoresExistingSessionCursorParameters() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Run Rollback", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let agentModeVM = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: tabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: nil
        )
        let sessionID = try XCTUnwrap(target.sessionID)
        agentModeVM.mcpAcceptSessionTarget(target)
        _ = try await agentModeVM.mcpStageModelParameterSelections(
            tabID: tabID,
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok-4.6",
            selections: [selection(value: "low")]
        )

        var stagedValueAtFailure: String?
        let service = makeRunService(
            window: window,
            targetTabID: tabID,
            beforeStartFailure: { viewModel, targetTabID in
                stagedValueAtFailure = viewModel.session(for: targetTabID)
                    .acpModelParameterSelections.first?.valueRaw
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Fail after staging Cursor parameters."),
                "model_id": .string(cursorModelID),
                "model_parameters": request([("effort", "high")])
            ])
            XCTFail("Expected the injected provider start failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Injected provider start failure"))
        }

        let retainedSession = agentModeVM.session(for: tabID)
        XCTAssertEqual(stagedValueAtFailure, "high")
        XCTAssertEqual(retainedSession.activeAgentSessionID, sessionID)
        XCTAssertEqual(retainedSession.acpModelParameterSelections.first?.valueRaw, "low")
    }

    func testRollbackRestoresOnlyParametersWithoutNewerIntent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor independent parameter rollback", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        let speed: (String) -> ACPModelParameterSelection = { value in
            .init(providerID: .cursor, baseModelRaw: "grok-4.6", kind: .speed, configID: "fast", valueRaw: value)
        }
        try viewModel.mcpApplyModelParameterSelections(
            tabID: tabID, selections: [selection(value: "low"), speed("false")]
        )
        let rollback = try XCTUnwrap(viewModel.mcpStageModelParameterSelections(
            tabID: tabID, agentRaw: AgentProviderKind.cursor.rawValue, modelRaw: "grok-4.6",
            selections: [selection(value: "high"), speed("true")]
        ))
        // The newer intent adopts the staged Speed value, leaving Effort owned by the old start.
        try viewModel.mcpApplyModelParameterSelections(tabID: tabID, selections: [speed("true")])
        viewModel.mcpRollbackStagedModelParameterSelections(rollback)
        XCTAssertEqual(session.acpModelParameterSelections.first { $0.kind == .thinking }?.valueRaw, "low")
        XCTAssertEqual(session.acpModelParameterSelections.first { $0.kind == .speed }?.valueRaw, "true")
    }

    func testAgentRunFailedStartPreservesNewerCursorParameterSelection() async throws {
        try await assertFailedStartPreservesNewerSelection("medium")
        try await assertFailedStartPreservesNewerSelection("high")
    }

    private func assertFailedStartPreservesNewerSelection(_ newerValue: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Run Concurrent Selection", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let agentModeVM = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let initialTarget = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: tabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: nil
        )
        _ = try await agentModeVM.mcpStageModelParameterSelections(
            tabID: tabID,
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok-4.6",
            selections: [selection(value: "low")]
        )
        agentModeVM.mcpAcceptSessionTarget(initialTarget)

        let service = makeRunService(
            window: window,
            targetTabID: tabID,
            resumeValueBeforeStartFailure: newerValue
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Preserve a newer parameter selection after failure."),
                "model_id": .string(cursorModelID),
                "model_parameters": request([("effort", "high")])
            ])
            XCTFail("Expected the injected provider start failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Injected provider start failure"))
        }

        XCTAssertEqual(
            agentModeVM.session(for: tabID).acpModelParameterSelections.first?.valueRaw,
            newerValue
        )
    }

    private var cursorModelID: String {
        AgentModelSelectionID(agentRaw: AgentProviderKind.cursor.rawValue, modelRaw: "grok-4.6").rawValue
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-cursor-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }

    private func makeWindow(name: String, root: URL) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        window.apiSettingsViewModel.isCursorConnected = true
        let workspace = window.workspaceManager.createWorkspace(
            name: name,
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "releaseGatedCursorMCPTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeManageService(
        window: WindowState,
        openCodeOneShotObservationProvider: AgentMCPModelParameterSupport.OneShotObservationProvider? = nil
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "release-gated-cursor-model-parameters",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false },
            openCodeOneShotObservationProvider: openCodeOneShotObservationProvider
                ?? AgentMCPModelParameterSupport.liveOneShotObservationProvider
        )
    }

    private func makeRunService(
        window: WindowState,
        targetTabID: UUID? = nil,
        beforeStartFailure: ((AgentModeViewModel, UUID) throws -> Void)? = nil,
        resumeValueBeforeStartFailure: String? = nil,
        successfulStart: Bool = false,
        observeSuccessfulStart: (([ACPModelParameterSelection]) -> Void)? = nil
    ) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "release-gated-cursor-model-parameters",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in targetTabID },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, message, metadata, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _, _, _ in
                if let resumeValueBeforeStartFailure {
                    // Exercise the production control activation/configuration path. A newer
                    // resume is accepted while the old start is waiting to dispatch its prompt.
                    return try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                        target: target,
                        message: message,
                        metadata: metadata,
                        agentModeVM: agentModeVM,
                        agentRaw: agentRaw,
                        modelRaw: modelRaw,
                        reasoningEffortRaw: reasoningEffortRaw,
                        dispatchInstruction: { sessionID, _, _, _, _ in
                            _ = try await self.makeManageService(window: window).execute(args: [
                                "op": .string("resume_session"),
                                "session_id": .string(sessionID.uuidString),
                                "model_parameters": self.request([("effort", resumeValueBeforeStartFailure)])
                            ])
                            throw MCPError.internalError("Injected provider start failure.")
                        }
                    )
                }
                try beforeStartFailure?(agentModeVM, target.tabID)
                if successfulStart {
                    let session = agentModeVM.session(for: target.tabID)
                    observeSuccessfulStart?(session.acpModelParameterSelections)
                    let snapshot = AgentRunMCPSnapshot(
                        sessionID: target.sessionID ?? UUID(),
                        tabID: target.tabID,
                        sessionName: "Cursor MCP Successful Run",
                        agentRaw: agentRaw,
                        agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
                        modelRaw: modelRaw,
                        reasoningEffortRaw: reasoningEffortRaw,
                        modelParameterSelections: session.acpModelParameterSelections.map {
                            .init(
                                providerID: $0.providerID.rawValue,
                                baseModelRaw: $0.baseModelRaw,
                                kind: $0.kind.rawValue,
                                configID: $0.configID,
                                valueRaw: $0.valueRaw
                            )
                        },
                        status: .running,
                        statusText: "Test harness running",
                        latestAssistantPreview: nil,
                        interaction: nil,
                        transcriptItemCount: 0,
                        updatedAt: Date(),
                        parentSessionID: session.parentSessionID,
                        failureReason: nil,
                        worktreeBindings: [],
                        activeWorktreeMerges: []
                    )
                    return AgentExternalMCPRunStarter.StartOutcome(snapshot: snapshot, delivery: .startedRun)
                }
                throw MCPError.internalError("Injected provider start failure.")
            }
        )
        service.resolveOracleReviewLaunchSource = { _, targetWindow in
            let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(workspace.activeComposeTabID)
            let snapshot = AgentRunOracleReviewLaunchSnapshot(
                route: .explicitWindowActiveCompose,
                windowID: targetWindow.windowID,
                workspaceID: workspace.id,
                tabID: tabID,
                selectionRevision: 0,
                promptText: "",
                selection: StoredSelection(),
                sourceAgentSessionID: nil,
                routedRunID: nil
            )
            return ResolvedAgentRunOracleReviewLaunchSource(
                snapshot: snapshot,
                source: .unavailable(.init(
                    delegationID: UUID(),
                    sourceTabID: tabID,
                    workspaceID: workspace.id,
                    sourceAgentSessionID: nil,
                    sourceAgentRunID: nil,
                    reason: .sourceCaptureFailed("Synthetic MCP release-catalog fixture")
                ))
            )
        }
        return service
    }

    private func request(_ pairs: [(String, String)]) -> Value {
        .array(pairs.map { configID, value in
            .object(["config_id": .string(configID), "value": .string(value)])
        })
    }

    private func selection(value: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "effort",
            valueRaw: value
        )
    }

    private func listedParameterConfigIDs(_ value: Value, modelRaw: String) -> [String] {
        let cursor = value.objectValue?["agents"]?.arrayValue?.first {
            $0.objectValue?["name"]?.stringValue == AgentProviderKind.cursor.displayName
        }
        let model = cursor?.objectValue?["models"]?.arrayValue?.first {
            $0.objectValue?["model_id"]?.stringValue == AgentModelSelectionID(
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: modelRaw
            ).rawValue
        }
        return model?.objectValue?["model_parameters"]?.arrayValue?.compactMap {
            $0.objectValue?["config_id"]?.stringValue
        } ?? []
    }

    private func effectiveParameterConfigIDs(_ value: Value) -> [String] {
        value.objectValue?["agent"]?.objectValue?["model_parameters"]?.arrayValue?.compactMap {
            $0.objectValue?["config_id"]?.stringValue
        } ?? []
    }

    private struct Fixture {
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
