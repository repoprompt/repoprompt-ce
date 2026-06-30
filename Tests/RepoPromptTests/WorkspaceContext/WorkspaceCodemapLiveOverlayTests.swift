import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapLiveOverlayTests: XCTestCase {
    func testOverlayBoundaryModelsHaveCheckedSendableContracts() {
        requireSendable(WorkspaceCodemapLiveOverlayPolicy.self)
        requireSendable(WorkspaceCodemapLiveDemandTicket.self)
        requireSendable(WorkspaceCodemapLiveDemandReservation.self)
        requireSendable(WorkspaceCodemapLiveManifestAdoptionTicket.self)
        requireSendable(WorkspaceCodemapLiveOverlayRegistrationDisposition.self)
        requireSendable(WorkspaceCodemapLiveDemandDisposition.self)
        requireSendable(WorkspaceCodemapLiveCompletionDisposition.self)
        requireSendable(WorkspaceCodemapLiveUnavailableDisposition.self)
        requireSendable(WorkspaceCodemapLiveManifestAdoptionDisposition.self)
        requireSendable(WorkspaceCodemapLiveManifestAdoptionEntry.self)
        requireSendable(WorkspaceCodemapLiveEntryStateSnapshot.self)
        requireSendable(WorkspaceCodemapLiveEntrySnapshot.self)
        requireSendable(WorkspaceCodemapLiveRootSnapshot.self)
        requireSendable(WorkspaceCodemapLiveReadySnapshot.self)
        requireSendable(WorkspaceCodemapLiveGraphSnapshot.self)
        requireSendable(WorkspaceCodemapLiveFrozenArtifactHandle.self)
        requireSendable(WorkspaceCodemapLiveOverlayRootAccounting.self)
        requireSendable(WorkspaceCodemapLiveOverlayAccounting.self)
    }

    func testCleanManifestBaselineRequiresExactCapabilityAuthorityAndCurrentNamespace() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Sources/Clean.swift": "struct Clean {}"]
        )
        defer { fixture.cleanup() }

        let clean = try await makeCleanReady(
            fixture: fixture,
            path: "Sources/Clean.swift",
            text: "struct Clean {}",
            fileID: uuid("10000000-0000-0000-0000-000000000001")
        )
        let manifest = try makeManifest(fixture: fixture, records: [clean.record])
        let adoption = try await fixture.overlay.adoptManifest(
            ticket: manifestTicket(fixture),
            snapshot: manifest,
            readyEntries: [clean.adoption]
        )
        assertEqualValue(adoption, .adopted(readyEntryCount: 1))

        let snapshotValue = await fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try unwrapValue(snapshotValue)
        assertEqualValue(snapshot.manifestGeneration, 1)
        assertEqualValue(snapshot.entries.count, 1)
        guard case let .ready(source, key, outcome) = snapshot.entries[0].state else {
            return XCTFail("Expected a ready clean binding.")
        }
        assertEqualValue(source, .cleanManifest)
        assertEqualValue(key, clean.completion.artifactKey)
        assertEqualValue(outcome, .ready)

        let wrongAuthority = repositoryAuthority(
            like: fixture.authority.capability.repositoryAuthority,
            authorityGeneration: fixture.authority.capability.repositoryAuthority.authorityGeneration + 1
        )
        let staleManifest = try CodeMapRootManifestSnapshot(
            namespace: fixture.namespace,
            authority: CodeMapRootManifestAuthority(namespace: fixture.namespace, token: wrongAuthority),
            manifestGeneration: 2,
            lastAccessEpochSeconds: 0,
            records: []
        )
        let staleAdoption = try await fixture.overlay.adoptManifest(
            ticket: manifestTicket(fixture),
            snapshot: staleManifest,
            readyEntries: []
        )
        assertEqualValue(staleAdoption, .rejected(.authorityMismatch))
    }

    func testDirtyPendingAndReadyShadowCleanUntilExplicitManifestRevalidation() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Sources/Shadow.swift": "struct Shadow {}"]
        )
        defer { fixture.cleanup() }
        let fileID = uuid("20000000-0000-0000-0000-000000000001")
        let clean = try await makeCleanReady(
            fixture: fixture,
            path: "Sources/Shadow.swift",
            text: "struct Shadow {}",
            fileID: fileID
        )
        let manifest = try makeManifest(fixture: fixture, records: [clean.record])
        _ = try await fixture.overlay.adoptManifest(
            ticket: manifestTicket(fixture),
            snapshot: manifest,
            readyEntries: [clean.adoption]
        )

        let dirty = try await makeWorktreeReady(
            fixture: fixture,
            path: "Sources/Shadow.swift",
            fileID: fileID,
            requestGeneration: 2,
            artifactName: "Clean"
        )
        let ticket = try await startedTicket(fixture.overlay.beginDemand(
            owner: WorkspaceCodemapLiveDemandOwner(),
            token: dirty.token
        ))
        let pendingValue = await fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch)
        let pending = try unwrapValue(pendingValue)
        assertEqualValue(pending.entries.count, 1)
        guard case .pending = pending.entries[0].state else {
            return XCTFail("Pending live state must shadow the clean baseline.")
        }

        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: dirty.completion,
            lease: dirty.lease
        ))
        let readyValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        let ready = try unwrapValue(readyValue)
        assertEqualValue(ready.entries.map(\.source), [.live])

        let invalidated = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Shadow.swift"],
            reason: .modified
        )
        assertEqualValue(invalidated, 1)
        let revokedValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        try assertTrueValue(unwrapValue(revokedValue).entries.isEmpty)

        let freshLease = try await fixture.artifactStore.lease(handle: clean.handle)
        let revalidation = try await fixture.overlay.adoptManifest(
            ticket: manifestTicket(fixture),
            snapshot: manifest,
            readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry(
                record: clean.record,
                binding: clean.binding,
                lease: freshLease
            )]
        )
        assertEqualValue(revalidation, .adopted(readyEntryCount: 1))
        let revalidatedValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        try assertEqualValue(unwrapValue(revalidatedValue).entries.map(\.source), [.cleanManifest])
    }

    func testRenameRevokesBothOldAndDestinationPathsSynchronously() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "Old.swift": "struct Old {}",
                "Destination.swift": "struct Destination {}"
            ]
        )
        defer { fixture.cleanup() }
        let old = try await makeWorktreeReady(
            fixture: fixture,
            path: "Old.swift",
            requestGeneration: 1,
            artifactName: "Old"
        )
        let destination = try await makeWorktreeReady(
            fixture: fixture,
            path: "Destination.swift",
            requestGeneration: 1,
            artifactName: "Destination"
        )
        let oldTicket = try await startedTicket(fixture.overlay.beginDemand(
            owner: .init(),
            token: old.token
        ))
        let destinationTicket = try await startedTicket(fixture.overlay.beginDemand(
            owner: .init(),
            token: destination.token
        ))
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: oldTicket,
            completion: old.completion,
            lease: old.lease
        ))
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: destinationTicket,
            completion: destination.completion,
            lease: destination.lease
        ))

        let invalidated = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Old.swift", "Destination.swift"],
            reason: .renamed
        )
        assertEqualValue(invalidated, 2)
        let snapshotValue = await fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try unwrapValue(snapshotValue)
        assertEqualValue(snapshot.entries.count, 2)
        assertTrueValue(snapshot.entries.allSatisfy {
            if case .shadowed(.renamed) = $0.state { true } else { false }
        })
        let graphValue = await fixture.overlay.graphContributions(rootEpoch: fixture.rootEpoch)
        try assertTrueValue(unwrapValue(graphValue).bindings.isEmpty)
    }

    func testCheckoutAndAuthorityInvalidationFencePendingCompletionAndPermitExplicitRebind() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Authority.swift": "struct Authority {}"]
        )
        defer { fixture.cleanup() }
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "Authority.swift",
            requestGeneration: 1,
            artifactName: "Authority"
        )
        let ticket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: ready.token))
        let invalidated = await fixture.overlay.invalidateRootAuthority(
            rootEpoch: fixture.rootEpoch,
            expectedAuthority: fixture.authority.capability.repositoryAuthority,
            reason: .checkoutChanged
        )
        assertTrueValue(invalidated)
        guard case .rejected(.rootAuthorityInvalid) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: ready.completion,
            lease: ready.lease
        ) else { return XCTFail("Checkout invalidation must reject the old completion.") }

        let reboundAuthority = repositoryAuthority(
            like: fixture.authority.capability.repositoryAuthority,
            authorityGeneration: fixture.authority.capability.repositoryAuthority.authorityGeneration + 1
        )
        let reboundCapability = capability(
            like: fixture.authority.capability,
            repositoryAuthority: reboundAuthority
        )
        let registration = await fixture.overlay.register(
            capability: .eligible(reboundCapability),
            catalogGeneration: fixture.catalogGeneration + 1
        )
        assertEqualValue(registration, .registered)
        let reboundValue = await fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch)
        let rebound = try unwrapValue(reboundValue)
        assertTrueValue(rebound.authorityIsCurrent)
        assertEqualValue(rebound.catalogGeneration, fixture.catalogGeneration + 1)
        assertTrueValue(rebound.entries.isEmpty)
    }

    func testStaleCompletionMatrixDropsReplacedInvalidatedAndUnloadedRequests() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Stale.swift": "struct Stale {}"]
        )
        defer { fixture.cleanup() }
        let fileID = uuid("50000000-0000-0000-0000-000000000001")
        let first = try await makeWorktreeReady(
            fixture: fixture,
            path: "Stale.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Stale"
        )
        let second = try await makeWorktreeReady(
            fixture: fixture,
            path: "Stale.swift",
            fileID: fileID,
            requestGeneration: 2,
            artifactName: "Stale"
        )
        let firstTicket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: first.token))
        _ = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: second.token))
        guard case .rejected(.staleTicket) = await fixture.overlay.acceptCompletion(
            ticket: firstTicket,
            completion: first.completion,
            lease: first.lease
        ) else { return XCTFail("A replaced request must be stale.") }

        _ = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Stale.swift"],
            reason: .watcherGap
        )
        let secondLease = try await fixture.artifactStore.lease(handle: second.handle)
        let secondTicket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: second.token))
        _ = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Stale.swift"],
            reason: .modified
        )
        guard case .rejected(.pendingRequestMissing) = await fixture.overlay.acceptCompletion(
            ticket: secondTicket,
            completion: second.completion,
            lease: secondLease
        ) else { return XCTFail("Path invalidation must remove pending authority.") }

        let thirdLease = try await fixture.artifactStore.lease(handle: second.handle)
        let thirdTicket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: second.token))
        let unloaded = await fixture.overlay.unregister(rootEpoch: fixture.rootEpoch)
        assertTrueValue(unloaded)
        guard case .rejected(.rootNotRegistered) = await fixture.overlay.acceptCompletion(
            ticket: thirdTicket,
            completion: second.completion,
            lease: thirdLease
        ) else { return XCTFail("Root unload must fence pending completion.") }

        let accounting = await fixture.overlay.accounting()
        XCTAssertGreaterThanOrEqual(accounting.staleCompletionDropCount, 3)
        await first.lease.close()
        await second.lease.close()
        await secondLease.close()
        await thirdLease.close()
    }

    func testRootUnloadIsIsolatedAndSameArtifactCanBeLeasedByTwoRoots() async throws {
        let sharedArtifactRootOwner = try await makeRootFixture(
            name: #function + "-one",
            files: ["Shared.swift": "struct Shared {}"]
        )
        defer { sharedArtifactRootOwner.cleanup() }
        let second = try await makeRootFixture(
            name: #function + "-two",
            files: ["Shared.swift": "struct Shared {}"],
            overlay: sharedArtifactRootOwner.overlay,
            artifactStore: sharedArtifactRootOwner.artifactStore
        )
        defer { second.cleanup() }

        let firstReady = try await makeWorktreeReady(
            fixture: sharedArtifactRootOwner,
            path: "Shared.swift",
            requestGeneration: 1,
            artifactName: "Shared"
        )
        let secondReady = try await makeWorktreeReady(
            fixture: second,
            path: "Shared.swift",
            requestGeneration: 1,
            artifactName: "Shared"
        )
        assertEqualValue(firstReady.completion.artifactKey, secondReady.completion.artifactKey)
        let firstTicket = try await startedTicket(sharedArtifactRootOwner.overlay.beginDemand(
            owner: .init(),
            token: firstReady.token
        ))
        let secondTicket = try await startedTicket(second.overlay.beginDemand(
            owner: .init(),
            token: secondReady.token
        ))
        _ = try await acceptedReady(sharedArtifactRootOwner.overlay.acceptCompletion(
            ticket: firstTicket,
            completion: firstReady.completion,
            lease: firstReady.lease
        ))
        _ = try await acceptedReady(second.overlay.acceptCompletion(
            ticket: secondTicket,
            completion: secondReady.completion,
            lease: secondReady.lease
        ))
        let beforeUnload = await sharedArtifactRootOwner.overlay.accounting()
        assertEqualValue(beforeUnload.leaseCount, 2)

        let firstUnloaded = await sharedArtifactRootOwner.overlay.unregister(
            rootEpoch: sharedArtifactRootOwner.rootEpoch
        )
        assertTrueValue(firstUnloaded)
        let firstSnapshot = await sharedArtifactRootOwner.overlay.snapshot(
            rootEpoch: sharedArtifactRootOwner.rootEpoch
        )
        assertNilValue(firstSnapshot)
        let secondBundleValue = await second.overlay.freeze(rootEpoch: second.rootEpoch)
        try assertEqualValue(unwrapValue(secondBundleValue).entries.count, 1)
        let afterUnload = await second.overlay.accounting()
        assertEqualValue(afterUnload.rootCount, 1)
    }

    func testFrozenBundleLeaseSurvivesEvictionAndRootUnloadThenReleasesOnBundleLifecycle() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Lease.swift": "struct Lease {}"]
        )
        defer { fixture.cleanup() }
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "Lease.swift",
            requestGeneration: 1,
            artifactName: "Lease"
        )
        let ticket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: ready.token))
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: ready.completion,
            lease: ready.lease
        ))
        let bundleValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        let bundle = try unwrapValue(bundleValue)
        let leasedAccounting = await fixture.artifactStore.accounting()
        assertEqualValue(leasedAccounting.activeLeaseCount, 1)

        let unloaded = await fixture.overlay.unregister(rootEpoch: fixture.rootEpoch)
        assertTrueValue(unloaded)
        let retainedAccounting = await fixture.artifactStore.accounting()
        assertEqualValue(retainedAccounting.activeLeaseCount, 1)
        assertEqualValue(bundle.entries.first?.artifactKey, ready.completion.artifactKey)
        let frozenHandle = try XCTUnwrap(try bundle.handle(for: ready.token.identity.fileID))
        XCTAssertEqual(try frozenHandle.artifactKey(), ready.completion.artifactKey)
        XCTAssertEqual(try bundle.snapshot().count, 1)
        XCTAssertEqual(try bundle.graphSnapshot().bindings.count, 1)
        XCTAssertNotNil(try bundle.renderedCodemap(
            for: ready.token.identity.fileID,
            displayPath: "Logical/Lease.swift"
        ))

        bundle.close()
        bundle.close()
        XCTAssertTrue(bundle.isClosed)
        XCTAssertTrue(bundle.entries.isEmpty)
        XCTAssertThrowsError(try bundle.snapshot()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        XCTAssertThrowsError(try bundle.graphSnapshot()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        XCTAssertThrowsError(try bundle.handle(for: ready.token.identity.fileID)) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        XCTAssertThrowsError(try bundle.renderedCodemap(
            for: ready.token.identity.fileID,
            displayPath: "Logical/Lease.swift"
        )) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        XCTAssertThrowsError(try frozenHandle.artifactKey()) {
            XCTAssertEqual($0 as? WorkspaceCodemapLiveOverlayBundleAccessError, .closed)
        }
        let releasedAccounting = await fixture.artifactStore.accounting()
        assertEqualValue(releasedAccounting.activeLeaseCount, 0)
        assertEqualValue(releasedAccounting.activeLeaseBytes, 0)
    }

    func testFrozenBundleConcurrentCloseAndReadIsLinearizableAndReleasesExactlyOnce() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Concurrent.swift": "struct Concurrent {}"]
        )
        defer { fixture.cleanup() }
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "Concurrent.swift",
            requestGeneration: 1,
            artifactName: "Concurrent"
        )
        let ticket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: ready.token)
        )
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: ready.completion,
            lease: ready.lease
        ))
        let bundle = try await unwrapValue(fixture.overlay.freeze(rootEpoch: fixture.rootEpoch))
        let fileID = ready.token.identity.fileID
        await assertTrueValue(fixture.overlay.unregister(rootEpoch: fixture.rootEpoch))

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    do {
                        guard try bundle.snapshot().count == 1,
                              let handle = try bundle.handle(for: fileID),
                              try handle.artifactKey() == ready.completion.artifactKey
                        else { return false }
                        _ = try handle.renderedCodemap(displayPath: "Logical/Concurrent.swift")
                        return true
                    } catch let error as WorkspaceCodemapLiveOverlayBundleAccessError {
                        return error == .closed
                    } catch {
                        return false
                    }
                }
            }
            group.addTask {
                bundle.close()
                bundle.close()
                return true
            }
            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        XCTAssertTrue(results.allSatisfy(\.self))
        XCTAssertTrue(bundle.isClosed)
        XCTAssertTrue(bundle.entries.isEmpty)
        let accounting = await fixture.artifactStore.accounting()
        XCTAssertEqual(accounting.activeLeaseCount, 0)
        XCTAssertEqual(accounting.activeLeaseBytes, 0)
    }

    func testFrozenBundleRemainsInternallyConsistentAcrossReplacement() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Frozen.swift": "struct Frozen {}"]
        )
        defer { fixture.cleanup() }
        let fileID = uuid("80000000-0000-0000-0000-000000000001")
        let first = try await makeWorktreeReady(
            fixture: fixture,
            path: "Frozen.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Frozen"
        )
        let firstTicket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: first.token))
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: firstTicket,
            completion: first.completion,
            lease: first.lease
        ))
        let frozenValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        let frozen = try unwrapValue(frozenValue)

        let replacement = try await makeWorktreeReady(
            fixture: fixture,
            path: "Frozen.swift",
            fileID: fileID,
            requestGeneration: 2,
            artifactName: "Frozen"
        )
        let replacementTicket = try await startedTicket(fixture.overlay.beginDemand(
            owner: .init(),
            token: replacement.token
        ))
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: replacementTicket,
            completion: replacement.completion,
            lease: replacement.lease
        ))
        let currentValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        let current = try unwrapValue(currentValue)

        assertEqualValue(frozen.entries.map(\.requestGeneration), [1])
        assertEqualValue(current.entries.map(\.requestGeneration), [2])
        XCTAssertLessThan(frozen.contributionGeneration, current.contributionGeneration)
        XCTAssertNotNil(try frozen.renderedCodemap(
            for: fileID,
            displayPath: "Logical/Frozen.swift"
        ))
    }

    func testGraphSnapshotEmitsOnlyCurrentReadyBindings() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "Ready.swift": "struct Ready {}",
                "Pending.swift": "struct Pending {}",
                "Unavailable.swift": "struct Unavailable {}"
            ]
        )
        defer { fixture.cleanup() }
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "Ready.swift",
            requestGeneration: 1,
            artifactName: "Ready"
        )
        let pending = try await makeWorktreeReady(
            fixture: fixture,
            path: "Pending.swift",
            requestGeneration: 1,
            artifactName: "Pending"
        )
        let readyTicket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: ready.token))
        _ = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: pending.token))
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: readyTicket,
            completion: ready.completion,
            lease: ready.lease
        ))
        let unavailable = try await makeWorktreeReady(
            fixture: fixture,
            path: "Unavailable.swift",
            requestGeneration: 1,
            artifactName: "Unavailable"
        )
        let unavailableTicket = try await startedTicket(fixture.overlay.beginDemand(
            owner: .init(),
            token: unavailable.token
        ))
        let unavailableSet = await fixture.overlay.setUnavailable(
            ticket: unavailableTicket,
            reason: .transient
        )
        assertEqualValue(unavailableSet, .accepted)
        await unavailable.lease.close()

        let graphValue = await fixture.overlay.graphContributions(rootEpoch: fixture.rootEpoch)
        let graph = try unwrapValue(graphValue)
        assertEqualValue(graph.bindings.count, 1)
        assertEqualValue(graph.bindings[0].identity.fileID, ready.token.identity.fileID)
        let store = try unwrapValue(WorkspaceCodemapSelectionGraphModelStore.authorized(
            by: graph.bindings[0],
            contributionGeneration: graph.contributionGeneration
        ))
        guard case .accepted = store.accept(graph.bindings[0]) else {
            return XCTFail("Emitted graph binding must be directly consumable by the graph model.")
        }
    }

    func testBoundsApplyBusyWaiterPolicyAndEvictActorOwnershipWithoutBreakingFrozenHandle() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 1,
            maximumEntryCount: 1,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 1,
            maximumWaiterCount: 1,
            maximumLeaseCountPerRoot: 1,
            maximumLeaseCount: 1,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "First.swift": "struct First {}",
                "Second.swift": "struct Second {}"
            ],
            policy: policy
        )
        defer { fixture.cleanup() }
        let first = try await makeWorktreeReady(
            fixture: fixture,
            path: "First.swift",
            requestGeneration: 1,
            artifactName: "First"
        )
        let firstTicket = try await startedTicket(fixture.overlay.beginDemand(
            owner: .init(rawValue: uuid("A0000000-0000-0000-0000-000000000001")),
            token: first.token
        ))
        let queuedOwner = WorkspaceCodemapLiveDemandOwner(
            rawValue: uuid("A0000000-0000-0000-0000-000000000002")
        )
        guard case let .queued(waiterReservation) = await fixture.overlay.beginDemand(
            owner: queuedOwner,
            token: first.token
        ) else { return XCTFail("Second waiter must receive a bounded reservation.") }
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: firstTicket,
            completion: first.completion,
            lease: first.lease
        ))
        guard case .ready = await fixture.overlay.resumeDemand(
            owner: queuedOwner,
            reservation: waiterReservation
        ) else { return XCTFail("The reserved waiter must observe the completed ready value.") }
        let frozenValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        let frozen = try unwrapValue(frozenValue)

        let second = try await makeWorktreeReady(
            fixture: fixture,
            path: "Second.swift",
            requestGeneration: 1,
            artifactName: "Second"
        )
        _ = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: second.token))
        let accounting = await fixture.overlay.accounting()
        assertEqualValue(accounting.entryCount, 1)
        assertEqualValue(accounting.pendingEntryCount, 1)
        assertEqualValue(accounting.evictionCount, 1)
        assertEqualValue(accounting.admissionReservationCount, 0)
        assertEqualValue(frozen.entries[0].artifactKey, first.completion.artifactKey)
    }

    func testAdmissionReservationsAreBoundedFIFOAndReclaimedByCancellationAndUnload() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 1,
            maximumEntryCount: 1,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 1,
            maximumWaiterCount: 1,
            maximumLeaseCountPerRoot: 1,
            maximumLeaseCount: 1,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max,
            maximumAdmissionReservationCountPerRoot: 3,
            maximumAdmissionReservationCount: 3
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["FIFO.swift": "struct FIFO {}"],
            policy: policy
        )
        defer { fixture.cleanup() }
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "FIFO.swift",
            requestGeneration: 1,
            artifactName: "FIFO"
        )
        let firstOwner = WorkspaceCodemapLiveDemandOwner()
        let secondOwner = WorkspaceCodemapLiveDemandOwner()
        let thirdOwner = WorkspaceCodemapLiveDemandOwner()
        let fourthOwner = WorkspaceCodemapLiveDemandOwner()
        let firstTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: firstOwner, token: ready.token)
        )
        guard case let .queued(secondReservation) = await fixture.overlay.beginDemand(
            owner: secondOwner,
            token: ready.token
        ) else { return XCTFail("The first saturated newcomer must reserve the FIFO head.") }
        guard case let .queued(thirdReservation) = await fixture.overlay.beginDemand(
            owner: thirdOwner,
            token: ready.token
        ) else { return XCTFail("The next newcomer must reserve behind the FIFO head.") }
        guard case let .queued(stillThirdReservation) = await fixture.overlay.resumeDemand(
            owner: thirdOwner,
            reservation: thirdReservation
        ) else { return XCTFail("A later reservation must not race past the FIFO head.") }
        assertEqualValue(stillThirdReservation, thirdReservation)

        await assertTrueValue(fixture.overlay.cancelDemand(owner: firstOwner, ticket: firstTicket))
        let secondTicket = try await startedTicket(fixture.overlay.resumeDemand(
            owner: secondOwner,
            reservation: secondReservation
        ))
        guard case let .queued(waitingThirdReservation) = await fixture.overlay.resumeDemand(
            owner: thirdOwner,
            reservation: thirdReservation
        ) else { return XCTFail("The second reservation must wait for the admitted head owner.") }
        assertEqualValue(waitingThirdReservation, thirdReservation)
        await assertTrueValue(fixture.overlay.cancelDemand(owner: secondOwner, ticket: secondTicket))
        let thirdTicket = try await startedTicket(fixture.overlay.resumeDemand(
            owner: thirdOwner,
            reservation: thirdReservation
        ))
        guard case let .queued(fourthReservation) = await fixture.overlay.beginDemand(
            owner: fourthOwner,
            token: ready.token
        ) else { return XCTFail("Saturated demand must continue to use the bounded queue.") }
        await assertEqualValue((fixture.overlay.accounting()).admissionReservationCount, 1)

        await assertTrueValue(fixture.overlay.unregister(rootEpoch: fixture.rootEpoch))
        await assertEqualValue((fixture.overlay.accounting()).admissionReservationCount, 0)
        guard case .rejected(.admissionReservationInvalid) = await fixture.overlay.resumeDemand(
            owner: fourthOwner,
            reservation: fourthReservation
        ) else { return XCTFail("Root unload must revoke and reclaim queued reservations.") }
        await assertFalseValue(fixture.overlay.cancelDemand(owner: thirdOwner, ticket: thirdTicket))
        await ready.lease.close()
    }

    func testSnapshotsAndBundlesDoNotExposePhysicalRootOrSourceBytes() async throws {
        let secretSource = "struct SourceBodyMustNotLeak_7F47C9 {}"
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Nested/Leak.swift": secretSource]
        )
        defer { fixture.cleanup() }
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "Nested/Leak.swift",
            requestGeneration: 1,
            artifactName: "Leak"
        )
        let ticket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: ready.token))
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: ready.completion,
            lease: ready.lease
        ))
        let snapshotValue = await fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try unwrapValue(snapshotValue)
        let bundleValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        let bundle = try unwrapValue(bundleValue)
        let exposed = String(reflecting: snapshot) + String(reflecting: bundle.entries)
        assertFalseValue(exposed.contains(fixture.authority.loadedRoot.path))
        assertFalseValue(exposed.contains(secretSource))
        assertFalseValue(exposed.contains("CodeMapArtifactHandle"))
        assertEqualValue(bundle.entries.map(\.standardizedRelativePath), ["Nested/Leak.swift"])

        let terminalOutcomes: [WorkspaceCodemapLiveArtifactOutcome] = [
            .ready, .readyNoSymbols, .oversize, .decodeFailed, .parseFailed
        ]
        let invalidationReasons: [WorkspaceCodemapLiveOverlayInvalidationReason] = [
            .modified, .deleted, .renamed, .watcherGap, .checkoutChanged,
            .authorityChanged, .catalogChanged, .evicted
        ]
        let allUnavailableReasons: [WorkspaceCodemapLiveOverlayUnavailableReason] = [
            .unsupportedFileType, .transient, .securityExcluded
        ] + terminalOutcomes.map(WorkspaceCodemapLiveOverlayUnavailableReason.terminalArtifact) +
            invalidationReasons.map(WorkspaceCodemapLiveOverlayUnavailableReason.invalidated)
        XCTAssertEqual(allUnavailableReasons.count, 16)
        for reason in allUnavailableReasons {
            let reflected = String(reflecting: reason)
            assertFalseValue(reflected.contains(fixture.authority.loadedRoot.path))
            assertFalseValue(reflected.contains(secretSource))
            assertFalseValue(reflected.contains("/"))
        }
    }

    func testTerminalCompletionBecomesUnavailableAndNeverEmitsGraphContribution() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Terminal.swift": "struct Terminal {}"]
        )
        defer { fixture.cleanup() }
        let terminal = try await makeWorktreeReady(
            fixture: fixture,
            path: "Terminal.swift",
            requestGeneration: 1,
            artifactName: "Terminal",
            outcome: .oversize(.utf8Bytes(actual: 1000, limit: 100))
        )
        let ticket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: terminal.token))
        guard case .acceptedUnavailable(.oversize) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: terminal.completion,
            lease: terminal.lease
        ) else { return XCTFail("Terminal artifact must publish unavailable state.") }
        let snapshotValue = await fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try unwrapValue(snapshotValue)
        guard case .unavailable(.terminalArtifact(.oversize)) = snapshot.entries.first?.state else {
            return XCTFail("Expected terminal unavailable snapshot.")
        }
        let bundleValue = await fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
        try assertTrueValue(unwrapValue(bundleValue).entries.isEmpty)
        let graphValue = await fixture.overlay.graphContributions(rootEpoch: fixture.rootEpoch)
        try assertTrueValue(unwrapValue(graphValue).bindings.isEmpty)
    }

    func testCompletionValidationAndBusyAdmissionRemainRetryable() async throws {
        let fixture = try await makeRootFixture(
            name: #function + "-validation",
            files: [
                "Target.swift": "struct Target {}",
                "Other.swift": "struct Other {}"
            ]
        )
        defer { fixture.cleanup() }
        let fileID = uuid("B0000000-0000-0000-0000-000000000001")
        let target = try await makeWorktreeReady(
            fixture: fixture,
            path: "Target.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Target"
        )
        let mismatched = try await makeWorktreeReady(
            fixture: fixture,
            path: "Target.swift",
            fileID: fileID,
            requestGeneration: 2,
            artifactName: "Target",
            pathGeneration: 1,
            ingressGeneration: 1
        )
        let other = try await makeWorktreeReady(
            fixture: fixture,
            path: "Other.swift",
            requestGeneration: 1,
            artifactName: "Other"
        )
        let ticket = try await startedTicket(fixture.overlay.beginDemand(owner: .init(), token: target.token))
        guard case .rejected(.binding(.requestGenerationMismatch)) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: mismatched.completion,
            lease: mismatched.lease
        ) else { return XCTFail("A mismatched completion must not consume the pending binding.") }
        guard case .rejected(.artifactHandleMismatch) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: target.completion,
            lease: other.lease
        ) else { return XCTFail("A wrong handle must leave the pending binding retryable.") }
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: target.completion,
            lease: target.lease
        ))
        await mismatched.lease.close()
        await other.lease.close()

        let busyPolicy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 4,
            maximumEntryCount: 4,
            maximumWaiterCountPerEntry: 2,
            maximumWaiterCountPerRoot: 4,
            maximumWaiterCount: 4,
            maximumLeaseCountPerRoot: 1,
            maximumLeaseCount: 1,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )
        let busyFixture = try await makeRootFixture(
            name: #function + "-busy",
            files: [
                "Blocker.swift": "struct Blocker {}",
                "Retry.swift": "struct Retry {}"
            ],
            policy: busyPolicy
        )
        defer { busyFixture.cleanup() }
        let blocker = try await makeWorktreeReady(
            fixture: busyFixture,
            path: "Blocker.swift",
            requestGeneration: 1,
            artifactName: "Blocker"
        )
        let blockerTicket = try await startedTicket(
            busyFixture.overlay.beginDemand(owner: .init(), token: blocker.token)
        )
        _ = try await acceptedReady(busyFixture.overlay.acceptCompletion(
            ticket: blockerTicket,
            completion: blocker.completion,
            lease: blocker.lease
        ))
        let retry = try await makeWorktreeReady(
            fixture: busyFixture,
            path: "Retry.swift",
            requestGeneration: 1,
            artifactName: "Retry"
        )
        let retryTicket = try await startedTicket(
            busyFixture.overlay.beginDemand(owner: .init(), token: retry.token)
        )
        guard case .busy(.leaseLimit) = await busyFixture.overlay.acceptCompletion(
            ticket: retryTicket,
            completion: retry.completion,
            lease: retry.lease
        ) else { return XCTFail("Saturated lease admission must report busy.") }
        _ = await busyFixture.overlay.invalidatePaths(
            rootEpoch: busyFixture.rootEpoch,
            standardizedRelativePaths: ["Blocker.swift"],
            reason: .modified
        )
        _ = try await acceptedReady(busyFixture.overlay.acceptCompletion(
            ticket: retryTicket,
            completion: retry.completion,
            lease: retry.lease
        ))
    }

    func testManifestGenerationIsMonotonicAndExactDuplicateIsNonMutating() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Manifest.swift": "struct Manifest {}"]
        )
        defer { fixture.cleanup() }
        let clean = try await makeCleanReady(
            fixture: fixture,
            path: "Manifest.swift",
            text: "struct Manifest {}",
            fileID: uuid("B1000000-0000-0000-0000-000000000001")
        )
        let generationTwo = try makeManifest(
            fixture: fixture,
            records: [clean.record],
            generation: 2
        )
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: generationTwo,
                readyEntries: [clean.adoption]
            ),
            .adopted(readyEntryCount: 1)
        )
        let beforeDuplicate = try await unwrapValue(fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch))
        let duplicateLease = try await fixture.artifactStore.lease(handle: clean.handle)
        let sameContent = try makeManifest(
            fixture: fixture,
            records: [clean.record],
            generation: 2,
            lastAccessEpochSeconds: 99
        )
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: sameContent,
                readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry(
                    record: clean.record,
                    binding: clean.binding,
                    lease: duplicateLease
                )]
            ),
            .exactDuplicate(readyEntryCount: 1)
        )
        let afterDuplicate = try await unwrapValue(fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch))
        assertEqualValue(afterDuplicate.contributionGeneration, beforeDuplicate.contributionGeneration)
        await duplicateLease.close()

        let older = try makeManifest(fixture: fixture, records: [clean.record], generation: 1)
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: older,
                readyEntries: [clean.adoption]
            ),
            .rejected(.staleManifestGeneration)
        )
        let conflicting = try makeManifest(fixture: fixture, records: [], generation: 2)
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: conflicting,
                readyEntries: []
            ),
            .rejected(.manifestGenerationConflict)
        )
        let newer = try makeManifest(fixture: fixture, records: [], generation: 3)
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: newer,
                readyEntries: []
            ),
            .adopted(readyEntryCount: 0)
        )
    }

    func testManifestAdoptionPreflightsRecordBytesEntriesAndLeasesBeforeValidation() async throws {
        let equalityProbe = ManifestRecordEqualityTraversalProbe()
        let recordLimitedPolicy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 4,
            maximumEntryCount: 4,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 1,
            maximumWaiterCount: 1,
            maximumLeaseCountPerRoot: 1,
            maximumLeaseCount: 1,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max,
            maximumManifestRecordCount: 1,
            maximumManifestEstimatedByteCount: .max
        )
        let recordOverlay = WorkspaceCodemapLiveOverlay(
            policy: recordLimitedPolicy,
            manifestRecordEqualityTraversal: equalityProbe.recordTraversal
        )
        let recordFixture = try await makeRootFixture(
            name: #function + "-records",
            files: ["A.swift": "struct A {}", "B.swift": "struct B {}"],
            policy: recordLimitedPolicy,
            overlay: recordOverlay
        )
        defer { recordFixture.cleanup() }
        let recordA = try await makeCleanReady(
            fixture: recordFixture,
            path: "A.swift",
            text: "struct A {}",
            fileID: uuid("B2200000-0000-0000-0000-000000000001")
        )
        let recordB = try await makeCleanReady(
            fixture: recordFixture,
            path: "B.swift",
            text: "struct B {}",
            fileID: uuid("B2200000-0000-0000-0000-000000000002")
        )
        let currentManifest = try makeManifest(
            fixture: recordFixture,
            records: [recordA.record],
            generation: 7
        )
        try await assertEqualValue(
            recordFixture.overlay.adoptManifest(
                ticket: manifestTicket(recordFixture),
                snapshot: currentManifest,
                readyEntries: [recordA.adoption]
            ),
            .adopted(readyEntryCount: 1)
        )
        assertEqualValue(equalityProbe.traversalCount, 0)

        let oversizedSameGeneration = try makeManifest(
            fixture: recordFixture,
            records: [recordA.record, recordB.record],
            generation: 7
        )
        try await assertEqualValue(
            recordFixture.overlay.adoptManifest(
                ticket: manifestTicket(recordFixture),
                snapshot: oversizedSameGeneration,
                readyEntries: [recordB.adoption]
            ),
            .busy(.manifestLimit)
        )
        assertEqualValue(equalityProbe.traversalCount, 0)
        await assertEqualValue((recordFixture.overlay.accounting()).entryCount, 1)
        await recordB.adoption.lease.close()

        let rejectedLeaseA = try await recordFixture.artifactStore.lease(handle: recordA.handle)
        let rejectedLeaseB = try await recordFixture.artifactStore.lease(handle: recordA.handle)
        let duplicateAdoptionA = WorkspaceCodemapLiveManifestAdoptionEntry(
            record: recordA.record,
            binding: recordA.binding,
            lease: rejectedLeaseA
        )
        let duplicateAdoptionB = WorkspaceCodemapLiveManifestAdoptionEntry(
            record: recordA.record,
            binding: recordA.binding,
            lease: rejectedLeaseB
        )
        try await assertEqualValue(
            recordFixture.overlay.adoptManifest(
                ticket: manifestTicket(recordFixture),
                snapshot: currentManifest,
                readyEntries: [duplicateAdoptionA, duplicateAdoptionB]
            ),
            .busy(.leaseLimit)
        )
        assertEqualValue(equalityProbe.traversalCount, 0)
        await rejectedLeaseA.close()
        await rejectedLeaseB.close()

        let duplicateLease = try await recordFixture.artifactStore.lease(handle: recordA.handle)
        try await assertEqualValue(
            recordFixture.overlay.adoptManifest(
                ticket: manifestTicket(recordFixture),
                snapshot: currentManifest,
                readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry(
                    record: recordA.record,
                    binding: recordA.binding,
                    lease: duplicateLease
                )]
            ),
            .exactDuplicate(readyEntryCount: 1)
        )
        assertEqualValue(equalityProbe.traversalCount, 1)
        await duplicateLease.close()

        let byteLimitedPolicy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 1,
            maximumEntryCount: 1,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 1,
            maximumWaiterCount: 1,
            maximumLeaseCountPerRoot: 1,
            maximumLeaseCount: 1,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max,
            maximumManifestRecordCount: 1,
            maximumManifestEstimatedByteCount: 1
        )
        let byteFixture = try await makeRootFixture(
            name: #function + "-bytes",
            files: ["Byte.swift": "struct Byte {}"],
            policy: byteLimitedPolicy
        )
        defer { byteFixture.cleanup() }
        let byteEntry = try await makeCleanReady(
            fixture: byteFixture,
            path: "Byte.swift",
            text: "struct Byte {}",
            fileID: uuid("B2200000-0000-0000-0000-000000000003")
        )
        try await assertEqualValue(
            byteFixture.overlay.adoptManifest(
                ticket: manifestTicket(byteFixture),
                snapshot: makeManifest(fixture: byteFixture, records: [byteEntry.record]),
                readyEntries: [byteEntry.adoption]
            ),
            .busy(.manifestLimit)
        )
        await assertEqualValue((byteFixture.overlay.accounting()).entryCount, 0)
        await byteEntry.adoption.lease.close()

        let entryLimitedPolicy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 1,
            maximumEntryCount: 1,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 1,
            maximumWaiterCount: 1,
            maximumLeaseCountPerRoot: 2,
            maximumLeaseCount: 2,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max,
            maximumManifestRecordCount: 2,
            maximumManifestEstimatedByteCount: .max
        )
        let entryFixture = try await makeRootFixture(
            name: #function + "-entries",
            files: ["C.swift": "struct C {}", "D.swift": "struct D {}"],
            policy: entryLimitedPolicy
        )
        defer { entryFixture.cleanup() }
        let entryC = try await makeCleanReady(
            fixture: entryFixture,
            path: "C.swift",
            text: "struct C {}",
            fileID: uuid("B2200000-0000-0000-0000-000000000004")
        )
        let entryD = try await makeCleanReady(
            fixture: entryFixture,
            path: "D.swift",
            text: "struct D {}",
            fileID: uuid("B2200000-0000-0000-0000-000000000005")
        )
        try await assertEqualValue(
            entryFixture.overlay.adoptManifest(
                ticket: manifestTicket(entryFixture),
                snapshot: makeManifest(fixture: entryFixture, records: [entryC.record, entryD.record]),
                readyEntries: [entryC.adoption, entryD.adoption]
            ),
            .busy(.entryLimit)
        )
        await assertEqualValue((entryFixture.overlay.accounting()).entryCount, 0)
        await entryC.adoption.lease.close()
        await entryD.adoption.lease.close()
    }

    func testManifestLoadsAreFencedByEveryOverlayInvalidationAndFreshRevalidation() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Fence.swift": "struct Fence {}"]
        )
        defer { fixture.cleanup() }
        let clean = try await makeCleanReady(
            fixture: fixture,
            path: "Fence.swift",
            text: "struct Fence {}",
            fileID: uuid("B2000000-0000-0000-0000-000000000001")
        )
        let manifest = try makeManifest(fixture: fixture, records: [clean.record])
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: manifest,
                readyEntries: [clean.adoption]
            ),
            .adopted(readyEntryCount: 1)
        )

        for reason in [
            WorkspaceCodemapLiveOverlayInvalidationReason.modified,
            .deleted,
            .renamed,
            .watcherGap
        ] {
            let staleTicket = try await manifestTicket(fixture)
            _ = await fixture.overlay.invalidatePaths(
                rootEpoch: fixture.rootEpoch,
                standardizedRelativePaths: ["Fence.swift"],
                reason: reason
            )
            await assertEqualValue(
                fixture.overlay.adoptManifest(
                    ticket: staleTicket,
                    snapshot: manifest,
                    readyEntries: [clean.adoption]
                ),
                .rejected(.staleLoad)
            )
            try await assertTrueValue(unwrapValue(
                fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)
            ).entries.isEmpty)

            let freshLease = try await fixture.artifactStore.lease(handle: clean.handle)
            try await assertEqualValue(
                fixture.overlay.adoptManifest(
                    ticket: manifestTicket(fixture),
                    snapshot: manifest,
                    readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry(
                        record: clean.record,
                        binding: clean.binding,
                        lease: freshLease
                    )]
                ),
                .adopted(readyEntryCount: 1)
            )
        }

        let authorityLoad = try await manifestTicket(fixture)
        await assertTrueValue(fixture.overlay.invalidateRootAuthority(
            rootEpoch: fixture.rootEpoch,
            expectedAuthority: fixture.authority.capability.repositoryAuthority,
            reason: .authorityChanged
        ))
        await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: authorityLoad,
                snapshot: manifest,
                readyEntries: [clean.adoption]
            ),
            .rejected(.rootAuthorityInvalid)
        )
    }

    func testStaleManifestAdoptionRollbackCannotEraseNewCommitAfterReregistration() async throws {
        let commitGate = OverlayFirstCommitGate()
        let overlay = WorkspaceCodemapLiveOverlay(
            manifestAdoptionCommitHook: { await commitGate.enter() }
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Fence.swift": "struct Fence {}"],
            overlay: overlay
        )
        defer { fixture.cleanup() }

        let clean = try await makeCleanReady(
            fixture: fixture,
            path: "Fence.swift",
            text: "struct Fence {}",
            fileID: uuid("B2000000-0000-0000-0000-000000000002")
        )
        let manifest = try makeManifest(fixture: fixture, records: [clean.record])
        let firstTicket = try await manifestTicket(fixture)
        let firstAdoption = Task {
            await overlay.adoptManifest(
                ticket: firstTicket,
                snapshot: manifest,
                readyEntries: [clean.adoption]
            )
        }
        await commitGate.waitUntilFirstCommit()

        await assertTrueValue(overlay.unregister(rootEpoch: fixture.rootEpoch))
        await assertEqualValue(
            overlay.register(
                capability: .eligible(fixture.authority.capability),
                catalogGeneration: fixture.catalogGeneration
            ),
            .registered
        )
        let secondTicket = try await manifestTicket(fixture)
        assertNotEqual(firstTicket.operationID, secondTicket.operationID)
        let secondLease = try await fixture.artifactStore.lease(handle: clean.handle)
        await assertEqualValue(
            overlay.adoptManifest(
                ticket: secondTicket,
                snapshot: manifest,
                readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry(
                    record: clean.record,
                    binding: clean.binding,
                    lease: secondLease
                )]
            ),
            .adopted(readyEntryCount: 1)
        )

        await commitGate.releaseFirstCommit()
        await assertEqualValue(firstAdoption.value, .adopted(readyEntryCount: 1))
        await assertFalseValue(overlay.rollbackManifestAdoption(
            ticket: firstTicket,
            manifestGeneration: manifest.manifestGeneration
        ))
        let snapshot = try await unwrapValue(overlay.snapshot(rootEpoch: fixture.rootEpoch))
        assertEqualValue(snapshot.manifestGeneration, manifest.manifestGeneration)
        assertEqualValue(snapshot.entries.count, 1)
    }

    func testManifestAdoptionTicketCurrentRequiresExactLiveRootGeneration() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Fence.swift": "struct Fence {}"]
        )
        defer { fixture.cleanup() }

        let ticket = try await manifestTicket(fixture)
        await assertTrueValue(fixture.overlay.isManifestAdoptionTicketCurrent(ticket))

        let wrongCatalog = WorkspaceCodemapLiveManifestAdoptionTicket(
            operationID: ticket.operationID,
            rootEpoch: ticket.rootEpoch,
            pipelineIdentity: ticket.pipelineIdentity,
            catalogGeneration: ticket.catalogGeneration + 1,
            repositoryAuthority: ticket.repositoryAuthority,
            invalidationGeneration: ticket.invalidationGeneration
        )
        await assertFalseValue(fixture.overlay.isManifestAdoptionTicketCurrent(wrongCatalog))
        let wrongAuthority = WorkspaceCodemapLiveManifestAdoptionTicket(
            operationID: ticket.operationID,
            rootEpoch: ticket.rootEpoch,
            pipelineIdentity: ticket.pipelineIdentity,
            catalogGeneration: ticket.catalogGeneration,
            repositoryAuthority: repositoryAuthority(
                like: ticket.repositoryAuthority,
                authorityGeneration: ticket.repositoryAuthority.authorityGeneration + 1
            ),
            invalidationGeneration: ticket.invalidationGeneration
        )
        await assertFalseValue(fixture.overlay.isManifestAdoptionTicketCurrent(wrongAuthority))

        _ = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Fence.swift"],
            reason: .modified
        )
        await assertFalseValue(fixture.overlay.isManifestAdoptionTicketCurrent(ticket))
        let freshTicket = try await manifestTicket(fixture)
        await assertTrueValue(fixture.overlay.isManifestAdoptionTicketCurrent(freshTicket))

        await assertTrueValue(fixture.overlay.unregister(rootEpoch: fixture.rootEpoch))
        await assertFalseValue(fixture.overlay.isManifestAdoptionTicketCurrent(freshTicket))
    }

    func testManifestInvalidationGenerationExhaustionFailsClosedWithoutABA() async throws {
        let overlay = WorkspaceCodemapLiveOverlay(initialManifestInvalidationGeneration: .max)
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Fence.swift": "struct Fence {}"],
            overlay: overlay
        )
        defer { fixture.cleanup() }

        let ticket = try await manifestTicket(fixture)
        await assertTrueValue(overlay.isManifestAdoptionTicketCurrent(ticket))
        _ = await overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Fence.swift"],
            reason: .watcherGap
        )

        await assertFalseValue(overlay.isManifestAdoptionTicketCurrent(ticket))
        await assertNilValue(overlay.beginManifestAdoption(
            rootEpoch: fixture.rootEpoch,
            namespace: fixture.namespace
        ))
        await assertNilValue(overlay.freeze(rootEpoch: fixture.rootEpoch))
        let snapshot = try await unwrapValue(overlay.snapshot(rootEpoch: fixture.rootEpoch))
        assertFalseValue(snapshot.authorityIsCurrent)
    }

    func testContributionGenerationExhaustionRevokesOldGraphSnapshotWithoutABA() async throws {
        let overlay = WorkspaceCodemapLiveOverlay(initialContributionGeneration: .max)
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Fence.swift": "struct Fence {}"],
            overlay: overlay
        )
        defer { fixture.cleanup() }

        let oldGraph = try await unwrapValue(overlay.graphContributions(rootEpoch: fixture.rootEpoch))
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "Fence.swift",
            requestGeneration: 1,
            artifactName: "Fence"
        )
        _ = try await startedTicket(overlay.beginDemand(owner: .init(), token: ready.token))

        await assertNilValue(overlay.consumeGraphSnapshot(oldGraph))
        await assertNilValue(overlay.graphContributions(rootEpoch: fixture.rootEpoch))
        await assertNilValue(overlay.freeze(rootEpoch: fixture.rootEpoch))
        await ready.lease.close()
    }

    func testManifestRevalidationNetsRetiredShadowAtCapacity() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 1,
            maximumEntryCount: 1,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 1,
            maximumWaiterCount: 1,
            maximumLeaseCountPerRoot: 1,
            maximumLeaseCount: 1,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Capacity.swift": "struct Capacity {}"],
            policy: policy
        )
        defer { fixture.cleanup() }
        let clean = try await makeCleanReady(
            fixture: fixture,
            path: "Capacity.swift",
            text: "struct Capacity {}",
            fileID: uuid("B2100000-0000-0000-0000-000000000001")
        )
        let manifest = try makeManifest(fixture: fixture, records: [clean.record])
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: manifest,
                readyEntries: [clean.adoption]
            ),
            .adopted(readyEntryCount: 1)
        )
        _ = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Capacity.swift"],
            reason: .modified
        )
        let shadowAccounting = await fixture.overlay.accounting()
        assertEqualValue(shadowAccounting.entryCount, 1)
        assertEqualValue(shadowAccounting.shadowEntryCount, 1)

        let freshLease = try await fixture.artifactStore.lease(handle: clean.handle)
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: manifest,
                readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry(
                    record: clean.record,
                    binding: clean.binding,
                    lease: freshLease
                )]
            ),
            .adopted(readyEntryCount: 1)
        )
        let readyAccounting = await fixture.overlay.accounting()
        assertEqualValue(readyAccounting.entryCount, 1)
        assertEqualValue(readyAccounting.readyEntryCount, 1)
        assertEqualValue(readyAccounting.shadowEntryCount, 0)
        assertEqualValue(readyAccounting.leaseCount, 1)
    }

    func testManifestAdoptionClearsOnlyItsPipelineShadows() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "Swift.swift": "struct SwiftValue {}",
                "TypeScript.ts": "export const value = 1"
            ]
        )
        defer { fixture.cleanup() }
        let typeScriptPipeline = try SyntaxManager().pipelineIdentity(
            for: .ts,
            decoderPolicy: .workspaceAutomaticV1
        )
        let typeScriptNamespace = try CodeMapRootManifestNamespace(
            capability: fixture.authority.capability,
            pipelineIdentity: typeScriptPipeline
        )
        let swift = try await makeCleanReady(
            fixture: fixture,
            path: "Swift.swift",
            text: "struct SwiftValue {}",
            fileID: uuid("B2150000-0000-0000-0000-000000000001")
        )
        let typeScript = try await makeCleanReady(
            fixture: fixture,
            path: "TypeScript.ts",
            text: "export const value = 1",
            fileID: uuid("B2150000-0000-0000-0000-000000000002"),
            namespace: typeScriptNamespace,
            language: .ts
        )
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: makeManifest(fixture: fixture, records: [swift.record]),
                readyEntries: [swift.adoption]
            ),
            .adopted(readyEntryCount: 1)
        )
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture, namespace: typeScriptNamespace),
                snapshot: makeManifest(
                    fixture: fixture,
                    records: [typeScript.record],
                    namespace: typeScriptNamespace
                ),
                readyEntries: [typeScript.adoption]
            ),
            .adopted(readyEntryCount: 1)
        )
        _ = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Swift.swift", "TypeScript.ts"],
            reason: .modified
        )
        let shadowed = await fixture.overlay.accounting()
        assertEqualValue(shadowed.shadowEntryCount, 2)

        let freshSwiftLease = try await fixture.artifactStore.lease(handle: swift.handle)
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: makeManifest(fixture: fixture, records: [swift.record], generation: 2),
                readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry(
                    record: swift.record,
                    binding: swift.binding,
                    lease: freshSwiftLease
                )]
            ),
            .adopted(readyEntryCount: 1)
        )
        let accounting = await fixture.overlay.accounting()
        assertEqualValue(accounting.readyEntryCount, 1)
        assertEqualValue(accounting.shadowEntryCount, 1)
        let snapshotValue = await fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch)
        let snapshot = try unwrapValue(snapshotValue)
        assertTrueValue(snapshot.entries.contains(where: {
            $0.standardizedRelativePath == "TypeScript.ts" &&
                $0.state == .shadowed(.modified)
        }))
    }

    func testNewerEmptyAndTerminalManifestsRetireObsoleteShadowsAndLeases() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "Obsolete.swift": "struct Obsolete {}",
                "Terminal.swift": "struct Terminal {}"
            ]
        )
        defer { fixture.cleanup() }

        let obsolete = try await makeCleanReady(
            fixture: fixture,
            path: "Obsolete.swift",
            text: "struct Obsolete {}",
            fileID: uuid("B2200000-0000-0000-0000-000000000001")
        )
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: makeManifest(fixture: fixture, records: [obsolete.record]),
                readyEntries: [obsolete.adoption]
            ),
            .adopted(readyEntryCount: 1)
        )
        _ = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Obsolete.swift"],
            reason: .deleted
        )
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: makeManifest(fixture: fixture, records: [], generation: 2),
                readyEntries: []
            ),
            .adopted(readyEntryCount: 0)
        )
        let emptyAccounting = await fixture.overlay.accounting()
        assertEqualValue(emptyAccounting.entryCount, 0)
        assertEqualValue(emptyAccounting.shadowEntryCount, 0)
        assertEqualValue(emptyAccounting.leaseCount, 0)

        let terminalReady = try await makeCleanReady(
            fixture: fixture,
            path: "Terminal.swift",
            text: "struct Terminal {}",
            fileID: uuid("B2200000-0000-0000-0000-000000000002")
        )
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: makeManifest(
                    fixture: fixture,
                    records: [terminalReady.record],
                    generation: 3
                ),
                readyEntries: [terminalReady.adoption]
            ),
            .adopted(readyEntryCount: 1)
        )
        _ = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Terminal.swift"],
            reason: .modified
        )
        let terminal = try await makeCleanReady(
            fixture: fixture,
            path: "Terminal.swift",
            text: "struct TerminalChanged {",
            fileID: uuid("B2200000-0000-0000-0000-000000000002"),
            outcome: .parseFailed(.parserReturnedNilTree)
        )
        await terminal.adoption.lease.close()
        try await assertEqualValue(
            fixture.overlay.adoptManifest(
                ticket: manifestTicket(fixture),
                snapshot: makeManifest(
                    fixture: fixture,
                    records: [terminal.record],
                    generation: 4
                ),
                readyEntries: []
            ),
            .adopted(readyEntryCount: 0)
        )
        let terminalAccounting = await fixture.overlay.accounting()
        assertEqualValue(terminalAccounting.entryCount, 0)
        assertEqualValue(terminalAccounting.shadowEntryCount, 0)
        assertEqualValue(terminalAccounting.leaseCount, 0)
        try await eventually {
            await fixture.artifactStore.accounting().activeLeaseCount == 0
        }
    }

    func testUnavailablePublicationIsTicketBoundAndEntryBounded() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 1,
            maximumEntryCount: 1,
            maximumWaiterCountPerEntry: 2,
            maximumWaiterCountPerRoot: 2,
            maximumWaiterCount: 2,
            maximumLeaseCountPerRoot: 2,
            maximumLeaseCount: 2,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "Same.swift": "struct Same {}",
                "Other.swift": "struct Other {}"
            ],
            policy: policy
        )
        defer { fixture.cleanup() }
        let first = try await makeWorktreeReady(
            fixture: fixture,
            path: "Same.swift",
            fileID: uuid("B3000000-0000-0000-0000-000000000001"),
            requestGeneration: 1,
            artifactName: "Same"
        )
        let firstTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: first.token)
        )
        await assertEqualValue(
            fixture.overlay.setUnavailable(
                ticket: firstTicket,
                reason: .unsupportedFileType
            ),
            .accepted
        )
        await assertEqualValue(
            fixture.overlay.setUnavailable(
                ticket: firstTicket,
                reason: .unsupportedFileType
            ),
            .exactDuplicate
        )
        await assertEqualValue(
            fixture.overlay.setUnavailable(
                ticket: firstTicket,
                reason: .terminalArtifact(.parseFailed)
            ),
            .rejected(.invalidReason)
        )
        await first.lease.close()

        let replacement = try await makeWorktreeReady(
            fixture: fixture,
            path: "Same.swift",
            fileID: uuid("B3000000-0000-0000-0000-000000000002"),
            requestGeneration: 1,
            artifactName: "Same"
        )
        let replacementTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: replacement.token)
        )
        await assertEqualValue((fixture.overlay.accounting()).entryCount, 1)
        let forgedContributionTicket = WorkspaceCodemapLiveDemandTicket(
            token: replacementTicket.token,
            contributionGeneration: .init(
                rawValue: replacementTicket.contributionGeneration.rawValue + 1
            ),
            requestID: replacementTicket.requestID
        )
        await assertEqualValue(
            fixture.overlay.setUnavailable(
                ticket: forgedContributionTicket,
                reason: .transient
            ),
            .rejected(.contributionGenerationMismatch)
        )
        await assertEqualValue(
            fixture.overlay.setUnavailable(
                ticket: replacementTicket,
                reason: .securityExcluded
            ),
            .accepted
        )
        await replacement.lease.close()
        await assertEqualValue((fixture.overlay.accounting()).entryCount, 1)

        let other = try await makeWorktreeReady(
            fixture: fixture,
            path: "Other.swift",
            requestGeneration: 1,
            artifactName: "Other"
        )
        _ = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: other.token)
        )
        let reclaimed = await fixture.overlay.accounting()
        assertEqualValue(reclaimed.entryCount, 1)
        assertEqualValue(reclaimed.pendingEntryCount, 1)
        assertEqualValue(reclaimed.unavailableEntryCount, 0)
        assertEqualValue(reclaimed.evictionCount, 1)
        await other.lease.close()
    }

    func testNegativeEvictionRemovesHiddenCleanAfterCancellationAndUnavailable() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 2,
            maximumEntryCount: 2,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 2,
            maximumWaiterCount: 2,
            maximumLeaseCountPerRoot: 2,
            maximumLeaseCount: 2,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )

        for terminalState in [false, true] {
            let fixture = try await makeRootFixture(
                name: #function + (terminalState ? "-unavailable" : "-cancelled"),
                files: [
                    "Hidden.swift": "struct Hidden {}",
                    "Unrelated.swift": "struct Unrelated {}"
                ],
                policy: policy
            )
            defer { fixture.cleanup() }
            let fileID = terminalState
                ? uuid("B4100000-0000-0000-0000-000000000001")
                : uuid("B4100000-0000-0000-0000-000000000002")
            let clean = try await makeCleanReady(
                fixture: fixture,
                path: "Hidden.swift",
                text: "struct Hidden {}",
                fileID: fileID
            )
            try await assertEqualValue(
                fixture.overlay.adoptManifest(
                    ticket: manifestTicket(fixture),
                    snapshot: makeManifest(fixture: fixture, records: [clean.record]),
                    readyEntries: [clean.adoption]
                ),
                .adopted(readyEntryCount: 1)
            )

            let live = try await makeWorktreeReady(
                fixture: fixture,
                path: "Hidden.swift",
                fileID: fileID,
                requestGeneration: 2,
                artifactName: "Clean"
            )
            let owner = WorkspaceCodemapLiveDemandOwner()
            let ticket = try await startedTicket(
                fixture.overlay.beginDemand(owner: owner, token: live.token)
            )
            if terminalState {
                await assertEqualValue(
                    fixture.overlay.setUnavailable(
                        ticket: ticket,
                        reason: .transient
                    ),
                    .accepted
                )
            } else {
                await assertTrueValue(fixture.overlay.cancelDemand(owner: owner, ticket: ticket))
            }
            let negativeAccounting = await fixture.overlay.accounting()
            assertEqualValue(negativeAccounting.entryCount, 2)
            assertEqualValue(negativeAccounting.readyEntryCount, 1)

            let unrelated = try await makeWorktreeReady(
                fixture: fixture,
                path: "Unrelated.swift",
                requestGeneration: 1,
                artifactName: "Unrelated"
            )
            _ = try await startedTicket(
                fixture.overlay.beginDemand(owner: .init(), token: unrelated.token)
            )
            let admittedAccounting = await fixture.overlay.accounting()
            assertEqualValue(admittedAccounting.entryCount, 1)
            assertEqualValue(admittedAccounting.pendingEntryCount, 1)
            assertEqualValue(admittedAccounting.readyEntryCount, 0)
            assertEqualValue(admittedAccounting.evictionCount, 1)
            try await assertTrueValue(
                unwrapValue(fixture.overlay.freeze(rootEpoch: fixture.rootEpoch)).entries.isEmpty
            )
            await live.lease.close()
            await unrelated.lease.close()
        }
    }

    func testUnavailableFloodEvictsOldestNegativeWithoutOvershoot() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 2,
            maximumEntryCount: 2,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 2,
            maximumWaiterCount: 2,
            maximumLeaseCountPerRoot: 2,
            maximumLeaseCount: 2,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "A.swift": "struct A {}",
                "B.swift": "struct B {}",
                "C.swift": "struct C {}",
                "D.swift": "struct D {}"
            ],
            policy: policy
        )
        defer { fixture.cleanup() }

        var readyByPath: [String: ReadyFixture] = [:]
        for path in ["A.swift", "B.swift", "C.swift", "D.swift"] {
            readyByPath[path] = try await makeWorktreeReady(
                fixture: fixture,
                path: path,
                requestGeneration: 1,
                artifactName: String(path.dropLast(".swift".count))
            )
        }
        for path in ["A.swift", "B.swift"] {
            let ready = try unwrapValue(readyByPath[path])
            let ticket = try await startedTicket(
                fixture.overlay.beginDemand(owner: .init(), token: ready.token)
            )
            await assertEqualValue(
                fixture.overlay.setUnavailable(ticket: ticket, reason: .transient),
                .accepted
            )
            await ready.lease.close()
        }
        let saturated = await fixture.overlay.accounting()
        assertEqualValue(saturated.entryCount, 2)
        assertEqualValue(saturated.evictionCount, 0)

        let c = try unwrapValue(readyByPath["C.swift"])
        let cTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: c.token)
        )
        let afterFirstEviction = await fixture.overlay.accounting()
        assertEqualValue(afterFirstEviction.entryCount, 2)
        assertEqualValue(afterFirstEviction.evictionCount, 1)
        await assertEqualValue(
            fixture.overlay.setUnavailable(ticket: cTicket, reason: .transient),
            .accepted
        )
        await c.lease.close()

        let d = try unwrapValue(readyByPath["D.swift"])
        _ = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: d.token)
        )
        let afterSecondEviction = await fixture.overlay.accounting()
        assertEqualValue(afterSecondEviction.entryCount, 2)
        assertEqualValue(afterSecondEviction.evictionCount, 2)
        let snapshot = try await unwrapValue(fixture.overlay.snapshot(rootEpoch: fixture.rootEpoch))
        assertEqualValue(snapshot.entries.map(\.standardizedRelativePath), ["C.swift", "D.swift"])
        await d.lease.close()
    }

    func testOwnerWideReleasePreventsWaiterStarvationAndSurvivesUnloadRace() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 2,
            maximumEntryCountPerRoot: 2,
            maximumEntryCount: 4,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 1,
            maximumWaiterCount: 2,
            maximumLeaseCountPerRoot: 2,
            maximumLeaseCount: 2,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Owner.swift": "struct Owner {}"],
            policy: policy
        )
        defer { fixture.cleanup() }
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "Owner.swift",
            requestGeneration: 1,
            artifactName: "Owner"
        )
        let abandoned = WorkspaceCodemapLiveDemandOwner(
            rawValue: uuid("B4000000-0000-0000-0000-000000000001")
        )
        let successor = WorkspaceCodemapLiveDemandOwner(
            rawValue: uuid("B4000000-0000-0000-0000-000000000002")
        )
        let abandonedTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: abandoned, token: ready.token)
        )
        let second = try await makeRootFixture(
            name: #function + "-second",
            files: ["SecondOwner.swift": "struct SecondOwner {}"],
            policy: policy,
            overlay: fixture.overlay,
            artifactStore: fixture.artifactStore
        )
        defer { second.cleanup() }
        let secondReady = try await makeWorktreeReady(
            fixture: second,
            path: "SecondOwner.swift",
            requestGeneration: 1,
            artifactName: "SecondOwner"
        )
        _ = try await startedTicket(
            fixture.overlay.beginDemand(owner: abandoned, token: secondReady.token)
        )
        guard case let .queued(successorReservation) = await fixture.overlay.beginDemand(
            owner: successor,
            token: ready.token
        ) else { return XCTFail("The saturated owner slot must issue a FIFO reservation.") }
        await assertEqualValue(fixture.overlay.cancelDemands(owner: abandoned), 2)
        let successorTicket = try await startedTicket(
            fixture.overlay.resumeDemand(owner: successor, reservation: successorReservation)
        )
        XCTAssertNotEqual(successorTicket, abandonedTicket)
        await assertEqualValue(fixture.overlay.cancelDemands(owner: successor), 1)
        await assertEqualValue((fixture.overlay.accounting()).pendingEntryCount, 0)

        await assertTrueValue(fixture.overlay.unregister(rootEpoch: fixture.rootEpoch))
        await assertEqualValue(fixture.overlay.cancelDemands(owner: successor), 0)
        await assertFalseValue(fixture.overlay.cancelDemand(owner: successor, ticket: successorTicket))
        await ready.lease.close()
        await secondReady.lease.close()
    }

    func testReadyHitRefreshesTrueLRUAndOverflowRebaseKeepsHotEntry() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 2,
            maximumEntryCount: 2,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 2,
            maximumWaiterCount: 2,
            maximumLeaseCountPerRoot: 2,
            maximumLeaseCount: 2,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )
        let overlay = WorkspaceCodemapLiveOverlay(
            policy: policy,
            initialAccessOrdinal: .max - 1
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "Hot.swift": "struct Hot {}",
                "Cold.swift": "struct Cold {}",
                "New.swift": "struct New {}"
            ],
            policy: policy,
            overlay: overlay
        )
        defer { fixture.cleanup() }

        let hot = try await makeWorktreeReady(
            fixture: fixture,
            path: "Hot.swift",
            requestGeneration: 1,
            artifactName: "Hot"
        )
        let hotTicket = try await startedTicket(overlay.beginDemand(owner: .init(), token: hot.token))
        _ = try await acceptedReady(overlay.acceptCompletion(
            ticket: hotTicket,
            completion: hot.completion,
            lease: hot.lease
        ))
        let cold = try await makeWorktreeReady(
            fixture: fixture,
            path: "Cold.swift",
            requestGeneration: 1,
            artifactName: "Cold"
        )
        let coldTicket = try await startedTicket(overlay.beginDemand(owner: .init(), token: cold.token))
        _ = try await acceptedReady(overlay.acceptCompletion(
            ticket: coldTicket,
            completion: cold.completion,
            lease: cold.lease
        ))
        guard case .ready = await overlay.beginDemand(owner: .init(), token: hot.token) else {
            return XCTFail("An exact ready hit must refresh its LRU ordinal.")
        }

        let new = try await makeWorktreeReady(
            fixture: fixture,
            path: "New.swift",
            requestGeneration: 1,
            artifactName: "New"
        )
        _ = try await startedTicket(overlay.beginDemand(owner: .init(), token: new.token))
        let snapshot = try await unwrapValue(overlay.snapshot(rootEpoch: fixture.rootEpoch))
        assertEqualValue(snapshot.entries.map(\.standardizedRelativePath), ["Hot.swift", "New.swift"])
        await assertEqualValue((overlay.accounting()).evictionCount, 1)
        await new.lease.close()
    }

    func testOrdinalAndAccountingCounterOverflowSaturatesWithoutReorderingNewEntries() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 1,
            maximumEntryCountPerRoot: 2,
            maximumEntryCount: 2,
            maximumWaiterCountPerEntry: 1,
            maximumWaiterCountPerRoot: 2,
            maximumWaiterCount: 2,
            maximumLeaseCountPerRoot: 2,
            maximumLeaseCount: 2,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max,
            maximumAdmissionReservationCountPerRoot: 1,
            maximumAdmissionReservationCount: 1
        )
        let overlay = WorkspaceCodemapLiveOverlay(
            policy: policy,
            initialAccessOrdinal: .max,
            initialCounterValue: .max
        )
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "A.swift": "struct A {}",
                "B.swift": "struct B {}",
                "C.swift": "struct C {}"
            ],
            policy: policy,
            overlay: overlay
        )
        defer { fixture.cleanup() }

        let a = try await makeWorktreeReady(
            fixture: fixture,
            path: "A.swift",
            requestGeneration: 1,
            artifactName: "A"
        )
        let aTicket = try await startedTicket(overlay.beginDemand(owner: .init(), token: a.token))
        _ = try await acceptedReady(overlay.acceptCompletion(
            ticket: aTicket,
            completion: a.completion,
            lease: a.lease
        ))
        let b = try await makeWorktreeReady(
            fixture: fixture,
            path: "B.swift",
            requestGeneration: 1,
            artifactName: "B"
        )
        let bTicket = try await startedTicket(overlay.beginDemand(owner: .init(), token: b.token))
        _ = try await acceptedReady(overlay.acceptCompletion(
            ticket: bTicket,
            completion: b.completion,
            lease: b.lease
        ))
        let c = try await makeWorktreeReady(
            fixture: fixture,
            path: "C.swift",
            requestGeneration: 1,
            artifactName: "C"
        )
        let cOwner = WorkspaceCodemapLiveDemandOwner()
        _ = try await startedTicket(overlay.beginDemand(owner: cOwner, token: c.token))
        let queuedOwner = WorkspaceCodemapLiveDemandOwner()
        guard case let .queued(reservation) = await overlay.beginDemand(
            owner: queuedOwner,
            token: c.token
        ) else { return XCTFail("The saturated waiter must reserve the bounded queue.") }
        guard case .busy(.admissionQueueLimit) = await overlay.beginDemand(
            owner: .init(),
            token: c.token
        ) else { return XCTFail("The saturated admission queue must fail closed.") }
        await assertTrueValue(overlay.cancelDemandReservation(owner: queuedOwner, reservation: reservation))
        guard case .rejected(.pendingRequestMissing) = await overlay.acceptCompletion(
            ticket: aTicket,
            completion: a.completion,
            lease: a.lease
        ) else {
            return XCTFail("The evicted entry must reject a stale completion.")
        }

        let snapshot = try await unwrapValue(overlay.snapshot(rootEpoch: fixture.rootEpoch))
        XCTAssertEqual(snapshot.entries.map(\.standardizedRelativePath), ["B.swift", "C.swift"])
        let accounting = await overlay.accounting()
        XCTAssertEqual(accounting.evictionCount, .max)
        XCTAssertEqual(accounting.busyDropCount, .max)
        XCTAssertEqual(accounting.staleCompletionDropCount, .max)
        await a.lease.close()
        await b.lease.close()
        await c.lease.close()
    }

    func testProcessEntryEvictionIsDeterministicFIFOAcrossRoots() async throws {
        let policy = WorkspaceCodemapLiveOverlayPolicy(
            maximumRootCount: 2,
            maximumEntryCountPerRoot: 2,
            maximumEntryCount: 2,
            maximumWaiterCountPerEntry: 2,
            maximumWaiterCountPerRoot: 2,
            maximumWaiterCount: 4,
            maximumLeaseCountPerRoot: 2,
            maximumLeaseCount: 4,
            maximumArtifactByteCountPerRoot: .max,
            maximumArtifactByteCount: .max
        )
        let overlay = WorkspaceCodemapLiveOverlay(policy: policy)
        let first = try await makeRootFixture(
            name: #function + "-first",
            files: ["First.swift": "struct First {}"],
            policy: policy,
            overlay: overlay
        )
        defer { first.cleanup() }
        let second = try await makeRootFixture(
            name: #function + "-second",
            files: [
                "Second.swift": "struct Second {}",
                "Third.swift": "struct Third {}"
            ],
            policy: policy,
            overlay: overlay,
            artifactStore: first.artifactStore
        )
        defer { second.cleanup() }
        let firstReady = try await makeWorktreeReady(
            fixture: first,
            path: "First.swift",
            requestGeneration: 1,
            artifactName: "First"
        )
        let firstTicket = try await startedTicket(
            overlay.beginDemand(owner: .init(), token: firstReady.token)
        )
        _ = try await acceptedReady(overlay.acceptCompletion(
            ticket: firstTicket,
            completion: firstReady.completion,
            lease: firstReady.lease
        ))
        let secondReady = try await makeWorktreeReady(
            fixture: second,
            path: "Second.swift",
            requestGeneration: 1,
            artifactName: "Second"
        )
        let secondTicket = try await startedTicket(
            overlay.beginDemand(owner: .init(), token: secondReady.token)
        )
        _ = try await acceptedReady(overlay.acceptCompletion(
            ticket: secondTicket,
            completion: secondReady.completion,
            lease: secondReady.lease
        ))
        let third = try await makeWorktreeReady(
            fixture: second,
            path: "Third.swift",
            requestGeneration: 1,
            artifactName: "Third"
        )
        _ = try await startedTicket(overlay.beginDemand(owner: .init(), token: third.token))

        try await assertTrueValue(unwrapValue(overlay.freeze(rootEpoch: first.rootEpoch)).entries.isEmpty)
        let secondSnapshot = try await unwrapValue(overlay.snapshot(rootEpoch: second.rootEpoch))
        assertEqualValue(secondSnapshot.entries.count, 2)
        await assertEqualValue((overlay.accounting()).entryCount, 2)
        await third.lease.close()
    }

    func testGraphSnapshotsRequireConsumeTimeCurrentness() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Graph.swift": "struct Graph {}"]
        )
        defer { fixture.cleanup() }
        let fileID = uuid("B5000000-0000-0000-0000-000000000001")
        let first = try await makeWorktreeReady(
            fixture: fixture,
            path: "Graph.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Graph"
        )
        let firstTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: first.token)
        )
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: firstTicket,
            completion: first.completion,
            lease: first.lease
        ))
        let firstGraph = try await unwrapValue(
            fixture.overlay.graphContributions(rootEpoch: fixture.rootEpoch)
        )
        await assertEqualValue(fixture.overlay.consumeGraphSnapshot(firstGraph)?.count, 1)

        let foreignCatalogGraph = WorkspaceCodemapLiveGraphSnapshot(
            rootEpoch: firstGraph.rootEpoch,
            catalogGeneration: firstGraph.catalogGeneration + 1,
            repositoryAuthority: firstGraph.repositoryAuthority,
            contributionGeneration: firstGraph.contributionGeneration,
            bindings: firstGraph.bindings
        )
        await assertNilValue(fixture.overlay.consumeGraphSnapshot(foreignCatalogGraph))
        let foreignRepositoryGraph = WorkspaceCodemapLiveGraphSnapshot(
            rootEpoch: firstGraph.rootEpoch,
            catalogGeneration: firstGraph.catalogGeneration,
            repositoryAuthority: repositoryAuthority(
                like: firstGraph.repositoryAuthority,
                authorityGeneration: firstGraph.repositoryAuthority.authorityGeneration + 1
            ),
            contributionGeneration: firstGraph.contributionGeneration,
            bindings: firstGraph.bindings
        )
        await assertNilValue(fixture.overlay.consumeGraphSnapshot(foreignRepositoryGraph))

        _ = await fixture.overlay.invalidatePaths(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Graph.swift"],
            reason: .modified
        )
        await assertNilValue(fixture.overlay.consumeGraphSnapshot(firstGraph))
        let invalidatedGraph = try await unwrapValue(
            fixture.overlay.graphContributions(rootEpoch: fixture.rootEpoch)
        )
        await assertEqualValue(fixture.overlay.consumeGraphSnapshot(invalidatedGraph)?.count, 0)

        let replacement = try await makeWorktreeReady(
            fixture: fixture,
            path: "Graph.swift",
            fileID: fileID,
            requestGeneration: 2,
            artifactName: "Graph"
        )
        let replacementTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: replacement.token)
        )
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: replacementTicket,
            completion: replacement.completion,
            lease: replacement.lease
        ))
        await assertNilValue(fixture.overlay.consumeGraphSnapshot(invalidatedGraph))
        let replacementGraph = try await unwrapValue(
            fixture.overlay.graphContributions(rootEpoch: fixture.rootEpoch)
        )
        await assertEqualValue(fixture.overlay.consumeGraphSnapshot(replacementGraph)?.count, 1)
        await assertTrueValue(fixture.overlay.unregister(rootEpoch: fixture.rootEpoch))
        await assertNilValue(fixture.overlay.consumeGraphSnapshot(replacementGraph))
    }

    func testCompletionStaleFencesIdentifyEveryAuthorityDimension() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "Fence.swift": "struct Fence {}",
                "Other.swift": "struct Other {}"
            ]
        )
        defer { fixture.cleanup() }
        let fileID = uuid("B6000000-0000-0000-0000-000000000001")
        let current = try await makeWorktreeReady(
            fixture: fixture,
            path: "Fence.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Fence",
            pathGeneration: 1,
            ingressGeneration: 1
        )
        let ticket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: current.token)
        )

        let differentLifetime = try await makeRootFixture(
            name: #function + "-lifetime",
            files: ["Fence.swift": "struct Fence {}"],
            rootID: fixture.rootEpoch.rootID,
            rootLifetimeID: UUID()
        )
        defer { differentLifetime.cleanup() }
        let lifetimeCompletion = try await makeWorktreeReady(
            fixture: differentLifetime,
            path: "Fence.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Fence",
            pathGeneration: 1,
            ingressGeneration: 1
        )
        guard case .rejected(.binding(.rootLifetimeIDMismatch)) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: lifetimeCompletion.completion,
            lease: lifetimeCompletion.lease
        ) else { return XCTFail("Root lifetime must be an exact completion fence.") }

        let catalogCompletion = try await makeWorktreeReady(
            fixture: fixture,
            path: "Fence.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Fence",
            catalogGeneration: fixture.catalogGeneration + 1,
            pathGeneration: 1,
            ingressGeneration: 1
        )
        guard case .rejected(.binding(.catalogGenerationMismatch)) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: catalogCompletion.completion,
            lease: catalogCompletion.lease
        ) else { return XCTFail("Catalog generation must be an exact completion fence.") }

        let foreignAuthority = try await WorkspaceCodemapAuthorityTestFixture.make(
            name: #function + "-authority",
            files: ["Fence.swift": "struct Fence {}"],
            rootID: fixture.rootEpoch.rootID,
            rootLifetimeID: fixture.rootEpoch.rootLifetimeID
        )
        defer { foreignAuthority.repositoryFixture.cleanup() }
        let source = try await fixture.authority.validatedWorktreeSource(
            loadedRootRelativePath: "Fence.swift"
        )
        let foreignSourceAuthority = try await foreignAuthority.sourceAuthority(
            repositoryRelativePath: "Fence.swift",
            pathGeneration: 1,
            ingressGeneration: 1
        )
        let foreignExpectation = try unwrapValue(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: current.token.identity,
            source: source,
            expectedArtifactKey: current.completion.artifactKey,
            classificationReason: .dirty,
            sourceAuthority: foreignSourceAuthority
        ))
        let foreignToken = try unwrapValue(WorkspaceCodemapArtifactRequestToken.issue(
            identity: current.token.identity,
            requestGeneration: 1,
            catalogGeneration: fixture.catalogGeneration,
            sourceExpectation: foreignExpectation
        ))
        let foreignCompletion = try unwrapValue(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: foreignToken,
            language: .swift,
            outcome: current.completion.outcome
        ))
        let foreignLease = try await fixture.artifactStore.lease(handle: current.handle)
        guard case .rejected(.binding(.repositoryAuthorityMismatch)) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: foreignCompletion,
            lease: foreignLease
        ) else { return XCTFail("Repository authority must be an exact completion fence.") }

        let pathCompletion = try await makeWorktreeReady(
            fixture: fixture,
            path: "Other.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Other",
            pathGeneration: 1,
            ingressGeneration: 1
        )
        guard case .rejected(.binding(.relativePathMismatch)) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: pathCompletion.completion,
            lease: pathCompletion.lease
        ) else { return XCTFail("Relative path must be an exact completion fence.") }

        let pathGenerationCompletion = try await makeWorktreeReady(
            fixture: fixture,
            path: "Fence.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Fence",
            pathGeneration: 2,
            ingressGeneration: 1
        )
        guard case .rejected(.binding(.sourceAuthorityPathGenerationMismatch)) =
            await fixture.overlay.acceptCompletion(
                ticket: ticket,
                completion: pathGenerationCompletion.completion,
                lease: pathGenerationCompletion.lease
            )
        else { return XCTFail("Path generation must be an exact completion fence.") }

        let ingressCompletion = try await makeWorktreeReady(
            fixture: fixture,
            path: "Fence.swift",
            fileID: fileID,
            requestGeneration: 1,
            artifactName: "Fence",
            pathGeneration: 1,
            ingressGeneration: 2
        )
        guard case .rejected(.binding(.sourceAuthorityIngressGenerationMismatch)) =
            await fixture.overlay.acceptCompletion(
                ticket: ticket,
                completion: ingressCompletion.completion,
                lease: ingressCompletion.lease
            )
        else { return XCTFail("Ingress generation must be an exact completion fence.") }

        let requestCompletion = try await makeWorktreeReady(
            fixture: fixture,
            path: "Fence.swift",
            fileID: fileID,
            requestGeneration: 2,
            artifactName: "Fence",
            pathGeneration: 1,
            ingressGeneration: 1
        )
        guard case .rejected(.binding(.requestGenerationMismatch)) = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: requestCompletion.completion,
            lease: requestCompletion.lease
        ) else { return XCTFail("Request generation must be an exact completion fence.") }

        let contributionTicket = WorkspaceCodemapLiveDemandTicket(
            token: ticket.token,
            contributionGeneration: .init(rawValue: ticket.contributionGeneration.rawValue + 1),
            requestID: ticket.requestID
        )
        guard case .rejected(.contributionGenerationMismatch) = await fixture.overlay.acceptCompletion(
            ticket: contributionTicket,
            completion: current.completion,
            lease: current.lease
        ) else { return XCTFail("Contribution generation must be an exact completion fence.") }

        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: current.completion,
            lease: current.lease
        ))
        await lifetimeCompletion.lease.close()
        await catalogCompletion.lease.close()
        await foreignLease.close()
        await pathCompletion.lease.close()
        await pathGenerationCompletion.lease.close()
        await ingressCompletion.lease.close()
        await requestCompletion.lease.close()
    }

    func testExactDuplicateCompletionRequiresCurrentTicketAndClosesDuplicateLease() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: ["Duplicate.swift": "struct Duplicate {}"]
        )
        defer { fixture.cleanup() }
        let ready = try await makeWorktreeReady(
            fixture: fixture,
            path: "Duplicate.swift",
            requestGeneration: 1,
            artifactName: "Duplicate"
        )
        let ticket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: ready.token)
        )
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: ready.completion,
            lease: ready.lease
        ))
        var storeAccounting = await fixture.artifactStore.accounting()
        XCTAssertEqual(storeAccounting.activeLeaseCount, 1)

        let duplicateLease = try await fixture.artifactStore.lease(handle: ready.handle)
        storeAccounting = await fixture.artifactStore.accounting()
        XCTAssertEqual(storeAccounting.activeLeaseCount, 2)
        guard case .exactDuplicate = await fixture.overlay.acceptCompletion(
            ticket: ticket,
            completion: ready.completion,
            lease: duplicateLease
        ) else { return XCTFail("The exact originating ticket should be idempotent.") }
        storeAccounting = await fixture.artifactStore.accounting()
        XCTAssertEqual(storeAccounting.activeLeaseCount, 1)

        let staleTicket = WorkspaceCodemapLiveDemandTicket(
            token: ticket.token,
            contributionGeneration: ticket.contributionGeneration,
            requestID: UUID()
        )
        let staleLease = try await fixture.artifactStore.lease(handle: ready.handle)
        guard case .rejected(.pendingRequestMissing) = await fixture.overlay.acceptCompletion(
            ticket: staleTicket,
            completion: ready.completion,
            lease: staleLease
        ) else { return XCTFail("A stale ticket must not become an exact duplicate after readiness.") }
        await staleLease.close()
        storeAccounting = await fixture.artifactStore.accounting()
        XCTAssertEqual(storeAccounting.activeLeaseCount, 1)
    }

    func testFocusedRegistrationDemandOutcomeAndInvalidationSemantics() async throws {
        let fixture = try await makeRootFixture(
            name: #function,
            files: [
                "NoSymbols.swift": "let value = 1",
                "Decode.swift": "struct Decode {}",
                "Parse.swift": "struct Parse {}"
            ]
        )
        defer { fixture.cleanup() }
        await assertEqualValue(
            fixture.overlay.register(
                capability: .eligible(fixture.authority.capability),
                catalogGeneration: fixture.catalogGeneration
            ),
            .exactDuplicate
        )
        await assertEqualValue(
            fixture.overlay.register(
                capability: .unresolved,
                catalogGeneration: fixture.catalogGeneration
            ),
            .rejected(.capabilityUnavailable)
        )
        let freshOverlay = WorkspaceCodemapLiveOverlay()
        await assertEqualValue(
            freshOverlay.register(
                capability: .eligible(fixture.authority.capability),
                catalogGeneration: 0
            ),
            .rejected(.catalogGenerationInvalid)
        )

        let noSymbols = try await makeWorktreeReady(
            fixture: fixture,
            path: "NoSymbols.swift",
            requestGeneration: 1,
            artifactName: "Unused",
            outcome: .readyNoSymbols
        )
        let owner = WorkspaceCodemapLiveDemandOwner()
        let noSymbolsTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: owner, token: noSymbols.token)
        )
        guard case .joined(noSymbolsTicket) = await fixture.overlay.beginDemand(
            owner: owner,
            token: noSymbols.token
        ) else { return XCTFail("A duplicate owner must join idempotently.") }
        guard case .joined(noSymbolsTicket) = await fixture.overlay.beginDemand(
            owner: .init(),
            token: noSymbols.token
        ) else { return XCTFail("A second owner must join the current request.") }
        _ = try await acceptedReady(fixture.overlay.acceptCompletion(
            ticket: noSymbolsTicket,
            completion: noSymbols.completion,
            lease: noSymbols.lease
        ))
        guard case .ready = await fixture.overlay.beginDemand(owner: .init(), token: noSymbols.token) else {
            return XCTFail("An exact ready token must use the ready fast path.")
        }
        await assertEqualValue(
            fixture.overlay.setUnavailable(
                ticket: noSymbolsTicket,
                reason: .transient
            ),
            .rejected(.pendingRequestMissing)
        )

        let conflict = try await makeWorktreeReady(
            fixture: fixture,
            path: "NoSymbols.swift",
            fileID: noSymbols.token.identity.fileID,
            requestGeneration: 1,
            artifactName: "Unused",
            outcome: .readyNoSymbols,
            pathGeneration: 2,
            ingressGeneration: 1
        )
        guard case .rejected(.requestGenerationConflict) = await fixture.overlay.beginDemand(
            owner: .init(),
            token: conflict.token
        ) else { return XCTFail("Equal request generations with different proof must conflict.") }
        let stale = try await makeWorktreeReady(
            fixture: fixture,
            path: "NoSymbols.swift",
            fileID: noSymbols.token.identity.fileID,
            requestGeneration: 0,
            artifactName: "Unused",
            outcome: .readyNoSymbols,
            pathGeneration: 1,
            ingressGeneration: 1
        )
        guard case .rejected(.staleRequestGeneration) = await fixture.overlay.beginDemand(
            owner: .init(),
            token: stale.token
        ) else { return XCTFail("Older demand generations must be rejected.") }
        await conflict.lease.close()
        await stale.lease.close()

        let decode = try await makeWorktreeReady(
            fixture: fixture,
            path: "Decode.swift",
            requestGeneration: 1,
            artifactName: "Decode",
            outcome: .decodeFailed(.undecodable)
        )
        let decodeTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: decode.token)
        )
        guard case .acceptedUnavailable(.decodeFailed) = await fixture.overlay.acceptCompletion(
            ticket: decodeTicket,
            completion: decode.completion,
            lease: decode.lease
        ) else { return XCTFail("Decode failures must become validated unavailable outcomes.") }

        let parse = try await makeWorktreeReady(
            fixture: fixture,
            path: "Parse.swift",
            requestGeneration: 1,
            artifactName: "Parse",
            outcome: .parseFailed(.parserReturnedNilTree)
        )
        let parseTicket = try await startedTicket(
            fixture.overlay.beginDemand(owner: .init(), token: parse.token)
        )
        guard case .acceptedUnavailable(.parseFailed) = await fixture.overlay.acceptCompletion(
            ticket: parseTicket,
            completion: parse.completion,
            lease: parse.lease
        ) else { return XCTFail("Parse failures must become validated unavailable outcomes.") }
        await assertEqualValue(
            fixture.overlay.invalidatePaths(
                rootEpoch: fixture.rootEpoch,
                standardizedRelativePaths: ["NoSymbols.swift"],
                reason: .deleted
            ),
            1
        )
    }

    private func makeRootFixture(
        name: String,
        files: [String: String],
        policy: WorkspaceCodemapLiveOverlayPolicy = .default,
        overlay: WorkspaceCodemapLiveOverlay? = nil,
        artifactStore: CodeMapArtifactStore? = nil,
        rootID: UUID = UUID(),
        rootLifetimeID: UUID = UUID()
    ) async throws -> RootFixture {
        let authority = try await WorkspaceCodemapAuthorityTestFixture.make(
            name: name,
            files: files,
            rootID: rootID,
            rootLifetimeID: rootLifetimeID
        )
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let namespace = try CodeMapRootManifestNamespace(
            capability: authority.capability,
            pipelineIdentity: pipeline
        )
        let resolvedOverlay = overlay ?? WorkspaceCodemapLiveOverlay(policy: policy)
        let resolvedArtifactStore: CodeMapArtifactStore = if let artifactStore {
            artifactStore
        } else {
            try CodeMapArtifactStore(
                rootURL: authority.secureArtifactRoot(named: "live-overlay-artifacts")
            )
        }
        let fixture = RootFixture(
            authority: authority,
            overlay: resolvedOverlay,
            artifactStore: resolvedArtifactStore,
            namespace: namespace,
            catalogGeneration: 11
        )
        guard await resolvedOverlay.register(
            capability: .eligible(authority.capability),
            catalogGeneration: fixture.catalogGeneration
        ) == .registered else {
            throw TestError.registrationFailed
        }
        return fixture
    }

    private func makeWorktreeReady(
        fixture: RootFixture,
        path: String,
        fileID: UUID = UUID(),
        requestGeneration: UInt64,
        artifactName: String,
        outcome: CodeMapSyntaxArtifactOutcome? = nil,
        catalogGeneration: UInt64? = nil,
        pathGeneration: UInt64? = nil,
        ingressGeneration: UInt64? = nil
    ) async throws -> ReadyFixture {
        let source = try await fixture.authority.validatedWorktreeSource(loadedRootRelativePath: path)
        let identity = try fixture.authority.bindingIdentity(
            fileID: fileID,
            loadedRootRelativePath: path
        )
        let repositoryPath = repositoryRelativePath(fixture: fixture, path: path)
        let sourceAuthority = try await fixture.authority.sourceAuthority(
            repositoryRelativePath: repositoryPath,
            pathGeneration: pathGeneration ?? requestGeneration,
            ingressGeneration: ingressGeneration ?? requestGeneration
        )
        let key = try CodeMapArtifactKey(source: source, pipelineIdentity: fixture.namespace.pipelineIdentity)
        let resolvedOutcome = outcome ?? .ready(makeArtifact(name: artifactName))
        let handle: CodeMapArtifactHandle
        switch try await fixture.artifactStore.lookup(key: key) {
        case let .hit(_, existing):
            guard existing.outcome == resolvedOutcome else { throw TestError.artifactOutcomeMismatch }
            handle = existing
        case .miss:
            _ = try await fixture.artifactStore.insert(key: key, deterministicOutcome: resolvedOutcome)
            handle = try await requireHandle(fixture.artifactStore, key: key)
        }
        let lease = try await fixture.artifactStore.lease(handle: handle)
        let expectation = try unwrapValue(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: identity,
            source: source,
            expectedArtifactKey: key,
            classificationReason: .dirty,
            sourceAuthority: sourceAuthority
        ))
        let token = try unwrapValue(WorkspaceCodemapArtifactRequestToken.issue(
            identity: identity,
            requestGeneration: requestGeneration,
            catalogGeneration: catalogGeneration ?? fixture.catalogGeneration,
            sourceExpectation: expectation
        ))
        let completion = try unwrapValue(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: token,
            language: .swift,
            outcome: resolvedOutcome
        ))
        return ReadyFixture(token: token, completion: completion, handle: handle, lease: lease)
    }

    private func makeCleanReady(
        fixture: RootFixture,
        path: String,
        text: String,
        fileID: UUID,
        outcome: CodeMapSyntaxArtifactOutcome? = nil,
        namespace: CodeMapRootManifestNamespace? = nil,
        language: LanguageType = .swift
    ) async throws -> CleanReadyFixture {
        let namespace = namespace ?? fixture.namespace
        let source = try await fixture.authority.cleanSource(bytes: Data(text.utf8))
        guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
            throw TestError.cleanSourceExpected
        }
        let key = try CodeMapArtifactKey(source: source, pipelineIdentity: namespace.pipelineIdentity)
        let resolvedOutcome = outcome ?? .ready(makeArtifact(name: "Clean"))
        _ = try await fixture.artifactStore.insert(key: key, deterministicOutcome: resolvedOutcome)
        let handle = try await requireHandle(fixture.artifactStore, key: key)
        let lease = try await fixture.artifactStore.lease(handle: handle)
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: namespace.pipelineIdentity
        )
        let association = try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: locator,
            artifactKey: key,
            casHandle: handle
        )
        let identity = try fixture.authority.bindingIdentity(
            fileID: fileID,
            loadedRootRelativePath: path
        )
        let repositoryPath = repositoryRelativePath(fixture: fixture, path: path)
        let sourceAuthority = try await fixture.authority.sourceAuthority(repositoryRelativePath: repositoryPath)
        let expectation = try unwrapValue(WorkspaceCodemapSourceExpectation.cleanGitBlob(
            bindingIdentity: identity,
            locatorIdentity: locator,
            sourceAuthority: sourceAuthority
        ))
        let token = try unwrapValue(WorkspaceCodemapArtifactRequestToken.issue(
            identity: identity,
            requestGeneration: 1,
            catalogGeneration: fixture.catalogGeneration,
            sourceExpectation: expectation
        ))
        let completion = try unwrapValue(WorkspaceCodemapArtifactCompletion.cleanGitBlob(
            token: token,
            language: language,
            association: association
        ))
        var binding = try unwrapValue(WorkspaceCodemapArtifactBinding(pending: token))
        assertEqualValue(binding.apply(completion), .accepted)
        let contribution: CodeMapSelectionGraphContribution? = switch resolvedOutcome {
        case let .ready(artifact):
            CodeMapSelectionGraphContribution(artifactKey: key, artifact: artifact)
        case .readyNoSymbols:
            CodeMapSelectionGraphContribution(
                artifactKey: key,
                definitions: [],
                references: []
            )
        case .oversize, .decodeFailed, .parseFailed:
            nil
        }
        let record = try CodeMapRootManifestRecord.verifiedClean(
            namespace: namespace,
            repositoryRelativePath: repositoryPath,
            gitMode: .regular,
            association: association,
            contribution: contribution,
            authority: CodeMapRootManifestAuthority(
                namespace: namespace,
                token: fixture.authority.capability.repositoryAuthority
            ),
            bindingGeneration: 1
        )
        return CleanReadyFixture(
            record: record,
            binding: binding,
            completion: completion,
            handle: handle,
            adoption: WorkspaceCodemapLiveManifestAdoptionEntry(
                record: record,
                binding: binding,
                lease: lease
            )
        )
    }

    private func makeManifest(
        fixture: RootFixture,
        records: [CodeMapRootManifestRecord],
        generation: UInt64 = 1,
        lastAccessEpochSeconds: UInt64 = 0,
        namespace: CodeMapRootManifestNamespace? = nil
    ) throws -> CodeMapRootManifestSnapshot {
        let namespace = namespace ?? fixture.namespace
        return try CodeMapRootManifestSnapshot(
            namespace: namespace,
            authority: CodeMapRootManifestAuthority(
                namespace: namespace,
                token: fixture.authority.capability.repositoryAuthority
            ),
            manifestGeneration: generation,
            lastAccessEpochSeconds: lastAccessEpochSeconds,
            records: records.sorted {
                $0.repositoryRelativePath.utf8.lexicographicallyPrecedes($1.repositoryRelativePath.utf8)
            }
        )
    }

    private func requireSendable(_: (some Sendable).Type) {}

    private func assertEqualValue<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    private func assertTrueValue(
        _ actual: Bool,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(actual, message, file: file, line: line)
    }

    private func assertNotEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotEqual(actual, expected, message, file: file, line: line)
    }

    private func assertFalseValue(
        _ actual: Bool,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(actual, message, file: file, line: line)
    }

    private func assertNilValue(
        _ actual: (some Any)?,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(actual, message, file: file, line: line)
    }

    private func unwrapValue<T>(
        _ actual: T?,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(actual, message, file: file, line: line)
    }

    private func manifestTicket(
        _ fixture: RootFixture,
        namespace: CodeMapRootManifestNamespace? = nil
    ) async throws -> WorkspaceCodemapLiveManifestAdoptionTicket {
        let ticket = await fixture.overlay.beginManifestAdoption(
            rootEpoch: fixture.rootEpoch,
            namespace: namespace ?? fixture.namespace
        )
        return try unwrapValue(ticket)
    }

    private func startedTicket(
        _ disposition: WorkspaceCodemapLiveDemandDisposition
    ) throws -> WorkspaceCodemapLiveDemandTicket {
        guard case let .started(ticket) = disposition else {
            throw TestError.demandFailed
        }
        return ticket
    }

    private func acceptedReady(
        _ disposition: WorkspaceCodemapLiveCompletionDisposition
    ) throws -> WorkspaceCodemapLiveReadySnapshot {
        guard case let .accepted(ready) = disposition else {
            throw TestError.completionFailed
        }
        return ready
    }

    private func requireHandle(
        _ store: CodeMapArtifactStore,
        key: CodeMapArtifactKey
    ) async throws -> CodeMapArtifactHandle {
        switch try await store.lookup(key: key) {
        case let .hit(_, handle): handle
        case .miss: throw TestError.artifactMissing
        }
    }

    private func repositoryRelativePath(fixture: RootFixture, path: String) -> String {
        let prefix = fixture.authority.capability.repositoryRelativeLoadedRootPrefix
        return prefix.isEmpty ? path : prefix + "/" + path
    }

    private func makeArtifact(name: String) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: [],
            classes: [ClassInfo(name: name, methods: [], properties: [])],
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }

    private func repositoryAuthority(
        like value: WorkspaceCodemapRepositoryAuthorityToken,
        authorityGeneration: UInt64
    ) -> WorkspaceCodemapRepositoryAuthorityToken {
        WorkspaceCodemapRepositoryAuthorityToken(
            authorityGeneration: authorityGeneration,
            repositoryNamespace: value.repositoryNamespace,
            objectFormat: value.objectFormat,
            repositoryBindingEpoch: value.repositoryBindingEpoch,
            worktreeBindingEpoch: value.worktreeBindingEpoch,
            layoutGeneration: value.layoutGeneration,
            indexGeneration: value.indexGeneration,
            checkoutConfigurationGeneration: value.checkoutConfigurationGeneration,
            attributeGeneration: value.attributeGeneration,
            sparseGeneration: value.sparseGeneration,
            metadataGeneration: value.metadataGeneration
        )
    }

    private func capability(
        like value: GitCodemapRootCapability,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    ) -> GitCodemapRootCapability {
        GitCodemapRootCapability(
            rootEpoch: value.rootEpoch,
            repositoryLayout: value.repositoryLayout,
            repositoryIdentity: value.repositoryIdentity,
            worktreeID: value.worktreeID,
            repositoryNamespace: value.repositoryNamespace,
            objectFormat: value.objectFormat,
            repositoryRelativeLoadedRootPrefix: value.repositoryRelativeLoadedRootPrefix,
            repositoryAuthority: repositoryAuthority
        )
    }

    private func eventually(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while await !condition() {
            if ContinuousClock.now - start > .nanoseconds(Int64(timeoutNanoseconds)) {
                throw TestError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

private actor OverlayFirstCommitGate {
    private var firstCommitEntered = false
    private var firstCommitReleased = false
    private var commitCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() async {
        commitCount += 1
        guard commitCount == 1 else { return }
        firstCommitEntered = true
        if firstCommitReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFirstCommit() async {
        while !firstCommitEntered {
            await Task.yield()
        }
    }

    func releaseFirstCommit() {
        firstCommitReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/// The lock linearizes the instrumentation counter captured by the overlay's
/// checked `@Sendable` traversal hook.
private final class ManifestRecordEqualityTraversalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var traversalCount: Int {
        lock.withLock { count }
    }

    func recordTraversal() {
        lock.withLock {
            let (next, overflow) = count.addingReportingOverflow(1)
            count = overflow ? .max : next
        }
    }
}

private struct RootFixture {
    let authority: WorkspaceCodemapAuthorityTestFixture
    let overlay: WorkspaceCodemapLiveOverlay
    let artifactStore: CodeMapArtifactStore
    let namespace: CodeMapRootManifestNamespace
    let catalogGeneration: UInt64

    var rootEpoch: WorkspaceCodemapRootEpoch {
        authority.capability.rootEpoch
    }

    func cleanup() {
        authority.repositoryFixture.cleanup()
    }
}

private struct ReadyFixture {
    let token: WorkspaceCodemapArtifactRequestToken
    let completion: WorkspaceCodemapArtifactCompletion
    let handle: CodeMapArtifactHandle
    let lease: CodeMapArtifactLease
}

private struct CleanReadyFixture {
    let record: CodeMapRootManifestRecord
    let binding: WorkspaceCodemapArtifactBinding
    let completion: WorkspaceCodemapArtifactCompletion
    let handle: CodeMapArtifactHandle
    let adoption: WorkspaceCodemapLiveManifestAdoptionEntry
}

private extension CodeMapSyntaxArtifactOutcome {
    var artifact: CodeMapSyntaxArtifact? {
        guard case let .ready(artifact) = self else { return nil }
        return artifact
    }
}

private enum TestError: Error {
    case registrationFailed
    case demandFailed
    case completionFailed
    case artifactMissing
    case artifactOutcomeMismatch
    case cleanSourceExpected
    case timeout
}
