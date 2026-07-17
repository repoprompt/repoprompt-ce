import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapBindingEngineInvalidationTests: CodemapBindingEngineTestCase {
    func testBulkCancellationTransitionsEmitExactPathFreeAggregateTelemetry() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/AlreadyCancelled.swift": SwiftFixtureSource.emptyStruct("AlreadyCancelled"),
                "Sources/Active.swift": SwiftFixtureSource.emptyStruct("Active"),
                "Sources/Queued.swift": SwiftFixtureSource.emptyStruct("Queued")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )

        for operation in EngineBulkCancellationOperation.allCases {
            let gate = EngineMultiEntryGate()
            let hookEvents = EngineHookEvents()
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                policy: WorkspaceCodemapBindingEnginePolicy(
                    maximumActiveRequestCountPerRoot: 2,
                    maximumActiveRequestCount: 2,
                    maximumQueuedRequestCountPerRoot: 1,
                    maximumQueuedRequestCount: 1,
                    maximumActiveTaskCountPerRoot: 2,
                    maximumActiveTaskCount: 2,
                    maximumConcurrentMaterializationCountPerRoot: 2,
                    maximumConcurrentMaterializationCount: 2
                ),
                hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
                sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                    await gate.enter()
                    try Task.checkCancellation()
                    throw FileSystemError.failedToReadFile
                }
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected registration for \(operation).")
            }
            for path in ["AlreadyCancelled.swift", "Active.swift", "Queued.swift"] {
                try repository.write(
                    "struct Dirty { let operation = \"\(operation)\" }\n",
                    to: "Sources/\(path)",
                    at: root
                )
            }

            let alreadyCancelled = Task {
                await fixture.engine.demand(fixture.demand(path: "Sources/AlreadyCancelled.swift"))
            }
            let active = Task {
                await fixture.engine.demand(fixture.demand(path: "Sources/Active.swift"))
            }
            let initialReadsEntered = await gate.waitUntilEntered(2)
            XCTAssertTrue(initialReadsEntered)
            let queued = Task {
                await fixture.engine.demand(fixture.demand(path: "Sources/Queued.swift"))
            }
            let requestQueued = await waitForEngineCondition {
                await fixture.engine.accounting().queuedRequestCount == 1
            }
            XCTAssertTrue(requestQueued)

            alreadyCancelled.cancel()
            guard case .cancelled = await alreadyCancelled.value else {
                return XCTFail("Expected caller cancellation for \(operation).")
            }
            XCTAssertTrue(hookEvents.wait(kind: .cancellation, numericValue: 1))
            let preBulk = await fixture.engine.accounting()
            XCTAssertEqual(preBulk.activeRequestCount, 2)
            XCTAssertEqual(preBulk.queuedRequestCount, 0)
            XCTAssertEqual(preBulk.counters.cancellations, 1)

            let shutdown: Task<Void, Never>?
            switch operation {
            case .pathInvalidation:
                let result = await fixture.engine.invalidateModified(
                    rootEpoch: fixture.rootEpoch,
                    standardizedRelativePaths: [
                        "Sources/AlreadyCancelled.swift",
                        "Sources/Active.swift",
                        "Sources/Queued.swift"
                    ]
                )
                XCTAssertEqual(result.cancelledRequestCount, 2)
                shutdown = nil
            case .authorityInvalidation:
                let result = await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
                XCTAssertEqual(result.cancelledRequestCount, 2)
                shutdown = nil
            case .unload:
                await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
                shutdown = nil
            case .shutdown:
                shutdown = Task { await fixture.engine.shutdown() }
            }

            XCTAssertTrue(hookEvents.wait(kind: .cancellation, numericValue: 2))
            let bulkAccounting = await fixture.engine.accounting()
            XCTAssertEqual(bulkAccounting.counters.cancellations, 3)
            let cancellationEvents = hookEvents.values(kind: .cancellation)
            XCTAssertEqual(cancellationEvents.map(\.numericValue), [1, 2])
            XCTAssertTrue(cancellationEvents.allSatisfy {
                $0.rootEpoch == nil && $0.artifactStorageDigest == nil
            })

            await gate.releaseAll()
            await shutdown?.value
            guard case .cancelled = await active.value,
                  case .cancelled = await queued.value
            else { return XCTFail("Expected bulk cancellation for \(operation).") }
            let drained = await waitForEngineCondition {
                await fixture.engine.accounting().activeRequestCount == 0
            }
            XCTAssertTrue(drained)
            let finalAccounting = await fixture.engine.accounting()
            XCTAssertEqual(finalAccounting.counters.cancellations, 3)
            XCTAssertEqual(hookEvents.count(kind: .cancellation), 2)
            XCTAssertEqual(hookEvents.numericTotal(kind: .cancellation), 3)
            await fixture.engine.shutdown()
        }
    }

    func testEditRenameDeleteWatcherAndCheckoutInvalidationsFenceVisibilityWithoutScheduling() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Fenced.swift": SwiftFixtureSource.emptyStruct("Fenced")]
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Fenced.swift")) else {
            return XCTFail("Expected initial ready result.")
        }
        let modified = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Fenced.swift"]
        )
        XCTAssertEqual(modified.revokedOverlayCount, 1)
        let modifiedBundleValue = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(try XCTUnwrap(modifiedBundleValue).entries.isEmpty)

        let renamed = await fixture.engine.invalidateRenamed(
            rootEpoch: fixture.rootEpoch,
            from: "Sources/Fenced.swift",
            to: "Sources/Renamed.swift"
        )
        XCTAssertFalse(renamed.manifestWriteFailed)
        let deleted = await fixture.engine.invalidateDeleted(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Renamed.swift"]
        )
        XCTAssertFalse(deleted.manifestWriteFailed)
        let watcher = await fixture.engine.invalidateWatcherGap(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(watcher.revokedOverlayCount, 1)
        guard case .rejected(.capabilityUnavailable) = await fixture.engine.demand(
            fixture.demand(path: "Sources/Fenced.swift")
        ) else { return XCTFail("Expected watcher authority fence.") }
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected explicit re-registration after watcher gap.")
        }
        let checkout = await fixture.engine.invalidateCheckout(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(checkout.revokedOverlayCount, 1)
    }

    func testCatalogInvalidationFencesVisibilityWithoutScheduling() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Fenced.swift": SwiftFixtureSource.emptyStruct("Fenced")]
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Fenced.swift")) else {
            return XCTFail("Expected initial ready result.")
        }
        let before = await fixture.engine.accounting()

        let invalidation = await fixture.engine.invalidateCatalog(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(invalidation.revokedOverlayCount, 1)
        XCTAssertEqual(invalidation.cancelledRequestCount, 0)
        let bundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(bundle)
        guard case .rejected(.capabilityUnavailable) = await fixture.engine.demand(
            fixture.demand(path: "Sources/Fenced.swift")
        ) else {
            return XCTFail("Catalog invalidation must not schedule replacement work.")
        }
        let after = await fixture.engine.accounting()
        XCTAssertEqual(after.rootCount, 1)
        XCTAssertEqual(after.unavailableRootCount, 1)
        XCTAssertEqual(after.counters.builds, before.counters.builds)
        XCTAssertEqual(after.activeRequestCount, 0)
        XCTAssertEqual(after.queuedRequestCount, 0)

        let repeated = await fixture.engine.invalidateCatalog(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(repeated.revokedOverlayCount, 0)
        XCTAssertEqual(repeated.cancelledRequestCount, 0)
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
    }

    func testManifestWriteFailureKeepsVerifiedOverlayReadyAndMarksRetryState() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Failure.swift": SwiftFixtureSource.emptyStruct("Failure"),
                "Sources/Recovery.swift": SwiftFixtureSource.emptyStruct("Recovery")
            ]
        )
        let fault = EngineManifestFaultOnce()
        let hookEvents = EngineHookEvents()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            manifestStoreHooks: CodeMapRootManifestStoreHooks(faultAction: fault.action)
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let failureResult = await fixture.engine.demand(fixture.demand(path: "Sources/Failure.swift"))
        guard case .ready = failureResult else {
            let accounting = await fixture.engine.accounting()
            return XCTFail(bindingDemandFailureMessage(
                "Manifest failure must not discard ready overlay state.",
                result: failureResult,
                accounting: accounting,
                events: hookEvents.snapshot()
            ))
        }
        XCTAssertTrue(hookEvents.wait(
            kind: .manifestRevisionQueued,
            rootEpoch: fixture.rootEpoch,
            numericValue: 1
        ))
        XCTAssertTrue(hookEvents.wait(
            kind: .manifestFailure,
            rootEpoch: fixture.rootEpoch,
            numericValue: 0
        ))
        XCTAssertEqual(fault.triggeredCount, 1)
        XCTAssertEqual(
            hookEvents.values(kind: .manifestFailure).count(where: { $0.rootEpoch == fixture.rootEpoch }),
            1
        )
        let accounting = await fixture.engine.accounting()
        XCTAssertLessThanOrEqual(accounting.dirtyManifestCount, 1)
        XCTAssertEqual(accounting.counters.manifestFailures, 1)
        let bundleValue = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(try XCTUnwrap(bundleValue).entries.count, 1)

        XCTAssertTrue(hookEvents.wait(
            kind: .manifestWrite,
            rootEpoch: fixture.rootEpoch,
            minimumCount: 1
        ))
        let retriedAccounting = await fixture.engine.accounting()
        XCTAssertEqual(retriedAccounting.dirtyManifestCount, 0)
        XCTAssertEqual(retriedAccounting.counters.manifestWrites, 1)

        let recoveryResult = await fixture.engine.demand(fixture.demand(path: "Sources/Recovery.swift"))
        guard case .ready = recoveryResult else {
            let accounting = await fixture.engine.accounting()
            return XCTFail(bindingDemandFailureMessage(
                "Expected newer manifest revision to recover publication.",
                result: recoveryResult,
                accounting: accounting,
                events: hookEvents.snapshot()
            ))
        }
        XCTAssertTrue(hookEvents.wait(
            kind: .manifestRevisionQueued,
            rootEpoch: fixture.rootEpoch,
            numericValue: 2
        ))
        XCTAssertTrue(hookEvents.wait(
            kind: .manifestWrite,
            rootEpoch: fixture.rootEpoch,
            minimumCount: 2
        ))
        let recoveredAccounting = await fixture.engine.accounting()
        XCTAssertEqual(recoveredAccounting.dirtyManifestCount, 0)
        XCTAssertEqual(recoveredAccounting.counters.manifestWrites, 2)

        let state = await fixture.capabilityService.state(for: fixture.rootEpoch)
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
            return XCTFail("Expected recovered manifest publication after retry.")
        }
        XCTAssertEqual(
            Set(snapshot.records.map(\.repositoryRelativePath)),
            ["Sources/Failure.swift", "Sources/Recovery.swift"]
        )
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)

        let reloaded = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered(adoptedReadyCount: 0) = await reloaded.engine.registerRoot(reloaded.registration) else {
            return XCTFail("Expected lazy recovered registration.")
        }
        guard await isReady(reloaded.engine.demand(
            reloaded.demand(path: "Sources/Failure.swift")
        )) else {
            return XCTFail("Expected recovered manifest to retain failed revision on demand.")
        }
        guard await isReady(reloaded.engine.demand(
            reloaded.demand(path: "Sources/Recovery.swift")
        )) else {
            return XCTFail("Expected recovered manifest to retain retry revision on demand.")
        }
    }

    func testRootBoundsAndPathFreeHooksDoNotLeakPhysicalPaths() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let firstRoot = try repository.makeRepository(
            named: "one",
            files: ["One.swift": SwiftFixtureSource.emptyStruct("One")]
        )
        let secondRoot = try repository.makeRepository(
            named: "two",
            files: ["Two.swift": SwiftFixtureSource.emptyStruct("Two")]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let eventDescriptions = EngineEventDescriptions()
        let first = try await makeEngineFixture(
            root: firstRoot,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(maximumRootCount: 1),
            hooks: WorkspaceCodemapBindingEngineHooks { eventDescriptions.append(String(describing: $0.kind)) }
        )
        guard case .registered = await first.engine.registerRoot(first.registration) else {
            return XCTFail("Expected first root registration.")
        }
        let secondRegistration = WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: secondRoot,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        guard case .busy = await first.engine.registerRoot(secondRegistration) else {
            return XCTFail("Expected root bound.")
        }
        XCTAssertFalse(eventDescriptions.values.joined().contains(firstRoot.path))
        await first.engine.unloadRoot(rootEpoch: first.rootEpoch)
        let finalAccounting = await first.engine.accounting()
        XCTAssertEqual(finalAccounting.rootCount, 0)
    }

    func testEnginePublicationCountersSaturateWithoutWrapping() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Saturating.swift": SwiftFixtureSource.emptyStruct("Saturating")]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            initialCounterValue: .max
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Saturating.swift")) else {
            return XCTFail("Expected ready publication at saturated accounting.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.overlayReadyPublications, .max)
        XCTAssertEqual(accounting.counters.builds, .max)
        XCTAssertEqual(accounting.counters.materializedBytes, .max)
    }

    func testConcurrentRegistrationReservesRootSlotBeforeManifestLoad() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let firstRoot = try repository.makeRepository(
            named: "one",
            files: ["One.swift": SwiftFixtureSource.emptyStruct("One")]
        )
        let secondRoot = try repository.makeRepository(
            named: "two",
            files: ["Two.swift": SwiftFixtureSource.emptyStruct("Two")]
        )
        let artifactRoot = try makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        let seedRuntime = try CodeMapArtifactRuntime(rootURL: artifactRoot)
        let seed = try await makeEngineFixture(root: firstRoot, runtime: seedRuntime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "One.swift")) else {
            return XCTFail("Expected manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let manifestReads = EngineLockedCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { manifestReads.increment() }
            )
        )
        let fixture = try await makeEngineFixture(
            root: firstRoot,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(maximumRootCount: 1)
        )
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected first registration.")
        }
        XCTAssertEqual(manifestReads.value, 0)
        let second = await fixture.engine.registerRoot(WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: secondRoot,
            catalogGeneration: 1,
            ingressGeneration: 1
        ))
        guard case .busy = second else { return XCTFail("Expected occupied root slot to reject overlap.") }
    }

    func testInvalidationsFenceBlockedCapabilityRegistrationBeforeAwait() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Fenced.swift": SwiftFixtureSource.emptyStruct("Fenced")]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )

        for kind in EngineRegistrationInvalidationKind.allCases {
            let gate = EngineBuildGate()
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                    beforeResolution: { await gate.enterIgnoringCancellationUntilRelease() }
                )
            )
            let registration = Task { await fixture.engine.registerRoot(fixture.registration) }
            _ = await gate.waitUntilEntered()

            let result: WorkspaceCodemapBindingInvalidationResult = switch kind {
            case .path:
                await fixture.engine.invalidateModified(
                    rootEpoch: fixture.rootEpoch,
                    standardizedRelativePaths: ["Sources/Fenced.swift"]
                )
            case .watcher:
                await fixture.engine.invalidateWatcherGap(rootEpoch: fixture.rootEpoch)
            case .checkout:
                await fixture.engine.invalidateCheckout(rootEpoch: fixture.rootEpoch)
            case .repository:
                await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
            }
            XCTAssertEqual(result, WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            ))
            guard case .failed = await registration.value else {
                return XCTFail("Expected \(kind) to fence capability registration.")
            }
            let accounting = await fixture.engine.accounting()
            XCTAssertEqual(accounting.rootCount, 0)
            XCTAssertEqual(accounting.eligibleRootCount, 0)
            let capability = await fixture.capabilityService.snapshotForTesting()
            XCTAssertEqual(capability.activeRecordCount, 0)
            XCTAssertEqual(capability.activeFlightCount, 0)
            XCTAssertEqual(capability.waiterCount, 0)
            XCTAssertEqual(capability.resolutionObserverCount, 1)
            await gate.release()
            await fixture.capabilityService.drain()
            let drainedCapability = await fixture.capabilityService.snapshotForTesting()
            XCTAssertEqual(drainedCapability.resolutionObserverCount, 0)
        }
    }

    func testUnloadDuringBlockedCapabilityRegistrationReleasesRootSlotImmediately() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Root.swift": SwiftFixtureSource.emptyStruct("Root")]
        )
        let gate = EngineFirstResolutionGate()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            ),
            policy: WorkspaceCodemapBindingEnginePolicy(maximumRootCount: 1),
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                beforeResolution: { await gate.enter() }
            )
        )
        let first = Task { await fixture.engine.registerRoot(fixture.registration) }
        _ = await gate.waitUntilFirstResolution()

        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
        guard case .failed = await first.value else {
            return XCTFail("Expected unloaded capability registration to fail without resolver cooperation.")
        }
        let unloadedAccounting = await fixture.engine.accounting()
        XCTAssertEqual(unloadedAccounting.rootCount, 0)
        let released = await fixture.capabilityService.snapshotForTesting()
        XCTAssertEqual(released.activeRecordCount, 0)
        XCTAssertEqual(released.activeFlightCount, 0)
        XCTAssertEqual(released.waiterCount, 0)
        XCTAssertEqual(released.historicalRecordCount, 1)

        let replacement = WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        guard case .registered = await fixture.engine.registerRoot(replacement) else {
            return XCTFail("Expected the synchronously released root slot to admit a replacement.")
        }
        let replacementAccounting = await fixture.engine.accounting()
        XCTAssertEqual(replacementAccounting.rootCount, 1)

        await gate.releaseFirstResolution()
        await fixture.capabilityService.drain()
        let finalCapability = await fixture.capabilityService.snapshotForTesting()
        XCTAssertEqual(finalCapability.activeRecordCount, 1)
        XCTAssertEqual(finalCapability.activeFlightCount, 0)
        XCTAssertEqual(finalCapability.waiterCount, 0)
        XCTAssertEqual(finalCapability.resolutionObserverCount, 0)
        XCTAssertEqual(finalCapability.historicalRecordCount, 1)
    }

    func testRequestReservationAndCancellationDuringValidatedReadReleaseExactlyOnce() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Dirty.swift": SwiftFixtureSource.emptyStruct("Dirty"),
                "Sources/Queued.swift": SwiftFixtureSource.emptyStruct("Queued")
            ]
        )
        let readGate = EngineBuildGate()
        let buildCounter = EngineAsyncCounter()
        let hookEvents = EngineHookEvents()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                return .readyNoSymbols
            })
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumActiveRequestCountPerRoot: 1,
                maximumActiveRequestCount: 1,
                maximumActiveTaskCountPerRoot: 1,
                maximumActiveTaskCount: 1,
                maximumConcurrentMaterializationCountPerRoot: 1,
                maximumConcurrentMaterializationCount: 1
            ),
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await readGate.enter()
                try Task.checkCancellation()
                throw FileSystemError.failedToReadFile
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        try repository.write("struct Dirty { let changed = true }\n", to: "Sources/Dirty.swift", at: root)
        let task = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Dirty.swift")) }
        _ = await readGate.waitUntilEntered()
        let queued = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Queued.swift")) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let gated = await fixture.engine.accounting()
        XCTAssertEqual(gated.activeRequestCount, 1)
        XCTAssertEqual(gated.counters.classifications, 1)
        task.cancel()
        await readGate.release()
        guard case .cancelled = await task.value else { return XCTFail("Expected read cancellation.") }
        guard case .ready = await queued.value else { return XCTFail("Expected queued request completion.") }
        for _ in 0 ..< 200 {
            if await fixture.engine.accounting().activeRequestCount == 0 {
                break
            }
            await Task.yield()
        }
        let buildCount = await buildCounter.value
        let accounting = await fixture.engine.accounting()
        let snapshot = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(accounting.activeRequestCount, 0)
        XCTAssertEqual(accounting.counters.classifications, 2)
        XCTAssertEqual(accounting.counters.cancellations, 1)
        XCTAssertEqual(hookEvents.count(kind: .cancellation), 1)
        XCTAssertEqual(hookEvents.numericTotal(kind: .cancellation), 1)
        XCTAssertFalse(try XCTUnwrap(snapshot).entries.contains {
            $0.standardizedRelativePath == "Sources/Dirty.swift"
        })
    }

    func testSourceAcquisitionFailureReleasesOverlayPreflightAndActiveRequest() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Failure.swift": SwiftFixtureSource.emptyStruct("Failure")]
        )
        try repository.write(
            "struct Failure { let dirty = true }\n",
            to: "Sources/Failure.swift",
            at: root
        )
        let overlay = WorkspaceCodemapLiveOverlay()
        let failingReader = WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
            throw POSIXError(.EIO)
        }
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            overlay: overlay,
            sourceReaderOverride: failingReader
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .unavailable(.transient) = await fixture.engine.demand(
            fixture.demand(path: "Sources/Failure.swift")
        ) else { return XCTFail("Expected typed acquisition failure.") }

        let engineAccounting = await fixture.engine.accounting()
        let overlayAccounting = await overlay.accounting()
        XCTAssertEqual(engineAccounting.activeRequestCount, 0)
        XCTAssertEqual(overlayAccounting.pendingEntryCount, 0)
        XCTAssertEqual(overlayAccounting.waiterCount, 0)
        XCTAssertEqual(overlayAccounting.admissionReservationCount, 0)
    }

    func testInvalidationFencesBlockedCompletionBeforeOverlayPublication() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Race.swift": SwiftFixtureSource.emptyStruct("Race")]
        )
        let buildGate = EngineBuildGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildGate.enter()
                return .readyNoSymbols
            })
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        let demand = Task { await fixture.engine.demand(fixture.demand(path: "Sources/Race.swift")) }
        _ = await buildGate.waitUntilEntered()
        let invalidation = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Race.swift"]
        )
        XCTAssertEqual(invalidation.cancelledRequestCount, 1)
        await buildGate.release()
        guard case .cancelled = await demand.value else { return XCTFail("Expected fenced completion.") }
        let bundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(try XCTUnwrap(bundle).entries.isEmpty)
        let firstInvalidationAccounting = await fixture.engine.accounting()
        XCTAssertEqual(firstInvalidationAccounting.activeRequestCount, 0)
        XCTAssertEqual(firstInvalidationAccounting.counters.cancellations, 1)
        _ = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Race.swift"]
        )
        let repeatedInvalidationAccounting = await fixture.engine.accounting()
        XCTAssertEqual(repeatedInvalidationAccounting.counters.cancellations, 1)
    }

    func testPathInvalidationDoesNotCancelUnrelatedActiveRequest() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Invalidated.swift": SwiftFixtureSource.emptyStruct("Invalidated"),
                "Sources/Unrelated.swift": SwiftFixtureSource.emptyStruct("Unrelated")
            ]
        )
        let sourceGate = EngineMultiEntryGate()
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
                maximumActiveRequestCountPerRoot: 2,
                maximumActiveRequestCount: 2,
                maximumActiveTaskCountPerRoot: 2,
                maximumActiveTaskCount: 2,
                maximumConcurrentMaterializationCountPerRoot: 2,
                maximumConcurrentMaterializationCount: 2
            ),
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient {
                identity, expected, maximumBytes, ownerID in
                await sourceGate.enter()
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
        try repository.write(
            "struct Invalidated { let dirty = true }\n",
            to: "Sources/Invalidated.swift",
            at: root
        )
        try repository.write(
            "struct Unrelated { let dirty = true }\n",
            to: "Sources/Unrelated.swift",
            at: root
        )
        let invalidated = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Invalidated.swift"))
        }
        let unrelated = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Unrelated.swift"))
        }
        _ = await sourceGate.waitUntilEntered(2)

        let invalidation = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Invalidated.swift"]
        )
        XCTAssertEqual(invalidation.cancelledRequestCount, 1)
        await sourceGate.releaseAll()

        guard case .cancelled = await invalidated.value else {
            return XCTFail("Expected only the invalidated path to cancel.")
        }
        guard case .ready = await unrelated.value else {
            return XCTFail("Expected the unrelated active request to remain current.")
        }
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.cancellations, 1)
        XCTAssertEqual(accounting.activeRequestCount, 0)
    }

    func testUnloadCancellationTelemetryCountsActiveRequestExactlyOnce() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Unload.swift": SwiftFixtureSource.emptyStruct("Unload")]
        )
        let buildGate = EngineBuildGate()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                    await buildGate.enter()
                    return .readyNoSymbols
                })
            )
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        let demand = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Unload.swift"))
        }
        await buildGate.waitUntilEntered()

        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
        await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
        await buildGate.release()
        guard case .cancelled = await demand.value else {
            return XCTFail("Expected unload to cancel the active request.")
        }
        let drained = await waitForEngineCondition {
            await fixture.engine.accounting().activeRequestCount == 0
        }
        XCTAssertTrue(drained)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.cancellations, 1)
    }
}
