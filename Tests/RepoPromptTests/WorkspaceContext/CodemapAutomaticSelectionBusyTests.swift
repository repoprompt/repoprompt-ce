import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodemapAutomaticSelectionBusyTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testAutomaticSelectionTranslatesRebuildingRuntimeToBusyConsumerCoverage() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Source.swift": SwiftFixtureSource.emptyStruct("Source")]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { rootEpoch, query in
                guard rootEpoch == query.key.rootEpoch else { return nil }
                queryCount.increment()
                return .unavailable(.rebuilding)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let ready = try await readyResult(settledResult(store: store, ticket: ticket))
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: identity.rootEpoch,
            minimumNodeCount: 1
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: ready.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: []
                )
            ]
        )
        let busyReason = WorkspaceCodemapStoreSelectionGraphQueryBusyReason.runtime(
            rootEpoch: identity.rootEpoch,
            reason: .rebuilding
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )
        let rootResult = try XCTUnwrap(result.roots.first)

        XCTAssertEqual(queryCount.value, 1)
        XCTAssertEqual(result.roots.count, 1)
        XCTAssertEqual(rootResult.rootEpoch, identity.rootEpoch)
        XCTAssertEqual(rootResult.targets, [])
        XCTAssertEqual(rootResult.sourceIssues, [])
        XCTAssertEqual(rootResult.targetIssues, [])
        XCTAssertEqual(rootResult.coverage, .busy(busyReason))
        XCTAssertEqual(rootResult.graphTargetCount, 0)
        XCTAssertEqual(rootResult.graphResolutionCount, 0)
        XCTAssertEqual(rootResult.graphReferenceFailureCount, 0)
        XCTAssertEqual(rootResult.graphByteCount, 0)
        XCTAssertNil(rootResult.graphKey)
        XCTAssertEqual(result.aggregateCoverage, .busy(busyReason))
        XCTAssertEqual(result.targets, [])
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRetriesTransientGraphReadinessThenPublishesReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { rootEpoch, query in
                guard rootEpoch == query.key.rootEpoch else { return nil }
                switch queryCount.incrementAndGet() {
                case 1:
                    return .unavailable(.notBuilt)
                case 2:
                    return .unavailable(.staleCurrentness(currentKey: query.key))
                default:
                    return nil
                }
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 4,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .seconds(2)
            )
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertGreaterThanOrEqual(queryCount.value, 3)
        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        let receipt = try XCTUnwrap(result.publicationReceipt)
        XCTAssertEqual(receipt.targets, result.targets)
        guard case let .complete(proofs) = result.aggregateCoverage else {
            return XCTFail("Expected complete coverage after transient graph readiness retries, got \(result.aggregateCoverage)")
        }
        XCTAssertEqual(receipt.coverageProofs, proofs)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRuntimeBudgetRemainsTerminalWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { rootEpoch, query in
                guard rootEpoch == query.key.rootEpoch else { return nil }
                queryCount.increment()
                return .unavailable(.outputBudgetExceeded(.resolvedTargets))
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 4,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .seconds(2)
            )
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        guard case .budget = result.aggregateCoverage else {
            return XCTFail("Expected terminal budget coverage, got \(result.aggregateCoverage)")
        }
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertLessThanOrEqual(queryCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRuntimeInvalidSnapshotRemainsTerminalWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        let queryCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphRuntimeQueryOverride: { rootEpoch, query in
                guard rootEpoch == query.key.rootEpoch else { return nil }
                queryCount.increment()
                return .unavailable(.invalidSnapshot)
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceTicket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["Source"],
                    references: ["Target"]
                ),
                target.id: CodeMapSelectionGraphContribution(
                    artifactKey: targetReady.snapshot.artifactKey,
                    definitions: ["Target"],
                    references: []
                )
            ]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 4,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1,
                maximumTotalWait: .seconds(2)
            )
        )
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(
            result.aggregateCoverage,
            .unavailable(.graph(.runtime(rootEpoch: identity.rootEpoch, reason: .invalidSnapshot)))
        )
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(queryCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionAccountingEqualityBoundaryFailsBeforeGraphQuery() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let queryCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphQueryBudgetPolicy: .init(
                maximumSourceIssueCount: 1,
                maximumTargetCount: 1,
                maximumResolutionCount: 1,
                maximumReferenceFailureCount: 1,
                maximumByteCount: 1
            ),
            automaticSelectionAccountingMaximum: 1,
            automaticSelectionQueryHook: { _ in queryCount.increment() }
        )

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots, [])
        XCTAssertEqual(result.targets, [])
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .budget(.accountingOverflow))
        XCTAssertEqual(queryCount.value, 0)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
    }

    func testAutomaticSelectionAccountingOverflowFailsClosedWithoutReceipt() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                protocol SourceProtocol {
                    func first() -> FirstTarget
                    func second() -> SecondTarget
                }
                """,
                "Sources/First.swift": SwiftFixtureSource.emptyStruct("FirstTarget"),
                "Sources/Second.swift": SwiftFixtureSource.emptyStruct("SecondTarget")
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let queryCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 1,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            ),
            automaticSelectionAccountingMaximum: 1,
            automaticSelectionQueryHook: { _ in queryCount.increment() }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        for file in files {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        _ = try XCTUnwrap(identities.first)

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: identities,
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots, [])
        XCTAssertEqual(result.targets, [])
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .budget(.accountingOverflow))
        XCTAssertEqual(queryCount.value, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionWithoutExistingDemandPerformsNoIOOrArtifactWork() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let root = try fixture.makePlainRoot(files: [
            "Sources/Source.swift": SwiftFixtureSource.emptyStruct("Source")
        ])
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock { await fixture.shutdown() }
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphFactory: graphProbe.factory
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [file.id],
            rootScope: .visibleWorkspace
        )
        let identity = try XCTUnwrap(identities.first)

        let result = try await store.resolveAutomaticCodemapSelection(
            sources: [identity],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.roots.first?.sourceIssues, [.notDemanded(identity)])
        XCTAssertEqual(result.roots.first?.coverage, .unavailable(.noReadySources))
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Setup.swift": SwiftFixtureSource.emptyStruct("Target"),
                "Sources/Source.swift": "struct Source { let target: Target }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let sourceFileIDs = CodemapLockedValues<UUID>()
        let selectionPhase = CodemapLockedCounter()
        let sourceDemandInvocations = CodemapLockedCounter()
        let busyOutcomes = CodemapLockedCounter()
        let sequence = CodemapAutomaticSelectionSequenceHarness()
        let settledOutcomes = CodemapLockedValues<WorkspaceCodemapArtifactDemandResult>()
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await sequence.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory,
            demandResultHook: { ticket, result in
                guard selectionPhase.value > 0,
                      sourceFileIDs.values.contains(ticket.fileID)
                else { return result }
                let invocation = await sequence.recordDemand(ticket)
                sourceDemandInvocations.increment()
                if invocation <= 2 {
                    busyOutcomes.increment()
                    return .busy(retryAfterMilliseconds: 1)
                }
                return result
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let setup = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Setup.swift"
        })
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        sourceFileIDs.append(source.id)
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: setup.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        let warmSourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: warmSourceTicket))
        _ = try await generationMatchedCompleteSeal(
            catalogClient: fixture.registry.makeBindingCatalogClient(),
            graphProbe: graphProbe,
            ticket: warmSourceTicket
        )
        _ = await store.cancelCodemapArtifactDemand(warmSourceTicket)
        selectionPhase.increment()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 6,
                initialBackoffMilliseconds: 400,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .seconds(10)
            ),
            automaticSelectionWaiter: .init { _ in try await sequence.wait() }
        )

        let resolution = Task {
            try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
        }
        let externalClock = ContinuousClock()
        let externalDeadline = externalClock.now.advanced(by: .seconds(5))
        let externalCompletion = CodemapBoundedCompletionState()
        let operation = Task { () throws -> WorkspaceCodemapAutomaticSelectionResult in
            defer {
                externalCompletion.recordCompletion(
                    beforeDeadline: externalClock.now < externalDeadline
                )
            }
            for demandIndex in 1 ... 3 {
                let pendingWaitIndex = demandIndex * 2 - 1
                guard await sequence.waitUntilWaitCount(pendingWaitIndex),
                      let tickets = await sequence.waitUntilDemandCount(demandIndex),
                      let ticket = tickets.last
                else { throw CodemapStoreTestError.timedOut }
                try await settledOutcomes.append(settledResult(
                    store: store,
                    ticket: ticket
                ))
                await sequence.releaseWait(pendingWaitIndex)
                if demandIndex < 3 {
                    let retryWaitIndex = pendingWaitIndex + 1
                    guard await sequence.waitUntilWaitCount(retryWaitIndex) else {
                        throw CodemapStoreTestError.timedOut
                    }
                    await sequence.releaseWait(retryWaitIndex)
                }
            }
            return try await resolution.value
        }
        let completedBeforeDeadline = await waitForCompletionBeforeExternalDeadline(
            externalCompletion,
            clock: externalClock,
            deadline: externalDeadline
        )
        guard completedBeforeDeadline else {
            resolution.cancel()
            operation.cancel()
            await sequence.releaseAll()
            let drained = await waitForBoundedCompletionDrain(externalCompletion)
            XCTAssertTrue(drained, "Busy-retry cleanup did not drain within its external bound")
            return XCTFail("Busy-retry sequence did not complete within the external bound")
        }
        let result = try await operation.value

        XCTAssertEqual(sourceDemandInvocations.value, 3)
        XCTAssertEqual(busyOutcomes.value, 2)
        let selectionTickets = await sequence.recordedTickets
        let waitCount = await sequence.waitCount
        XCTAssertEqual(selectionTickets.count, 3)
        XCTAssertEqual(waitCount, 5)
        XCTAssertEqual(settledOutcomes.values.count, 3)
        for outcome in settledOutcomes.values.prefix(2) {
            guard case .unavailable(.busy) = outcome else {
                return XCTFail("Expected the first two scoped demand outcomes to be busy")
            }
        }
        guard let finalOutcome = settledOutcomes.values.last,
              case .ready = finalOutcome
        else {
            return XCTFail("Expected the third scoped demand outcome to be ready")
        }
        XCTAssertEqual(result.targets.map(\.fileID), [setup.id])
        let receipt = try XCTUnwrap(
            result.publicationReceipt,
            "Expected receipt for \(result.aggregateCoverage)"
        )
        guard case let .complete(proofs) = result.aggregateCoverage else {
            return XCTFail("Expected complete proof-backed coverage after busy retries")
        }
        XCTAssertEqual(receipt.coverageProofs, proofs)
        XCTAssertEqual(receipt.targets, result.targets)
        XCTAssertNotNil(receipt.publicationLease)
        let publication = await store.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(publication, .current(result.targets))
        for ticket in selectionTickets {
            await assertStale(store.codemapArtifactDemandStatus(ticket))
        }
        let receiptSourceTicket = try XCTUnwrap(receipt.sourceTickets.first)
        let sourceRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: receiptSourceTicket.rootEpoch,
            fileID: source.id
        )
        XCTAssertEqual(sourceRetainCount, 0)
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionBusySourceRoundBoundStopsBeforeDeadline() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Setup.swift": SwiftFixtureSource.emptyStruct("Setup"),
                "Sources/Source.swift": SwiftFixtureSource.emptyStruct("Source")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let sourceFileIDs = CodemapLockedValues<UUID>()
        let selectionPhase = CodemapLockedCounter()
        let sourceDemandInvocations = CodemapLockedCounter()
        let sequence = CodemapAutomaticSelectionSequenceHarness()
        let settledOutcomes = CodemapLockedValues<WorkspaceCodemapArtifactDemandResult>()
        addTeardownBlock {
            await sequence.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(demandResultHook: { ticket, result in
            guard selectionPhase.value > 0,
                  sourceFileIDs.values.contains(ticket.fileID)
            else { return result }
            _ = await sequence.recordDemand(ticket)
            sourceDemandInvocations.increment()
            return .busy(retryAfterMilliseconds: 1)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let setup = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Setup.swift"
        })
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        sourceFileIDs.append(source.id)
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: setup.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        let warmSourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: warmSourceTicket))
        _ = await store.cancelCodemapArtifactDemand(warmSourceTicket)
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        selectionPhase.increment()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 6,
                initialBackoffMilliseconds: 400,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .seconds(10)
            ),
            automaticSelectionWaiter: .init { _ in try await sequence.wait() }
        )

        let resolution = Task {
            try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
        }
        let externalClock = ContinuousClock()
        let externalDeadline = externalClock.now.advanced(by: .seconds(5))
        let externalCompletion = CodemapBoundedCompletionState()
        let operation = Task { () throws -> WorkspaceCodemapAutomaticSelectionResult in
            defer {
                externalCompletion.recordCompletion(
                    beforeDeadline: externalClock.now < externalDeadline
                )
            }
            for demandIndex in 1 ... 3 {
                let pendingWaitIndex = demandIndex * 2 - 1
                guard await sequence.waitUntilWaitCount(pendingWaitIndex),
                      let tickets = await sequence.waitUntilDemandCount(demandIndex),
                      let ticket = tickets.last
                else { throw CodemapStoreTestError.timedOut }
                try await settledOutcomes.append(settledResult(
                    store: store,
                    ticket: ticket
                ))
                await sequence.releaseWait(pendingWaitIndex)
                if demandIndex < 3 {
                    let retryWaitIndex = pendingWaitIndex + 1
                    guard await sequence.waitUntilWaitCount(retryWaitIndex) else {
                        throw CodemapStoreTestError.timedOut
                    }
                    await sequence.releaseWait(retryWaitIndex)
                }
            }
            return try await resolution.value
        }
        let completedBeforeDeadline = await waitForCompletionBeforeExternalDeadline(
            externalCompletion,
            clock: externalClock,
            deadline: externalDeadline
        )
        guard completedBeforeDeadline else {
            resolution.cancel()
            operation.cancel()
            await sequence.releaseAll()
            let drained = await waitForBoundedCompletionDrain(externalCompletion)
            XCTAssertTrue(drained, "Busy round-bound cleanup did not drain within its external bound")
            return XCTFail("Busy round-bound sequence did not complete within the external bound")
        }
        let result = try await operation.value

        XCTAssertEqual(sourceDemandInvocations.value, 3)
        let selectionTickets = await sequence.recordedTickets
        let waitCount = await sequence.waitCount
        XCTAssertEqual(selectionTickets.count, 3)
        XCTAssertEqual(waitCount, 5)
        XCTAssertEqual(settledOutcomes.values.count, 3)
        for outcome in settledOutcomes.values {
            guard case .unavailable(.busy) = outcome else {
                return XCTFail("Expected every scoped demand outcome to remain busy")
            }
        }
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        guard case let .pending(reasons) = result.aggregateCoverage else {
            return XCTFail("Expected bounded busy pending coverage")
        }
        XCTAssertEqual(reasons.count, 1)
        if case let .sourceBusy(_, attempts) = reasons[0] {
            XCTAssertEqual(attempts, 2)
        } else {
            XCTFail("Expected source busy reason")
        }
        for ticket in selectionTickets {
            await assertStale(store.codemapArtifactDemandStatus(ticket))
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        let sourceRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: warmSourceTicket.rootEpoch,
            fileID: source.id
        )
        XCTAssertEqual(sourceRetainCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionBusySourceDeadlineStopsBeforeRoundBound() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Setup.swift": SwiftFixtureSource.emptyStruct("Setup"),
                "Sources/Source.swift": SwiftFixtureSource.emptyStruct("Source")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let sourceFileIDs = CodemapLockedValues<UUID>()
        let selectionPhase = CodemapLockedCounter()
        let sourceDemandInvocations = CodemapLockedCounter()
        let selectionTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(demandResultHook: { ticket, result in
            guard selectionPhase.value > 0,
                  sourceFileIDs.values.contains(ticket.fileID)
            else { return result }
            sourceDemandInvocations.increment()
            selectionTickets.append(ticket)
            return .busy(retryAfterMilliseconds: 1)
        })
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let setup = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Setup.swift"
        })
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        sourceFileIDs.append(source.id)
        let setupTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: setup.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: setupTicket))
        let warmSourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: warmSourceTicket))
        _ = await store.cancelCodemapArtifactDemand(warmSourceTicket)
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        selectionPhase.increment()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 100,
                initialBackoffMilliseconds: 400,
                maximumBackoffMilliseconds: 400,
                maximumTotalWait: .milliseconds(500)
            ),
            automaticSelectionWaiter: .production
        )
        let externalClock = ContinuousClock()
        let externalDeadline = externalClock.now.advanced(by: .seconds(5))
        let externalCompletion = CodemapBoundedCompletionState()
        let resolution = Task {
            defer {
                externalCompletion.recordCompletion(
                    beforeDeadline: externalClock.now < externalDeadline
                )
            }
            return try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )
        }
        let completedBeforeDeadline = await waitForCompletionBeforeExternalDeadline(
            externalCompletion,
            clock: externalClock,
            deadline: externalDeadline
        )
        guard completedBeforeDeadline else {
            resolution.cancel()
            let drained = await waitForBoundedCompletionDrain(externalCompletion)
            XCTAssertTrue(drained, "Busy deadline cleanup did not drain within its external bound")
            return XCTFail("Busy deadline resolution did not complete within the external bound")
        }
        let result = try await resolution.value

        XCTAssertGreaterThan(sourceDemandInvocations.value, 0)
        XCTAssertLessThan(sourceDemandInvocations.value, 100)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .stale(.publicationReceipt))
        for ticket in selectionTickets.values {
            await assertStale(store.codemapArtifactDemandStatus(ticket))
            let retainCount = await store.codemapArtifactDemandRetainCountForTesting(ticket)
            XCTAssertEqual(retainCount, 0)
        }
        let sourceRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: warmSourceTicket.rootEpoch,
            fileID: source.id
        )
        XCTAssertEqual(sourceRetainCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionSourceDemandLimitAllowsNAndRejectsNPlusOneBeforeFanout() async throws {
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let root = try fixture.makePlainRoot(files: [
            "Sources/First.swift": SwiftFixtureSource.emptyStruct("First"),
            "Sources/Second.swift": SwiftFixtureSource.emptyStruct("Second"),
            "Sources/Third.swift": SwiftFixtureSource.emptyStruct("Third")
        ])
        addTeardownBlock { await fixture.shutdown() }
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled,
            selectionGraphQueryBudgetPolicy: .init(
                maximumRawSourceCount: 2,
                maximumUniqueSourceCount: 2,
                maximumTargetCount: 100,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100
            )
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id).sorted {
            $0.standardizedRelativePath < $1.standardizedRelativePath
        }
        let demandCount = CodemapLockedCounter()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionSourceDemandHook: { _, _ in demandCount.increment() }
        )

        _ = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: Array(files.prefix(2).map(\.id)),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(demandCount.value, 2)

        let rejected = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: files.map(\.id),
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(demandCount.value, 2)
        XCTAssertEqual(rejected.targets, [])
        XCTAssertNil(rejected.publicationReceipt)
        XCTAssertEqual(rejected.aggregateCoverage, .budget(.sourceLimit(attempted: 3, limit: 2)))
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionRequiresReadySourceCoverageInEveryRoot() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let repositoryRoot = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let plainRoot = try fixture.makePlainRoot(files: [
            "Sources/Plain.swift": SwiftFixtureSource.emptyStruct("Plain")
        ])
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore()
        let repository = try await store.loadRoot(path: repositoryRoot.path)
        let plain = try await store.loadRoot(path: plainRoot.path)
        let repositoryFiles = await store.files(inRoot: repository.id)
        let source = try XCTUnwrap(repositoryFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let plainFiles = await store.files(inRoot: plain.id)
        let plainSource = try XCTUnwrap(plainFiles.first)
        let sourceTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: source.id)
        )
        _ = try await readyResult(settledResult(store: store, ticket: sourceTicket))

        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id, plainSource.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertEqual(result.aggregateCoverage, .unavailable(.noReadySources))
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: repository.id)
        await store.unloadRoot(id: plain.id)
    }

    func testAutomaticSelectionCancellationMidSourceFanoutCancelsOnlyIssuedTickets() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let fixture = try CodemapStoreFixture(name: #function, syntheticGraphArtifacts: true)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": SwiftFixtureSource.emptyStruct("First"),
                "Sources/Second.swift": SwiftFixtureSource.emptyStruct("Second")
            ]
        )
        let fanoutGate = CodemapSuspensionGate()
        let readyPublicationGate = CodemapSuspensionGate()
        addTeardownBlock {
            await fanoutGate.release()
            await readyPublicationGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let cancelledTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let store = fixture.makeStore(
            cancellationCleanupHook: { ticket in
                cancelledTickets.append(ticket)
            },
            readyPublicationHook: { _ in
                await readyPublicationGate.enterAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id).sorted {
            $0.standardizedRelativePath < $1.standardizedRelativePath
        }
        XCTAssertEqual(
            files.map(\.standardizedRelativePath),
            ["Sources/First.swift", "Sources/Second.swift"]
        )
        try await AsyncTestWait.waitUntil("automatic selection source identities are cataloged", timeout: 5) {
            await store.codemapAutomaticSelectionSourceIdentities(
                forFileIDs: files.map(\.id),
                rootScope: .visibleWorkspace
            ).count == 2
        }
        let demandCount = CodemapLockedCounter()
        let issuedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionSourceDemandHook: { _, result in
                demandCount.increment()
                if case let .pending(ticket) = result {
                    issuedTickets.append(ticket)
                } else if case let .ready(ready) = result {
                    issuedTickets.append(ready.ticket)
                }
                if demandCount.value == 1 {
                    await fanoutGate.enterAndWait()
                }
            }
        )
        let task = Task {
            try await service.resolveAutomaticCodemapSelection(
                sourceFileIDs: files.map(\.id),
                rootScope: .visibleWorkspace
            )
        }
        let fanoutEntered = await fanoutGate.waitUntilEntered()
        XCTAssertTrue(fanoutEntered)
        let readyPublicationEntered = await readyPublicationGate.waitUntilEntered()
        XCTAssertTrue(readyPublicationEntered)
        let selectionTicket = try XCTUnwrap(issuedTickets.values.first)
        let joinedResult = await store.requestCodemapArtifact(forFileID: files[0].id)
        let joinedTicket: WorkspaceCodemapArtifactDemandTicket
        switch joinedResult {
        case let .pending(ticket):
            joinedTicket = ticket
        case let .ready(ready):
            joinedTicket = ready.ticket
        case let .unavailable(reason):
            return XCTFail("Expected joined demand, got \(reason)")
        }
        XCTAssertNotEqual(selectionTicket.retainID, joinedTicket.retainID)
        let joinedRetainCount = await store.codemapArtifactDemandRetainCountForTesting(selectionTicket)
        XCTAssertEqual(joinedRetainCount, 2)
        task.cancel()
        await fanoutGate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(demandCount.value, 1)
        XCTAssertEqual(issuedTickets.values.count, 1)
        let survivingRetainCount = await store.codemapArtifactDemandRetainCountForTesting(joinedTicket)
        XCTAssertEqual(survivingRetainCount, 1)
        XCTAssertTrue(cancelledTickets.values.isEmpty)
        let survivingStatus = await store.codemapArtifactDemandStatus(joinedTicket)
        guard case .pending = survivingStatus else {
            return XCTFail("Expected the surviving retain to remain pending behind the publication gate")
        }
        await readyPublicationGate.release()
        _ = try await readyResult(settledResult(store: store, ticket: joinedTicket))
        XCTAssertTrue(cancelledTickets.values.isEmpty)

        let released = await store.cancelCodemapArtifactDemand(joinedTicket)
        XCTAssertTrue(released)
        let finalRetainCount = await store.codemapArtifactDemandRetainCountForTesting(joinedTicket)
        XCTAssertEqual(finalRetainCount, 0)
        XCTAssertEqual(cancelledTickets.values, [joinedTicket])
        let releasedStatus = await store.codemapArtifactDemandStatus(joinedTicket)
        guard case .unavailable(.staleCurrentness) = releasedStatus else {
            return XCTFail("Expected the released caller token to become stale")
        }
        await store.unloadRoot(id: loaded.id)
    }
}
