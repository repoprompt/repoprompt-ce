import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapAutomaticSelectionGraphNativeTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testGraphCatalogFirstPageExposesImmutableProjectedTotalFromStore() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Alpha.swift": SwiftFixtureSource.emptyStruct("Alpha"),
                "Sources/Beta.swift": SwiftFixtureSource.emptyStruct("Beta")
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore(codemapGraphIndexBuildLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let alpha = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Alpha.swift"
        })
        let demand = try await readyArtifactDemand(store: store, forFileID: alpha.id)
        let catalog = fixture.registry.makeBindingCatalogClient()
        let page = try await graphIndexPage(catalog.readGraphIndexCatalogPage(
            WorkspaceCodemapGraphIndexCatalogPageRequest(
                rootEpoch: demand.ticket.rootEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 1,
                maximumPathByteCount: 1024
            )
        ))

        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.supportedCandidateCountThroughPage, 1)
        XCTAssertEqual(page.projectedSupportedCandidateTotal, 2)
        XCTAssertFalse(page.isEnd)
    }

    func testPublisherIngressAppliesCatalogWhileCorrelatedCodemapInvalidationIsStalled() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Seed.swift": SwiftFixtureSource.emptyStruct("Seed")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let codemapGate = TestReleaseFence(name: "codemap suspension gate")
        addTeardownBlock {
            await codemapGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let seed = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Seed.swift"
        })
        let initialDemand = try await readyArtifactDemand(store: store, forFileID: seed.id)
        let ticket = initialDemand.ticket

        await store.setCodemapPathInvalidationStageHandlerForTesting { epoch, _, stage in
            guard epoch == ticket.rootEpoch, stage == .rootMutationFence else { return }
            await codemapGate.enterAndWait()
        }

        let createdRelativePath = "Sources/Generated.swift"
        let createdURL = root.appendingPathComponent(createdRelativePath)
        try SwiftFixtureSource.emptyStruct("Generated").write(
            to: createdURL,
            atomically: true,
            encoding: .utf8
        )
        try await store.replayPublisherFileSystemDeltasForCodemapIndependenceTesting(
            rootID: loaded.id,
            deltas: [.fileAdded(createdRelativePath)],
            servicePublicationSequence: 41
        )
        let codemapStalled = await codemapGate.waitUntilEntered()
        XCTAssertTrue(codemapStalled)
        guard codemapStalled else { return }

        let catalogFile = await store.file(rootID: loaded.id, relativePath: createdRelativePath)
        XCTAssertNotNil(catalogFile)

        let demandDuringInvalidation = await store.requestCodemapArtifact(forFileID: seed.id)
        guard case .unavailable(.busy) = demandDuringInvalidation else {
            return XCTFail("Expected the retained codemap invalidation flight to fence demand admission")
        }

        let rootFenceTask = Task {
            try await store.replayPublisherFileSystemDeltasForCodemapIndependenceTesting(
                rootID: loaded.id,
                deltas: [.fileModified(".git/HEAD", nil)],
                servicePublicationSequence: 42
            )
        }
        var rootFenceParked = false
        for _ in 0 ..< 200 {
            if await store.codemapPathQuiescenceWaiterCountForTesting(rootEpoch: ticket.rootEpoch) == 1 {
                rootFenceParked = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(rootFenceParked, "Root fence acquisition should park behind retained path work")
        guard rootFenceParked else {
            codemapGate.release()
            _ = try? await rootFenceTask.value
            return
        }

        let explicitlyCreatedRelativePath = "Sources/Explicit.swift"
        let explicitlyCreatedURL = root.appendingPathComponent(explicitlyCreatedRelativePath)
        let createTask = Task {
            try await store.createFile(
                rootID: loaded.id,
                relativePath: explicitlyCreatedRelativePath,
                content: SwiftFixtureSource.emptyStruct("Explicit")
            )
        }
        var createdBeforeDerivedInvalidationReleased = false
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: explicitlyCreatedURL.path) {
                createdBeforeDerivedInvalidationReleased = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            createdBeforeDerivedInvalidationReleased,
            "Explicit create must not wait for publisher-derived codemap convergence"
        )
        _ = try await createTask.value
        let waiterCountWhileStalled = await store.codemapPathQuiescenceWaiterCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(waiterCountWhileStalled, 1)

        let deleteTask = Task {
            try await store.deleteFile(rootID: loaded.id, relativePath: createdRelativePath)
        }
        var deletedBeforeDerivedInvalidationReleased = false
        for _ in 0 ..< 200 {
            if !FileManager.default.fileExists(atPath: createdURL.path) {
                deletedBeforeDerivedInvalidationReleased = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            deletedBeforeDerivedInvalidationReleased,
            "Explicit mutation must not wait for publisher-derived codemap convergence"
        )

        await codemapGate.release()
        try await deleteTask.value
        try await rootFenceTask.value
        let waiterCountAfterRelease = await store.codemapPathQuiescenceWaiterCountForTesting(
            rootEpoch: ticket.rootEpoch
        )
        XCTAssertEqual(waiterCountAfterRelease, 0)
        await store.setCodemapPathInvalidationStageHandlerForTesting(nil)

        let refreshed = try await readyArtifactDemand(store: store, forFileID: seed.id)
        XCTAssertEqual(refreshed.ticket.fileID, seed.id)
    }

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

        _ = try await readyArtifactDemand(
            store: store,
            forFileID: source.id,
            priority: .background
        )
        let automaticDemandTicketOffset = fixture.demandedTickets.values.count

        _ = try await awaitCodemapGraphsReady(store: store, rootIDs: [loaded.id])
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
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

        _ = try await awaitCodemapGraphsReady(
            store: store,
            rootIDs: [firstRoot.id, secondRoot.id]
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [firstSource.id, secondSource.id],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(identities.count, 2)
        let firstIdentity = try XCTUnwrap(identities.first { $0.fileID == firstSource.id })
        let isolatedResult = try await store.resolveAutomaticCodemapSelection(
            sources: [firstIdentity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(isolatedResult.targets.map(\.fileID), [firstTarget.id])
        XCTAssertFalse(isolatedResult.targets.contains { $0.fileID == secondTarget.id })
        let mergedResult = try await store.resolveAutomaticCodemapSelection(
            sources: Array(identities.reversed()),
            rootScope: .visibleWorkspace
        )
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
                rootIDs: [source.rootID],
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

        _ = try await awaitCodemapGraphsReady(
            store: store,
            rootIDs: [budgetRoot.id, healthyRoot.id]
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [budgetSource.id, healthySource.id],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(identities.count, 2)
        let result = try await store.resolveAutomaticCodemapSelection(
            sources: Array(identities.reversed()),
            rootScope: .visibleWorkspace
        )
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

    func testTargetDemandRetryExhaustionDrainsExactOwnedTicket() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let cleaned = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore(
            cancellationCleanupHook: { cleaned.append($0) },
            demandResultHook: { _, _ in .busy(retryAfterMilliseconds: 0) }
        )
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            rootIDs: [root.id],
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [target.id]
        )
        let ticketOffset = fixture.demandedTickets.values.count
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 1,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .zero
            )
        )
        let result = try await service.resolveAutomaticCodemapSelection(sourceFileIDs: [source.id])
        XCTAssertEqual(result.targets, [])
        XCTAssertFalse(result.issues.isEmpty)
        let demanded = Array(fixture.demandedTickets.values.dropFirst(ticketOffset))
        XCTAssertEqual(demanded.map(\.fileID), [target.id])
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
            rootIDs: [root.id],
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
        let demandPublication = TestReleaseFence(name: "automatic target publication")
        let readinessWait = TestReleaseFence(name: "automatic target readiness wait")
        let demandGateEnabled = CodemapLockedCounter()
        let cleaned = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        addTeardownBlock {
            demandPublication.release()
            readinessWait.release()
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore(
            cancellationCleanupHook: { cleaned.append($0) },
            demandResultHook: { _, result in
                if demandGateEnabled.value > 0 {
                    await demandPublication.enterAndWaitIgnoringCancellationUntilRelease()
                }
                return result
            }
        )
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            rootIDs: [root.id],
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [target.id]
        )
        let ticketOffset = fixture.demandedTickets.values.count
        let cleanupOffset = cleaned.values.count
        demandGateEnabled.increment()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 100,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .seconds(5)
            ),
            automaticSelectionWaiter: .init(sleep: { _ in
                await readinessWait.enterAndWaitIgnoringCancellationUntilRelease()
            })
        )
        let resolution = Task {
            try await service.resolveAutomaticCodemapSelection(sourceFileIDs: [source.id])
        }
        let entered = await readinessWait.waitUntilEntered(timeout: TestFenceDefaults.enterWait)
        XCTAssertTrue(entered)
        resolution.cancel()
        readinessWait.release()
        do {
            _ = try await resolution.value
            XCTFail("Expected automatic target demand cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        demandPublication.release()
        XCTAssertEqual(
            Array(fixture.demandedTickets.values.dropFirst(ticketOffset)).map(\.fileID),
            [target.id]
        )
        XCTAssertEqual(
            Array(cleaned.values.dropFirst(cleanupOffset)).map(\.fileID),
            [target.id]
        )
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
            rootIDs: [root.id],
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

    func testDefaultCandidateDemandCapRejects1025Targets() {
        let selectionPolicy = WorkspaceCodemapAutomaticSelectionRequestPolicy.default
        let presentationPolicy = WorkspaceCodemapPresentationRequestPolicy.default

        for candidateDemandLimitIssue in [
            selectionPolicy.candidateDemandLimitIssue,
            presentationPolicy.candidateDemandLimitIssue
        ] {
            XCTAssertNil(candidateDemandLimitIssue(1024))
            XCTAssertEqual(
                candidateDemandLimitIssue(1025),
                .budget(.targetDemandLimit(attempted: 1025, limit: 1024))
            )
        }
    }

    func testCandidateDemandCapStopsBeforeTargetDemandLoop() async throws {
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
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let first = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/First.swift" })
        let second = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Second.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            rootIDs: [root.id],
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [first.id, second.id]
        )
        let ticketOffset = fixture.demandedTickets.values.count
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(maximumCandidateDemandCount: 1)
        )

        let result = try await service.resolveAutomaticCodemapSelection(sourceFileIDs: [source.id])

        let issue = WorkspaceCodemapAutomaticSelectionIssue.budget(
            .targetDemandLimit(attempted: 2, limit: 1)
        )
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.aggregateCoverage, .unavailable([issue]))
        XCTAssertEqual(result.targets, [])
        XCTAssertNil(result.receipt)
        XCTAssertEqual(fixture.demandedTickets.values.count, ticketOffset)
    }

    func testPresentationCandidateDemandCapStopsBeforeAutomaticTargetDemandLoop() async throws {
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
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let first = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/First.swift" })
        let second = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Second.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            rootIDs: [root.id],
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [first.id, second.id]
        )
        let ticketOffset = fixture.demandedTickets.values.count
        let presentation = try await WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: .init(maximumCandidateDemandCount: 1)
        ).presentation(
            for: .automatic(sourceFileIDs: [source.id]),
            rootScope: .visibleWorkspace,
            logicalRootDisplayNamesByRootID: [root.id: rootURL.lastPathComponent]
        )

        let issue = WorkspaceCodemapAutomaticSelectionIssue.budget(
            .targetDemandLimit(attempted: 2, limit: 1)
        )
        let operationIssue = WorkspaceCodemapOperationIssue.automatic(.unavailable([issue]))
        XCTAssertEqual(presentation.orderedEntries, [])
        XCTAssertNil(presentation.publicationReceipt)
        XCTAssertTrue(presentation.issues.contains(operationIssue))
        guard case let .unavailable(coverageIssues) = presentation.coverage else {
            return XCTFail("An oversized automatic presentation must fail before target demand.")
        }
        XCTAssertTrue(coverageIssues.contains(operationIssue))
        XCTAssertEqual(fixture.demandedTickets.values.count, ticketOffset)
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
            rootIDs: [firstRoot.id],
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
            rootIDs: [reloadedRoot.id],
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

        _ = try await awaitCodemapGraphsReady(store: store, rootIDs: [loaded.id])
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let resolved = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(Set(resolved.targets.map(\.fileID)), Set([first.id, second.id]))
        let receipt = try XCTUnwrap(resolved.receipt)

        try "struct FirstTarget { let changed: Bool }\n".write(
            to: rootURL.appendingPathComponent("Sources/First.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await store.replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: loaded.id,
            deltas: [.fileModified("Sources/First.swift", Date())]
        )

        let revalidation = await store.revalidateAutomaticCodemapSelection(
            receipt,
            rootScope: .visibleWorkspace
        )
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

    @MainActor
    func testPendingViewModelSelectionRetriesWhenMarkerBecomesReadyWithoutRootStatusChange() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": "struct Target {}\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let readyPublication = TestReleaseFence(name: "delayed automatic target readiness")
        addTeardownBlock {
            readyPublication.release()
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore(readyPublicationHook: { _ in
            await readyPublication.enterAndWait()
        })
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        _ = try await waitForAutomaticSelection(
            store: store,
            rootIDs: [root.id],
            sourceFileIDs: [source.id],
            expectedTargetFileIDs: [target.id]
        )

        let manager = WorkspaceFilesViewModel(
            workspaceFileContextStore: store,
            automaticCodemapSelectionRequestPolicy: .init(
                maximumReadinessRounds: 1,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .milliseconds(1)
            ),
            automaticCodemapReadinessRetryDelay: .milliseconds(500)
        )
        _ = try manager.attachRootShell(for: root, workspaceID: UUID())
        let sourceViewModelValue = await manager.materializeFileForUserInput(source.standardizedFullPath)
        let sourceViewModel = try XCTUnwrap(sourceViewModelValue)
        manager.selectFileForTesting(sourceViewModel)
        let clock = ContinuousClock()
        let retryDeadline = clock.now.advanced(by: .seconds(3))
        while fixture.demandedTickets.values.count < 2, clock.now < retryDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(manager.autoCodemapFiles.isEmpty)
        let unchangedRootStatus = manager.codemapRootStatus(rootID: root.id)
        XCTAssertEqual(fixture.demandedTickets.values.map(\.fileID), [target.id, target.id])

        readyPublication.release()
        let deadline = clock.now.advanced(by: .seconds(5))
        while manager.autoCodemapFiles.map(\.id) != [target.id], clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(manager.autoCodemapFiles.map(\.id), [target.id])
        XCTAssertFalse(manager.automaticCodemapReadinessRetryPendingForTesting)
        XCTAssertFalse(manager.automaticCodemapReadinessRetryTaskActiveForTesting)
        XCTAssertEqual(
            manager.codemapRootStatus(rootID: root.id)?.availability,
            unchangedRootStatus?.availability
        )
        XCTAssertEqual(fixture.demandedTickets.values.map(\.fileID), [target.id, target.id])
        XCTAssertTrue(readyPublication.hasEntered)

        let presentation = try await WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 32,
                initialBackoffMilliseconds: 5,
                maximumBackoffMilliseconds: 50,
                maximumTotalWait: .seconds(5)
            )
        ).presentation(
            for: .automatic(sourceFileIDs: [source.id]),
            rootScope: .visibleWorkspace,
            logicalRootDisplayNamesByRootID: [root.id: rootURL.lastPathComponent]
        )
        XCTAssertEqual(presentation.orderedEntries.map(\.fileID), [target.id])
        if case .pending = presentation.coverage {
            XCTFail("Automatic presentation must wait for the target instead of returning pending.")
        }
        await manager.unloadAllRootFolders()
    }

    @MainActor
    func testPartialResultWithPendingSiblingRequiresReadinessRetryAfterPublishing() throws {
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: UUID(),
            rootLifetimeID: UUID()
        )
        let readyTarget = try WorkspaceCodemapAutomaticSelectionTarget(
            rootEpoch: rootEpoch,
            fileID: UUID(),
            catalogGeneration: 4,
            requestGeneration: 7,
            logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: "repository",
                standardizedRelativePath: "Sources/Ready.swift"
            ))
        )
        let pendingFileID = UUID()
        let root = WorkspaceCodemapAutomaticSelectionRootResult(
            rootEpoch: rootEpoch,
            status: .partial,
            targets: [readyTarget],
            sources: [],
            issues: [.targetDemandPending(rootEpoch: rootEpoch, fileID: pendingFileID)],
            coverage: nil,
            graphTargetCount: 2,
            graphResolutionCount: 1,
            graphReferenceFailureCount: 0,
            graphByteCount: 128,
            receipt: nil
        )
        let result = WorkspaceCodemapAutomaticSelectionResult(roots: [root])

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.targets, [readyTarget])
        XCTAssertTrue(WorkspaceFilesViewModel.automaticCodemapResultNeedsReadinessRetry(result))
    }

    private func waitForAutomaticSelection(
        store: WorkspaceFileContextStore,
        rootIDs: Set<UUID>,
        sourceFileIDs: [UUID],
        expectedTargetFileIDs: [UUID]
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult {
        _ = try await awaitCodemapGraphsReady(store: store, rootIDs: rootIDs)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceFileIDs,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(identities.count, sourceFileIDs.count)
        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(result.targets.map(\.fileID), expectedTargetFileIDs)
        XCTAssertNotNil(result.receipt)
        return result
    }
}
