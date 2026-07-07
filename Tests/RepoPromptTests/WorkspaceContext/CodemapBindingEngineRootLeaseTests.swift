import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodemapBindingEngineRootLeaseTests: CodemapBindingEngineTestCase {
    func testSequentialRootsRetainGlobalAdoptionLeaseBudgetUntilUnloadThenRecover() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let firstRoot = try repository.makeRepository(
            named: "first",
            files: ["Sources/A.swift": SwiftFixtureSource.emptyStruct("A")]
        )
        let secondRoot = try repository.makeRepository(
            named: "second",
            files: ["Sources/B.swift": SwiftFixtureSource.emptyStruct("B")]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        for (root, path) in [(firstRoot, "Sources/A.swift"), (secondRoot, "Sources/B.swift")] {
            let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
            _ = await seed.engine.registerRoot(seed.registration)
            guard case .ready = await seed.engine.demand(seed.demand(path: path)) else {
                return XCTFail("Expected manifest seed for \(path).")
            }
            await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)
        }

        let firstEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let secondEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let firstFileIDs = EngineFileIDs()
        let secondFileIDs = EngineFileIDs()
        let catalog = WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
            let root: URL
            let fileIDs: EngineFileIDs
            if epoch == firstEpoch {
                root = firstRoot
                fileIDs = firstFileIDs
            } else if epoch == secondEpoch {
                root = secondRoot
                fileIDs = secondFileIDs
            } else {
                return nil
            }
            guard let identity = WorkspaceCodemapArtifactBindingIdentity(
                rootID: epoch.rootID,
                rootLifetimeID: epoch.rootLifetimeID,
                fileID: fileIDs.id(for: relativePath),
                standardizedRootPath: root.path,
                standardizedRelativePath: relativePath,
                standardizedFullPath: root.appendingPathComponent(relativePath).path
            ) else { return nil }
            return WorkspaceCodemapManifestBindingCandidate(
                identity: identity,
                requestGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }
        let runtime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let service = capabilityService()
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: service,
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                throw FileSystemError.failedToReadFile
            },
            catalogClient: catalog,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumRootCount: 2,
                maximumManifestAdoptionLeaseCountPerRoot: 1,
                maximumManifestAdoptionLeaseCount: 1,
                maximumManifestAdoptionLeaseByteCountPerRoot: .max,
                maximumManifestAdoptionLeaseByteCount: .max
            )
        )
        addTeardownBlock { await engine.shutdown() }
        func demand(
            epoch: WorkspaceCodemapRootEpoch,
            root: URL,
            fileIDs: EngineFileIDs,
            path: String
        ) -> WorkspaceCodemapBindingDemand {
            let identity = WorkspaceCodemapArtifactBindingIdentity(
                rootID: epoch.rootID,
                rootLifetimeID: epoch.rootLifetimeID,
                fileID: fileIDs.id(for: path),
                standardizedRootPath: root.path,
                standardizedRelativePath: path,
                standardizedFullPath: root.appendingPathComponent(path).path
            )!
            return WorkspaceCodemapBindingDemand(
                owner: .init(),
                identity: identity,
                requestGeneration: 1,
                catalogGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1,
                priority: .background,
                language: .swift
            )
        }
        let firstRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: firstEpoch.rootID,
            rootLifetimeID: firstEpoch.rootLifetimeID,
            loadedRootURL: firstRoot,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        let secondRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: secondEpoch.rootID,
            rootLifetimeID: secondEpoch.rootLifetimeID,
            loadedRootURL: secondRoot,
            catalogGeneration: 1,
            ingressGeneration: 1
        )

        guard case .registered(adoptedReadyCount: 0) = await engine.registerRoot(firstRegistration) else {
            return XCTFail("Expected lazy first registration.")
        }
        guard await isReady(engine.demand(demand(
            epoch: firstEpoch,
            root: firstRoot,
            fileIDs: firstFileIDs,
            path: "Sources/A.swift"
        ))) else {
            return XCTFail("Expected first retained adoption on demand.")
        }
        let firstAccounting = await engine.accounting()
        XCTAssertEqual(firstAccounting.manifestAdoptionLeaseCount, 1)
        XCTAssertGreaterThan(firstAccounting.manifestAdoptionLeaseByteCount, 0)

        guard case .registered(adoptedReadyCount: 0) = await engine.registerRoot(secondRegistration) else {
            return XCTFail("Expected second root to respect the retained global lease bound.")
        }
        _ = await engine.demand(demand(
            epoch: secondEpoch,
            root: secondRoot,
            fileIDs: secondFileIDs,
            path: "Sources/Missing.swift"
        ))
        let boundedAccounting = await engine.accounting()
        XCTAssertEqual(boundedAccounting.manifestAdoptionLeaseCount, 1)
        XCTAssertEqual(
            boundedAccounting.manifestAdoptionLeaseByteCount,
            firstAccounting.manifestAdoptionLeaseByteCount
        )

        await engine.unloadRoot(rootEpoch: firstEpoch)
        let releasedAccounting = await engine.accounting()
        XCTAssertEqual(releasedAccounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(releasedAccounting.manifestAdoptionLeaseByteCount, 0)

        guard await isReady(engine.demand(demand(
            epoch: secondEpoch,
            root: secondRoot,
            fileIDs: secondFileIDs,
            path: "Sources/B.swift"
        ))) else {
            return XCTFail("Expected same-session adoption retry after lease pressure cleared.")
        }
        let recoveredAccounting = await engine.accounting()
        XCTAssertEqual(recoveredAccounting.manifestAdoptionLeaseCount, 1)
        XCTAssertEqual(recoveredAccounting.counters.manifestAdoptions, 2)
    }

    func testUnloadDuringBlockedManifestRegistrationFailsAndReleasesRootAndLeaseState() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Unload.swift": SwiftFixtureSource.emptyStruct("Unload")]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Unload.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let loadGate = EngineBuildGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { await loadGate.enter() }
            )
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected lazy registration.")
        }
        let demand = Task {
            await fixture.engine.demand(fixture.demand(
                path: "Sources/Unload.swift",
                priority: .background
            ))
        }
        _ = await loadGate.waitUntilEntered()
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)

        guard case .cancelled = await demand.value else {
            return XCTFail("Expected unload to cancel blocked manifest adoption demand.")
        }
        while await fixture.engine.accounting().activeRequestCount != 0 {
            await Task.yield()
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.rootCount, 0)
        XCTAssertEqual(accounting.activeRequestCount, 0)
        XCTAssertEqual(accounting.queuedRequestCount, 0)
        XCTAssertEqual(accounting.ownerCount, 0)
        XCTAssertEqual(accounting.reservedSourceByteCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
        XCTAssertEqual(accounting.rootAdmissionHistoryCount, 0)
        XCTAssertEqual(accounting.ownerAdmissionHistoryCount, 0)
        let snapshot = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(snapshot)

        let shutdownFinished = EngineCompletionFlag()
        let shutdown = Task {
            await fixture.engine.shutdown()
            shutdownFinished.finish()
        }
        XCTAssertFalse(shutdownFinished.waitUntilFinished(timeout: 0.1))
        await loadGate.release()
        await shutdown.value
    }

    func testPostCommitManifestAdoptionAuthorityRaceRollsBackOverlaySessionAndLease() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Race.swift": SwiftFixtureSource.emptyStruct("Race")]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Race.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let adoptionGate = EngineBuildGate()
        let overlay = WorkspaceCodemapLiveOverlay(
            manifestAdoptionCommitHook: { await adoptionGate.enter() }
        )
        let runtime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let fixture = try await makeEngineFixture(root: root, runtime: runtime, overlay: overlay)
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected lazy registration.")
        }
        let demand = Task {
            await fixture.engine.demand(fixture.demand(
                path: "Sources/Race.swift",
                priority: .background
            ))
        }
        _ = await adoptionGate.waitUntilEntered()

        let invalidation = Task {
            await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
        }
        while await fixture.engine.accounting().unavailableRootCount == 0 {
            await Task.yield()
        }
        await adoptionGate.release()

        _ = await invalidation.value
        guard case .cancelled = await demand.value else {
            return XCTFail("Expected stale demand to cancel after adoption rollback.")
        }
        let snapshotValue = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.authorityIsCurrent)
        XCTAssertTrue(snapshot.entries.isEmpty)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.manifestAdoptions, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
    }
}
