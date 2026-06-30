import CoreServices
import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class WorkspacePendingSeededRootTests: XCTestCase {
        func testEligibleReceiptStaysHiddenUntilAtomicCommitThenServesProjectedSearchAndRead() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: prepared.binding.worktreeRootPath)
                    .appendingPathComponent("Empty/Deep/Leaf", isDirectory: true),
                withIntermediateDirectories: true
            )
            let store = WorkspaceFileContextStore()
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            WorktreeStartupInstrumentation.resetForTesting()

            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )

            let preparationInstrumentation = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(
                preparation.ownership.pendingSeededRootPreparations.count,
                1,
                "endEventID=\(prepared.hint.creationReceipt.witnessCoverage.endEventID) observations=\(preparation.ownership.materializationHintObservationsByPhysicalRootPath) instrumentation=\(preparationInstrumentation)"
            )
            XCTAssertTrue(preparation.ownership.roots.isEmpty)
            let rootsBeforeCommit = await store.roots()
            XCTAssertFalse(rootsBeforeCommit.contains { $0.standardizedFullPath == prepared.binding.worktreeRootPath })
            let availabilityBeforeCommit = await store.rootScopeAvailability(fixture.scope(for: prepared.binding))
            XCTAssertEqual(
                availabilityBeforeCommit,
                .sessionWorktreeUnavailable(missingPhysicalRootPaths: [prepared.binding.worktreeRootPath])
            )

            let projectionValue = try await materializer.commit(preparation)
            let projection = try XCTUnwrap(projectionValue)
            let physicalRoot = try XCTUnwrap(projection.physicalRootRefs.first)
            XCTAssertEqual(physicalRoot.standardizedFullPath, prepared.binding.worktreeRootPath)

            let snapshot = await store.searchCatalogSnapshot(rootScope: fixture.scope(for: prepared.binding))
            XCTAssertEqual(snapshot.roots.map(\.id), [physicalRoot.id])
            XCTAssertEqual(
                Set(snapshot.files.map(\.standardizedRelativePath)),
                fixture.expectedTargetFiles
            )
            let pathIndex = try XCTUnwrap(snapshot.rootPathIndexes.first)
            guard case .projectedReuse = pathIndex.buildKind else {
                return XCTFail("Expected the atomically published shard to retain projected reuse")
            }
            XCTAssertFalse(pathIndex.search("Tracked", limit: 20).isEmpty)
            let empty = await store.folder(rootID: physicalRoot.id, relativePath: "Empty")
            let emptyDeep = await store.folder(rootID: physicalRoot.id, relativePath: "Empty/Deep")
            let emptyLeaf = await store.folder(rootID: physicalRoot.id, relativePath: "Empty/Deep/Leaf")
            XCTAssertNotNil(empty)
            XCTAssertNotNil(emptyDeep)
            XCTAssertNotNil(emptyLeaf)

            let postCommitURL = URL(fileURLWithPath: prepared.binding.worktreeRootPath)
                .appendingPathComponent("PostCommit.swift")
            try "let postCommit = true\n".write(to: postCommitURL, atomically: true, encoding: .utf8)
            let createdFileFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
            )
            _ = try await store.acceptWatcherPayloadForTesting(
                rootID: physicalRoot.id,
                events: [(postCommitURL.path, createdFileFlags, 99001)]
            )
            _ = await store.awaitAppliedIngress(rootRefs: [physicalRoot])
            let postCommitRecord = await store.file(
                rootID: physicalRoot.id,
                relativePath: "PostCommit.swift"
            )
            XCTAssertNotNil(postCommitRecord)
            let patchedSnapshot = await store.searchCatalogSnapshot(rootScope: fixture.scope(for: prepared.binding))
            let patchedIndex = try XCTUnwrap(patchedSnapshot.rootPathIndexes.first)
            XCTAssertFalse(patchedIndex.search("PostCommit", limit: 20).isEmpty)

            let tracked = try XCTUnwrap(snapshot.files.first { $0.standardizedRelativePath == "Tracked.swift" })
            let read = try await store.interactiveReadSnapshot(for: tracked)
            XCTAssertEqual(read?.preparedContent.linesWithEndings.joined(), "let value = 1\n")

            let diagnostics = await store.readSearchRootDiagnosticsSnapshot()
            let target = try XCTUnwrap(diagnostics.first { $0.rootID == physicalRoot.id })
            XCTAssertEqual(target.crawlCount, 0)
            XCTAssertTrue(target.watcherActive)
            XCTAssertEqual(target.sessionWorktreeOwnerCount, 1)
            let instrumentation = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(instrumentation.routeCounts[.diffSeedServing], 4)
            XCTAssertTrue(instrumentation.events.contains { $0.phase == .seedPublished })
            XCTAssertEqual(instrumentation.seed.fullCrawlFallbackCount, 0)

            await materializer.release(sessionID: fixture.agentSessionID)
        }

        func testProjectionAbortRecordsOneTerminalReceiptDecision() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let store = WorkspaceFileContextStore()
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            WorktreeStartupInstrumentation.resetForTesting()

            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            XCTAssertEqual(preparation.ownership.pendingSeededRootPreparations.count, 1)

            await materializer.abort(preparation)
            await materializer.abort(preparation)

            let records = WorktreeStartupInstrumentation.receiptDecisions(
                correlationID: fixture.correlationID
            )
            XCTAssertEqual(records.count, 1)
            let aggregate = try XCTUnwrap(records.first)
            XCTAssertEqual(aggregate.creationAttemptCount, 0)
            XCTAssertEqual(aggregate.terminalStage, .consumption)
            XCTAssertFalse(aggregate.ambiguousOrDuplicate)
            XCTAssertNotNil(aggregate.projection)
            XCTAssertNotNil(aggregate.consumption)
        }

        func testPendingMetadataInvalidationAfterValidationFailsClosedBeforePublication() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let store = WorkspaceFileContextStore()
            let authority = GitWorkspaceStateAuthority.shared
            let key = GitWorkspaceAuthorityRepositoryKey(layout: prepared.hint.creationReceipt.targetLayout)
            await store.setPendingSeededRootDidActivateHandler { _ in
                await authority.metadataDidChange(repositoryKey: key, kinds: [.index])
            }
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            WorktreeStartupInstrumentation.resetForTesting()

            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            XCTAssertEqual(preparation.ownership.pendingSeededRootPreparations.count, 1)
            let projectionValue = try await materializer.commit(preparation)
            let projection = try XCTUnwrap(projectionValue)
            let root = try XCTUnwrap(projection.physicalRootRefs.first)
            let diagnostics = await store.readSearchRootDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.first { $0.rootID == root.id }?.crawlCount, 1)
            let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(ownership.pendingSeededRootCount, 0)
            XCTAssertEqual(WorktreeStartupInstrumentation.snapshot().seed.fullCrawlFallbackCount, 1)
            await materializer.release(sessionID: fixture.agentSessionID)
        }

        func testTwoRootSeededPublicationPermitPublishesBothAtomicallyWithoutDeadlock() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let first = try await fixture.prepareWorktree()
            let second = try await fixture.prepareWorktree()
            let store = WorkspaceFileContextStore()
            let activationGate = PendingSeededActivationGate()
            await store.setPendingSeededRootDidActivateHandler { path in
                guard path == first.binding.worktreeRootPath else { return }
                await activationGate.markStartedAndWaitForRelease()
            }
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [first.binding, second.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [
                    first.binding.id: first.hint,
                    second.binding.id: second.hint
                ]
            )
            XCTAssertEqual(preparation.ownership.pendingSeededRootPreparations.count, 2)
            let commit = Task { try await materializer.commit(preparation) }
            await activationGate.waitUntilStarted()
            let rootsDuringPrivateActivation = await store.roots()
            XCTAssertFalse(rootsDuringPrivateActivation.contains {
                $0.standardizedFullPath == first.binding.worktreeRootPath
                    || $0.standardizedFullPath == second.binding.worktreeRootPath
            })

            await activationGate.release()
            let projectionValue = try await commit.value
            _ = try XCTUnwrap(projectionValue)
            let expectedPaths = Set([first.binding.worktreeRootPath, second.binding.worktreeRootPath])
            let allPublishedRoots = await store.roots()
            let publishedRoots = allPublishedRoots.filter {
                expectedPaths.contains($0.standardizedFullPath)
            }
            XCTAssertEqual(
                Set(publishedRoots.map(\.standardizedFullPath)),
                expectedPaths
            )
            XCTAssertEqual(publishedRoots.count, 2)
            for root in publishedRoots {
                let isCurrent = await store.publishedSeededAuthorityIsCurrentForTesting(rootID: root.id)
                XCTAssertTrue(isCurrent)
            }
            let catalog = await store.searchCatalogSnapshot(
                rootScope: fixture.scope(for: [first.binding, second.binding])
            )
            XCTAssertEqual(Set(catalog.roots.map(\.id)), Set(publishedRoots.map(\.id)))
            let diagnostics = await store.readSearchRootDiagnosticsSnapshot()
            XCTAssertTrue(publishedRoots.allSatisfy { root in
                diagnostics.contains { $0.rootID == root.id && $0.crawlCount == 0 && $0.watcherActive }
            })
            await materializer.release(sessionID: fixture.agentSessionID)
        }

        func testTwoConsumersPublishFromOneAuthorityFlightWithoutStalingEachOther() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let firstStore = WorkspaceFileContextStore()
            let secondStore = WorkspaceFileContextStore()
            let firstMaterializer = WorkspaceRootBindingProjectionMaterializer(store: firstStore)
            let secondMaterializer = WorkspaceRootBindingProjectionMaterializer(store: secondStore)

            let firstPreparation = try await firstMaterializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            let secondPreparation = try await secondMaterializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            XCTAssertEqual(firstPreparation.ownership.pendingSeededRootPreparations.count, 1)
            XCTAssertEqual(
                secondPreparation.ownership.pendingSeededRootPreparations.count,
                1,
                "observations=\(secondPreparation.ownership.materializationHintObservationsByPhysicalRootPath)"
            )

            let firstProjectionValue = try await firstMaterializer.commit(firstPreparation)
            let secondProjectionValue = try await secondMaterializer.commit(secondPreparation)
            let firstProjection = try XCTUnwrap(firstProjectionValue)
            let secondProjection = try XCTUnwrap(secondProjectionValue)
            let firstRoot = try XCTUnwrap(firstProjection.physicalRootRefs.first)
            let secondRoot = try XCTUnwrap(secondProjection.physicalRootRefs.first)
            let firstIsCurrent = await firstStore.publishedSeededAuthorityIsCurrentForTesting(rootID: firstRoot.id)
            let secondIsCurrent = await secondStore.publishedSeededAuthorityIsCurrentForTesting(rootID: secondRoot.id)
            XCTAssertTrue(firstIsCurrent)
            XCTAssertTrue(secondIsCurrent)
            let firstDiagnostics = await firstStore.readSearchRootDiagnosticsSnapshot()
            let secondDiagnostics = await secondStore.readSearchRootDiagnosticsSnapshot()
            XCTAssertEqual(
                firstDiagnostics.first { $0.rootID == firstRoot.id }?.crawlCount,
                0
            )
            XCTAssertEqual(
                secondDiagnostics.first { $0.rootID == secondRoot.id }?.crawlCount,
                0
            )

            await firstMaterializer.release(sessionID: fixture.agentSessionID)
            await secondMaterializer.release(sessionID: fixture.agentSessionID)
        }

        func testLaggingConsumerRevalidatesAdvancedInvalidFenceBeforePublication() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let firstStore = WorkspaceFileContextStore()
            let secondStore = WorkspaceFileContextStore()
            let firstMaterializer = WorkspaceRootBindingProjectionMaterializer(store: firstStore)
            let secondMaterializer = WorkspaceRootBindingProjectionMaterializer(store: secondStore)
            let firstPreparation = try await firstMaterializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            let secondPreparation = try await secondMaterializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            let authority = GitWorkspaceStateAuthority.shared
            let monitor = await authority.metadataMonitorForTesting()
            let key = GitWorkspaceAuthorityRepositoryKey(layout: prepared.hint.creationReceipt.targetLayout)

            await monitor.acceptEventWithoutDeliveryForTesting(repositoryKey: key)
            let firstProjectionValue = try await firstMaterializer.commit(firstPreparation)
            let firstProjection = try XCTUnwrap(firstProjectionValue)
            let firstRoot = try XCTUnwrap(firstProjection.physicalRootRefs.first)
            let firstIsCurrent = await firstStore.publishedSeededAuthorityIsCurrentForTesting(rootID: firstRoot.id)
            XCTAssertTrue(firstIsCurrent, "The first consumer must publish the recaptured F1 fence")

            await monitor.acceptEventWithoutDeliveryForTesting(repositoryKey: key)
            let invalidatedF1IsCurrent = await firstStore
                .publishedSeededAuthorityIsCurrentForTesting(rootID: firstRoot.id)
            XCTAssertFalse(invalidatedF1IsCurrent, "The second accepted cut must invalidate F1")
            await firstMaterializer.release(sessionID: fixture.agentSessionID)

            let secondProjectionValue = try await secondMaterializer.commit(secondPreparation)
            let secondProjection = try XCTUnwrap(secondProjectionValue)
            let secondRoot = try XCTUnwrap(secondProjection.physicalRootRefs.first)
            let secondIsCurrent = await secondStore
                .publishedSeededAuthorityIsCurrentForTesting(rootID: secondRoot.id)
            XCTAssertTrue(secondIsCurrent)
            let diagnostics = await secondStore.readSearchRootDiagnosticsSnapshot()
            XCTAssertEqual(
                diagnostics.first { $0.rootID == secondRoot.id }?.crawlCount,
                0,
                "The available recapture must be validated instead of returning stale F1 and full-crawling"
            )
            let read = try await secondStore.readContent(
                rootID: secondRoot.id,
                relativePath: "Tracked.swift"
            )
            XCTAssertEqual(read, "let value = 1\n")
            let catalog = await secondStore.searchCatalogSnapshot(
                rootScope: fixture.scope(for: prepared.binding)
            )
            XCTAssertEqual(catalog.roots.map(\.id), [secondRoot.id])

            await secondMaterializer.release(sessionID: fixture.agentSessionID)
        }

        func testReleasingOneCoalescedConsumerKeepsSiblingPublicationCurrent() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let firstStore = WorkspaceFileContextStore()
            let secondStore = WorkspaceFileContextStore()
            let firstMaterializer = WorkspaceRootBindingProjectionMaterializer(store: firstStore)
            let secondMaterializer = WorkspaceRootBindingProjectionMaterializer(store: secondStore)

            let firstPreparation = try await firstMaterializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            let secondPreparation = try await secondMaterializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            let firstProjectionValue = try await firstMaterializer.commit(firstPreparation)
            let secondProjectionValue = try await secondMaterializer.commit(secondPreparation)
            let firstProjection = try XCTUnwrap(firstProjectionValue)
            let secondProjection = try XCTUnwrap(secondProjectionValue)
            let firstRoot = try XCTUnwrap(firstProjection.physicalRootRefs.first)
            let secondRoot = try XCTUnwrap(secondProjection.physicalRootRefs.first)

            await firstMaterializer.release(sessionID: fixture.agentSessionID)
            let firstRootsAfterRelease = await firstStore.roots()
            let siblingIsCurrent = await secondStore.publishedSeededAuthorityIsCurrentForTesting(rootID: secondRoot.id)
            XCTAssertFalse(firstRootsAfterRelease.contains { $0.id == firstRoot.id })
            XCTAssertTrue(siblingIsCurrent)
            let siblingRead = try await secondStore.readContent(
                rootID: secondRoot.id,
                relativePath: "Tracked.swift"
            )
            XCTAssertEqual(siblingRead, "let value = 1\n")
            let siblingCatalog = await secondStore.searchCatalogSnapshot(
                rootScope: fixture.scope(for: prepared.binding)
            )
            XCTAssertEqual(siblingCatalog.roots.map(\.id), [secondRoot.id])

            await secondMaterializer.release(sessionID: fixture.agentSessionID)
        }

        func testPublishedAuthorityBlocksCatalogAndReadUntilFinalMutationCompletion() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let store = WorkspaceFileContextStore()
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            let projectionValue = try await materializer.commit(preparation)
            let projection = try XCTUnwrap(projectionValue)
            let root = try XCTUnwrap(projection.physicalRootRefs.first)
            let authority = GitWorkspaceStateAuthority.shared
            let key = GitWorkspaceAuthorityRepositoryKey(layout: prepared.hint.creationReceipt.targetLayout)
            let first = await authority.beginMutation(repositoryKey: key, kind: .branchSwitch)
            let second = await authority.beginMutation(repositoryKey: key, kind: .branchSwitch)
            await store.waitForPublishedSeededAuthorityMutationDepthForTesting(rootID: root.id, atLeast: 2)

            let read = Task { try await store.readContent(rootID: root.id, relativePath: "Tracked.swift") }
            await store.waitForPublishedSeededAuthorityWaiterForTesting(rootID: root.id)
            guard case .unavailable = await store.searchCatalogAccess(rootScope: fixture.scope(for: prepared.binding)) else {
                return XCTFail("Catalog must fail closed while Git authority is mutation-active")
            }

            await authority.finishMutation(first, outcome: .succeeded)
            await Task.yield()
            let intermediateValue = await store.publishedSeededAuthoritySnapshotForTesting(rootID: root.id)
            let intermediate = try XCTUnwrap(intermediateValue)
            XCTAssertTrue(intermediate.isBlocked)
            XCTAssertGreaterThanOrEqual(intermediate.activeMutationDepth, 1)
            XCTAssertEqual(intermediate.fullCrawlCount, 0)

            await authority.finishMutation(second, outcome: .succeeded)
            await store.waitForPublishedSeededAuthorityReconciliationForTesting(rootID: root.id)
            let readValue = try await read.value
            XCTAssertEqual(readValue, "let value = 1\n")
            let currentValue = await store.publishedSeededAuthoritySnapshotForTesting(rootID: root.id)
            let current = try XCTUnwrap(currentValue)
            XCTAssertFalse(current.isBlocked)
            XCTAssertEqual(current.activeMutationDepth, 0)
            XCTAssertEqual(current.fullCrawlCount, 0)
            await materializer.release(sessionID: fixture.agentSessionID)
        }

        func testCheckoutCompletionWithChangedAuthorityFullCrawlsOnceBeforeUnblockingRead() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let store = WorkspaceFileContextStore()
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            let projectionValue = try await materializer.commit(preparation)
            let projection = try XCTUnwrap(projectionValue)
            let root = try XCTUnwrap(projection.physicalRootRefs.first)
            let authority = GitWorkspaceStateAuthority.shared
            let key = GitWorkspaceAuthorityRepositoryKey(layout: prepared.hint.creationReceipt.targetLayout)
            let mutation = await authority.beginMutation(repositoryKey: key, kind: .branchSwitch)
            await store.waitForPublishedSeededAuthorityMutationDepthForTesting(rootID: root.id, atLeast: 1)
            try "let value = 2\n".write(
                to: URL(fileURLWithPath: prepared.binding.worktreeRootPath).appendingPathComponent("Tracked.swift"),
                atomically: true,
                encoding: .utf8
            )
            let worktreeURL = URL(fileURLWithPath: prepared.binding.worktreeRootPath, isDirectory: true)
            try fixture.git(["add", "Tracked.swift"], at: worktreeURL)
            try fixture.git(["commit", "-m", "checkout target"], at: worktreeURL)
            let read = Task { try await store.readContent(rootID: root.id, relativePath: "Tracked.swift") }
            await store.waitForPublishedSeededAuthorityWaiterForTesting(rootID: root.id)

            await authority.finishMutation(mutation, outcome: .succeeded)
            await store.waitForPublishedSeededAuthorityReconciliationForTesting(rootID: root.id)
            let readValue = try await read.value
            XCTAssertEqual(readValue, "let value = 2\n")
            let currentValue = await store.publishedSeededAuthoritySnapshotForTesting(rootID: root.id)
            let current = try XCTUnwrap(currentValue)
            XCTAssertFalse(current.isBlocked)
            XCTAssertEqual(current.fullCrawlCount, 1)
            await materializer.release(sessionID: fixture.agentSessionID)
        }

        func testWatcherActivationFailureRollsBackPrivateStateAndFullCrawlsOnce() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let store = WorkspaceFileContextStore()
            await store.setSeededPublicationActivationFailureForTesting(true)
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            WorktreeStartupInstrumentation.resetForTesting()
            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            XCTAssertEqual(preparation.ownership.pendingSeededRootPreparations.count, 1)
            let projectionValue = try await materializer.commit(preparation)
            let projection = try XCTUnwrap(projectionValue)
            let root = try XCTUnwrap(projection.physicalRootRefs.first)
            let diagnostics = await store.readSearchRootDiagnosticsSnapshot()
            let target = try XCTUnwrap(diagnostics.first { $0.rootID == root.id })
            XCTAssertEqual(target.crawlCount, 1)
            XCTAssertTrue(target.watcherActive)
            XCTAssertEqual(WorktreeStartupInstrumentation.snapshot().seed.fullCrawlFallbackCount, 1)
            await materializer.release(sessionID: fixture.agentSessionID)
        }

        func testOwnerSupersessionAfterPrivateWatcherActivationExposesNoSeededRoot() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let store = WorkspaceFileContextStore()
            await store.setPendingSeededRootDidActivateHandler { _ in
                _ = try? await store.prepareSessionWorktreeOwnership(
                    ownerID: fixture.agentSessionID,
                    bindingFingerprint: "superseding-owner",
                    physicalRootPaths: []
                )
            }
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            WorktreeStartupInstrumentation.resetForTesting()
            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            do {
                _ = try await materializer.commit(preparation)
                XCTFail("Superseded private activation must not commit")
            } catch WorkspaceSessionWorktreeOwnershipError.staleUpdate {
                // Expected.
            }
            let roots = await store.roots()
            XCTAssertFalse(roots.contains {
                $0.standardizedFullPath == prepared.binding.worktreeRootPath
            })
            let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(ownership.pendingSeededRootCount, 0)
            XCTAssertEqual(ownership.pathReservationCount, 0)
            let records = WorktreeStartupInstrumentation.receiptDecisions(
                correlationID: fixture.correlationID
            )
            XCTAssertEqual(records.count, 1)
            let aggregate = try XCTUnwrap(records.first)
            XCTAssertEqual(aggregate.creationAttemptCount, 0)
            XCTAssertEqual(aggregate.terminalStage, .consumption)
            XCTAssertFalse(aggregate.ambiguousOrDuplicate)
            XCTAssertNotNil(aggregate.projection)
            XCTAssertNotNil(aggregate.consumption)
        }

        func testShardFailureRollsBackPrivateStateAndFallsBackToOneFullCrawl() async throws {
            let fixture = try PendingSeededRootFixture()
            defer { fixture.cleanup() }
            let prepared = try await fixture.prepareWorktree()
            let store = WorkspaceFileContextStore()
            await store.setSeededShardPreparationFailureForTesting(true)
            defer { Task { await store.setSeededShardPreparationFailureForTesting(false) } }
            let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
            WorktreeStartupInstrumentation.resetForTesting()

            let preparation = try await materializer.prepare(
                sessionID: fixture.agentSessionID,
                bindings: [prepared.binding],
                startupContext: fixture.startupContext(serving: true),
                initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
            )
            XCTAssertTrue(preparation.ownership.pendingSeededRootPreparations.isEmpty)
            XCTAssertEqual(
                preparation.ownership.materializationHintObservationsByPhysicalRootPath[
                    prepared.binding.worktreeRootPath
                ],
                .fallback(.seededShardPreparationFailure)
            )
            let target = try XCTUnwrap(preparation.ownership.roots.first)
            let diagnostics = await store.readSearchRootDiagnosticsSnapshot()
            XCTAssertEqual(diagnostics.first { $0.rootID == target.rootID }?.crawlCount, 1)
            let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(ownership.pendingSeededRootCount, 0)
            XCTAssertEqual(ownership.pathReservationCount, 0)
            XCTAssertEqual(ownership.rootClaimCount, 1)
            let instrumentation = WorktreeStartupInstrumentation.snapshot()
            XCTAssertEqual(instrumentation.seed.fullCrawlFallbackCount, 1)
            XCTAssertEqual(instrumentation.fallbackCounts[.seededShardPreparationFailure], 1)

            _ = try await materializer.commit(preparation)
            await materializer.release(sessionID: fixture.agentSessionID)
        }
    }

    final class AgentRunDiffSeededWorktreeInitializationTests: XCTestCase {
        func testDefaultOffAndForcedFullCrawlUseOrdinaryRouteExactlyOnce() async throws {
            for mode in [PendingSeededRootFixture.Mode.defaultOff, .forcedFullCrawl] {
                let fixture = try PendingSeededRootFixture()
                defer { fixture.cleanup() }
                let prepared = try await fixture.prepareWorktree()
                let store = WorkspaceFileContextStore()
                let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
                let context: WorktreeStartupContext = switch mode {
                case .defaultOff:
                    fixture.startupContext(serving: false)
                case .forcedFullCrawl:
                    fixture.startupContext(serving: true, control: .forceFullCrawl)
                }

                let preparation = try await materializer.prepare(
                    sessionID: fixture.agentSessionID,
                    bindings: [prepared.binding],
                    startupContext: context,
                    initializationHintsByBindingID: [prepared.binding.id: prepared.hint]
                )
                XCTAssertTrue(preparation.ownership.pendingSeededRootPreparations.isEmpty)
                let rootsBeforeCommit = await store.roots()
                let targetBeforeCommit = try XCTUnwrap(rootsBeforeCommit.first {
                    $0.standardizedFullPath == prepared.binding.worktreeRootPath
                })
                let diagnostics = await store.readSearchRootDiagnosticsSnapshot()
                XCTAssertEqual(diagnostics.first { $0.rootID == targetBeforeCommit.id }?.crawlCount, 1)

                let projectionValue = try await materializer.commit(preparation)
                let projection = try XCTUnwrap(projectionValue)
                let target = try XCTUnwrap(projection.physicalRootRefs.first)
                let trackedRecord = await store.file(rootID: target.id, relativePath: "Tracked.swift")
                let tracked = try XCTUnwrap(trackedRecord)
                let read = try await store.interactiveReadSnapshot(for: tracked)
                XCTAssertEqual(read?.preparedContent.linesWithEndings.joined(), "let value = 1\n")
                await materializer.release(sessionID: fixture.agentSessionID)
            }
        }
    }

    private struct PendingSeededRootFixture {
        enum Mode {
            case defaultOff
            case forcedFullCrawl
        }

        struct PreparedWorktree {
            let binding: AgentSessionWorktreeBinding
            let hint: WorkspaceRootMaterializationHint
        }

        let sandbox: URL
        let root: URL
        let worktrees: URL
        let correlationID = UUID()
        let agentSessionID = UUID()
        let expectedOwnerBindingGeneration: UInt64 = 1

        let expectedTargetFiles: Set<String> = [
            ".gitignore", ".worktreeinclude", "Tracked.swift"
        ]

        init() throws {
            sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspacePendingSeededRootTests-\(UUID().uuidString)", isDirectory: true)
            root = sandbox.appendingPathComponent("repo", isDirectory: true)
            worktrees = sandbox.appendingPathComponent("worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
            try git(["init"])
            try git(["config", "user.name", "RepoPrompt Test"])
            try git(["config", "user.email", "repoprompt@example.test"])
            try git(["config", "commit.gpgSign", "false"])
            try write("Tracked.swift", "let value = 1\n")
            try write(".gitignore", "secret.txt\n")
            try write(".worktreeinclude", "secret.txt\n")
            try write("secret.txt", "ephemeral secret\n")
            try git(["add", "Tracked.swift", ".gitignore", ".worktreeinclude"])
            try git(["commit", "-m", "base"])
        }

        func prepareWorktree() async throws -> PreparedWorktree {
            let authority = GitWorkspaceStateAuthority.shared
            let git = GitService(workspaceStateAuthority: authority)
            let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
            guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
                rootURL: root,
                authoritativeRelativeFilePaths: [".gitignore", ".worktreeinclude", "Tracked.swift"]
            ) else {
                throw XCTSkip("Reusable snapshot admission unavailable")
            }
            let request = GitWorktreeCreateRequest(
                path: worktrees.appendingPathComponent("child-\(UUID().uuidString)", isDirectory: true),
                branch: "pending-\(UUID().uuidString)",
                baseRef: "HEAD",
                appManagedContainer: worktrees,
                mainWorktreeRoot: root,
                knownWorktreeRoots: [root],
                copyWorktreeIncludeFiles: true
            )
            let result = try await git.createWorktreeWithResult(
                request: request,
                at: root,
                initializationContext: GitWorktreeInitializationContext(
                    agentSessionID: agentSessionID,
                    correlationID: correlationID,
                    logicalRootPath: root.path,
                    expectedOwnerBindingGeneration: expectedOwnerBindingGeneration,
                    repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""),
                    observeReceipt: true
                )
            )
            let receipt = try XCTUnwrap(result.initializationReceipt)
            let descriptor = result.descriptor
            let binding = AgentSessionWorktreeBinding(
                id: "pending-binding-\(UUID().uuidString)",
                repositoryID: descriptor.repository.repositoryID,
                repoKey: descriptor.repository.repoKey,
                logicalRootPath: root.path,
                logicalRootName: root.lastPathComponent,
                worktreeID: descriptor.worktreeID,
                worktreeRootPath: descriptor.path,
                worktreeName: descriptor.name,
                branch: descriptor.branch,
                head: descriptor.head,
                source: "test"
            )
            let context = startupContext(serving: true)
            let hint = WorkspaceRootMaterializationHint(
                bindingID: binding.id,
                standardizedTargetPath: binding.worktreeRootPath,
                creationReceipt: receipt,
                correlationID: correlationID
            ).validated(
                matching: binding,
                sessionID: agentSessionID,
                startupContext: context
            )
            return PreparedWorktree(binding: binding, hint: hint)
        }

        func startupContext(
            serving: Bool,
            control: WorktreeStartupServingControl = .automatic
        ) -> WorktreeStartupContext {
            WorktreeStartupContext(
                agentSessionID: agentSessionID,
                correlationID: correlationID,
                flags: WorktreeStartupFeatureFlags(
                    observeDiffSeededWorktreeStartup: serving,
                    serveDiffSeededWorktreeStartup: serving
                ),
                servingControl: control
            )
        }

        func scope(for binding: AgentSessionWorktreeBinding) -> WorkspaceLookupRootScope {
            .sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [binding.worktreeRootPath]
            )
        }

        func scope(for bindings: [AgentSessionWorktreeBinding]) -> WorkspaceLookupRootScope {
            .sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: Set(bindings.map(\.worktreeRootPath))
            )
        }

        func write(_ relativePath: String, _ contents: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func git(_ arguments: [String], at workingDirectory: URL? = nil) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory ?? root
            process.environment = ProcessInfo.processInfo.environment.merging([
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_TERMINAL_PROMPT": "0"
            ]) { _, new in new }
            let stderr = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                throw NSError(
                    domain: "WorkspacePendingSeededRootTests.git",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: detail]
                )
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: sandbox)
        }
    }

    private actor PendingSeededActivationGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
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

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif
