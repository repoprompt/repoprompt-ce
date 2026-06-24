import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorktreeStartupInstrumentationTests: XCTestCase {
        func testObservationAndServingFlagsDefaultDisabledAndServingRequiresObservation() throws {
            let suiteName = "WorktreeStartupInstrumentationTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            XCTAssertEqual(WorktreeStartupFeatureFlags.current(defaults: defaults), .init())
            defaults.set(true, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            XCTAssertFalse(WorktreeStartupFeatureFlags.current(defaults: defaults).serveDiffSeededWorktreeStartup)
            defaults.set(true, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            XCTAssertEqual(
                WorktreeStartupFeatureFlags.current(defaults: defaults),
                .init(
                    observeDiffSeededWorktreeStartup: true,
                    serveDiffSeededWorktreeStartup: true
                )
            )

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
