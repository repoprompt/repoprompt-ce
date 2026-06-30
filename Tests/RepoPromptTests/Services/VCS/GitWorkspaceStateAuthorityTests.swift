@testable import RepoPrompt
import XCTest

final class GitWorkspaceStateAuthorityTests: XCTestCase {
    func testMutationSuccessFailureAndCancellationInvalidateEachGenerationExactlyOnce() async throws {
        let fixture = try GitAuthorityFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        var lease = try await authority.install(fixture.snapshot())
        let initiallyCurrent = await authority.isCurrent(lease)
        XCTAssertTrue(initiallyCurrent)

        for (kind, outcome) in [
            (GitWorkspaceMutationKind.branchSwitch, GitWorkspaceMutationOutcome.succeeded),
            (.fetch, .failed),
            (.mergeApply, .cancelled)
        ] {
            let before = await authority.snapshotForTesting()
            let token = await authority.beginMutation(repositoryKey: fixture.key, kind: kind)
            let currentDuringMutation = await authority.isCurrent(lease)
            XCTAssertFalse(currentDuringMutation)
            await authority.finishMutation(token, outcome: outcome)
            await authority.finishMutation(token, outcome: outcome)
            let after = await authority.snapshotForTesting()
            XCTAssertEqual(
                after.authorityGenerations[fixture.key],
                (before.authorityGenerations[fixture.key] ?? 0) + 1
            )
            lease = try await authority.install(fixture.snapshot(metadataGeneration: UUID().uuidString))
            let recapturedCurrent = await authority.isCurrent(lease)
            XCTAssertTrue(recapturedCurrent)
        }
    }

    func testRealMetadataMutationsInvalidateNestedRefsReplacementCreationAndDeletionWithoutPolling() async throws {
        let fixture = try GitAuthorityFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let token = try await authority.retainMetadataObservation(for: fixture.layout)
        var lease = try await authority.install(fixture.snapshot())
        let before = await monitor.snapshotForTesting()
        XCTAssertEqual(before.pollingCommandCount, 0)
        var metadataEventCount = await authority.snapshotForTesting().metadataEventCount

        let nestedReference = fixture.layout.commonDir.appendingPathComponent("refs/heads/team/topic")
        var watermark = monitor.acceptedWatermark(for: fixture.key)
        try FileManager.default.createDirectory(
            at: nestedReference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "1111111111111111111111111111111111111111\n".write(
            to: nestedReference,
            atomically: true,
            encoding: .utf8
        )
        await monitor.flushForTesting(repositoryKey: fixture.key)
        try await waitUntil { monitor.acceptedWatermark(for: fixture.key) > watermark }
        try await waitUntil { await !(authority.isCurrent(lease)) }
        try await waitUntil { await authority.snapshotForTesting().metadataEventCount > metadataEventCount }
        metadataEventCount = await authority.snapshotForTesting().metadataEventCount

        lease = try await authority.install(fixture.snapshot(metadataGeneration: "replacement"))
        watermark = monitor.acceptedWatermark(for: fixture.key)
        try "ref: refs/heads/replaced\n".write(
            to: fixture.layout.gitDir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        await monitor.flushForTesting(repositoryKey: fixture.key)
        try await waitUntil { monitor.acceptedWatermark(for: fixture.key) > watermark }
        try await waitUntil { await !(authority.isCurrent(lease)) }
        try await waitUntil { await authority.snapshotForTesting().metadataEventCount > metadataEventCount }
        metadataEventCount = await authority.snapshotForTesting().metadataEventCount

        lease = try await authority.install(fixture.snapshot(metadataGeneration: "deletion"))
        watermark = monitor.acceptedWatermark(for: fixture.key)
        try FileManager.default.removeItem(at: nestedReference)
        await monitor.flushForTesting(repositoryKey: fixture.key)
        try await waitUntil { monitor.acceptedWatermark(for: fixture.key) > watermark }
        try await waitUntil { await !(authority.isCurrent(lease)) }
        try await waitUntil { await authority.snapshotForTesting().metadataEventCount > metadataEventCount }

        await authority.releaseMetadataObservation(token)
        let after = await monitor.snapshotForTesting()
        XCTAssertEqual(after.retainedRepositoryCount, 0)
        XCTAssertEqual(after.retainTokenCount, 0)
        XCTAssertEqual(after.pollingCommandCount, 0)
        XCTAssertGreaterThanOrEqual(after.acceptedEventCount, 3)
    }

    func testConditionalInstallRejectsMutationAndMetadataInvalidationDuringCollection() async throws {
        let fixture = try GitAuthorityFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let observation = try await authority.retainMetadataObservation(for: fixture.layout)
        let scope = try fixture.scope()

        let mutationCapture = try await authority.beginCollection(scopeKey: scope).get()
        let mutation = await authority.beginMutation(repositoryKey: fixture.key, kind: .branchSwitch)
        await authority.finishMutation(mutation, outcome: .succeeded)
        let mutationInstall = try await authority.install(fixture.snapshot(), capturedUsing: mutationCapture)
        XCTAssertEqual(mutationInstall.failure, .invalidatedDuringCollection)

        let metadataCapture = try await authority.beginCollection(scopeKey: scope).get()
        let watermark = monitor.acceptedWatermark(for: fixture.key)
        try "ref: refs/heads/changed-during-collection\n".write(
            to: fixture.layout.gitDir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        await monitor.flushForTesting(repositoryKey: fixture.key)
        try await waitUntil { monitor.acceptedWatermark(for: fixture.key) > watermark }
        let metadataInstall = try await authority.install(
            fixture.snapshot(metadataGeneration: "stale"),
            capturedUsing: metadataCapture
        )
        XCTAssertEqual(metadataInstall.failure, .invalidatedDuringCollection)
        try await waitUntil { await authority.snapshotForTesting().publishedScopeCount == 0 }

        await authority.releaseMetadataObservation(observation)
    }

    func testPendingFenceUsesAcceptedWatermarkAndAllowsOnlyOneCoalescedRevalidation() async throws {
        let fixture = try GitAuthorityFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let observation = try await authority.retainMetadataObservation(for: fixture.layout)
        var snapshot = try fixture.snapshot()
        var lease = try await authority.install(snapshot)
        var fence = Self.pendingInitializationFence(
            snapshot: snapshot,
            lease: lease,
            metadataObservationToken: observation,
            targetLayout: fixture.layout
        )

        var initialDecision = await authority.pendingInitializationFenceDecision(fence)
        for recaptureIndex in 0 ..< 3 where initialDecision != .current {
            snapshot = try fixture.snapshot(
                metadataGeneration: "metadata-recaptured-\(recaptureIndex)-\(monitor.acceptedWatermark(for: fixture.key))"
            )
            lease = try await authority.install(snapshot)
            fence = Self.pendingInitializationFence(
                snapshot: snapshot,
                lease: lease,
                metadataObservationToken: observation,
                targetLayout: fixture.layout
            )
            initialDecision = await authority.pendingInitializationFenceDecision(fence)
        }
        XCTAssertEqual(initialDecision, .current)

        await monitor.injectAcceptedEventForTesting(repositoryKey: fixture.key, kinds: [.head])
        await monitor.injectAcceptedEventForTesting(repositoryKey: fixture.key, kinds: [.index])
        let latestAcceptedWatermark = monitor.acceptedWatermark(for: fixture.key)
        XCTAssertGreaterThanOrEqual(latestAcceptedWatermark, lease.acceptedMetadataWatermark + 2)
        let currentAfterAcceptedEvents = await authority.pendingInitializationAuthorityFenceIsCurrent(fence)
        XCTAssertFalse(currentAfterAcceptedEvents)
        XCTAssertFalse(authority.pendingInitializationAuthorityFenceIsSynchronouslyCurrent(fence))
        XCTAssertNil(authority.withPendingInitializationAuthorityPublicationPermit([fence]) { true })

        let decision = await authority.pendingInitializationFenceDecision(fence)
        XCTAssertEqual(
            decision,
            .revalidationRequired(latestAcceptedMetadataWatermark: latestAcceptedWatermark)
        )

        let alreadyRevalidated = GitWorkspacePendingInitializationAuthorityFence(
            snapshot: fence.snapshot,
            lease: fence.lease,
            metadataObservationToken: fence.metadataObservationToken,
            acceptedMetadataWatermark: fence.acceptedMetadataWatermark,
            targetLayout: fence.targetLayout,
            repositoryRelativeRootPrefix: fence.repositoryRelativeRootPrefix,
            additionalAuthorityPaths: fence.additionalAuthorityPaths,
            revalidationUsed: true
        )
        let repeatedDecision = await authority.pendingInitializationFenceDecision(alreadyRevalidated)
        XCTAssertEqual(repeatedDecision, .fallback)
        let monitorSnapshot = await monitor.snapshotForTesting()
        XCTAssertEqual(monitorSnapshot.pollingCommandCount, 0)
        await authority.releasePendingInitializationAuthorityFence(fence)
    }

    func testSynchronousPublicationPermitRejectsMutationBeginWithoutWaitingForEventDelivery() async throws {
        let fixture = try GitAuthorityFixture()
        defer { fixture.cleanup() }
        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let observation = try await authority.retainMetadataObservation(for: fixture.layout)
        let snapshot = try fixture.snapshot()
        let lease = try await authority.install(snapshot)
        let fence = GitWorkspacePendingInitializationAuthorityFence(
            snapshot: snapshot,
            lease: lease,
            metadataObservationToken: observation,
            acceptedMetadataWatermark: lease.acceptedMetadataWatermark,
            targetLayout: fixture.layout,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix,
            additionalAuthorityPaths: [],
            revalidationUsed: false
        )

        XCTAssertTrue(authority.pendingInitializationAuthorityFenceIsSynchronouslyCurrent(fence))
        XCTAssertEqual(
            authority.withPendingInitializationAuthorityPublicationPermit([fence]) { true },
            true
        )
        let mutation = await authority.beginMutation(repositoryKey: fixture.key, kind: .branchSwitch)
        XCTAssertFalse(authority.pendingInitializationAuthorityFenceIsSynchronouslyCurrent(fence))
        XCTAssertNil(authority.withPendingInitializationAuthorityPublicationPermit([fence]) { true })
        await authority.finishMutation(mutation, outcome: .succeeded)
        await authority.releasePendingInitializationAuthorityFence(fence)
    }

    func testInvalidationStreamEmitsPathFreeMutationAndMetadataWakeups() async throws {
        let fixture = try GitAuthorityFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let events = await authority.invalidationEvents()
        var iterator = events.makeAsyncIterator()

        let mutation = await authority.beginMutation(
            repositoryKey: fixture.key,
            kind: .branchSwitch
        )
        await authority.finishMutation(mutation, outcome: .succeeded)
        await authority.metadataDidChange(repositoryKey: fixture.key, kinds: [.monitorGap])

        let began = await iterator.next()
        let completed = await iterator.next()
        let metadata = await iterator.next()
        XCTAssertEqual(began?.repositoryKey, fixture.key)
        XCTAssertEqual(began?.kind, .mutationBegan(.branchSwitch))
        XCTAssertEqual(completed?.kind, .mutationCompleted(.branchSwitch, .succeeded))
        XCTAssertEqual(metadata?.kind, .metadata([.monitorGap]))
        XCTAssertEqual(metadata?.acceptedMetadataWatermark, 0)
    }

    func testMonitorRetainsAreAdditiveTransactionalAndExternalAuthorityUsesRealEvents() async throws {
        let fixture = try GitAuthorityFixture()
        defer { fixture.cleanup() }
        let boundedMonitor = GitWorkspaceMetadataMonitor(maximumPathsPerRepository: 2)
        let head = fixture.layout.gitDir.appendingPathComponent("HEAD")
        let refs = fixture.layout.commonDir.appendingPathComponent("refs", isDirectory: true)
        let index = fixture.layout.gitDir.appendingPathComponent("index")

        let first = try await boundedMonitor.retain(repositoryKey: fixture.key, paths: [head]) { _ in }
        let initial = await boundedMonitor.snapshotForTesting()
        let second = try await boundedMonitor.retain(repositoryKey: fixture.key, paths: [refs]) { _ in }
        let additive = await boundedMonitor.snapshotForTesting()
        XCTAssertEqual(additive.sourceCount, initial.sourceCount + 1)
        XCTAssertEqual(additive.coveredPathCount, 2)

        do {
            _ = try await boundedMonitor.retain(repositoryKey: fixture.key, paths: [index]) { _ in }
            XCTFail("Expected an all-or-nothing path cap failure")
        } catch let error as GitWorkspaceMetadataMonitorError {
            XCTAssertEqual(error, .pathLimitExceeded(requested: 3, limit: 2))
        }
        let afterFailure = await boundedMonitor.snapshotForTesting()
        XCTAssertEqual(afterFailure.sourceCount, additive.sourceCount)
        XCTAssertEqual(afterFailure.coveredPathCount, additive.coveredPathCount)
        XCTAssertEqual(afterFailure.retainTokenCount, additive.retainTokenCount)
        await boundedMonitor.release(second)
        await boundedMonitor.release(first)

        let monitor = GitWorkspaceMetadataMonitor()
        let authority = GitWorkspaceStateAuthority(metadataMonitor: monitor)
        let baseObservation = try await authority.retainMetadataObservation(for: fixture.layout)
        let beforeExternal = await monitor.snapshotForTesting()
        let external = fixture.sandbox.appendingPathComponent("global excludes")
        let externalObservation = try await authority.retainMetadataObservation(
            for: fixture.layout,
            additionalAuthorityPaths: [external]
        )
        let afterExternal = await monitor.snapshotForTesting()
        XCTAssertEqual(afterExternal.sourceCount, beforeExternal.sourceCount + 1)
        var metadataEventCount = await authority.snapshotForTesting().metadataEventCount

        var lease = try await authority.install(fixture.snapshot())
        var watermark = monitor.acceptedWatermark(for: fixture.key)
        try "*.generated\n".write(to: external, atomically: true, encoding: .utf8)
        await monitor.flushForTesting(repositoryKey: fixture.key)
        try await waitUntil { monitor.acceptedWatermark(for: fixture.key) > watermark }
        try await waitUntil { await !(authority.isCurrent(lease)) }
        try await waitUntil { await authority.snapshotForTesting().metadataEventCount > metadataEventCount }
        metadataEventCount = await authority.snapshotForTesting().metadataEventCount

        lease = try await authority.install(fixture.snapshot(metadataGeneration: "external-replacement"))
        watermark = monitor.acceptedWatermark(for: fixture.key)
        try "*.cache\n".write(to: external, atomically: true, encoding: .utf8)
        await monitor.flushForTesting(repositoryKey: fixture.key)
        try await waitUntil { monitor.acceptedWatermark(for: fixture.key) > watermark }
        try await waitUntil { await !(authority.isCurrent(lease)) }
        try await waitUntil { await authority.snapshotForTesting().metadataEventCount > metadataEventCount }
        metadataEventCount = await authority.snapshotForTesting().metadataEventCount

        let externalDeletion = fixture.sandbox.appendingPathComponent("global attributes deletion")
        try "*.binary binary\n".write(to: externalDeletion, atomically: true, encoding: .utf8)
        let deletionObservation = try await authority.retainMetadataObservation(
            for: fixture.layout,
            additionalAuthorityPaths: [externalDeletion]
        )
        lease = try await authority.install(fixture.snapshot(metadataGeneration: "external-deletion"))
        watermark = monitor.acceptedWatermark(for: fixture.key)
        try FileManager.default.removeItem(at: externalDeletion)
        await monitor.flushForTesting(repositoryKey: fixture.key)
        try await waitUntil { monitor.acceptedWatermark(for: fixture.key) > watermark }
        try await waitUntil { await !(authority.isCurrent(lease)) }
        try await waitUntil { await authority.snapshotForTesting().metadataEventCount > metadataEventCount }

        await authority.releaseMetadataObservation(deletionObservation)
        await authority.releaseMetadataObservation(externalObservation)
        await authority.releaseMetadataObservation(baseObservation)
    }

    func testAuthorityCompatibilityIdentityIncludesTreePrefixPoliciesAndSearchABI() throws {
        let fixture = try GitAuthorityFixture()
        defer { fixture.cleanup() }
        let baseline = try fixture.snapshot()
        let otherTree = try fixture.snapshot(treeDigit: "2")
        let otherPrefix = try fixture.snapshot(rootPrefix: "Nested")
        let otherPolicy = try fixture.snapshot(ignoreDigest: "ignore-v2")
        let otherSearchABI = try fixture.snapshot(searchABI: GitWorkspaceSearchABIIdentity(
            matcherSchemaVersion: 2,
            projectedKeySchemaVersion: 1,
            comparatorSchemaVersion: 1,
            pathNormalizationSchemaVersion: 1
        ))

        XCTAssertNotEqual(baseline, otherTree)
        XCTAssertNotEqual(baseline, otherPrefix)
        XCTAssertNotEqual(baseline, otherPolicy)
        XCTAssertNotEqual(baseline, otherSearchABI)
        XCTAssertEqual(baseline.repositoryNamespace, otherTree.repositoryNamespace)
        XCTAssertEqual(baseline.objectFormat, .sha1)
    }

    private static func pendingInitializationFence(
        snapshot: GitWorkspaceAuthoritySnapshot,
        lease: GitWorkspaceAuthorityLease,
        metadataObservationToken: GitWorkspaceMetadataMonitor.RetainToken,
        targetLayout: GitRepositoryLayout,
        revalidationUsed: Bool = false
    ) -> GitWorkspacePendingInitializationAuthorityFence {
        GitWorkspacePendingInitializationAuthorityFence(
            snapshot: snapshot,
            lease: lease,
            metadataObservationToken: metadataObservationToken,
            acceptedMetadataWatermark: lease.acceptedMetadataWatermark,
            targetLayout: targetLayout,
            repositoryRelativeRootPrefix: snapshot.repositoryRelativeRootPrefix,
            additionalAuthorityPaths: [],
            revalidationUsed: revalidationUsed
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () async -> Bool
    ) async throws {
        for _ in 0 ..< 1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for authority invalidation", file: file, line: line)
    }
}

private struct GitAuthorityFixture {
    let sandbox: URL
    let layout: GitRepositoryLayout
    let namespace: GitBlobRepositoryNamespace

    var key: GitWorkspaceAuthorityRepositoryKey {
        GitWorkspaceAuthorityRepositoryKey(layout: layout)
    }

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorkspaceStateAuthorityTests-\(UUID().uuidString)", isDirectory: true)
        let gitDirectory = sandbox.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("refs/heads", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("info", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/main\n".write(
            to: gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: gitDirectory.appendingPathComponent("index"))
        try "[core]\n\tbare = false\n".write(
            to: gitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: gitDirectory.appendingPathComponent("info/exclude"))
        try Data().write(to: gitDirectory.appendingPathComponent("info/attributes"))
        layout = GitRepositoryLayout(
            workTreeRoot: sandbox,
            dotGitPath: gitDirectory,
            gitDir: gitDirectory,
            commonDir: gitDirectory,
            isWorktree: false
        )
        namespace = try GitBlobRepositoryNamespace(
            commonDirectory: gitDirectory,
            salt: Data(repeating: 7, count: GitBlobRepositoryNamespace.saltByteCount)
        )
    }

    func snapshot(
        treeDigit: Character = "1",
        rootPrefix: String = "",
        ignoreDigest: String = "ignore-v1",
        searchABI: GitWorkspaceSearchABIIdentity = .current,
        metadataGeneration: String = "metadata-v1"
    ) throws -> GitWorkspaceAuthoritySnapshot {
        let head = try GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "a", count: 40))
        let tree = try GitObjectID(
            objectFormat: .sha1,
            lowercaseHex: String(repeating: treeDigit, count: 40)
        )
        return try GitWorkspaceAuthoritySnapshot(
            repositoryKey: key,
            repositoryNamespace: namespace,
            objectFormat: .sha1,
            headCommitOID: head,
            treeOID: tree,
            repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(rootPrefix),
            repositoryBindingEpoch: "repository",
            worktreeBindingEpoch: "worktree",
            layoutGeneration: "layout",
            indexGeneration: "index",
            checkoutConfigurationGeneration: "checkout",
            metadataGeneration: metadataGeneration,
            policyIdentity: GitWorkspacePolicyIdentity(
                mandatoryIgnorePolicyIdentity: "mandatory-ignore",
                committedIgnoreControlDigest: ignoreDigest,
                configuredIgnoreAuthorityDigest: "configured-ignore",
                attributePolicyDigest: "attributes",
                sparsePolicyDigest: "sparse-disabled",
                searchABI: searchABI,
                resolvedExcludesFileIdentity: nil,
                resolvedAttributesFileIdentity: nil
            )
        )
    }

    func scope(rootPrefix: String = "") throws -> GitWorkspaceAuthorityScopeKey {
        try GitWorkspaceAuthorityScopeKey(
            repositoryKey: key,
            repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(rootPrefix)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
