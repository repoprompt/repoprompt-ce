#if DEBUG
    import Combine
    import CoreServices
    import MCP
    @testable import RepoPrompt
    import RepoPromptShared
    import XCTest

    final class MCPReadSearchLatencyDiagnosticsGuardTests: XCTestCase {
        @MainActor
        func testReadFileAutoSelectionProbeRegistryRemovesOnTakeAndReleasesOnCallerCancelExpiryAndContextCancellation() async throws {
            let key = MCPReadFileAutoSelectionCoordinator.ContextKey(
                windowID: 1,
                workspaceID: UUID(),
                tabID: UUID(),
                route: .bound(connectionID: UUID(), runID: UUID()),
                bindingGeneration: 1
            )
            let coordinator = MCPReadFileAutoSelectionCoordinator(
                isContextCurrent: { $0 == key },
                applyCanonical: { _, _ in .unchanged },
                applyMirror: { _ in }
            )
            XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
            let drainResult = await coordinator.drain(.canonicalSelection, for: key)
            XCTAssertEqual(drainResult, .completed)
            let baseline = try XCTUnwrap(coordinator.debugContextSnapshot(for: key))
            let target = MCPServerViewModel.DebugReadFileAutoSelectionTarget(
                connectionID: UUID(),
                runID: UUID(),
                agentSessionID: UUID(),
                workspaceID: key.workspaceID,
                tabID: key.tabID,
                route: key.route.diagnosticScope,
                bindingGeneration: key.bindingGeneration,
                contextKey: key
            )
            let releases = ProbeReleaseRecorder()
            let registry = MCPReadFileAutoSelectionProbeRegistry()

            func entry(
                expiryMilliseconds: Int,
                target entryTarget: MCPServerViewModel.DebugReadFileAutoSelectionTarget? = nil
            ) -> MCPReadFileAutoSelectionProbeRegistry.Entry {
                MCPReadFileAutoSelectionProbeRegistry.Entry(
                    probeID: UUID(),
                    createdAt: Date(),
                    expiryMilliseconds: expiryMilliseconds,
                    windowID: 1,
                    serverIdentity: ObjectIdentifier(coordinator),
                    target: entryTarget ?? target,
                    baseline: baseline,
                    forceAuthoritative: true,
                    releaseForceAuthoritative: { await releases.record() }
                )
            }

            let taken = entry(expiryMilliseconds: 1000)
            let insertedTaken = await registry.insert(taken)
            XCTAssertTrue(insertedTaken)
            let retainedTakenEntry = await registry.take(taken.probeID)
            let takenEntry = try XCTUnwrap(retainedTakenEntry)
            await takenEntry.releaseForceAuthoritative()
            let containsTaken = await registry.containsForTesting(taken.probeID)
            let releaseCountAfterTake = await releases.count()
            XCTAssertFalse(containsTaken)
            XCTAssertEqual(releaseCountAfterTake, 1)

            let cancelled = entry(expiryMilliseconds: 1000)
            let insertedCancelled = await registry.insert(cancelled)
            XCTAssertTrue(insertedCancelled)
            let cancelledEntry = await registry.cancel(cancelled.probeID)
            let containsCancelled = await registry.containsForTesting(cancelled.probeID)
            let releaseCountAfterCancel = await releases.count()
            XCTAssertNotNil(cancelledEntry)
            XCTAssertFalse(containsCancelled)
            XCTAssertEqual(releaseCountAfterCancel, 2)

            let expired = entry(expiryMilliseconds: 1000)
            let insertedExpired = await registry.insert(expired)
            XCTAssertTrue(insertedExpired)
            await registry.expireForTesting(expired.probeID)
            let containsExpired = await registry.containsForTesting(expired.probeID)
            let releaseCountAfterExpiry = await releases.count()
            XCTAssertFalse(containsExpired)
            XCTAssertEqual(releaseCountAfterExpiry, 3)

            let lifecycleEntry = entry(expiryMilliseconds: 1000)
            let insertedLifecycle = await registry.insert(lifecycleEntry)
            XCTAssertTrue(insertedLifecycle)
            let otherKey = MCPReadFileAutoSelectionCoordinator.ContextKey(
                windowID: key.windowID,
                workspaceID: key.workspaceID,
                tabID: UUID(),
                route: key.route,
                bindingGeneration: key.bindingGeneration
            )
            let otherTarget = MCPServerViewModel.DebugReadFileAutoSelectionTarget(
                connectionID: target.connectionID,
                runID: target.runID,
                agentSessionID: target.agentSessionID,
                workspaceID: otherKey.workspaceID,
                tabID: otherKey.tabID,
                route: otherKey.route.diagnosticScope,
                bindingGeneration: otherKey.bindingGeneration,
                contextKey: otherKey
            )
            let otherEntry = entry(expiryMilliseconds: 1000, target: otherTarget)
            let insertedOther = await registry.insert(otherEntry)
            XCTAssertTrue(insertedOther)

            await registry.cancel(
                serverIdentity: lifecycleEntry.serverIdentity,
                contextKey: key
            )
            let containsLifecycle = await registry.containsForTesting(lifecycleEntry.probeID)
            let containsOther = await registry.containsForTesting(otherEntry.probeID)
            let releaseCountAfterContextCancellation = await releases.count()
            XCTAssertFalse(containsLifecycle)
            XCTAssertTrue(containsOther)
            XCTAssertEqual(releaseCountAfterContextCancellation, 4)
            _ = await registry.cancel(otherEntry.probeID)
            let finalReleaseCount = await releases.count()
            XCTAssertEqual(finalReleaseCount, 5)

            let workspaceID = try XCTUnwrap(target.workspaceID)
            func applyEditsState(
                probeID: UUID = UUID(),
                target entryTarget: MCPServerViewModel.DebugReadFileAutoSelectionTarget? = nil,
                expectsSyntheticModification: Bool = true
            ) -> MCPApplyEditsRebaseProbeState {
                let resolvedTarget = entryTarget ?? target
                let storeSnapshot = WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot(
                    rootID: UUID(),
                    rootLifetimeID: UUID(),
                    rootToken: UUID(),
                    rootPath: "/tmp/worktree",
                    fileID: UUID(),
                    fullPath: "/tmp/worktree/fixture.swift",
                    relativePath: "fixture.swift",
                    isSessionWorktree: true,
                    producedAppliedIndexGeneration: 10
                )
                return MCPApplyEditsRebaseProbeState(
                    probeID: probeID,
                    createdAt: Date(),
                    expiryMilliseconds: 1000,
                    deadlineMilliseconds: 5000,
                    windowID: 1,
                    serverIdentity: ObjectIdentifier(coordinator),
                    target: resolvedTarget,
                    rootScope: .sessionBoundWorkspace(
                        canonicalRootPaths: [],
                        physicalRootPaths: [storeSnapshot.rootPath]
                    ),
                    rootID: storeSnapshot.rootID,
                    rootLifetimeID: storeSnapshot.rootLifetimeID,
                    rootToken: storeSnapshot.rootToken,
                    fileID: storeSnapshot.fileID,
                    physicalPath: storeSnapshot.fullPath,
                    relativePath: storeSnapshot.relativePath,
                    selectionPathCandidates: [storeSnapshot.fullPath, storeSnapshot.relativePath],
                    expectedFileSHA256: String(repeating: "0", count: 64),
                    expectedByteCount: 1,
                    expectedLineCount: 1,
                    expectedRanges: [LineRange(start: 1, end: 1)],
                    expectsSyntheticModification: expectsSyntheticModification,
                    baselineStore: storeSnapshot,
                    baselineProjection: WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot(
                        handledGeneration: 10,
                        registrationGeneration: 2,
                        hasPendingRebaseTask: false
                    ),
                    baselineSelection: WorkspaceManagerViewModel.ApplyEditsRebaseProbeSelectionSnapshot(
                        workspaceID: workspaceID,
                        tabID: resolvedTarget.tabID,
                        selectionRevision: 5,
                        ranges: [LineRange(start: 1, end: 1)]
                    )
                )
            }

            let applyRegistry = MCPApplyEditsRebaseProbeRegistry()
            MCPApplyEditsRebaseProbeRecorder.resetForTesting()
            let takenState = applyEditsState()
            let takenApplyEntry = MCPApplyEditsRebaseProbeRegistry.Entry(
                probeID: takenState.probeID,
                createdAt: Date(),
                expiryMilliseconds: 1000,
                serverIdentity: takenState.serverIdentity,
                contextKey: target.contextKey,
                state: takenState
            )
            let insertedTakenApplyProbe = await applyRegistry.insert(takenApplyEntry)
            XCTAssertTrue(insertedTakenApplyProbe)
            XCTAssertEqual(MCPApplyEditsRebaseProbeRecorder.activeCountForTesting(), 1)
            let retainedTakenApplyProbe = await applyRegistry.take(takenState.probeID)
            XCTAssertNotNil(retainedTakenApplyProbe)
            let containsTakenApplyProbe = await applyRegistry.containsForTesting(takenState.probeID)
            XCTAssertFalse(containsTakenApplyProbe)
            XCTAssertEqual(MCPApplyEditsRebaseProbeRecorder.activeCountForTesting(), 1, "Drain owns recorder cleanup after taking the registry entry.")
            MCPApplyEditsRebaseProbeRecorder.unregister(takenState.probeID)

            let boundedState = applyEditsState()
            let boundedEntry = MCPApplyEditsRebaseProbeRegistry.Entry(
                probeID: boundedState.probeID,
                createdAt: Date(),
                expiryMilliseconds: 1000,
                serverIdentity: boundedState.serverIdentity,
                contextKey: target.contextKey,
                state: boundedState
            )
            let insertedBoundedApplyProbe = await applyRegistry.insert(boundedEntry)
            XCTAssertTrue(insertedBoundedApplyProbe)
            MCPApplyEditsRebaseProbeRecorder.recordServicePublication(
                rootToken: boundedState.rootToken,
                source: .syntheticMutation,
                deltas: [.fileModified("fixture.swift", nil)]
            )
            for index in 0 ..< 70 {
                boundedState.increment("test_events", event: "unsafe / payload \(index)")
            }
            let boundedSnapshot = boundedState.snapshot()
            XCTAssertEqual(boundedSnapshot.events.count, 64)
            XCTAssertGreaterThan(boundedSnapshot.eventOverflowCount, 0)
            XCTAssertEqual(boundedSnapshot.counters["service_publications_syntheticMutation"], 1)
            XCTAssertTrue(boundedSnapshot.events.allSatisfy { !$0.category.contains("/") && $0.category.count <= 48 })
            let cancelledBoundedApplyProbe = await applyRegistry.cancel(boundedState.probeID)
            XCTAssertNotNil(cancelledBoundedApplyProbe)
            XCTAssertEqual(MCPApplyEditsRebaseProbeRecorder.activeCountForTesting(), 0)

            let isolatedState = applyEditsState()
            let unrelatedState = applyEditsState(target: otherTarget)
            XCTAssertTrue(MCPApplyEditsRebaseProbeRecorder.register(isolatedState))
            XCTAssertTrue(MCPApplyEditsRebaseProbeRecorder.register(unrelatedState))
            let childConnectionID = UUID()
            let requestIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .number(77),
                connectionID: childConnectionID.uuidString,
                connectionGeneration: 4,
                requestOrdinal: 9
            )
            MCPApplyEditsRebaseProbeRecorder.recordApplyEditsInvocation(
                connectionID: childConnectionID,
                workspaceID: target.workspaceID,
                tabID: target.tabID,
                physicalPath: isolatedState.physicalPath,
                requestIdentity: requestIdentity
            )
            MCPApplyEditsRebaseProbeRecorder.recordApplyEditsOutcome(
                connectionID: childConnectionID,
                workspaceID: target.workspaceID,
                tabID: target.tabID,
                physicalPath: isolatedState.physicalPath,
                requestIdentity: requestIdentity,
                editsApplied: 1,
                outcome: "success"
            )
            XCTAssertEqual(isolatedState.snapshot().counters["apply_edits_outcomes"], 1)
            XCTAssertEqual(isolatedState.snapshot().counters["apply_edits_child_connection_routes"], 1)
            XCTAssertNil(unrelatedState.snapshot().counters["apply_edits_outcomes"])

            XCTAssertEqual(
                isolatedState.minimumStableEvidenceFailure(
                    snapshot: isolatedState.snapshot(),
                    store: isolatedState.baselineStore,
                    projection: isolatedState.baselineProjection
                ),
                "missing_service_publications_syntheticMutation"
            )
            for (counter, amount) in [
                ("service_publications_syntheticMutation", UInt64(1)),
                ("publisher_ingress_modifications_syntheticMutation", 1),
                ("store_modification_publications", 1),
                ("applied_index_modification_events", 2),
                ("projection_modification_events", 2),
                ("rebase_registrations", 2),
                ("rebase_replacements", 1),
                ("rebase_executions", 1),
                ("rebase_successful_completions", 1)
            ] {
                isolatedState.increment(counter, by: amount)
            }
            let advancedStore = WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot(
                rootID: isolatedState.baselineStore.rootID,
                rootLifetimeID: isolatedState.baselineStore.rootLifetimeID,
                rootToken: isolatedState.baselineStore.rootToken,
                rootPath: isolatedState.baselineStore.rootPath,
                fileID: isolatedState.baselineStore.fileID,
                fullPath: isolatedState.baselineStore.fullPath,
                relativePath: isolatedState.baselineStore.relativePath,
                isSessionWorktree: true,
                producedAppliedIndexGeneration: isolatedState.baselineStore.producedAppliedIndexGeneration + 2
            )
            let advancedProjection = WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot(
                handledGeneration: isolatedState.baselineProjection.handledGeneration + 2,
                registrationGeneration: isolatedState.baselineProjection.registrationGeneration + 2,
                hasPendingRebaseTask: false
            )
            XCTAssertNil(isolatedState.minimumStableEvidenceFailure(
                snapshot: isolatedState.snapshot(),
                store: advancedStore,
                projection: advancedProjection
            ))

            let optimizedState = applyEditsState(expectsSyntheticModification: false)
            optimizedState.bindRequestIdentity(requestIdentity)
            for (counter, amount) in [
                ("apply_edits_invocations", UInt64(1)),
                ("apply_edits_outcomes", 1),
                ("apply_edits_applied", 1),
                ("service_publications_watcher", 1),
                ("publisher_ingress_modifications_watcher", 1),
                ("store_modification_publications", 1),
                ("applied_index_modification_events", 2),
                ("projection_modification_events", 2),
                ("rebase_registrations", 2),
                ("rebase_replacements", 1),
                ("rebase_executions", 1),
                ("rebase_successful_completions", 1)
            ] {
                optimizedState.increment(counter, by: amount)
            }
            let optimizedStore = WorkspaceFileContextStore.ApplyEditsRebaseProbePathSnapshot(
                rootID: optimizedState.baselineStore.rootID,
                rootLifetimeID: optimizedState.baselineStore.rootLifetimeID,
                rootToken: optimizedState.baselineStore.rootToken,
                rootPath: optimizedState.baselineStore.rootPath,
                fileID: optimizedState.baselineStore.fileID,
                fullPath: optimizedState.baselineStore.fullPath,
                relativePath: optimizedState.baselineStore.relativePath,
                isSessionWorktree: true,
                producedAppliedIndexGeneration: optimizedState.baselineStore.producedAppliedIndexGeneration + 2
            )
            let optimizedProjection = WorkspaceFilesViewModel.ApplyEditsRebaseProbePathSnapshot(
                handledGeneration: optimizedState.baselineProjection.handledGeneration + 2,
                registrationGeneration: optimizedState.baselineProjection.registrationGeneration + 2,
                hasPendingRebaseTask: false
            )
            XCTAssertNil(optimizedState.minimumStableEvidenceFailure(
                snapshot: optimizedState.snapshot(),
                store: optimizedStore,
                projection: optimizedProjection
            ))
            optimizedState.increment("service_publications_syntheticMutation")
            XCTAssertEqual(
                optimizedState.minimumStableEvidenceFailure(
                    snapshot: optimizedState.snapshot(),
                    store: optimizedStore,
                    projection: optimizedProjection
                ),
                "unexpected_service_publications_syntheticMutation"
            )

            let exactResponseEvent = MCPResponseDeliveryTraceEvent(
                layer: "transport",
                phase: "transport_write_completed",
                requestIdentity: requestIdentity
            )
            let unrelatedResponseEvent = MCPResponseDeliveryTraceEvent(
                layer: "transport",
                phase: "transport_write_completed",
                requestIdentity: MCPRequestTimelineIdentity(
                    jsonRPCRequestID: .number(78),
                    connectionID: target.connectionID.uuidString,
                    connectionGeneration: 4,
                    requestOrdinal: 10
                )
            )
            XCTAssertNil(ServerNetworkManager.debugApplyEditsProbeResponseEvent(
                for: nil,
                events: [exactResponseEvent]
            ))
            XCTAssertEqual(ServerNetworkManager.debugApplyEditsProbeResponseEvent(
                for: requestIdentity,
                events: [unrelatedResponseEvent, exactResponseEvent]
            ), exactResponseEvent)
            let decodedApplyEditsEvent = MCPResponseDeliveryTraceEvent(
                layer: "app_sdk",
                phase: "sdk_decode_completed",
                tool: "apply_edits",
                requestIdentity: requestIdentity
            )
            XCTAssertEqual(
                MCPApplyEditsRebaseProbeRecorder.latestApplyEditsRequestIdentity(
                    connectionID: childConnectionID,
                    events: [unrelatedResponseEvent, decodedApplyEditsEvent]
                ),
                requestIdentity
            )
            MCPApplyEditsRebaseProbeRecorder.unregister(isolatedState.probeID)
            MCPApplyEditsRebaseProbeRecorder.unregister(unrelatedState.probeID)
            XCTAssertEqual(MCPApplyEditsRebaseProbeRecorder.activeCountForTesting(), 0)

            let sourceTabState = applyEditsState()
            XCTAssertTrue(MCPApplyEditsRebaseProbeRecorder.register(sourceTabState))
            let sourceTabRequestIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .number(79),
                connectionID: childConnectionID.uuidString,
                connectionGeneration: 4,
                requestOrdinal: 11
            )
            MCPApplyEditsRebaseProbeRecorder.recordApplyEditsInvocation(
                connectionID: childConnectionID,
                workspaceID: nil,
                tabID: UUID(),
                physicalPath: sourceTabState.physicalPath,
                requestIdentity: sourceTabRequestIdentity
            )
            MCPApplyEditsRebaseProbeRecorder.recordApplyEditsOutcome(
                connectionID: childConnectionID,
                workspaceID: nil,
                tabID: UUID(),
                physicalPath: sourceTabState.physicalPath,
                requestIdentity: sourceTabRequestIdentity,
                editsApplied: 1,
                outcome: "success"
            )
            XCTAssertEqual(sourceTabState.snapshot().counters["apply_edits_source_workspace_routes"], 1)
            XCTAssertEqual(sourceTabState.snapshot().counters["apply_edits_source_tab_routes"], 1)
            XCTAssertEqual(sourceTabState.snapshot().counters["apply_edits_outcomes"], 1)
            MCPApplyEditsRebaseProbeRecorder.unregister(sourceTabState.probeID)

            let expiringState = applyEditsState()
            let expiringEntry = MCPApplyEditsRebaseProbeRegistry.Entry(
                probeID: expiringState.probeID,
                createdAt: Date(),
                expiryMilliseconds: 1000,
                serverIdentity: expiringState.serverIdentity,
                contextKey: target.contextKey,
                state: expiringState
            )
            let insertedExpiringApplyProbe = await applyRegistry.insert(expiringEntry)
            XCTAssertTrue(insertedExpiringApplyProbe)
            await applyRegistry.expireForTesting(expiringState.probeID)
            let containsExpiredApplyProbe = await applyRegistry.containsForTesting(expiringState.probeID)
            XCTAssertFalse(containsExpiredApplyProbe)
            XCTAssertEqual(MCPApplyEditsRebaseProbeRecorder.activeCountForTesting(), 0)

            let contextState = applyEditsState()
            let contextEntry = MCPApplyEditsRebaseProbeRegistry.Entry(
                probeID: contextState.probeID,
                createdAt: Date(),
                expiryMilliseconds: 1000,
                serverIdentity: contextState.serverIdentity,
                contextKey: target.contextKey,
                state: contextState
            )
            let insertedContextApplyProbe = await applyRegistry.insert(contextEntry)
            XCTAssertTrue(insertedContextApplyProbe)
            await applyRegistry.cancel(serverIdentity: contextState.serverIdentity, contextKey: target.contextKey)
            let containsContextApplyProbe = await applyRegistry.containsForTesting(contextState.probeID)
            XCTAssertFalse(containsContextApplyProbe)
            XCTAssertEqual(MCPApplyEditsRebaseProbeRecorder.activeCountForTesting(), 0)
        }

        private var temporaryRoots = FileSystemTemporaryRoots()

        override func tearDown() {
            EditFlowPerf.resetDebugCaptureForTesting()
            temporaryRoots.removeAll()
            super.tearDown()
        }

        @MainActor
        func testRuntimeSnapshotHiddenOperationsExposeBoundedAggregateAndDispatcherContracts() async throws {
            let sourceLabel = "testHiddenDispatcherRecognizesReadSearchCaptureOperations"
            try XCTContext.runActivity(named: sourceLabel) { _ in
                try scenarioHiddenDispatcherRecognizesReadSearchCaptureOperations()
            }

            let runtimeLabel = "testRuntimeSnapshotHiddenOperationValidatesBoundsAndReturnsAggregateShape"
            try await scenarioRuntimeSnapshotHiddenOperationValidatesBoundsAndReturnsAggregateShape(caseLabel: runtimeLabel)
        }

        @MainActor
        func testRuntimeSnapshotProjectsBoundedActiveCoalescedAndPendingBarrierState() async throws {
            let sourceLabel = "testReadSearchBarrierDiagnosticsExposeBoundedPendingSuccessorState"
            try XCTContext.runActivity(named: sourceLabel) { _ in
                try scenarioReadSearchBarrierDiagnosticsExposeBoundedPendingSuccessorState()
            }

            let runtimeLabel = "testRuntimeSnapshotProjectsActiveAndCoalescedPendingBarrierState"
            try await scenarioRuntimeSnapshotProjectsActiveAndCoalescedPendingBarrierState(caseLabel: runtimeLabel)
        }

        func testMCPDispatchAndCatalogRecorderInventoryPreservesSanitizedStageContracts() throws {
            try withIsolatedCaptureCase("testSearchDTOBuildNestedRecorderCapturesOnlyCoarseSanitizedDimensions") {
                scenarioSearchDTOBuildNestedRecorderCapturesOnlyCoarseSanitizedDimensions()
            }
            try withIsolatedCaptureCase("testNewReadDispatchStageRecorderCapturesToolDimensionAndFinishes") {
                try scenarioNewReadDispatchStageRecorderCapturesToolDimensionAndFinishes()
            }
            try withIsolatedCaptureCase("testServiceToolLookupInnerAttributionRecorderUsesStaticEmptyDimensions") {
                scenarioServiceToolLookupInnerAttributionRecorderUsesStaticEmptyDimensions()
            }
            try withIsolatedCaptureCase("testMCPWindowToolCatalogLifecycleAttributionRecorderUsesStaticEmptyDimensions") {
                scenarioMCPWindowToolCatalogLifecycleAttributionRecorderUsesStaticEmptyDimensions()
            }
            try withIsolatedCaptureCase("testOuterEnvelopeRecorderCapturesCombinedToolAndSanitizedOutcomes") {
                try scenarioOuterEnvelopeRecorderCapturesCombinedToolAndSanitizedOutcomes()
            }
        }

        func testReadAutoSelectionRecorderInventoryPreservesSanitizedStageAndLifecycleContracts() throws {
            try withIsolatedCaptureCase("testProviderReadRecorderCapturesTotalAndSanitizedAutoSelectOutcomes") {
                try scenarioProviderReadRecorderCapturesTotalAndSanitizedAutoSelectOutcomes()
            }
            try withIsolatedCaptureCase("testProviderAutoSelectNestedRecorderCapturesRepresentativeSanitizedOutcomes") {
                scenarioProviderAutoSelectNestedRecorderCapturesRepresentativeSanitizedOutcomes()
            }
            try withIsolatedCaptureCase("testReadFileAutoSelectionQueueRecorderCapturesSanitizedStagesAndLifecycle") {
                try scenarioReadFileAutoSelectionQueueRecorderCapturesSanitizedStagesAndLifecycle()
            }
        }

        func testStaleCaptureStateCannotContaminateSubsequentIntervalOrLifecycleCapture() throws {
            try withIsolatedCaptureCase("testStaleIntervalFromFinishedCaptureDoesNotContaminateNextCapture") {
                try scenarioStaleIntervalFromFinishedCaptureDoesNotContaminateNextCapture()
            }
            try withIsolatedCaptureCase("testStaleLifecycleCorrelationCannotContaminateNextCapture") {
                try scenarioStaleLifecycleCorrelationCannotContaminateNextCapture()
            }
        }

        private func scenarioHiddenDispatcherRecognizesReadSearchCaptureOperations() throws {
            let diagnostics = try diagnosticsSource()
            XCTAssertTrue(diagnostics.contains("mcp_read_search_capture_begin"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_capture_snapshot"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_admission_snapshot"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_admission_configure"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_content_read_scheduler_snapshot"))
            XCTAssertTrue(diagnostics.contains("mcp_read_file_auto_selection_probe_begin"))
            XCTAssertTrue(diagnostics.contains("mcp_read_file_auto_selection_probe_drain"))
            XCTAssertTrue(diagnostics.contains("mcp_read_file_auto_selection_probe_cancel"))
            XCTAssertTrue(diagnostics.contains("mcp_apply_edits_rebase_probe_begin"))
            XCTAssertTrue(diagnostics.contains("mcp_apply_edits_rebase_probe_drain"))
            XCTAssertTrue(diagnostics.contains("mcp_apply_edits_rebase_probe_cancel"))

            for operation in [
                "mcp_read_file_auto_selection_probe_begin",
                "mcp_read_file_auto_selection_probe_drain",
                "mcp_read_file_auto_selection_probe_cancel",
                "mcp_apply_edits_rebase_probe_begin",
                "mcp_apply_edits_rebase_probe_drain",
                "mcp_apply_edits_rebase_probe_cancel"
            ] {
                XCTAssertEqual(
                    try sourceFilesContaining(operation),
                    ["Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift"],
                    operation
                )
            }

            let sibling = try source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            XCTAssertTrue(sibling.contains("#if DEBUG"))
            XCTAssertTrue(sibling.contains("100 ... 100_000"))
            XCTAssertTrue(sibling.contains("100 ... 60000"))
            XCTAssertTrue(sibling.contains("0 ... 60000"))
            XCTAssertTrue(sibling.contains("overload_count"))
            XCTAssertTrue(sibling.contains("wait_expiry_count"))
            XCTAssertTrue(sibling.contains("active_count"))
            XCTAssertTrue(sibling.contains("queued_count"))
            XCTAssertTrue(sibling.contains("window_count"))
            XCTAssertTrue(sibling.contains("\"lanes\""))
            XCTAssertTrue(sibling.contains("\"lane_count\""))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.ordinary.rawValue"))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.control.rawValue"))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.smallRead.rawValue"))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.gitRead.rawValue"))
            XCTAssertTrue(sibling.contains("MCPConnectionCallLane.fileSearch.rawValue"))
            XCTAssertTrue(sibling.contains("maximum_active_count"))
            XCTAssertTrue(sibling.contains("maximum_queued_count"))
            XCTAssertTrue(sibling.contains("max_queued_waiters"))
            XCTAssertTrue(sibling.contains("active_permit_count"))
            XCTAssertTrue(sibling.contains("queued_waiter_count"))
            XCTAssertTrue(sibling.contains("owner_lane_count"))
            XCTAssertTrue(sibling.contains("cancellation_count"))
            XCTAssertTrue(sibling.contains("interactive_grant_count"))
            XCTAssertTrue(sibling.contains("bulk_grant_count"))
            for payloadKey in [
                "captured_target_sequence",
                "accepted_intent_count",
                "completed_intent_count",
                "canonical_apply_attempt_count",
                "semantic_noop_apply_count",
                "semantic_noop_intent_count",
                "mutation_ms_per_accepted_intent",
                "mutation_samples",
                "worker_idle",
                "pending_work",
                "sample_overflow_count",
                "coverage_certificate_hit_count",
                "authoritative_fallback_count",
                "coverage_certificate_miss_reason_counts"
            ] {
                XCTAssertTrue(sibling.contains("\"\(payloadKey)\""), payloadKey)
            }
            XCTAssertTrue(sibling.contains("actor MCPReadFileAutoSelectionProbeRegistry"))
            XCTAssertTrue(sibling.contains("force_authoritative"))
            XCTAssertTrue(sibling.contains("expiry_ms"))
            XCTAssertTrue(sibling.contains("releaseForceAuthoritative"))
            XCTAssertTrue(sibling.contains("private static let capacity = 16"))
            XCTAssertTrue(sibling.contains("private static let expirySeconds: TimeInterval = 30 * 60"))

            let applyEditsProbe = try source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsApplyEditsRebaseLatency.swift")
            XCTAssertTrue(applyEditsProbe.contains("#if DEBUG"))
            XCTAssertTrue(applyEditsProbe.contains("private static let eventLimit = 64"))
            XCTAssertTrue(applyEditsProbe.contains("private static let capacity = 16"))
            XCTAssertTrue(applyEditsProbe.contains("100 ... 30 * 60 * 1000"))
            XCTAssertTrue(applyEditsProbe.contains("driver_receipt_required"))
            XCTAssertTrue(applyEditsProbe.contains("waitForPendingSliceRebasesAndCaptureFence"))
            XCTAssertTrue(applyEditsProbe.contains("minimumStableEvidenceFailure"))
            XCTAssertTrue(applyEditsProbe.contains("event.requestIdentity == identity"))
            XCTAssertTrue(applyEditsProbe.contains("current.connectionID == state.target.connectionID"))
            XCTAssertFalse(applyEditsProbe.contains("debugReadFileAutoSelectionContextSnapshot(for: state.target)"))
            XCTAssertFalse(applyEditsProbe.contains("publishSyntheticModification"))

            let workspaceFiles = try source("Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift")
            XCTAssertTrue(workspaceFiles.contains("recordRebaseTaskStart"))
            XCTAssertTrue(workspaceFiles.contains("recordRebaseExecution"))
            assertSourceOrder(
                in: workspaceFiles,
                hooks: [
                    "try? await Task.sleep(nanoseconds: 300_000_000)",
                    "guard sliceRebaseTaskIDsByFullPath[fullPath] == taskID",
                    "MCPApplyEditsRebaseProbeRecorder.recordRebaseExecution"
                ]
            )

            let bridgeLedger = try source("Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift")
            XCTAssertTrue(bridgeLedger.contains("#if DEBUG\n        /// Same-process monotonic timestamp"))
            XCTAssertTrue(bridgeLedger.contains("value[\"monotonic_uptime_ms\"] = monotonicUptimeMS"))
            let coordinator = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift")
            XCTAssertTrue(coordinator.contains("#if DEBUG\n        enum DebugCanonicalApplyOutcome"))
            XCTAssertTrue(coordinator.contains("private static let debugMutationSampleLimit = 256"))
            XCTAssertTrue(coordinator.contains("func debugDrainCanonical(for key: ContextKey)"))
            XCTAssertTrue(coordinator.contains("semanticNoOpIntentCount"))

            let server = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            XCTAssertTrue(server.contains("#if DEBUG\n        @MainActor\n        var readFileAutoSelectionPredecessorDrainWaiterRegisteredHandlerStorageForTesting"))
            XCTAssertTrue(server.contains("struct DebugReadFileAutoSelectionTarget"))
            XCTAssertTrue(server.contains("func debugResolveReadFileAutoSelectionTargets("))
            XCTAssertTrue(server.contains("func debugDrainReadFileAutoSelection("))

            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            XCTAssertFalse(provider.contains("mcp_read_file_auto_selection_probe_"))
            XCTAssertFalse(provider.contains("debugDrainReadFileAutoSelection"))
        }

        func testPerStoreAdmissionDebugConfigurationIsFixedCapacityIdleOnlyAndBounded() async {
            let store = WorkspaceFileContextStore()
            let baseline = await store.searchLaneSnapshotForTesting()
            XCTAssertEqual(baseline.activePermitCount, 0)
            XCTAssertEqual(baseline.waiterCount, 0)

            let replacement = StoreBackedWorkspaceSearchLane.Configuration(
                maxQueueWait: .seconds(60),
                retryAfterMilliseconds: 60000
            )
            guard case let .applied(configured) = await store.configureSearchLaneForTesting(replacement) else {
                return XCTFail("Idle per-store lane should accept bounded DEBUG configuration")
            }
            XCTAssertEqual(configured.configuration.maxQueueWaitMilliseconds, 60000)
            XCTAssertEqual(configured.configuration.retryAfterMilliseconds, 60000)
            XCTAssertTrue(configured.isIdle)

            let sibling = try? source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            XCTAssertTrue(sibling?.contains("\"active_capacity\": entry.snapshot.configuration.maxActiveLeases") == true)
            XCTAssertTrue(sibling?.contains("\"max_queued\": entry.snapshot.configuration.maxQueuedWaiters") == true)
            XCTAssertTrue(sibling?.contains("range: 100 ... 60000") == true)
            XCTAssertTrue(sibling?.contains("range: 0 ... 60000") == true)
            XCTAssertFalse(sibling?.contains("global_capacity") == true)
        }

        func testSearchLaneInvalidWindowErrorsRetainRequestedOperation() async throws {
            let manager = ServerNetworkManager.shared
            for operation in [
                "mcp_read_search_admission_snapshot",
                "mcp_read_search_admission_configure"
            ] {
                let result = await manager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: [
                        "op": .string(operation),
                        "window_id": .int(0)
                    ]
                )
                let payload = try debugDiagnosticsPayload(result)
                XCTAssertEqual(payload["ok"] as? Bool, false)
                XCTAssertEqual(payload["op"] as? String, operation)
                XCTAssertEqual(payload["code"] as? String, "invalid_params")
            }
        }

        func testContentReadSchedulerDebugDiagnosticsExposeAggregateSnapshot() async throws {
            let manager = ServerNetworkManager.shared
            let result = await manager.handleDebugDiagnosticsTool(
                connectionID: UUID(),
                arguments: ["op": .string("mcp_read_search_content_read_scheduler_snapshot")]
            )
            let payload = try debugDiagnosticsPayload(result)
            XCTAssertEqual(payload["ok"] as? Bool, true)
            let scheduler = try XCTUnwrap(payload["scheduler"] as? [String: Any])
            XCTAssertEqual((scheduler["capacity"] as? NSNumber)?.intValue, FileSystemService.contentReadWorkerLimitForTesting)
            XCTAssertEqual((scheduler["max_queued_waiters"] as? NSNumber)?.intValue, 512)
            XCTAssertNotNil(scheduler["active_permit_count"])
            XCTAssertNotNil(scheduler["queued_waiter_count"])
            XCTAssertNotNil(scheduler["owner_lane_count"])
            XCTAssertNotNil(scheduler["grant_count"])
            XCTAssertNotNil(scheduler["overload_count"])
        }

        func testPermitLifecycleTimelineEventsJoinBySharedRequestIdentity() async throws {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            _ = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
            addTeardownBlock {
                await manager.debugRemoveConnection(connectionID)
            }

            let identity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .number(41),
                connectionID: connectionID.uuidString,
                connectionGeneration: 7,
                appInvocationID: UUID().uuidString,
                requestOrdinal: 3
            )
            _ = startedCapture(label: "permit-identity", maxSamples: 100)
            let correlation = try XCTUnwrap(
                EditFlowPerf.makeLifecycleCorrelationIfActive(requestIdentity: identity)
            )

            let value = try await manager.withConnectionCallPermitForTesting(
                connectionID: connectionID,
                lane: .ordinary,
                toolName: "read_file",
                lifecycleCorrelation: correlation
            ) {
                "ok"
            }
            XCTAssertEqual(value, "ok")

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let permitEvents = snapshot.lifecycleEvents.filter {
                [
                    "MCP.ToolCall.PermitQueued",
                    "MCP.ToolCall.PermitAcquired",
                    "MCP.ToolCall.PermitReleased"
                ].contains($0.eventName)
            }
            XCTAssertEqual(permitEvents.map(\.eventName), [
                "MCP.ToolCall.PermitQueued",
                "MCP.ToolCall.PermitAcquired",
                "MCP.ToolCall.PermitReleased"
            ])
            XCTAssertEqual(Set(permitEvents.map(\.correlationID)).count, 1)
            XCTAssertTrue(permitEvents.allSatisfy { $0.requestIdentity == identity })
            XCTAssertTrue(permitEvents.allSatisfy {
                $0.sanitizedDimensions.contains("tool=read_file")
                    && $0.sanitizedDimensions.contains("admissionClass=ordinary")
                    && $0.sanitizedDimensions.contains("queueDepth=")
                    && $0.sanitizedDimensions.contains("ownerResource=connection_\(connectionID.uuidString)")
            })
            XCTAssertTrue(permitEvents.last?.sanitizedDimensions.contains("outcome=completed") == true)

            let payloads = try XCTUnwrap(
                EditFlowPerf.debugCaptureSnapshot(finish: false)
                    .payload()["lifecycle_events"] as? [[String: Any]]
            )
            let joinedIdentities = payloads.compactMap { $0["request_identity"] as? [String: Any] }
            XCTAssertEqual(joinedIdentities.count, 3)
            XCTAssertTrue(joinedIdentities.allSatisfy {
                $0["jsonrpc_request_id"] as? String == "number:41"
                    && $0["connection_id"] as? String == connectionID.uuidString
                    && ($0["connection_generation"] as? NSNumber)?.uint64Value == 7
                    && $0["app_invocation_id"] as? String == identity.appInvocationID
                    && ($0["request_ordinal"] as? NSNumber)?.uint64Value == 3
            })

            let managerSource = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            for hook in [
                "EditFlowPerf.Lifecycle.MCPToolCall.permitQueued",
                "EditFlowPerf.Lifecycle.MCPToolCall.permitAcquired",
                "EditFlowPerf.Lifecycle.MCPToolCall.permitReleased",
                "requestIdentity: resolvedRequestIdentity"
            ] {
                XCTAssertTrue(managerSource.contains(hook), "Missing permit timeline hook: \(hook)")
            }
        }

        func testCorrelatedRequestTimelineJoinsAllWI2StagesAndWorkloadMatrices() throws {
            let connectionID = UUID().uuidString
            let identity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("request-7"),
                connectionID: connectionID,
                connectionGeneration: 2,
                requestOrdinal: 11
            )
            let invocationID = try XCTUnwrap(identity.appInvocationID)
            XCTAssertEqual(
                invocationID,
                MCPRequestTimelineIdentity.deterministicAppInvocationID(
                    jsonRPCRequestID: .string("request-7"),
                    connectionID: connectionID,
                    connectionGeneration: 2,
                    requestOrdinal: 11
                )
            )
            let otherConnectionIdentity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("request-7"),
                connectionID: UUID().uuidString,
                connectionGeneration: 2,
                requestOrdinal: 11
            )
            XCTAssertNotEqual(invocationID, otherConnectionIdentity.appInvocationID)

            _ = startedCapture(label: "wi2-all-stages", maxSamples: 200)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive(requestIdentity: identity))
            for event in [
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                EditFlowPerf.Lifecycle.MCPToolCall.permitQueued,
                EditFlowPerf.Lifecycle.MCPToolCall.permitAcquired,
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorEntered,
                EditFlowPerf.Lifecycle.MCPToolCall.mainActorExited,
                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderBegan,
                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded,
                EditFlowPerf.Lifecycle.MCPToolCall.observerScheduled,
                EditFlowPerf.Lifecycle.MCPToolCall.observerEntered,
                EditFlowPerf.Lifecycle.MCPToolCall.observerExited,
                EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                EditFlowPerf.Lifecycle.MCPToolCall.handlerResultReady,
                EditFlowPerf.Lifecycle.MCPToolCall.permitReleased
            ] {
                EditFlowPerf.lifecycleEvent(event, correlation: correlation)
            }
            let capturePayload = EditFlowPerf.debugCaptureSnapshot(finish: true).payload()
            XCTAssertEqual((capturePayload["request_timeline_count"] as? NSNumber)?.intValue, 1)
            let timelines = try XCTUnwrap(capturePayload["request_timelines"] as? [[String: Any]])
            XCTAssertEqual(timelines.first?["join_key"] as? String, invocationID)
            let catalog = try XCTUnwrap(capturePayload["workload_matrix_catalog"] as? [[String: Any]])
            XCTAssertEqual(Set(catalog.compactMap { $0["id"] as? String }), [
                "same_connection_ordinary_burst",
                "same_connection_mixed_ordinary_search",
                "distinct_connections_one_window",
                "distinct_windows",
                "agent_transcript_short_vs_long"
            ])

            let previousPerf = UserDefaults.standard.object(forKey: "enableAgentModePerfDiagnostics")
            UserDefaults.standard.set(true, forKey: "enableAgentModePerfDiagnostics")
            defer {
                if let previousPerf {
                    UserDefaults.standard.set(previousPerf, forKey: "enableAgentModePerfDiagnostics")
                } else {
                    UserDefaults.standard.removeObject(forKey: "enableAgentModePerfDiagnostics")
                }
                MCPResponseDeliveryTracer.resetDebugEvents()
            }
            MCPResponseDeliveryTracer.resetDebugEvents()
            for (layer, phase) in [
                ("app_uds_transport", "frame_accepted"),
                ("app_sdk", "sdk_decode_completed"),
                ("app_tool_handler", "handler_result_ready"),
                ("app_uds_transport", "sdk_encode_completed"),
                ("app_uds_transport", "transport_write_completed"),
                ("proxy_ledger", "frame_committed"),
                ("proxy_stdout", "stdout_write_completed")
            ] {
                MCPResponseDeliveryTracer.emit(MCPResponseDeliveryTraceEvent(
                    layer: layer,
                    phase: phase,
                    connectionID: connectionID,
                    connectionGeneration: 2,
                    direction: phase == "frame_accepted" ? .clientToServer : .serverToClient,
                    id: .string("request-7"),
                    method: "tools/call",
                    tool: "read_file",
                    requestOrdinal: 11,
                    requestIdentity: identity
                ))
            }
            let delivery = MCPResponseDeliveryTracer.debugEventSnapshot()
            XCTAssertEqual(delivery.count, 7)
            XCTAssertTrue(delivery.allSatisfy { $0.requestIdentity?.appInvocationID == invocationID })

            let sources = try [
                source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift"),
                source("Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift"),
                source("Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift"),
                source("Sources/RepoPromptMCP/main.swift"),
                source("Sources/RepoPrompt/Infrastructure/AI/Agents/AgentToolTracker.swift"),
                source("Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunTerminalCommitBarrier.swift")
            ].joined(separator: "\n")
            for hook in [
                "frame_accepted",
                "sdk_decode_completed",
                "permitQueued",
                "permitAcquired",
                "mainActorScheduled",
                "resolvedProviderBegan",
                "observerScheduled",
                "handler_result_ready",
                "sdk_encode_completed",
                "transport_write_completed",
                "stdout_write_completed",
                "publicationPending",
                "terminalBarrier"
            ] {
                XCTAssertTrue(sources.contains(hook), "Missing WI-2 stage hook: \(hook)")
            }
        }

        func testLimiterDiagnosticsReportPromptQueuedCancellationAndIdleState() async {
            let clock = LockedMCPDiagnosticsClock(nowNanoseconds: 1_000_000_000)
            let limiter = AsyncLimiter(limit: 1, debugNowNanoseconds: { clock.now() })
            let holderGate = MCPDiagnosticsGate()
            let waiterBodyRan = MCPDiagnosticsSignal()
            let snapshotSignal = MCPDiagnosticsSnapshotSignal()
            await limiter.setDebugStateObserver { snapshot in
                Task { await snapshotSignal.record(snapshot) }
            }

            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.markStartedAndWaitForRelease()
                }
            }
            await holderGate.waitUntilStarted()

            let waiter = Task {
                do {
                    try await limiter.withPermit {
                        await waiterBodyRan.mark()
                    }
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }

            let queued = await snapshotSignal.waitUntil { $0.waiterCount == 1 }
            XCTAssertEqual(queued.limit, 1)
            XCTAssertEqual(queued.permits, 0)
            XCTAssertEqual(queued.activePermitCount, 1)
            XCTAssertEqual(queued.waiterCount, 1)
            XCTAssertEqual(queued.inFlight, 2)
            XCTAssertEqual(queued.oldestWaiterAgeMilliseconds, 0)
            XCTAssertFalse(queued.isClosed)
            XCTAssertFalse(queued.isIdle)

            clock.advance(milliseconds: 275)
            let aged = await limiter.debugSnapshot()
            XCTAssertEqual(aged.oldestWaiterAgeMilliseconds, 275)

            waiter.cancel()
            let cancelled = await snapshotSignal.waitUntil {
                $0.cancelledWaiterCount == 1 && $0.waiterCount == 0 && $0.inFlight == 1
            }
            XCTAssertEqual(cancelled.waiterCount, 0)
            XCTAssertEqual(cancelled.cancelledWaiterCount, 1)
            let waiterWasCancelled = await waiter.value
            let didRunWaiterBody = await waiterBodyRan.isMarked()
            XCTAssertTrue(waiterWasCancelled)
            XCTAssertFalse(didRunWaiterBody)

            await holderGate.release()
            try? await holder.value

            let settled = await snapshotSignal.waitUntil { $0.isIdle }
            XCTAssertEqual(settled.permits, 1)
            XCTAssertEqual(settled.activePermitCount, 0)
            XCTAssertEqual(settled.waiterCount, 0)
            XCTAssertEqual(settled.inFlight, 0)
            XCTAssertNil(settled.oldestWaiterAgeMilliseconds)
            XCTAssertEqual(settled.cancelledWaiterCount, 1)
            XCTAssertFalse(settled.isClosed)
            XCTAssertTrue(settled.isIdle)
            await limiter.setDebugStateObserver(nil)
        }

        @MainActor
        private func scenarioRuntimeSnapshotHiddenOperationValidatesBoundsAndReturnsAggregateShape(caseLabel: String) async throws {
            let manager = ServerNetworkManager.shared
            let connectionID = UUID()
            _ = await manager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)
            addTeardownBlock {
                await manager.debugRemoveConnection(connectionID)
            }
            let runID = UUID()
            await manager.registerToolEventObserver(
                for: runID,
                observer: ServerNetworkManager.ToolEventObserver(onCalled: { _, _, _ in }, onCompleted: nil)
            )
            addTeardownBlock {
                await manager.unregisterToolObservers(for: runID)
            }

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            let expectedToolEventObserverCount = await manager.toolEventObserverCount()
            let result = await manager.handleDebugDiagnosticsTool(
                connectionID: connectionID,
                arguments: [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "window_id": .int(window.windowID),
                    "recent_publication_limit": .int(0),
                    "root_limit": .int(1)
                ]
            )
            let payload = try debugDiagnosticsPayload(result, caseLabel: caseLabel)
            XCTAssertEqual(payload["ok"] as? Bool, true, caseLabel)
            XCTAssertEqual(payload["op"] as? String, "mcp_read_search_runtime_snapshot", caseLabel)
            let runtime = try XCTUnwrap(payload["runtime"] as? [String: Any], caseLabel)
            XCTAssertEqual(runtime["consistency"] as? String, "best_effort")
            XCTAssertEqual((runtime["window_count"] as? NSNumber)?.intValue, 1)
            let observers = try XCTUnwrap(runtime["observers"] as? [String: Any])
            XCTAssertNil(observers["tool_call_observer_count"])
            XCTAssertEqual(
                (observers["tool_event_observer_count"] as? NSNumber)?.intValue,
                expectedToolEventObserverCount
            )
            let windows = try XCTUnwrap(runtime["windows"] as? [[String: Any]])
            let windowPayload = try XCTUnwrap(windows.first)
            XCTAssertEqual((windowPayload["window_id"] as? NSNumber)?.intValue, window.windowID)
            XCTAssertNotNil(windowPayload["projection_direct_file_id_lookup_count"])
            XCTAssertNotNil(windowPayload["projection_direct_folder_id_lookup_count"])
            XCTAssertNotNil(windowPayload["projection_direct_id_lookup_miss_count"])
            XCTAssertNotNil(windowPayload["projection_canonical_resync_count"])
            let uiIndexRebuild = try XCTUnwrap(windowPayload["ui_index_rebuild"] as? [String: Any])
            XCTAssertNotNil(uiIndexRebuild["count"])
            XCTAssertNotNil(uiIndexRebuild["visited_file_count"])
            let storeWork = try XCTUnwrap(windowPayload["store_work"] as? [String: Any])
            XCTAssertNotNil(storeWork["invalidations"])
            XCTAssertNotNil(storeWork["catalog_rebuild"])
            let searchRebuild = try XCTUnwrap(windowPayload["search_rebuild"] as? [String: Any])
            XCTAssertNotNil(searchRebuild["c_index_build_us"])
            XCTAssertNotNil(searchRebuild["stale_discarded_count"])
            let duplication = try XCTUnwrap(runtime["physical_root_duplication"] as? [[String: Any]])
            XCTAssertTrue(duplication.isEmpty)
            let toolWork = try XCTUnwrap(runtime["tool_work"] as? [String: Any])
            XCTAssertNotNil(toolWork["git_invocations"])
            XCTAssertNotNil(toolWork["read_file_invocations"])
            let autoSelection = try XCTUnwrap(windowPayload["read_file_auto_selection"] as? [String: Any])
            for key in [
                "canonical_lane_count",
                "canonical_worker_count",
                "mirror_lane_count",
                "mirror_worker_count",
                "closing_context_count",
                "pending_canonical_batch_count",
                "pending_mirror_batch_count"
            ] {
                XCTAssertEqual((autoSelection[key] as? NSNumber)?.intValue, 0, key)
            }
            let smallReadLaneLimit = ServerNetworkManager.smallReadCallLaneLimit
            let controlLaneLimit = ServerNetworkManager.controlCallLaneLimit
            let gitReadLaneLimit = ServerNetworkManager.gitReadCallLaneLimit
            let fileSearchLaneLimit = ServerNetworkManager.fileSearchCallLaneLimit
            let totalLaneLimit = 1 + controlLaneLimit + smallReadLaneLimit + gitReadLaneLimit + fileSearchLaneLimit
            let limiter = try XCTUnwrap(runtime["limiter"] as? [String: Any])
            XCTAssertEqual(limiter["found"] as? Bool, true)
            XCTAssertEqual(limiter["connection_id"] as? String, connectionID.uuidString)
            XCTAssertEqual((limiter["lane_count"] as? NSNumber)?.intValue, MCPConnectionCallLane.allCases.count)
            XCTAssertEqual((limiter["limit"] as? NSNumber)?.intValue, totalLaneLimit)
            XCTAssertEqual((limiter["permits"] as? NSNumber)?.intValue, totalLaneLimit)
            XCTAssertEqual((limiter["active_permit_count"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((limiter["waiter_count"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((limiter["in_flight_count"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual(limiter["is_closed"] as? Bool, false)
            XCTAssertEqual(limiter["is_idle"] as? Bool, true)
            let lanes = try XCTUnwrap(limiter["lanes"] as? [String: Any])
            XCTAssertEqual(Set(lanes.keys), Set(MCPConnectionCallLane.allCases.map(\.rawValue)))
            for (laneName, laneLimit) in [
                ("ordinary", 1),
                ("control", controlLaneLimit),
                ("small_read", smallReadLaneLimit),
                ("git_read", gitReadLaneLimit),
                ("file_search", fileSearchLaneLimit)
            ] {
                let lane = try XCTUnwrap(lanes[laneName] as? [String: Any])
                XCTAssertEqual((lane["limit"] as? NSNumber)?.intValue, laneLimit, laneName)
                XCTAssertEqual((lane["permits"] as? NSNumber)?.intValue, laneLimit, laneName)
                XCTAssertEqual((lane["active_permit_count"] as? NSNumber)?.intValue, 0, laneName)
                XCTAssertEqual((lane["waiter_count"] as? NSNumber)?.intValue, 0, laneName)
                XCTAssertEqual((lane["in_flight_count"] as? NSNumber)?.intValue, 0, laneName)
                XCTAssertEqual(lane["is_closed"] as? Bool, false, laneName)
                XCTAssertEqual(lane["is_idle"] as? Bool, true, laneName)
            }

            let missingConnectionID = UUID()
            let missingResult = await manager.handleDebugDiagnosticsTool(
                connectionID: connectionID,
                arguments: [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "connection_id": .string(missingConnectionID.uuidString),
                    "window_id": .int(window.windowID),
                    "recent_publication_limit": .int(0),
                    "root_limit": .int(1)
                ]
            )
            let missingPayload = try debugDiagnosticsPayload(missingResult, caseLabel: caseLabel)
            let missingRuntime = try XCTUnwrap(missingPayload["runtime"] as? [String: Any], caseLabel)
            let missingLimiter = try XCTUnwrap(missingRuntime["limiter"] as? [String: Any], caseLabel)
            XCTAssertEqual(missingLimiter["found"] as? Bool, false, caseLabel)
            XCTAssertEqual(missingLimiter["connection_id"] as? String, missingConnectionID.uuidString, caseLabel)

            for invalidArguments: [String: Value] in [
                [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "connection_id": .string("not-a-uuid")
                ],
                [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "recent_publication_limit": .int(33)
                ],
                [
                    "op": .string("mcp_read_search_runtime_snapshot"),
                    "root_limit": .int(0)
                ]
            ] {
                let invalidResult = await manager.handleDebugDiagnosticsTool(
                    connectionID: connectionID,
                    arguments: invalidArguments
                )
                let invalidPayload = try debugDiagnosticsPayload(invalidResult, caseLabel: caseLabel)
                XCTAssertEqual(invalidPayload["ok"] as? Bool, false, caseLabel)
                XCTAssertEqual(invalidPayload["op"] as? String, "mcp_read_search_runtime_snapshot", caseLabel)
                XCTAssertEqual(invalidPayload["code"] as? String, "invalid_params", caseLabel)
            }
        }

        @MainActor
        private func scenarioRuntimeSnapshotProjectsActiveAndCoalescedPendingBarrierState(caseLabel: String) async throws {
            let manager = ServerNetworkManager.shared
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
            }

            let root = try temporaryRoots.makeRoot(suiteName: "RuntimePendingBarrier")
            let firstURL = root.appendingPathComponent("First.swift")
            let secondURL = root.appendingPathComponent("Second.swift")
            try FileSystemTestSupport.write("first", to: firstURL)
            try FileSystemTestSupport.write("second", to: secondURL)
            let store = window.workspaceFileContextStore
            let record = try await store.loadRoot(path: root.path)
            let rootID = record.id
            let rootName = record.name
            let rootPath = record.fullPath
            let attachedPublisherIngress = try await store.attachPublisherIngressWithoutStartingWatcherForTesting(rootID: rootID)
            XCTAssertTrue(attachedPublisherIngress)
            await store.resetScopedIngressBarrierDiagnosticsForTesting(rootID: rootID)

            let flushGate = MCPDiagnosticsGate()
            await store.setScopedIngressBarrierWillFlushHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await flushGate.markStartedAndWaitForRelease()
            }
            let activeBarrier = Task.detached {
                await store.awaitAppliedIngress(rootRefs: [WorkspaceRootRef(id: rootID, name: rootName, fullPath: rootPath)])
            }
            var pendingBarrier: Task<[WorkspaceIngressBarrierSample], Never>?
            var coalescedBarrier: Task<[WorkspaceIngressBarrierSample], Never>?

            do {
                do {
                    try await waitForDiagnosticsGateStart(flushGate, label: "scoped ingress flush")
                } catch {
                    let loadedRoots = await store.roots()
                    let rootDescriptions = loadedRoots.map { root in
                        "\(root.id.uuidString):\(root.kind):\(root.standardizedFullPath)"
                    }
                    let stats = await store.scopedIngressBarrierStatsForTesting(rootID: record.id)
                    let flightCount = await store.scopedIngressBarrierFlightCountForTesting()
                    let authority = await store.publishedSeededAuthoritySnapshotForTesting(rootID: record.id)
                    XCTFail(
                        "Scoped ingress flush did not start; roots=\(rootDescriptions) stats=\(stats) flightCount=\(flightCount) authority=\(String(describing: authority))"
                    )
                    throw error
                }
                let createdFileFlags = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
                )
                let firstAccepted = try await store.acceptWatcherPayloadForTesting(
                    rootID: record.id,
                    events: [(absolutePath: firstURL.path, flags: createdFileFlags, eventId: 500)],
                    scheduleDrain: false
                )
                _ = try XCTUnwrap(firstAccepted, "Expected first watcher watermark")
                pendingBarrier = Task.detached {
                    await store.awaitAppliedIngress(rootRefs: [WorkspaceRootRef(id: rootID, name: rootName, fullPath: rootPath)])
                }
                for _ in 0 ..< 1000 {
                    if await store.scopedIngressBarrierStatsForTesting(rootID: record.id).successorCount == 1 { break }
                    await Task.yield()
                }

                let acceptedSecondWatermark = try await store.acceptWatcherPayloadForTesting(
                    rootID: record.id,
                    events: [(absolutePath: secondURL.path, flags: createdFileFlags, eventId: 501)],
                    scheduleDrain: false
                )
                let secondAccepted = try XCTUnwrap(
                    acceptedSecondWatermark,
                    "Expected second watcher watermark"
                )
                try await store.publishSyntheticFileSystemDeltasForTesting(
                    rootID: record.id,
                    deltas: [.fileModified("First.swift", nil)]
                )
                let acceptedServicePublicationSequence = await store.appliedIngressSnapshotForTesting(rootID: record.id)
                    .acceptedServicePublicationSequence
                coalescedBarrier = Task.detached {
                    await store.awaitAppliedIngress(rootRefs: [WorkspaceRootRef(id: rootID, name: rootName, fullPath: rootPath)])
                }
                for _ in 0 ..< 1000 {
                    if await store.scopedIngressBarrierStatsForTesting(rootID: record.id).coalescedSuccessorCount == 1 {
                        break
                    }
                    await Task.yield()
                }

                let result = await manager.handleDebugDiagnosticsTool(
                    connectionID: UUID(),
                    arguments: [
                        "op": .string("mcp_read_search_runtime_snapshot"),
                        "window_id": .int(window.windowID),
                        "recent_publication_limit": .int(0),
                        "root_limit": .int(1)
                    ]
                )
                let cleanupDrainedFlights = await cleanupRuntimePendingBarrierTest(
                    store: store,
                    rootID: record.id,
                    flushGate: flushGate,
                    activeBarrier: activeBarrier,
                    pendingBarrier: pendingBarrier,
                    coalescedBarrier: coalescedBarrier
                )
                XCTAssertTrue(cleanupDrainedFlights, "Scoped ingress barrier flights should drain before test teardown")

                let payload = try debugDiagnosticsPayload(result, caseLabel: caseLabel)
                let runtime = try XCTUnwrap(payload["runtime"] as? [String: Any], caseLabel)
                let windows = try XCTUnwrap(runtime["windows"] as? [[String: Any]], caseLabel)
                let windowPayload = try XCTUnwrap(windows.first, caseLabel)
                let roots = try XCTUnwrap(windowPayload["roots"] as? [[String: Any]], caseLabel)
                let rootPayload = try XCTUnwrap(roots.first, caseLabel)
                let barrier = try XCTUnwrap(rootPayload["barrier"] as? [String: Any], caseLabel)
                XCTAssertEqual((barrier["launch_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((barrier["join_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((barrier["successor_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((barrier["coalesced_successor_count"] as? NSNumber)?.intValue, 1)
                XCTAssertEqual((barrier["completion_count"] as? NSNumber)?.intValue, 0)
                let active = try XCTUnwrap(barrier["active"] as? [String: Any])
                XCTAssertEqual((active["target_watcher_watermark"] as? NSNumber)?.uint64Value, 0)
                let pending = try XCTUnwrap(barrier["pending"] as? [String: Any])
                XCTAssertEqual(
                    (pending["target_watcher_watermark"] as? NSNumber)?.uint64Value,
                    secondAccepted.rawValue
                )
                XCTAssertEqual(
                    (pending["target_service_publication_sequence"] as? NSNumber)?.uint64Value,
                    acceptedServicePublicationSequence
                )
                XCTAssertNotNil((pending["age_ms"] as? NSNumber)?.uint64Value)
            } catch {
                _ = await cleanupRuntimePendingBarrierTest(
                    store: store,
                    rootID: record.id,
                    flushGate: flushGate,
                    activeBarrier: activeBarrier,
                    pendingBarrier: pendingBarrier,
                    coalescedBarrier: coalescedBarrier
                )
                throw error
            }
        }

        private func scenarioSearchDTOBuildNestedRecorderCapturesOnlyCoarseSanitizedDimensions() {
            _ = startedCapture(label: "search-dto-build-decomposition", maxSamples: 100)
            let stages: [(StaticString, String)] = [
                (EditFlowPerf.Stage.Search.dtoRootRefSnapshotLookup, "EditFlow.Search.DTOBuild.RootRefSnapshotLookup"),
                (EditFlowPerf.Stage.Search.dtoDisplayResolverPreparation, "EditFlow.Search.DTOBuild.DisplayResolverPreparation"),
                (EditFlowPerf.Stage.Search.dtoPathDisplayProjection, "EditFlow.Search.DTOBuild.PathDisplayProjection"),
                (EditFlowPerf.Stage.Search.dtoCapAccounting, "EditFlow.Search.DTOBuild.CapAccounting"),
                (EditFlowPerf.Stage.Search.dtoAssembly, "EditFlow.Search.DTOBuild.Assembly")
            ]
            let dimensions = EditFlowPerf.Dimensions(
                outcome: "completed",
                scannedFileCount: 1630,
                contentMatchCount: 0,
                pathMatchCount: 80,
                usesWorktreeProjection: true,
                searchMode: "path",
                countOnly: false
            )
            for (stage, _) in stages {
                EditFlowPerf.measure(stage, dimensions) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, stages.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertEqual(Set(snapshot.stages.map(\.stageName)), Set(stages.map(\.1)))
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
            XCTAssertTrue(snapshot.stages.allSatisfy {
                $0.sanitizedDimensions == "outcome=completed scannedFileCount=1630 contentMatchCount=0 pathMatchCount=80 usesWorktreeProjection=true searchMode=path countOnly=false"
            })
            XCTAssertTrue(snapshot.stages.allSatisfy {
                !$0.sanitizedDimensions.contains("/") &&
                    !$0.sanitizedDimensions.contains("payload") &&
                    !$0.sanitizedDimensions.contains("pattern") &&
                    !$0.sanitizedDimensions.contains("workspace") &&
                    !$0.sanitizedDimensions.contains("root")
            })
        }

        private func scenarioNewReadDispatchStageRecorderCapturesToolDimensionAndFinishes() throws {
            _ = startedCapture(label: "dispatch-decomposition", maxSamples: 100)
            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookup,
                EditFlowPerf.Dimensions(toolName: "read_file")
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            XCTAssertEqual(aggregate.stageName, "EditFlow.MCPToolCall.ServiceToolLookup")
            XCTAssertEqual(aggregate.sanitizedDimensions, "tool=read_file")
            XCTAssertEqual(aggregate.sampleCount, 1)
        }

        private func scenarioServiceToolLookupInnerAttributionRecorderUsesStaticEmptyDimensions() {
            _ = startedCapture(label: "service-tool-lookup-inner", maxSamples: 100)
            for stage in [
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupAppSettingsToolsBuild,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowRoutingToolsCacheActorBody,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsActorBodyTotal,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization
            ] {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 7)
            XCTAssertEqual(
                Set(snapshot.stages.map(\.stageName)),
                Set([
                    "EditFlow.MCPToolCall.ServiceToolLookup.ServiceToolsAwait",
                    "EditFlow.MCPToolCall.ServiceToolLookup.ToolDefinitionScan",
                    "EditFlow.MCPToolCall.ServiceToolLookup.PublicWindowIDInjection",
                    "EditFlow.MCPToolCall.ServiceToolLookup.AppSettingsToolsBuild",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowRoutingToolsCacheActorBody",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsActorBodyTotal",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsMaterialization"
                ])
            )
            XCTAssertTrue(snapshot.stages.allSatisfy(\.sanitizedDimensions.isEmpty))
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
        }

        private func scenarioMCPWindowToolCatalogLifecycleAttributionRecorderUsesStaticEmptyDimensions() {
            _ = startedCapture(label: "window-tool-catalog-lifecycle", maxSamples: 100)
            for stage in [
                EditFlowPerf.Stage.MCPWindowToolCatalog.construction,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolSummariesChange,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolRegistrationUpdate,
                EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateWindowToolsEnabledDidSet,
                EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateAgentBootstrap,
                EditFlowPerf.Stage.MCPWindowToolCatalog.readinessWarmAccess,
                EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication,
                EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable
            ] {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 9)
            XCTAssertEqual(
                Set(snapshot.stages.map(\.stageName)),
                Set([
                    "EditFlow.MCPWindowToolCatalog.Construction",
                    "EditFlow.MCPWindowToolCatalog.InvalidateToolsCache",
                    "EditFlow.MCPWindowToolCatalog.Invalidation.ToolSummariesChange",
                    "EditFlow.MCPWindowToolCatalog.Invalidation.ToolRegistrationUpdate",
                    "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.WindowToolsEnabledDidSet",
                    "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.AgentBootstrap",
                    "EditFlow.MCPWindowToolCatalog.ReadinessWarmAccess",
                    "EditFlow.MCPWindowToolCatalog.ServiceRegistryToolsPublication",
                    "EditFlow.MCPWindowToolCatalog.CodexTurnMCPServerEnable"
                ])
            )
            XCTAssertTrue(snapshot.stages.allSatisfy(\.sanitizedDimensions.isEmpty))
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
        }

        private func scenarioOuterEnvelopeRecorderCapturesCombinedToolAndSanitizedOutcomes() throws {
            _ = startedCapture(label: "outer-envelope", maxSamples: 100)
            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.preLimiterEnvelope,
                EditFlowPerf.Dimensions(toolName: "read_file")
            ) {}
            for outcome in ["attempted", "skipped"] {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
            }
            for outcome in ["success", "dispatchError", "toolNotFound"] {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 8)

            let plain = try XCTUnwrap(snapshot.stages.first { $0.stageName == "EditFlow.MCPToolCall.PreLimiterEnvelope" })
            XCTAssertEqual(plain.sanitizedDimensions, "tool=read_file")
            XCTAssertEqual(plain.sampleCount, 1)

            let expectedCombinedDimensions = [
                "tool=read_file outcome=attempted",
                "tool=read_file outcome=dispatchError",
                "tool=read_file outcome=skipped",
                "tool=read_file outcome=success",
                "tool=read_file outcome=toolNotFound"
            ]
            let combinedRows = snapshot.stages.filter { $0.stageName != "EditFlow.MCPToolCall.PreLimiterEnvelope" }
            XCTAssertTrue(combinedRows.allSatisfy { $0.sampleCount == 1 })
            XCTAssertTrue(combinedRows.allSatisfy { expectedCombinedDimensions.contains($0.sanitizedDimensions) })
            XCTAssertTrue(combinedRows.allSatisfy { !$0.sanitizedDimensions.contains("/") && !$0.sanitizedDimensions.contains("payload") })
            XCTAssertEqual(
                Set(combinedRows.map(\.sanitizedDimensions)),
                Set(expectedCombinedDimensions)
            )
        }

        private func scenarioProviderReadRecorderCapturesTotalAndSanitizedAutoSelectOutcomes() throws {
            _ = startedCapture(label: "provider-read-decomposition", maxSamples: 100)
            EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerTotal) {}
            EditFlowPerf.measure(
                EditFlowPerf.Stage.ReadFile.providerAutoSelect,
                EditFlowPerf.Dimensions(outcome: "attempted")
            ) {}
            EditFlowPerf.measure(
                EditFlowPerf.Stage.ReadFile.providerAutoSelect,
                EditFlowPerf.Dimensions(outcome: "skipped")
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 3)

            let total = try XCTUnwrap(snapshot.stages.first { $0.stageName == "EditFlow.ReadFile.ProviderTotal" })
            XCTAssertEqual(total.sanitizedDimensions, "")
            XCTAssertEqual(total.sampleCount, 1)

            let autoSelectRows = snapshot.stages.filter { $0.stageName == "EditFlow.ReadFile.ProviderAutoSelect" }
            XCTAssertEqual(autoSelectRows.map(\.sanitizedDimensions).sorted(), ["outcome=attempted", "outcome=skipped"])
            XCTAssertTrue(autoSelectRows.allSatisfy { $0.sampleCount == 1 })
            XCTAssertTrue(autoSelectRows.allSatisfy { !$0.sanitizedDimensions.contains("/") && !$0.sanitizedDimensions.contains("payload") })
        }

        private func scenarioProviderAutoSelectNestedRecorderCapturesRepresentativeSanitizedOutcomes() {
            _ = startedCapture(label: "provider-auto-select-decomposition", maxSamples: 100)
            let samples: [(StaticString, String)] = [
                (EditFlowPerf.Stage.ReadFile.AutoSelect.eligibilityResolution, "eligible"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.selectionProjection, "full"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.fullFlowTotal, "unchanged"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.autoCodemapRecomputeTotal, "attempted"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.finalSelectionEquality, "unchanged"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.persistence, "skipped")
            ]
            for (stage, outcome) in samples {
                EditFlowPerf.measure(stage, EditFlowPerf.Dimensions(outcome: outcome)) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, samples.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
            XCTAssertEqual(
                Set(snapshot.stages.map(\.sanitizedDimensions)),
                Set(samples.map { "outcome=\($0.1)" })
            )
            XCTAssertTrue(snapshot.stages.allSatisfy {
                !$0.sanitizedDimensions.contains("/") &&
                    !$0.sanitizedDimensions.contains("payload") &&
                    !$0.sanitizedDimensions.contains("namespace")
            })
        }

        private func scenarioReadFileAutoSelectionQueueRecorderCapturesSanitizedStagesAndLifecycle() throws {
            _ = startedCapture(label: "read-file-auto-selection-queue", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            let samples: [StaticString] = [
                EditFlowPerf.Stage.ReadFile.AutoSelect.responseEnqueue,
                EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalQueueWait,
                EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalMutation,
                EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalStoredCommit,
                EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorEnqueue,
                EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorQueueWait,
                EditFlowPerf.Stage.ReadFile.AutoSelect.mirrorApply,
                EditFlowPerf.Stage.ReadFile.AutoSelect.drainWait,
                EditFlowPerf.Stage.WorkspaceDurability.flushWait,
                EditFlowPerf.Stage.WorkspaceDurability.atomicWrite
            ]
            for stage in samples {
                EditFlowPerf.measure(stage, EditFlowPerf.Dimensions(outcome: "success", queueDepth: 1)) {}
            }
            for event in [
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.enqueueAccepted,
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.canonicalApplyBegan,
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorScheduled,
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.mirrorApplyEnded,
                EditFlowPerf.Lifecycle.ReadFileAutoSelect.drainEnded,
                EditFlowPerf.Lifecycle.WorkspaceDurability.flushEnded,
                EditFlowPerf.Lifecycle.WorkspaceDurability.writeEnded
            ] {
                EditFlowPerf.lifecycleEvent(event, correlation: correlation, EditFlowPerf.Dimensions(outcome: "success"))
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.retainedSampleCount, samples.count)
            XCTAssertEqual(snapshot.retainedLifecycleEventCount, 7)
            XCTAssertTrue(snapshot.stages.allSatisfy { !$0.sanitizedDimensions.contains("/") })
            XCTAssertTrue(snapshot.lifecycleEvents.allSatisfy { !$0.sanitizedDimensions.contains("/") })
        }

        func testCaptureRejectsConcurrentStartAndFinishDisablesCapture() {
            switch EditFlowPerf.beginDebugCapture(label: "first", maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("First capture should start.")
            }
            switch EditFlowPerf.beginDebugCapture(label: "second", maxSamples: 100) {
            case .started:
                XCTFail("Concurrent capture should be rejected.")
            case let .busy(snapshot):
                XCTAssertEqual(snapshot.label, "first")
                XCTAssertTrue(snapshot.active)
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
        }

        private func scenarioStaleIntervalFromFinishedCaptureDoesNotContaminateNextCapture() throws {
            _ = startedCapture(label: "capture-a", maxSamples: 100)
            let staleState = try XCTUnwrap(EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.providerExecution))
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            _ = startedCapture(label: "capture-b", maxSamples: 100)
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.providerExecution, staleState)

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.label, "capture-b")
            XCTAssertEqual(snapshot.retainedSampleCount, 0)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertTrue(snapshot.stages.isEmpty)
        }

        func testDirectCaptureSampleLimitIsClampedToDiagnosticBounds() {
            let lowerBound = startedCapture(label: "lower", maxSamples: 1)
            XCTAssertEqual(lowerBound.maxSamples, 100)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            let upperBound = startedCapture(label: "upper", maxSamples: 100_001)
            XCTAssertEqual(upperBound.maxSamples, 100_000)
            XCTAssertEqual(upperBound.maxLifecycleEvents, 20000)
        }

        func testUnsafeSyntheticLabelAndDimensionsAreSanitizedAndBounded() throws {
            let unsafe = "synthetic /:|\\n" + String(repeating: "x", count: 100)
            let started = startedCapture(label: unsafe, maxSamples: 100)
            assertPermittedLabel(started.label)

            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.providerExecution,
                EditFlowPerf.Dimensions(toolName: unsafe, status: unsafe)
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            let components = aggregate.sanitizedDimensions.split(separator: " ")
            XCTAssertEqual(components.count, 2)
            for component in components {
                let parts = component.split(separator: "=", maxSplits: 1)
                XCTAssertEqual(parts.count, 2)
                assertPermittedLabel(String(parts[1]))
            }
        }

        func testBoundedCaptureReportsDroppedSamplesAndSanitizedDimensions() throws {
            switch EditFlowPerf.beginDebugCapture(label: "bounded", maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("Capture should start.")
            }

            for _ in 0 ..< 101 {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.providerExecution,
                    EditFlowPerf.Dimensions(toolName: "read_file", status: "ok")
                ) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.retainedSampleCount, 100)
            XCTAssertEqual(snapshot.droppedSampleCount, 1)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            XCTAssertEqual(aggregate.sampleCount, 100)
            XCTAssertTrue(aggregate.sanitizedDimensions.contains("tool=read_file"))
            XCTAssertFalse(aggregate.sanitizedDimensions.contains("/"))
            XCTAssertFalse(aggregate.sanitizedDimensions.contains("namespace"))
        }

        func testLifecycleTimelinePreservesCorrelationOrderingAndSanitizesDimensions() throws {
            _ = startedCapture(label: "timeline", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            let unsafe = "unsafe /:|\\n" + String(repeating: "x", count: 100)

            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: correlation,
                EditFlowPerf.Dimensions(
                    toolName: unsafe,
                    storeCapacity: -1,
                    globalCapacity: -2,
                    storeActiveCount: -3,
                    globalActiveCount: -4,
                    storeQueueDepth: -5,
                    globalQueueDepth: -6,
                    workloadClass: unsafe,
                    admissionClass: unsafe,
                    queueAgeBucket: unsafe,
                    contentSource: unsafe,
                    rootToken: unsafe,
                    queueDepth: -7,
                    waiterCount: -8
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.routingSnapshotCompleted,
                correlation: correlation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.maxLifecycleEvents, 100)
            XCTAssertEqual(snapshot.retainedLifecycleEventCount, 2)
            XCTAssertEqual(snapshot.droppedLifecycleEventCount, 0)
            XCTAssertEqual(snapshot.lifecycleEvents.map(\.ordinal), [1, 2])
            XCTAssertEqual(snapshot.lifecycleEvents.map(\.eventName), [
                "MCP.ToolCall.Received",
                "MCP.ToolCall.RoutingSnapshotCompleted"
            ])
            XCTAssertEqual(Set(snapshot.lifecycleEvents.map(\.correlationID)).count, 1)
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("queueDepth=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("waiterCount=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("storeCapacity=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("globalCapacity=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("storeActiveCount=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("globalActiveCount=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("storeQueueDepth=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("globalQueueDepth=0"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("workloadClass=unsafe"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("admissionClass=unsafe"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("queueAgeBucket=unsafe"))
            XCTAssertTrue(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("contentSource=unsafe"))
            XCTAssertFalse(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("/"))
            XCTAssertFalse(snapshot.lifecycleEvents[0].sanitizedDimensions.contains("|"))
        }

        func testLifecycleTimelineBoundReportsDroppedEventsWithoutConsumingIntervalBudget() throws {
            _ = startedCapture(label: "timeline-bound", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            for _ in 0 ..< 101 {
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.MCPToolCall.received,
                    correlation: correlation,
                    EditFlowPerf.Dimensions(toolName: "read_file")
                )
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.retainedSampleCount, 0)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertEqual(snapshot.maxLifecycleEvents, 100)
            XCTAssertEqual(snapshot.retainedLifecycleEventCount, 100)
            XCTAssertEqual(snapshot.droppedLifecycleEventCount, 1)
            XCTAssertEqual(snapshot.lifecycleEvents.count, 100)
        }

        private func scenarioStaleLifecycleCorrelationCannotContaminateNextCapture() throws {
            _ = startedCapture(label: "timeline-a", maxSamples: 100)
            let staleCorrelation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            _ = startedCapture(label: "timeline-b", maxSamples: 100)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: staleCorrelation,
                EditFlowPerf.Dimensions(toolName: "read_file")
            )

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.label, "timeline-b")
            XCTAssertEqual(snapshot.retainedLifecycleEventCount, 0)
            XCTAssertEqual(snapshot.droppedLifecycleEventCount, 0)
            XCTAssertTrue(snapshot.lifecycleEvents.isEmpty)
        }

        func testInactiveLifecycleEventDoesNotEvaluateDimensionsAndAggregateOnlyPayloadOmitsTimeline() throws {
            var dimensionsEvaluated = false
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.received,
                correlation: nil,
                EditFlowPerf.Dimensions(toolName: {
                    dimensionsEvaluated = true
                    return "should_not_evaluate"
                }())
            )
            XCTAssertFalse(dimensionsEvaluated)

            var intervalDimensionsEvaluated = false
            let inactiveState = EditFlowPerf.begin(
                EditFlowPerf.Stage.Search.broadAdmissionLeaseHold,
                EditFlowPerf.Dimensions(admissionClass: {
                    intervalDimensionsEvaluated = true
                    return "should_not_evaluate"
                }())
            )
            XCTAssertNil(inactiveState)
            XCTAssertFalse(intervalDimensionsEvaluated)

            _ = startedCapture(label: "aggregate-only", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.MCPToolCall.received, correlation: correlation)
            let payload = EditFlowPerf.debugCaptureSnapshot(finish: true).payload(includeTimeline: false)
            XCTAssertEqual(payload["timeline_included"] as? Bool, false)
            XCTAssertNil(payload["lifecycle_events"])
            XCTAssertEqual(payload["retained_lifecycle_event_count"] as? Int, 1)
        }

        func testWithConnectionIDScopesLifecycleCorrelationAcrossChildTaskAndRestoresIt() async throws {
            _ = startedCapture(label: "connection-task-local", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            XCTAssertNil(EditFlowPerf.currentLifecycleCorrelation)

            let observed = await ServerNetworkManager.withConnectionID(UUID(), lifecycleCorrelation: correlation) {
                let immediate = EditFlowPerf.currentLifecycleCorrelation?.id
                let child = await Task { EditFlowPerf.currentLifecycleCorrelation?.id }.value
                return (immediate, child)
            }

            XCTAssertEqual(observed.0, correlation.id)
            XCTAssertEqual(observed.1, correlation.id)
            XCTAssertNil(EditFlowPerf.currentLifecycleCorrelation)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)
        }

        func testFileSystemPublicationScopesCorrelationDuringSynchronousSinkAndChildTask() async throws {
            let root = try temporaryRoots.makeRoot(suiteName: "FileSystemPublicationCorrelation")
            let service = try await FileSystemService(
                path: root.path,
                respectRepoIgnore: false,
                respectCursorignore: false,
                skipSymlinks: true
            )
            let publisher = await service.publisherForChanges()
            let childTaskCompleted = expectation(description: "sink child task captured publication correlation")
            let observations = LockedCorrelationIDs()
            let cancellable = publisher.sink { _ in
                observations.recordSink(EditFlowPerf.currentFileSystemPublicationCorrelation?.id)
                Task {
                    observations.recordChildTask(EditFlowPerf.currentFileSystemPublicationCorrelation?.id)
                    childTaskCompleted.fulfill()
                }
            }

            _ = startedCapture(label: "filesystem-publication", maxSamples: 100)
            XCTAssertNil(EditFlowPerf.currentFileSystemPublicationCorrelation)
            await service.publishFileSystemDeltas([.fileAdded("Synthetic.swift")], source: .syntheticMutation)
            XCTAssertNil(EditFlowPerf.currentFileSystemPublicationCorrelation)
            await fulfillment(of: [childTaskCompleted], timeout: 1)

            let ids = observations.snapshot()
            let sinkID = try XCTUnwrap(ids.sink)
            XCTAssertEqual(ids.childTask, sinkID)
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertTrue(snapshot.lifecycleEvents.contains {
                $0.eventName == "FileSystem.ServicePublish" && $0.correlationID == sinkID.uuidString
            })
            withExtendedLifetime(cancellable) {}
            await service.stopWatchingForChanges()
        }

        private func scenarioReadSearchBarrierDiagnosticsExposeBoundedPendingSuccessorState() throws {
            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            for hook in [
                "ScopedIngressBarrierRootFlightState",
                "ScopedIngressBarrierPendingFlight",
                "scopedIngressBarrierFlightStatesByRootID",
                "scopedIngressBarrierCoalescedSuccessorCountsByRootID",
                "flightState.pending = ScopedIngressBarrierPendingFlight(",
                "pending.target = pending.target.merging(target)",
                "flightState.active?.task?.cancel()",
                "flightState.pending?.join.complete(with: nil)"
            ] {
                XCTAssertTrue(store.contains(hook), "Missing bounded barrier-state hook: \(hook)")
            }
            XCTAssertFalse(store.contains("scopedIngressBarrierFlightsByRootID"))

            let diagnostics = try source(
                "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift"
            )
            XCTAssertTrue(diagnostics.contains("\"coalesced_successor_count\": snapshot.coalescedSuccessorCount"))
            XCTAssertTrue(diagnostics.contains("\"pending\": Self.debugOptionalValue(pending)"))
            XCTAssertTrue(diagnostics.contains("target_service_publication_sequence"))
            XCTAssertTrue(diagnostics.contains("\"age_ms\": pending.ageMilliseconds"))
        }

        @MainActor
        private func cleanupRuntimePendingBarrierTest(
            store: WorkspaceFileContextStore,
            rootID: UUID,
            flushGate: MCPDiagnosticsGate,
            activeBarrier: Task<[WorkspaceIngressBarrierSample], Never>,
            pendingBarrier: Task<[WorkspaceIngressBarrierSample], Never>?,
            coalescedBarrier: Task<[WorkspaceIngressBarrierSample], Never>?
        ) async -> Bool {
            await flushGate.release()

            var drainedFlights = await waitForScopedIngressBarrierFlightsToDrain(store: store)
            if !drainedFlights {
                activeBarrier.cancel()
                pendingBarrier?.cancel()
                coalescedBarrier?.cancel()
                _ = await activeBarrier.value
                _ = await pendingBarrier?.value
                _ = await coalescedBarrier?.value
                drainedFlights = await waitForScopedIngressBarrierFlightsToDrain(store: store)
            } else {
                _ = await activeBarrier.value
                _ = await pendingBarrier?.value
                _ = await coalescedBarrier?.value
            }

            await store.setScopedIngressBarrierWillFlushHandler(nil)
            await store.stopWatchingRoot(id: rootID)
            let drainedAfterStop = await waitForScopedIngressBarrierFlightsToDrain(store: store)
            return drainedFlights && drainedAfterStop
        }

        private func waitForDiagnosticsGateStart(
            _ gate: MCPDiagnosticsGate,
            label: String,
            attempts: Int = 200
        ) async throws {
            for _ in 0 ..< attempts {
                if await gate.hasStarted() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw MCPDiagnosticsTimeoutError(label: label)
        }

        private func waitForScopedIngressBarrierFlightsToDrain(
            store: WorkspaceFileContextStore,
            attempts: Int = 200
        ) async -> Bool {
            for _ in 0 ..< attempts {
                if await store.scopedIngressBarrierFlightCountForTesting() == 0 { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return await store.scopedIngressBarrierFlightCountForTesting() == 0
        }

        private struct MCPDiagnosticsTimeoutError: Error, CustomStringConvertible {
            let label: String

            var description: String {
                "Timed out waiting for diagnostics gate to start: \(label)"
            }
        }

        private actor MCPDiagnosticsGate {
            private var started = false
            private var released = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStartedAndWaitForRelease() async {
                started = true
                let pendingStartWaiters = startWaiters
                startWaiters.removeAll()
                pendingStartWaiters.forEach { $0.resume() }
                guard !released else { return }
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }

            func waitUntilStarted() async {
                guard !started else { return }
                await withCheckedContinuation { continuation in
                    startWaiters.append(continuation)
                }
            }

            func hasStarted() -> Bool {
                started
            }

            func release() {
                released = true
                let pendingReleaseWaiters = releaseWaiters
                releaseWaiters.removeAll()
                pendingReleaseWaiters.forEach { $0.resume() }
            }
        }

        private actor MCPDiagnosticsSignal {
            private var marked = false

            func mark() {
                marked = true
            }

            func isMarked() -> Bool {
                marked
            }
        }

        private actor MCPDiagnosticsSnapshotSignal {
            typealias Snapshot = AsyncLimiter.DebugSnapshot
            private var latest: Snapshot?
            private var waiter: (
                predicate: @Sendable (Snapshot) -> Bool,
                continuation: CheckedContinuation<Snapshot, Never>
            )?

            func record(_ snapshot: Snapshot) {
                latest = snapshot
                guard let waiter, waiter.predicate(snapshot) else { return }
                self.waiter = nil
                waiter.continuation.resume(returning: snapshot)
            }

            func waitUntil(
                _ predicate: @escaping @Sendable (Snapshot) -> Bool
            ) async -> Snapshot {
                if let latest, predicate(latest) { return latest }
                return await withCheckedContinuation { continuation in
                    waiter = (predicate, continuation)
                }
            }
        }

        private final class LockedMCPDiagnosticsClock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64

            init(nowNanoseconds: UInt64) {
                value = nowNanoseconds
            }

            func now() -> UInt64 {
                lock.lock()
                defer { lock.unlock() }
                return value
            }

            func advance(milliseconds: UInt64) {
                lock.lock()
                value &+= milliseconds * 1_000_000
                lock.unlock()
            }
        }

        private final class LockedCorrelationIDs: @unchecked Sendable {
            private let lock = NSLock()
            private var sinkID: UUID?
            private var childTaskID: UUID?

            func recordSink(_ id: UUID?) {
                lock.lock()
                sinkID = id
                lock.unlock()
            }

            func recordChildTask(_ id: UUID?) {
                lock.lock()
                childTaskID = id
                lock.unlock()
            }

            func snapshot() -> (sink: UUID?, childTask: UUID?) {
                lock.lock()
                defer { lock.unlock() }
                return (sinkID, childTaskID)
            }
        }

        @MainActor
        func testWI8ProviderProjectionWorkerRunsOffMainActorAndEmitsHandoffTimeline() async throws {
            _ = startedCapture(label: "wi8-provider-projection", maxSamples: 100)
            let identity = MCPRequestTimelineIdentity(
                jsonRPCRequestID: .string("wi8"),
                connectionID: UUID().uuidString,
                connectionGeneration: 1,
                requestOrdinal: 1
            )
            let correlation = try XCTUnwrap(
                EditFlowPerf.makeLifecycleCorrelationIfActive(requestIdentity: identity)
            )

            let workerRanOnMainThread = try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                try await MCPProviderProjectionWorker.run(
                    toolName: MCPWindowToolName.git,
                    phase: "test_projection"
                ) {
                    let ranOnMainThread = Thread.isMainThread
                    Thread.sleep(forTimeInterval: 0.02)
                    return ranOnMainThread
                }
            }
            XCTAssertFalse(workerRanOnMainThread)

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let handoffEvents = snapshot.lifecycleEvents.filter {
                $0.sanitizedDimensions.contains("outcome=test_projection")
            }
            XCTAssertEqual(handoffEvents.map(\.eventName), [
                "MCP.ToolCall.MainActorScheduled",
                "MCP.ToolCall.MainActorEntered",
                "MCP.ToolCall.MainActorExited",
                "MCP.ToolCall.MainActorScheduled",
                "MCP.ToolCall.MainActorEntered",
                "MCP.ToolCall.MainActorExited"
            ])
            XCTAssertTrue(handoffEvents.prefix(3).allSatisfy {
                $0.sanitizedDimensions.contains("observerType=provider_projection_capture")
            })
            XCTAssertTrue(handoffEvents.suffix(3).allSatisfy {
                $0.sanitizedDimensions.contains("observerType=provider_projection_resume")
            })
            let workerStage = try XCTUnwrap(snapshot.stages.first {
                $0.stageName == "EditFlow.MCPProviderProjection.WorkerBody"
            })
            XCTAssertEqual(workerStage.sanitizedDimensions, "tool=git outcome=test_projection")
            XCTAssertGreaterThanOrEqual(workerStage.p50MS, 10)
            XCTAssertGreaterThanOrEqual(
                handoffEvents[3].offsetMS - handoffEvents[2].offsetMS,
                10,
                "Worker body time must fall after MainActor exit and before resume scheduling"
            )
        }

        @MainActor
        func testWI8GitAndReadProjectionPreserveDTOContents() async throws {
            let patch = """
            diff --git a/Sample.swift b/Sample.swift
            --- a/Sample.swift
            +++ b/Sample.swift
            @@ -1,1 +1,1 @@
            -old
            +new
            """
            let changedFiles = [
                VCSUncommittedFile(path: "Sample.swift", status: "M", additions: 1, deletions: 1)
            ]
            let diff = try await MCPGitToolProjection.makeDiffDTO(
                compare: "uncommitted",
                detail: "patches",
                changedFiles: changedFiles,
                perFilePatches: ["Sample.swift": patch],
                maxLinesForPatches: 100
            )
            XCTAssertEqual(diff.totals, .init(files: 1, insertions: 1, deletions: 1))
            XCTAssertEqual(diff.byStatus, ["M": 1])
            XCTAssertEqual(diff.files?.first?.path, "Sample.swift")
            XCTAssertEqual(diff.files?.first?.hunks?.first?.oldStart, 1)
            XCTAssertEqual(diff.files?.first?.hunks?.first?.newStart, 1)
            XCTAssertEqual(diff.truncated, false)

            let prepared = WorkspaceInteractiveReadProcessor.prepare("one\r\ntwo\nthree")
            let read = try await MCPReadFileToolProjection.makeBaseReply(
                preparedContent: prepared,
                startLine1Based: 2,
                lineCount: 1,
                displayPath: "Sample.txt"
            )
            XCTAssertEqual(read.reply.content, "two\n")
            XCTAssertEqual(read.reply.totalLines, 3)
            XCTAssertEqual(read.reply.firstLine, 2)
            XCTAssertEqual(read.reply.lastLine, 2)
            XCTAssertEqual(read.returnedLineCount, 1)
        }

        private func assertSourceOrder(
            in source: String,
            hooks: [String],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            var searchStart = source.startIndex
            for hook in hooks {
                guard let match = source.range(of: hook, range: searchStart ..< source.endIndex) else {
                    XCTFail("Missing or out-of-order hook: \(hook)", file: file, line: line)
                    return
                }
                searchStart = match.upperBound
            }
        }

        private func withIsolatedCaptureCase(
            _ caseLabel: String,
            _ body: () throws -> Void
        ) rethrows {
            EditFlowPerf.resetDebugCaptureForTesting()
            defer { EditFlowPerf.resetDebugCaptureForTesting() }
            try XCTContext.runActivity(named: caseLabel) { _ in
                try body()
            }
        }

        private func startedCapture(
            label: String,
            maxSamples: Int,
            failureLabel: String? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                let message = [failureLabel, "Capture should start."]
                    .compactMap(\.self)
                    .joined(separator: ": ")
                XCTFail(message, file: file, line: line)
                fatalError(message)
            }
        }

        private func assertPermittedLabel(
            _ value: String,
            caseLabel: String? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let prefix = caseLabel.map { $0 + ": " } ?? ""
            XCTAssertLessThanOrEqual(value.unicodeScalars.count, 64, prefix + value, file: file, line: line)
            XCTAssertTrue(
                value.unicodeScalars.allSatisfy(allowed.contains),
                prefix + "Unexpected unsafe label: \(value)",
                file: file,
                line: line
            )
        }

        private func debugDiagnosticsPayload(
            _ result: CallTool.Result,
            caseLabel: String? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> [String: Any] {
            let text = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            let message = caseLabel ?? ""
            let data = try XCTUnwrap(text.data(using: .utf8), message, file: file, line: line)
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any],
                message,
                file: file,
                line: line
            )
        }

        private func diagnosticsSource() throws -> String {
            let root = try RepoRoot.url()
            let directory = root.appendingPathComponent("Sources/RepoPrompt/Features/Diagnostics/MCP")
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("MCPConnectionManager+DebugDiagnostics") && $0.pathExtension == "swift" }
                .map { try String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n")
        }

        private func source(_ relativePath: String) throws -> String {
            try String(contentsOf: RepoRoot.url().appendingPathComponent(relativePath), encoding: .utf8)
        }

        private func sourceFilesContaining(_ needle: String) throws -> [String] {
            let root = try RepoRoot.url()
            let sources = root.appendingPathComponent("Sources", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var matches: [String] = []
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                guard contents.contains(needle) else { continue }
                matches.append(RepoRoot.relativePath(for: fileURL, relativeTo: root))
            }
            return matches.sorted()
        }
    }

    private actor ProbeReleaseRecorder {
        private var releaseCount = 0

        func record() {
            releaseCount += 1
        }

        func count() -> Int {
            releaseCount
        }
    }
#endif
