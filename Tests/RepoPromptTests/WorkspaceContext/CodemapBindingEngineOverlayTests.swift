import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

final class CodemapBindingEngineOverlayTests: CodemapBindingEngineTestCase {
    func testProjectionRestartsAgainstConcurrentOverlayContributionGeneration() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": SwiftFixtureSource.emptyStruct("Preload"),
                "Sources/Live.swift": SwiftFixtureSource.emptyStruct("Live")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let overlay = WorkspaceCodemapLiveOverlay()
        let recorder = EngineProjectionRecorder()
        let publicationGate = EngineAsyncGate()
        let publisher = EngineProjectionGenerationRacePublisher(
            gate: publicationGate,
            recorder: recorder
        )
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            overlay: overlay,
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
                    recorder: recorder,
                    publishProjectionOverride: { snapshot in
                        await publisher.publish(snapshot)
                    }
                ).client
            }
        )
        addTeardownBlock { publicationGate.release() }
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let publicationEntered = await publicationGate.waitUntilEntered()
        XCTAssertTrue(publicationEntered)

        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Live.swift")) else {
            publicationGate.release()
            return XCTFail("Expected concurrent live overlay publication.")
        }
        publicationGate.release()
        let completed = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(completed)

        let snapshots = await publisher.snapshots
        let segmentGenerations = snapshots.compactMap { snapshot -> WorkspaceCodemapProjectionGeneration? in
            guard case let .segment(segment) = snapshot else { return nil }
            return segment.generation
        }
        XCTAssertGreaterThanOrEqual(segmentGenerations.count, 2)
        XCTAssertLessThan(
            try XCTUnwrap(segmentGenerations.first?.contributionGeneration),
            try XCTUnwrap(segmentGenerations.last?.contributionGeneration)
        )
        let segmentSequences = snapshots.compactMap { snapshot -> UInt64? in
            guard case let .segment(segment) = snapshot else { return nil }
            return segment.sequence
        }
        XCTAssertEqual(segmentSequences, [0, 0])
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.projectionCoveragesSuperseded, 1)
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 1)
        let repeatedSchedule = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        XCTAssertEqual(repeatedSchedule, .handedOff)
    }

    func testCompletedProjectionPreparesAndCommitsOverlayGenerationSuccessorWithoutReplay() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": SwiftFixtureSource.emptyStruct("Preload"),
                "Sources/Live.swift": SwiftFixtureSource.emptyStruct("Live")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
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
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let completed = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)

        let retainedDemand = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fixture.fileIDs.id(for: "Sources/Preload.swift")],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: .max,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(retainedTicket, initialRetainedStatus) = retainedDemand,
              case .ready = initialRetainedStatus
        else {
            return XCTFail("Expected retained demand to observe generation-1 coverage.")
        }

        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Live.swift")) else {
            return XCTFail("Expected live publication to advance overlay generation.")
        }
        let frozenBundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let bundle = try XCTUnwrap(frozenBundle)
        defer { bundle.close() }
        let liveSnapshot = try bundle.graphSnapshot()
        let preparedSeal = await fixture.engine.prepareCompletedProjectionSuccessor(
            rootEpoch: fixture.rootEpoch,
            liveSnapshot: liveSnapshot
        )
        let seal = try XCTUnwrap(preparedSeal)
        let fencedStatus = await fixture.engine.projectionDemandStatus(retainedTicket)
        XCTAssertEqual(fencedStatus, .stale)
        XCTAssertEqual(seal.predecessorProof.generation.contributionGeneration.rawValue, 1)
        XCTAssertEqual(
            seal.successorProof.generation.contributionGeneration,
            liveSnapshot.contributionGeneration
        )
        let committed = await fixture.engine.commitCompletedProjectionSuccessor(seal)
        XCTAssertTrue(committed)
        let duplicate = await fixture.engine.prepareCompletedProjectionSuccessor(
            rootEpoch: fixture.rootEpoch,
            liveSnapshot: liveSnapshot
        )
        XCTAssertNil(duplicate)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 1)
    }

    func testRejectedCompletedProjectionSuccessorRestartsWorkerAndCoalescesRetainedDemand() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Preload.swift": SwiftFixtureSource.emptyStruct("Preload"),
                "Sources/Live.swift": SwiftFixtureSource.emptyStruct("Live")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
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
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let initialCompleted = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .complete &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(initialCompleted)

        let retainedDemand = await fixture.engine.acquireProjectionDemand(
            rootEpoch: fixture.rootEpoch,
            fileIDs: [fixture.fileIDs.id(for: "Sources/Preload.swift")],
            catalogGeneration: 1,
            ingressGeneration: 1,
            deadlineUptimeNanoseconds: .max,
            owner: WorkspaceCodemapLiveDemandOwner()
        )
        guard case let .acquired(retainedTicket, initialStatus) = retainedDemand,
              case .ready = initialStatus
        else {
            return XCTFail("Expected retained demand to observe initial projection coverage.")
        }

        guard case .ready = await fixture.engine.demand(fixture.demand(path: "Sources/Live.swift")) else {
            return XCTFail("Expected live publication to advance overlay generation.")
        }
        let frozenBundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let bundle = try XCTUnwrap(frozenBundle)
        defer { bundle.close() }
        let liveSnapshot = try bundle.graphSnapshot()
        let preparedSeal = await fixture.engine.prepareCompletedProjectionSuccessor(
            rootEpoch: fixture.rootEpoch,
            liveSnapshot: liveSnapshot
        )
        let seal = try XCTUnwrap(preparedSeal)

        let restarted = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: liveSnapshot.contributionGeneration
        )
        XCTAssertTrue(restarted)
        let duplicateRestart = await fixture.engine.restartCompletedProjectionForOverlayAdvance(
            rootEpoch: fixture.rootEpoch,
            contributionGeneration: liveSnapshot.contributionGeneration
        )
        XCTAssertFalse(duplicateRestart)
        let successorCompleted = await fixture.engine.waitForCurrentProjectionCoverage(
            rootEpoch: fixture.rootEpoch
        )
        XCTAssertTrue(successorCompleted)
        let completedAccounting = await fixture.engine.accounting()
        XCTAssertEqual(completedAccounting.projectionRoots.first?.phase, .complete)
        XCTAssertEqual(completedAccounting.activeProjectionBatchCount, 0)
        XCTAssertEqual(completedAccounting.queuedProjectionBatchCount, 0)

        let retainedStatus = await fixture.engine.projectionDemandStatus(retainedTicket)
        XCTAssertEqual(retainedStatus, .ready(seal.successorProof))
        var accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.retainedProjectionDemandCount, 1)
        XCTAssertEqual(accounting.counters.projectionPreloadsScheduled, 2)
        await fixture.engine.releaseProjectionDemand(retainedTicket)
        accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.retainedProjectionDemandCount, 0)
    }

    func testProjectionResourceBudgetExposesTypedTerminalCoverage() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: ["Sources/Budget.swift": SwiftFixtureSource.emptyStruct("Budget")]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumRetainedProjectionByteCountPerRoot: 1,
                maximumRetainedProjectionByteCount: 1
            ),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Budget.swift"
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
        _ = await fixture.engine.registerRoot(fixture.registration)
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let budgeted = await waitForEngineCondition {
            let accounting = await fixture.engine.accounting()
            return accounting.projectionRoots.first?.phase == .budgetLimited &&
                accounting.activeProjectionBatchCount == 0
        }
        XCTAssertTrue(budgeted)
        let accounting = await fixture.engine.accounting()
        let budget = try XCTUnwrap(accounting.projectionRoots.first?.budget)
        XCTAssertEqual(budget.dimension, .retainedProjectionBytes)
        XCTAssertGreaterThan(budget.attempted, 1)
        XCTAssertEqual(budget.limit, 1)
        XCTAssertEqual(accounting.suspendedProjectionJobCount, 0)
        XCTAssertNil(accounting.projectionRoots.first?.retry)
        XCTAssertEqual(accounting.activeProjectionBatchCount, 0)

        let disposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [],
                candidates: [],
                maximumMatchedCandidateCount: 0
            )
        )
        guard case let .budget(dimension, attempted, limit) = disposition else {
            return XCTFail("Expected typed terminal budget coverage.")
        }
        XCTAssertEqual(dimension, budget.dimension)
        XCTAssertEqual(attempted, budget.attempted)
        XCTAssertEqual(limit, budget.limit)
    }

    func testProjectionCompletenessDoesNotUseManifestAdoptionRetentionCap() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let paths = ["Sources/One.swift", "Sources/Two.swift"]
        let root = try repository.makeRepository(
            named: "repository",
            files: Dictionary(uniqueKeysWithValues: paths.map { ($0, SwiftFixtureSource.emptyStruct("Value")) })
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(maximumManifestAdoptionRecordCount: 1),
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

        let candidates = paths.map { path in
            WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate(
                identity: WorkspaceCodemapArtifactBindingIdentity(
                    rootID: fixture.rootEpoch.rootID,
                    rootLifetimeID: fixture.rootEpoch.rootLifetimeID,
                    fileID: fixture.fileIDs.id(for: path),
                    standardizedRootPath: root.path,
                    standardizedRelativePath: path,
                    standardizedFullPath: root.appendingPathComponent(path).path
                )!,
                language: .swift,
                requestGeneration: 1,
                catalogGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }
        let disposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [],
                candidates: candidates,
                maximumMatchedCandidateCount: 0
            )
        )
        guard case let .ready(plan) = disposition else {
            return XCTFail("Expected the complete two-candidate universe above the adoption cap.")
        }
        XCTAssertEqual(plan.indexedCandidateCount, 2)
        XCTAssertTrue(plan.necessaryCandidates.isEmpty)
        XCTAssertEqual(plan.coverageProof.catalogCompletion.supportedCandidateCount, 2)

        let subsetDisposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [],
                candidates: [candidates[0]],
                maximumMatchedCandidateCount: 0
            )
        )
        guard case .stale = subsetDisposition else {
            return XCTFail("Expected a subset to be rejected against the full-catalog coverage proof.")
        }
    }

    func testAutomaticSelectionMatchedCandidateBytesAreBounded() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": SwiftFixtureSource.emptyStruct("Source"),
                "Sources/Candidate.swift": SwiftFixtureSource.emptyStruct("Candidate")
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts"),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                .ready(CodeMapSyntaxArtifact(
                    imports: [],
                    classes: [ClassInfo(name: "Target", methods: [], properties: [])],
                    functions: [],
                    enums: [],
                    globalVars: [],
                    macros: [],
                    referencedTypes: ["Target"]
                ))
            })
        )
        let recorder = EngineProjectionRecorder()
        let fixture = try await makeEngineFixture(
            root: root,
            runtime: runtime,
            policy: WorkspaceCodemapBindingEnginePolicy(
                maximumAutomaticSelectionMatchedCandidateByteCount: 1
            ),
            projectionCatalogFactory: { rootEpoch, fileIDs in
                let path = "Sources/Candidate.swift"
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
        guard case let .ready(source) = await fixture.engine.demand(
            fixture.demand(path: "Sources/Source.swift")
        ) else { return XCTFail("Expected the source contribution.") }
        _ = await fixture.engine.scheduleProjectionPreload(rootEpoch: fixture.rootEpoch)
        let completed = await waitForEngineCondition {
            await fixture.engine.accounting().projectionRoots.first?.phase == .complete
        }
        XCTAssertTrue(completed)

        let candidatePath = "Sources/Candidate.swift"
        let candidate = try WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate(
            identity: XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
                rootID: fixture.rootEpoch.rootID,
                rootLifetimeID: fixture.rootEpoch.rootLifetimeID,
                fileID: fixture.fileIDs.id(for: candidatePath),
                standardizedRootPath: root.path,
                standardizedRelativePath: candidatePath,
                standardizedFullPath: root.appendingPathComponent(candidatePath).path
            )),
            language: .swift,
            requestGeneration: 1,
            catalogGeneration: 1,
            pathGeneration: 1,
            ingressGeneration: 1
        )
        let disposition = await fixture.engine.planAutomaticSelectionCandidates(
            WorkspaceCodemapBindingAutomaticSelectionPlanRequest(
                rootEpoch: fixture.rootEpoch,
                sourceTickets: [WorkspaceCodemapArtifactDemandTicket(
                    retainID: UUID(),
                    requestID: UUID(),
                    rootEpoch: fixture.rootEpoch,
                    fileID: source.fileID,
                    requestGeneration: source.requestGeneration,
                    catalogGeneration: 1,
                    pathGeneration: 1,
                    ingressGeneration: 1
                )],
                candidates: [candidate],
                maximumMatchedCandidateCount: 1
            )
        )
        guard case let .budget(dimension, attempted, limit) = disposition else {
            return XCTFail("Expected matched candidate byte-budget rejection.")
        }
        XCTAssertEqual(dimension, .retainedProjectionBytes)
        XCTAssertGreaterThan(attempted, 1)
        XCTAssertEqual(limit, 1)
    }
}
