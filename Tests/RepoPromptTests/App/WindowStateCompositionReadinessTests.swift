import MCP
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class WindowStateCompositionReadinessTests: XCTestCase {
    func testActiveChatRestoreSettlesBetweenFirstProjectionAndRuntimePublication() async throws {
        let fixture = try await makeFixture()

        try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)

        XCTAssertTrue(fixture.recorder.didRequestHydration)
        XCTAssertTrue(fixture.recorder.didReachInitialActiveSessionPresentation)
        XCTAssertEqual(
            fixture.recorder.events,
            [.firstAuthoritativeProjectionApplied, .initialActiveSessionRestoreSettled]
        )
        XCTAssertEqual(fixture.composition.workspaceManager.activeWorkspaceID, fixture.workspaceID)
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.activeTranscriptPresentation.visibleRows.map(\.text),
            ["restored user", "restored assistant"]
        )
        XCTAssertTrue(fixture.composition.agentModeViewModel.activeTranscriptPresentation.bindingsHydrated)
        XCTAssertFalse(fixture.composition.workspaceManager.isInitialized)
        XCTAssertTrue(fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mappings.isEmpty == true)

        await fixture.readinessGate.release()
        await fixture.indexGate.release()
        await fixture.composition.workspaceSessionActivationTask?.value

        XCTAssertEqual(
            fixture.recorder.events,
            [
                .firstAuthoritativeProjectionApplied,
                .initialActiveSessionRestoreSettled,
                .runtimeAdapterPublished,
                .selectedSessionInitializationCompleted
            ]
        )
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.activeTranscriptPresentation.visibleRows.map(\.text),
            ["restored user", "restored assistant"]
        )
        XCTAssertTrue(fixture.composition.agentModeViewModel.activeTranscriptPresentation.bindingsHydrated)
        XCTAssertTrue(fixture.composition.workspaceManager.isInitialized)

        let mapping = try XCTUnwrap(
            fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mapping(windowID: fixture.windowID)
        )
        XCTAssertEqual(mapping.runtimeID, fixture.composition.workspaceRuntimeID)
        XCTAssertEqual(mapping.sessionID, fixture.composition.workspaceSessionID)
        XCTAssertEqual(mapping.activeWorkspaceID, fixture.workspaceID)

        await fixture.shutdown()
    }

    func testInactiveAgentModeStillRestoresBeforeRuntimePublication() async throws {
        let fixture = try await makeFixture(activateAgentMode: false)

        try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)

        XCTAssertTrue(fixture.recorder.didRequestHydration)
        XCTAssertTrue(fixture.recorder.didReachInitialActiveSessionPresentation)
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.activeTranscriptPresentation.visibleRows.map(\.text),
            ["restored user", "restored assistant"]
        )
        XCTAssertTrue(fixture.composition.agentModeViewModel.activeTranscriptPresentation.bindingsHydrated)

        await fixture.readinessGate.release()
        await fixture.indexGate.release()
        await fixture.composition.workspaceSessionActivationTask?.value

        XCTAssertEqual(
            fixture.recorder.events,
            [
                .firstAuthoritativeProjectionApplied,
                .initialActiveSessionRestoreSettled,
                .runtimeAdapterPublished,
                .selectedSessionInitializationCompleted
            ]
        )
        XCTAssertTrue(fixture.composition.workspaceManager.isInitialized)
        XCTAssertEqual(
            fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot
                .mapping(windowID: fixture.windowID)?.runtimeID,
            fixture.composition.workspaceRuntimeID
        )

        await fixture.shutdown()
    }

    func testCancelledOrClosingReadinessWaitFailsClosedWithoutAdapterPublication() async throws {
        for interruption in ReadinessInterruption.allCases {
            var fixture: Fixture? = try await makeFixture(gateInitialRestore: true)
            let storageRoot = try XCTUnwrap(fixture?.storageRoot)
            do {
                let activeFixture = try XCTUnwrap(fixture)
                try await fulfillment(of: [XCTUnwrap(activeFixture.initialPresentationReached)], timeout: 3)
                for _ in 0 ..< 100
                    where activeFixture.composition.agentModeViewModel.test_initialActiveSessionRestoreWaiterCount != 1
                {
                    await Task.yield()
                }

                XCTAssertTrue(activeFixture.recorder.didRequestHydration)
                XCTAssertTrue(activeFixture.recorder.didReachInitialActiveSessionPresentation)
                XCTAssertEqual(activeFixture.recorder.events, [.firstAuthoritativeProjectionApplied])
                XCTAssertEqual(
                    activeFixture.composition.agentModeViewModel.test_initialActiveSessionRestoreWaiterCount,
                    1
                )

                switch interruption {
                case .cancel:
                    let activationFinished = expectation(description: "cancelled activation finished")
                    activeFixture.composition.workspaceSessionActivationTask?.cancel()
                    Task { @MainActor in
                        await activeFixture.composition.workspaceSessionActivationTask?.value
                        activationFinished.fulfill()
                    }
                    await fulfillment(of: [activationFinished], timeout: 3)
                    XCTAssertEqual(
                        activeFixture.composition.agentModeViewModel.test_initialActiveSessionRestoreWaiterCount,
                        0
                    )
                case .beginClosing:
                    activeFixture.composition.workspaceRuntimeBeginClose()
                    await activeFixture.initialPresentationGate.release()
                    await activeFixture.indexGate.release()
                    await activeFixture.composition.workspaceSessionActivationTask?.value
                }

                XCTAssertEqual(
                    activeFixture.recorder.events,
                    [.firstAuthoritativeProjectionApplied],
                    "unexpected readiness progress for \(interruption)"
                )
                XCTAssertFalse(
                    activeFixture.composition.workspaceManager.isInitialized,
                    "selected initialization escaped fail-closed boundary for \(interruption)"
                )
                XCTAssertTrue(
                    activeFixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mappings.isEmpty == true,
                    "stale adapter published for \(interruption)"
                )
                if let runtimeID = activeFixture.composition.workspaceRuntimeID {
                    XCTAssertNil(
                        activeFixture.container.runtimeAdapterRegistry?.publicationState(runtimeID: runtimeID),
                        "adapter entry was staged for \(interruption)"
                    )
                }
                await activeFixture.shutdown()
            }

            fixture = nil
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }

    func testPostPublicationOwnershipLossFailsClosedBeforeSelectedInitialization() async throws {
        for interruption in PostPublicationInterruption.allCases {
            let fixture = try await makeFixture(gateRuntimePublicationReady: true)
            try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)
            await fixture.readinessGate.release()
            try await fulfillment(of: [XCTUnwrap(fixture.runtimePublicationReadyReached)], timeout: 3)

            XCTAssertFalse(fixture.composition.workspaceManager.isInitialized)
            XCTAssertNotNil(
                fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mapping(windowID: fixture.windowID)
            )

            switch interruption {
            case .cancel:
                fixture.composition.workspaceSessionActivationTask?.cancel()
            case .beginClosing:
                fixture.composition.workspaceRuntimeBeginClose()
            case .adapterOwnershipLoss:
                if let runtimeID = fixture.composition.workspaceRuntimeID {
                    _ = fixture.container.runtimeAdapterRegistry?.beginClosing(runtimeID: runtimeID)
                }
            case .lifecycleOwnershipLoss:
                if let runtimeID = fixture.composition.workspaceRuntimeID {
                    _ = await fixture.container.runtimeLifecycleRegistry?.beginDraining(runtimeID: runtimeID)
                }
            }
            if interruption != .cancel {
                await fixture.runtimePublicationReadyGate.release()
            }

            let activationFinished = expectation(description: "post-publication interruption finished")
            Task { @MainActor in
                await fixture.composition.workspaceSessionActivationTask?.value
                activationFinished.fulfill()
            }
            await fulfillment(of: [activationFinished], timeout: 3)
            await fixture.indexGate.release()

            XCTAssertEqual(
                fixture.recorder.events,
                [.firstAuthoritativeProjectionApplied, .initialActiveSessionRestoreSettled],
                "unexpected selected-session progress for \(interruption)"
            )
            XCTAssertFalse(
                fixture.composition.workspaceManager.isInitialized,
                "selected initialization escaped post-publication ownership fence for \(interruption)"
            )
            XCTAssertNil(
                fixture.container.runtimeAdapterRegistry?.latestRoutingTableSnapshot.mapping(windowID: fixture.windowID),
                "runtime mapping remained published for \(interruption)"
            )

            await fixture.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
    }

    func testRestoredAgentManageSelectionSurvivesAuthoritativeProjectionFeedback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateCompositionReadinessTests-\(UUID().uuidString)")
            .appendingPathComponent("ManageSelectionRoot")
        let worktreeRoot = root.deletingLastPathComponent()
            .appendingPathComponent("ManageSelectionWorktree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let paths = [
            root.appendingPathComponent("AGENTS.md"),
            root.appendingPathComponent("Package.swift"),
            root.appendingPathComponent("Sources/App.swift")
        ]
        let worktreePaths = paths.map { path in
            worktreeRoot.appendingPathComponent(path.path.replacingOccurrences(of: root.path + "/", with: ""))
        }
        try FileManager.default.createDirectory(
            at: paths[2].deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: worktreePaths[2].deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Agent instructions\n".write(to: paths[0], atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.0\n".write(to: paths[1], atomically: true, encoding: .utf8)
        try "struct App {}\n".write(to: paths[2], atomically: true, encoding: .utf8)
        for (source, destination) in zip(paths, worktreePaths) {
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let fixture = try await makeFixture(
            repoPaths: [root.path],
            useProductionAgentRestore: true,
            agentWorktreeBindings: [makeWorktreeBinding(logicalRoot: root, worktreeRoot: worktreeRoot)],
            injectProjectionSelectionFeedback: true
        )
        addTeardownBlock { @MainActor in
            fixture.composition.workspaceManager
                .test_setAuthoritativeProjectionFeedbackEventHandler(nil)
            await fixture.shutdown()
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)
        await fixture.readinessGate.release()
        await fixture.indexGate.release()
        await fixture.composition.workspaceSessionActivationTask?.value
        XCTAssertTrue(fixture.composition.workspaceManager.isInitialized)
        XCTAssertEqual(
            fixture.composition.workspaceManager.composeTab(with: fixture.tabID)?.activeAgentSessionID,
            fixture.agentSessionID
        )
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.activeTranscriptPresentation.visibleRows.map(\.text),
            ["restored user", "restored assistant"]
        )
        XCTAssertTrue(fixture.composition.agentModeViewModel.activeTranscriptPresentation.bindingsHydrated)
        XCTAssertTrue(
            fixture.composition.workspaceManager.composeTab(with: fixture.tabID)?.selection.selectedPaths.isEmpty == true
        )
        _ = await fixture.composition.workspaceFileContextStore.awaitAppliedIngress(rootScope: .visibleWorkspace)
        _ = try await fixture.composition.workspaceFileContextStore.loadRoot(
            path: worktreeRoot.path,
            kind: .sessionWorktree
        )

        let projectionFeedbackSuppressed = expectation(
            description: "projection-originated selected-files feedback suppressed synchronously"
        )
        let runtimeMetricsReadCompleted = expectation(
            description: "runtime metrics reads canonical selection without flushing stale UI"
        )
        fixture.projectionFeedbackRecorder.setRuntimeMetricsReadHandler { _ in
            runtimeMetricsReadCompleted.fulfill()
        }
        var selectedFilesEventOrigin: Bool?
        fixture.composition.workspaceManager
            .test_setAuthoritativeProjectionFeedbackEventHandler { source, originatedDuringProjection in
                guard source == .selectedFiles, selectedFilesEventOrigin == nil else { return }
                selectedFilesEventOrigin = originatedDuringProjection
                projectionFeedbackSuppressed.fulfill()
            }
        let connectionID = UUID()
        try fixture.composition.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "restored-agent-projection-feedback",
            tabID: fixture.tabID,
            workspaceID: fixture.workspaceID,
            windowID: fixture.windowID
        )
        let tools = await fixture.composition.mcpServer.windowMCPTools
        let manageSelection = try XCTUnwrap(
            tools.first { $0.name == MCPWindowToolName.manageSelection }
        )
        let setValue = try await ServerNetworkManager.withConnectionID(connectionID) {
            try await manageSelection([
                "op": .string("set"),
                "paths": .array(paths.map { .string($0.path) }),
                "mode": .string("full"),
                "view": .string("files"),
                "path_display": .string("full"),
                "strict": .bool(true)
            ])
        }
        fixture.projectionFeedbackRecorder.markManageSelectionReturned()
        XCTAssertEqual(try Set(selectedPaths(from: setValue)), Set(paths.map(\.path)))
        XCTAssertEqual(fixture.projectionFeedbackRecorder.injectionCount, 1)

        let expectedSelection = Set(paths.map(\.path))
        XCTAssertEqual(
            try Set(XCTUnwrap(
                fixture.composition.workspaceSessionCommandClient?.snapshot?.selection(
                    workspaceID: fixture.workspaceID,
                    tabID: fixture.tabID
                )
            ).selectedPaths),
            expectedSelection
        )
        XCTAssertEqual(
            try Set(XCTUnwrap(
                fixture.composition.workspaceManager.composeTab(with: fixture.tabID)
            ).selection.selectedPaths),
            expectedSelection
        )
        await fulfillment(
            of: [projectionFeedbackSuppressed, runtimeMetricsReadCompleted],
            timeout: 3
        )
        XCTAssertEqual(selectedFilesEventOrigin, true)
        XCTAssertEqual(fixture.projectionFeedbackRecorder.runtimeMetricsReadBeforeToolReturn, true)
        XCTAssertEqual(
            try Set(XCTUnwrap(fixture.projectionFeedbackRecorder.runtimeMetricsSelection).selectedPaths),
            expectedSelection
        )
        XCTAssertEqual(
            try Set(XCTUnwrap(
                fixture.composition.workspaceSessionCommandClient?.snapshot?.selection(
                    workspaceID: fixture.workspaceID,
                    tabID: fixture.tabID
                )
            ).selectedPaths),
            expectedSelection
        )

        let getValue = try await ServerNetworkManager.withConnectionID(connectionID) {
            try await manageSelection([
                "op": .string("get"),
                "view": .string("files"),
                "path_display": .string("full")
            ])
        }
        XCTAssertEqual(try Set(selectedPaths(from: getValue)), expectedSelection)

        let visibleSelectionWithoutWorktreeMirror = fixture.composition.workspaceFilesViewModel.snapshotSelection()
        XCTAssertTrue(
            visibleSelectionWithoutWorktreeMirror.selectedPaths.isEmpty,
            "worktree-bound MCP selection must remain canonical without active UI mirroring"
        )
        let userSelectionPublished = expectation(
            description: "post-projection user selection published synchronously"
        )
        var didObserveUserSelection = false
        fixture.composition.workspaceManager
            .test_setAuthoritativeProjectionFeedbackEventHandler { source, originatedDuringProjection in
                guard source == .selectedFiles,
                      !originatedDuringProjection,
                      !didObserveUserSelection
                else { return }
                didObserveUserSelection = true
                userSelectionPublished.fulfill()
            }
        let sequenceBeforeUserSelection = try XCTUnwrap(
            fixture.composition.workspaceSessionCommandClient?.snapshot?.snapshotSequence
        )
        await fixture.composition.workspaceFilesViewModel.applyStoredSelection(
            StoredSelection(
                selectedPaths: [paths[0].path],
                codemapAutoEnabled: false
            )
        )
        await fulfillment(of: [userSelectionPublished], timeout: 3)
        let userSelectionProjected = expectation(description: "post-projection user selection projected")
        Task { @MainActor in
            _ = await fixture.composition.workspaceSessionObservationBridge?.waitUntilApplied(
                sequence: sequenceBeforeUserSelection &+ 1
            )
            userSelectionProjected.fulfill()
        }
        await fulfillment(of: [userSelectionProjected], timeout: 3)
        XCTAssertEqual(
            try XCTUnwrap(
                fixture.composition.workspaceSessionCommandClient?.snapshot?.selection(
                    workspaceID: fixture.workspaceID,
                    tabID: fixture.tabID
                )
            ),
            StoredSelection(
                selectedPaths: [paths[0].path],
                codemapAutoEnabled: false
            )
        )
    }

    func testSelectionSliceFeedbackPreservesProgrammaticOriginAndPublishesLaterUserEdit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateCompositionReadinessTests-\(UUID().uuidString)")
            .appendingPathComponent("SliceFeedbackRoot")
        let worktreeRoot = root.deletingLastPathComponent()
            .appendingPathComponent("SliceFeedbackWorktree")
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        let worktreeFileURL = worktreeRoot.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: worktreeFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let source = "struct App {\n    let value = 1\n}\n"
        try source.write(to: fileURL, atomically: true, encoding: .utf8)
        try source.write(to: worktreeFileURL, atomically: true, encoding: .utf8)

        let fixture = try await makeFixture(
            repoPaths: [root.path],
            useProductionAgentRestore: true,
            agentWorktreeBindings: [makeWorktreeBinding(logicalRoot: root, worktreeRoot: worktreeRoot)]
        )
        addTeardownBlock { @MainActor in
            fixture.composition.workspaceManager
                .test_setAuthoritativeProjectionFeedbackEventHandler(nil)
            await fixture.shutdown()
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)
        await fixture.readinessGate.release()
        await fixture.indexGate.release()
        await fixture.composition.workspaceSessionActivationTask?.value
        _ = await fixture.composition.workspaceFileContextStore.awaitAppliedIngress(rootScope: .visibleWorkspace)
        _ = try await fixture.composition.workspaceFileContextStore.loadRoot(
            path: worktreeRoot.path,
            kind: .sessionWorktree
        )
        let locatedFiles = await fixture.composition.workspaceFilesViewModel.findFiles(
            atPaths: [fileURL.path],
            profile: .mcpSelection
        )
        let file = try XCTUnwrap(locatedFiles[fileURL.path])
        let selectedPath = file.standardizedFullPath

        let promptFeedbackDrained = expectation(description: "preexisting prompt feedback drained")
        fixture.composition.workspaceManager
            .test_setAuthoritativeProjectionFeedbackEventHandler { source, _ in
                guard source == .promptText else { return }
                promptFeedbackDrained.fulfill()
            }
        fixture.composition.promptManager.promptText = "slice feedback readiness barrier"
        await fulfillment(of: [promptFeedbackDrained], timeout: 3)
        await fixture.composition.workspaceManager.test_flushUISnapshotCommands()
        fixture.composition.workspaceManager
            .test_setAuthoritativeProjectionFeedbackEventHandler(nil)

        let connectionID = UUID()
        try fixture.composition.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "restored-agent-slice-feedback",
            tabID: fixture.tabID,
            workspaceID: fixture.workspaceID,
            windowID: fixture.windowID
        )
        let tools = await fixture.composition.mcpServer.windowMCPTools
        let manageSelection = try XCTUnwrap(
            tools.first { $0.name == MCPWindowToolName.manageSelection }
        )

        let programmaticSlice = LineRange(start: 1, end: 1)
        _ = try await ServerNetworkManager.withConnectionID(connectionID) {
            try await manageSelection([
                "op": .string("set"),
                "mode": .string("slices"),
                "slices": .array([
                    .object([
                        "path": .string(fileURL.path),
                        "ranges": .array([
                            .object([
                                "start_line": .int(programmaticSlice.start),
                                "end_line": .int(programmaticSlice.end)
                            ])
                        ])
                    ])
                ]),
                "view": .string("files"),
                "path_display": .string("full"),
                "strict": .bool(true)
            ])
        }
        let canonicalProgrammaticSelection = try XCTUnwrap(
            fixture.composition.workspaceSessionCommandClient?.snapshot?.selection(
                workspaceID: fixture.workspaceID,
                tabID: fixture.tabID
            )
        )
        XCTAssertEqual(canonicalProgrammaticSelection.selectedPaths, [selectedPath])
        XCTAssertEqual(canonicalProgrammaticSelection.slices, [selectedPath: [programmaticSlice]])
        XCTAssertTrue(
            fixture.composition.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty,
            "worktree-bound sliced selection must remain canonical without active UI mirroring"
        )

        let programmaticFeedback = expectation(
            description: "programmatic slice feedback remains tagged after debounce"
        )
        var programmaticOrigin: Bool?
        fixture.composition.workspaceManager
            .test_setAuthoritativeProjectionFeedbackEventHandler { source, originatedDuringProgrammaticApply in
                guard source == .selectionSlices, programmaticOrigin == nil else { return }
                programmaticOrigin = originatedDuringProgrammaticApply
                programmaticFeedback.fulfill()
            }
        await fixture.composition.selectionCoordinator.withApplyingSelectionMirror {
            fixture.composition.workspaceFilesViewModel.seedSelectionSlicesForTesting(
                [programmaticSlice],
                for: file
            )
        }
        await fulfillment(of: [programmaticFeedback], timeout: 3)
        await fixture.composition.workspaceManager.test_flushUISnapshotCommands()
        XCTAssertEqual(programmaticOrigin, true)
        XCTAssertEqual(
            try XCTUnwrap(
                fixture.composition.workspaceSessionCommandClient?.snapshot?.selection(
                    workspaceID: fixture.workspaceID,
                    tabID: fixture.tabID
                )
            ),
            canonicalProgrammaticSelection
        )
        XCTAssertTrue(
            fixture.composition.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty,
            "suppressed slice feedback must not synthesize an active UI mirror"
        )

        let userSlice = LineRange(start: 2, end: 2)
        let userFeedback = expectation(description: "later user slice feedback publishes")
        var userOrigin: Bool?
        fixture.composition.workspaceManager
            .test_setAuthoritativeProjectionFeedbackEventHandler { source, originatedDuringProgrammaticApply in
                guard source == .selectionSlices, userOrigin == nil else { return }
                userOrigin = originatedDuringProgrammaticApply
                userFeedback.fulfill()
            }
        let userMutation = try await fixture.composition.workspaceFilesViewModel.setSelectionSlices(
            entries: [.init(path: fileURL.path, ranges: [userSlice])],
            mode: .setPaths,
            persistWorkspace: false
        )
        XCTAssertTrue(userMutation.invalidPaths.isEmpty)
        await fulfillment(of: [userFeedback], timeout: 3)
        await fixture.composition.workspaceManager.test_flushUISnapshotCommands()
        XCTAssertEqual(userOrigin, false)
        let canonicalUserSelection = try XCTUnwrap(
            fixture.composition.workspaceSessionCommandClient?.snapshot?.selection(
                workspaceID: fixture.workspaceID,
                tabID: fixture.tabID
            )
        )
        XCTAssertEqual(canonicalUserSelection.selectedPaths, [selectedPath])
        XCTAssertEqual(canonicalUserSelection.slices, [selectedPath: [userSlice]])
    }

    func testSetStatusWaitsForDelayedAuthoritativeBackgroundTitleProjection() async throws {
        let renamedTitle = "Delayed background title"
        let projectionReached = expectation(description: "renamed snapshot reached assembled observation bridge")
        let projectionGate = CompositionReadinessGate()
        let fixture = try await makeFixture()
        addTeardownBlock { @MainActor in
            fixture.composition.workspaceSessionObservationBridge?.test_setBeforeApply(nil)
            await projectionGate.release()
            await fixture.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }

        try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)
        await fixture.readinessGate.release()
        await fixture.indexGate.release()
        await fixture.composition.workspaceSessionActivationTask?.value
        fixture.composition.workspaceSessionObservationBridge?.test_setBeforeApply { snapshot in
            guard snapshot.workspaces.contains(where: { workspace in
                workspace.composeTabs.contains(where: { $0.name == renamedTitle })
            }) else { return }
            projectionReached.fulfill()
            await projectionGate.wait()
        }

        let client = try XCTUnwrap(fixture.composition.workspaceSessionCommandClient)
        let foregroundTab = ComposeTabState(name: "Foreground decoy")
        let createResult = await client.execute(
            .composeTab(.create(
                workspaceID: fixture.workspaceID,
                tab: foregroundTab,
                makeActive: true
            )),
            source: WorkspaceSessionCommandSource(kind: "test-delayed-set-status-foreground")
        )
        guard case .committed = createResult else {
            return XCTFail("Expected foreground decoy creation, got \(createResult)")
        }
        XCTAssertEqual(fixture.composition.promptManager.activeComposeTabID, foregroundTab.id)

        var setStatusReturned = false
        let setStatusTask = Task { @MainActor in
            defer { setStatusReturned = true }
            return await fixture.composition.agentModeViewModel.renameSession(
                tabID: fixture.tabID,
                to: renamedTitle
            )
        }

        await fulfillment(of: [projectionReached], timeout: 3)
        XCTAssertFalse(setStatusReturned)
        XCTAssertEqual(
            fixture.composition.workspaceManager.composeTabName(with: fixture.tabID),
            "Active"
        )
        XCTAssertEqual(fixture.composition.promptManager.activeComposeTabID, foregroundTab.id)

        await projectionGate.release()
        let result = await setStatusTask.value
        XCTAssertEqual(result, renamedTitle)
        XCTAssertEqual(
            fixture.composition.workspaceManager.composeTabName(with: fixture.tabID),
            renamedTitle
        )
        XCTAssertEqual(
            fixture.composition.promptManager.currentComposeTabs.first(where: { $0.id == fixture.tabID })?.name,
            renamedTitle
        )
        XCTAssertEqual(fixture.composition.promptManager.activeComposeTabID, foregroundTab.id)
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.sidebarSessions(
                for: fixture.composition.promptManager.currentComposeTabs
            ).first(where: { $0.tabID == fixture.tabID })?.title,
            renamedTitle
        )
    }

    func testCancelledSetStatusCompletesCommittedRenameWithoutPartialProjection() async throws {
        let renamedTitle = "Cancelled committed title"
        let delayed = try await makeDelayedSessionRenameFixture(renamedTitle: renamedTitle)
        var renameReturned = false
        let renameTask = Task { @MainActor in
            defer { renameReturned = true }
            return await delayed.fixture.composition.agentModeViewModel.renameSession(
                tabID: delayed.fixture.tabID,
                to: renamedTitle
            )
        }

        await fulfillment(of: [delayed.projectionReached], timeout: 3)
        renameTask.cancel()
        await Task.yield()
        XCTAssertFalse(renameReturned, "caller cancellation must not abandon committed projection")

        await delayed.projectionGate.release()
        let renameResult = await renameTask.value
        XCTAssertNil(renameResult, "the cancelled caller may surface cancellation after convergence")
        try await assertCommittedRenameConverged(delayed, renamedTitle: renamedTitle)
    }

    func testRunTransitionDuringCommittedSetStatusDoesNotRenameDecoyRow() async throws {
        let renamedTitle = "Original session committed title"
        let delayed = try await makeDelayedSessionRenameFixture(renamedTitle: renamedTitle)
        let session = delayed.fixture.composition.agentModeViewModel.session(for: delayed.fixture.tabID)
        let originalRunID = UUID()
        session.runID = originalRunID
        let originalRun = session.beginRunAttempt(source: "test.setStatus.originalRun")
        let renameTask = Task { @MainActor in
            await delayed.fixture.composition.agentModeViewModel.renameSession(
                tabID: delayed.fixture.tabID,
                to: renamedTitle
            )
        }

        await fulfillment(of: [delayed.projectionReached], timeout: 3)
        XCTAssertTrue(session.endRunAttempt(ifCurrent: originalRun, source: "test.setStatus.transition"))
        let replacementRunID = UUID()
        session.runID = replacementRunID
        let replacementRun = session.beginRunAttempt(source: "test.setStatus.replacementRun")

        await delayed.projectionGate.release()
        let renameResult = await renameTask.value
        XCTAssertEqual(renameResult, renamedTitle)
        XCTAssertEqual(session.runID, replacementRunID)
        XCTAssertEqual(session.activeRunAttemptID, replacementRun.attemptID)
        try await assertCommittedRenameConverged(delayed, renamedTitle: renamedTitle)
    }

    private struct DelayedSessionRenameFixture {
        let fixture: Fixture
        let projectionGate: CompositionReadinessGate
        let projectionReached: XCTestExpectation
        let foregroundTab: ComposeTabState
        let decoySessionID: UUID
    }

    private enum DelayedSessionRenameFixtureError: Error {
        case decoyCreationFailed
    }

    private func makeDelayedSessionRenameFixture(
        renamedTitle: String
    ) async throws -> DelayedSessionRenameFixture {
        let projectionReached = expectation(description: "committed rename reached observation bridge")
        let projectionGate = CompositionReadinessGate()
        let fixture = try await makeFixture(useProductionAgentRestore: true)
        addTeardownBlock { @MainActor in
            fixture.composition.workspaceSessionObservationBridge?.test_setBeforeApply(nil)
            await projectionGate.release()
            await fixture.shutdown()
        }

        try await fulfillment(of: [XCTUnwrap(fixture.readinessReached)], timeout: 3)
        await fixture.readinessGate.release()
        await fixture.indexGate.release()
        await fixture.composition.workspaceSessionActivationTask?.value

        let client = try XCTUnwrap(fixture.composition.workspaceSessionCommandClient)
        let decoySessionID = UUID()
        let foregroundTab = ComposeTabState(
            name: "Foreground decoy",
            activeAgentSessionID: decoySessionID
        )
        let createResult = await client.execute(
            .composeTab(.create(
                workspaceID: fixture.workspaceID,
                tab: foregroundTab,
                makeActive: true
            )),
            source: WorkspaceSessionCommandSource(kind: "test-delayed-set-status-decoy")
        )
        guard case .committed = createResult else {
            XCTFail("Expected foreground decoy creation, got \(createResult)")
            throw DelayedSessionRenameFixtureError.decoyCreationFailed
        }

        let viewModel = fixture.composition.agentModeViewModel
        let owner = try XCTUnwrap(viewModel.test_sessionIndexOwner)
        let workspace = try XCTUnwrap(fixture.composition.workspaceManager.workspace(withID: fixture.workspaceID))
        var index = viewModel.test_ownerValidatedSessionIndex
        index[decoySessionID] = makeSessionNamingIndexEntry(
            id: decoySessionID,
            tabID: foregroundTab.id,
            name: foregroundTab.name
        )
        viewModel.test_installSessionIndexSnapshot(
            index,
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )

        fixture.composition.workspaceSessionObservationBridge?.test_setBeforeApply { snapshot in
            guard snapshot.workspaces.contains(where: { workspace in
                workspace.id == fixture.workspaceID
                    && workspace.composeTabs.contains(where: { tab in
                        tab.id == fixture.tabID && tab.name == renamedTitle
                    })
            }) else { return }
            projectionReached.fulfill()
            await projectionGate.wait()
        }
        XCTAssertEqual(fixture.composition.promptManager.activeComposeTabID, foregroundTab.id)
        return DelayedSessionRenameFixture(
            fixture: fixture,
            projectionGate: projectionGate,
            projectionReached: projectionReached,
            foregroundTab: foregroundTab,
            decoySessionID: decoySessionID
        )
    }

    private func assertCommittedRenameConverged(
        _ delayed: DelayedSessionRenameFixture,
        renamedTitle: String
    ) async throws {
        let fixture = delayed.fixture
        XCTAssertEqual(fixture.composition.promptManager.activeComposeTabID, delayed.foregroundTab.id)
        XCTAssertEqual(fixture.composition.workspaceManager.composeTabName(with: fixture.tabID), renamedTitle)
        XCTAssertEqual(
            fixture.composition.promptManager.currentComposeTabs.first(where: { $0.id == fixture.tabID })?.name,
            renamedTitle
        )
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.test_ownerValidatedSessionIndex[fixture.agentSessionID]?.name,
            renamedTitle
        )
        XCTAssertEqual(
            fixture.composition.agentModeViewModel.test_ownerValidatedSessionIndex[delayed.decoySessionID]?.name,
            delayed.foregroundTab.name
        )
        let rows = fixture.composition.agentModeViewModel.sidebarSessions(
            for: fixture.composition.promptManager.currentComposeTabs
        )
        XCTAssertEqual(rows.first(where: { $0.tabID == fixture.tabID })?.title, renamedTitle)
        XCTAssertEqual(
            rows.first(where: { $0.tabID == delayed.foregroundTab.id })?.title,
            delayed.foregroundTab.name
        )
        let workspace = try XCTUnwrap(fixture.composition.workspaceManager.workspace(withID: fixture.workspaceID))
        let persisted = try await AgentSessionDataService.shared.loadAgentSession(
            id: fixture.agentSessionID,
            for: workspace
        )
        XCTAssertEqual(persisted?.name, renamedTitle)
    }

    private func makeSessionNamingIndexEntry(
        id: UUID,
        tabID: UUID,
        name: String
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: name,
            lastUserMessageAt: Date(),
            savedAt: Date(),
            lastRunStateRaw: AgentSessionRunState.idle.rawValue,
            itemCount: 0,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private enum ReadinessInterruption: String, CaseIterable {
        case cancel
        case beginClosing
    }

    private enum PostPublicationInterruption: String, CaseIterable {
        case cancel
        case beginClosing
        case adapterOwnershipLoss
        case lifecycleOwnershipLoss
    }

    private struct Fixture {
        let windowID: Int
        let workspaceID: UUID
        let tabID: UUID
        let agentSessionID: UUID
        let storageRoot: URL
        let container: RepoPromptAppCoreContainer
        let composition: WindowStateComposition
        let recorder: ActivationEventRecorder
        let projectionFeedbackRecorder: ProjectionFeedbackRecorder
        let readinessGate: CompositionReadinessGate
        let indexGate: CompositionReadinessGate
        let initialPresentationGate: CompositionReadinessGate
        let runtimePublicationReadyGate: CompositionReadinessGate
        let readinessReached: XCTestExpectation?
        let initialPresentationReached: XCTestExpectation?
        let runtimePublicationReadyReached: XCTestExpectation?
        let cleanupState: FixtureCleanupState

        @MainActor
        func shutdown() async {
            guard !cleanupState.didShutdown else { return }
            cleanupState.didShutdown = true

            composition.workspaceRuntimeBeginClose()
            composition.workspaceSessionObservationBridge?.stop()
            composition.workspaceSessionActivationTask?.cancel()
            await readinessGate.release()
            await indexGate.release()
            await initialPresentationGate.release()
            await runtimePublicationReadyGate.release()
            await composition.workspaceSessionActivationTask?.value
            await composition.workspaceSessionShutdown()
            await composition.workspaceManager.cancelActiveSessions()
            await composition.agentModeViewModel.prepareForWindowClose()
            composition.workspaceManager.prepareForWindowClose()
        }
    }

    private final class FixtureCleanupState {
        var didShutdown = false
    }

    private static var nextWindowID = -20000

    private func makeFixture(
        gateInitialRestore: Bool = false,
        activateAgentMode: Bool = true,
        gateRuntimePublicationReady: Bool = false,
        repoPaths: [String] = [],
        useProductionAgentRestore: Bool = false,
        agentWorktreeBindings: [AgentSessionWorktreeBinding] = [],
        injectProjectionSelectionFeedback: Bool = false
    ) async throws -> Fixture {
        let windowID = Self.nextWindowID
        Self.nextWindowID -= 1

        let tabID = UUID()
        let sessionID = UUID()
        let workspaceID = UUID()
        let workspaceName = "Readiness"
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateCompositionReadinessTests-\(UUID().uuidString)")
        let workspaceStorage = storageRoot
            .appendingPathComponent("Workspace-\(workspaceName)-\(workspaceID.uuidString)")
        let workspace = WorkspaceModel(
            id: workspaceID,
            name: workspaceName,
            repoPaths: repoPaths,
            customStoragePath: workspaceStorage,
            composeTabs: [
                ComposeTabState(
                    id: tabID,
                    name: "Active",
                    activeAgentSessionID: sessionID
                )
            ],
            activeComposeTabID: tabID
        )
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try writeIndexedWorkspace(workspace, baseRoot: storageRoot)

        let payload = makeHydrationPayload(
            sessionID: sessionID,
            tabID: tabID,
            worktreeBindings: agentWorktreeBindings
        )
        if useProductionAgentRestore {
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                payload.persistedSession,
                for: workspace
            )
        }
        let recorder = ActivationEventRecorder()
        let projectionFeedbackRecorder = ProjectionFeedbackRecorder()
        var runtimeMetricsSelectionRead: (@MainActor () -> StoredSelection?)?
        let readinessGate = CompositionReadinessGate()
        let indexGate = CompositionReadinessGate()
        let initialPresentationGate = CompositionReadinessGate()
        let runtimePublicationReadyGate = CompositionReadinessGate()
        let readinessReached = gateInitialRestore ? nil : expectation(description: "assembled readiness reached")
        let initialPresentationReached = gateInitialRestore
            ? expectation(description: "initial active-session presentation reached")
            : nil
        let runtimePublicationReadyReached = gateRuntimePublicationReady
            ? expectation(description: "runtime publication ready returned")
            : nil
        let hooks = WindowStateCompositionTestHooks(
            configureAgentModeViewModel: { viewModel in
                if !useProductionAgentRestore {
                    viewModel.test_setPersistedHydrationPreparer { request in
                        recorder.recordHydrationRequest()
                        return request.sessionID == sessionID ? payload : nil
                    }
                    viewModel.test_setSidebarIndexBuilders(
                        prioritized: { _ in
                            AgentSessionSidebarBuildResult(
                                entriesBySessionID: [:],
                                preferredSessionIDByTabID: [:]
                            )
                        },
                        stream: { _, _ in
                            AsyncThrowingStream { continuation in
                                Task {
                                    await indexGate.wait()
                                    continuation.finish()
                                }
                            }
                        }
                    )
                }
                viewModel.test_setBeforeInitialActiveSessionPresentation {
                    recorder.recordInitialActiveSessionPresentation()
                    if gateInitialRestore {
                        initialPresentationReached?.fulfill()
                        await initialPresentationGate.wait()
                    }
                }
                if activateAgentMode {
                    viewModel.setAgentModeActive(true)
                }
            },
            recordActivationEvent: { recorder.record($0) },
            waitAfterInitialActiveSessionRestore: {
                readinessReached?.fulfill()
                await readinessGate.wait()
            },
            waitAfterRuntimePublicationReady: {
                guard gateRuntimePublicationReady else { return }
                runtimePublicationReadyReached?.fulfill()
                await runtimePublicationReadyGate.wait()
            },
            afterAuthoritativeWorkspaceProjection: { _, files, snapshot in
                guard injectProjectionSelectionFeedback,
                      let activeWorkspaceID = snapshot.activeWorkspaceID,
                      let activeWorkspace = snapshot.workspaces.first(where: { $0.id == activeWorkspaceID }),
                      let activeTabID = activeWorkspace.activeComposeTabID,
                      let activeSelection = snapshot.selection(
                          workspaceID: activeWorkspaceID,
                          tabID: activeTabID
                      ),
                      !activeSelection.selectedPaths.isEmpty
                else { return }

                guard projectionFeedbackRecorder.beginInjection() else { return }
                files.test_emitEmptySelectionForAuthoritativeProjectionFeedback()
                let visibleSelection = files.snapshotSelection()
                XCTAssertTrue(
                    visibleSelection.selectedPaths.isEmpty,
                    "expected stale empty UI selection, got \(visibleSelection.selectedPaths)"
                )

                guard projectionFeedbackRecorder.beginRuntimeMetricsRead() else { return }
                Task { @MainActor in
                    projectionFeedbackRecorder.recordRuntimeMetricsSelection(
                        runtimeMetricsSelectionRead?()
                    )
                }
            }
        )

        let containerDefaults = try XCTUnwrap(
            UserDefaults(suiteName: "WindowStateCompositionReadinessTests.\(UUID().uuidString)")
        )
        let container = RepoPromptAppCoreContainer(
            userDefaults: containerDefaults,
            debugOverride: .core,
            debugRoutingOverride: .lifecycleRegistry
        )

        let defaults = UserDefaults.standard
        let previousStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        defaults.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let composition = WindowStateCompositionFactory.make(
            windowID: windowID,
            deferredInitialAgentSystemWorkspaceRefresh: false,
            sharedMCPService: MCPService(),
            appCoreContainer: container,
            loadStoredAPISettingsDataOnInit: false,
            testHooks: hooks
        )
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let runtimeMetricsSelectionCoordinator = composition.selectionCoordinator
        runtimeMetricsSelectionRead = {
            AgentModeRuntimeMetricsSelectionResolver.selection(
                for: tabID,
                selectionCoordinator: runtimeMetricsSelectionCoordinator
            )
        }
        if let previousStoragePath {
            defaults.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
        } else {
            defaults.removeObject(forKey: "GlobalCustomStorageURL")
        }

        let fixture = Fixture(
            windowID: windowID,
            workspaceID: workspace.id,
            tabID: tabID,
            agentSessionID: sessionID,
            storageRoot: storageRoot,
            container: container,
            composition: composition,
            recorder: recorder,
            projectionFeedbackRecorder: projectionFeedbackRecorder,
            readinessGate: readinessGate,
            indexGate: indexGate,
            initialPresentationGate: initialPresentationGate,
            runtimePublicationReadyGate: runtimePublicationReadyGate,
            readinessReached: readinessReached,
            initialPresentationReached: initialPresentationReached,
            runtimePublicationReadyReached: runtimePublicationReadyReached,
            cleanupState: FixtureCleanupState()
        )
        addTeardownBlock { @MainActor in
            await fixture.shutdown()
            try? FileManager.default.removeItem(at: fixture.storageRoot)
        }
        return fixture
    }

    private func selectedPaths(from value: Value) throws -> [String] {
        let object = try XCTUnwrap(value.objectValue)
        let files = try XCTUnwrap(object["files"]?.arrayValue)
        return try files.map { file in
            try XCTUnwrap(file.objectValue?["path"]?.stringValue)
        }
    }

    private func makeWorktreeBinding(
        logicalRoot: URL,
        worktreeRoot: URL
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "restored-agent-selection-binding",
            repositoryID: "restored-agent-selection-repository",
            repoKey: logicalRoot.path,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: "restored-agent-selection-worktree",
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "test/restored-agent-selection",
            head: "abcdef1234567890",
            visualLabel: "restored",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makeHydrationPayload(
        sessionID: UUID,
        tabID: UUID,
        worktreeBindings: [AgentSessionWorktreeBinding] = []
    ) -> AgentSessionHydrationPayload {
        let items = [
            AgentChatItem.user("restored user", sequenceIndex: 0),
            AgentChatItem.assistant("restored assistant", sequenceIndex: 1)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .idle,
            nextSequenceIndex: 2,
            compact: false
        )
        let selection = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: nil,
            modelRaw: nil
        )
        let savedAt = Date(timeIntervalSince1970: 100)
        let persistedSession = AgentSession(
            id: sessionID,
            composeTabID: tabID,
            name: "Restored",
            savedAt: savedAt,
            transcript: transcript,
            itemCount: items.count,
            lastUserMessageAt: items[0].timestamp,
            agentKind: selection.agent.rawValue,
            agentModel: selection.modelRaw,
            lastRunState: AgentSessionRunState.idle.rawValue,
            autoEditEnabled: false,
            worktreeBindings: worktreeBindings
        )
        return AgentSessionHydrationPayload(
            sessionID: sessionID,
            persistedSession: persistedSession,
            canonicalLiveItems: items,
            transcript: transcript,
            builtPresentation: AgentSessionRestoreSupport.buildTranscriptPresentation(
                from: transcript,
                sourceItems: items,
                selectedAgent: selection.agent,
                previousPerformanceSnapshot: .empty,
                projectionProtection: .none,
                isCompressedHistoryRevealed: false,
                isColdLoad: true
            ),
            normalizedRunState: .idle,
            normalizedSelection: selection,
            lastUserMessageAt: items[0].timestamp,
            restoredIndexEntry: AgentSessionRestoreSupport.buildSidebarIndexEntry(
                from: persistedSession,
                tabID: tabID,
                name: "Restored",
                lastUserMessageAt: items[0].timestamp,
                itemCount: items.count
            ),
            needsReloadMigrationSave: false
        )
    }

    private func writeIndexedWorkspace(
        _ workspace: WorkspaceModel,
        baseRoot: URL
    ) throws {
        let workspaceDirectory = baseRoot
            .appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)")
        try FileManager.default.createDirectory(
            at: workspaceDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(workspace).write(
            to: workspaceDirectory.appendingPathComponent("workspace.json"),
            options: .atomic
        )
        let entry = WorkspaceIndexEntry(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath,
            isSystemWorkspace: workspace.isSystemWorkspace,
            isHiddenInMenus: workspace.isHiddenInMenus
        )
        try JSONEncoder().encode([entry]).write(
            to: baseRoot.appendingPathComponent("workspacesIndex.json"),
            options: .atomic
        )
    }
}

@MainActor
private final class ActivationEventRecorder {
    private(set) var events: [WindowStateCompositionActivationEvent] = []
    private(set) var didRequestHydration = false
    private(set) var didReachInitialActiveSessionPresentation = false

    func record(_ event: WindowStateCompositionActivationEvent) {
        events.append(event)
    }

    func recordHydrationRequest() {
        didRequestHydration = true
    }

    func recordInitialActiveSessionPresentation() {
        didReachInitialActiveSessionPresentation = true
    }
}

@MainActor
private final class ProjectionFeedbackRecorder {
    private(set) var injectionCount = 0
    private(set) var runtimeMetricsSelection: StoredSelection?
    private(set) var runtimeMetricsReadBeforeToolReturn: Bool?
    private var runtimeMetricsReadScheduled = false
    private var manageSelectionReturned = false
    private var runtimeMetricsReadHandler: ((StoredSelection?) -> Void)?

    func beginInjection() -> Bool {
        guard injectionCount == 0 else { return false }
        injectionCount = 1
        return true
    }

    func beginRuntimeMetricsRead() -> Bool {
        guard !runtimeMetricsReadScheduled else { return false }
        runtimeMetricsReadScheduled = true
        return true
    }

    func setRuntimeMetricsReadHandler(_ handler: @escaping (StoredSelection?) -> Void) {
        runtimeMetricsReadHandler = handler
    }

    func recordRuntimeMetricsSelection(_ selection: StoredSelection?) {
        runtimeMetricsSelection = selection
        runtimeMetricsReadBeforeToolReturn = !manageSelectionReturned
        runtimeMetricsReadHandler?(selection)
    }

    func markManageSelectionReturned() {
        manageSelectionReturned = true
    }
}

private actor CompositionReadinessGate {
    private var isReleased = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        guard !isReleased, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isReleased, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func release() {
        isReleased = true
        let currentWaiters = Array(waiters.values)
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume()
    }
}
