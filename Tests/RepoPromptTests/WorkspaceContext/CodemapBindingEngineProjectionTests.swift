import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodemapBindingEngineProjectionTests: CodemapBindingEngineTestCase {
    func testNonGitRootBecomesUnavailableWithoutArtifactManifestOrBuildWork() async throws {
        let sandbox = try makeRepositoryFixture(name: #function)
        let root = sandbox.sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let artifactRoot = try makeSecureDirectory(in: sandbox.sandbox, named: "artifacts")
        let buildCounter = EngineAsyncCounter()
        let manifestReads = EngineLockedCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: artifactRoot,
            manifestStoreHooks: CodeMapRootManifestStoreHooks(
                afterReadAdmission: { manifestReads.increment() }
            ),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                return .readyNoSymbols
            })
        )
        let service = capabilityService()
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: service,
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                throw FileSystemError.failedToReadFile
            }
        )
        addTeardownBlock { await engine.shutdown() }
        let result = await engine.registerRoot(WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        ))
        guard case let .unavailable(state) = result,
              case .terminalUnavailable(.nonGit) = state
        else { return XCTFail("Expected terminal non-Git capability.") }
        let buildCount = await buildCounter.value
        XCTAssertEqual(buildCount, 0)
        XCTAssertEqual(manifestReads.value, 0)
        let coordinator = await runtime.coordinator.accounting()
        XCTAssertEqual(coordinator.counters.requests, 0)
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.unavailableRootCount, 1)
    }

    func testProjectionPreloadSchedulingIsExplicitIdempotentAndSealsEmptyCatalog() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["README.md": "# Empty projection catalog\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            projectionCatalogFactory: { rootEpoch, _ in
                EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [],
                    recorder: recorder
                ).client
            }
        )
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected eligible registration.")
        }
        let preScheduleAccounting = await fixture.engine.accounting()
        XCTAssertEqual(preScheduleAccounting.counters.projectionPreloadsScheduled, 0)

        let firstSchedule = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let duplicateSchedule = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(firstSchedule, .handedOff)
        XCTAssertEqual(duplicateSchedule, .handedOff)
        let completed = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.projectionJobCount, 1)
        XCTAssertEqual(accounting.activeProjectionBatchCount, 0)
        XCTAssertEqual(accounting.queuedProjectionBatchCount, 0)
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 1)
        XCTAssertEqual(accounting.counters.projectionCoveragesCompleted, 1)
        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots.count, 1)
        guard case .seal = snapshots.first else {
            return XCTFail("Expected an empty-catalog coverage seal without a segment.")
        }
    }

    func testProjectionDemandJoinsActiveBatchWithoutPreemptionAndBecomesExactReady() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Requested.swift": "struct Requested {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let pageGate = EngineAsyncGate()
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            projectionCatalogFactory: { rootEpoch, _ in
                EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [],
                    recorder: recorder,
                    pageGate: pageGate
                ).client
            }
        )
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected eligible registration.")
        }
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(pageGate.waitUntilEntered())

        let acquisition = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fixture.fileIDs.id(for: "Sources/Requested.swift")],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: .max,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(ticket, initialStatus) = acquisition else {
            return XCTFail("Expected projection demand acquisition.")
        }
        guard case .activeBatch = initialStatus else {
            return XCTFail("Expected the retainer to join the admitted non-preemptive batch.")
        }
        let whileBlocked = await fixture.engine.accounting()
        XCTAssertEqual(whileBlocked.activeProjectionBatchCount, 1)
        XCTAssertEqual(whileBlocked.retainedProjectionDemandCount, 1)
        XCTAssertEqual(whileBlocked.counters.projectionCancelledBatches, 0)

        pageGate.release()
        let completed = await waitForEngineCondition {
            guard case .ready = await fixture.engine.projectionDemandStatus(ticket) else { return false }
            return true
        }
        XCTAssertTrue(completed)
        let readyAccounting = await fixture.engine.accounting()
        XCTAssertEqual(readyAccounting.counters.projectionDemandsJoined, 1)
        XCTAssertEqual(readyAccounting.counters.projectionCancelledBatches, 0)
        await fixture.engine.releaseProjectionDemand(ticket)
        let releasedAccounting = await fixture.engine.accounting()
        XCTAssertEqual(releasedAccounting.retainedProjectionDemandCount, 0)
    }

    func testProjectionDemandClockExpiryBoundsRetryClampAndRevocationAreDeterministic() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Requested.swift": "struct Requested {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let clock = EngineUptimeClock(100)
        let pageGate = EngineAsyncGate()
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumProjectionDemandCountPerRoot: 1,
                maximumProjectionDemandCount: 1,
                maximumProjectionDemandFileIDCount: 2,
                maximumProjectionDemandMetadataByteCountPerRoot: 220,
                maximumProjectionDemandMetadataByteCount: 220,
                projectionDemandRetryMilliseconds: 1
            ),
            uptimeNanoseconds: { clock.now },
            projectionCatalogFactory: { rootEpoch, _ in
                EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [],
                    recorder: recorder,
                    pageGate: pageGate
                ).client
            }
        )
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected eligible registration.")
        }
        let fileID = fixture.fileIDs.id(for: "Sources/Requested.swift")
        let first = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fileID],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 200,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(firstTicket, _) = first else {
            return XCTFail("Expected first retained demand.")
        }
        let countRejected = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [UUID()],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 300,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .busy(.requestLimit, retryAfterMilliseconds) = countRejected else {
            return XCTFail("Expected bounded request-count rejection.")
        }
        XCTAssertEqual(retryAfterMilliseconds, 25)

        clock.set(200)
        let expiredStatus = await fixture.engine.projectionDemandStatus(firstTicket)
        XCTAssertEqual(expiredStatus, .expired)
        var accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.retainedProjectionDemandCount, 0)
        XCTAssertEqual(accounting.terminalProjectionDemandStatusCount, 1)
        XCTAssertEqual(accounting.counters.projectionDemandsExpired, 1)

        let fileIDRejected = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [UUID(), UUID(), UUID()],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 400,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .busy(.fileIDLimit(attempted, limit), retryAfterMilliseconds) = fileIDRejected else {
            return XCTFail("Expected bounded file-ID rejection.")
        }
        XCTAssertEqual(attempted, 3)
        XCTAssertEqual(limit, 2)
        XCTAssertEqual(retryAfterMilliseconds, 25)

        let metadataRejected = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [UUID(), UUID()],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 400,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .busy(.metadataByteLimit(attempted, limit), _) = metadataRejected else {
            return XCTFail("Expected bounded metadata-byte rejection.")
        }
        XCTAssertEqual(attempted, 224)
        XCTAssertEqual(limit, 220)

        let replacement = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fileID],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 400,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(replacementTicket, _) = replacement else {
            return XCTFail("Expected capacity to be reusable after expiry.")
        }
        XCTAssertTrue(pageGate.waitUntilEntered())
        clock.set(401)
        pageGate.release()
        let completedAfterDeadline = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completedAfterDeadline)
        let lateStatus = await fixture.engine.projectionDemandStatus(replacementTicket)
        XCTAssertEqual(lateStatus, .expired)

        let current = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fileID],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 500,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(currentTicket, .ready) = current else {
            return XCTFail("Expected current complete coverage before revocation.")
        }
        _ = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Requested.swift"]
        )
        let staleStatus = await fixture.engine.projectionDemandStatus(currentTicket)
        XCTAssertEqual(staleStatus, .stale)
        accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.retainedProjectionDemandCount, 0)
        XCTAssertLessThanOrEqual(accounting.terminalProjectionDemandStatusCount, 1)
        XCTAssertEqual(accounting.counters.projectionDemandsRevoked, 1)
    }

    func testProjectionDemandEarliestDeadlineOvertakesPreloadAndSharesBackgroundFairnessQuantum() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let roots = try (0 ..< 4).map { index in
            try repository.makeRepository(
                named: "repository-\(index)",
                files: ["README.md": "# Root \(index)\n"]
            )
        }
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let rootEpochs = roots.map { _ in
            WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        }
        let blocker = EngineAsyncGate()
        let hookEvents = EngineHookEvents()
        let catalog = WorkspaceCodemapBindingCatalogClient { _, _ in nil } readProjectionCatalogPage: {
            request in
            if request.rootEpoch == rootEpochs[0] {
                await blocker.enterAndWait()
            }
            let token = WorkspaceCodemapProjectionCatalogToken(
                rootEpoch: request.rootEpoch,
                topologyGeneration: 1,
                appliedIndexGeneration: 1,
                catalogGeneration: 1,
                ingressGeneration: 1,
                projectionInvalidationGeneration: 1
            )
            switch WorkspaceCodemapProjectionCatalogPage.validated(
                request: request,
                token: token,
                entries: [],
                nextCursor: nil,
                isEnd: true,
                supportedCandidateCountThroughPage: 0
            ) {
            case let .success(page): return .page(page)
            case .failure: return .unavailable(.catalogUnavailable)
            }
        } revalidateProjectionCatalogToken: { epoch, token in
            epoch == token.rootEpoch ? .current : .stale
        } publishProjection: { snapshot in
            switch snapshot {
            case let .segment(segment):
                .accepted(segment.progress)
            case let .seal(proof):
                switch WorkspaceCodemapProjectionProgress.notStarted.advancing(
                    to: .complete,
                    by: .zero,
                    catalogCompletion: proof.catalogCompletion
                ) {
                case let .success(progress): .accepted(progress)
                case .failure: .superseded
                }
            }
        }
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: capabilityService(),
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                throw FileSystemError.failedToReadFile
            },
            catalogClient: catalog,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumConsecutiveDemandAdmissions: 1,
                maximumActiveProjectionBatchCountPerRoot: 1,
                maximumActiveProjectionBatchCount: 1
            ),
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            initialAdmissionOrdinal: .max,
            uptimeNanoseconds: { 100 },
            accessEpochSeconds: { 42 }
        )
        addTeardownBlock { await engine.shutdown() }
        let registrations = zip(rootEpochs, roots).map { rootEpoch, root in
            WorkspaceCodemapBindingRootRegistration(
                rootID: rootEpoch.rootID,
                rootLifetimeID: rootEpoch.rootLifetimeID,
                loadedRootURL: root,
                catalogGeneration: 1,
                ingressGeneration: 1
            )
        }
        for registration in registrations {
            guard case .registered = await engine.registerRoot(registration) else {
                return XCTFail("Expected every Git root to register.")
            }
        }

        _ = await engine.scheduleProjectionPreload(rootEpoch: rootEpochs[0])
        XCTAssertTrue(blocker.waitUntilEntered())
        let later = await engine.acquireProjectionDemand(
            rootEpoch: rootEpochs[1],
            fileIDs: [UUID()],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 1000,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        let earlier = await engine.acquireProjectionDemand(
            rootEpoch: rootEpochs[2],
            fileIDs: [UUID()],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 500,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(laterTicket, _) = later,
              case let .acquired(earlierTicket, _) = earlier
        else { return XCTFail("Expected both root retainers to be admitted.") }
        _ = await engine.scheduleProjectionPreload(rootEpoch: rootEpochs[3])
        let allQueued = await waitForEngineCondition {
            await engine.accounting().queuedProjectionBatchCount == 3
        }
        XCTAssertTrue(allQueued)
        blocker.release()
        let completed = await waitForEngineCondition {
            let accounting = await engine.accounting()
            return accounting.projectionRoots.count == 4 &&
                accounting.projectionRoots.allSatisfy { $0.phase == .complete }
        }
        XCTAssertTrue(completed)
        let admissionOrder = hookEvents.values(kind: .projectionBatchStarted).compactMap(\.rootEpoch)
        XCTAssertEqual(Array(admissionOrder.prefix(4)), [
            rootEpochs[0],
            rootEpochs[2],
            rootEpochs[3],
            rootEpochs[1]
        ])
        await engine.releaseProjectionDemand(laterTicket)
        await engine.releaseProjectionDemand(earlierTicket)
    }

    func testRetainedProjectionDemandUsesSpareCapacityBeforeForegroundQuantumIsExhausted() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "README.md": "# Foreground fairness\n",
                "Sources/Foreground.swift": "struct Foreground {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let foregroundGate = EngineAsyncGate()
        let recorder = EngineProjectionRecorder()
        let hookEvents = EngineHookEvents()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumConsecutiveDemandAdmissions: 2,
                maximumActiveProjectionBatchCountPerRoot: 1,
                maximumActiveProjectionBatchCount: 1
            ),
            hooks: WorkspaceCodemapBindingEngineHooks { hookEvents.record($0) },
            uptimeNanoseconds: { 100 },
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await foregroundGate.enterAndWait()
                try Task.checkCancellation()
                throw FileSystemError.failedToReadFile
            },
            projectionCatalogFactory: { rootEpoch, _ in
                EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [],
                    recorder: recorder
                ).client
            }
        )
        guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected eligible registration.")
        }
        try repository.write(
            "struct Foreground { let changed = true }\n",
            to: "Sources/Foreground.swift",
            at: root
        )

        let foreground = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Foreground.swift"))
        }
        XCTAssertTrue(foregroundGate.waitUntilEntered())
        defer {
            foreground.cancel()
            foregroundGate.release()
        }

        let acquisition = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fixture.fileIDs.id(for: "Sources/Requested.swift")],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: 1000,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(ticket, _) = acquisition else {
            return XCTFail("Expected retained projection demand acquisition.")
        }
        let completedWhileForegroundBlocked = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completedWhileForegroundBlocked)
        XCTAssertEqual(
            hookEvents.values(kind: .projectionBatchStarted).compactMap(\.rootEpoch),
            [fixture.rootEpoch]
        )

        await fixture.engine.releaseProjectionDemand(ticket)
        foregroundGate.release()
        _ = await foreground.value
    }

    func testProjectionPreloadUsesCurrentV2EnvelopeAndFinalSegmentCarriesSealCompletion() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Warm.swift": "struct Warm {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected a v2 manifest seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let sourceReads = EngineAsyncCounter()
        let recorder = EngineProjectionRecorder()
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await sourceReads.increment()
                throw FileSystemError.failedToReadFile
            },
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Warm.swift"
                let candidate = WorkspaceCodemapProjectionCatalogCandidate(
                    identity: WorkspaceCodemapArtifactBindingIdentity(
                        rootID: rootEpoch.rootID,
                        rootLifetimeID: rootEpoch.rootLifetimeID,
                        fileID: fileIDs.id(for: path),
                        standardizedRootPath: root.path,
                        standardizedRelativePath: path,
                        standardizedFullPath: root.appendingPathComponent(path).path
                    )!,
                    language: .swift,
                    requestGeneration: 1,
                    pathGeneration: 1
                )
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [candidate],
                    recorder: recorder
                ).client
            }
        )
        _ = await warm.engine.registerRoot(warm.registration)
        let schedule = await warm.engine.scheduleProjectionPreload(rootEpoch: warm.rootEpoch)
        XCTAssertEqual(schedule, .handedOff)
        let completed = await waitForEngineCondition {
            await warm.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)
        let accounting = await warm.engine.accounting()
        XCTAssertEqual(accounting.counters.projectionEnvelopeHits, 1)
        XCTAssertEqual(accounting.counters.classifications, 0)
        XCTAssertEqual(accounting.counters.projectionBuildsStarted, 0)
        XCTAssertEqual(accounting.counters.materializations, 0)
        XCTAssertEqual(accounting.counters.validatedWorktreeReads, 0)
        let sourceReadCount = await sourceReads.value
        let overlaySnapshot = await warm.engine.snapshot(rootEpoch: warm.rootEpoch)
        let projectionSnapshots = await recorder.snapshots
        XCTAssertEqual(sourceReadCount, 0)
        XCTAssertEqual(overlaySnapshot?.entries.count, 0)
        XCTAssertEqual(projectionSnapshots.count, 2)
        guard case let .segment(segment) = projectionSnapshots[0],
              case let .seal(proof) = projectionSnapshots[1]
        else { return XCTFail("Expected one non-empty segment followed by its seal.") }
        XCTAssertEqual(segment.progress.catalogCompletion, proof.catalogCompletion)
        XCTAssertEqual(segment.progress.counts, proof.counts)
    }

    /// Extraction note: this preserves the missing-envelope preload coverage from the former
    /// monolithic WorkspaceCodemapBindingEngineTests suite. The explicit ready-demand path is
    /// represented by this clean locator/CAS reuse assertion after the manifest envelope is empty.
    func testProjectionPreloadMissingEnvelopeClassifiesThenReusesLocatorAndCAS() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Warm.swift": "struct Warm {}\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let seed = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        guard case .ready = await seed.engine.demand(seed.demand(path: "Sources/Warm.swift")) else {
            return XCTFail("Expected locator/CAS seed.")
        }
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)

        let sourceReads = EngineAsyncCounter()
        let recorder = EngineProjectionRecorder()
        let warm = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumRetainedSourceByteCountPerRoot: 8 * 1024 * 1024,
                maximumRetainedSourceByteCountPerOwner: 8 * 1024 * 1024,
                maximumRetainedSourceByteCount: 8 * 1024 * 1024
            ),
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await sourceReads.increment()
                throw FileSystemError.failedToReadFile
            },
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Warm.swift"
                let candidate = WorkspaceCodemapProjectionCatalogCandidate(
                    identity: WorkspaceCodemapArtifactBindingIdentity(
                        rootID: rootEpoch.rootID,
                        rootLifetimeID: rootEpoch.rootLifetimeID,
                        fileID: fileIDs.id(for: path),
                        standardizedRootPath: root.path,
                        standardizedRelativePath: path,
                        standardizedFullPath: root.appendingPathComponent(path).path
                    )!,
                    language: .swift,
                    requestGeneration: 1,
                    pathGeneration: 1
                )
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [candidate],
                    recorder: recorder
                ).client
            }
        )
        _ = await warm.engine.registerRoot(warm.registration)
        let capabilityState = await warm.capabilityService.state(for: warm.rootEpoch)
        let capability = try eligible(capabilityState)
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let namespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: pipeline
        )
        _ = try await runtime.manifestStore.replaceCurrentManifest(
            namespace: namespace,
            authority: CodeMapRootManifestAuthority(
                namespace: namespace,
                token: capability.repositoryAuthority
            ),
            records: [],
            lastAccessEpochSeconds: 42
        )

        _ = await warm.engine.scheduleProjectionPreload(rootEpoch: warm.rootEpoch)
        let completed = await waitForEngineCondition {
            await warm.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)
        let accounting = await warm.engine.accounting()
        let sourceReadCount = await sourceReads.value
        XCTAssertEqual(accounting.counters.projectionEnvelopeHits, 0)
        XCTAssertEqual(accounting.counters.classifications, 1)
        XCTAssertEqual(accounting.counters.projectionBuildsStarted, 0)
        XCTAssertEqual(accounting.counters.materializations, 0)
        XCTAssertEqual(accounting.counters.validatedWorktreeReads, 0)
        XCTAssertEqual(sourceReadCount, 0)
        XCTAssertEqual(accounting.counters.manifestWrites, 1)
    }

    func testProjectionPreloadCleanMaterializationOversizePublishesTerminalEntry() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Oversize.swift": "struct Oversize {}\n"]
        )
        let buildCounter = EngineAsyncCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                return .readyNoSymbols
            })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            materializationServiceOverride: GitBlobSourceMaterializationService(
                policy: GitBlobSourceMaterializationPolicy(maximumRawByteCount: 1)
            ),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Oversize.swift"
                let candidate = WorkspaceCodemapProjectionCatalogCandidate(
                    identity: WorkspaceCodemapArtifactBindingIdentity(
                        rootID: rootEpoch.rootID,
                        rootLifetimeID: rootEpoch.rootLifetimeID,
                        fileID: fileIDs.id(for: path),
                        standardizedRootPath: root.path,
                        standardizedRelativePath: path,
                        standardizedFullPath: root.appendingPathComponent(path).path
                    )!,
                    language: .swift,
                    requestGeneration: 1,
                    pathGeneration: 1
                )
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [candidate],
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let completed = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)

        let snapshots = await recorder.snapshots
        guard case let .segment(segment) = snapshots.first,
              let entry = segment.entries.first
        else { return XCTFail("Expected a terminal oversize projection segment.") }
        XCTAssertEqual(entry.outcome, .terminalArtifact(.oversize))
        let buildCount = await buildCounter.value
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(buildCount, 0)
        XCTAssertEqual(accounting.counters.projectionBuildsStarted, 0)
    }

    func testProjectionPreloadWorktreeFileTooLargePublishesTerminalEntry() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let path = "Sources/Oversize.swift"
        let root = try repository.makeRepository(
            named: "repository",
            files: [path: "struct Oversize {}\n"]
        )
        try repository.write("struct Oversize { let dirty = true }\n", to: path, at: root)
        let buildCounter = EngineAsyncCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                return .readyNoSymbols
            })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                throw FileSystemError.fileTooLarge
            },
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let candidate = WorkspaceCodemapProjectionCatalogCandidate(
                    identity: WorkspaceCodemapArtifactBindingIdentity(
                        rootID: rootEpoch.rootID,
                        rootLifetimeID: rootEpoch.rootLifetimeID,
                        fileID: fileIDs.id(for: path),
                        standardizedRootPath: root.path,
                        standardizedRelativePath: path,
                        standardizedFullPath: root.appendingPathComponent(path).path
                    )!,
                    language: .swift,
                    requestGeneration: 1,
                    pathGeneration: 1
                )
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [candidate],
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let completed = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)

        let snapshots = await recorder.snapshots
        guard case let .segment(segment) = snapshots.first,
              let entry = segment.entries.first
        else { return XCTFail("Expected a terminal worktree oversize projection segment.") }
        XCTAssertEqual(entry.outcome, .terminalArtifact(.oversize))
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.worktreeClassifications, 1)
        XCTAssertEqual(accounting.counters.projectionBuildsStarted, 0)
        let buildCount = await buildCounter.value
        XCTAssertEqual(buildCount, 0)
    }

    func testDemandAdmissionCountsActiveAndDrainingProjectionMaterializationUsage() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": "struct Preload {}\n",
                "Sources/Foreground.swift": "struct Foreground {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let gate = EngineMultiEntryGate()
        addTeardownBlock { await gate.releaseAll() }
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await gate.enter()
                return .readyNoSymbols
            })
        )
        let recorder = EngineProjectionRecorder()
        let sourceLimit = UInt64(8 * 1024 * 1024)
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumRetainedSourceByteCountPerRoot: sourceLimit,
                maximumRetainedSourceByteCountPerOwner: sourceLimit,
                maximumRetainedSourceByteCount: sourceLimit * 2,
                maximumConcurrentMaterializationCountPerRoot: 1,
                maximumConcurrentMaterializationCountPerOwner: 1,
                maximumConcurrentMaterializationCount: 1
            ),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Preload.swift"
                let candidate = WorkspaceCodemapProjectionCatalogCandidate(
                    identity: WorkspaceCodemapArtifactBindingIdentity(
                        rootID: rootEpoch.rootID,
                        rootLifetimeID: rootEpoch.rootLifetimeID,
                        fileID: fileIDs.id(for: path),
                        standardizedRootPath: root.path,
                        standardizedRelativePath: path,
                        standardizedFullPath: root.appendingPathComponent(path).path
                    )!,
                    language: .swift,
                    requestGeneration: 1,
                    pathGeneration: 1
                )
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [candidate],
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let enteredBuild = await gate.waitUntilEntered(1)
        XCTAssertTrue(enteredBuild)
        let activeProjectionRetained = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionResources.retainedSourceBytes == sourceLimit &&
                accounting.activeProjectionBatchCount == 1 &&
                accounting.projectionRoots.first?.activeBatchCount == 1
        }
        XCTAssertTrue(activeProjectionRetained)

        let blockedByActive = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Foreground.swift"))
        }
        let queuedBehindActive = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.activeRequestCount == 0 && accounting.queuedRequestCount == 1
        }
        XCTAssertTrue(queuedBehindActive)
        blockedByActive.cancel()
        guard case .cancelled = await blockedByActive.value else {
            return XCTFail("Expected the active-usage demand to cancel from the admission queue.")
        }
        let activeDemandQueueDrained = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.activeRequestCount == 0 && accounting.queuedRequestCount == 0
        }
        XCTAssertTrue(activeDemandQueueDrained)

        _ = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Unrelated.swift"]
        )
        let drainingRetained = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionJobCount == 0 &&
                accounting.drainingProjectionTaskCount == 1 &&
                accounting.activeProjectionBatchCount == 1 &&
                accounting.projectionResources.retainedSourceBytes == sourceLimit
        }
        XCTAssertTrue(drainingRetained)

        let blockedByDrain = Task {
            await fixture.engine.demand(fixture.demand(path: "Sources/Foreground.swift"))
        }
        let queuedBehindDrain = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.activeRequestCount == 0 && accounting.queuedRequestCount == 1
        }
        XCTAssertTrue(queuedBehindDrain)
        let buildCountBeforeRelease = await gate.count
        XCTAssertEqual(buildCountBeforeRelease, 1)

        await gate.releaseAll()
        guard let drainedResult = await demandResult(blockedByDrain, before: .seconds(10)),
              isReady(drainedResult)
        else {
            blockedByDrain.cancel()
            return XCTFail("Expected demand admission after projection materialization drained.")
        }
        let fullyDrained = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.activeRequestCount == 0 &&
                accounting.queuedRequestCount == 0 &&
                accounting.drainingProjectionTaskCount == 0 &&
                accounting.activeProjectionBatchCount == 0 &&
                accounting.projectionResources == .zero
        }
        XCTAssertTrue(fullyDrained)
    }

    /// Extraction note: this covers transient projection redundancy by ensuring a replacement
    /// projection does not resolve while the same root's superseded active batch is draining.
    func testProjectionRescheduleWaitsForSameRootDrainingBatchAdmission() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": "struct Preload {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let gate = EngineMultiEntryGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await gate.enter()
                return .readyNoSymbols
            })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumActiveProjectionBatchCountPerRoot: 1,
                maximumActiveProjectionBatchCount: 2,
                projectionRetryInitialMilliseconds: 1,
                projectionRetryMaximumMilliseconds: 1,
                projectionRetryJitterPercent: 0
            ),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Preload.swift"
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )],
                    recorder: recorder
                ).client
            }
        )
        addTeardownBlock { await gate.releaseAll() }
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let firstBuildEntered = await gate.waitUntilEntered(1)
        XCTAssertTrue(firstBuildEntered)

        _ = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Unrelated.swift"]
        )
        let replacementSchedule = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(replacementSchedule, .handedOff)
        let replacementQueued = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.queuedProjectionBatchCount == 1 &&
                accounting.projectionRoots.first?.activeBatchCount == 1
        }
        XCTAssertTrue(replacementQueued)
        let buildCountBeforeRelease = await gate.count
        XCTAssertEqual(buildCountBeforeRelease, 1)

        await gate.releaseAll()
        let completed = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(completed)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 2)
        XCTAssertEqual(accounting.counters.projectionCoveragesCancelled, 1)
        XCTAssertEqual(accounting.activeProjectionBatchCount, 0)
    }

    func testProjectionRescheduleCountsSameRootDrainingSourceAndMaterialization() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": "struct Preload {}\n",
                "Sources/Unrelated.swift": "struct Unrelated {}\n"
            ]
        )
        let gate = EngineMultiEntryGate()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await gate.enter()
                return .readyNoSymbols
            })
        )
        let recorder = EngineProjectionRecorder()
        let sourceReservation = UInt64(8 * 1024 * 1024)
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumRetainedSourceByteCountPerRoot: sourceReservation,
                maximumRetainedSourceByteCountPerOwner: sourceReservation,
                maximumRetainedSourceByteCount: sourceReservation * 3,
                maximumConcurrentMaterializationCountPerRoot: 1,
                maximumConcurrentMaterializationCountPerOwner: 1,
                maximumConcurrentMaterializationCount: 2,
                maximumActiveProjectionBatchCountPerRoot: 2,
                maximumActiveProjectionBatchCount: 2,
                projectionRetryInitialMilliseconds: 1,
                projectionRetryMaximumMilliseconds: 1,
                projectionRetryJitterPercent: 0
            ),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Preload.swift"
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )],
                    recorder: recorder
                ).client
            }
        )
        addTeardownBlock { await gate.releaseAll() }
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let firstBuildEntered = await gate.waitUntilEntered(1)
        XCTAssertTrue(firstBuildEntered)

        _ = await fixture.engine.invalidateModified(
            rootEpoch: fixture.rootEpoch,
            standardizedRelativePaths: ["Sources/Unrelated.swift"]
        )
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let replacementRetried = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.counters.projectionRetries > 0 &&
                accounting.projectionRoots.first?.resources.retainedSourceBytes == sourceReservation
        }
        XCTAssertTrue(replacementRetried)
        let buildCountBeforeRelease = await gate.count
        XCTAssertEqual(buildCountBeforeRelease, 1)

        await gate.releaseAll()
        let completed = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(completed)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.projectionResources, .zero)
        XCTAssertEqual(accounting.activeProjectionBatchCount, 0)
    }

    func testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let canonical = try repository.makeRepository(
            named: "canonical",
            files: [
                "Sources/Unchanged.swift": "struct Unchanged {}\n",
                "Sources/Changed.swift": "struct Changed {}\n"
            ]
        )
        let linked = try repository.makeLinkedWorktree(
            from: canonical,
            named: "linked",
            branch: "linked-preload"
        )
        let externalParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(#function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalParent, withIntermediateDirectories: false)
        let external = externalParent.appendingPathComponent("external", isDirectory: true)
        _ = try repository.runGit(
            ["worktree", "add", "-b", "external-preload", external.path, "HEAD"],
            at: canonical
        )
        defer {
            _ = try? repository.runGit(["worktree", "remove", "--force", external.path], at: canonical)
            try? FileManager.default.removeItem(at: externalParent)
        }

        let buildCounter = EngineAsyncCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                return .readyNoSymbols
            })
        )
        let seed = try await makeEngineFixture(root: canonical, runtime: runtime)
        _ = await seed.engine.registerRoot(seed.registration)
        for path in ["Sources/Unchanged.swift", "Sources/Changed.swift"] {
            guard await isReady(seed.engine.demand(seed.demand(path: path))) else {
                return XCTFail("Expected initial artifact seed for \(path).")
            }
        }
        let seedManifestDrained = await waitForEngineCondition {
            let accounting = await seed.engine.accounting()
            return accounting.dirtyManifestCount == 0 && accounting.counters.manifestWrites > 0
        }
        XCTAssertTrue(seedManifestDrained)
        try await replaceCurrentManifestWithEmpty(fixture: seed, runtime: runtime)
        await seed.engine.unloadRoot(rootEpoch: seed.rootEpoch)
        let seededBuildCount = await buildCounter.value
        XCTAssertEqual(seededBuildCount, 2)

        let roots = [("main", canonical), ("linked", linked), ("external", external)]
        for (label, root) in roots {
            try repository.write(
                "struct Changed { let location = \"\(label)\" }\n",
                to: "Sources/Changed.swift",
                at: root
            )
            let recorder = EngineProjectionRecorder()
            let before = await runtime.coordinator.accounting()
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                projectionCatalogFactory: { rootEpoch, fileIDs in
                    let candidates = ["Sources/Unchanged.swift", "Sources/Changed.swift"].map { path in
                        WorkspaceCodemapProjectionCatalogCandidate(
                            identity: WorkspaceCodemapArtifactBindingIdentity(
                                rootID: rootEpoch.rootID,
                                rootLifetimeID: rootEpoch.rootLifetimeID,
                                fileID: fileIDs.id(for: path),
                                standardizedRootPath: root.path,
                                standardizedRelativePath: path,
                                standardizedFullPath: root.appendingPathComponent(path).path
                            )!,
                            language: .swift,
                            requestGeneration: 1,
                            pathGeneration: 1
                        )
                    }
                    return EngineProjectionCatalogStub(
                        rootEpoch: rootEpoch,
                        entries: candidates,
                        recorder: recorder
                    ).client
                }
            )
            _ = await fixture.engine.registerRoot(fixture.registration)
            let schedule = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(schedule, .handedOff)
            let completed = await waitForEngineCondition {
                await fixture.engine.accounting().projectionRoots.first?.phase == .complete
            }
            XCTAssertTrue(completed, "Expected complete mixed projection for \(label).")

            let accounting = await fixture.engine.accounting()
            let after = await runtime.coordinator.accounting()
            XCTAssertEqual(accounting.counters.projectionEnvelopeHits, 0, label)
            // Under Git metadata refresh pressure, a clean unchanged file may safely fall back
            // to validated worktree bytes before locator/CAS reuse. This contract is the
            // resulting reuse/build behavior, not the exact clean-vs-worktree classifier route.
            XCTAssertEqual(accounting.counters.materializations, 0, label)
            XCTAssertEqual(accounting.counters.projectionLocatorMisses, 0, label)
            XCTAssertEqual(accounting.counters.projectionBuildsStarted, 1, label)
            XCTAssertEqual(after.counters.locatorHits, before.counters.locatorHits + 1, label)
            XCTAssertEqual(after.counters.buildsStarted, before.counters.buildsStarted + 1, label)
            let snapshots = await recorder.snapshots
            let projectedEntryCount = snapshots.reduce(into: 0) { count, snapshot in
                if case let .segment(segment) = snapshot { count += segment.entries.count }
            }
            XCTAssertEqual(projectedEntryCount, 2, label)
            await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch)
            await fixture.engine.shutdown()
        }
        let finalBuildCount = await buildCounter.value
        XCTAssertEqual(finalBuildCount, 5)
    }

    func testProjectionPreloadMapsWorktreeAndTerminalGitClassificationsWithoutCleanReuse() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let submoduleSource = try repository.makeRepository(
            named: "submodule-source",
            files: ["Sources/Submodule.swift": "struct Submodule {}\n"]
        )
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                ".gitattributes": "Sources/Transformed.swift text eol=crlf\n",
                "Sources/Transformed.swift": "struct Transformed { let value = 1 }\n",
                "Sources/Conflict.swift": "struct Conflict { let value = 0 }\n",
                "Sources/Assume.swift": "struct Assume { let value = 1 }\n",
                "Sources/Skip.swift": "struct Skip { let value = 1 }\n",
                "Sources/Real.swift": "struct Real {}\n"
            ]
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Sources/Link.swift").path,
            withDestinationPath: "Real.swift"
        )
        _ = try repository.runGit(["add", "--", "Sources/Link.swift"], at: root)
        _ = try repository.runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", submoduleSource.path, "Vendor/Sub"],
            at: root
        )
        try repository.commit("Add terminal boundaries", at: root)

        _ = try repository.runGit(["checkout", "-b", "conflict-side"], at: root)
        try repository.write(
            "struct Conflict { let value = 1 }\n",
            to: "Sources/Conflict.swift",
            at: root
        )
        try repository.stage("Sources/Conflict.swift", at: root)
        try repository.commit("Conflict side", at: root)
        _ = try repository.runGit(["checkout", "main"], at: root)
        try repository.write(
            "struct Conflict { let value = 2 }\n",
            to: "Sources/Conflict.swift",
            at: root
        )
        try repository.stage("Sources/Conflict.swift", at: root)
        try repository.commit("Conflict main", at: root)
        let merge = try repository.runGitResult(["merge", "conflict-side"], at: root)
        XCTAssertNotEqual(merge.terminationStatus, 0)

        _ = try repository.runGit(
            ["update-index", "--assume-unchanged", "--", "Sources/Assume.swift"],
            at: root
        )
        try repository.write(
            "struct Assume { let worktree = 2 }\n",
            to: "Sources/Assume.swift",
            at: root
        )
        _ = try repository.runGit(
            ["update-index", "--skip-worktree", "--", "Sources/Skip.swift"],
            at: root
        )
        try repository.write(
            "struct Skip { let worktree = 3 }\n",
            to: "Sources/Skip.swift",
            at: root
        )

        let buildCounter = EngineAsyncCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCounter.increment()
                return .readyNoSymbols
            })
        )
        let recorder = EngineProjectionRecorder()
        let paths = [
            "Sources/Transformed.swift",
            "Sources/Conflict.swift",
            "Sources/Assume.swift",
            "Sources/Skip.swift",
            "Sources/Link.swift",
            "Vendor/Sub"
        ]
        let classificationBatch = await GitBlobIdentityService().classify(
            workspaceRoot: root,
            relativePaths: paths
        )
        XCTAssertNil(classificationBatch.failure)
        let classifications = Dictionary(uniqueKeysWithValues: classificationBatch.classifications.map {
            ($0.relativePath, $0.outcome)
        })
        XCTAssertEqual(
            classifications["Sources/Transformed.swift"],
            .requiresValidatedWorktreeBytes(.checkoutTransformation)
        )
        XCTAssertEqual(
            classifications["Sources/Conflict.swift"],
            .requiresValidatedWorktreeBytes(.unmerged)
        )
        XCTAssertEqual(
            classifications["Sources/Assume.swift"],
            .requiresValidatedWorktreeBytes(.indexFlag)
        )
        XCTAssertEqual(
            classifications["Sources/Skip.swift"],
            .requiresValidatedWorktreeBytes(.indexFlag)
        )
        XCTAssertEqual(classifications["Sources/Link.swift"], .securityExcluded(.symlinkLeaf))
        XCTAssertEqual(classifications["Vendor/Sub"], .unsupported(.gitlink))
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let candidates = paths.map { path in
                    WorkspaceCodemapProjectionCatalogCandidate(
                        identity: WorkspaceCodemapArtifactBindingIdentity(
                            rootID: rootEpoch.rootID,
                            rootLifetimeID: rootEpoch.rootLifetimeID,
                            fileID: fileIDs.id(for: path),
                            standardizedRootPath: root.path,
                            standardizedRelativePath: path,
                            standardizedFullPath: root.appendingPathComponent(path).path
                        )!,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )
                }
                return EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: candidates,
                    recorder: recorder
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let completed = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)

        let accounting = await fixture.engine.accounting()
        let projectionRetryCounterDiagnostic = """
        Projection preload retry-aware counters for worktree/terminal classifications.
        classifications: \(accounting.counters.classifications)
        cleanClassifications: \(accounting.counters.cleanClassifications)
        worktreeClassifications: \(accounting.counters.worktreeClassifications)
        validatedWorktreeReads: \(accounting.counters.validatedWorktreeReads)
        projectionRetries: \(accounting.counters.projectionRetries)
        projectionBuildsStarted: \(accounting.counters.projectionBuildsStarted)
        materializations: \(accounting.counters.materializations)
        projectionLocatorMisses: \(accounting.counters.projectionLocatorMisses)
        projectionRoots: \(accounting.projectionRoots)
        """
        XCTAssertGreaterThanOrEqual(accounting.counters.classifications, 1, projectionRetryCounterDiagnostic)
        XCTAssertEqual(accounting.counters.cleanClassifications, 0)
        XCTAssertGreaterThanOrEqual(accounting.counters.worktreeClassifications, 4, projectionRetryCounterDiagnostic)
        XCTAssertGreaterThanOrEqual(accounting.counters.validatedWorktreeReads, 4, projectionRetryCounterDiagnostic)
        XCTAssertEqual(
            accounting.counters.worktreeClassifications,
            accounting.counters.validatedWorktreeReads,
            projectionRetryCounterDiagnostic
        )
        XCTAssertEqual(accounting.counters.materializations, 0)
        XCTAssertEqual(accounting.counters.projectionLocatorMisses, 0)
        XCTAssertEqual(accounting.counters.projectionBuildsStarted, 4)
        let buildCount = await buildCounter.value
        XCTAssertEqual(buildCount, 4)

        let snapshots = await recorder.snapshots
        let entries = snapshots.flatMap { snapshot -> [WorkspaceCodemapProjectionEntry] in
            if case let .segment(segment) = snapshot { return segment.entries }
            return []
        }
        let outcomes = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.identity.standardizedRelativePath, $0.outcome)
        })
        for path in paths.prefix(4) {
            guard case .empty? = outcomes[path] else {
                return XCTFail("Expected source-backed empty projection for \(path).")
            }
        }
        XCTAssertEqual(outcomes["Sources/Link.swift"], .terminalExcluded(.securityExcluded))
        XCTAssertEqual(outcomes["Vendor/Sub"], .terminalExcluded(.gitlink))
    }

    func testProjectionPreloadUnloadCancelsBlockedCatalogPageAndDrainsAccounting() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["README.md": "# Blocked projection catalog\n"]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let gate = EngineAsyncGate()
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            projectionCatalogFactory: { rootEpoch, _ in
                EngineProjectionCatalogStub(
                    rootEpoch: rootEpoch,
                    entries: [],
                    recorder: recorder,
                    pageGate: gate
                ).client
            }
        )
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        XCTAssertTrue(gate.waitUntilEntered())

        let unload = Task { await fixture.engine.unloadRoot(rootEpoch: fixture.rootEpoch) }
        gate.release()
        await unload.value
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.projectionJobCount, 0)
        XCTAssertEqual(accounting.queuedProjectionBatchCount, 0)
        XCTAssertEqual(accounting.activeProjectionBatchCount, 0)
        XCTAssertEqual(accounting.projectionResources, .zero)
        XCTAssertEqual(accounting.counters.projectionCoveragesCancelled, 1)
        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots.count, 0)
    }
}
