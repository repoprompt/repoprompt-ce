import CoreServices
import Foundation
@testable import RepoPrompt
import XCTest

final class GitLoadedRootAuthorityEvidenceTests: XCTestCase {
    func testPrunedRootDiagnosticsRemainCompleteBeyondFormerCountCap() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        try "ignored-*/\n".write(
            to: fixture.root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        for index in 0 ..< 65 {
            try FileManager.default.createDirectory(
                at: fixture.root.appendingPathComponent("ignored-\(index)", isDirectory: true),
                withIntermediateDirectories: false
            )
        }
        _ = try fixture.runGit(["add", ".gitignore"])
        _ = try fixture.runGit(["commit", "-q", "-m", "ignored roots"])

        let git = GitService(workspaceStateAuthority: GitWorkspaceStateAuthority())
        let captured = try await git.workspaceAuthoritySnapshot(
            in: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            cacheMode: .bypassReadAndAdmission
        )
        let diagnostics = try XCTUnwrap(captured.snapshot.policyIdentity.canonicalizationDiagnostics)
        XCTAssertEqual(diagnostics.completeness, .complete)
        XCTAssertEqual(diagnostics.prunedRootCount, 65)
        XCTAssertEqual(diagnostics.prunedRootSummarySHA256.utf8.count, 64)
    }

    func testCommittedControlDiagnosticsRemainCompleteBeyondFormerRecordCap() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        try fixture.importCommittedControls(count: 4097)

        let git = GitService(workspaceStateAuthority: GitWorkspaceStateAuthority())
        let captured = try await git.workspaceAuthoritySnapshot(
            in: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            cacheMode: .bypassReadAndAdmission
        )
        let diagnostics = try XCTUnwrap(captured.snapshot.policyIdentity.canonicalizationDiagnostics)
        XCTAssertEqual(diagnostics.completeness, .complete)
        XCTAssertEqual(diagnostics.committedControlCount, 4097)
        XCTAssertEqual(diagnostics.committedControlSummarySHA256.utf8.count, 64)
    }

    func testWarmPrefixControlCacheHitReplaysCanonicalizationDetail() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let detail = GitPrefixControlCollectionDetail(
            collectionCompleted: true,
            ignoreControlCount: 1,
            attributeControlCount: 0,
            prunedRootCount: 1,
            prunedRootSummarySHA256: String(repeating: "a", count: 64)
        )
        let counter = PrefixControlCollectedEvidenceCounter(evidence: .init(
            footer: prefixFooter(),
            collectionDetail: detail
        ))

        let first = try await authority.prefixControlEvidenceWithDetail(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        let warm = try await authority.prefixControlEvidenceWithDetail(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }

        XCTAssertEqual(first.collectionDetail, detail)
        XCTAssertEqual(warm.collectionDetail, detail)
        let collectionCount = await counter.collectionCount()
        XCTAssertEqual(collectionCount, 1)
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.prefixControlCacheHitCount, 1)
    }

    func testDetailRequestRescansCacheEntryWithoutCanonicalizationDetail() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let footerCounter = PrefixControlCollectorCounter(footer: prefixFooter())
        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await footerCounter.collect() }
        let detail = GitPrefixControlCollectionDetail(
            collectionCompleted: true,
            ignoreControlCount: 1,
            attributeControlCount: 0,
            prunedRootCount: 0,
            prunedRootSummarySHA256: String(repeating: "b", count: 64)
        )
        let detailCounter = PrefixControlCollectedEvidenceCounter(evidence: .init(
            footer: prefixFooter(),
            collectionDetail: detail
        ))

        let rescanned = try await authority.prefixControlEvidenceWithDetail(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await detailCounter.collect() }

        XCTAssertEqual(rescanned.collectionDetail, detail)
        let footerCollectionCount = await footerCounter.collectionCount()
        let detailCollectionCount = await detailCounter.collectionCount()
        XCTAssertEqual(footerCollectionCount, 1)
        XCTAssertEqual(detailCollectionCount, 1)
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)
    }

    func testAutomaticAuthorityCapturesShareOnePhysicalPrefixScanAndWarmCaptureHits() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let scope = GitWorkspaceAuthorityScopeKey(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout),
            repositoryRelativeRootPrefix: prefix
        )

        let discovery = try await git.workspaceAuthoritySnapshot(in: fixture.layout, prefix: prefix)
        let captureToken = try await authority.beginCollection(scopeKey: scope).get()
        let captured = try await git.workspaceAuthoritySnapshot(in: fixture.layout, prefix: prefix)
        _ = try await authority.install(captured.snapshot, capturedUsing: captureToken).get()
        var counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.prefixControlCacheMissCount, 1)
        XCTAssertEqual(counters.prefixControlCacheHitCount, 1)
        XCTAssertEqual(counters.prefixControlCacheAdmissionCount, 1)
        XCTAssertEqual(discovery.snapshot, captured.snapshot)
        XCTAssertEqual(
            discovery.snapshot.policyIdentity.canonicalizationDiagnostics?.completeness,
            .complete
        )
        XCTAssertEqual(
            captured.snapshot.policyIdentity.canonicalizationDiagnostics?.completeness,
            .complete
        )

        let warm = try await git.workspaceAuthoritySnapshot(in: fixture.layout, prefix: prefix)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.prefixControlCacheHitCount, 2)
        XCTAssertEqual(warm.snapshot, captured.snapshot)
        XCTAssertEqual(
            warm.snapshot.policyIdentity.canonicalizationDiagnostics?.completeness,
            .complete
        )

        let bypassAuthority = GitWorkspaceStateAuthority()
        let bypassGit = GitService(workspaceStateAuthority: bypassAuthority)
        let bypassA = try await bypassGit.workspaceAuthoritySnapshot(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .bypassReadAndAdmission
        )
        let bypassB = try await bypassGit.workspaceAuthoritySnapshot(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .bypassReadAndAdmission
        )
        let bypassCounters = await bypassAuthority.snapshotForTesting()
        XCTAssertEqual(bypassCounters.prefixControlPhysicalScanCount, 2)
        XCTAssertEqual(bypassCounters.prefixControlCacheBypassCount, 2)
        XCTAssertEqual(bypassCounters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(bypassA.snapshot, bypassB.snapshot)
        XCTAssertEqual(bypassA.snapshot, captured.snapshot)
    }

    func testIdenticalPrefixCollectionCoalescesAndWaiterCancellationIsScoped() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let gate = PrefixControlCollectorGate(footer: prefixFooter())

        let first = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        await gate.waitUntilCollectionStarts()
        let second = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        try await waitUntil { await authority.snapshotForTesting().prefixControlCacheCoalescedWaiterCount == 1 }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected cancelled waiter")
        } catch is CancellationError {}
        await gate.release()
        let secondValue = try await second.value
        let collectionCount = await gate.collectionCount()
        XCTAssertEqual(secondValue, prefixFooter())
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(collectionCount, 1)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 0)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.pendingPrefixControlArtifactBytes, 0)
    }

    func testMonitorGapThenPrefixMissAndHitNeverRestoreRepositoryMetadataCoverage() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let key = GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout)
        let scope = GitWorkspaceAuthorityScopeKey(
            repositoryKey: key,
            repositoryRelativeRootPrefix: prefix
        )
        let counter = PrefixControlCollectorCounter(footer: prefixFooter())

        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        await authority.metadataDidChange(repositoryKey: key, kinds: [.monitorGap])

        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }

        let collectionCount = await counter.collectionCount()
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(collectionCount, 2)
        XCTAssertEqual(counters.prefixControlCacheMissCount, 2)
        XCTAssertEqual(counters.prefixControlCacheHitCount, 1)
        switch await authority.beginCollection(scopeKey: scope) {
        case .success:
            XCTFail("Narrow prefix-control coverage must not restore repository metadata coverage")
        case let .failure(reason):
            XCTAssertEqual(reason, .monitorCoverageUnavailable)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var fullObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var lastFailure: String?
        while clock.now < deadline, fullObservation == nil {
            let candidate = try await authority.retainMetadataObservation(for: fixture.layout)
            switch await authority.beginCollection(scopeKey: scope) {
            case .success:
                fullObservation = candidate
            case let .failure(reason):
                lastFailure = String(describing: reason)
                await authority.releaseMetadataObservation(candidate)
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        guard let fullObservation else {
            XCTFail("Validated full metadata coverage must restore collection: \(lastFailure ?? "<none>")")
            return
        }
        await authority.releaseMetadataObservation(fullObservation)
    }

    func testSaturatedAdmissionUsesOneBoundedUncachedFlightForIdenticalCalls() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority(prefixControlCacheLimits: .init(
            maximumEntryCount: 2,
            maximumEntriesPerRepository: 2,
            maximumResidentBytes: 1024,
            maximumArtifactBytes: 0,
            maximumPendingAdmissionCount: 1,
            maximumPendingResidentBytes: 512,
            maximumPendingArtifactBytes: 0
        ))
        let firstGate = PrefixControlCollectorGate(footer: prefixFooter())
        let saturatedGate = PrefixControlCollectorGate(footer: prefixFooter())

        let first = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                cacheMode: .automatic
            ) { try await firstGate.collect() }
        }
        await firstGate.waitUntilCollectionStarts()

        let saturatedA = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix("Sources"),
                cacheMode: .automatic
            ) { try await saturatedGate.collect() }
        }
        await saturatedGate.waitUntilCollectionStarts()
        let saturatedB = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix("Sources"),
                cacheMode: .automatic
            ) { try await saturatedGate.collect() }
        }
        try await waitUntil {
            await authority.snapshotForTesting().prefixControlCacheCoalescedWaiterCount == 1
        }

        var counters = await authority.snapshotForTesting()
        let saturatedCollectionCount = await saturatedGate.collectionCount()
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 2)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 1024)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)
        XCTAssertEqual(saturatedCollectionCount, 1)

        await saturatedGate.release()
        let saturatedAValue = try await saturatedA.value
        let saturatedBValue = try await saturatedB.value
        XCTAssertEqual(saturatedAValue, prefixFooter())
        XCTAssertEqual(saturatedBValue, prefixFooter())
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 512)

        await firstGate.release()
        _ = try await first.value
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 0 }
    }

    func testSoleWaiterCancellationRetainsFlightResourcesUntilSlowCollectorCompletes() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let gate = PrefixControlCollectorGate(footer: prefixFooter())

        let waiter = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        await gate.waitUntilCollectionStarts()
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected waiter cancellation")
        } catch is CancellationError {}

        var counters = await authority.snapshotForTesting()
        var monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 512)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 1)

        await gate.release()
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 0 }
        counters = await authority.snapshotForTesting()
        monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.pendingPrefixControlArtifactBytes, 0)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)
    }

    func testCancelledSameKeyFlightRemainsAuthoritativeUntilPhysicalCompletion() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let gate = PrefixControlCollectorGate(footer: prefixFooter())

        let first = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        await gate.waitUntilCollectionStarts()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected first waiter cancellation")
        } catch is CancellationError {}

        do {
            _ = try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
            XCTFail("Expected bounded rejection while cancelled physical flight remains active")
        } catch let error as GitPrefixControlEvidenceCacheError {
            XCTAssertEqual(error, .resourceAdmission)
        }

        var counters = await authority.snapshotForTesting()
        var monitorState = await monitor.snapshotForTesting()
        var collectionCount = await gate.collectionCount()
        XCTAssertEqual(collectionCount, 1)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 512)
        XCTAssertEqual(monitorState.retainTokenCount, 1)

        await gate.release()
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 0 }
        counters = await authority.snapshotForTesting()
        monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.pendingPrefixControlArtifactBytes, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)

        let retry = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { try await gate.collect() }
        XCTAssertEqual(retry, prefixFooter())
        counters = await authority.snapshotForTesting()
        collectionCount = await gate.collectionCount()
        XCTAssertEqual(collectionCount, 2)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)

        await authority.metadataDidChange(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout),
            kinds: [.monitorGap]
        )
        monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(monitorState.retainTokenCount, 0)
    }

    func testCancelledUncachedSameKeyFlightRemainsAuthoritativeUntilPhysicalCompletion() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(
            metadataMonitor: monitor,
            prefixControlCacheLimits: .init(
                maximumEntryCount: 1,
                maximumEntriesPerRepository: 1,
                maximumResidentBytes: 512,
                maximumArtifactBytes: 0,
                maximumPendingAdmissionCount: 1,
                maximumPendingResidentBytes: 1,
                maximumPendingArtifactBytes: 0
            )
        )
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let gate = PrefixControlCollectorGate(footer: prefixFooter())

        let first = Task {
            try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
        }
        await gate.waitUntilCollectionStarts()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected first uncached waiter cancellation")
        } catch is CancellationError {}

        do {
            _ = try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: prefix,
                cacheMode: .automatic
            ) { try await gate.collect() }
            XCTFail("Expected bounded rejection while cancelled uncached flight remains active")
        } catch let error as GitPrefixControlEvidenceCacheError {
            XCTAssertEqual(error, .resourceAdmission)
        }

        var counters = await authority.snapshotForTesting()
        var monitorState = await monitor.snapshotForTesting()
        var collectionCount = await gate.collectionCount()
        XCTAssertEqual(collectionCount, 1)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 1)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 512)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)

        await gate.release()
        try await waitUntil { await authority.snapshotForTesting().pendingPrefixControlAdmissionCount == 0 }
        counters = await authority.snapshotForTesting()
        monitorState = await monitor.snapshotForTesting()
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.pendingPrefixControlArtifactBytes, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)

        let retry = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { try await gate.collect() }
        XCTAssertEqual(retry, prefixFooter())
        counters = await authority.snapshotForTesting()
        monitorState = await monitor.snapshotForTesting()
        collectionCount = await gate.collectionCount()
        XCTAssertEqual(collectionCount, 2)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)
        XCTAssertEqual(counters.pendingPrefixControlAdmissionCount, 0)
        XCTAssertEqual(counters.pendingPrefixControlResidentBytes, 0)
        XCTAssertEqual(counters.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(monitorState.retainTokenCount, 0)
    }

    func testAcceptedWatermarkInvalidatesCachedFooterBeforeActorDelivery() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let counter = PrefixControlCollectorCounter(footer: prefixFooter())
        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        await monitor.acceptEventWithoutDeliveryForTesting(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout)
        )
        _ = try await authority.prefixControlEvidence(
            in: fixture.layout,
            prefix: prefix,
            cacheMode: .automatic
        ) { await counter.collect() }
        let collectionCount = await counter.collectionCount()
        XCTAssertEqual(collectionCount, 2)
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)
        XCTAssertGreaterThanOrEqual(counters.prefixControlCacheInvalidationCount, 1)
    }

    func testCorruptFooterAndResidentBudgetNeverRetainAdmissionOrArtifacts() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let corruptAuthority = GitWorkspaceStateAuthority()
        let corrupt = GitPrefixControlEvidenceManifestFooter(
            recordCount: 0,
            recordPayloadByteCount: 0,
            pathPayloadByteCount: 0,
            ignoreControlDigest: Data(),
            attributeControlDigest: Data(repeating: 1, count: 32),
            artifactDigest: Data(repeating: 2, count: 32)
        )
        do {
            _ = try await corruptAuthority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                cacheMode: .automatic
            ) { corrupt }
            XCTFail("Expected corrupt footer rejection")
        } catch let error as GitPrefixControlEvidenceCacheError {
            XCTAssertEqual(error, .corruptFooter)
        }
        var snapshot = await corruptAuthority.snapshotForTesting()
        XCTAssertEqual(snapshot.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(snapshot.pendingPrefixControlAdmissionCount, 0)
        XCTAssertEqual(snapshot.prefixControlCacheArtifactBytes, 0)

        let bounded = GitWorkspaceStateAuthority(prefixControlCacheLimits: .init(
            maximumEntryCount: 1,
            maximumEntriesPerRepository: 1,
            maximumResidentBytes: 1,
            maximumArtifactBytes: 0,
            maximumPendingAdmissionCount: 1,
            maximumPendingResidentBytes: 512,
            maximumPendingArtifactBytes: 0
        ))
        let counter = PrefixControlCollectorCounter(footer: prefixFooter())
        for _ in 0 ..< 2 {
            _ = try await bounded.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                cacheMode: .automatic
            ) { await counter.collect() }
        }
        snapshot = await bounded.snapshotForTesting()
        let boundedCollectionCount = await counter.collectionCount()
        XCTAssertEqual(boundedCollectionCount, 2)
        XCTAssertEqual(snapshot.prefixControlCacheEntryCount, 0)
        XCTAssertEqual(snapshot.prefixControlCacheResidentBytes, 0)
        XCTAssertEqual(snapshot.prefixControlCacheArtifactBytes, 0)
        XCTAssertEqual(snapshot.pendingPrefixControlAdmissionCount, 0)
        XCTAssertEqual(snapshot.prefixControlCacheEvictionCount, 2)
    }

    func testMonitorUnavailableFallsBackWithoutAdmissionAndTypedMatcherFailsClosed() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor(maximumPathsPerRepository: 1)
        let key = GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout)
        let retained = try await monitor.retain(
            repositoryKey: key,
            paths: [fixture.layout.gitDir.appendingPathComponent("HEAD")]
        ) { _ in }
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let counter = PrefixControlCollectorCounter(footer: prefixFooter())
        for _ in 0 ..< 2 {
            _ = try await authority.prefixControlEvidence(
                in: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix("Sources"),
                cacheMode: .automatic
            ) { await counter.collect() }
        }
        let snapshot = await authority.snapshotForTesting()
        let collectionCount = await counter.collectionCount()
        XCTAssertEqual(collectionCount, 2)
        XCTAssertEqual(snapshot.prefixControlCacheEntryCount, 0)

        let prefix = try GitRepositoryRelativeRootPrefix("Sources/Nested")
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let directoryCreateFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated
        )
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent(".gitignore").path,
            flags: fileFlag
        ))
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent("Sources/Nested/NewDirectory").path,
            flags: directoryCreateFlags
        ))
        XCTAssertFalse(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent(".git/objects/.gitignore").path,
            flags: fileFlag
        ))
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent("Sources/Nested/Child/.git").path,
            flags: directoryCreateFlags
        ))
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent("Sources/.git").path,
            flags: fileFlag
        ))
        XCTAssertFalse(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent("Sources/Nested/Child/.git/HEAD").path,
            flags: fileFlag
        ))
        XCTAssertFalse(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: fixture.root.appendingPathComponent("Sources/ordinary.swift").path,
            flags: fileFlag
        ))
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rpce-metadata-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalControl = external.appendingPathComponent("external-ignore")
        try "Generated/\n".write(to: externalControl, atomically: true, encoding: .utf8)
        let linkedControl = fixture.root.appendingPathComponent(".gitignore")
        try FileManager.default.createSymbolicLink(at: linkedControl, withDestinationURL: externalControl)
        let symlinkFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsSymlink | kFSEventStreamEventFlagItemCreated
        )
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: linkedControl.path,
            flags: symlinkFlags
        ))

        let sources = fixture.root.appendingPathComponent("Sources", isDirectory: true)
        let nestedScope = sources.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedScope, withIntermediateDirectories: true)
        let linkedDirectory = nestedScope.appendingPathComponent("LinkedDirectory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: external)
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: linkedDirectory.path,
            flags: symlinkFlags
        ))

        let nestedParent = nestedScope.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedParent, withIntermediateDirectories: true)
        let externalGit = external.appendingPathComponent("external-git", isDirectory: true)
        try FileManager.default.createDirectory(at: externalGit, withIntermediateDirectories: true)
        let linkedGit = nestedParent.appendingPathComponent(".git")
        try FileManager.default.createSymbolicLink(at: linkedGit, withDestinationURL: externalGit)
        XCTAssertTrue(try GitWorkspaceMetadataMonitor.prefixControlScopeMatchesForTesting(
            repositoryRoot: fixture.root,
            prefix: prefix,
            eventPath: linkedGit.path,
            flags: symlinkFlags
        ))
        await monitor.release(retained)
    }

    func testLazyPrefixCollectorCrossesLegacyTenThousandBoundaryAndFindsLateControl() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let late = fixture.root.appendingPathComponent("late/.gitignore")
        try FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "late-control\n".write(to: late, atomically: true, encoding: .utf8)

        let beyondLimit = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: 10001, lateControl: late)
        let baseline = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: 0, lateControl: late)
        let streamed = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: [],
            candidateSource: beyondLimit
        )
        let expected = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: [],
            candidateSource: baseline
        )

        XCTAssertEqual(streamed.recordCount, 1)
        XCTAssertEqual(streamed.ignoreControlDigest, expected.ignoreControlDigest)
        XCTAssertEqual(streamed.attributeControlDigest, expected.attributeControlDigest)
        XCTAssertEqual(beyondLimit.emittedNoiseCount, 10001)
    }

    func testRepositoryUnderDotGitNamedAncestorStillEnumeratesDescendantControls() async throws {
        let fixture = try AuthorityEvidenceFixture(rootAncestorComponents: [".git", "ancestor"])
        defer { fixture.cleanup() }
        let control = fixture.root.appendingPathComponent("Sources/.gitignore")
        try FileManager.default.createDirectory(
            at: control.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "*.generated\n".write(to: control, atomically: true, encoding: .utf8)

        let evidence = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )

        XCTAssertEqual(evidence.recordCount, 1)
        XCTAssertGreaterThan(evidence.pathPayloadByteCount, 0)
    }

    func testPrefixControlReaderSerializesConcurrentConsumers() async throws {
        let store = try GitPrefixControlEvidenceManifestStore()
        let writer = try store.makeWriter(rootPrefixBytes: Data())
        let recordCount = 64
        for index in 0 ..< recordCount {
            try await writer.append(GitPrefixControlEvidenceRecord(
                repositoryRelativePathBytes: Data(String(format: "controls/%03d/.gitignore", index).utf8),
                kind: .gitignore,
                content: GitWorkspaceAuthorityContentIdentity(
                    exists: true,
                    sha256: String(repeating: "a", count: 64),
                    byteCount: index
                )
            ))
        }
        var lease: GitPrefixControlEvidenceManifestLease? = try await writer.finish()
        let paths: [Data]
        let validationState: GitPrefixControlEvidenceReaderValidationState
        do {
            let reader = try XCTUnwrap(lease).makeReader()
            paths = try await withThrowingTaskGroup(of: Data?.self) { group in
                for _ in 0 ... recordCount {
                    group.addTask { try await reader.next()?.repositoryRelativePathBytes }
                }
                var values: [Data] = []
                for try await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            validationState = await reader.validationState
        }

        XCTAssertEqual(paths.count, recordCount)
        XCTAssertEqual(Set(paths).count, recordCount)
        XCTAssertEqual(validationState, .verified)
        lease = nil
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
    }

    func testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded() async throws {
        try await exerciseLargeLogicalStream(recordCount: 100_000)
    }

    func testMillionLogicalCandidatesAndTreeRecordsStayByteBoundedWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RPCE_RUN_MILLION_RECORD_GIT_AUTHORITY_TESTS"] == "1",
            "Set RPCE_RUN_MILLION_RECORD_GIT_AUTHORITY_TESTS=1 for the required slow lane"
        )
        try await exerciseLargeLogicalStream(recordCount: 1_000_000)
    }

    func testCorruptionCancellationAndResourceFailureCleanArtifacts() async throws {
        let header = try inventoryHeader()

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let writer = try store.makeWriter(header: header)
            try await writer.append(inventoryRecord(path: "A.swift"))
            var lease: WorkspaceRootReusableInventoryManifestLease? = try await writer.finish()
            let handle = try FileHandle(forWritingTo: XCTUnwrap(lease).fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x7F]))
            try handle.close()
            XCTAssertThrowsError(try lease?.makeReader())
            lease = nil
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        }

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let policy = WorkspaceRootReusableInventoryResourcePolicy(
                maximumBufferedRecordBytes: 512,
                maximumRecordsPerBatch: 2,
                maximumRecordByteCount: 1024,
                maximumOpenRuns: 2,
                minimumFreeDiskBytes: 0,
                maximumAggregateArtifactBytes: 64 * 1024 * 1024
            )
            let writer = try store.makeWriter(header: header, resourcePolicy: policy)
            for index in 0 ..< 8 {
                try await writer.append(inventoryRecord(path: String(format: "cancel-%07d.swift", index)))
            }
            XCTAssertTrue(containsSpillRun(in: store.directoryURL), "cancellation must begin after a spill run exists")
            let task = Task {
                for index in 8 ..< 1_000_000 {
                    try await writer.append(self.inventoryRecord(path: String(format: "cancel-%07d.swift", index)))
                    await Task.yield()
                }
            }
            await Task.yield()
            task.cancel()
            do {
                try await task.value
                XCTFail("Expected deterministic cancellation")
            } catch is CancellationError {}
            await writer.cancel()
            try store.cleanup()
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
        }

        do {
            let store = try WorkspaceRootReusableInventoryManifestStore()
            let policy = WorkspaceRootReusableInventoryResourcePolicy(
                maximumBufferedRecordBytes: 256,
                maximumRecordsPerBatch: 2,
                maximumRecordByteCount: 1024,
                maximumOpenRuns: 2,
                minimumFreeDiskBytes: 0,
                maximumAggregateArtifactBytes: 512
            )
            let writer = try store.makeWriter(header: header, resourcePolicy: policy)
            do {
                for index in 0 ..< 32 {
                    try await writer.append(inventoryRecord(path: "resource-\(index).swift"))
                }
                _ = try await writer.finish()
                XCTFail("Expected aggregate byte admission failure")
            } catch let error as WorkspaceRootReusableInventoryManifestError {
                XCTAssertEqual(error, .resourceAdmission)
            }
            await writer.cancel()
            try store.cleanup()
            XCTAssertTrue(store.activeArtifactURLs.isEmpty)
        }
    }

    func testArtifactBudgetIncludesPendingReservationsAndFailsClosed() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let sourceAuthority = GitWorkspaceStateAuthority()
        let sourceCoordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: sourceAuthority),
            authority: sourceAuthority
        )
        guard case .admitted = await sourceCoordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: ["A.swift"]
        ) else { return XCTFail("Expected source snapshot admission") }
        let sourceLease: GitWorkspaceAuthorityLease
        switch try await sourceAuthority.currentLease(
            for: GitWorkspaceAuthorityRepositoryKey(layout: fixture.layout),
            prefix: GitRepositoryRelativeRootPrefix("")
        ) {
        case let .success(value): sourceLease = value
        case let .failure(reason): return XCTFail("Missing source authority: \(reason)")
        }
        let currentReusable = await sourceAuthority.currentReusableSnapshot(capturedUsing: sourceLease)
        let reusable = try XCTUnwrap(currentReusable)
        let artifactBytes = reusable.artifactByteCount
        XCTAssertGreaterThan(artifactBytes, 0)

        let authority = GitWorkspaceStateAuthority(
            reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits(
                maximumSnapshotCount: 4,
                maximumSnapshotsPerRepository: 4,
                maximumEstimatedBytes: 8 * 1024 * 1024,
                maximumArtifactBytes: artifactBytes
            )
        )
        let lease = try await authority.install(sourceLease.snapshot)
        let firstObservation = try await authority.retainMetadataObservation(for: fixture.layout)
        let preparedFirst = await authority.prepareReusableSnapshotAdmission(
            reusable,
            capturedUsing: lease,
            observationToken: firstObservation
        )
        let first = try XCTUnwrap(preparedFirst)
        var counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 1)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, 0)
        XCTAssertEqual(counters.reusableSnapshotArtifactBudgetRejectionCount, 0)

        let rejectedObservation = try await authority.retainMetadataObservation(for: fixture.layout)
        let rejected = await authority.prepareReusableSnapshotAdmission(
            reusable,
            capturedUsing: lease,
            observationToken: rejectedObservation
        )
        XCTAssertNil(rejected)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 1)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertEqual(counters.reusableSnapshotArtifactBudgetRejectionCount, 1)

        let admittedReceipt = await authority.admitPreparedReusableSnapshot(first)
        let receipt = try XCTUnwrap(admittedReceipt)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.pendingReusableSnapshotAdmissionCount, 0)
        XCTAssertEqual(counters.pendingReusableSnapshotArtifactBytes, 0)
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, artifactBytes)
        XCTAssertLessThanOrEqual(counters.reusableSnapshotArtifactBytes, artifactBytes)
        await authority.revokeReusableSnapshotAdmission(receipt)
        counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.reusableSnapshotArtifactBytes, 0)
    }

    private func prefixFooter() -> GitPrefixControlEvidenceManifestFooter {
        GitPrefixControlEvidenceManifestFooter(
            recordCount: 1,
            recordPayloadByteCount: 32,
            pathPayloadByteCount: 10,
            ignoreControlDigest: Data(repeating: 1, count: 32),
            attributeControlDigest: Data(repeating: 2, count: 32),
            artifactDigest: Data(repeating: 3, count: 32)
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        } while Date() < deadline
        XCTFail("Timed out waiting for deterministic cache state", file: file, line: line)
    }

    func testStaleCatalogBatchFailsClosedAndLeavesNoReusableAdmission() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let result = await coordinator.observeStreamedAuthoritativeFullLoad(
            rootURL: fixture.root,
            catalogBatchEvidenceProvider: { _ in .stale(.loadedRootWatcherStale) }
        )
        XCTAssertEqual(
            result,
            .failed(.init(stage: .catalogClassification, cause: .loadedRootWatcherStale))
        )
        let snapshot = await authority.snapshotForTesting()
        XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
        XCTAssertEqual(snapshot.reusableSnapshotAliasCount, 0)
        XCTAssertEqual(snapshot.reusableSnapshotEstimatedBytes, 0)
        XCTAssertEqual(snapshot.reusableSnapshotArtifactBytes, 0)
    }

    private func exerciseLargeLogicalStream(recordCount: Int) async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let late = fixture.root.appendingPathComponent("late/.gitattributes")
        try FileManager.default.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "*.swift text\n".write(to: late, atomically: true, encoding: .utf8)
        let source = LazyPrefixCandidateSource(root: fixture.root, logicalNoiseCount: recordCount, lateControl: late)
        let controls = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: [],
            candidateSource: source
        )
        XCTAssertEqual(source.emittedNoiseCount, recordCount)
        XCTAssertEqual(controls.recordCount, 1)

        let store = try WorkspaceRootReusableInventoryManifestStore()
        let policy = WorkspaceRootReusableInventoryResourcePolicy(
            maximumBufferedRecordBytes: 1024 * 1024,
            maximumRecordsPerBatch: 4096,
            maximumRecordByteCount: 1024 * 1024,
            maximumOpenRuns: 4,
            minimumFreeDiskBytes: 0,
            maximumAggregateArtifactBytes: 4 * 1024 * 1024 * 1024
        )
        let writer = try store.makeWriter(header: inventoryHeader(), resourcePolicy: policy)
        let oid = String(repeating: "1", count: 40)
        var parser = try GitLoadedRootTreeInventoryStreamingParser(
            objectFormat: .sha1,
            rootPrefix: GitRepositoryRelativeRootPrefix("")
        ) { record in
            guard let mode = String(data: record.modeBytes, encoding: .utf8),
                  let oidString = String(data: record.objectIDBytes, encoding: .utf8)
            else { throw GitWorktreeInitializationError.malformedOutput("test metadata") }
            try await writer.append(WorkspaceRootReusableInventoryManifestRecord(
                rootRelativePathBytes: record.repositoryRelativePathBytes,
                mode: mode,
                kind: record.kind,
                objectID: GitObjectID(objectFormat: .sha1, lowercaseHex: oidString),
                catalogProjection: .searchableRegularFile
            ))
        }
        for index in 0 ..< recordCount {
            let path = String(format: "f%07d.swift", index)
            let frame = Data("100644 blob \(oid)\t\(path)\0".utf8)
            if index == 0 {
                for byte in frame {
                    try await parser.consume(Data([byte]))
                }
            } else {
                try await parser.consume(frame)
            }
        }
        try await parser.finish()
        var lease: WorkspaceRootReusableInventoryManifestLease? = try await writer.finish()
        var observed = 0
        do {
            let completed = try XCTUnwrap(lease)
            XCTAssertEqual(completed.footer.totalRecordCount, UInt64(recordCount))
            XCTAssertEqual(completed.footer.searchableRegularFileCount, UInt64(recordCount))
            XCTAssertGreaterThan(completed.statistics.initialRunCount, policy.maximumOpenRuns)
            XCTAssertGreaterThan(completed.statistics.mergePassCount, 1)
            XCTAssertLessThanOrEqual(completed.statistics.peakBufferedRecordBytes, policy.maximumBufferedRecordBytes)
            XCTAssertLessThanOrEqual(completed.statistics.peakResidentScheduledRunCount, policy.maximumOpenRuns)
            XCTAssertLessThanOrEqual(completed.artifactByteCount, policy.maximumAggregateArtifactBytes ?? .max)
            XCTAssertGreaterThanOrEqual(completed.statistics.peakWorkspaceByteCount, completed.artifactByteCount)
            XCTAssertGreaterThanOrEqual(
                completed.statistics.peakAggregateArtifactByteCount,
                completed.statistics.peakWorkspaceByteCount
            )
            XCTAssertLessThanOrEqual(
                completed.statistics.peakWorkspaceByteCount,
                policy.maximumAggregateArtifactBytes ?? .max
            )
            XCTAssertLessThanOrEqual(
                completed.statistics.peakAggregateArtifactByteCount,
                policy.maximumAggregateArtifactBytes ?? .max
            )
            let reader = try completed.makeReader()
            while try reader.next() != nil {
                observed += 1
            }
            XCTAssertEqual(reader.validationState, .verified)
        }
        XCTAssertEqual(observed, recordCount)
        lease = nil
        XCTAssertTrue(store.activeArtifactURLs.isEmpty)
    }

    private func containsSpillRun(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix("run.") { return true }
        }
        return false
    }

    func testReachabilityCanonicalizationRejectsInvalidUTF8MandatoryGitIgnore() async throws {
        for placement in ["root", "nested"] {
            let fixture = try AuthorityEvidenceFixture()
            defer { fixture.cleanup() }
            let control: URL
            if placement == "root" {
                control = fixture.root.appendingPathComponent(".gitignore")
            } else {
                let reachable = fixture.root.appendingPathComponent("Reachable", isDirectory: true)
                try FileManager.default.createDirectory(at: reachable, withIntermediateDirectories: true)
                control = reachable.appendingPathComponent(".gitignore")
            }
            try Data([0xFF, 0xFE, 0xFD]).write(to: control)

            do {
                _ = try await GitService.streamedPrefixControlEvidence(
                    layout: fixture.layout,
                    prefix: GitRepositoryRelativeRootPrefix(""),
                    indexedGitlinkPaths: []
                )
                XCTFail("Expected invalid mandatory .gitignore UTF-8 to fail for \(placement)")
            } catch MandatoryGitIgnoreControlError.invalidEncoding {
                // Strict mandatory decoding must reject both root and nested controls.
            } catch {
                XCTFail("Unexpected canonical reachability error for \(placement): \(error)")
            }
        }
    }

    func testReachabilityCanonicalizationPrunesControlsBelowUntraversableIgnoredDirectory() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let rootIgnore = fixture.root.appendingPathComponent(".gitignore")
        try "Generated/\n".write(to: rootIgnore, atomically: true, encoding: .utf8)

        let baseline = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        let ignoredDirectory = fixture.root.appendingPathComponent("Generated/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        try "*.tmp\n".write(
            to: ignoredDirectory.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "*.swift text\n".write(
            to: ignoredDirectory.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )

        let filtered = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertEqual(filtered.recordCount, 1)
        XCTAssertEqual(filtered.ignoreControlDigest, baseline.ignoreControlDigest)
        XCTAssertEqual(filtered.attributeControlDigest, baseline.attributeControlDigest)
    }

    func testReachabilityCanonicalizationRetainsReincludedAndOptionalVariantControls() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        try "Generated/*\n!Generated/keep/\n".write(
            to: fixture.root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "Generated/\n".write(
            to: fixture.root.appendingPathComponent(".repo_ignore"),
            atomically: true,
            encoding: .utf8
        )
        let retainedDirectory = fixture.root.appendingPathComponent("Generated/keep", isDirectory: true)
        try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
        try "*.swift text\n".write(
            to: retainedDirectory.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )

        let evidence = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertEqual(evidence.recordCount, 3)
    }

    func testGitIgnoreFloorRejectsSecondaryNegationInCanonicalAndOrdinaryTraversal() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        try "Generated/\n".write(
            to: fixture.root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let global = "!Generated/\n!Generated/keep/\n"
        let retained = fixture.root.appendingPathComponent("Generated/keep", isDirectory: true)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        try "*.swift text\n".write(
            to: retained.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )

        let authority = IgnoreRulesManager.compileRootAuthority(
            gitignoreContent: "Generated/\n",
            globalIgnoreContent: global,
            repoIgnoreContent: nil,
            cursorignoreContent: nil
        )
        let ordinaryRules = try IgnoreRulesManager.makeRootRules(
            authority: authority,
            respectRepoIgnore: true,
            respectCursorignore: true,
            policy: .gitRoot(repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""))
        )
        XCTAssertFalse(WorkspaceCatalogDirectoryReachability.shouldTraverse(
            repositoryRelativeDirectory: "Generated",
            rules: ordinaryRules.snapshot()
        ))
        let nonGitRules = IgnoreRulesManager.makeRootRules(
            authority: authority,
            respectRepoIgnore: true,
            respectCursorignore: true,
            policy: .nonGitRoot
        )
        XCTAssertTrue(WorkspaceCatalogDirectoryReachability.shouldTraverse(
            repositoryRelativeDirectory: "Generated",
            rules: nonGitRules.snapshot()
        ))

        let evidence = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: [],
            globalIgnoreDefaultsOverride: global
        )
        XCTAssertEqual(evidence.recordCount, 1)
    }

    func testSecondaryOnlyExclusionPrunesCanonicalAndOrdinaryTraversal() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let generated = fixture.root.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try "*.swift text\n".write(
            to: generated.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        let authority = IgnoreRulesManager.compileRootAuthority(
            gitignoreContent: nil,
            globalIgnoreContent: "Generated/\n",
            repoIgnoreContent: nil,
            cursorignoreContent: nil
        )
        let ordinaryRules = try IgnoreRulesManager.makeRootRules(
            authority: authority,
            respectRepoIgnore: true,
            respectCursorignore: true,
            policy: .gitRoot(repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""))
        )
        XCTAssertFalse(WorkspaceCatalogDirectoryReachability.shouldTraverse(
            repositoryRelativeDirectory: "Generated",
            rules: ordinaryRules.snapshot()
        ))

        let evidence = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: [],
            globalIgnoreDefaultsOverride: "Generated/\n"
        )
        XCTAssertEqual(evidence.recordCount, 0)
    }

    func testGitNegationWithinMandatoryChainKeepsCanonicalAndOrdinaryTraversalReachable() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let gitignore = "Generated/*\n!Generated/keep/\n"
        try gitignore.write(
            to: fixture.root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let retained = fixture.root.appendingPathComponent("Generated/keep", isDirectory: true)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        try "*.swift text\n".write(
            to: retained.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        let authority = IgnoreRulesManager.compileRootAuthority(
            gitignoreContent: gitignore,
            globalIgnoreContent: "",
            repoIgnoreContent: nil,
            cursorignoreContent: nil
        )
        let ordinaryRules = try IgnoreRulesManager.makeRootRules(
            authority: authority,
            respectRepoIgnore: true,
            respectCursorignore: true,
            policy: .gitRoot(repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""))
        )
        XCTAssertTrue(WorkspaceCatalogDirectoryReachability.shouldTraverse(
            repositoryRelativeDirectory: "Generated",
            rules: ordinaryRules.snapshot()
        ))

        let evidence = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: [],
            globalIgnoreDefaultsOverride: ""
        )
        XCTAssertEqual(evidence.recordCount, 2)
    }

    func testBuiltInSecondaryDefaultsDoNotMasqueradeAsMandatoryGitAuthority() throws {
        let global = "!.svn/\n!.DS_Store\n!Thumbs.db\n!.git/\n"
        let authority = IgnoreRulesManager.compileRootAuthority(
            gitignoreContent: nil,
            globalIgnoreContent: global,
            repoIgnoreContent: nil,
            cursorignoreContent: nil
        )
        let gitRules = try IgnoreRulesManager.makeRootRules(
            authority: authority,
            respectRepoIgnore: true,
            respectCursorignore: true,
            policy: .gitRoot(repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""))
        )

        XCTAssertFalse(gitRules.isIgnored(relativePath: ".svn", isDirectory: true))
        XCTAssertFalse(gitRules.isIgnored(relativePath: ".DS_Store", isDirectory: false))
        XCTAssertFalse(gitRules.isIgnored(relativePath: "Thumbs.db", isDirectory: false))
        XCTAssertTrue(gitRules.isIgnored(relativePath: ".git", isDirectory: true))

        let nonGitRules = IgnoreRulesManager.makeRootRules(
            authority: authority,
            respectRepoIgnore: true,
            respectCursorignore: true,
            policy: .nonGitRoot
        )
        XCTAssertFalse(nonGitRules.isIgnored(relativePath: ".git", isDirectory: true))
    }

    func testLoadedRepositorySubdirectoryKeepsGitIgnoreAsMandatoryFloor() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        try "Sources/Generated/\n".write(
            to: fixture.root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let loadedRoot = fixture.root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: loadedRoot, withIntermediateDirectories: true)
        try "!Generated/\n".write(
            to: loadedRoot.appendingPathComponent(".repo_ignore"),
            atomically: true,
            encoding: .utf8
        )

        let service = try await FileSystemService(path: loadedRoot.path)
        let generatedIsIncluded = await service.directoryIsIncludedInOrdinaryCrawl(relativePath: "Generated")
        XCTAssertFalse(generatedIsIncluded)
        let policy = await service.ignoreRulePolicy
        if case let .gitRoot(prefix) = policy {
            XCTAssertEqual(prefix.value, "Sources")
        } else {
            XCTFail("Loaded repository subdirectory must retain Git-root policy")
        }
    }

    func testLoadedRepositorySubdirectoryHonorsScopedGitNegation() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        try "Sources/Generated/\n".write(
            to: fixture.root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let loadedRoot = fixture.root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: loadedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: loadedRoot.appendingPathComponent("Generated/keep", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "!Generated/\n!Generated/keep/\n".write(
            to: loadedRoot.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        let service = try await FileSystemService(path: loadedRoot.path)
        let generatedIsIncluded = await service.directoryIsIncludedInOrdinaryCrawl(relativePath: "Generated")
        let keepIsIncluded = await service.directoryIsIncludedInOrdinaryCrawl(relativePath: "Generated/keep")
        XCTAssertTrue(generatedIsIncluded)
        XCTAssertTrue(keepIsIncluded)
    }

    func testExplicitNonGitAndBarePoliciesRemainNonGitAndAmbiguousGitFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rpce-ignore-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/main\n".write(
            to: root.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        if case .nonGitRoot = try IgnoreRulePolicy.resolvingLoadedRoot(root) {
            // A bare repository has no worktree ignore authority.
        } else {
            XCTFail("Bare/non-Git roots must keep explicit non-Git semantics")
        }

        try "not a gitfile\n".write(
            to: root.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertThrowsError(try IgnoreRulePolicy.resolvingLoadedRoot(root))
    }

    func testBogusNestedGitMarkerFailsClosedInsteadOfDroppingContainingAuthority() throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let nestedRoot = fixture.root.appendingPathComponent("Sources", isDirectory: true)
        let loadedRoot = nestedRoot.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: loadedRoot, withIntermediateDirectories: true)

        XCTAssertThrowsError(try IgnoreRulePolicy.resolvingLoadedRoot(loadedRoot))
    }

    func testValidLinkedWorktreeSubdirectoryCarriesContainingRepositoryPrefix() throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let linkedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rpce-linked-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fixture.runGit(["worktree", "remove", "--force", linkedRoot.path])
            try? FileManager.default.removeItem(at: linkedRoot)
        }
        try fixture.runGit([
            "worktree", "add", "-q", "-b", "rpce-policy-\(UUID().uuidString)", linkedRoot.path, "HEAD"
        ])
        let loadedRoot = linkedRoot.appendingPathComponent("Sources/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: loadedRoot, withIntermediateDirectories: true)

        let policy = try IgnoreRulePolicy.resolvingLoadedRoot(loadedRoot)
        guard case let .gitRoot(prefix) = policy else {
            return XCTFail("Valid linked-worktree subdirectory must retain Git authority")
        }
        XCTAssertEqual(prefix.value, "Sources/Nested")
    }

    func testMandatoryGitIgnoreSymlinkReadAndEncodingFailuresFailInitialLoad() async throws {
        for failure in ["symlink", "directory", "encoding"] {
            let fixture = try AuthorityEvidenceFixture()
            defer { fixture.cleanup() }
            let control = fixture.root.appendingPathComponent(".gitignore")
            if failure == "symlink" {
                let external = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "rpce-external-ignore-\(UUID().uuidString)"
                )
                defer { try? FileManager.default.removeItem(at: external) }
                try "Generated/\n".write(to: external, atomically: true, encoding: .utf8)
                try FileManager.default.createSymbolicLink(at: control, withDestinationURL: external)
            } else if failure == "directory" {
                try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
            } else {
                try Data([0xFF, 0xFE, 0xFD]).write(to: control)
            }

            do {
                _ = try await FileSystemService(path: fixture.root.path)
                XCTFail("Expected mandatory .gitignore \(failure) failure")
            } catch {
                // Mandatory Git authority must fail closed.
            }
        }
    }

    func testMandatoryGitIgnoreRefreshFailureRetainsInstalledPolicy() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let control = fixture.root.appendingPathComponent(".gitignore")
        try "Generated/\n".write(to: control, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Generated", isDirectory: true),
            withIntermediateDirectories: true
        )
        let service = try await FileSystemService(path: fixture.root.path)
        let initiallyIncluded = await service.directoryIsIncludedInOrdinaryCrawl(relativePath: "Generated")
        XCTAssertFalse(initiallyIncluded)

        try Data([0xFF, 0xFE]).write(to: control)
        do {
            try await service.refreshIgnoreRules()
            XCTFail("Expected refresh to reject invalid mandatory authority")
        } catch {}
        let includedAfterFailedRefresh = await service.directoryIsIncludedInOrdinaryCrawl(
            relativePath: "Generated"
        )
        XCTAssertFalse(includedAfterFailedRefresh)
    }

    func testNestedMandatoryGitIgnoreFailureDoesNotCacheParentOnlyRules() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let child = fixture.root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rpce-nested-external-ignore-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: external) }
        try "Generated/\n".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: child.appendingPathComponent(".gitignore"),
            withDestinationURL: external
        )
        let service = try await FileSystemService(path: fixture.root.path)

        let included = await service.directoryIsIncludedInOrdinaryCrawl(relativePath: "Child/Generated")
        XCTAssertFalse(included)
        let cached = await service.cachedIgnoreRules(for: "Child")
        XCTAssertNil(cached)
    }

    func testReachabilityCanonicalizationBoundsAggregateRetainedControlMemory() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        try String(repeating: "generated-file\n", count: 128).write(
            to: fixture.root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await GitService.streamedPrefixControlEvidence(
                layout: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                indexedGitlinkPaths: [],
                resourcePolicy: GitPrefixControlEvidenceResourcePolicy(
                    maximumAggregateControlBytes: 512
                ),
                globalIgnoreDefaultsOverride: ""
            )
            XCTFail("Expected aggregate retained-control budget failure")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .cappedOutput)
        }
    }

    func testDirectoryObservationMemoryUsesAggregateByteBudget() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        for index in 0 ..< 16 {
            try FileManager.default.createDirectory(
                at: fixture.root.appendingPathComponent("Directory-\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        do {
            _ = try await GitService.streamedPrefixControlEvidence(
                layout: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                indexedGitlinkPaths: [],
                resourcePolicy: GitPrefixControlEvidenceResourcePolicy(
                    maximumAggregateControlBytes: 8 * 1024
                ),
                globalIgnoreDefaultsOverride: ""
            )
            XCTFail("Expected directory-observation aggregate budget failure")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .cappedOutput)
        }
    }

    func testReachabilityCanonicalizationFinalizationFencesOmittedControlDeletionAndChange() async throws {
        for mutation in ["delete", "change"] {
            let fixture = try AuthorityEvidenceFixture()
            defer { fixture.cleanup() }
            let control = fixture.root.appendingPathComponent(".gitignore")
            try "Generated/\n".write(to: control, atomically: true, encoding: .utf8)
            let source = MutatingEmptyPrefixCandidateSource {
                if mutation == "delete" {
                    try FileManager.default.removeItem(at: control)
                } else {
                    try "Changed/\n".write(to: control, atomically: true, encoding: .utf8)
                }
            }

            do {
                _ = try await GitWorkspaceStateAuthority().prefixControlEvidence(
                    in: fixture.layout,
                    prefix: GitRepositoryRelativeRootPrefix(""),
                    cacheMode: .bypassReadAndAdmission
                ) {
                    try await GitService.streamedPrefixControlEvidence(
                        layout: fixture.layout,
                        prefix: GitRepositoryRelativeRootPrefix(""),
                        indexedGitlinkPaths: [],
                        candidateSource: source,
                        globalIgnoreDefaultsOverride: ""
                    )
                }
                XCTFail("Expected omitted eager control \(mutation) to fail closed")
            } catch {
                // Any stable-read/currentness failure is the required fail-closed result.
            }
        }
    }

    func testBypassFinalizationFencesLateControlAndTopologyAdditions() async throws {
        for addition in ["control", "topology", "gitlink"] {
            let fixture = try AuthorityEvidenceFixture(makeCommit: true)
            defer { fixture.cleanup() }
            let head = try fixture.runGit(["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let source = MutatingEmptyPrefixCandidateSource {
                if addition == "control" {
                    try "*.swift text\n".write(
                        to: fixture.root.appendingPathComponent(".gitattributes"),
                        atomically: true,
                        encoding: .utf8
                    )
                } else if addition == "topology" {
                    try FileManager.default.createDirectory(
                        at: fixture.root.appendingPathComponent("Late/.git", isDirectory: true),
                        withIntermediateDirectories: true
                    )
                } else {
                    try fixture.runGit([
                        "update-index", "--add", "--cacheinfo", "160000", head, "LateGitlink"
                    ])
                }
            }

            do {
                _ = try await GitWorkspaceStateAuthority().prefixControlEvidence(
                    in: fixture.layout,
                    prefix: GitRepositoryRelativeRootPrefix(""),
                    cacheMode: .bypassReadAndAdmission
                ) {
                    try await GitService.streamedPrefixControlEvidence(
                        layout: fixture.layout,
                        prefix: GitRepositoryRelativeRootPrefix(""),
                        indexedGitlinkPaths: [],
                        candidateSource: source,
                        globalIgnoreDefaultsOverride: ""
                    )
                }
                XCTFail("Expected late \(addition) addition to fail closed")
            } catch {
                // Any final currentness/topology error is the required fail-closed result.
            }
        }
    }

    func testPostArtifactFinalizationFenceRejectsControlMutation() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let control = fixture.root.appendingPathComponent(".gitignore")
        try "Generated/\n".write(to: control, atomically: true, encoding: .utf8)

        do {
            _ = try await GitService.streamedPrefixControlEvidence(
                layout: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix(""),
                indexedGitlinkPaths: [],
                globalIgnoreDefaultsOverride: "",
                postArtifactFinalizationHook: {
                    try "Changed/\n".write(to: control, atomically: true, encoding: .utf8)
                }
            )
            XCTFail("Expected post-finalization currentness failure")
        } catch {
            // The bounded post-artifact fence must reject the mutation.
        }
    }

    func testReachabilityCanonicalizationFailsBeforeNestedGitDirectoryOrGitfileControls() async throws {
        for boundaryKind in ["directory", "gitfile"] {
            let fixture = try AuthorityEvidenceFixture()
            defer { fixture.cleanup() }
            let nested = fixture.root.appendingPathComponent("Nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let boundary = nested.appendingPathComponent(".git")
            if boundaryKind == "directory" {
                try FileManager.default.createDirectory(at: boundary, withIntermediateDirectories: false)
            } else {
                try "gitdir: ../metadata\n".write(to: boundary, atomically: true, encoding: .utf8)
            }
            try "*.swift text\n".write(
                to: nested.appendingPathComponent(".gitattributes"),
                atomically: true,
                encoding: .utf8
            )

            do {
                _ = try await GitService.streamedPrefixControlEvidence(
                    layout: fixture.layout,
                    prefix: GitRepositoryRelativeRootPrefix(""),
                    indexedGitlinkPaths: [],
                    globalIgnoreDefaultsOverride: ""
                )
                XCTFail("Expected nested Git \(boundaryKind) to fail closed")
            } catch let error as GitWorktreeInitializationError {
                XCTAssertEqual(error.reason, .malformedOutput)
            }
        }
    }

    func testReachabilityCanonicalizationFailsBeforeIndexedGitlinkControlsWithoutGitfile() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let head = try fixture.runGit(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.runGit(["update-index", "--add", "--cacheinfo", "160000", head, "Nested"])
        let nested = fixture.root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "*.swift text\n".write(
            to: nested.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await GitService(workspaceStateAuthority: GitWorkspaceStateAuthority())
                .workspaceAuthoritySnapshot(
                    in: fixture.layout,
                    prefix: GitRepositoryRelativeRootPrefix(""),
                    cacheMode: .bypassReadAndAdmission
                )
            XCTFail("Expected indexed gitlink topology to fail closed before controls")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .malformedOutput)
        }
    }

    func testSameLogicalCacheKeyDoesNotReuseFooterAcrossIndexedGitlinkMutation() async throws {
        let fixture = try AuthorityEvidenceFixture(makeCommit: true)
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let prefix = try GitRepositoryRelativeRootPrefix("")
        _ = try await git.workspaceAuthoritySnapshot(in: fixture.layout, prefix: prefix)
        let head = try fixture.runGit(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.runGit(["update-index", "--add", "--cacheinfo", "160000", head, "Nested"])
        let nested = fixture.root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "*.swift text\n".write(
            to: nested.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await git.workspaceAuthoritySnapshot(in: fixture.layout, prefix: prefix)
            XCTFail("Expected indexed gitlink mutation to invalidate prefix-control evidence")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .malformedOutput)
        }
        let counters = await authority.snapshotForTesting()
        XCTAssertEqual(counters.prefixControlCacheHitCount, 0)
        XCTAssertEqual(counters.prefixControlPhysicalScanCount, 2)
    }

    func testReachableControlAddChangeDeleteAndOrderChangeExactDigest() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let rootIgnore = fixture.root.appendingPathComponent(".gitignore")
        try "one\ntwo\n".write(to: rootIgnore, atomically: true, encoding: .utf8)
        let baseline = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )

        try "two\none\n".write(to: rootIgnore, atomically: true, encoding: .utf8)
        let reordered = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertNotEqual(reordered.ignoreControlDigest, baseline.ignoreControlDigest)

        try "one\ntwo\n".write(to: rootIgnore, atomically: true, encoding: .utf8)
        let nestedControl = fixture.root.appendingPathComponent("Sources/.repo_ignore")
        try FileManager.default.createDirectory(
            at: nestedControl.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "*.generated\n".write(to: nestedControl, atomically: true, encoding: .utf8)
        let added = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertNotEqual(added.ignoreControlDigest, baseline.ignoreControlDigest)

        try "*.changed\n".write(to: nestedControl, atomically: true, encoding: .utf8)
        let changed = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertNotEqual(changed.ignoreControlDigest, added.ignoreControlDigest)

        try FileManager.default.removeItem(at: nestedControl)
        let deleted = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertEqual(deleted.ignoreControlDigest, baseline.ignoreControlDigest)

        let attributes = fixture.root.appendingPathComponent("Sources/.gitattributes")
        try "*.swift text\n*.json -text\n".write(to: attributes, atomically: true, encoding: .utf8)
        let attributeAdded = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertNotEqual(attributeAdded.attributeControlDigest, baseline.attributeControlDigest)

        try "*.json -text\n*.swift text\n".write(to: attributes, atomically: true, encoding: .utf8)
        let attributeReordered = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertNotEqual(attributeReordered.attributeControlDigest, attributeAdded.attributeControlDigest)

        try "*.swift binary\n".write(to: attributes, atomically: true, encoding: .utf8)
        let attributeChanged = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertNotEqual(attributeChanged.attributeControlDigest, attributeReordered.attributeControlDigest)

        try FileManager.default.removeItem(at: attributes)
        let attributeDeleted = try await GitService.streamedPrefixControlEvidence(
            layout: fixture.layout,
            prefix: GitRepositoryRelativeRootPrefix(""),
            indexedGitlinkPaths: []
        )
        XCTAssertEqual(attributeDeleted.attributeControlDigest, baseline.attributeControlDigest)
    }

    func testReachabilityCanonicalizationFailsClosedForSymbolicLinkTopology() async throws {
        let fixture = try AuthorityEvidenceFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("ordinary-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("ambiguous-prefix"),
            withDestinationURL: target
        )

        do {
            _ = try await GitService.streamedPrefixControlEvidence(
                layout: fixture.layout,
                prefix: GitRepositoryRelativeRootPrefix("ambiguous-prefix"),
                indexedGitlinkPaths: []
            )
            XCTFail("Expected symbolic-link topology to fail closed")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .malformedOutput)
        }
    }

    private func inventoryHeader() throws -> WorkspaceRootReusableInventoryManifestHeader {
        let oid = try GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "2", count: 40))
        return try WorkspaceRootReusableInventoryManifestHeader(
            compatibilityDomain: WorkspaceRootReusableSnapshot.manifestCompatibilityDomain,
            compatibilityDigest: Data(repeating: 3, count: 32),
            treeOID: oid,
            objectFormat: .sha1,
            repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""),
            commandFormat: GitLoadedRootTreeInventorySpool.commandFormat,
            rawStandardOutputDigest: Data(repeating: 4, count: 32),
            catalogPolicyDigest: Data(repeating: 5, count: 32)
        )
    }

    private func inventoryRecord(path: String) throws -> WorkspaceRootReusableInventoryManifestRecord {
        try WorkspaceRootReusableInventoryManifestRecord(
            rootRelativePath: path,
            mode: "100644",
            kind: .blob,
            objectID: GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "1", count: 40)),
            catalogProjection: .searchableRegularFile
        )
    }
}

private actor PrefixControlCollectorGate {
    private let footer: GitPrefixControlEvidenceManifestFooter
    private var continuation: CheckedContinuation<Void, Never>?
    private var collectionStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var count = 0

    init(footer: GitPrefixControlEvidenceManifestFooter) {
        self.footer = footer
    }

    func collect() async throws -> GitPrefixControlEvidenceManifestFooter {
        count += 1
        let waiters = collectionStartWaiters
        collectionStartWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        try Task.checkCancellation()
        return footer
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func collectionCount() -> Int {
        count
    }

    func waitUntilCollectionStarts() async {
        if count > 0 { return }
        await withCheckedContinuation { collectionStartWaiters.append($0) }
    }
}

private actor PrefixControlCollectorCounter {
    private let footer: GitPrefixControlEvidenceManifestFooter
    private var count = 0

    init(footer: GitPrefixControlEvidenceManifestFooter) {
        self.footer = footer
    }

    func collect() -> GitPrefixControlEvidenceManifestFooter {
        count += 1
        return footer
    }

    func collectionCount() -> Int {
        count
    }
}

private actor PrefixControlCollectedEvidenceCounter {
    private let evidence: GitPrefixControlCollectedEvidence
    private var count = 0

    init(evidence: GitPrefixControlCollectedEvidence) {
        self.evidence = evidence
    }

    func collect() -> GitPrefixControlCollectedEvidence {
        count += 1
        return evidence
    }

    func collectionCount() -> Int {
        count
    }
}

private final class LazyPrefixCandidateSource: GitPrefixControlCandidateSource {
    private let root: URL
    private let logicalNoiseCount: Int
    private let lateControl: URL
    private var index = 0
    private(set) var emittedNoiseCount = 0
    private(set) var currentCandidateKind: GitPrefixControlCandidateKind = .regularFile

    init(root: URL, logicalNoiseCount: Int, lateControl: URL) {
        self.root = root
        self.logicalNoiseCount = logicalNoiseCount
        self.lateControl = lateControl
    }

    func nextCandidate() throws -> URL? {
        if index < logicalNoiseCount {
            defer { index += 1
                emittedNoiseCount += 1
            }
            currentCandidateKind = .regularFile
            return root.appendingPathComponent("logical-noise-\(index)")
        }
        if index == logicalNoiseCount {
            index += 1
            currentCandidateKind = .directory
            return lateControl.deletingLastPathComponent()
        }
        if index == logicalNoiseCount + 1 {
            index += 1
            currentCandidateKind = .regularFile
            return lateControl
        }
        return nil
    }

    func skipDescendants() {}
}

private final class MutatingEmptyPrefixCandidateSource: GitPrefixControlCandidateSource {
    private let mutation: () throws -> Void
    private var mutated = false
    let currentCandidateKind: GitPrefixControlCandidateKind = .regularFile

    init(mutation: @escaping () throws -> Void) {
        self.mutation = mutation
    }

    func nextCandidate() throws -> URL? {
        if !mutated {
            mutated = true
            try mutation()
        }
        return nil
    }

    func skipDescendants() {}
}

private final class AuthorityEvidenceFixture {
    let root: URL
    let layout: GitRepositoryLayout
    private let cleanupRoot: URL

    init(makeCommit: Bool = false, rootAncestorComponents: [String] = []) throws {
        let cleanupRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rpce-loaded-root-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        self.cleanupRoot = cleanupRoot
        root = rootAncestorComponents.reduce(cleanupRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.git(["init", "-q"], at: root)
        try Self.git(["config", "user.email", "tests@example.invalid"], at: root)
        try Self.git(["config", "user.name", "RepoPrompt Tests"], at: root)
        if makeCommit {
            try "let value = 1\n".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            try Self.git(["add", "A.swift"], at: root)
            try Self.git(["commit", "-q", "-m", "fixture"], at: root)
        }
        layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: root))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: cleanupRoot)
    }

    @discardableResult
    func runGit(_ arguments: [String]) throws -> String {
        try Self.git(arguments, at: root)
    }

    func importCommittedControls(count: Int) throws {
        let branch = try runGit(["symbolic-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var stream = Data()
        stream.append(Data("commit \(branch)\n".utf8))
        stream.append(Data("committer RepoPrompt Tests <tests@example.invalid> 0 +0000\n".utf8))
        stream.append(Data("data 7\nfixture\n".utf8))
        for index in 0 ..< count {
            stream.append(Data(String(format: "M 100644 inline control-%06d/.gitignore\n", index).utf8))
            stream.append(Data("data 0\n\n".utf8))
        }
        stream.append(Data("done\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["fast-import", "--quiet"]
        process.currentDirectoryURL = root
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(stream)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitLoadedRootAuthorityEvidenceTests", code: Int(process.terminationStatus))
        }
    }

    @discardableResult
    private static func git(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitLoadedRootAuthorityEvidenceTests", code: Int(process.terminationStatus))
        }
        return String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}
