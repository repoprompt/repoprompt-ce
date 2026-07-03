import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodemapBindingEngineWarmManifestTests: CodemapBindingEngineTestCase {
    func testCleanColdBuildPublishesManifestAndWarmRegistrationAdoptsWithoutMaterialization() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Clean.swift": "struct Clean {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let cold = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered(adoptedReadyCount: 0) = await cold.engine.registerRoot(cold.registration) else {
            return XCTFail("Expected cold registration.")
        }
        guard case .ready = await cold.engine.demand(cold.demand(path: "Sources/Clean.swift")) else {
            return XCTFail("Expected clean ready demand.")
        }
        let coldAccounting = await cold.engine.accounting()
        XCTAssertEqual(coldAccounting.counters.materializations, 1)
        XCTAssertEqual(coldAccounting.counters.manifestWrites, 1)
        XCTAssertEqual(coldAccounting.counters.builds, 1)
        await cold.engine.unloadRoot(rootEpoch: cold.rootEpoch)

        let sourceReadCounter = EngineAsyncCounter()
        let trappingReader = WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
            await sourceReadCounter.increment()
            throw CancellationError()
        }
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            sourceReaderOverride: trappingReader
        )
        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(
            path: "Sources/Clean.swift",
            priority: .background
        ))) else {
            return XCTFail("Expected first background request to adopt the warm manifest.")
        }
        let warmAccounting = await warm.engine.accounting()
        XCTAssertEqual(warmAccounting.counters.materializations, 0)
        XCTAssertEqual(warmAccounting.counters.builds, 0)
        XCTAssertEqual(warmAccounting.counters.demandManifestAdoptionBypasses, 0)
        XCTAssertEqual(warmAccounting.counters.demandManifestAdoptionWaits, 1)
        XCTAssertEqual(warmAccounting.counters.manifestAdoptions, 1)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        guard case let .ready(source, _, _) = try XCTUnwrap(snapshot.entries.first).state else {
            return XCTFail("Expected adopted ready entry.")
        }
        XCTAssertEqual(source, .cleanManifest)
    }

    func testManifestAdoptionSkipsRecordWhenCandidateGenerationIsNewerThanBindingGeneration() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Warm.swift": "struct Warm {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        let seedResult = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift"))
        let seedReady: WorkspaceCodemapLiveReadySnapshot
        guard case let .ready(ready) = seedResult else {
            return XCTFail("Expected warm artifact seed, got \(seedResult).")
        }
        seedReady = ready
        XCTAssertGreaterThan(seedReady.requestGeneration, 0)
        let seedRecord = try await publishVerifiedManifestRecord(
            fixture: seed,
            runtime: seedRuntime,
            ready: seedReady
        )
        XCTAssertEqual(seedRecord.bindingGeneration, seedReady.requestGeneration)
        let seedCapability = try await eligible(seed.capabilityService.resolve(
            root: seed.registration.capabilityRequest
        ))
        let seedPipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let seedNamespace = try CodeMapRootManifestNamespace(
            capability: seedCapability,
            pipelineIdentity: seedPipeline
        )
        let seedAuthority = try CodeMapRootManifestAuthority(
            namespace: seedNamespace,
            token: seedCapability.repositoryAuthority
        )
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)
        let persistedLoad = try await seedRuntime.manifestStore.loadCurrentManifest(
            namespace: seedNamespace,
            currentAuthority: seedAuthority
        )
        guard case let .hit(persistedSnapshot) = persistedLoad else {
            return XCTFail("Expected seeded manifest to be persisted, got \(persistedLoad).")
        }
        let persistedRecord = try XCTUnwrap(persistedSnapshot.records.first {
            $0.repositoryRelativePath == seedRecord.repositoryRelativePath
        })
        XCTAssertEqual(persistedRecord.bindingGeneration, seedReady.requestGeneration)

        let currentGeneration = seedReady.requestGeneration + 1
        let warmCatalogResolutions = EngineManifestBindingResolutionRecorder()
        let warmRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let warm = try await makeEngineFixture(
            root: root,
            runtime: warmRuntime,
            projectionCatalogFactory: { rootEpoch, fileIDs in
                WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
                    guard epoch == rootEpoch,
                          let identity = WorkspaceCodemapArtifactBindingIdentity(
                              rootID: rootEpoch.rootID,
                              rootLifetimeID: rootEpoch.rootLifetimeID,
                              fileID: fileIDs.id(for: relativePath),
                              standardizedRootPath: root.path,
                              standardizedRelativePath: relativePath,
                              standardizedFullPath: root.appendingPathComponent(relativePath).path
                          )
                    else { return nil }
                    let candidate = WorkspaceCodemapManifestBindingCandidate(
                        identity: identity,
                        requestGeneration: currentGeneration,
                        pathGeneration: currentGeneration,
                        ingressGeneration: 1
                    )
                    await warmCatalogResolutions.record(candidate)
                    return candidate
                }
            }
        )
        _ = await warm.engine.registerRoot(warm.registration)
        let result = await warm.engine.demand(warm.demand(
            path: "Sources/Warm.swift",
            priority: .background,
            requestGeneration: currentGeneration,
            pathGeneration: currentGeneration
        ))

        guard isReady(result) else {
            return XCTFail("Generation-skewed manifest record should be skipped and rebuilt, got \(result).")
        }
        let warmResolutions = await warmCatalogResolutions.entries
        XCTAssertFalse(warmResolutions.isEmpty)
        XCTAssertTrue(warmResolutions.allSatisfy {
            $0.relativePath == "Sources/Warm.swift" &&
                $0.requestGeneration == currentGeneration &&
                $0.pathGeneration == currentGeneration &&
                $0.ingressGeneration == 1
        })
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
        XCTAssertEqual(accounting.counters.demandManifestAdoptionWaits, 1)
        XCTAssertEqual(accounting.counters.locatorFastPaths, 1)
        XCTAssertEqual(accounting.counters.casFastPaths, 1)
        XCTAssertEqual(accounting.counters.builds, 0)
        XCTAssertEqual(accounting.counters.materializations, 0)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        let entry = try XCTUnwrap(snapshot.entries.first {
            $0.standardizedRelativePath == "Sources/Warm.swift"
        })
        guard case let .ready(source, _, _) = entry.state else {
            return XCTFail("Expected live ready entry.")
        }
        XCTAssertEqual(source, .live)
        switch result {
        case let .ready(snapshot), let .alreadyReady(snapshot):
            XCTAssertEqual(snapshot.requestGeneration, currentGeneration)
        case .unavailable, .busy, .rejected, .cancelled:
            XCTFail("Expected ready rebuilt demand, got \(result).")
        }
    }

    func testDemandWarmLocatorAndCASBypassUnstartedManifestAdoption() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Warm.swift": "struct Warm {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let runtime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected warm artifact seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let warm = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await warm.engine.registerRoot(warm.registration)
        guard await isReady(warm.engine.demand(warm.demand(path: "Sources/Warm.swift"))) else {
            return XCTFail("Expected demand to resolve from the warm locator and CAS.")
        }

        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.demandManifestAdoptionBypasses, 1)
        XCTAssertEqual(accounting.counters.demandManifestAdoptionWaits, 0)
        XCTAssertEqual(accounting.counters.manifestLoads, 0)
        XCTAssertEqual(accounting.counters.manifestAdoptions, 0)
        XCTAssertEqual(accounting.counters.locatorFastPaths, 1)
        XCTAssertEqual(accounting.counters.casFastPaths, 1)
        XCTAssertEqual(accounting.counters.materializations, 0)
        XCTAssertEqual(accounting.counters.builds, 0)
    }

    func testPublishedArtifactLookupSurvivesOwnerExitCancellationAndTargetedInvalidation() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Warm.swift": "struct Warm {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let hookEvents = EngineHookEvents()
        let lookupCurrentnessGate = EngineAsyncGate()
        let gatePostLookupCurrentnessValidation = EngineLockedFlag()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks(
                event: { hookEvents.record($0) },
                afterPublishedArtifactLookupBeforeCurrentnessValidation: { _ in
                    if gatePostLookupCurrentnessValidation.value {
                        await lookupCurrentnessGate.enterAndWait()
                    }
                }
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let seedDemand = fixture.demand(path: "Sources/Warm.swift")
        guard case .ready = await fixture.engine.demand(seedDemand) else {
            return XCTFail("Expected the seed demand to publish a durable artifact.")
        }
        let cancelledOwnerCount = await fixture.engine.cancel(owner: seedDemand.owner)
        XCTAssertEqual(cancelledOwnerCount, 0)

        let lookupRequest: @Sendable (UUID) -> WorkspaceCodemapPublishedArtifactLookupRequest = { ownerID in
            WorkspaceCodemapPublishedArtifactLookupRequest(
                ownerID: ownerID,
                identity: seedDemand.identity,
                requestGeneration: seedDemand.requestGeneration,
                catalogGeneration: seedDemand.catalogGeneration,
                pathGeneration: seedDemand.pathGeneration,
                ingressGeneration: seedDemand.ingressGeneration,
                language: seedDemand.language
            )
        }

        let accountingBeforeWarmLookups = await fixture.engine.accounting()
        for result in await [
            fixture.engine.lookupPublishedArtifact(lookupRequest(UUID())),
            fixture.engine.lookupPublishedArtifact(lookupRequest(UUID()))
        ] {
            guard case let .hit(hit) = result else {
                return XCTFail("Independent owners must share the published artifact.")
            }
            XCTAssertEqual(hit.source, .projectionCAS)
        }
        let accountingAfterWarmLookups = await fixture.engine.accounting()
        XCTAssertEqual(
            accountingAfterWarmLookups.counters.publishedArtifactProjectionCASHits,
            accountingBeforeWarmLookups.counters.publishedArtifactProjectionCASHits + 2
        )
        XCTAssertEqual(
            accountingAfterWarmLookups.counters.publishedArtifactLocatorCASHits,
            accountingBeforeWarmLookups.counters.publishedArtifactLocatorCASHits
        )
        XCTAssertEqual(
            accountingAfterWarmLookups.counters.publishedArtifactLookupMisses,
            accountingBeforeWarmLookups.counters.publishedArtifactLookupMisses
        )
        XCTAssertEqual(accountingAfterWarmLookups.activeRequestCount, 0)
        XCTAssertEqual(accountingAfterWarmLookups.queuedRequestCount, 0)
        XCTAssertEqual(accountingAfterWarmLookups.ownerCount, 0)
        XCTAssertEqual(
            accountingAfterWarmLookups.counters.classifications,
            accountingBeforeWarmLookups.counters.classifications
        )
        XCTAssertEqual(
            accountingAfterWarmLookups.counters.manifestAdoptions,
            accountingBeforeWarmLookups.counters.manifestAdoptions
        )
        XCTAssertEqual(
            accountingAfterWarmLookups.counters.materializations,
            accountingBeforeWarmLookups.counters.materializations
        )
        XCTAssertEqual(
            accountingAfterWarmLookups.counters.builds,
            accountingBeforeWarmLookups.counters.builds
        )

        let cancelled = Task {
            await fixture.engine.lookupPublishedArtifact(lookupRequest(UUID()))
        }
        cancelled.cancel()
        _ = await cancelled.value
        guard case .hit = await fixture.engine.lookupPublishedArtifact(lookupRequest(UUID())) else {
            return XCTFail("Cancelling one lookup must not revoke the published artifact.")
        }

        let accountingBeforeInvalidation = await fixture.engine.accounting()
        XCTAssertEqual(accountingBeforeInvalidation.counters.classifications, 1)
        XCTAssertGreaterThanOrEqual(
            accountingBeforeInvalidation.counters.publishedArtifactProjectionCASHits,
            3
        )
        XCTAssertEqual(accountingBeforeInvalidation.counters.publishedArtifactLocatorCASHits, 0)
        XCTAssertGreaterThanOrEqual(hookEvents.count(kind: .publishedArtifactLookupHit), 3)
        XCTAssertTrue(hookEvents.values(kind: .publishedArtifactLookupHit).allSatisfy {
            $0.publishedArtifactLookupSource == .projectionCAS
        })

        gatePostLookupCurrentnessValidation.set(true)
        let racedLookup = Task {
            await fixture.engine.lookupPublishedArtifact(lookupRequest(UUID()))
        }
        XCTAssertTrue(lookupCurrentnessGate.waitUntilEntered())
        let accountingBeforePostLookupInvalidation = await fixture.engine.accounting()
        let invalidation = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Warm.swift"]
        )
        XCTAssertFalse(invalidation.manifestWriteFailed)
        lookupCurrentnessGate.release()
        guard case let .miss(racedReason) = await racedLookup.value else {
            return XCTFail("A post-CAS invalidation must reject the stale lookup.")
        }
        XCTAssertEqual(racedReason, .currentnessMismatch)
        let accountingAfterPostLookupInvalidation = await fixture.engine.accounting()
        XCTAssertEqual(
            accountingAfterPostLookupInvalidation.counters.publishedArtifactPostLookupCurrentnessRejections,
            accountingBeforePostLookupInvalidation.counters.publishedArtifactPostLookupCurrentnessRejections + 1
        )
        XCTAssertEqual(
            hookEvents.count(kind: .publishedArtifactPostLookupCurrentnessRejection),
            1
        )
        XCTAssertEqual(
            hookEvents.values(kind: .publishedArtifactPostLookupCurrentnessRejection).first?
                .publishedArtifactLookupSource,
            .projectionCAS
        )
        gatePostLookupCurrentnessValidation.set(false)
        guard case let .miss(reason) = await fixture.engine.lookupPublishedArtifact(lookupRequest(UUID())) else {
            return XCTFail("A changed path identity must invalidate its published projection.")
        }
        XCTAssertEqual(reason, .projectionMissing)
        XCTAssertEqual(
            hookEvents.values(kind: .invalidation).last?.invalidationReason,
            .modified
        )
        XCTAssertEqual(
            hookEvents.values(kind: .publishedArtifactLookupMiss).last?
                .publishedArtifactLookupMissReason,
            .projectionMissing
        )
    }

    func testDemandBypassesBlockedBackgroundManifestAdoption() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Warm.swift": "struct Warm {}\n",
                "Sources/Background.swift": "struct Background {}\n"
            ]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected warm artifact seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let adoptionGate = EngineBuildGate()
        let warmRuntime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { await adoptionGate.enter() }
            )
        )
        let warm = try await makeEngineFixture(root: root, runtime: warmRuntime)
        _ = await warm.engine.registerRoot(warm.registration)
        let background = Task {
            await warm.engine.demand(warm.demand(
                path: "Sources/Background.swift",
                priority: .background
            ))
        }
        let backgroundAdoptionEntered = await adoptionGate.waitUntilEntered()
        XCTAssertTrue(backgroundAdoptionEntered)

        let demanded = Task {
            await warm.engine.demand(warm.demand(path: "Sources/Warm.swift"))
        }
        let demandedResult = await demandResult(demanded, before: .seconds(5))
        let blockedAccounting = await warm.engine.accounting()
        await adoptionGate.release()
        let backgroundResult = await background.value

        guard let demandedResult, isReady(demandedResult) else {
            return XCTFail("Demand must complete while root-wide adoption remains blocked.")
        }
        XCTAssertTrue(isReady(backgroundResult))
        XCTAssertEqual(blockedAccounting.counters.demandManifestAdoptionBypasses, 1)
        XCTAssertEqual(blockedAccounting.counters.demandManifestAdoptionWaits, 1)
        XCTAssertEqual(blockedAccounting.counters.locatorFastPaths, 1)
        XCTAssertEqual(blockedAccounting.counters.casFastPaths, 1)
        XCTAssertEqual(blockedAccounting.counters.materializations, 0)
        XCTAssertEqual(blockedAccounting.counters.builds, 0)
    }

    func testDemandBypassRejectsChangedSourceProofBeforeWarmLocatorResolution() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Warm.swift": "struct Warm {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let runtime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected warm artifact seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let mutation = EngineOneShotFileMutation(
            url: root.appendingPathComponent("Sources/Warm.swift"),
            contents: "struct Warm { let changed = true }\n"
        )
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { await mutation.mutateOnce() }
            )
        )
        _ = await warm.engine.registerRoot(warm.registration)

        guard case .rejected(.sourceAuthorityUnavailable) = await warm.engine.demand(
            warm.demand(path: "Sources/Warm.swift")
        ) else {
            return XCTFail("Changed source proof must reject the demand bypass.")
        }
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.demandManifestAdoptionBypasses, 1)
        XCTAssertEqual(accounting.counters.manifestLoads, 0)
        XCTAssertEqual(accounting.counters.locatorFastPaths, 0)
        XCTAssertEqual(accounting.counters.casFastPaths, 0)
        XCTAssertEqual(accounting.counters.materializations, 0)
        XCTAssertEqual(accounting.counters.overlayReadyPublications, 0)
    }

    func testPathInvalidationDuringBlockedWarmAdoptionRemainsRetryable() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Warm.swift": "struct Warm {}\n",
                "Sources/Trigger.swift": "struct Trigger {}\n",
                "Sources/Other.swift": "struct Other {}\n"
            ]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected warm manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let adoptionGate = EngineFirstResolutionGate()
        let warmRuntime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { await adoptionGate.enter() }
            )
        )
        let warm = try await makeEngineFixture(root: root, runtime: warmRuntime)
        _ = await warm.engine.registerRoot(warm.registration)
        let trigger = Task {
            await warm.engine.demand(warm.demand(
                path: "Sources/Trigger.swift",
                priority: .background
            ))
        }
        let firstAdoptionEntered = await adoptionGate.waitUntilFirstResolution()
        XCTAssertTrue(firstAdoptionEntered)
        let invalidationResult = await warm.engine.invalidateModified(
            rootEpoch: warm.rootEpoch,
            standardizedRelativePaths: ["Sources/Other.swift"]
        )
        XCTAssertFalse(invalidationResult.manifestWriteFailed)
        let replacement = Task {
            await warm.engine.demand(warm.demand(
                path: "Sources/Warm.swift",
                priority: .background
            ))
        }
        guard let replacementResult = await demandResult(
            replacement,
            before: .seconds(5)
        ), await adoptionGate.resolutionCount >= 2,
        isReady(replacementResult)
        else {
            return XCTFail("Expected warm manifest adoption to retry after invalidation.")
        }
        await adoptionGate.releaseFirstResolution()
        guard case .ready = await trigger.value else {
            return XCTFail("Expected unrelated trigger demand to remain active.")
        }
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        let warmEntry = try XCTUnwrap(snapshot.entries.first(where: {
            $0.standardizedRelativePath == "Sources/Warm.swift"
        }))
        guard case .ready = warmEntry.state else {
            return XCTFail("Expected retried warm entry.")
        }
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.manifestLoads, 2)
    }

    func testCancelledManifestAdoptionWaiterReleasesAdmissionWithoutCancellingSharedLoad() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Warm.swift": "struct Warm {}\n"]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: root, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected warm manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let loadGate = EngineBuildGate()
        let sharedLoadCancellation = EngineLockedFlag()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: {
                    await loadGate.enter()
                    sharedLoadCancellation.set(Task.isCancelled)
                }
            )
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumActiveRequestCountPerRoot: 1,
                maximumActiveRequestCount: 1,
                maximumQueuedRequestCountPerRoot: 1,
                maximumQueuedRequestCount: 1,
                maximumActiveTaskCountPerRoot: 1,
                maximumActiveTaskCount: 1,
                maximumConcurrentMaterializationCountPerRoot: 1,
                maximumConcurrentMaterializationCount: 1
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let first = Task {
            await fixture.engine.demand(fixture.demand(
                path: "Sources/Warm.swift",
                priority: .background
            ))
        }
        let sharedLoadEntered = await loadGate.waitUntilEntered()
        XCTAssertTrue(sharedLoadEntered)
        let second = Task {
            await fixture.engine.demand(fixture.demand(
                path: "Sources/Warm.swift",
                priority: .background
            ))
        }
        while await fixture.engine.accounting().queuedRequestCount != 1 {
            await Task.yield()
        }

        first.cancel()
        guard case .cancelled = await first.value else {
            return XCTFail("Expected the detached manifest waiter to cancel.")
        }
        let waiterReplaced = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.activeRequestCount == 1 && accounting.queuedRequestCount == 0
        }
        XCTAssertTrue(waiterReplaced)
        let recovered = await fixture.engine.accounting()
        XCTAssertEqual(recovered.activeRequestCount, 1)
        XCTAssertEqual(recovered.queuedRequestCount, 0)
        XCTAssertEqual(recovered.ownerCount, 1)
        XCTAssertEqual(recovered.counters.cancellations, 1)

        await loadGate.release()
        guard await isReady(second.value) else {
            return XCTFail("Expected the remaining waiter to complete from the shared adoption.")
        }
        XCTAssertFalse(sharedLoadCancellation.value)
        let final = await fixture.engine.accounting()
        XCTAssertEqual(final.activeRequestCount, 0)
        XCTAssertEqual(final.queuedRequestCount, 0)
        XCTAssertEqual(final.counters.manifestLoads, 1)
        XCTAssertEqual(final.counters.manifestAdoptions, 1)
        XCTAssertEqual(final.counters.cancellations, 1)
    }

    func testOwnerCancellationImmediatelyReleasesAdmissionWhileBlockedIOGuaranteesDrain() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Blocked.swift": "struct Blocked {}\n",
                "Sources/Replacement.swift": "struct Replacement {}\n"
            ]
        )
        let gate = EngineFirstResolutionGate()
        let fileSystem = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumActiveRequestCountPerRoot: 1,
                maximumActiveRequestCount: 1,
                maximumQueuedRequestCountPerRoot: 1,
                maximumQueuedRequestCount: 1,
                maximumActiveTaskCountPerRoot: 1,
                maximumActiveTaskCount: 1,
                maximumConcurrentMaterializationCountPerRoot: 1,
                maximumConcurrentMaterializationCount: 1
            ),
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient {
                identity,
                expected,
                maximumBytes,
                ownerID in
                await gate.enter()
                return try await fileSystem.loadValidatedRawContent(
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
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write("struct Blocked { let dirty = true }\n", to: "Sources/Blocked.swift", at: root)
        try repository.write(
            "struct Replacement { let dirty = true }\n",
            to: "Sources/Replacement.swift",
            at: root
        )
        let blockedOwner = WorkspaceCodemapLiveDemandOwner()
        let blocked = Task {
            await fixture.engine.demand(fixture.demand(
                path: "Sources/Blocked.swift",
                owner: blockedOwner
            ))
        }
        let blockedReadEntered = await gate.waitUntilFirstResolution()
        XCTAssertTrue(blockedReadEntered)
        let replacement = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Replacement.swift"))
        }

        let queued = await waitForEngineCondition {
            await fixture.engine.accounting().queuedRequestCount == 1
        }
        XCTAssertTrue(queued)
        let cancelledCount = await fixture.engine.cancel(owner: blockedOwner)
        XCTAssertEqual(cancelledCount, 1)
        guard case .cancelled = await blocked.value else {
            return XCTFail("Expected logical cancellation before blocked I/O drained.")
        }
        guard let replacementResult = await demandResult(replacement, before: .seconds(5)),
              isReady(replacementResult),
              await gate.resolutionCount >= 2
        else {
            return XCTFail("Expected immediate replacement admission while stale I/O remained blocked.")
        }
        let recovered = await fixture.engine.accounting()
        XCTAssertEqual(recovered.queuedRequestCount, 0)
        XCTAssertEqual(recovered.counters.cancellations, 1)

        await gate.releaseFirstResolution()
        let drained = await waitForEngineCondition {
            await fixture.engine.accounting().activeRequestCount == 0
        }
        XCTAssertTrue(drained)
    }

    func testWarmManifestAdoptionReclassifiesDirtyCandidateAndKeepsOnlyCurrentCleanOID() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Clean.swift": "struct Clean {}\n",
                "Sources/Dirty.swift": "struct Dirty {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Clean.swift")),
              case .ready = await seed.engine.demand(seed.demand(path: "Sources/Dirty.swift"))
        else { return XCTFail("Expected manifest seeds.") }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)
        try repository.write(
            "struct Dirty { let changed = true }\n",
            to: "Sources/Dirty.swift",
            at: root
        )

        let sourceReadCounter = EngineAsyncCounter()
        let trappingReader = WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
            await sourceReadCounter.increment()
            throw CancellationError()
        }
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            sourceReaderOverride: trappingReader
        )
        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(
            path: "Sources/Clean.swift",
            priority: .background
        ))) else {
            return XCTFail("Only the current clean manifest candidate should be adopted by background work.")
        }
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.entries.map(\.standardizedRelativePath), ["Sources/Clean.swift"])
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.materializations, 0)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testWarmManifestMutationDuringClassificationCannotPublishStaleCleanEntry() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Race.swift": "struct Race {}\n",
                "Sources/Trigger.swift": "struct Trigger {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Race.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let mutation = EngineOneShotFileMutation(
            url: root.appendingPathComponent("Sources/Race.swift"),
            contents: "struct Race { let changed = true }\n"
        )
        let sourceReadCounter = EngineAsyncCounter()
        let hookEvents = EngineHookEvents()
        let trappingReader = WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
            await sourceReadCounter.increment()
            throw CancellationError()
        }
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            sourceReaderOverride: trappingReader,
            identityHooks: GitBlobIdentityServiceHooks(
                afterGitCollection: { await mutation.mutateOnce() }
            )
        )
        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(
            path: "Sources/Trigger.swift",
            priority: .background
        ))) else {
            return XCTFail("Expected background trigger after rejecting the stale warm candidate.")
        }
        XCTAssertEqual(hookEvents.count(kind: .manifestLoadHit), 1)
        let mutationInvocationCount = await mutation.invocationCount
        XCTAssertGreaterThanOrEqual(mutationInvocationCount, 1)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Race.swift" })
        XCTAssertTrue(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Trigger.swift" })
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.materializations, 1)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testWarmManifestMutationAfterClassificationFailsClosedWithoutSourceRead() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Race.swift": "struct Race {}\n",
                "Sources/Trigger.swift": "struct Trigger {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Race.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let mutation = EngineOneShotFileMutation(
            url: root.appendingPathComponent("Sources/Race.swift"),
            contents: "struct Race { let changedAfterClassification = true }\n"
        )
        let sourceReadCounter = EngineAsyncCounter()
        let hookEvents = EngineHookEvents()
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await sourceReadCounter.increment()
                throw CancellationError()
            },
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { await mutation.mutateOnce() }
            )
        )

        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(
            path: "Sources/Trigger.swift",
            priority: .background
        ))) else {
            return XCTFail("Expected background trigger after the stale candidate failed closed.")
        }
        XCTAssertEqual(hookEvents.count(kind: .manifestLoadHit), 1)
        let mutationInvocationCount = await mutation.invocationCount
        XCTAssertGreaterThanOrEqual(mutationInvocationCount, 1)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Race.swift" })
        XCTAssertTrue(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Trigger.swift" })
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.materializations, 1)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testWarmManifestMutationAfterAuthorityCaptureFailsFinalFenceWithoutSourceRead() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Race.swift": "struct Race {}\n",
                "Sources/Trigger.swift": "struct Trigger {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Race.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let mutation = EngineSecondCatalogResolutionMutation(
            url: root.appendingPathComponent("Sources/Race.swift"),
            contents: "struct Race { let changedAfterAuthority = true }\n"
        )
        let sourceReadCounter = EngineAsyncCounter()
        let hookEvents = EngineHookEvents()
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await sourceReadCounter.increment()
                throw CancellationError()
            },
            catalogResolutionHook: { _ in await mutation.resolve() }
        )

        guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
            return XCTFail("Expected lazy warm registration.")
        }
        guard await isReady(warm.engine.demand(warm.demand(
            path: "Sources/Trigger.swift",
            priority: .background
        ))) else {
            return XCTFail("Expected background trigger after the final authority fence rejected the candidate.")
        }
        XCTAssertEqual(hookEvents.count(kind: .manifestLoadHit), 1)
        let resolutionCount = await mutation.resolutionCount
        XCTAssertGreaterThanOrEqual(resolutionCount, 2)
        let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Race.swift" })
        XCTAssertTrue(snapshot.entries.contains { $0.standardizedRelativePath == "Sources/Trigger.swift" })
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.materializations, 1)
        XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
        XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
        let sourceReadCount = await sourceReadCounter.value
        XCTAssertEqual(sourceReadCount, 0)
    }

    func testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead() async throws {
        for state in WarmManifestCandidateState.allCases {
            let repository = try makeRepositoryFixture(name: "\(#function)-\(state)")
            let path = "Sources/Candidate.swift"
            let triggerPath = "Sources/Trigger.swift"
            let root = try repository.makeRepository(
                named: "repository",
                files: [
                    path: "struct Candidate {}\n",
                    triggerPath: "struct Trigger {}\n"
                ]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let seed = try await makeEngineFixture(root: root, runtime: runtime)
            _ = await seed.engine.registerRoot(seed.registration)
            guard case let .ready(seedReady) = await seed.engine.demand(seed.demand(path: path)) else {
                return XCTFail("Expected manifest seed for \(state).")
            }
            let seedRecord = try await publishVerifiedManifestRecord(
                fixture: seed,
                runtime: runtime,
                ready: seedReady
            )
            await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

            switch state {
            case .stagedOnly, .stagedAndUnstaged:
                try repository.write("struct Candidate { let staged = true }\n", to: path, at: root)
                try repository.stage(path, at: root)
                let stagedSeed = try await makeEngineFixture(root: root, runtime: runtime)
                _ = await stagedSeed.engine.registerRoot(stagedSeed.registration)
                guard case let .ready(stagedReady) = await stagedSeed.engine.demand(
                    stagedSeed.demand(path: path)
                ) else {
                    return XCTFail("Expected staged manifest seed for \(state).")
                }
                _ = try await publishVerifiedManifestRecord(
                    fixture: stagedSeed,
                    runtime: runtime,
                    ready: stagedReady
                )
                await stagedSeed.engine.unloadRoot(rootEpoch: stagedSeed.rootEpoch)
                if state == .stagedAndUnstaged {
                    try repository.write(
                        "struct Candidate { let unstaged = true }\n",
                        to: path,
                        at: root
                    )
                }
            case .untrackedReplacement, .conflict, .checkoutTransform:
                try configureWarmManifestCandidate(
                    state,
                    repository: repository,
                    root: root,
                    path: path
                )
                try await republishManifestForCurrentAuthority(
                    record: seedRecord,
                    root: root,
                    runtime: runtime
                )
            }

            let classificationBatch = await GitBlobIdentityService().classify(
                workspaceRoot: root,
                relativePaths: [path]
            )
            let classification = try XCTUnwrap(classificationBatch.classifications.first)
            assertWarmManifestClassification(classification, matches: state)

            let sourceReadCounter = EngineAsyncCounter()
            let hookEvents = EngineHookEvents()
            let warm = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
                sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                    await sourceReadCounter.increment()
                    throw CancellationError()
                }
            )
            guard case .registered(adoptedReadyCount: 0) = await warm.engine.registerRoot(warm.registration) else {
                return XCTFail("Expected lazy warm registration for \(state).")
            }
            guard await isReady(warm.engine.demand(warm.demand(
                path: triggerPath,
                priority: .background
            ))) else {
                return XCTFail("Expected background trigger after rejecting \(state).")
            }
            XCTAssertEqual(hookEvents.count(kind: .manifestLoadHit), 1)
            let snapshotValue = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
            let snapshot = try XCTUnwrap(snapshotValue)
            XCTAssertFalse(
                snapshot.entries.contains { $0.standardizedRelativePath == path },
                "Unexpected warm entry for \(state)."
            )
            XCTAssertTrue(snapshot.entries.contains { $0.standardizedRelativePath == triggerPath })
            let accounting = await warm.engine.accounting()
            XCTAssertEqual(accounting.counters.materializations, 1)
            XCTAssertEqual(accounting.manifestAdoptionLeaseCount, 0)
            XCTAssertEqual(accounting.manifestAdoptionLeaseByteCount, 0)
            let sourceReadCount = await sourceReadCounter.value
            XCTAssertEqual(sourceReadCount, 0)
            await warm.engine.unloadRoot(rootEpoch: warm.rootEpoch)
        }
    }

    func testLinkedWorktreeSharesLocatorAndCASButUsesDistinctManifestNamespace() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let canonical = try repository.makeRepository(
            named: "canonical",
            files: ["Sources/Shared.swift": "struct Shared {}\n"]
        )
        let linked = try repository.makeLinkedWorktree(
            from: canonical,
            named: "linked",
            branch: "linked-branch"
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let first = try await makeEngineFixture(root: canonical, runtime: runtime)
        _ = await first.engine.registerRoot(first.registration)
        guard case .ready = await first.engine.demand(first.demand(path: "Sources/Shared.swift")) else {
            return XCTFail("Expected canonical ready result.")
        }
        let second = try await makeEngineFixture(root: linked, runtime: runtime)
        _ = await second.engine.registerRoot(second.registration)
        guard case .ready = await second.engine.demand(second.demand(path: "Sources/Shared.swift")) else {
            return XCTFail("Expected linked ready result.")
        }
        let secondAccounting = await second.engine.accounting()
        XCTAssertEqual(secondAccounting.counters.materializations, 0)
        XCTAssertEqual(secondAccounting.counters.locatorFastPaths, 1)

        let firstCapability = try await eligible(first.capabilityService.state(for: first.rootEpoch))
        let secondCapability = try await eligible(second.capabilityService.state(for: second.rootEpoch))
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let firstNamespace = try CodeMapRootManifestNamespace(
            capability: firstCapability,
            pipelineIdentity: pipeline
        )
        let secondNamespace = try CodeMapRootManifestNamespace(
            capability: secondCapability,
            pipelineIdentity: pipeline
        )
        XCTAssertEqual(firstNamespace.repositoryNamespace, secondNamespace.repositoryNamespace)
        XCTAssertNotEqual(firstNamespace.worktreeIdentity, secondNamespace.worktreeIdentity)
        XCTAssertNotEqual(
            runtime.manifestStore.manifestURL(for: firstNamespace),
            runtime.manifestStore.manifestURL(for: secondNamespace)
        )
    }

    func testDirtyUntrackedAndTransformedFilesUseValidatedSourceAndNeverWriteManifest() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                ".gitattributes": "Sources/Transformed.swift text eol=crlf\n",
                "Notes.txt": "not a supported codemap source\n",
                "Sources/Dirty.swift": "struct Dirty {}\n",
                "Sources/Transformed.swift": "struct Transformed {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write("struct Dirty { let changed = true }\n", to: "Sources/Dirty.swift", at: root)
        try repository.write("struct Untracked {}\n", to: "Sources/Untracked.swift", at: root)

        for path in ["Sources/Dirty.swift", "Sources/Untracked.swift", "Sources/Transformed.swift"] {
            guard case .ready = await fixture.engine.demand(fixture.demand(path: path)) else {
                return XCTFail("Expected source-backed ready result for \(path).")
            }
        }
        guard case .unavailable(.unsupportedFileType) = await fixture.engine.demand(
            fixture.demand(path: "Notes.txt")
        ) else { return XCTFail("Expected typed unsupported outcome.") }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.validatedWorktreeReads, 3)
        XCTAssertEqual(accounting.counters.materializations, 0)
        XCTAssertEqual(accounting.counters.manifestWrites, 0)
        XCTAssertEqual(accounting.counters.overlayReadyPublications, 3)
        XCTAssertEqual(accounting.counters.overlayUnavailablePublications, 0)
        let snapshotValue = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.entries.count, 3)
        for entry in snapshot.entries {
            guard case let .ready(source, _, _) = entry.state else {
                return XCTFail("Expected live ready source.")
            }
            XCTAssertEqual(source, .live)
        }
    }

    func testFanInCancellationRemovesOneAssociationAndSharedBuildCompletesForOtherOwner() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/FanIn.swift": "struct FanIn {}\n"]
        )
        let gate = EngineBuildGate()
        let buildCounter = EngineAsyncCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                await gate.enter()
                return .readyNoSymbols
            })
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        let firstOwner = WorkspaceCodemapLiveDemandOwner()
        let secondOwner = WorkspaceCodemapLiveDemandOwner()
        let first = Task { await fixture.engine.demand(fixture.demand(path: "Sources/FanIn.swift", owner: firstOwner)) }
        _ = await gate.waitUntilEntered()
        let second = Task { await fixture.engine.demand(fixture.demand(path: "Sources/FanIn.swift", owner: secondOwner)) }
        for _ in 0 ..< 200 {
            if await fixture.engine.accounting().activeRequestCount == 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0 ..< 200 {
            if await runtime.coordinator.accounting().counters.joins > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let joinedCount = await runtime.coordinator.accounting().counters.joins
        XCTAssertGreaterThan(joinedCount, 0)
        let cancellationCount = await fixture.engine.cancel(owner: firstOwner)
        XCTAssertEqual(cancellationCount, 1)
        await gate.release()
        guard case .cancelled = await first.value else { return XCTFail("Expected first cancellation.") }
        let secondResult = await second.value
        guard case .ready = secondResult else {
            return XCTFail("Expected joined owner completion, got \(String(describing: secondResult)).")
        }
        let buildCount = await buildCounter.value
        let finalAccounting = await fixture.engine.accounting()
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(finalAccounting.activeRequestCount, 0)
    }

    func testConcurrentExactDuplicateCompletionPublishesOnceAndReleasesDuplicateLease() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Duplicate.swift": "struct Duplicate {}\n"]
        )
        let gate = EngineBuildGate()
        let events = EngineHookEvents()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await gate.enter()
                return .readyNoSymbols
            })
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks(event: { events.record($0) })
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let first = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Duplicate.swift")) }
        _ = await gate.waitUntilEntered()
        let second = Task {
            await fixture.engine.demand(fixture.demand(
                path: "Sources/Duplicate.swift",
                owner: WorkspaceCodemapLiveDemandOwner()
            ))
        }
        for _ in 0 ..< 200 {
            if await runtime.coordinator.accounting().counters.joins > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await gate.release()
        let results = await [first.value, second.value]
        XCTAssertEqual(results.count(where: { if case .ready = $0 { true } else { false } }), 1)
        XCTAssertEqual(results.count(where: { if case .alreadyReady = $0 { true } else { false } }), 1)

        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.overlayReadyPublications, 1)
        XCTAssertEqual(accounting.counters.overlayExactDuplicateCompletions, 1)
        XCTAssertEqual(events.count(kind: .overlayReady), 1)
        XCTAssertEqual(events.count(kind: .overlayExactDuplicate), 1)
        let storeAccounting = await runtime.artifactStore.accounting()
        XCTAssertEqual(storeAccounting.activeLeaseCount, 1)
    }
}
