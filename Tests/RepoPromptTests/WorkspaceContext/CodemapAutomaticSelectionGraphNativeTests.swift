import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapAutomaticSelectionGraphNativeTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testAutomaticSelectionUsesCommittedGraphAndTargetOnlyBackgroundDemand() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let unrelated = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Unrelated.swift" })

        let sourceSeed = await store.requestCodemapArtifact(
            forFileID: source.id,
            priority: .background
        )
        let sourceReady: WorkspaceCodemapArtifactDemandResult = switch sourceSeed {
        case let .pending(ticket):
            try await settledResult(store: store, ticket: ticket)
        default:
            sourceSeed
        }
        guard case .ready = sourceReady else {
            return XCTFail("Expected the source artifact to be ready before graph-native selection.")
        }
        let automaticDemandTicketOffset = fixture.demandedTickets.values.count

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var resolved: WorkspaceCodemapAutomaticSelectionResult?
        while clock.now < deadline {
            let identities = await store.codemapAutomaticSelectionSourceIdentities(
                forFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
            if let identity = identities.first {
                let result = try await store.resolveAutomaticCodemapSelection(
                    sources: [identity],
                    rootScope: .visibleWorkspace
                )
                if result.targets.contains(where: { $0.fileID == target.id }), result.receipt != nil {
                    resolved = result
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let result = try XCTUnwrap(resolved)
        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        XCTAssertFalse(result.targets.contains { $0.fileID == source.id || $0.fileID == unrelated.id })
        let buildCountBeforeRepeatQuery = fixture.buildCount.value
        let builtSourceCountBeforeRepeatQuery = fixture.builtSourceTexts.values.count
        let repeatIdentities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let repeatIdentity = try XCTUnwrap(repeatIdentities.first)
        let repeated = try await store.resolveAutomaticCodemapSelection(
            sources: [repeatIdentity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(repeated.targets.map(\.fileID), [target.id])
        XCTAssertEqual(fixture.buildCount.value, buildCountBeforeRepeatQuery)
        XCTAssertEqual(fixture.builtSourceTexts.values.count, builtSourceCountBeforeRepeatQuery)
        let receipt = try XCTUnwrap(result.receipt)
        let rootReceipt = try XCTUnwrap(receipt.roots.first)
        let revalidation = await store.revalidateAutomaticCodemapSelection(
            receipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(revalidation.validTargets.map(\.fileID), [target.id])
        XCTAssertTrue(revalidation.issues.isEmpty)

        XCTAssertEqual(
            Array(fixture.demandedTickets.values.dropFirst(automaticDemandTicketOffset)).map(\.fileID),
            [],
            "Exact-root reference discovery must not request a source or target artifact."
        )
        let targetDemandSourceOffset = fixture.builtSourceTexts.values.count
        let ownedCandidate = await store.requestAutomaticCodemapTargetWithOwnership(
            target: result.targets[0],
            rootReceipt: rootReceipt,
            rootScope: .visibleWorkspace
        )
        let owned = try XCTUnwrap(ownedCandidate)
        let ready: WorkspaceCodemapArtifactDemandResult = switch owned.result {
        case let .pending(ticket):
            try await settledResult(store: store, ticket: ticket)
        default:
            owned.result
        }
        guard case .ready = ready else {
            return XCTFail("Expected the receipt-validated target demand to become ready.")
        }
        let automaticDemandTickets = Array(
            fixture.demandedTickets.values.dropFirst(automaticDemandTicketOffset)
        )
        XCTAssertEqual(automaticDemandTickets.map(\.fileID), [target.id])
        XCTAssertEqual(Set(automaticDemandTickets.map(\.requestID)).count, 1)
        XCTAssertFalse(automaticDemandTickets.contains { $0.fileID == source.id || $0.fileID == unrelated.id })
        let targetDemandSources = Array(fixture.builtSourceTexts.values.dropFirst(targetDemandSourceOffset))
        XCTAssertLessThanOrEqual(targetDemandSources.count, 1)
        XCTAssertTrue(targetDemandSources.allSatisfy { $0 == "struct Target {}\n" })
        XCTAssertFalse(targetDemandSources.contains("protocol SourceProtocol { var target: Target { get } }\n"))
        XCTAssertFalse(targetDemandSources.contains("struct Unrelated {}\n"))
        XCTAssertTrue(
            fixture.buildPriorities.values.allSatisfy { $0 == .background },
            "Automatic reference discovery and target rendering must never create source-demand priority work."
        )
    }

    func testRealTwoRootQueriesRemainIsolatedThenMergeDeterministically() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: "\(#function)-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: "\(#function)-second")
        let firstRootURL = try firstRepository.makeRepository(
            named: "repository-a",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let secondRootURL = try secondRepository.makeRepository(
            named: "repository-b",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let store = fixture.makeStore()
        let firstRoot = try await store.loadRoot(path: firstRootURL.path)
        let secondRoot = try await store.loadRoot(path: secondRootURL.path)
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let secondFiles = await store.files(inRoot: secondRoot.id)
        let firstSource = try XCTUnwrap(firstFiles.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let firstTarget = try XCTUnwrap(firstFiles.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let secondSource = try XCTUnwrap(secondFiles.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let secondTarget = try XCTUnwrap(secondFiles.first { $0.standardizedRelativePath == "Sources/Target.swift" })

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var isolated: WorkspaceCodemapAutomaticSelectionResult?
        var merged: WorkspaceCodemapAutomaticSelectionResult?
        while clock.now < deadline {
            let identities = await store.codemapAutomaticSelectionSourceIdentities(
                forFileIDs: [firstSource.id, secondSource.id],
                rootScope: .visibleWorkspace
            )
            if identities.count == 2 {
                let orderedIdentities = identities.sorted {
                    workspaceCodemapRootEpochPrecedes($0.rootEpoch, $1.rootEpoch)
                }
                let expectedOrderedRootIDs = orderedIdentities.map(\.rootEpoch.rootID)
                let targetByRoot = [firstRoot.id: firstTarget.id, secondRoot.id: secondTarget.id]
                let expectedOrderedTargetIDs = expectedOrderedRootIDs.compactMap { targetByRoot[$0] }
                let firstIdentity = try XCTUnwrap(identities.first { $0.fileID == firstSource.id })
                let firstResult = try await store.resolveAutomaticCodemapSelection(
                    sources: [firstIdentity],
                    rootScope: .visibleWorkspace
                )
                let mergedResult = try await store.resolveAutomaticCodemapSelection(
                    sources: Array(identities.reversed()),
                    rootScope: .visibleWorkspace
                )
                if firstResult.targets.map(\.fileID) == [firstTarget.id],
                   mergedResult.roots.map(\.rootEpoch.rootID) == expectedOrderedRootIDs,
                   mergedResult.targets.map(\.fileID) == expectedOrderedTargetIDs
                {
                    isolated = firstResult
                    merged = mergedResult
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let isolatedResult = try XCTUnwrap(isolated)
        XCTAssertEqual(isolatedResult.targets.map(\.fileID), [firstTarget.id])
        XCTAssertFalse(isolatedResult.targets.contains { $0.fileID == secondTarget.id })
        let mergedResult = try XCTUnwrap(merged)
        let expectedRootIDs = mergedResult.roots.map(\.rootEpoch).sorted(
            by: workspaceCodemapRootEpochPrecedes
        ).map(\.rootID)
        let expectedTargetByRoot = [firstRoot.id: firstTarget.id, secondRoot.id: secondTarget.id]
        let expectedTargets = expectedRootIDs.compactMap { expectedTargetByRoot[$0] }
        XCTAssertEqual(mergedResult.roots.map(\.rootEpoch.rootID), expectedRootIDs)
        XCTAssertEqual(mergedResult.targets.map(\.fileID), expectedTargets)
        XCTAssertEqual(mergedResult.roots.map { $0.targets.map(\.fileID) }, expectedTargets.map { [$0] })
        XCTAssertTrue(mergedResult.roots.allSatisfy { root in
            root.targets.allSatisfy { $0.rootEpoch == root.rootEpoch }
        })
    }

    func testInvalidEarlierRootDoesNotChargeAcceptedBudgetsOrSuppressHealthyLaterRoot() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: "\(#function)-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: "\(#function)-second")
        let firstURL = try firstRepository.makeRepository(
            named: "repository-a",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let secondURL = try secondRepository.makeRepository(
            named: "repository-b",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let policy = WorkspaceCodemapAutomaticSelectionBudgetPolicy(
            maximumTargetCount: 1,
            maximumResolutionCount: 1,
            maximumReferenceFailureCount: 0,
            maximumByteCount: 4096
        )
        let store = fixture.makeStore(selectionGraphQueryBudgetPolicy: policy)
        let firstRoot = try await store.loadRoot(path: firstURL.path)
        let secondRoot = try await store.loadRoot(path: secondURL.path)
        let rootURLs = [firstRoot.id: firstURL, secondRoot.id: secondURL]
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let secondFiles = await store.files(inRoot: secondRoot.id)
        let allFiles = firstFiles + secondFiles
        let sources = allFiles.filter { $0.standardizedRelativePath == "Sources/Source.swift" }
        let targetsByRoot = Dictionary(uniqueKeysWithValues: allFiles.compactMap { file in
            file.standardizedRelativePath == "Sources/Target.swift" ? (file.rootID, file.id) : nil
        })
        for source in sources {
            _ = try await waitForAutomaticSelection(
                store: store,
                sourceFileIDs: [source.id],
                expectedTargetFileIDs: [XCTUnwrap(targetsByRoot[source.rootID])]
            )
        }
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sources.map(\.id),
            rootScope: .visibleWorkspace
        ).sorted { workspaceCodemapRootEpochPrecedes($0.rootEpoch, $1.rootEpoch) }
        let staleFirst = try XCTUnwrap(identities.first)
        let healthyLater = try XCTUnwrap(identities.last)
        let staleURL = try XCTUnwrap(rootURLs[staleFirst.rootEpoch.rootID])
        try "protocol SourceProtocol { var target: Target { get }; var changed: Bool { get } }\n".write(
            to: staleURL.appendingPathComponent("Sources/Source.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: staleFirst.rootEpoch.rootID,
            deltas: [.fileModified("Sources/Source.swift", Date())]
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [staleFirst, healthyLater],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(result.targets.map(\.fileID), try [XCTUnwrap(targetsByRoot[healthyLater.rootEpoch.rootID])])
        XCTAssertEqual(result.roots.map(\.rootEpoch), [staleFirst.rootEpoch, healthyLater.rootEpoch])
        XCTAssertTrue(result.roots[0].issues.contains { issue in
            if case .sourceGenerationChanged = issue { return true }
            return false
        })
        XCTAssertEqual(result.roots[1].status, .ok)
        XCTAssertNotNil(result.roots[1].receipt)
    }

    func testGraphBudgetRootDoesNotSuppressHealthyRealStoreRoot() async throws {
        let budgetRepository = try ReviewGitRepositoryFixture(name: "\(#function)-budget")
        let healthyRepository = try ReviewGitRepositoryFixture(name: "\(#function)-healthy")
        let budgetURL = try budgetRepository.makeRepository(
            named: "budget",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: ForeignDefinition { get } }\n"
            ]
        )
        let healthyURL = try healthyRepository.makeRepository(
            named: "healthy",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            budgetRepository.cleanup()
            healthyRepository.cleanup()
        }
        let policy = WorkspaceCodemapAutomaticSelectionBudgetPolicy(
            maximumTargetCount: 10,
            maximumResolutionCount: 10,
            maximumReferenceFailureCount: 0,
            maximumByteCount: 4096
        )
        let store = fixture.makeStore(selectionGraphQueryBudgetPolicy: policy)
        let budgetRoot = try await store.loadRoot(path: budgetURL.path)
        let healthyRoot = try await store.loadRoot(path: healthyURL.path)
        let budgetFiles = await store.files(inRoot: budgetRoot.id)
        let budgetSource = try XCTUnwrap(budgetFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let healthyFiles = await store.files(inRoot: healthyRoot.id)
        let healthySource = try XCTUnwrap(healthyFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let healthyTarget = try XCTUnwrap(healthyFiles.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var resolved: WorkspaceCodemapAutomaticSelectionResult?
        while clock.now < deadline {
            let identities = await store.codemapAutomaticSelectionSourceIdentities(
                forFileIDs: [budgetSource.id, healthySource.id],
                rootScope: .visibleWorkspace
            )
            if identities.count == 2 {
                let candidate = try await store.resolveAutomaticCodemapSelection(
                    sources: Array(identities.reversed()),
                    rootScope: .visibleWorkspace
                )
                let budgetResult = candidate.roots.first { $0.rootEpoch.rootID == budgetRoot.id }
                let healthyResult = candidate.roots.first { $0.rootEpoch.rootID == healthyRoot.id }
                if budgetResult?.issues.contains(.budget(.referenceFailureLimit(attempted: 1, limit: 0))) == true,
                   healthyResult?.targets.map(\.fileID) == [healthyTarget.id]
                {
                    resolved = candidate
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let result = try XCTUnwrap(resolved)
        let budgetResult = try XCTUnwrap(result.roots.first { $0.rootEpoch.rootID == budgetRoot.id })
        let healthyResult = try XCTUnwrap(result.roots.first { $0.rootEpoch.rootID == healthyRoot.id })
        XCTAssertEqual(
            result.roots.map(\.rootEpoch),
            result.roots.map(\.rootEpoch).sorted(by: workspaceCodemapRootEpochPrecedes)
        )
        XCTAssertEqual(budgetResult.status, .unavailable)
        XCTAssertEqual(budgetResult.targets, [])
        XCTAssertNil(budgetResult.receipt)
        XCTAssertEqual(
            budgetResult.issues,
            [.budget(.referenceFailureLimit(attempted: 1, limit: 0))]
        )
        XCTAssertEqual(healthyResult.status, .ok)
        XCTAssertEqual(healthyResult.targets.map(\.fileID), [healthyTarget.id])
        XCTAssertNotNil(healthyResult.receipt)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.targets.map(\.fileID), [healthyTarget.id])
        XCTAssertEqual(result.receipt?.roots.map(\.rootEpoch.rootID), [healthyRoot.id])
    }

    func testTargetDemandDeadlineDrainsExactOwnedTicket() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let demandAttempts = CodemapLockedCounter()
        let cleaned = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore(
            cancellationCleanupHook: { cleaned.append($0) },
            demandResultHook: { _, result in
                demandAttempts.incrementAndGet() == 1
                    ? .busy(retryAfterMilliseconds: 0)
                    : result
            }
        )
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [target.id]
        )
        let ticketOffset = fixture.demandedTickets.values.count
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 10,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 10,
                maximumTotalWait: .seconds(1)
            ),
            automaticSelectionWaiter: .init(sleep: { _ in
                try await Task.sleep(for: .milliseconds(10))
            })
        )
        let result = try await service.resolveAutomaticCodemapSelection(sourceFileIDs: [source.id])
        XCTAssertEqual(result.targets, [])
        XCTAssertFalse(result.issues.isEmpty)
        let demanded = Array(fixture.demandedTickets.values.dropFirst(ticketOffset))
        XCTAssertEqual(demanded.map(\.fileID), [target.id])
        XCTAssertEqual(demandAttempts.value, 1)
        XCTAssertEqual(Set(cleaned.values.map(\.retainID)), Set(demanded.map(\.retainID)))
    }

    func testTargetDemandBusyRetryReleasesPriorTicketAndSucceeds() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let demandAttempts = CodemapLockedCounter()
        let cleaned = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore(
            cancellationCleanupHook: { cleaned.append($0) },
            demandResultHook: { _, result in
                demandAttempts.incrementAndGet() == 1
                    ? .busy(retryAfterMilliseconds: 0)
                    : result
            }
        )
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [target.id]
        )
        let ticketOffset = fixture.demandedTickets.values.count
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 300,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 25,
                maximumTotalWait: .seconds(10)
            ),
            automaticSelectionWaiter: .init(sleep: { _ in
                try await Task.sleep(for: .milliseconds(25))
            })
        )
        let result = try await service.resolveAutomaticCodemapSelection(sourceFileIDs: [source.id])
        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        let demanded = Array(fixture.demandedTickets.values.dropFirst(ticketOffset))
        XCTAssertEqual(demanded.map(\.fileID), [target.id, target.id])
        XCTAssertEqual(demandAttempts.value, 2)
        XCTAssertEqual(Set(cleaned.values.map(\.retainID)), Set(demanded.map(\.retainID)))
    }

    func testTargetDemandCancellationDrainsExactOwnedTicket() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let demandGate = TestReleaseFence(name: "automatic target cancellation")
        let cleaned = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        addTeardownBlock {
            demandGate.release()
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore(
            cancellationCleanupHook: { cleaned.append($0) },
            demandResultHook: { _, result in
                await demandGate.enterAndWait()
                return result
            }
        )
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [target.id]
        )
        let service = WorkspaceSelectionMutationService(store: store)
        let resolution = Task {
            try await service.resolveAutomaticCodemapSelection(sourceFileIDs: [source.id])
        }
        let entered = await demandGate.waitUntilEntered(timeout: TestFenceDefaults.enterWait)
        XCTAssertTrue(entered)
        resolution.cancel()
        demandGate.release()
        do {
            _ = try await resolution.value
            XCTFail("Expected automatic target demand cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(fixture.demandedTickets.values.map(\.fileID), [target.id])
        XCTAssertEqual(cleaned.values.map(\.fileID), [target.id])
    }

    func testFinalRevalidationDropsTargetMutatedDuringDemandAndCleansTicket() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let publication = TestReleaseFence(name: "automatic target publication")
        let cleaned = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        addTeardownBlock {
            publication.release()
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore(
            cancellationCleanupHook: { cleaned.append($0) },
            demandResultHook: { _, result in
                await publication.enterAndWait()
                return result
            }
        )
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [target.id]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 100,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .seconds(5)
            ),
            automaticSelectionWaiter: .init(sleep: { _ in await Task.yield() })
        )
        let resolution = Task {
            try await service.resolveAutomaticCodemapSelection(sourceFileIDs: [source.id])
        }
        let publicationEntered = await publication.waitUntilEntered(timeout: TestFenceDefaults.enterWait)
        XCTAssertTrue(publicationEntered)
        try "struct Target { let changed: Bool }\n".write(
            to: rootURL.appendingPathComponent("Sources/Target.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: root.id,
            deltas: [.fileModified("Sources/Target.swift", Date())]
        )
        publication.release()
        let result = try await resolution.value
        XCTAssertEqual(result.targets, [])
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue([.pending, .unavailable].contains(result.roots[0].status))
        XCTAssertEqual(cleaned.values.map(\.fileID), [target.id])
    }

    func testRootReloadAndVisibleScopeChangesInvalidateReceipts() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let extraRepository = try ReviewGitRepositoryFixture(name: "\(#function)-extra")
        let extraURL = try extraRepository.makeRepository(
            named: "extra",
            files: ["Sources/Extra.swift": "struct Extra {}\n"]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
            extraRepository.cleanup()
        }
        let store = fixture.makeStore()
        let firstRoot = try await store.loadRoot(path: rootURL.path)
        let firstFiles = await store.files(inRoot: firstRoot.id)
        let firstSource = try XCTUnwrap(firstFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let firstTarget = try XCTUnwrap(firstFiles.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let first = try await waitForAutomaticSelection(
            store: store,
            sourceFileIDs: [firstSource.id],
            expectedTargetFileIDs: [firstTarget.id]
        )
        let firstReceipt = try XCTUnwrap(first.receipt)

        await store.unloadRoot(id: firstRoot.id)
        let reloadedRoot = try await store.loadRoot(path: rootURL.path)
        let afterReload = await store.revalidateAutomaticCodemapSelection(
            firstReceipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(afterReload.validTargets, [])
        XCTAssertEqual(afterReload.issues, [.rootScopeChanged])

        let reloadedFiles = await store.files(inRoot: reloadedRoot.id)
        let reloadedSource = try XCTUnwrap(reloadedFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let reloadedTarget = try XCTUnwrap(reloadedFiles.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let reloaded = try await waitForAutomaticSelection(
            store: store,
            sourceFileIDs: [reloadedSource.id],
            expectedTargetFileIDs: [reloadedTarget.id]
        )
        let reloadedReceipt = try XCTUnwrap(reloaded.receipt)
        _ = try await store.loadRoot(path: extraURL.path)
        let afterScopeChange = await store.revalidateAutomaticCodemapSelection(
            reloadedReceipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(afterScopeChange.validTargets, [])
        XCTAssertEqual(afterScopeChange.issues, [.rootScopeChanged])
    }

    func testRevalidationPreservesUnaffectedSiblingTargetAfterRealStoreMutation() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var first: FirstTarget { get }; var second: SecondTarget { get } }\n",
                "Sources/First.swift": "struct FirstTarget {}\n",
                "Sources/Second.swift": "struct SecondTarget {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let first = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/First.swift" })
        let second = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Second.swift" })

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var resolved: WorkspaceCodemapAutomaticSelectionResult?
        while clock.now < deadline {
            let identities = await store.codemapAutomaticSelectionSourceIdentities(
                forFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
            if let identity = identities.first {
                let candidate = try await store.resolveAutomaticCodemapSelection(
                    sources: [identity],
                    rootScope: .visibleWorkspace
                )
                if Set(candidate.targets.map(\.fileID)) == Set([first.id, second.id]), candidate.receipt != nil {
                    resolved = candidate
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let receipt = try XCTUnwrap(resolved?.receipt)

        try "struct FirstTarget { let changed: Bool }\n".write(
            to: rootURL.appendingPathComponent("Sources/First.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: loaded.id,
            deltas: [.fileModified("Sources/First.swift", Date())]
        )

        var revalidation = await store.revalidateAutomaticCodemapSelection(
            receipt,
            rootScope: .visibleWorkspace
        )
        let mutationDeadline = clock.now.advanced(by: .seconds(10))
        while revalidation.validTargets.contains(where: { $0.fileID == first.id }), clock.now < mutationDeadline {
            try await Task.sleep(for: .milliseconds(25))
            revalidation = await store.revalidateAutomaticCodemapSelection(
                receipt,
                rootScope: .visibleWorkspace
            )
        }
        XCTAssertEqual(revalidation.validTargets.map(\.fileID), [second.id])
        XCTAssertTrue(revalidation.issues.contains(.targetGenerationChanged(
            rootEpoch: receipt.roots[0].rootEpoch,
            fileID: first.id
        )))
        guard case let .valid(_, targets) = revalidation.roots.first else {
            return XCTFail("A stale sibling target must not invalidate the healthy target in the same root.")
        }
        XCTAssertEqual(targets.map(\.fileID), [second.id])
    }

    private func waitForAutomaticSelection(
        store: WorkspaceFileContextStore,
        sourceFileIDs: [UUID],
        expectedTargetFileIDs: [UUID]
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let identities = await store.codemapAutomaticSelectionSourceIdentities(
                forFileIDs: sourceFileIDs,
                rootScope: .visibleWorkspace
            )
            if identities.count == sourceFileIDs.count {
                let result = try await store.resolveAutomaticCodemapSelection(
                    sources: identities,
                    rootScope: .visibleWorkspace
                )
                if result.targets.map(\.fileID) == expectedTargetFileIDs, result.receipt != nil {
                    return result
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CodemapStoreTestError.timedOut
    }
}
