import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorktreeStartupInstrumentationTests: XCTestCase {
        func testObservationAndServingFlagsDefaultEnabledAndServingRequiresObservation() throws {
            let suiteName = "WorktreeStartupInstrumentationTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            // Diff-seeded worktree startup ships ON by default: absent keys enable both routes.
            XCTAssertEqual(
                WorktreeStartupFeatureFlags.current(defaults: defaults),
                .init(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                )
            )
            // Serving still requires observation: explicit observe=false disables serving too.
            defaults.set(false, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            defaults.set(true, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            XCTAssertFalse(WorktreeStartupFeatureFlags.current(defaults: defaults).observeDiffSeededWorktreeStartup)
            XCTAssertFalse(WorktreeStartupFeatureFlags.current(defaults: defaults).serveDiffSeededWorktreeStartup)
            // serve=false is an explicit kill switch while observation stays enabled.
            defaults.set(true, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            defaults.set(false, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            XCTAssertEqual(
                WorktreeStartupFeatureFlags.current(defaults: defaults),
                .init(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: false
                )
            )
            // Both keys explicitly false disables both routes.
            defaults.set(false, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            XCTAssertEqual(WorktreeStartupFeatureFlags.current(defaults: defaults), .init())

            let automatic = WorktreeStartupContext(agentSessionID: UUID())
            XCTAssertEqual(automatic.servingControl, .automatic)
            let forced = WorktreeStartupContext(
                agentSessionID: UUID(),
                flags: .init(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                ),
                servingControl: .forceFullCrawl
            )
            XCTAssertEqual(forced.servingControl, .forceFullCrawl)
            XCTAssertTrue(forced.flags.serveDiffSeededWorktreeStartup)
        }

        func testScopedControlPreparesExactLoadedRootAndRejectsStaleScopeBeforeLease() async throws {
            let repositories = try ReviewGitRepositoryFixture(name: #function)
            let root = try repositories.makeRepository(
                named: "repository",
                files: ["Sources/App.swift": "struct ScopedControl {}\n"]
            )
            defer { repositories.cleanup() }

            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let store = WorkspaceFileContextStore()
            let loadedRoot = try await store.loadRoot(path: root.path)
            let exactScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 501,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: loadedRoot.id
            )

            let prepared = try await diagnostics.setFlagsPreparingBaseSnapshot(
                scope: exactScope,
                observe: false,
                serve: true,
                forceFullCrawl: false,
                expiresSeconds: 120,
                store: store,
                expectedStandardizedRootPath: loadedRoot.standardizedFullPath
            )
            XCTAssertTrue(prepared.baseSnapshotPrepared)
            let snapshotIdentity = try XCTUnwrap(prepared.baseSnapshotIdentity)
            XCTAssertFalse(snapshotIdentity.sha256.isEmpty)
            XCTAssertEqual(snapshotIdentity.searchABI, .current)
            XCTAssertEqual(prepared.control.route.name, "diffSeedServing")
            XCTAssertEqual(try diagnostics.reset(scope: exactScope)["control_count"], 1)

            let crossRootScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 502,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: loadedRoot.id
            )
            do {
                _ = try await diagnostics.setFlagsPreparingBaseSnapshot(
                    scope: crossRootScope,
                    observe: true,
                    serve: false,
                    forceFullCrawl: false,
                    expiresSeconds: 120,
                    store: store,
                    expectedStandardizedRootPath: root.deletingLastPathComponent().path
                )
                XCTFail("A mismatched loaded-root path must not create a benchmark control.")
            } catch {
                XCTAssertEqual(
                    error as? DebugWorktreeStartupBenchmarkError,
                    .baseSnapshotUnavailable(.init(
                        reason: .failed,
                        stage: .loadedRootValidation,
                        cause: "loaded_root_owner_stale"
                    ))
                )
            }
            XCTAssertEqual(try diagnostics.reset(scope: crossRootScope)["control_count"], 0)

            await store.unloadRoot(id: loadedRoot.id)
            let staleScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 503,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: loadedRoot.id
            )
            do {
                _ = try await diagnostics.setFlagsPreparingBaseSnapshot(
                    scope: staleScope,
                    observe: true,
                    serve: false,
                    forceFullCrawl: false,
                    expiresSeconds: 120,
                    store: store,
                    expectedStandardizedRootPath: loadedRoot.standardizedFullPath
                )
                XCTFail("An unloaded root must not create a benchmark control.")
            } catch {
                XCTAssertEqual(
                    error as? DebugWorktreeStartupBenchmarkError,
                    .baseSnapshotUnavailable(.init(
                        reason: .failed,
                        stage: .loadedRootValidation,
                        cause: "loaded_root_owner_stale"
                    ))
                )
            }
            XCTAssertEqual(try diagnostics.reset(scope: staleScope)["control_count"], 0)

            let forcedScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 504,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let forced = try await diagnostics.setFlagsPreparingBaseSnapshot(
                scope: forcedScope,
                observe: true,
                serve: true,
                forceFullCrawl: true,
                expiresSeconds: 120,
                store: store,
                expectedStandardizedRootPath: "/not-loaded"
            )
            XCTAssertFalse(forced.baseSnapshotPrepared)
            XCTAssertNil(forced.baseSnapshotIdentity)
            XCTAssertEqual(forced.control.route.name, "forcedFullCrawl")
            XCTAssertEqual(try diagnostics.reset(scope: forcedScope)["control_count"], 1)
        }

        func testNonGitMaterializationCarriesCorrelationUsesFullCrawlAndIssuesZeroGitCommands() async throws {
            let sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorktreeStartupInstrumentationTests-\(UUID().uuidString)", isDirectory: true)
            let logicalURL = sandbox.appendingPathComponent("logical", isDirectory: true)
            let physicalURL = sandbox.appendingPathComponent("physical", isDirectory: true)
            try FileManager.default.createDirectory(at: logicalURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: physicalURL, withIntermediateDirectories: true)
            try "struct PlainRoot {}\n".write(
                to: physicalURL.appendingPathComponent("Plain.swift"),
                atomically: true,
                encoding: .utf8
            )
            defer { try? FileManager.default.removeItem(at: sandbox) }

            let store = WorkspaceFileContextStore()
            let logicalRecord = try await store.loadRoot(path: logicalURL.path)
            let logicalRoot = WorkspaceRootRef(
                id: logicalRecord.id,
                name: logicalRecord.name,
                fullPath: logicalRecord.standardizedFullPath
            )
            let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalURL.path)
            let binding = AgentSessionWorktreeBinding(
                id: "instrumentation-binding",
                repositoryID: "non-git",
                repoKey: "non-git",
                logicalRootPath: logicalRoot.standardizedFullPath,
                logicalRootName: logicalRoot.name,
                worktreeID: "plain-root",
                worktreeRootPath: physicalRoot.standardizedFullPath,
                source: "test"
            )
            let context = WorktreeStartupContext(
                agentSessionID: UUID(),
                correlationID: UUID(),
                flags: .init()
            )
            let sessionID = UUID()
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            MCPToolWorkCountDiagnostics.resetForTesting()
            WorktreeStartupInstrumentation.resetForTesting()

            try await MCPToolWorkCountDiagnostics.withGitInvocation(operation: "non_git_worktree_startup") {
                let preparation = try await materializer.prepare(
                    sessionID: sessionID,
                    bindings: [binding],
                    startupContext: context
                )
                _ = try await materializer.commit(preparation)
            }

            let git = try XCTUnwrap(MCPToolWorkCountDiagnostics.debugSnapshots().git.last)
            XCTAssertEqual(git.commandCount, 0, git.commands.joined(separator: "\n"))
            let instrumentation = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(instrumentation.routeCounts, [.fullCrawl: 1])
            XCTAssertEqual(
                instrumentation.events.map(\.correlationID),
                Array(repeating: context.correlationID, count: instrumentation.events.count)
            )
            XCTAssertEqual(instrumentation.events.map(\.phase), [.rootLoadStarted, .rootReady])
            XCTAssertTrue(instrumentation.events.allSatisfy { !$0.observationEnabled && !$0.servingEnabled })
            XCTAssertTrue(instrumentation.deltaCompatibilityEvaluations.isEmpty)

            await materializer.release(sessionID: sessionID)
            await store.unloadRoot(id: logicalRecord.id)
        }

        func testShadowCountersAreBoundedAndPathFree() {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupInstrumentation.recordInventoryComparison(matched: true)
            WorktreeStartupInstrumentation.recordInventoryComparison(matched: false)
            WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                matched: true,
                baseEntryCount: 90,
                overlayEntryCount: 3,
                tombstoneCount: 2
            )
            WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                matched: false,
                baseEntryCount: 89,
                overlayEntryCount: 4,
                tombstoneCount: 3
            )

            let snapshot = WorktreeStartupInstrumentation.snapshot()
            let counters = snapshot.shadow
            XCTAssertEqual(counters.inventoryComparisons, 2)
            XCTAssertEqual(counters.inventoryMatches, 1)
            XCTAssertEqual(counters.inventoryMismatches, 1)
            XCTAssertEqual(counters.projectedSearchComparisons, 2)
            XCTAssertEqual(counters.projectedSearchMatches, 1)
            XCTAssertEqual(counters.projectedSearchMismatches, 1)
            XCTAssertEqual(counters.latestBaseEntryCount, 89)
            XCTAssertEqual(counters.latestOverlayEntryCount, 4)
            XCTAssertEqual(counters.latestTombstoneCount, 3)
            XCTAssertEqual(snapshot.fallbackCounts[.projectedSearchMismatch], 1)
        }

        func testSeedCountersAreBoundedPathFreeAndCountFallbackOnce() {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: true)
            WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: false)
            WorktreeStartupInstrumentation.recordSeedReplay(
                acceptedPayloadCount: Int.max,
                acceptedEventCount: 7,
                initializationWatermarkDelta: 5,
                serviceSequenceDelta: 4,
                changedPathCount: 3
            )
            WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(used: false)
            WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(used: true)
            WorktreeStartupInstrumentation.recordSeedProjectedPreparation(
                baseEntryCount: 90,
                overlayEntryCount: 3,
                tombstoneCount: 2
            )
            WorktreeStartupInstrumentation.recordSeedFullCrawlFallback()

            let seed = WorktreeStartupInstrumentation.snapshot().seed
            XCTAssertEqual(seed.receiptJournalCutPresent, 1)
            XCTAssertEqual(seed.receiptJournalCutAbsent, 1)
            XCTAssertEqual(seed.acceptedReplayPayloadCount, 1_000_000)
            XCTAssertEqual(seed.acceptedReplayEventCount, 7)
            XCTAssertEqual(seed.latestInitializationWatermarkDelta, 5)
            XCTAssertEqual(seed.latestServiceSequenceDelta, 4)
            XCTAssertEqual(seed.latestReplayChangedPathCount, 3)
            XCTAssertEqual(seed.metadataRevalidationChecks, 2)
            XCTAssertEqual(seed.metadataRevalidationUses, 1)
            XCTAssertEqual(seed.latestProjectedBaseEntryCount, 90)
            XCTAssertEqual(seed.latestProjectedOverlayEntryCount, 3)
            XCTAssertEqual(seed.latestProjectedTombstoneCount, 2)
            XCTAssertEqual(seed.fullCrawlFallbackCount, 1)
        }

        func testBenchmarkTokenRejectsCrossRootExternalDestinationAndReplay() throws {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 91,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(
                scope: scope,
                observe: true,
                serve: true,
                forceFullCrawl: false,
                expiresSeconds: 120
            )
            let arm = try diagnostics.arm(
                expectedStart: expected,
                controlID: control.controlID,
                scenario: "clean_same_tree",
                invocation: 1,
                ordinal: 1,
                warmup: false,
                expiresSeconds: 120
            )
            let valid = benchmarkValidatedStart(expected: expected)
            var wrongRoot = benchmarkValidatedStart(expected: expected)
            wrongRoot = DebugWorktreeStartupBenchmarkValidatedStart(
                scope: DebugWorktreeStartupBenchmarkScope(
                    windowID: scope.windowID,
                    workspaceID: scope.workspaceID,
                    contextID: scope.contextID,
                    rootID: UUID()
                ),
                logicalRootID: UUID(),
                standardizedLogicalRootPath: valid.standardizedLogicalRootPath,
                repositoryID: valid.repositoryID,
                repositoryKey: valid.repositoryKey,
                requestedBranch: valid.requestedBranch,
                requestedBaseRef: valid.requestedBaseRef,
                standardizedDestinationPath: valid.standardizedDestinationPath,
                standardizedAppManagedContainerPath: valid.standardizedAppManagedContainerPath,
                destinationID: valid.destinationID,
                agentSessionID: valid.agentSessionID,
                startAttemptID: valid.startAttemptID
            )
            XCTAssertThrowsError(try diagnostics.consume(token: arm.token, validatedStart: wrongRoot))

            let external = DebugWorktreeStartupBenchmarkValidatedStart(
                scope: valid.scope,
                logicalRootID: valid.logicalRootID,
                standardizedLogicalRootPath: valid.standardizedLogicalRootPath,
                repositoryID: valid.repositoryID,
                repositoryKey: valid.repositoryKey,
                requestedBranch: valid.requestedBranch,
                requestedBaseRef: valid.requestedBaseRef,
                standardizedDestinationPath: "/tmp/external-worktree",
                standardizedAppManagedContainerPath: valid.standardizedAppManagedContainerPath,
                destinationID: valid.destinationID,
                agentSessionID: valid.agentSessionID,
                startAttemptID: valid.startAttemptID
            )
            XCTAssertThrowsError(try diagnostics.consume(token: arm.token, validatedStart: external))
            XCTAssertEqual(try diagnostics.consume(token: arm.token, validatedStart: valid).correlationID, arm.correlationID)
            XCTAssertThrowsError(try diagnostics.consume(token: arm.token, validatedStart: valid))
        }

        func testDisablingBenchmarkGateImmediatelyRevokesArmedToken() throws {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let scope = DebugWorktreeStartupBenchmarkScope(windowID: 92, workspaceID: UUID(), contextID: UUID(), rootID: UUID())
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(scope: scope, observe: true, serve: false, forceFullCrawl: false, expiresSeconds: 120)
            let arm = try diagnostics.arm(expectedStart: expected, controlID: control.controlID, scenario: "clean_same_tree", invocation: 1, ordinal: 1, warmup: false, expiresSeconds: 120)
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false)
            XCTAssertThrowsError(try diagnostics.preflight(token: arm.token)) { error in
                XCTAssertEqual(error as? DebugWorktreeStartupBenchmarkError, .disabled)
            }
            XCTAssertThrowsError(try diagnostics.consume(token: arm.token, validatedStart: benchmarkValidatedStart(expected: expected)))
        }

        func testRoutingProvenanceRejectsForgedWindowAndContext() throws {
            let connectionID = UUID()
            let workspaceID = UUID()
            let contextID = UUID()
            let provenance = DebugWorktreeStartupBenchmarkRoutingProvenance(
                connectionID: connectionID,
                boundWindowID: 7,
                boundWorkspaceID: workspaceID,
                boundContextID: contextID
            )
            XCTAssertNoThrow(try provenance.authorize(connectionID: connectionID, windowID: 7, hiddenWindowID: 7, workspaceID: workspaceID, contextID: contextID, benchmarkContextID: contextID))
            XCTAssertThrowsError(try provenance.authorize(connectionID: connectionID, windowID: 8, hiddenWindowID: 7, workspaceID: workspaceID, contextID: contextID, benchmarkContextID: contextID))
            XCTAssertThrowsError(try provenance.authorize(connectionID: connectionID, windowID: 7, hiddenWindowID: 7, workspaceID: workspaceID, contextID: UUID(), benchmarkContextID: contextID))
        }

        func testBenchmarkMetricsAreCorrelationIsolatedAndAmbiguousCodemapIsUnavailable() {
            WorktreeStartupInstrumentation.resetForTesting()
            let tagA = benchmarkMetricTag(correlationID: UUID())
            let tagB = benchmarkMetricTag(correlationID: UUID())
            WorktreeStartupInstrumentation.recordBenchmarkFilesystemWork(tag: tagA, durationMicroseconds: 11, itemCount: 2)
            WorktreeStartupInstrumentation.recordBenchmarkFilesystemWork(tag: tagB, durationMicroseconds: 99, itemCount: 50)
            WorktreeStartupInstrumentation.recordBenchmarkContentReadWork(tag: tagA, waitMicroseconds: 3, executionMicroseconds: 7, overloaded: false)
            WorktreeStartupInstrumentation.recordBenchmarkContentReadWork(tag: tagB, waitMicroseconds: 30, executionMicroseconds: 70, overloaded: false)
            WorktreeStartupInstrumentation.recordBenchmarkCodemapWork(tag: tagA, durations: nil, buildPerformed: false, exactlyAttributed: false)
            let snapshot = WorktreeStartupInstrumentation.benchmarkMetricSnapshot(for: tagA)
            XCTAssertEqual(snapshot.filesystemDurationMicroseconds, 11)
            XCTAssertEqual(snapshot.filesystemItemCount, 2)
            XCTAssertEqual(snapshot.contentReadWaitMicroseconds, 3)
            XCTAssertEqual(snapshot.contentReadExecutionMicroseconds, 7)
            XCTAssertEqual(snapshot.codemapAttribution, .unavailable)
        }

        func testReceiptDecisionBufferCapsAt128AndEvictsOldestTerminalBeforeNonterminal() {
            WorktreeStartupInstrumentation.resetForTesting()
            let oldestTerminal = UUID()
            let oldestNonterminal = UUID()
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: oldestTerminal,
                decision: .init(),
                terminal: true
            )
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: oldestNonterminal,
                decision: .init()
            )
            for _ in 0 ..< 126 {
                WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                    correlationID: UUID(),
                    decision: .init()
                )
            }
            let newest = UUID()
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: newest,
                decision: .init()
            )

            let snapshot = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(snapshot.receiptDecisions.count, 128)
            XCTAssertEqual(snapshot.receiptDecisionEvictionCount, 1)
            XCTAssertTrue(snapshot.receiptDecisions.contains { $0.correlationID == oldestNonterminal })
            XCTAssertTrue(snapshot.receiptDecisions.contains { $0.correlationID == newest })
            XCTAssertFalse(snapshot.receiptDecisions.contains { $0.correlationID == oldestTerminal })

            WorktreeStartupInstrumentation.resetForTesting()
            let oldest = UUID()
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: oldest,
                decision: .init()
            )
            for _ in 0 ..< 128 {
                WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                    correlationID: UUID(),
                    decision: .init()
                )
            }
            XCTAssertFalse(
                WorktreeStartupInstrumentation.receiptDecisions().contains { $0.correlationID == oldest }
            )
        }

        func testReceiptDecisionStagesAreCorrelationIsolatedAndAggregateOnce() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            let first = UUID()
            let second = UUID()
            var creation = WorktreeStartupInstrumentation.ReceiptCreationDecision()
            creation.sourceLayoutState = .linkedWorktree
            creation.outcome = .receiptEmitted
            creation.receiptEmitted = true
            var coordinator = WorktreeStartupInstrumentation.ReceiptCoordinatorDecision()
            coordinator.createResultReceiptCount = 1
            coordinator.hintCount = 1
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: first,
                decision: creation
            )
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: first,
                decision: coordinator
            )
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: second,
                decision: .init()
            )

            let firstDecision = try XCTUnwrap(
                WorktreeStartupInstrumentation.receiptDecisions(correlationID: first).first
            )
            XCTAssertEqual(firstDecision.creation, creation)
            XCTAssertEqual(firstDecision.coordinator, coordinator)
            XCTAssertNil(firstDecision.projection)
            XCTAssertEqual(firstDecision.creationAttemptCount, 1)
            XCTAssertFalse(firstDecision.ambiguousOrDuplicate)
            XCTAssertEqual(WorktreeStartupInstrumentation.receiptDecisions().count, 2)
        }

        func testReceiptDecisionDuplicateConflictInvalidatesAndFirstTerminalWins() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            let correlationID = UUID()
            var coordinator = WorktreeStartupInstrumentation.ReceiptCoordinatorDecision()
            coordinator.bindingCount = 1
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: correlationID,
                decision: coordinator,
                terminal: true
            )
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: correlationID,
                decision: coordinator,
                terminal: true
            )
            XCTAssertFalse(try XCTUnwrap(
                WorktreeStartupInstrumentation.receiptDecisions(correlationID: correlationID).first
            ).ambiguousOrDuplicate)

            var conflicting = coordinator
            conflicting.hintCount = 1
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: correlationID,
                decision: conflicting
            )
            WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                correlationID: correlationID,
                decision: .init(),
                terminal: true
            )
            let decision = try XCTUnwrap(
                WorktreeStartupInstrumentation.receiptDecisions(correlationID: correlationID).first
            )
            XCTAssertTrue(decision.ambiguousOrDuplicate)
            XCTAssertEqual(decision.coordinator, coordinator)
            XCTAssertNotNil(decision.consumption)
            XCTAssertEqual(decision.terminalStage, .coordinator)

            let duplicateCreationID = UUID()
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: duplicateCreationID,
                decision: .init()
            )
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: duplicateCreationID,
                decision: .init()
            )
            let duplicate = try XCTUnwrap(
                WorktreeStartupInstrumentation.receiptDecisions(correlationID: duplicateCreationID).first
            )
            XCTAssertTrue(duplicate.ambiguousOrDuplicate)
            XCTAssertEqual(duplicate.creationAttemptCount, 2)
        }

        func testDeltaCompatibilityEvaluationRecordsAreCorrelationScopedBoundedAndFailOnDuplicates() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            let correlationID = UUID()
            let base = WorkspaceRootSeedTestSupport.compatibilityKey()
            let evaluator = base.deltaCompatibilityEvaluation(with: base, source: .hintEvaluator)
            let planner = base.deltaCompatibilityEvaluation(with: base, source: .planner)

            func record(
                _ evaluation: WorkspaceRootSeedDeltaCompatibilityEvaluation,
                correlationID: UUID = correlationID,
                terminalFallback: WorkspaceRootSeedFallbackReason? = nil
            ) {
                WorktreeStartupInstrumentation.recordDeltaCompatibilityEvaluation(
                    correlationID: correlationID,
                    evaluation: evaluation,
                    exactSnapshotLookupReached: true,
                    exactSnapshotLookupPassed: true,
                    targetAuthorityComparisonReached: true,
                    targetAuthorityComparisonPassed: true,
                    currentSearchABIReached: evaluation.source == .hintEvaluator,
                    currentSearchABIMatched: evaluation.source == .hintEvaluator ? true : nil,
                    catalogPolicyComparisonReached: evaluation.source == .planner,
                    catalogPolicyMatched: evaluation.source == .planner ? true : nil,
                    terminalFallback: terminalFallback
                )
            }

            record(evaluator)
            record(planner)
            XCTAssertEqual(
                WorktreeStartupInstrumentation.deltaCompatibilityEvaluations(correlationID: correlationID)
                    .map(\.evaluation.source),
                [.hintEvaluator, .planner]
            )

            record(evaluator)
            var stored = try XCTUnwrap(
                WorktreeStartupInstrumentation.deltaCompatibilityEvaluations(correlationID: correlationID)
                    .first { $0.evaluation.source == .hintEvaluator }
            )
            XCTAssertTrue(stored.duplicate)
            XCTAssertFalse(stored.contradictory)
            XCTAssertEqual(stored.evaluation, evaluator)

            record(evaluator, terminalFallback: .compatibilityMismatch)
            stored = try XCTUnwrap(
                WorktreeStartupInstrumentation.deltaCompatibilityEvaluations(correlationID: correlationID)
                    .first { $0.evaluation.source == .hintEvaluator }
            )
            XCTAssertTrue(stored.duplicate)
            XCTAssertTrue(stored.contradictory)
            XCTAssertNil(stored.terminalFallback)

            for _ in 0 ..< 127 {
                record(evaluator, correlationID: UUID())
            }
            XCTAssertEqual(WorktreeStartupInstrumentation.deltaCompatibilityEvaluations().count, 128)
            XCTAssertEqual(WorktreeStartupInstrumentation.currentDeltaCompatibilityEvaluationEvictionCount(), 1)

            WorktreeStartupInstrumentation.resetForTesting()
            XCTAssertTrue(WorktreeStartupInstrumentation.deltaCompatibilityEvaluations().isEmpty)
            XCTAssertEqual(WorktreeStartupInstrumentation.currentDeltaCompatibilityEvaluationEvictionCount(), 0)
        }

        func testCanonicalizationComparisonParticipatesInDuplicateAndContradictionDetection() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            let correlationID = UUID()
            let base = WorkspaceRootSeedTestSupport.compatibilityKey(
                canonicalizationDiagnostics: WorkspaceRootSeedTestSupport.canonicalizationDiagnostics(
                    prunedRootCount: 1
                )
            )
            let target = WorkspaceRootSeedTestSupport.compatibilityKey(
                canonicalizationDiagnostics: WorkspaceRootSeedTestSupport.canonicalizationDiagnostics()
            )
            let evaluation = target.deltaCompatibilityEvaluation(with: base, source: .hintEvaluator)
            let comparison = try XCTUnwrap(GitWorkspacePolicyCanonicalizationDiagnostics.comparison(
                base: base.policyIdentity,
                target: target.policyIdentity
            ))

            func record(_ comparison: GitWorkspacePolicyCanonicalizationDiagnostics.Comparison) {
                WorktreeStartupInstrumentation.recordDeltaCompatibilityEvaluation(
                    correlationID: correlationID,
                    evaluation: evaluation,
                    policyCanonicalizationComparison: comparison,
                    exactSnapshotLookupReached: true,
                    exactSnapshotLookupPassed: true,
                    targetAuthorityComparisonReached: true,
                    targetAuthorityComparisonPassed: true,
                    currentSearchABIReached: true,
                    currentSearchABIMatched: true,
                    catalogPolicyComparisonReached: false,
                    catalogPolicyMatched: nil,
                    terminalFallback: nil
                )
            }

            record(comparison)
            record(comparison)
            var stored = try XCTUnwrap(
                WorktreeStartupInstrumentation.deltaCompatibilityEvaluations(correlationID: correlationID).first
            )
            XCTAssertTrue(stored.duplicate)
            XCTAssertFalse(stored.contradictory)

            let contradictoryTarget = WorkspaceRootSeedTestSupport.compatibilityKey(
                canonicalizationDiagnostics: WorkspaceRootSeedTestSupport.canonicalizationDiagnostics(
                    committedControlSummarySHA256: String(repeating: "e", count: 64)
                )
            )
            let contradictoryComparison = try XCTUnwrap(
                GitWorkspacePolicyCanonicalizationDiagnostics.comparison(
                    base: base.policyIdentity,
                    target: contradictoryTarget.policyIdentity
                )
            )
            XCTAssertEqual(contradictoryComparison.classification, .semanticInputDifference)
            record(contradictoryComparison)
            stored = try XCTUnwrap(
                WorktreeStartupInstrumentation.deltaCompatibilityEvaluations(correlationID: correlationID).first
            )
            XCTAssertTrue(stored.duplicate)
            XCTAssertTrue(stored.contradictory)
        }

        func testCanonicalizationDiagnosticSummariesRemainCompleteBeyondFormerCountCaps() {
            let large = WorkspaceRootSeedTestSupport.canonicalizationDiagnostics(
                prunedRootCount: 65,
                committedControlCount: 4097
            )
            XCTAssertEqual(large.prunedRootCount, 65)
            XCTAssertEqual(large.committedControlCount, 4097)
            XCTAssertEqual(large.prunedRootSummarySHA256.utf8.count, 64)
            XCTAssertEqual(large.committedControlSummarySHA256.utf8.count, 64)

            let matchingLarge = WorkspaceRootSeedTestSupport.canonicalizationDiagnostics(
                prunedRootCount: 65,
                committedControlCount: 4097
            )
            let largeKey = WorkspaceRootSeedTestSupport.compatibilityKey(canonicalizationDiagnostics: large)
            let matchingKey = WorkspaceRootSeedTestSupport.compatibilityKey(
                canonicalizationDiagnostics: matchingLarge
            )
            XCTAssertEqual(
                GitWorkspacePolicyCanonicalizationDiagnostics.comparison(
                    base: largeKey.policyIdentity,
                    target: matchingKey.policyIdentity
                )?.classification,
                .canonicalEquivalentAfterReachabilityFiltering
            )

            let defaultKey = WorkspaceRootSeedTestSupport.compatibilityKey(
                canonicalizationDiagnostics: WorkspaceRootSeedTestSupport.canonicalizationDiagnostics()
            )
            XCTAssertEqual(defaultKey.policyIdentity, largeKey.policyIdentity)
            XCTAssertEqual(Set([defaultKey.policyIdentity, largeKey.policyIdentity]).count, 1)

            let incoherent = WorkspaceRootSeedTestSupport.canonicalizationDiagnostics(
                prunedRootSummarySHA256: "not-a-digest"
            )
            let incoherentKey = WorkspaceRootSeedTestSupport.compatibilityKey(
                canonicalizationDiagnostics: incoherent
            )
            XCTAssertEqual(
                GitWorkspacePolicyCanonicalizationDiagnostics.comparison(
                    base: defaultKey.policyIdentity,
                    target: incoherentKey.policyIdentity
                )?.classification,
                .incoherent
            )
        }

        func testReceiptDecisionSchemaV6ExportIsTerminalBoundedPathFreeAndOperationCorrelated() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 611,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(
                scope: scope,
                observe: true,
                serve: true,
                forceFullCrawl: false,
                expiresSeconds: 120
            )
            let arm = try diagnostics.arm(
                expectedStart: expected,
                controlID: control.controlID,
                scenario: "receipt_path_privacy",
                invocation: 1,
                ordinal: 1,
                warmup: false,
                expiresSeconds: 120
            )
            let consumed = try diagnostics.consume(
                token: arm.token,
                validatedStart: benchmarkValidatedStart(expected: expected)
            )
            let pathSentinel = "/private/receipt-path-sentinel"
            var creation = WorktreeStartupInstrumentation.ReceiptCreationDecision()
            creation.sourceLayoutState = .linkedWorktree
            creation.sourceCommonDirectoryDigest = WorktreeStartupInstrumentation.receiptDecisionDigest(
                pathSentinel,
                domain: .commonDirectory
            )
            creation.outcome = .receiptEmitted
            creation.receiptEmitted = true
            creation.witnessStartEventID = 100
            creation.witnessEndEventID = 200
            creation.witnessStartAcceptedCallbackWatermark = 2
            creation.witnessEndAcceptedCallbackWatermark = 4
            creation.witnessAcceptedCallbackCount = 4
            creation.witnessAcceptedEventCount = 300
            creation.witnessAcceptedDestinationEventCount = 257
            creation.witnessAcceptedNonDestinationEventCount = 43
            creation.witnessMustScanSubDirs = false
            creation.witnessRootChanged = false
            creation.witnessUserDropped = false
            creation.witnessKernelDropped = false
            creation.witnessEventIDsWrapped = false
            creation.witnessEventIDRegressed = false
            WorktreeStartupInstrumentation.recordReceiptCreationDecision(
                correlationID: arm.correlationID,
                decision: creation
            )
            WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                correlationID: arm.correlationID,
                decision: .init()
            )
            WorktreeStartupInstrumentation.recordReceiptProjectionDecision(
                correlationID: arm.correlationID,
                decision: .init()
            )
            var consumption = WorktreeStartupInstrumentation.ReceiptConsumptionDecision()
            consumption.finalObservation = .eligible
            consumption.selectedRoute = .diffSeedServing
            consumption.fullCrawlPerformed = false
            WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                correlationID: arm.correlationID,
                decision: consumption
            )
            let canonicalizationPathSentinel = "/private/ignored-derived-controls"
            let baseCompatibility = WorkspaceRootSeedTestSupport.compatibilityKey(
                canonicalizationDiagnostics: WorkspaceRootSeedTestSupport.canonicalizationDiagnostics(
                    prunedRootCount: 1,
                    prunedRootSummarySHA256: GitWorkspacePolicyCanonicalizationDiagnostics
                        .repositoryRelativePathFingerprint(canonicalizationPathSentinel)
                )
            )
            let compatibility = WorkspaceRootSeedTestSupport.compatibilityKey(
                canonicalizationDiagnostics: WorkspaceRootSeedTestSupport.canonicalizationDiagnostics()
            )
            func recordCompatibility(
                _ source: WorkspaceRootSeedDeltaCompatibilitySource,
                correlationID: UUID = arm.correlationID,
                terminalFallback: WorkspaceRootSeedFallbackReason? = nil
            ) {
                WorktreeStartupInstrumentation.recordDeltaCompatibilityEvaluation(
                    correlationID: correlationID,
                    evaluation: compatibility.deltaCompatibilityEvaluation(
                        with: baseCompatibility,
                        source: source
                    ),
                    policyCanonicalizationComparison: GitWorkspacePolicyCanonicalizationDiagnostics.comparison(
                        base: baseCompatibility.policyIdentity,
                        target: compatibility.policyIdentity
                    ),
                    exactSnapshotLookupReached: true,
                    exactSnapshotLookupPassed: true,
                    targetAuthorityComparisonReached: true,
                    targetAuthorityComparisonPassed: true,
                    currentSearchABIReached: source == .hintEvaluator,
                    currentSearchABIMatched: source == .hintEvaluator ? true : nil,
                    catalogPolicyComparisonReached: source == .planner,
                    catalogPolicyMatched: source == .planner ? true : nil,
                    terminalFallback: terminalFallback
                )
            }
            recordCompatibility(.hintEvaluator)
            recordCompatibility(.planner)
            let context = WorktreeStartupContext(
                agentSessionID: consumed.metricTag.agentSessionID,
                correlationID: arm.correlationID,
                flags: consumed.flags,
                servingControl: consumed.servingControl
            )
            WorktreeStartupInstrumentation.record(.bindingTransitionStarted, context: context)
            WorktreeStartupInstrumentation.record(.rootReady, context: context, route: .diffSeedServing)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .firstBenchmarkSearchStarted)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .firstBenchmarkReadStarted)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .firstBenchmarkReadCompleted)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .firstBenchmarkSearchCompleted)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .firstBenchmarkCodemapStarted)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .firstBenchmarkCodemapCompleted)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .warmBenchmarkCodemapStarted)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .warmBenchmarkCodemapCompleted)
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .passiveBenchmarkTreeStarted)
            let passiveTag = try XCTUnwrap(
                diagnostics.activeBenchmarkMetricTag(agentSessionID: consumed.metricTag.agentSessionID)
            )
            WorktreeStartupInstrumentation.recordBenchmarkPassiveTree(
                tag: passiveTag,
                durationMicroseconds: 13
            )
            let markerRootID = UUID()
            let markerLifetimeID = UUID()
            WorktreeStartupInstrumentation.recordBenchmarkMarkerPublication(
                tag: passiveTag,
                rootID: markerRootID,
                rootLifetimeID: markerLifetimeID,
                revision: 4,
                effectiveChangeCount: 1,
                source: .warmReplay
            )
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .passiveBenchmarkTreeCompleted)
            XCTAssertNil(
                diagnostics.activeBenchmarkMetricTag(agentSessionID: consumed.metricTag.agentSessionID)
            )
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .benchmarkSelectionStarted)
            XCTAssertEqual(
                diagnostics.activeBenchmarkMetricTag(agentSessionID: consumed.metricTag.agentSessionID),
                consumed.metricTag
            )
            try diagnostics.mark(scope: scope, correlationID: arm.correlationID, phase: .benchmarkSelectionCompleted)
            XCTAssertThrowsError(
                try diagnostics.mark(
                    scope: scope,
                    correlationID: arm.correlationID,
                    phase: .firstBenchmarkSearchStarted
                )
            ) { error in
                XCTAssertEqual(error as? DebugWorktreeStartupBenchmarkError, .invalidTransition)
            }
            WorktreeStartupInstrumentation.recordBenchmarkPlannerPhase(
                tag: consumed.metricTag,
                phase: .targetNamespace,
                durationMicroseconds: 11,
                itemCount: 2
            )
            WorktreeStartupInstrumentation.recordBenchmarkMutationLock(
                tag: consumed.metricTag,
                queueWaitMicroseconds: 3,
                heldMicroseconds: 7
            )
            WorktreeStartupInstrumentation.recordBenchmarkMutationWork(
                tag: consumed.metricTag,
                mutationDurationMicroseconds: 5,
                postMutationFinalizationMicroseconds: 9
            )

            let payload = try diagnostics.snapshotPayload(
                scope: scope,
                correlationID: arm.correlationID,
                export: true
            )
            XCTAssertEqual(payload["schema_version"] as? Int, 6)
            XCTAssertEqual(payload["bounded"] as? Bool, true)
            XCTAssertEqual(payload["contains_paths"] as? Bool, false)
            XCTAssertEqual(payload["receipt_decision_count"] as? Int, 1)
            XCTAssertEqual(payload["terminal_receipt_decision_count"] as? Int, 1)
            XCTAssertEqual(payload["receipt_decision_buffer_evicted"] as? Bool, false)
            XCTAssertEqual(payload["receipt_decision_ambiguous"] as? Bool, false)
            XCTAssertEqual(payload["delta_compatibility_evaluation_count"] as? Int, 2)
            XCTAssertEqual(payload["delta_compatibility_evaluation_buffer_evicted"] as? Bool, false)
            XCTAssertEqual(payload["delta_compatibility_evaluation_ambiguous"] as? Bool, false)
            XCTAssertEqual(payload["delta_compatibility_evaluation_contradictory"] as? Bool, false)
            let compatibilityPayloads = try XCTUnwrap(
                payload["delta_compatibility_evaluations"] as? [[String: Any]]
            )
            XCTAssertEqual(compatibilityPayloads.map { $0["source"] as? String }, ["hintEvaluator", "planner"])
            XCTAssertTrue(compatibilityPayloads.allSatisfy {
                ($0["field_evaluations"] as? [[String: Any]])?.count == 15
                    && ($0["mismatched_fields"] as? [String]) == []
                    && ($0["correction_rule_applied"] as? String) == "none"
            })
            let canonicalizationComparison = try XCTUnwrap(
                compatibilityPayloads.first?["policy_canonicalization_comparison"] as? [String: Any]
            )
            XCTAssertEqual(
                canonicalizationComparison["classification"] as? String,
                "canonicalEquivalentAfterReachabilityFiltering"
            )
            let constituentComparisons = try XCTUnwrap(
                canonicalizationComparison["constituent_comparisons"] as? [[String: Any]]
            )
            XCTAssertEqual(
                constituentComparisons.compactMap { $0["constituent"] as? String },
                GitWorkspacePolicyCanonicalizationDiagnostics.Constituent.allCases.map(\.rawValue)
            )
            XCTAssertEqual(
                constituentComparisons.first { $0["constituent"] as? String == "canonicalization" }?["matched"]
                    as? Bool,
                true
            )
            let baseCanonicalization = try XCTUnwrap(canonicalizationComparison["base"] as? [String: Any])
            let baseConstituents = try XCTUnwrap(baseCanonicalization["constituents"] as? [[String: Any]])
            XCTAssertEqual(
                baseConstituents.compactMap { $0["constituent"] as? String },
                GitWorkspacePolicyCanonicalizationDiagnostics.Constituent.allCases.map(\.rawValue)
            )
            let sample = try XCTUnwrap(payload["sample"] as? [String: Any])
            XCTAssertEqual(sample["valid"] as? Bool, true)
            XCTAssertEqual(sample["boundary_evidence_available"] as? Bool, true)
            XCTAssertEqual(sample["boundary_invalid_reasons"] as? [String], [])
            XCTAssertNotNil(sample["interactive_readiness_us"] as? UInt64)
            let durations = try XCTUnwrap(sample["durations_us"] as? [String: UInt64])
            for key in ["first_search", "first_read", "first_codemap", "warm_codemap", "passive_tree", "selection"] {
                XCTAssertNotNil(durations[key], key)
            }
            let work = try XCTUnwrap(payload["work"] as? [String: Any])
            let planner = try XCTUnwrap(work["planner"] as? [String: [String: Any]])
            XCTAssertEqual(planner["targetNamespace"]?["duration_us"] as? UInt64, 11)
            XCTAssertEqual(planner["targetNamespace"]?["item_count"] as? Int, 2)
            let mutation = try XCTUnwrap(work["mutation_lock"] as? [String: Any])
            XCTAssertEqual(mutation["queue_wait_us"] as? UInt64, 3)
            XCTAssertEqual(mutation["held_us"] as? UInt64, 7)
            XCTAssertEqual(mutation["mutation_us"] as? UInt64, 5)
            XCTAssertEqual(mutation["post_mutation_finalization_us"] as? UInt64, 9)
            let markers = try XCTUnwrap(work["marker_publications"] as? [[String: Any]])
            XCTAssertEqual(markers.count, 1)
            XCTAssertEqual(markers.first?["root_id"] as? String, markerRootID.uuidString)
            XCTAssertEqual(markers.first?["root_lifetime_id"] as? String, markerLifetimeID.uuidString)
            XCTAssertEqual(markers.first?["source"] as? String, "warmReplay")
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let exported = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(exported.contains(pathSentinel))
            XCTAssertFalse(exported.contains(canonicalizationPathSentinel))
            XCTAssertTrue(exported.contains("source_common_directory_digest"))
            XCTAssertTrue(exported.contains("\"witness_start_event_id\":100"))
            XCTAssertTrue(exported.contains("\"witness_end_event_id\":200"))
            XCTAssertTrue(exported.contains("\"witness_accepted_destination_event_count\":257"))
            XCTAssertTrue(exported.contains("\"witness_accepted_non_destination_event_count\":43"))
            XCTAssertTrue(exported.contains("\"witness_user_dropped\":false"))

            recordCompatibility(.hintEvaluator)
            let duplicatePayload = try diagnostics.snapshotPayload(
                scope: scope,
                correlationID: arm.correlationID,
                export: false
            )
            XCTAssertEqual(duplicatePayload["delta_compatibility_evaluation_ambiguous"] as? Bool, true)
            XCTAssertEqual(duplicatePayload["delta_compatibility_evaluation_contradictory"] as? Bool, false)
            XCTAssertEqual((duplicatePayload["sample"] as? [String: Any])?["valid"] as? Bool, false)

            recordCompatibility(.hintEvaluator, terminalFallback: .compatibilityMismatch)
            let contradictoryPayload = try diagnostics.snapshotPayload(
                scope: scope,
                correlationID: arm.correlationID,
                export: false
            )
            XCTAssertEqual(
                contradictoryPayload["delta_compatibility_evaluation_contradictory"] as? Bool,
                true
            )
            XCTAssertEqual((contradictoryPayload["sample"] as? [String: Any])?["valid"] as? Bool, false)

            for _ in 0 ..< 127 {
                recordCompatibility(.hintEvaluator, correlationID: UUID())
            }
            let evictedPayload = try diagnostics.snapshotPayload(
                scope: scope,
                correlationID: arm.correlationID,
                export: false
            )
            XCTAssertEqual(evictedPayload["delta_compatibility_evaluation_buffer_evicted"] as? Bool, true)
            XCTAssertEqual((evictedPayload["sample"] as? [String: Any])?["valid"] as? Bool, false)

            var boundaryEvents = Dictionary(
                uniqueKeysWithValues: WorktreeStartupBenchmarkDiagnostics.requiredBoundaryPhasesForTesting
                    .enumerated().map { index, phase in
                        (phase, UInt64(10000 + index * 1000))
                    }
            )
            boundaryEvents[.rootReady] = 9999
            let invalidBoundary = WorktreeStartupBenchmarkDiagnostics.boundaryEvidenceForTesting(
                boundaryEvents,
                baseline: 10000
            )
            XCTAssertFalse(invalidBoundary.valid)
            XCTAssertTrue(invalidBoundary.milestones[WorktreeStartupPhase.rootReady.rawValue] is NSNull)
            XCTAssertTrue(invalidBoundary.invalidReasons.contains("pre_baseline_rootReady"))
        }

        func testReceiptDecisionEvictionInvalidatesBenchmarkSampleAndResetClearsState() throws {
            WorktreeStartupInstrumentation.resetForTesting()
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 612,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(
                scope: scope,
                observe: true,
                serve: false,
                forceFullCrawl: false,
                expiresSeconds: 120
            )
            let arm = try diagnostics.arm(
                expectedStart: expected,
                controlID: control.controlID,
                scenario: "receipt_eviction",
                invocation: 1,
                ordinal: 1,
                warmup: false,
                expiresSeconds: 120
            )
            _ = try diagnostics.consume(
                token: arm.token,
                validatedStart: benchmarkValidatedStart(expected: expected)
            )
            WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                correlationID: arm.correlationID,
                decision: .init()
            )
            for _ in 0 ..< 128 {
                WorktreeStartupInstrumentation.recordReceiptCoordinatorDecision(
                    correlationID: UUID(),
                    decision: .init()
                )
            }

            let payload = try diagnostics.snapshotPayload(
                scope: scope,
                correlationID: arm.correlationID,
                export: false
            )
            XCTAssertEqual(payload["receipt_decision_buffer_evicted"] as? Bool, true)
            XCTAssertEqual((payload["sample"] as? [String: Any])?["valid"] as? Bool, false)

            WorktreeStartupInstrumentation.resetForTesting()
            let resetSnapshot = WorktreeStartupInstrumentation.snapshot()
            XCTAssertTrue(resetSnapshot.receiptDecisions.isEmpty)
            XCTAssertEqual(resetSnapshot.receiptDecisionEvictionCount, 0)
        }

        func testPreparationRecorderReportsActiveCompletedSaturatingPathFreeSchema() {
            let preparationID = UUID()
            let recorder = WorktreeStartupPreparationInstrumentation.Recorder(preparationID: preparationID)
            recorder.recordCompleted(.scopeResolution, durationNanoseconds: 5000)
            let total = recorder.begin(.setFlagsTotal)
            let scan = recorder.begin(.prefixControlScan)
            recorder.increment(.authorityCaptures, by: 2)
            recorder.setAbsolute(.enumeratedCandidates, to: UInt64.max)
            recorder.increment(.enumeratedCandidates)
            recorder.recordReason(.absent)

            let active = recorder.snapshot()
            XCTAssertEqual(active.preparationID, preparationID)
            XCTAssertNil(active.terminalState)
            XCTAssertEqual(active.currentActivePhase, .prefixControlScan)
            XCTAssertEqual(active.phases.count, WorktreeStartupPreparationInstrumentation.Phase.allCases.count)
            XCTAssertEqual(active.phases[.scopeResolution]?.completedCount, 1)
            XCTAssertEqual(active.phases[.scopeResolution]?.completedDurationNanoseconds, 5000)
            XCTAssertEqual(active.phases[.prefixControlScan]?.activeCount, 1)
            XCTAssertEqual(active.counters.count, WorktreeStartupPreparationInstrumentation.Counter.allCases.count)
            XCTAssertEqual(active.counters[.authorityCaptures], 2)
            XCTAssertEqual(active.counters[.enumeratedCandidates], UInt64.max)
            XCTAssertTrue(active.saturatedCounters.contains(.enumeratedCandidates))
            XCTAssertEqual(active.reasons[.absent], 1)

            scan.end()
            scan.end()
            total.end()
            XCTAssertTrue(recorder.terminalize(.admitted))
            XCTAssertFalse(recorder.terminalize(.failed))
            let terminal = recorder.snapshot()
            XCTAssertEqual(terminal.terminalState, .admitted)
            XCTAssertNil(terminal.currentActivePhase)
            XCTAssertEqual(terminal.phases[.prefixControlScan]?.count, 1)
            XCTAssertEqual(terminal.phases[.prefixControlScan]?.completedCount, 1)
        }

        func testPreparationRegistryScopesBoundsAndEvictsOnlyCompletedRecords() throws {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics(maximumPreparationRecordCount: 2)
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 610,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let otherScope = DebugWorktreeStartupBenchmarkScope(
                windowID: 611,
                workspaceID: scope.workspaceID,
                contextID: scope.contextID,
                rootID: scope.rootID
            )
            let first = UUID()
            let second = UUID()
            _ = try diagnostics.beginPreparationForTesting(preparationID: first, scope: scope)
            _ = try diagnostics.beginPreparationForTesting(preparationID: second, scope: scope)
            XCTAssertThrowsError(
                try diagnostics.beginPreparationForTesting(preparationID: UUID(), scope: scope)
            ) { error in
                XCTAssertEqual(error as? DebugWorktreeStartupBenchmarkError, .preparationCapacityExceeded)
            }
            XCTAssertThrowsError(try diagnostics.preparationSnapshot(scope: otherScope, preparationID: first)) {
                XCTAssertEqual($0 as? DebugWorktreeStartupBenchmarkError, .invalidPreparation)
            }

            diagnostics.terminalizePreparationForTesting(preparationID: first, state: .failed)
            let third = UUID()
            _ = try diagnostics.beginPreparationForTesting(preparationID: third, scope: scope)
            XCTAssertThrowsError(try diagnostics.preparationSnapshot(scope: scope, preparationID: first))
            XCTAssertNil(try diagnostics.preparationSnapshot(scope: scope, preparationID: second).terminalState)
            XCTAssertNil(try diagnostics.preparationSnapshot(scope: scope, preparationID: third).terminalState)
        }

        func testCompletedPreparationRegistryRecordsExpire() throws {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics(completedPreparationTTLNanoseconds: 0)
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 612,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let preparationID = UUID()
            _ = try diagnostics.beginPreparationForTesting(preparationID: preparationID, scope: scope)
            diagnostics.terminalizePreparationForTesting(preparationID: preparationID, state: .admitted)
            XCTAssertThrowsError(try diagnostics.preparationSnapshot(scope: scope, preparationID: preparationID)) {
                XCTAssertEqual($0 as? DebugWorktreeStartupBenchmarkError, .invalidPreparation)
            }
        }

        func testClientDisconnectAfterControlCreationRevokesExactOwnedControl() async throws {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics(afterControlLeaseForTesting: {
                withUnsafeCurrentTask { task in task?.cancel() }
            })
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 613,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let preparationID = UUID()
            let task = Task {
                try await diagnostics.setFlagsPreparingBaseSnapshot(
                    scope: scope,
                    observe: true,
                    serve: true,
                    forceFullCrawl: true,
                    expiresSeconds: 120,
                    store: WorkspaceFileContextStore(),
                    expectedStandardizedRootPath: "/not-loaded",
                    preparationID: preparationID
                )
            }
            do {
                _ = try await task.value
                XCTFail("A disconnected set_flags caller must not receive an orphaned control.")
            } catch is CancellationError {
                // Expected.
            }
            let snapshot = try diagnostics.preparationSnapshot(scope: scope, preparationID: preparationID)
            XCTAssertEqual(snapshot.terminalState, .cancelled)
            XCTAssertEqual(snapshot.reasons[.cancellation], 1)
            let ownership = try XCTUnwrap(snapshot.routeControlOwnership)
            XCTAssertEqual(ownership.windowID, scope.windowID)
            XCTAssertEqual(ownership.workspaceID, scope.workspaceID)
            XCTAssertEqual(ownership.contextID, scope.contextID)
            XCTAssertEqual(ownership.rootID, scope.rootID)
            XCTAssertTrue(ownership.revoked)
            XCTAssertThrowsError(try diagnostics.restoreFlags(scope: scope, controlID: ownership.controlID)) {
                XCTAssertEqual($0 as? DebugWorktreeStartupBenchmarkError, .invalidControl)
            }
            XCTAssertEqual(try diagnostics.reset(scope: scope)["control_count"], 0)
        }

        func testRecoverableStartRegistryIsBoundedScopedAndAbortIsIdempotent() throws {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            defer { WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false) }
            let diagnostics = WorktreeStartupBenchmarkDiagnostics(
                maximumRecoverableStartRecordCount: 1
            )
            let scope = DebugWorktreeStartupBenchmarkScope(
                windowID: 614,
                workspaceID: UUID(),
                contextID: UUID(),
                rootID: UUID()
            )
            let expected = benchmarkExpectedStart(scope: scope)
            let control = try diagnostics.setFlags(
                scope: scope,
                observe: true,
                serve: true,
                forceFullCrawl: false,
                expiresSeconds: 120
            )
            let arm = try diagnostics.arm(
                expectedStart: expected,
                controlID: control.controlID,
                scenario: "clean_same_tree",
                invocation: 3,
                ordinal: 4,
                warmup: false,
                expiresSeconds: 120
            )
            let sessionID = UUID()
            let tabID = UUID()
            try diagnostics.registerRecoverableStartTarget(
                correlationID: arm.correlationID,
                agentSessionID: sessionID,
                targetTabID: tabID,
                targetOrigin: .createdNewTab
            )
            try diagnostics.recordRecoverableStartWorktree(
                correlationID: arm.correlationID,
                worktreeID: "worktree-1",
                repositoryID: "repository-1",
                repositoryKey: "repo-key",
                branch: "benchmark-branch",
                head: String(repeating: "a", count: 40),
                physicalPath: "/tmp/private-enterprise-path"
            )
            try diagnostics.recordRecoverableStartBinding(
                correlationID: arm.correlationID,
                bindingID: "binding-1",
                physicalRootPath: "/tmp/private-enterprise-path/Nested"
            )
            try diagnostics.recordRecoverableStartPhase(
                correlationID: arm.correlationID,
                phase: .ownershipCommitted
            )

            let snapshot = try diagnostics.recoverableStartSnapshot(
                scope: scope,
                correlationID: arm.correlationID,
                controlID: control.controlID
            )
            XCTAssertEqual(snapshot.agentSessionID, sessionID)
            XCTAssertEqual(snapshot.targetTabID, tabID)
            XCTAssertEqual(snapshot.phase, .ownershipCommitted)
            XCTAssertEqual(snapshot.worktreePathDigest?.count, 64)
            XCTAssertFalse(snapshot.worktreePathDigest?.contains("private") == true)
            XCTAssertEqual(snapshot.ownedPhysicalPathDigests.count, 1)
            XCTAssertFalse(snapshot.ownedPhysicalPathDigests[0].contains("private"))

            let firstAbort = try diagnostics.requestRecoverableStartAbort(
                scope: scope,
                correlationID: arm.correlationID,
                controlID: control.controlID
            )
            let secondAbort = try diagnostics.requestRecoverableStartAbort(
                scope: scope,
                correlationID: arm.correlationID,
                controlID: control.controlID
            )
            XCTAssertTrue(firstAbort.snapshot.abortRequested)
            XCTAssertEqual(firstAbort.snapshot, secondAbort.snapshot)
            XCTAssertFalse(firstAbort.requiresAgentCancel)
            XCTAssertThrowsError(
                try diagnostics.requireRecoverableStartNotAborted(correlationID: arm.correlationID)
            ) { error in
                XCTAssertEqual(error as? DebugWorktreeStartupBenchmarkError, .startAborted)
            }
            XCTAssertThrowsError(try diagnostics.arm(
                expectedStart: expected,
                controlID: control.controlID,
                scenario: "clean_same_tree",
                invocation: 3,
                ordinal: 5,
                warmup: false,
                expiresSeconds: 120
            )) { error in
                XCTAssertEqual(error as? DebugWorktreeStartupBenchmarkError, .recoveryCapacityExceeded)
            }
            XCTAssertEqual(try diagnostics.reset(scope: scope)["recovery_count"], 1)

            let postLaunchControl = try diagnostics.setFlags(
                scope: scope,
                observe: true,
                serve: true,
                forceFullCrawl: false,
                expiresSeconds: 120
            )
            let postLaunchArm = try diagnostics.arm(
                expectedStart: expected,
                controlID: postLaunchControl.controlID,
                scenario: "clean_same_tree",
                invocation: 3,
                ordinal: 6,
                warmup: false,
                expiresSeconds: 120
            )
            try diagnostics.beginRecoverableProviderDispatch(
                correlationID: postLaunchArm.correlationID
            )
            XCTAssertTrue(
                try diagnostics.recoverableStartSnapshot(
                    scope: scope,
                    correlationID: postLaunchArm.correlationID,
                    controlID: postLaunchControl.controlID
                ).providerDispatchStarted
            )
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false)
            XCTAssertNil(
                diagnostics.recoverableStartAbortRequested(
                    correlationID: postLaunchArm.correlationID
                ),
                "Gate revocation after provider dispatch must make bookkeeping unavailable, not fail the live start."
            )
            XCTAssertNil(try? diagnostics.recordRecoverableStartPhase(
                correlationID: postLaunchArm.correlationID,
                phase: .responsePrepared,
                providerRunActive: true
            ))
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
        }

        private func benchmarkExpectedStart(
            scope: DebugWorktreeStartupBenchmarkScope
        ) -> DebugWorktreeStartupBenchmarkExpectedStart {
            let root = "/benchmark/root-\(scope.rootID.uuidString)"
            let layout = GitRepositoryLayout(
                workTreeRoot: URL(fileURLWithPath: root),
                dotGitPath: URL(fileURLWithPath: root + "/.git"),
                gitDir: URL(fileURLWithPath: root + "/.git"),
                commonDir: URL(fileURLWithPath: root + "/.git"),
                isWorktree: false
            )
            let repository = GitWorktreeIdentity.repositoryIdentity(commonGitDir: layout.commonDir, mainWorktreeRoot: layout.workTreeRoot)
            return DebugWorktreeStartupBenchmarkExpectedStart(
                rootIdentity: DebugWorktreeStartupBenchmarkRootIdentity(
                    scope: scope,
                    standardizedLogicalRootPath: root,
                    repositoryID: repository.repositoryID,
                    repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout)
                ),
                requestedBranch: "bench",
                requestedBaseRef: "HEAD"
            )
        }

        private func benchmarkValidatedStart(
            expected: DebugWorktreeStartupBenchmarkExpectedStart
        ) -> DebugWorktreeStartupBenchmarkValidatedStart {
            let container = "/benchmark/.repoprompt-worktrees/root"
            return DebugWorktreeStartupBenchmarkValidatedStart(
                scope: expected.rootIdentity.scope,
                logicalRootID: expected.rootIdentity.scope.rootID,
                standardizedLogicalRootPath: expected.rootIdentity.standardizedLogicalRootPath,
                repositoryID: expected.rootIdentity.repositoryID,
                repositoryKey: expected.rootIdentity.repositoryKey,
                requestedBranch: expected.requestedBranch,
                requestedBaseRef: expected.requestedBaseRef,
                standardizedDestinationPath: container + "/agent-session",
                standardizedAppManagedContainerPath: container,
                destinationID: "wt-test",
                agentSessionID: UUID(),
                startAttemptID: UUID()
            )
        }

        private func benchmarkMetricTag(correlationID: UUID) -> WorktreeStartupInstrumentation.BenchmarkMetricTag {
            WorktreeStartupInstrumentation.BenchmarkMetricTag(
                correlationID: correlationID,
                contextID: UUID(),
                agentSessionID: UUID(),
                logicalRootID: UUID(),
                repositoryID: "repo",
                destinationID: "worktree"
            )
        }
    }
#endif
