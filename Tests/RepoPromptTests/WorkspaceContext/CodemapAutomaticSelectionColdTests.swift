import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

final class CodemapAutomaticSelectionColdTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testAutomaticSelectionAboveManifestCacheCountPermitsSmallSealedMatch() async throws {
        let manifestAdoptionLimit = 3
        let supportedCandidateCount = manifestAdoptionLimit + 1
        var repositoryFiles = [
            "Sources/Source.swift": "struct Source { let target: Target }\n",
            "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
        ]
        let extraSupportedCandidateCount = supportedCandidateCount - repositoryFiles.count
        for index in 0 ..< extraSupportedCandidateCount {
            repositoryFiles[String(format: "Sources/Enterprise/File%03d.swift", index)] =
                "struct Enterprise\(index) {}\n"
        }
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: repositoryFiles
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true,
            bindingEnginePolicy: smallManifestAdoptionPolicy(recordLimit: manifestAdoptionLimit)
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        let graphPublished = await graphProbe.waitUntilPublished(
            rootEpoch: sourceTicket.rootEpoch,
            minimumNodeCount: 2
        )
        XCTAssertTrue(graphPublished)
        let proof = try await publishCompleteAutomaticSelectionProjection(
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

        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertEqual(proof.catalogCompletion.supportedCandidateCount, UInt64(supportedCandidateCount))
        XCTAssertGreaterThan(
            proof.catalogCompletion.supportedCandidateCount,
            UInt64(manifestAdoptionLimit)
        )
        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        XCTAssertNotNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness() async throws {
        let unsupportedInventoryCount = 8193
        let selectionQueryGate = CodemapArmableSuspensionGate()
        let selectionQueryCount = CodemapLockedCounter()
        let repositoryFiles = [
            "Sources/Source.swift": "struct Source { let target: Target }\n",
            "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
        ]
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        addTeardownBlock {
            repositoryFixture.cleanup()
        }
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: repositoryFiles
        )
        let unsupportedDirectory = root.appendingPathComponent("Assets/Unsupported", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unsupportedDirectory,
            withIntermediateDirectories: true
        )
        let unsupportedSeed = unsupportedDirectory.appendingPathComponent(
            String(format: "File%05d.txt", 0)
        )
        try Self.write("ignored\n", to: unsupportedSeed)
        for index in 1 ..< unsupportedInventoryCount {
            let linkedFile = unsupportedDirectory.appendingPathComponent(
                String(format: "File%05d.txt", index)
            )
            try FileManager.default.linkItem(at: unsupportedSeed, to: linkedFile)
        }
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await selectionQueryGate.release()
            await fixture.shutdown()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            automaticSelectionQueryHook: { _ in
                selectionQueryCount.increment()
                await selectionQueryGate.enterIfArmedAndWait()
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
        let proof = try await publishCompleteAutomaticSelectionProjection(
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
        let selectionQueryCountBeforeSelection = selectionQueryCount.value
        let buildCountBeforeSelection = fixture.buildCount.value

        await selectionQueryGate.arm()
        let selectionTask = Task {
            try await WorkspaceSelectionMutationService(store: store)
                .resolveAutomaticCodemapSelection(
                    sourceFileIDs: [source.id],
                    rootScope: .visibleWorkspace
                )
        }
        let queryEntered = await selectionQueryGate.waitUntilEntered()
        XCTAssertTrue(queryEntered)
        XCTAssertEqual(selectionQueryCount.value - selectionQueryCountBeforeSelection, 1)
        let responsiveInventory = await store.files(inRoot: loaded.id)
        let unsupportedResponsiveInventory = responsiveInventory.filter {
            $0.standardizedRelativePath.hasPrefix("Assets/Unsupported/")
        }
        XCTAssertEqual(proof.catalogCompletion.supportedCandidateCount, 2)
        XCTAssertEqual(responsiveInventory.count, 2 + unsupportedInventoryCount)
        XCTAssertEqual(unsupportedResponsiveInventory.count, unsupportedInventoryCount)
        XCTAssertEqual(
            responsiveInventory.count - Int(proof.catalogCompletion.supportedCandidateCount),
            unsupportedInventoryCount
        )
        await selectionQueryGate.release()
        let result = try await selectionTask.value

        XCTAssertEqual(result.targets.map(\.fileID), [target.id])
        XCTAssertNotNil(result.publicationReceipt)
        XCTAssertGreaterThan(selectionQueryCount.value - selectionQueryCountBeforeSelection, 0)
        XCTAssertEqual(fixture.buildCount.value - buildCountBeforeSelection, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionSealedGraphMatchedTargetBudgetFailsClosed() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var first: FirstTarget { get }; var second: SecondTarget { get } }\n",
                "Sources/First.swift": SwiftFixtureSource.emptyStruct("FirstTarget"),
                "Sources/Second.swift": SwiftFixtureSource.emptyStruct("SecondTarget")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            projectionAuthority: .manual,
            syntheticGraphArtifacts: true
        )
        let graphProbe = CodemapSelectionGraphProbe()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(selectionGraphFactory: graphProbe.factory)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let first = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/First.swift" })
        let second = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Second.swift" })
        var readyByFileID: [UUID: WorkspaceCodemapArtifactDemandReady] = [:]
        for file in [source, first, second] {
            let ticket = try await pendingTicket(store.requestCodemapArtifact(forFileID: file.id))
            readyByFileID[file.id] = try await readyResult(settledResult(store: store, ticket: ticket))
        }
        let sourceReady = try XCTUnwrap(readyByFileID[source.id])
        let firstReady = try XCTUnwrap(readyByFileID[first.id])
        let secondReady = try XCTUnwrap(readyByFileID[second.id])
        _ = await graphProbe.waitUntilPublished(rootEpoch: sourceReady.ticket.rootEpoch, minimumNodeCount: 3)
        _ = try await publishCompleteAutomaticSelectionProjection(
            fixture: fixture,
            graphProbe: graphProbe,
            ticket: sourceReady.ticket,
            contributionsByFileID: [
                source.id: CodeMapSelectionGraphContribution(
                    artifactKey: sourceReady.snapshot.artifactKey,
                    definitions: ["SourceProtocol"],
                    references: ["FirstTarget", "SecondTarget"]
                ),
                first.id: CodeMapSelectionGraphContribution(
                    artifactKey: firstReady.snapshot.artifactKey,
                    definitions: ["FirstTarget"],
                    references: []
                ),
                second.id: CodeMapSelectionGraphContribution(
                    artifactKey: secondReady.snapshot.artifactKey,
                    definitions: ["SecondTarget"],
                    references: []
                )
            ]
        )
        let service = WorkspaceSelectionMutationService(
            store: store,
            automaticSelectionPolicy: .init(maximumCandidateDemandCount: 1)
        )

        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(result.aggregateCoverage, .budget(.candidateDemandLimit(attempted: 2, limit: 1)))
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testAutomaticSelectionSealedGraphResultByteBudgetFailsClosed() async throws {
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
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            selectionGraphFactory: graphProbe.factory,
            selectionGraphQueryBudgetPolicy: .init(
                maximumTargetCount: 100,
                maximumResolutionCount: 100,
                maximumReferenceFailureCount: 100,
                maximumByteCount: 1
            )
        )
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Source.swift" })
        let target = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Target.swift" })
        let sourceTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: source.id))
        let sourceReady = try await readyResult(settledResult(store: store, ticket: sourceTicket))
        let targetTicket = try await pendingTicket(store.requestCodemapArtifact(forFileID: target.id))
        let targetReady = try await readyResult(settledResult(store: store, ticket: targetTicket))
        _ = await graphProbe.waitUntilPublished(rootEpoch: sourceTicket.rootEpoch, minimumNodeCount: 2)
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

        let result = try await WorkspaceSelectionMutationService(store: store)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        guard case let .budget(.byteLimit(attempted, limit)) = result.aggregateCoverage else {
            return XCTFail("Expected fail-closed result-byte budget")
        }
        XCTAssertGreaterThan(attempted, limit)
        XCTAssertEqual(limit, 1)
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        await store.unloadRoot(id: loaded.id)
    }

    func testColdAutomaticSelectionNeverPlansSameNamedDefinitionFromAnotherRoot() async throws {
        let firstRepository = try ReviewGitRepositoryFixture(name: #function + "-first")
        let secondRepository = try ReviewGitRepositoryFixture(name: #function + "-second")
        let firstRootURL = try firstRepository.makeRepository(
            named: "first",
            files: ["Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n"]
        )
        let secondRootURL = try secondRepository.makeRepository(
            named: "second",
            files: ["Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            firstRepository.cleanup()
            secondRepository.cleanup()
        }
        let warmStore = fixture.makeStore()
        var warmRoots: [WorkspaceRootRecord] = []
        for rootURL in [firstRootURL, secondRootURL] {
            let loaded = try await warmStore.loadRoot(path: rootURL.path)
            warmRoots.append(loaded)
            for file in await warmStore.files(inRoot: loaded.id) {
                let ticket = try await pendingTicket(
                    warmStore.requestCodemapArtifact(forFileID: file.id)
                )
                _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
            }
        }
        for root in warmRoots {
            await warmStore.unloadRoot(id: root.id)
        }

        let coldGraphProbe = CodemapSelectionGraphProbe()
        let coldStore = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: coldGraphProbe.factory
        )
        let firstColdRoot = try await coldStore.loadRoot(path: firstRootURL.path)
        let secondColdRoot = try await coldStore.loadRoot(path: secondRootURL.path)
        let firstColdEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: firstColdRoot.id,
            rootLifetimeID: coldStore.rootLifetimeIDForTesting(rootID: firstColdRoot.id)
        )
        let secondColdEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: secondColdRoot.id,
            rootLifetimeID: coldStore.rootLifetimeIDForTesting(rootID: secondColdRoot.id)
        )
        let firstCoverageComplete = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: firstColdEpoch
        )
        let secondCoverageComplete = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: secondColdEpoch
        )
        XCTAssertTrue(firstCoverageComplete)
        XCTAssertTrue(secondCoverageComplete)
        let firstFiles = await coldStore.files(inRoot: firstColdRoot.id)
        let source = try XCTUnwrap(firstFiles.first)
        let result = try await WorkspaceSelectionMutationService(store: coldStore)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertFalse(result.roots.contains { $0.rootEpoch.rootID == secondColdRoot.id })
        await coldStore.unloadRoot(id: firstColdRoot.id)
        await coldStore.unloadRoot(id: secondColdRoot.id)
    }

    func testColdAutomaticSelectionBuildsOnlyMatchedMissingCASTargetAtBackgroundPriority() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target"),
                "Sources/Unrelated.swift": SwiftFixtureSource.emptyStruct("Unrelated")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        let warmFiles = await warmStore.files(inRoot: warmRoot.id)
        var targetKey: CodeMapArtifactKey?
        for file in warmFiles {
            let ticket = try await pendingTicket(
                warmStore.requestCodemapArtifact(forFileID: file.id)
            )
            let ready = try await readyResult(settledResult(store: warmStore, ticket: ticket))
            if file.standardizedRelativePath == "Sources/Target.swift" {
                targetKey = ready.snapshot.artifactKey
            }
        }
        let warmBuildCount = fixture.buildCount.value
        await warmStore.unloadRoot(id: warmRoot.id)
        try FileManager.default.removeItem(at: fixture.artifactURL(for: XCTUnwrap(targetKey)))

        let coldGraphProbe = CodemapSelectionGraphProbe()
        let coldStore = try fixture.makeFreshStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: coldGraphProbe.factory
        )
        let coldRoot = try await coldStore.loadRoot(path: root.path)
        let coldRootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: coldRoot.id,
            rootLifetimeID: coldStore.rootLifetimeIDForTesting(rootID: coldRoot.id)
        )
        let coldCoverageComplete = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: coldRootEpoch
        )
        XCTAssertTrue(coldCoverageComplete)
        let coldGraph = try XCTUnwrap(coldGraphProbe.graph(rootEpoch: coldRootEpoch))
        let initialColdGraphAccounting = await coldGraph.accounting()
        let initialColdGraphKey = try XCTUnwrap(initialColdGraphAccounting.currentObservedKey)
        let coldFiles = await coldStore.files(inRoot: coldRoot.id)
        let source = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let sourceTicket = try await pendingTicket(
            coldStore.requestCodemapArtifact(forFileID: source.id)
        )
        addTeardownBlock {
            _ = await coldStore.cancelCodemapArtifactDemand(sourceTicket)
        }
        _ = try await readyResult(settledResult(store: coldStore, ticket: sourceTicket))
        let sourceGraphClock = ContinuousClock()
        let sourceGraphPublished = await coldStore.waitForCodemapGraphPublication(
            rootEpoch: sourceTicket.rootEpoch,
            deadline: sourceGraphClock.now.advanced(by: .seconds(8))
        )
        XCTAssertTrue(sourceGraphPublished)
        let sourceCoverageKeyValue = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: coldRootEpoch,
            after: initialColdGraphKey.contributionGeneration
        )
        let sourceCoverageKey = try XCTUnwrap(sourceCoverageKeyValue)
        let sourceIdentities = await coldStore.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let planDisposition = await coldStore.planAutomaticCodemapSelectionCandidates(
            sources: sourceIdentities,
            rootScope: .visibleWorkspace
        )
        guard case let .ready(candidatePlan) = planDisposition else {
            XCTFail("Expected ready candidate plan, got \(planDisposition)")
            return
        }
        XCTAssertEqual(
            candidatePlan.candidates.map(\.identity.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        let targetCandidate = try XCTUnwrap(candidatePlan.candidates.first)
        let ownedTargetValue = await coldStore.requestAutomaticCodemapArtifactWithOwnership(
            candidate: targetCandidate,
            rootScope: .visibleWorkspace,
            rootScopeEpochs: candidatePlan.rootScopeEpochs,
            coverageProofs: candidatePlan.coverageProofs
        )
        let ownedTarget = try XCTUnwrap(ownedTargetValue)
        let targetTicket: WorkspaceCodemapArtifactDemandTicket = switch ownedTarget.ownership {
        case let .created(ticket), let .joined(ticket):
            ticket
        case .notAcquired:
            try pendingTicket(ownedTarget.result)
        }
        addTeardownBlock {
            _ = await coldStore.cancelCodemapArtifactDemand(targetTicket)
        }
        _ = try await readyResult(settledResult(store: coldStore, ticket: targetTicket))
        let targetGraphClock = ContinuousClock()
        let targetGraphPublished = await coldStore.waitForCodemapGraphPublication(
            rootEpoch: targetTicket.rootEpoch,
            deadline: targetGraphClock.now.advanced(by: .seconds(8))
        )
        XCTAssertTrue(targetGraphPublished)
        let targetCoverageKey = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: coldRootEpoch,
            after: sourceCoverageKey.contributionGeneration
        )
        XCTAssertNotNil(targetCoverageKey)

        let result = try await WorkspaceSelectionMutationService(store: coldStore)
            .resolveAutomaticCodemapSelection(
                sourceFileIDs: [source.id],
                rootScope: .visibleWorkspace
            )

        XCTAssertEqual(
            result.targets.map(\.logicalPath.standardizedRelativePath),
            ["Sources/Target.swift"]
        )
        XCTAssertEqual(fixture.buildCount.value, warmBuildCount + 1)
        XCTAssertEqual(fixture.buildPriorities.values.last, .background)
        XCTAssertFalse(result.targets.contains {
            $0.logicalPath.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        await coldStore.unloadRoot(id: coldRoot.id)
    }

    func testAutomaticSelectionFinalizationDeadlineFailsClosedWhileCleanupContinues() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        let cleanupGate = CodemapSuspensionGate()
        addTeardownBlock {
            await cleanupGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore()
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        for file in await warmStore.files(inRoot: warmRoot.id) {
            let ticket = try await pendingTicket(warmStore.requestCodemapArtifact(forFileID: file.id))
            _ = try await readyResult(settledResult(store: warmStore, ticket: ticket))
        }
        await warmStore.unloadRoot(id: warmRoot.id)

        let graphProbe = CodemapSelectionGraphProbe()
        let store = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory,
            cancellationCleanupHook: { _ in
                await cleanupGate.enterAndWait()
            }
        )
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let coverageComplete = await graphProbe.waitUntilCompleteCoverage(rootEpoch: rootEpoch)
        XCTAssertTrue(coverageComplete)
        let files = await store.files(inRoot: loaded.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let externalClock = ContinuousClock()
        let externalDeadline = externalClock.now.advanced(by: .seconds(5))
        let externalCompletion = CodemapBoundedCompletionState()
        let resolution = Task {
            defer {
                externalCompletion.recordCompletion(
                    beforeDeadline: externalClock.now < externalDeadline
                )
            }
            return try await WorkspaceSelectionMutationService(store: store)
                .resolveAutomaticCodemapSelection(
                    sourceFileIDs: [source.id],
                    rootScope: .visibleWorkspace
                )
        }

        let cleanupEntered = await cleanupGate.waitUntilEntered()
        XCTAssertTrue(cleanupEntered)
        let completedBeforeDeadline = await waitForCompletionBeforeExternalDeadline(
            externalCompletion,
            clock: externalClock,
            deadline: externalDeadline
        )
        guard completedBeforeDeadline else {
            resolution.cancel()
            await cleanupGate.release()
            let drained = await waitForBoundedCompletionDrain(externalCompletion)
            XCTAssertTrue(drained, "Finalization cleanup did not drain within its external bound")
            return XCTFail("Finalization deadline did not fail closed within the external bound")
        }
        let result = try await resolution.value
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertNil(result.publicationReceipt)
        XCTAssertEqual(result.aggregateCoverage, .stale(.publicationReceipt))
        let sourceRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: rootEpoch,
            fileID: source.id
        )
        XCTAssertEqual(sourceRetainCount, 0)
        let targetRetainCount = await store.codemapArtifactDemandRetainCountForTesting(
            rootEpoch: rootEpoch,
            fileID: target.id
        )
        XCTAssertEqual(targetRetainCount, 0)

        await cleanupGate.release()
        await store.unloadRoot(id: loaded.id)
    }

    func testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "protocol SourceProtocol { var target: Target { get } }\n",
                "Sources/Target.swift": SwiftFixtureSource.emptyStruct("Target"),
                "Sources/Unrelated.swift": SwiftFixtureSource.emptyStruct("Unrelated")
            ]
        )
        let fixture = try CodemapStoreFixture(
            name: #function,
            syntheticGraphArtifacts: true
        )
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }

        let warmStore = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .disabled
        )
        let warmRoot = try await warmStore.loadRoot(path: root.path)
        let warmFiles = await warmStore.files(inRoot: warmRoot.id)
        for file in warmFiles {
            let ticket = try await pendingTicket(
                warmStore.requestCodemapArtifact(forFileID: file.id)
            )
            let warmResult = try await settledResult(store: warmStore, ticket: ticket)
            guard case .ready = warmResult else {
                XCTFail("Expected warm codemap demand for \(file.standardizedRelativePath) to be ready, got \(warmResult)")
                throw CodemapStoreTestError.expectedReady
            }
        }
        let warmBuildCount = fixture.buildCount.value
        await warmStore.unloadRoot(id: warmRoot.id)

        let coldGraphProbe = CodemapSelectionGraphProbe()
        let coldStore = fixture.makeStore(
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: coldGraphProbe.factory
        )
        let coldRoot = try await coldStore.loadRoot(path: root.path)
        let coldRootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: coldRoot.id,
            rootLifetimeID: coldStore.rootLifetimeIDForTesting(rootID: coldRoot.id)
        )
        let coldCoverageComplete = await coldGraphProbe.waitUntilCompleteCoverage(
            rootEpoch: coldRootEpoch
        )
        XCTAssertTrue(coldCoverageComplete)
        let coldFiles = await coldStore.files(inRoot: coldRoot.id)
        let source = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        // This test verifies cold CAS candidate discovery/publication semantics, not the mutation
        // service's default short round-bound transient pending behavior. Under CI load, the
        // background candidate demand may need more than six status checks to become ready.
        let service = WorkspaceSelectionMutationService(
            store: coldStore,
            automaticSelectionPolicy: .init(
                maximumReadinessRounds: 64,
                maximumTotalWait: .seconds(10)
            )
        )
        let result = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let coldResultDiagnostics = """
        aggregateCoverage: \(result.aggregateCoverage)
        roots: \(result.roots)
        sourceIssues: \(result.roots.flatMap(\.sourceIssues))
        targetIssues: \(result.roots.flatMap(\.targetIssues))
        """

        XCTAssertEqual(
            result.targets.map(\.logicalPath.standardizedRelativePath),
            ["Sources/Target.swift"],
            coldResultDiagnostics
        )
        XCTAssertEqual(fixture.buildCount.value, warmBuildCount)
        XCTAssertFalse(result.targets.contains {
            $0.logicalPath.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        let receipt = try XCTUnwrap(result.publicationReceipt, coldResultDiagnostics)
        let actualTarget = try XCTUnwrap(receipt.targets.first)
        let unrelated = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Unrelated.swift"
        })
        let unrelatedLogicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: actualTarget.logicalPath.rootDisplayName,
            standardizedRelativePath: unrelated.standardizedRelativePath
        ))
        let staleExtraTarget = WorkspaceCodemapAutomaticSelectionTarget(
            rootEpoch: actualTarget.rootEpoch,
            fileID: unrelated.id,
            catalogGeneration: actualTarget.catalogGeneration,
            requestGeneration: actualTarget.requestGeneration,
            logicalPath: unrelatedLogicalPath
        )
        let forgedReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: receipt.requestID,
            rootScope: receipt.rootScope,
            rootScopeEpochs: receipt.rootScopeEpochs,
            sourceTickets: receipt.sourceTickets,
            graphKeys: receipt.graphKeys,
            coverageProofs: receipt.coverageProofs,
            targets: receipt.targets + [staleExtraTarget],
            publicationPermit: receipt.publicationPermit
        )
        let forgedResult = WorkspaceCodemapAutomaticSelectionResult(
            roots: result.roots,
            aggregateCoverage: result.aggregateCoverage,
            publicationReceipt: forgedReceipt
        )
        let queryCountBeforeRefresh = await coldGraphProbe.materializedQueryResultCount()
        let rejectedRefresh = await coldStore.refreshAutomaticCodemapSelectionResultForCurrentProjection(
            forgedResult,
            sourceTickets: receipt.sourceTickets,
            rootScope: .visibleWorkspace
        )
        XCTAssertNil(rejectedRefresh)
        let queryCountAfterRefresh = await coldGraphProbe.materializedQueryResultCount()
        XCTAssertGreaterThan(queryCountAfterRefresh, queryCountBeforeRefresh)

        let sourceRetainBeforePublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(receipt.sourceTickets[0])
        XCTAssertEqual(sourceRetainBeforePublication, 1)
        let targetIdentity = try XCTUnwrap(result.targets.first)
        let targetRetainBeforePublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(
                rootEpoch: targetIdentity.rootEpoch,
                fileID: targetIdentity.fileID
            )
        XCTAssertEqual(
            targetRetainBeforePublication,
            0,
            "candidate/provisional ownership must not escape into the publication receipt"
        )
        let publication = await coldStore.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        guard case let .current(targets) = publication else {
            return XCTFail("Expected current publication receipt")
        }
        XCTAssertEqual(targets, result.targets)
        let sourceRetainAfterPublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(receipt.sourceTickets[0])
        XCTAssertEqual(sourceRetainAfterPublication, 0)

        let repeated = try await service.resolveAutomaticCodemapSelection(
            sourceFileIDs: [source.id],
            rootScope: .visibleWorkspace
        )
        let repeatedReceipt = try XCTUnwrap(repeated.publicationReceipt)
        let repeatedRetainBeforePublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(repeatedReceipt.sourceTickets[0])
        XCTAssertEqual(repeatedRetainBeforePublication, 1)
        _ = await coldStore.revalidateAutomaticCodemapSelectionForPublication(
            repeatedReceipt,
            rootScope: .visibleWorkspace
        )
        let repeatedRetainAfterPublication = await coldStore
            .codemapArtifactDemandRetainCountForTesting(repeatedReceipt.sourceTickets[0])
        XCTAssertEqual(
            repeatedRetainAfterPublication,
            0,
            "repeated resolve/revalidate cycles must not grow retainers"
        )

        let target = try XCTUnwrap(coldFiles.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        try Self.write(
            "struct Target { let changed = true }\n",
            to: root.appendingPathComponent(target.standardizedRelativePath)
        )
        await coldStore.replayObservedFileSystemDeltas(
            rootID: coldRoot.id,
            deltas: [.fileModified(target.standardizedRelativePath, nil)]
        )
        var committedAfterWatcherInvalidation = false
        let permitCommit = receipt.publicationPermit.withCurrent {
            committedAfterWatcherInvalidation = true
        }
        XCTAssertNil(permitCommit)
        XCTAssertFalse(committedAfterWatcherInvalidation)
        let watcherStalePublication = await coldStore
            .revalidateAutomaticCodemapSelectionForPublication(
                receipt,
                rootScope: .visibleWorkspace
            )
        XCTAssertEqual(watcherStalePublication, .stale(.publicationReceipt))

        await coldStore.unloadRoot(id: coldRoot.id)
        let stalePublication = await coldStore.revalidateAutomaticCodemapSelectionForPublication(
            receipt,
            rootScope: .visibleWorkspace
        )
        XCTAssertEqual(stalePublication, .stale(.publicationReceipt))
    }
}
