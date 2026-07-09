import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodemapBindingEngineManifestWriteTests: CodemapBindingEngineTestCase {
    func testShutdownWaitsForBlockedManifestWriterAndDrainsEngineWork() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Shutdown.swift": SwiftFixtureSource.emptyStruct("Shutdown")]
        )
        let writeGate = EngineBlockingGate()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
                manifestStoreHooks: CodeMapRootManifestStoreHooks(
                    afterWriteShardAdmission: { writeGate.enterAndWait() }
                )
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let demand = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Shutdown.swift"))
        }
        let writeEntered = await writeGate.waitUntilEntered()
        XCTAssertTrue(writeEntered)
        let shutdownFinished = EngineCompletionFlag()
        let shutdown = Task {
            await fixture.engine.shutdown()
            shutdownFinished.finish()
        }
        XCTAssertFalse(shutdownFinished.waitUntilFinished(timeout: 0.1))

        writeGate.release()
        await shutdown.value
        guard case .cancelled = await demand.value else {
            return XCTFail("Expected shutdown to cancel manifest-producing demand.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.rootCount, 0)
        XCTAssertEqual(accounting.activeRequestCount, 0)
        XCTAssertEqual(accounting.queuedRequestCount, 0)
        await fixture.engine.shutdown()
    }

    func testSerializedManifestWriterPersistsNewestRecordSetWhenSecondCompletionArrivesFirst() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": SwiftFixtureSource.emptyStruct("One"),
                "Sources/Two.swift": SwiftFixtureSource.emptyStruct("Two")
            ]
        )
        let writeGate = EngineBlockingGate()
        let hookEvents = EngineHookEvents()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterWriteShardAdmission: { writeGate.enterAndWait() }
            )
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let first = Task { await fixture.engine.demand(fixture.demand(path: "Sources/One.swift")) }
        let writeEntered = await writeGate.waitUntilEntered()
        XCTAssertTrue(writeEntered)
        let second = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Two.swift")) }
        XCTAssertTrue(hookEvents.wait(kind: .manifestRevisionQueued, numericValue: 2))
        writeGate.release()
        guard case .ready = await first.value else { return XCTFail("Expected first ready.") }
        guard case .ready = await second.value else { return XCTFail("Expected second ready.") }
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)

        let reloaded = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered(adoptedReadyCount: 0) = await reloaded.engine.registerRoot(reloaded.registration) else {
            return XCTFail("Expected lazy reloaded registration.")
        }
        guard await isReady(reloaded.engine.demand(
            reloaded.demand(path: "Sources/One.swift")
        )) else {
            return XCTFail("Expected latest two-record manifest snapshot on demand.")
        }
    }

    func testSameNamespaceWriterDrainsUnloadedPredecessorBeforeSuccessor() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": SwiftFixtureSource.emptyStruct("First"),
                "Sources/Second.swift": SwiftFixtureSource.emptyStruct("Second")
            ]
        )
        let writerGate = EngineAsyncGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let service = capabilityService()
        let hookEvents = EngineHookEvents()
        let firstEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let secondEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let firstFileIDs = EngineFileIDs()
        let secondFileIDs = EngineFileIDs()
        let fileSystem = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let catalog = WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
            let fileIDs = epoch == firstEpoch ? firstFileIDs : secondFileIDs
            guard epoch == firstEpoch || epoch == secondEpoch,
                  let identity = WorkspaceCodemapArtifactBindingIdentity(
                      rootID: epoch.rootID,
                      rootLifetimeID: epoch.rootLifetimeID,
                      fileID: fileIDs.id(for: relativePath),
                      standardizedRootPath: root.path,
                      standardizedRelativePath: relativePath,
                      standardizedFullPath: root.appendingPathComponent(relativePath).path
                  )
            else { return nil }
            return WorkspaceCodemapManifestBindingCandidate(
                identity: identity,
                requestGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }
        let reader = WorkspaceCodemapValidatedSourceReaderClient { identity, expected, maximumBytes, ownerID in
            try await fileSystem.loadValidatedRawContent(
                ofRelativePath: identity.standardizedRelativePath,
                expectedFingerprint: FileContentFingerprint(
                    deviceID: expected.device,
                    fileNumber: expected.inode,
                    byteSize: expected.size,
                    modificationSeconds: expected.modificationSeconds,
                    modificationNanoseconds: expected.modificationNanoseconds,
                    statusChangeSeconds: expected.changeSeconds,
                    statusChangeNanoseconds: expected.changeNanoseconds
                ),
                maximumBytes: maximumBytes,
                workloadClass: .codemap,
                schedulerOwnerID: ownerID
            )
        }
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: service,
            sourceReader: reader,
            catalogClient: catalog,
            hooks: WorkspaceCodemapBindingEngineHooks(
                event: { hookEvents.record($0) },
                afterManifestStoreWriteBeforeCompletion: { rootEpoch in
                    guard rootEpoch == firstEpoch else { return }
                    await writerGate.enterAndWait()
                }
            ),
            accessEpochSeconds: { 42 }
        )
        addTeardownBlock { await engine.shutdown() }
        let firstRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: firstEpoch.rootID,
            rootLifetimeID: firstEpoch.rootLifetimeID,
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        let secondRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: secondEpoch.rootID,
            rootLifetimeID: secondEpoch.rootLifetimeID,
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        func demand(
            epoch: WorkspaceCodemapRootEpoch,
            fileIDs: EngineFileIDs,
            path: String
        ) -> WorkspaceCodemapBindingDemand {
            WorkspaceCodemapBindingDemand(
                owner: .init(),
                identity: WorkspaceCodemapArtifactBindingIdentity(
                    rootID: epoch.rootID,
                    rootLifetimeID: epoch.rootLifetimeID,
                    fileID: fileIDs.id(for: path),
                    standardizedRootPath: root.path,
                    standardizedRelativePath: path,
                    standardizedFullPath: root.appendingPathComponent(path).path
                )!,
                requestGeneration: 1,
                catalogGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1,
                priority: .demand,
                language: .swift
            )
        }

        _ = await engine.registerRoot(firstRegistration)
        _ = await engine.registerRoot(secondRegistration)
        let first = Task {
            await engine.demand(demand(
                epoch: firstEpoch,
                fileIDs: firstFileIDs,
                path: "Sources/First.swift"
            ))
        }
        let writerEntered = await writerGate.waitUntilEntered()
        XCTAssertTrue(writerEntered)
        defer { writerGate.release() }
        await engine.unloadRoot(rootEpoch: firstEpoch)
        guard case .cancelled = await first.value else {
            return XCTFail("Expected unloaded predecessor demand to cancel.")
        }
        let secondFinished = EngineCompletionFlag()
        let second = Task {
            let result = await engine.demand(demand(
                epoch: secondEpoch,
                fileIDs: secondFileIDs,
                path: "Sources/Second.swift"
            ))
            secondFinished.finish()
            return result
        }
        XCTAssertTrue(hookEvents.wait(
            kind: .manifestRevisionQueued,
            rootEpoch: secondEpoch,
            numericValue: 1
        ))
        XCTAssertFalse(secondFinished.waitUntilFinished(timeout: 0))
        let overlapEvents = hookEvents.snapshot()
        let firstQueuedIndex = try XCTUnwrap(overlapEvents.firstIndex {
            $0.kind == .manifestRevisionQueued && $0.rootEpoch == firstEpoch
        })
        let unloadIndex = try XCTUnwrap(overlapEvents.firstIndex {
            $0.kind == .rootUnload && $0.rootEpoch == firstEpoch
        })
        let secondQueuedIndex = try XCTUnwrap(overlapEvents.firstIndex {
            $0.kind == .manifestRevisionQueued && $0.rootEpoch == secondEpoch
        })
        XCTAssertLessThan(firstQueuedIndex, unloadIndex)
        XCTAssertLessThan(unloadIndex, secondQueuedIndex)
        writerGate.release()

        guard case .ready = await second.value else {
            return XCTFail("Expected same-namespace successor demand to complete.")
        }
        let state = await service.state(for: secondEpoch)
        let capability = try eligible(state)
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let namespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: pipeline
        )
        let authority = try CodeMapRootManifestAuthority(
            namespace: namespace,
            token: capability.repositoryAuthority
        )
        guard case let .hit(snapshot) = try await runtime.manifestStore.loadCurrentManifest(
            namespace: namespace,
            currentAuthority: authority
        ) else {
            return XCTFail("Expected same-namespace manifest.")
        }
        XCTAssertEqual(
            Set(snapshot.records.map(\.repositoryRelativePath)),
            ["Sources/First.swift", "Sources/Second.swift"]
        )
    }

    func testPathInvalidationDuringManifestWriteDrainsNewestRevision() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
        )
        let writeGate = EngineBlockingGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterWriteShardAdmission: { writeGate.enterAndWait() }
            )
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        let demand = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Feature.swift"))
        }
        let writeEntered = await writeGate.waitUntilEntered()
        XCTAssertTrue(writeEntered)
        let invalidation = Task {
            await fixture.engine.invalidateModified(
                rootEpoch: fixture.rootEpoch,
                standardizedRelativePaths: ["Sources/Feature.swift"]
            )
        }

        writeGate.release()
        let invalidationResult = await invalidation.value
        XCTAssertFalse(invalidationResult.manifestWriteFailed)
        guard case .cancelled = await demand.value else {
            return XCTFail("Expected the invalidated manifest-producing demand to cancel.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.dirtyManifestCount, 0)
    }

    func testQueuedAndLastOwnerCancellationDrainReservationsAndFairnessHistoryAfterOrdinalRebase() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": SwiftFixtureSource.emptyStruct("First"),
                "Sources/Second.swift": SwiftFixtureSource.emptyStruct("Second")
            ]
        )
        let gate = EngineBuildGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let policy = WorkspaceCodemapBindingEnginePolicy(
            maximumActiveRequestCountPerRoot: 1,
            maximumActiveRequestCount: 1,
            maximumActiveRequestCountPerOwner: 1,
            maximumQueuedRequestCountPerRoot: 1,
            maximumQueuedRequestCountPerOwner: 1,
            maximumQueuedRequestCount: 1,
            maximumActiveTaskCountPerRoot: 1,
            maximumActiveTaskCountPerOwner: 1,
            maximumActiveTaskCount: 1,
            maximumValidatedWorktreeByteCount: 64,
            maximumRetainedSourceByteCountPerRoot: 64,
            maximumRetainedSourceByteCount: 64
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: policy,
            initialQueueOrdinal: .max,
            initialAdmissionOrdinal: .max,
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await gate.enter()
                try Task.checkCancellation()
                throw FileSystemError.failedToReadFile
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write("struct First { let dirty = true }\n", to: "Sources/First.swift", at: root)
        try repository.write("struct Second { let dirty = true }\n", to: "Sources/Second.swift", at: root)
        let firstOwner = WorkspaceCodemapLiveDemandOwner()
        let secondOwner = WorkspaceCodemapLiveDemandOwner()
        let first = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/First.swift", owner: firstOwner))
        }
        _ = await gate.waitUntilEntered()
        let second = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Second.swift", owner: secondOwner))
        }
        while await fixture.engine.accounting().queuedRequestCount == 0 {
            await Task.yield()
        }
        let peak = await fixture.engine.accounting()
        XCTAssertEqual(peak.activeRequestCount, 1)
        XCTAssertEqual(peak.queuedRequestCount, 1)
        XCTAssertEqual(peak.reservedSourceByteCount, 64)
        XCTAssertEqual(peak.ownerCount, 2)
        XCTAssertEqual(peak.rootAdmissionHistoryCount, 1)
        XCTAssertEqual(peak.ownerAdmissionHistoryCount, 1)

        let queuedCancellationCount = await fixture.engine.cancel(owner: secondOwner)
        let activeCancellationCount = await fixture.engine.cancel(owner: firstOwner)
        let duplicateQueuedCancellationCount = await fixture.engine.cancel(owner: secondOwner)
        let duplicateActiveCancellationCount = await fixture.engine.cancel(owner: firstOwner)
        XCTAssertEqual(queuedCancellationCount, 1)
        XCTAssertEqual(activeCancellationCount, 1)
        XCTAssertEqual(duplicateQueuedCancellationCount, 0)
        XCTAssertEqual(duplicateActiveCancellationCount, 0)
        await gate.release()
        guard case .cancelled = await first.value else { return XCTFail("Expected active cancellation.") }
        guard case .cancelled = await second.value else { return XCTFail("Expected queued cancellation.") }
        while await fixture.engine.accounting().activeRequestCount != 0 {
            await Task.yield()
        }
        let drained = await fixture.engine.accounting()
        XCTAssertEqual(drained.activeRequestCount, 0)
        XCTAssertEqual(drained.queuedRequestCount, 0)
        XCTAssertEqual(drained.reservedSourceByteCount, 0)
        XCTAssertEqual(drained.ownerCount, 0)
        XCTAssertEqual(drained.rootAdmissionHistoryCount, 0)
        XCTAssertEqual(drained.ownerAdmissionHistoryCount, 0)
        XCTAssertEqual(drained.counters.cancellations, 2)
    }
}
