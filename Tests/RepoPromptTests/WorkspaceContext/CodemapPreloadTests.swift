import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapPreloadTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    func testRootLoadSearchAndReadDoNotInvokeCodemapRuntimeProvider() async throws {
        let sandbox = try CodemapStoreFixture.makeSandbox(name: #function)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.write(SwiftFixtureSource.emptyStruct("Feature"), to: root.appendingPathComponent("Sources/Feature.swift"))

        let providerInvocations = CodemapLockedCounter()
        let graphProbe = CodemapSelectionGraphProbe()
        let store = WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerInvocations.increment()
                throw WorkspaceCodemapBindingEngineProviderError.unconfigured
            },
            codemapProjectionPreloadLaunchPolicyForTesting: .enabled,
            selectionGraphFactory: graphProbe.factory
        )

        let loaded = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let search = WorkspaceSearchService()
        _ = await search.rebuildIndex(from: snapshot)
        let searchResult = await search.search("Feature", limit: 10)
        let content = try await store.readContent(
            rootID: loaded.id,
            relativePath: "Sources/Feature.swift"
        )

        XCTAssertEqual(snapshot.files.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(searchResult.results.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(content, SwiftFixtureSource.emptyStruct("Feature"))
        XCTAssertEqual(providerInvocations.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
        XCTAssertEqual(providerInvocations.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
    }

    func testProjectionPreloadStartIsAfterOrdinaryRootInventorySearchAndReadVisibility() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let startGate = CodemapRootSuspensionGate()
        addTeardownBlock {
            await startGate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let store = fixture.makeStore()
        await store.setCodemapProjectionPreloadStartHandlerForTesting { rootEpoch in
            await startGate.enterAndWait(rootEpoch)
        }

        let loaded = try await store.loadRoot(path: root.path)
        let enteredEpoch = await startGate.waitUntilEntered()
        let blockedEpoch = try XCTUnwrap(enteredEpoch)
        let files = await store.files(inRoot: loaded.id)
        let searchSnapshot = await store.searchCatalogSnapshot(rootScope: .allLoaded)
        let contents = try await store.readContent(
            rootID: loaded.id,
            relativePath: "Sources/Feature.swift"
        )

        XCTAssertEqual(blockedEpoch.rootID, loaded.id)
        XCTAssertEqual(files.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(searchSnapshot.files.map(\.standardizedRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(contents, SwiftFixtureSource.emptyStruct("Feature"))
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        let beforeStart = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        XCTAssertEqual(beforeStart.map(\.kind), [
            .rootInventoryAndSearchReady,
            .scheduled
        ])

        await startGate.release()
        let didStart = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .started
        )
        XCTAssertTrue(didStart)
        let afterStart = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let readyOrdinal = try XCTUnwrap(afterStart.first { $0.kind == .rootInventoryAndSearchReady }?.ordinal)
        let scheduledOrdinal = try XCTUnwrap(afterStart.first { $0.kind == .scheduled }?.ordinal)
        let startedOrdinal = try XCTUnwrap(afterStart.first { $0.kind == .started }?.ordinal)
        XCTAssertLessThan(readyOrdinal, scheduledOrdinal)
        XCTAssertLessThan(scheduledOrdinal, startedOrdinal)
        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionPreloadNonGitEligibilityPerformsZeroRuntimeWorkWithoutDemand() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let preflightCount = CodemapLockedCounter()
        let graphProbe = CodemapSelectionGraphProbe()
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            codemapProjectionPreloadLaunchPolicy: .enabled,
            selectionGraphFactory: graphProbe.factory
        )

        let loaded = try await store.loadRoot(path: root.path)
        let didReachTerminalEligibility = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal
        )
        XCTAssertTrue(didReachTerminalEligibility)
        let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: loaded.id)
        let phase = await store.codemapProjectionPreloadLaunchPhaseForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: loaded.id, rootLifetimeID: lifetimeID)
        )
        XCTAssertEqual(phase, .terminalNonGit)
        XCTAssertEqual(preflightCount.value, 1)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)
        XCTAssertEqual(fixture.manifestReadCount.value, 0)
        XCTAssertEqual(fixture.buildCount.value, 0)
        XCTAssertEqual(graphProbe.factoryCount, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testProjectionPreloadAndDemandJoinEligibilityAndSetupSingleflights() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let eligibilityGate = CodemapSuspensionGate()
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock {
            await eligibilityGate.release()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                await eligibilityGate.enterAndWait()
                return .eligible
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let eligibilityEntered = await eligibilityGate.waitUntilEntered()
        XCTAssertTrue(eligibilityEntered)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)

        let demandTask = Task {
            await store.requestCodemapArtifact(forFileID: file.id)
        }
        await eligibilityGate.release()
        let demand = await demandTask.value
        let didHandOff = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .handedOff
        )
        XCTAssertTrue(didHandOff)

        XCTAssertEqual(preflightCount.value, 1)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        let operationCounts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(operationCounts.setupTasksCreated, 1)
        if case let .pending(ticket) = demand {
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }
        await store.unloadRoot(id: loaded.id)
    }

    func testWatcherPathInvalidationSupersedesAndReschedulesProjectionPreload() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let preflightCount = CodemapLockedCounter()
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let didReachInitialTerminalEligibility = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal
        )
        XCTAssertTrue(didReachInitialTerminalEligibility)

        try Self.write(
            "struct Feature { let changed = true }\n",
            to: root.appendingPathComponent("Sources/Feature.swift")
        )
        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.fileModified("Sources/Feature.swift", nil)]
        )
        let didReschedule = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 2
        )
        XCTAssertTrue(didReschedule)
        let didReachRescheduledTerminalEligibility = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal,
            count: 2
        )
        XCTAssertTrue(didReachRescheduledTerminalEligibility)
        let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let superseded = try XCTUnwrap(events.first { $0.kind == .superseded }?.ordinal)
        let schedules = events.filter { $0.kind == .scheduled }
        XCTAssertEqual(schedules.count, 2)
        XCTAssertLessThan(superseded, schedules[1].ordinal)
        XCTAssertEqual(preflightCount.value, 1)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 0)
        XCTAssertEqual(fixture.engineFactoryCount.value, 0)

        let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: loaded.id)
        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: lifetimeID,
            deltas: [],
            requiresFullResync: true
        )
        let didRescheduleAfterGap = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 3
        )
        XCTAssertTrue(didRescheduleAfterGap)
        let didReachTerminalAfterGap = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal,
            count: 3
        )
        XCTAssertTrue(didReachTerminalAfterGap)
        let eventsAfterGap = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let gapSchedule = try XCTUnwrap(eventsAfterGap.last { $0.kind == .scheduled })
        XCTAssertEqual(gapSchedule.trigger, .watcherGap)
        XCTAssertTrue(
            eventsAfterGap
                .filter { $0.ordinal >= gapSchedule.ordinal }
                .allSatisfy { $0.trigger == .watcherGap }
        )
        XCTAssertEqual(preflightCount.value, 2)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadCancelsAndDrainsBlockedProjectionPreloadLaunch() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let startGate = CodemapRootSuspensionGate()
        addTeardownBlock {
            await startGate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let store = fixture.makeStore(codemapProjectionPreloadLaunchPolicy: .enabled)
        await store.setCodemapProjectionPreloadStartHandlerForTesting { rootEpoch in
            await startGate.enterAndWait(rootEpoch)
        }
        let loaded = try await store.loadRoot(path: root.path)
        let enteredRootEpoch = await startGate.waitUntilEntered()
        let rootEpoch = try XCTUnwrap(enteredRootEpoch)

        let unloadTask = Task { await store.unloadRoot(id: loaded.id) }
        let didCancel = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .cancelled
        )
        XCTAssertTrue(didCancel)
        let phase = await store.codemapProjectionPreloadLaunchPhaseForTesting(rootEpoch: rootEpoch)
        let flightCount = await store.codemapEligibilityFlightCountForTesting()
        XCTAssertNil(phase)
        XCTAssertEqual(flightCount, 0)
        await startGate.release()
        await unloadTask.value
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
    }

    func testFirstProjectionPageLazilyPublishesRecordsOnlyShardAfterRootReady() async throws {
        let registrationGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: registrationGate)
        addTeardownBlock {
            await registrationGate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let before = await store.storeWorkDiagnosticsSnapshot()
        XCTAssertEqual(before.rootCatalogShards.publishedShardCount, 0)

        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let registrationEntered = await registrationGate.waitUntilEntered()
        XCTAssertTrue(registrationEntered)
        XCTAssertEqual(ticket.rootEpoch, rootEpoch)

        let page = try await projectionPage(
            fixture.registry.makeBindingCatalogClient()
                .readProjectionCatalogPage(WorkspaceCodemapProjectionCatalogPageRequest(
                    rootEpoch: ticket.rootEpoch,
                    token: nil,
                    cursor: nil,
                    maximumEntryCount: 16,
                    maximumPathByteCount: 4096
                ))
        )
        XCTAssertEqual(page.entries.map(\.identity.fileID), [file.id])
        let after = await store.storeWorkDiagnosticsSnapshot()
        let shard = try XCTUnwrap(after.rootCatalogShards.roots.first { $0.rootID == loaded.id })
        XCTAssertEqual(after.rootCatalogShards.publishedShardCount, 1)
        XCTAssertEqual(shard.pathIndexBuildCount, 0)

        await registrationGate.release()
        await store.unloadRoot(id: loaded.id)
    }

    func testLargeRootFirstProjectionShardBuildRunsOffActor() async throws {
        let registrationGate = CodemapResolutionGate()
        let catalogBuildGate = CodemapRootSuspensionGate()
        let responsivenessGate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: registrationGate)
        addTeardownBlock {
            await responsivenessGate.release()
            await catalogBuildGate.release()
            await registrationGate.release()
            await fixture.shutdown()
        }
        let firstPageEntryLimit = 4
        let fileCountCrossingFirstPage = firstPageEntryLimit + 1
        var sourceFiles: [String: String] = [:]
        sourceFiles.reserveCapacity(fileCountCrossingFirstPage)
        for index in 0 ..< fileCountCrossingFirstPage {
            sourceFiles[String(format: "Sources/File%04d.swift", index)] =
                "struct File\(index) {}\n"
        }
        let root = try fixture.makePlainRoot(files: sourceFiles)
        let store = fixture.makeStore()
        await store.setCodemapProjectionCatalogBuildHandlerForTesting { rootEpoch in
            await catalogBuildGate.enterAndWait(rootEpoch)
        }
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let diagnosticsBeforePage = await store.storeWorkDiagnosticsSnapshot()
        XCTAssertEqual(diagnosticsBeforePage.rootCatalogShards.publishedShardCount, 0)
        let firstFile = await store.file(rootID: loaded.id, relativePath: "Sources/File0000.swift")
        let file = try XCTUnwrap(firstFile)
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let registrationEntered = await registrationGate.waitUntilEntered()
        XCTAssertTrue(registrationEntered)
        XCTAssertEqual(ticket.rootEpoch, rootEpoch)

        let catalog = fixture.registry.makeBindingCatalogClient()
        let pageTask = Task {
            await catalog.readProjectionCatalogPage(WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: ticket.rootEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: firstPageEntryLimit,
                maximumPathByteCount: 4096
            ))
        }
        addTeardownBlock {
            pageTask.cancel()
            await responsivenessGate.release()
            await catalogBuildGate.release()
            await registrationGate.release()
        }
        let enteredCatalogBuildEpoch = await catalogBuildGate.waitUntilEntered(timeout: .seconds(10))
        guard enteredCatalogBuildEpoch == rootEpoch else {
            pageTask.cancel()
            await catalogBuildGate.release()
            XCTFail("Expected catalog shard build gate to enter \(rootEpoch), got \(String(describing: enteredCatalogBuildEpoch))")
            return
        }

        let responsivenessTask = Task {
            let roots = await store.roots()
            let availability = await store.rootScopeAvailability(.allLoaded)
            let content = try await store.readContent(
                rootID: loaded.id,
                relativePath: file.standardizedRelativePath
            )
            await responsivenessGate.enterAndWait()
            return (roots, availability, content)
        }
        let actorRemainedResponsive = await responsivenessGate.waitUntilEntered()
        await responsivenessGate.release()
        await catalogBuildGate.release()
        XCTAssertTrue(actorRemainedResponsive)
        let responsiveness = try await responsivenessTask.value
        XCTAssertEqual(responsiveness.0.map(\.id), [loaded.id])
        XCTAssertEqual(responsiveness.1, .available)
        XCTAssertEqual(responsiveness.2, sourceFiles[file.standardizedRelativePath])

        let page = try await projectionPage(pageTask.value)
        XCTAssertEqual(page.entries.count, firstPageEntryLimit)
        XCTAssertEqual(page.entries.first?.identity.standardizedRelativePath, "Sources/File0000.swift")
        let diagnostics = await store.storeWorkDiagnosticsSnapshot()
        let shard = try XCTUnwrap(diagnostics.rootCatalogShards.roots.first { $0.rootID == loaded.id })
        XCTAssertEqual(shard.pathIndexBuildCount, 0)

        await registrationGate.release()
        await store.unloadRoot(id: loaded.id)
    }

    func testTransientEligibilityUsesOneAuthorityCheckedBackoffRetry() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let clock = CodemapRetryTestClock(nowNanoseconds: 1000)
        let sleepGate = CodemapRetrySleepGate()
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock {
            await sleepGate.releaseAll()
            await fixture.shutdown()
        }
        let policy = WorkspaceFileContextStore.CodemapProjectionPreloadRetryPolicy(
            maximumRetryCount: 2,
            initialBackoffNanoseconds: 100,
            maximumBackoffNanoseconds: 400,
            nowNanoseconds: { clock.nowNanoseconds },
            sleep: { delay in try await sleepGate.sleep(delay) }
        )
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return preflightCount.value == 1
                    ? .transientUnavailable(.repositoryChanging)
                    : .terminalUnavailable(.nonGit)
            },
            codemapProjectionPreloadRetryPolicy: policy,
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let observedDelay = await sleepGate.waitForFirstDelay()
        let delay = try XCTUnwrap(observedDelay)
        XCTAssertEqual(delay, 100)
        let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: loaded.id)
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: loaded.id, rootLifetimeID: lifetimeID)
        let retry = await store.codemapProjectionPreloadRetrySnapshotForTesting(rootEpoch: rootEpoch)
        XCTAssertEqual(retry?.attempt, 1)
        XCTAssertEqual(retry?.deadlineNanoseconds, 1100)
        XCTAssertEqual(preflightCount.value, 1)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let demandDuringBackoff = await store.requestCodemapArtifact(forFileID: file.id)
        guard case .unavailable(.busy) = demandDuringBackoff else {
            return XCTFail("Expected demand to respect the root retry backoff")
        }
        XCTAssertEqual(preflightCount.value, 1)

        clock.advance(by: 100)
        await sleepGate.releaseAll()
        let didRetry = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .retryStarted
        )
        let didTerminate = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal
        )
        XCTAssertTrue(didRetry)
        XCTAssertTrue(didTerminate)
        XCTAssertEqual(preflightCount.value, 2)
        let delays = await sleepGate.delays
        XCTAssertEqual(delays, [100])
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testUnloadCancelsBlockedPreloadRetrySleepWithoutManualRelease() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let clock = CodemapRetryTestClock(nowNanoseconds: 10000)
        let sleepGate = CodemapRetrySleepGate()
        addTeardownBlock {
            await sleepGate.releaseAll()
            await fixture.shutdown()
        }
        let policy = WorkspaceFileContextStore.CodemapProjectionPreloadRetryPolicy(
            maximumRetryCount: 1,
            initialBackoffNanoseconds: 1000,
            maximumBackoffNanoseconds: 1000,
            nowNanoseconds: { clock.nowNanoseconds },
            sleep: { delay in try await sleepGate.sleep(delay) }
        )
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                .transientUnavailable(.repositoryChanging)
            },
            codemapProjectionPreloadRetryPolicy: policy,
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let observedDelay = await sleepGate.waitForFirstDelay()
        XCTAssertEqual(observedDelay, 1000)

        await store.unloadRoot(id: loaded.id)

        let roots = await store.roots()
        let delays = await sleepGate.delays
        XCTAssertTrue(roots.isEmpty)
        XCTAssertEqual(delays, [1000])
    }

    func testTransientSetupUsesOneBackoffThenFreshSetupRegistration() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let clock = CodemapRetryTestClock(nowNanoseconds: 5000)
        let sleepGate = CodemapRetrySleepGate()
        let runtimeCalls = CodemapLockedCounter()
        addTeardownBlock {
            await sleepGate.releaseAll()
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let policy = WorkspaceFileContextStore.CodemapProjectionPreloadRetryPolicy(
            maximumRetryCount: 2,
            initialBackoffNanoseconds: 250,
            maximumBackoffNanoseconds: 500,
            nowNanoseconds: { clock.nowNanoseconds },
            sleep: { delay in try await sleepGate.sleep(delay) }
        )
        let store = WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                if runtimeCalls.incrementAndGet() == 1 {
                    throw WorkspaceCodemapBindingEngineProviderError.unconfigured
                }
                return try fixture.runtime()
            },
            codemapLocalGitClassificationProbe: .init { _ in .requiresGitPreflight },
            codemapGitEligibilityProbe: .init { _ in .eligible },
            codemapProjectionPreloadRetryPolicy: policy,
            codemapProjectionPreloadLaunchPolicyForTesting: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let observedDelay = await sleepGate.waitForFirstDelay()
        let delay = try XCTUnwrap(observedDelay)
        XCTAssertEqual(delay, 250)
        XCTAssertEqual(runtimeCalls.value, 1)

        clock.advance(by: 250)
        await sleepGate.releaseAll()
        let didHandOff = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .handedOff
        )
        XCTAssertTrue(didHandOff)
        XCTAssertEqual(runtimeCalls.value, 2)
        let delays = await sleepGate.delays
        XCTAssertEqual(delays, [250])
        let counts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(counts.setupTasksCreated, 2)
        await store.unloadRoot(id: loaded.id)
    }

    func testExplicitMaterializationAndRepositoryAuthorityChangeRescheduleCurrentPreload() async throws {
        let fixture = try CodemapStoreFixture(name: #function)
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock { await fixture.shutdown() }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .terminalUnavailable(.nonGit)
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let didReachInitialTerminal = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .eligibilityTerminal
        )
        XCTAssertTrue(didReachInitialTerminal)

        do {
            try await store.moveFile(
                rootID: loaded.id,
                from: "Sources/Missing.swift",
                to: "Sources/StillMissing.swift"
            )
            XCTFail("Expected missing move to fail")
        } catch {
            // The authority fence cancelled old work, so failure restores exactly one preload.
        }
        let restoredAfterFailedMove = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 2
        )
        XCTAssertTrue(restoredAfterFailedMove)

        let external = root.appendingPathComponent("Sources/External.swift")
        try Self.write(SwiftFixtureSource.emptyStruct("External"), to: external)
        let materialized = try await store.materializeExplicitlyRequestedFile(
            external.path,
            rootScope: .allLoaded
        )
        guard case .materialized = materialized else {
            return XCTFail("Expected explicit materialization")
        }
        let materializationRescheduled = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 3
        )
        XCTAssertTrue(materializationRescheduled)

        _ = try await store.createFile(
            rootID: loaded.id,
            relativePath: "Sources/Created.swift",
            content: SwiftFixtureSource.emptyStruct("Created")
        )
        let createRescheduled = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 4
        )
        XCTAssertTrue(createRescheduled)

        await store.replayObservedFileSystemDeltas(
            rootID: loaded.id,
            deltas: [.folderModified(".git")]
        )
        let repositoryDetached = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .repositoryAuthorityDetached
        )
        let repositoryRescheduled = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .scheduled,
            count: 5
        )
        XCTAssertTrue(repositoryDetached)
        XCTAssertTrue(repositoryRescheduled)
        let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let detachedOrdinal = try XCTUnwrap(events.last { $0.kind == .repositoryAuthorityDetached }?.ordinal)
        let lastScheduledOrdinal = try XCTUnwrap(events.last { $0.kind == .scheduled }?.ordinal)
        XCTAssertLessThan(detachedOrdinal, lastScheduledOrdinal)
        XCTAssertEqual(fixture.providerAccessCount.value, 0)
        await store.unloadRoot(id: loaded.id)
    }

    func testRepositoryLayoutChangeDetachesEngineSessionThenRegistersCurrentAuthority() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .eligible
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let initialHandOff = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .handedOff
        )
        XCTAssertTrue(initialHandOff)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/Feature.swift" })
        let ticket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: loaded.id)

        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: lifetimeID,
            deltas: [.folderModified(".git")]
        )
        let didDetach = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .repositoryAuthorityDetached
        )
        let didRegisterCurrentAuthority = await waitForCodemapPreloadEventCount(
            store: store,
            rootID: loaded.id,
            kind: .handedOff,
            count: 2
        )
        XCTAssertTrue(didDetach)
        XCTAssertTrue(didRegisterCurrentAuthority)
        await assertStale(store.codemapArtifactDemandStatus(ticket))
        let counts = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(counts.setupTasksCreated, 2)
        XCTAssertEqual(preflightCount.value, 2)
        XCTAssertEqual(fixture.providerAccessCount.value, 2)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testStaleLifetimeRepositoryDeltaDoesNotAcquireFenceOrDetachCurrentAuthority() async throws {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositoryFixture.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let preflightCount = CodemapLockedCounter()
        addTeardownBlock {
            await fixture.shutdown()
            repositoryFixture.cleanup()
        }
        let store = fixture.makeStore(
            codemapGitEligibilityProbe: .init { _ in
                preflightCount.increment()
                return .eligible
            },
            codemapProjectionPreloadLaunchPolicy: .enabled
        )
        let loaded = try await store.loadRoot(path: root.path)
        let didHandOff = await waitForCodemapPreloadEvent(
            store: store,
            rootID: loaded.id,
            kind: .handedOff
        )
        XCTAssertTrue(didHandOff)
        let eventsBefore = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let countsBefore = await store.codemapPresentationOperationCountsForTesting()

        await store.replayPublisherFileSystemPublicationForTesting(
            rootID: loaded.id,
            expectedLifetimeID: UUID(),
            deltas: [.folderModified(".git")]
        )

        let eventsAfter = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: loaded.id)
        let countsAfter = await store.codemapPresentationOperationCountsForTesting()
        XCTAssertEqual(eventsAfter, eventsBefore)
        XCTAssertEqual(countsAfter.setupTasksCreated, countsBefore.setupTasksCreated)
        XCTAssertEqual(preflightCount.value, 1)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        await store.unloadRoot(id: loaded.id)
    }

    func testFirstExplicitDemandReturnsStableExactRootPendingTicketAndRegistersOnce() async throws {
        let gate = CodemapResolutionGate()
        let fixture = try CodemapStoreFixture(name: #function, resolutionGate: gate)
        addTeardownBlock {
            await gate.release()
            await fixture.shutdown()
        }
        let root = try fixture.makePlainRoot(files: [
            "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")
        ])
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let loadedFiles = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(loadedFiles.first)

        let firstTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        let duplicateTicket = try await pendingTicket(
            store.requestCodemapArtifact(forFileID: file.id)
        )
        XCTAssertNotEqual(firstTicket.retainID, duplicateTicket.retainID)
        XCTAssertEqual(firstTicket.requestID, duplicateTicket.requestID)
        XCTAssertEqual(firstTicket.rootEpoch, duplicateTicket.rootEpoch)
        XCTAssertEqual(firstTicket.fileID, duplicateTicket.fileID)
        XCTAssertEqual(firstTicket.requestGeneration, duplicateTicket.requestGeneration)
        let gateEntered = await gate.waitUntilEntered()
        XCTAssertTrue(gateEntered)

        let candidate = await fixture.registry.makeBindingCatalogClient()
            .resolveManifestBinding(firstTicket.rootEpoch, file.standardizedRelativePath)
        XCTAssertEqual(candidate?.identity.fileID, file.id)
        XCTAssertEqual(candidate?.identity.rootID, loaded.id)
        XCTAssertEqual(candidate?.identity.rootLifetimeID, firstTicket.rootEpoch.rootLifetimeID)
        XCTAssertEqual(fixture.providerAccessCount.value, 1)
        XCTAssertEqual(fixture.runtimeFactoryCount.value, 1)
        XCTAssertEqual(fixture.engineFactoryCount.value, 1)
        let resolutionCount = await gate.resolutionCount
        XCTAssertEqual(resolutionCount, 1)

        await gate.release()
        let settled = try await settledResult(store: store, ticket: firstTicket)
        assertNonGitTerminal(settled)
        await store.unloadRoot(id: loaded.id)
    }
}
