import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentServiceTests: XCTestCase {
        func testImplementedOperationsMatchCanonicalAdvertisement() {
            XCTAssertEqual(
                PromptExperimentAgentOperation.allCases.map(\.rawValue),
                MCPDomainToolCatalog.promptExperimentOperations
            )
        }

        private final class FakeRuntime: PromptExperimentRuntime {
            var submitted: [PromptExperimentRunRequest] = []
            var cancelled: [PromptExperimentRuntimeHandle] = []
            var immediateResults: [Int: PromptExperimentRuntimeResult] = [:]
            var submissionErrors: [Int: PromptExperimentSubmissionError] = [:]
            var holdResults = false
            var holdSubmission = false
            var preflightedPlans: [PromptExperimentPlan] = []
            var preflightError: PromptExperimentAuthorityError?
            private var submissionGate: CheckedContinuation<Void, Never>?
            private var blockedSubmissionWaiters: [CheckedContinuation<Void, Never>] = []
            private var resultContinuations: [UUID: CheckedContinuation<PromptExperimentRuntimeResult, Never>] = [:]
            private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
            private var resultWaiters: [CheckedContinuation<Void, Never>] = []

            func preflightOptimization(_ plan: PromptExperimentPlan) async throws {
                preflightedPlans.append(plan)
                if let preflightError { throw preflightError }
            }

            func submit(
                _ request: PromptExperimentRunRequest,
                progress: @escaping @MainActor @Sendable (String) async -> Void
            ) async throws -> PromptExperimentRuntimeHandle {
                if let error = submissionErrors[request.attempt.ordinal] { throw error }
                if holdSubmission {
                    await withCheckedContinuation {
                        submissionGate = $0
                        let waiters = blockedSubmissionWaiters
                        blockedSubmissionWaiters.removeAll()
                        waiters.forEach { $0.resume() }
                    }
                }
                submitted.append(request)
                let waiters = submissionWaiters
                submissionWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await progress("controlled fake accepted")
                return PromptExperimentRuntimeHandle(
                    id: request.attempt.id,
                    tabID: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", request.attempt.ordinal))"),
                    runID: nil
                )
            }

            func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult {
                let request = submitted.first(where: { $0.attempt.id == handle.id })
                guard holdResults else {
                    let ordinal = request?.attempt.ordinal ?? 0
                    return immediateResults[ordinal] ?? Self.completed(
                        handle: handle,
                        output: "output-\(ordinal)",
                        fixtureDigest: request?.plan.environment.fixtureDigest ?? "unavailable"
                    )
                }
                return await withCheckedContinuation {
                    resultContinuations[handle.id] = $0
                    let waiters = resultWaiters
                    resultWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }

            func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation {
                cancelled.append(handle)
                return .requested
            }

            func waitUntilSubmitBlocked() async {
                if submissionGate != nil { return }
                await withCheckedContinuation { blockedSubmissionWaiters.append($0) }
            }

            func releaseSubmission() {
                submissionGate?.resume()
                submissionGate = nil
            }

            func waitUntilSubmitted() async {
                if !submitted.isEmpty { return }
                await withCheckedContinuation { submissionWaiters.append($0) }
            }

            func waitUntilWaitingForResult() async {
                if !resultContinuations.isEmpty { return }
                await withCheckedContinuation { resultWaiters.append($0) }
            }

            func settleFirst(disposition: PromptExperimentRuntimeDisposition = .completed) {
                guard let request = submitted.first,
                      let continuation = resultContinuations.removeValue(forKey: request.attempt.id)
                else { return }
                continuation.resume(returning: Self.result(
                    handle: PromptExperimentRuntimeHandle(id: request.attempt.id, tabID: nil, runID: nil),
                    disposition: disposition,
                    output: "late-output",
                    fixtureDigest: request.plan.environment.fixtureDigest
                ))
            }

            static func completed(
                handle: PromptExperimentRuntimeHandle,
                output: String,
                fixtureDigest: String
            ) -> PromptExperimentRuntimeResult {
                result(handle: handle, disposition: .completed, output: output, fixtureDigest: fixtureDigest)
            }

            static func result(
                handle: PromptExperimentRuntimeHandle,
                disposition: PromptExperimentRuntimeDisposition,
                output: String?,
                fixtureDigest: String = "fixture",
                selection: StoredSelection = StoredSelection(selectedPaths: ["fixture.md"]),
                assistantOutput: String? = "Done"
            ) -> PromptExperimentRuntimeResult {
                PromptExperimentRuntimeResult(
                    disposition: disposition,
                    runtimeLink: PromptExperimentRuntimeLink(
                        adapter: PromptExperimentPlan.executionAdapter,
                        tabID: handle.tabID,
                        runID: UUID(),
                        provider: "fake",
                        model: "fake-model"
                    ),
                    committedHandoff: output.map {
                        PromptExperimentRuntimeHandoff(
                            prompt: $0,
                            selection: selection,
                            selectionRevision: 7,
                            usedAgentOutputAsPrompt: false
                        )
                    },
                    assistantOutput: assistantOutput,
                    handoffUnavailableReason: output == nil ? "controlled missing handoff" : nil,
                    fixtureDigestBefore: fixtureDigest,
                    fixtureDigestAfter: fixtureDigest
                )
            }
        }

        private actor AsyncGate {
            private var isOpen = false
            private var entered = false
            private var entryWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                entered = true
                let waiters = entryWaiters
                entryWaiters.removeAll()
                waiters.forEach { $0.resume() }
                guard !isOpen else { return }
                await withCheckedContinuation { releaseWaiters.append($0) }
            }

            func waitUntilEntered() async {
                guard !entered else { return }
                await withCheckedContinuation { entryWaiters.append($0) }
            }

            func open() {
                isOpen = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        private struct Harness {
            let root: URL
            let store: PromptExperimentStore
            let runtime: FakeRuntime
            let service: PromptExperimentService
        }

        func testApprovalRequiresNativeActionAndExactDigest() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)

            do {
                try await harness.service.approve(experimentID: id, displayedDigest: plan.digest, source: .agent)
                XCTFail("Agent approval must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .approvalRequiresNativeUI)
            }
            do {
                try await harness.service.approve(experimentID: id, displayedDigest: "wrong")
                XCTFail("Digest mismatch must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .digestMismatch)
            }

            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            XCTAssertEqual(harness.service.record(id: id)?.phase, .approved)
            XCTAssertEqual(harness.service.record(id: id)?.approvals.last?.planDigest, plan.digest)
        }

        func testPersistenceReopenAndReadableViews() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            XCTAssertNil(reopened.loadError)
            XCTAssertEqual(reopened.record(id: id)?.currentPlan?.digest, plan.digest)
            XCTAssertEqual(reopened.record(id: id)?.phase, .approved)

            let directory = try await reopened.recordDirectoryURL(experimentID: id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("overview.md").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("plan.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("results.csv").path))
        }

        func testCorruptCanonicalStoreIsVisibleAndNotReplaced() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let canonical = root.appendingPathComponent("experiments.json")
            let bytes = Data("not-json".utf8)
            try bytes.write(to: canonical)
            let service = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )

            await service.load()

            XCTAssertNotNil(service.loadError)
            XCTAssertEqual(try Data(contentsOf: canonical), bytes)
        }

        func testScheduleIdentityIsDeterministicAndInterleaved() throws {
            let date = Date(timeIntervalSince1970: 100)
            let draft = Self.validDraft(date: date, repetitions: 3)
            let environment = try PromptExperimentEnvironment(
                workspaceID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                sourceTabID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                capturedAt: date,
                isolatedRootPath: "/tmp/synthetic",
                selection: StoredSelection(selectedPaths: ["/tmp/synthetic/fixture.md"]),
                fixtureFiles: [PromptExperimentFixtureFile(path: "/tmp/synthetic/fixture.md", byteCount: 1, sha256: "fixture")],
                fixtureDigest: "fixture",
                captureLimitations: ["synthetic"]
            )
            let first = try PromptExperimentPlan.seal(draft: draft, target: XCTUnwrap(Self.fakeTarget("explore")), environment: environment, at: date)
            let second = try PromptExperimentPlan.seal(draft: draft, target: XCTUnwrap(Self.fakeTarget("explore")), environment: environment, at: date.addingTimeInterval(50))

            XCTAssertEqual(first.digest, second.digest)
            XCTAssertEqual(first.trials.map(\.id), second.trials.map(\.id))
            let expected: [PromptExperimentCondition] = [.original, .candidate, .candidate, .original, .original, .candidate]
            XCTAssertEqual(first.trials.map(\.condition), expected)
            XCTAssertEqual(Set(first.trials.map(\.id)).count, first.trials.count)
        }

        func testTamperedScheduleInvalidatesApprovedPlanDigest() throws {
            let date = Date(timeIntervalSince1970: 100)
            let draft = Self.validDraft(date: date, repetitions: 1)
            let environment = PromptExperimentEnvironment(
                workspaceID: UUID(),
                sourceTabID: UUID(),
                capturedAt: date,
                isolatedRootPath: "/tmp/synthetic",
                selection: StoredSelection(selectedPaths: ["/tmp/synthetic/fixture.md"]),
                fixtureFiles: [PromptExperimentFixtureFile(path: "/tmp/synthetic/fixture.md", byteCount: 1, sha256: "fixture")],
                fixtureDigest: "fixture",
                captureLimitations: []
            )
            let plan = try PromptExperimentPlan.seal(
                draft: draft,
                target: XCTUnwrap(Self.fakeTarget("explore")),
                environment: environment,
                at: date
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(plan)) as? [String: Any])
            var trials = try XCTUnwrap(object["trials"] as? [[String: Any]])
            trials[0]["condition"] = PromptExperimentCondition.candidate.rawValue
            object["trials"] = trials
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let tampered = try decoder.decode(
                PromptExperimentPlan.self,
                from: JSONSerialization.data(withJSONObject: object)
            )

            XCTAssertFalse(tampered.verifiesIntegrity())
        }

        func testSubmissionUncertainStopsWithoutRetry() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.submissionErrors[1] = .acceptanceUnknown("transport lost after send")
            let id = try await approvedExperiment(harness)

            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .inconclusive)
            XCTAssertEqual(record.attempts.first?.status, .submissionUncertain)
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertEqual(record.attempts.dropFirst().first?.status, .planned)
        }

        func testRuntimeFailureRetainsSerialScheduleAndEvidence() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.immediateResults[1] = FakeRuntime.result(
                handle: PromptExperimentRuntimeHandle(id: UUID(), tabID: nil, runID: nil),
                disposition: .failed("controlled failure"),
                output: "failure evidence"
            )
            let id = try await approvedExperiment(harness)

            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(harness.runtime.submitted.map(\.attempt.ordinal), [1, 2])
            XCTAssertEqual(record.phase, .inconclusive)
            XCTAssertEqual(record.attempts.map(\.status), [.failed, .completed])
            XCTAssertNotNil(record.attempts.first?.committedHandoff)
        }

        func testCancellationPreservesRequestedThenLateSettlement() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilSubmitted()
            await harness.runtime.waitUntilWaitingForResult()

            try await harness.service.cancel(experimentID: id)
            var record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .cancelling)
            XCTAssertEqual(record.attempts.first?.status, .cancellationRequested)
            XCTAssertEqual(harness.runtime.cancelled.count, 1)

            harness.runtime.settleFirst()
            await harness.service.waitForExecutionForTesting(experimentID: id)
            record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .cancelled)
            XCTAssertEqual(record.attempts.first?.status, .cancelledSettled)
            XCTAssertEqual(record.attempts.first?.lateResultAfterCancellation, true)
            XCTAssertNotNil(record.attempts.first?.committedHandoff)
            XCTAssertEqual(record.attempts.dropFirst().first?.status, .planned)
        }

        func testCancellationDuringSubmissionIsForwardedAfterAcceptance() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdSubmission = true
            harness.runtime.holdResults = true
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilSubmitBlocked()
            do {
                try await harness.service.run(experimentID: id)
                XCTFail("Duplicate run admission must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .experimentAlreadyRunning)
            }

            try await harness.service.cancel(experimentID: id)
            XCTAssertEqual(harness.service.record(id: id)?.attempts.first?.status, .cancellationRequested)
            XCTAssertTrue(harness.runtime.cancelled.isEmpty)

            harness.runtime.releaseSubmission()
            await harness.runtime.waitUntilWaitingForResult()
            XCTAssertEqual(harness.runtime.cancelled.count, 1)
            harness.runtime.settleFirst(disposition: .cancelled)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .cancelled)
            XCTAssertEqual(record.attempts.first?.status, .cancelledSettled)
            XCTAssertEqual(record.attempts.first?.lateResultAfterCancellation, true)
        }

        func testReopenMarksInFlightSubmissionUncertain() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilSubmitted()
            await harness.runtime.waitUntilWaitingForResult()

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let reopenedRecord = try XCTUnwrap(reopened.record(id: id))
            XCTAssertEqual(reopenedRecord.phase, .inconclusive)
            XCTAssertEqual(reopenedRecord.attempts.first?.status, .submissionUncertain)

            try await harness.service.cancel(experimentID: id)
            harness.runtime.settleFirst(disposition: .cancelled)
            await harness.service.waitForExecutionForTesting(experimentID: id)
        }

        func testDraftOptimisticVersionRejectsStaleRepeatedUpdate() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            await harness.service.load()
            let id = try await harness.service.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            var original = try XCTUnwrap(harness.service.record(id: id)?.draft)
            let originalDigest = try original.contentDigest()
            original.title = "First writer"
            let updated = try await harness.service.updateDraft(
                experimentID: id,
                expectedDraftID: original.id,
                expectedDraftVersion: original.optimisticVersion,
                expectedDraftDigest: originalDigest,
                draft: original
            )
            XCTAssertEqual(updated.optimisticVersion, 2)

            do {
                original.title = "Stale writer"
                try await harness.service.updateDraft(
                    experimentID: id,
                    expectedDraftID: original.id,
                    expectedDraftVersion: 1,
                    expectedDraftDigest: originalDigest,
                    draft: original
                )
                XCTFail("A repeated update from version 1 must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .staleDraft)
            }
        }

        func testAgentDraftToNativeSealedProposalIsSessionOwnedAndUnprivileged() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let owner = PromptExperimentAgentOwner(controllerSessionID: UUID(), sourceTabID: UUID())
            let otherOwner = PromptExperimentAgentOwner(controllerSessionID: UUID(), sourceTabID: UUID())
            let interface = PromptExperimentAgentInterface(service: harness.service)

            let capabilities = try await interface.execute(.capabilities, owner: owner)
            guard case let .capabilities(operations, targets, gepaRuntime, _) = capabilities else {
                return XCTFail("Expected capabilities")
            }
            XCTAssertFalse(operations.contains("approve"))
            XCTAssertFalse(operations.contains("run"))
            XCTAssertEqual(targets.map(\.selector), harness.service.availableTargets().map(\.selector))
            XCTAssertEqual(gepaRuntime.pinnedRevision, PromptExperimentGEPAConfiguration.pinnedRevision)

            let createdResponse = try await interface.execute(.createDraft, owner: owner)
            guard case let .draft(id, created) = createdResponse else { return XCTFail("Expected draft") }
            let updatedResponse = try await interface.execute(.updateDraft(
                experimentID: id,
                expectedDraftID: created.id,
                expectedDraftVersion: created.optimisticVersion,
                expectedDraftDigest: created.contentDigest(),
                patch: PromptExperimentAgentDraftPatch(
                    title: "Agent proposal",
                    taskInput: "Report the value.",
                    syntheticFixture: "The value is cobalt.",
                    originalInstructions: "Read and answer.",
                    candidateInstructions: "Read, cite, and answer.",
                    targetRole: "explore",
                    repetitions: 1,
                    optimization: Self.validOptimization()
                )
            ), owner: owner)
            guard case let .draft(_, updated) = updatedResponse else { return XCTFail("Expected updated draft") }

            do {
                _ = try await interface.execute(.read(experimentID: id), owner: otherOwner)
                XCTFail("A different Agent session must not read the experiment")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .ownerMismatch)
            }

            _ = try await interface.execute(.proposeSeal(
                experimentID: id,
                expectedDraftID: updated.id,
                expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            ), owner: owner)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(sealed.phase, .awaitingApproval)
            XCTAssertEqual(sealed.currentPlan?.schemaVersion, PromptExperimentPlan.optimizationSchemaVersion)
            XCTAssertTrue(harness.runtime.preflightedPlans.isEmpty, "Preflight must not probe the external runtime before native approval")
            XCTAssertNil(PromptExperimentAgentOperation(rawValue: "approve"))
            XCTAssertNil(PromptExperimentAgentOperation(rawValue: "run"))

            let plan = try XCTUnwrap(sealed.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            XCTAssertEqual(harness.service.record(id: id)?.phase, .approved)

            let cloneResponse = try await interface.execute(.cloneDraft(experimentID: id), owner: owner)
            guard case let .draft(cloneID, cloneDraft) = cloneResponse else { return XCTFail("Expected owned clone draft") }
            XCTAssertNotEqual(cloneID, id)
            XCTAssertEqual(cloneDraft.optimization, plan.optimization)
            do {
                _ = try await interface.execute(.cloneDraft(experimentID: id), owner: otherOwner)
                XCTFail("A different Agent session must not clone the experiment")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .ownerMismatch)
            }
        }

        func testAgentCanProposeRunAgainButCannotStartIt() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let record = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let owner = PromptExperimentAgentOwner(
                controllerSessionID: record.controllerSessionID,
                sourceTabID: record.sourceTabID
            )
            let response = try await PromptExperimentAgentInterface(service: harness.service).execute(
                .proposeRunAgain(experimentID: id, expectedPlanDigest: plan.digest),
                owner: owner
            )
            guard case let .record(next, _) = response else { return XCTFail("Expected next-revision record") }
            XCTAssertEqual(next.phase, .drafting)
            XCTAssertEqual(next.draft?.parentPlanID, plan.id)
            XCTAssertEqual(next.draft?.optimization?.seedCandidate, plan.optimization?.seedCandidate)
            XCTAssertTrue(next.attempts(for: plan).count == 1)
            XCTAssertNil(PromptExperimentAgentOperation(rawValue: "start"))
        }

        func testCanonicalCommitSurvivesReadableProjectionFailure() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            let directory = try await harness.store.recordDirectoryURL(experimentID: id)
            try FileManager.default.removeItem(at: directory)
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data("blocked".utf8)))

            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            XCTAssertEqual(harness.service.record(id: id)?.phase, .approved)
            XCTAssertNotNil(harness.service.projectionError)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            XCTAssertNil(reopened.loadError)
            XCTAssertEqual(reopened.record(id: id)?.phase, .approved)
            XCTAssertNotNil(reopened.projectionError)
        }

        func testCreateWaitsForInitialLoadAndPreservesOldAndNewRecords() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let seed = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await seed.load()
            let oldID = try await seed.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())

            let gate = AsyncGate()
            let service = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root, beforeLoad: { await gate.wait() }),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            let newSessionID = UUID()
            let create = Task {
                try await service.createExperiment(controllerSessionID: newSessionID, sourceTabID: UUID())
            }
            await gate.waitUntilEntered()
            XCTAssertTrue(service.records.isEmpty)
            await gate.open()
            let newID = try await create.value

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            XCTAssertNotNil(reopened.record(id: oldID))
            XCTAssertNotNil(reopened.record(id: newID))
            XCTAssertEqual(reopened.records.count, 2)
        }

        func testNextRevisionReResolvesExperimentAfterFixtureReadSuspension() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = AsyncGate()
            let runtime = FakeRuntime()
            let store = PromptExperimentStore(
                rootURL: root,
                beforeReadSyntheticFixture: { await gate.wait() }
            )
            let service = PromptExperimentService(
                store: store,
                runtime: runtime,
                resolveTarget: Self.fakeTarget,
                now: { Date(timeIntervalSince1970: 1000) }
            )
            let harness = Harness(root: root, store: store, runtime: runtime, service: service)
            let originalID = try await approvedExperiment(harness)
            try await service.run(experimentID: originalID)
            await service.waitForExecutionForTesting(experimentID: originalID)
            let digest = try XCTUnwrap(service.record(id: originalID)?.currentPlan?.digest)

            let nextRevision = Task {
                try await service.startNextRevision(experimentID: originalID, expectedPlanDigest: digest)
            }
            await gate.waitUntilEntered()
            let insertedID = try await service.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            await gate.open()
            try await nextRevision.value

            XCTAssertEqual(service.record(id: originalID)?.draft?.revision, 2)
            XCTAssertEqual(service.record(id: insertedID)?.draft?.revision, 1)
            XCTAssertEqual(service.record(id: insertedID)?.phase, .drafting)
        }

        func testPriorRevisionEvidenceSurvivesNextRevisionRunAndReopen() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)
            let firstPlan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            let firstAttempts = try XCTUnwrap(harness.service.record(id: id)?.attempts(for: firstPlan))
            XCTAssertEqual(firstAttempts.count, 2)
            XCTAssertTrue(firstAttempts.allSatisfy { $0.committedHandoff != nil })

            try await harness.service.startNextRevision(experimentID: id, expectedPlanDigest: firstPlan.digest)
            var secondDraft = try XCTUnwrap(harness.service.record(id: id)?.draft)
            let secondBaseDigest = try secondDraft.contentDigest()
            secondDraft.candidateInstructions += " Include the fixture filename."
            let updated = try await harness.service.updateDraft(
                experimentID: id,
                expectedDraftID: secondDraft.id,
                expectedDraftVersion: secondDraft.optimisticVersion,
                expectedDraftDigest: secondBaseDigest,
                draft: secondDraft
            )
            let secondPlan = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: updated.id,
                expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            )
            try await harness.service.approve(experimentID: id, displayedDigest: secondPlan.digest)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let record = try XCTUnwrap(reopened.record(id: id))
            XCTAssertEqual(record.plans.map(\.revision), [1, 2])
            XCTAssertEqual(record.attempts(for: firstPlan).count, 2)
            XCTAssertEqual(record.attempts(for: secondPlan).count, 2)
            XCTAssertTrue(record.attempts(for: firstPlan).allSatisfy { $0.committedHandoff != nil })
            XCTAssertTrue(record.attempts(for: secondPlan).allSatisfy { $0.committedHandoff != nil })
        }

        func testLoadMigratesUnambiguousLegacyAttemptLineage() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            var legacyRecords = harness.service.records
            let recordIndex = try XCTUnwrap(legacyRecords.firstIndex { $0.id == id })
            for attemptIndex in legacyRecords[recordIndex].attempts.indices {
                legacyRecords[recordIndex].attempts[attemptIndex].planID = nil
                legacyRecords[recordIndex].attempts[attemptIndex].planRevision = nil
                legacyRecords[recordIndex].attempts[attemptIndex].planDigest = nil
            }
            _ = try await harness.store.saveRecords(legacyRecords)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let record = try XCTUnwrap(reopened.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            XCTAssertEqual(record.attempts(for: plan).count, plan.trials.count)
            XCTAssertTrue(record.attempts.allSatisfy {
                $0.planID == plan.id && $0.planRevision == plan.revision && $0.planDigest == plan.digest
            })

            let persisted = try await harness.store.loadRecords()
            XCTAssertEqual(persisted.first(where: { $0.id == id })?.attempts(for: plan).count, plan.trials.count)
        }

        func testCommittedHandoffUsesOverridePromptAndFinalSelectionAcrossReopen() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await approvedExperiment(harness)
            let record = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            let trial = try XCTUnwrap(plan.trials.first)
            let finalSelection = StoredSelection(
                selectedPaths: ["fixture.md", "notes.md"],
                manualCodemapPaths: ["fixture.md"],
                slices: ["fixture.md": [LineRange(start: 2, end: 4, description: "answer evidence")]],
                codemapAutoEnabled: false
            )
            let tabID = UUID()
            let committedTab = MCPServerViewModel.ContextBuilderCommittedTabSnapshot(
                identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: tabID),
                nestedRunID: UUID(),
                tab: ComposeTabState(
                    id: tabID,
                    name: "Committed",
                    selection: finalSelection,
                    promptText: "stale prompt area",
                    contextOverrides: ContextBuilderOverrides(
                        useOverridePrompt: true,
                        overridePromptText: "Actual immutable handoff"
                    )
                ),
                selectionRevision: 42,
                usedAgentOutputAsPrompt: false
            )
            let completion = ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion(
                runID: UUID(),
                tabID: tabID,
                identity: committedTab.identity,
                agentKind: .codexExec,
                modelRaw: "catalog-model-high",
                terminalDisposition: .completed,
                agentOutput: "Done",
                usedAgentOutputAsPrompt: false,
                committedTab: committedTab
            )
            let runtimeResult = NativePromptExperimentContextBuilderRuntime.runtimeResult(
                completion: completion,
                fallbackProvider: "fallback",
                fallbackModel: "fallback-model",
                fixtureDigestBefore: plan.environment.fixtureDigest,
                fixtureDigestAfter: plan.environment.fixtureDigest
            )
            XCTAssertEqual(runtimeResult.committedHandoff?.prompt, "Actual immutable handoff")
            XCTAssertEqual(runtimeResult.committedHandoff?.selection, finalSelection)
            XCTAssertEqual(runtimeResult.assistantOutput, "Done")
            harness.runtime.immediateResults[trial.ordinal] = runtimeResult

            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let reopenedRecord = try XCTUnwrap(reopened.record(id: id))
            let attempt = try XCTUnwrap(reopenedRecord.attempts.first)
            let handoff = try XCTUnwrap(attempt.committedHandoff)
            XCTAssertEqual(handoff.selection, finalSelection)
            XCTAssertEqual(handoff.selectionRevision, 42)
            XCTAssertEqual(attempt.assistantOutputPreview, "Done")
            XCTAssertNotEqual(handoff.promptPreview, attempt.assistantOutputPreview)
            let promptArtifactData = try await harness.store.readArtifact(handoff.promptEvidence)
            let assistantArtifact = try XCTUnwrap(attempt.assistantOutputEvidence)
            let assistantArtifactData = try await harness.store.readArtifact(assistantArtifact)
            XCTAssertEqual(String(data: promptArtifactData, encoding: .utf8), "Actual immutable handoff")
            XCTAssertEqual(String(data: assistantArtifactData, encoding: .utf8), "Done")

            let owner = PromptExperimentAgentOwner(
                controllerSessionID: reopenedRecord.controllerSessionID,
                sourceTabID: reopenedRecord.sourceTabID
            )
            let response = try await PromptExperimentAgentInterface(service: reopened).execute(.read(experimentID: id), owner: owner)
            guard case let .record(_, artifactTextBySHA256) = response else { return XCTFail("Expected record response") }
            XCTAssertEqual(artifactTextBySHA256[handoff.promptEvidence.sha256], "Actual immutable handoff")
            XCTAssertEqual(artifactTextBySHA256[attempt.assistantOutputEvidence?.sha256 ?? ""], "Done")

            let directory = try await reopened.recordDirectoryURL(experimentID: id)
            let overview = try String(contentsOf: directory.appendingPathComponent("overview.md"), encoding: .utf8)
            XCTAssertTrue(overview.contains("Actual immutable handoff"))
            XCTAssertTrue(overview.contains("fixture.md: 2-4 (answer evidence)"))
            XCTAssertTrue(overview.contains("Assistant output preview: Done"))
        }

        func testCompletedRuntimeWithoutCommittedHandoffIsInconclusive() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await approvedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            harness.runtime.immediateResults[1] = FakeRuntime.result(
                handle: PromptExperimentRuntimeHandle(id: UUID(), tabID: nil, runID: nil),
                disposition: .completed,
                output: nil,
                fixtureDigest: plan.environment.fixtureDigest,
                assistantOutput: "Done"
            )

            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .inconclusive)
            XCTAssertEqual(record.attempts.first?.status, .failed)
            XCTAssertEqual(record.attempts.first?.handoffUnavailableReason, "controlled missing handoff")
            XCTAssertEqual(record.attempts.first?.assistantOutputPreview, "Done")
        }

        func testExplicitCatalogTargetsSealExactModelsWithoutChangingRoleDefaults() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let targets = [
                PromptExperimentResolvedTarget(
                    role: "codexExec:gpt-6-astra-high",
                    agentRaw: AgentProviderKind.codexExec.rawValue,
                    modelRaw: "gpt-6-astra-high",
                    displayName: "Codex GPT-6 Astra High"
                ),
                PromptExperimentResolvedTarget(
                    role: "codexExec:gpt-6-astra-xhigh",
                    agentRaw: AgentProviderKind.codexExec.rawValue,
                    modelRaw: "gpt-6-astra-xhigh",
                    displayName: "Codex GPT-6 Astra XHigh"
                )
            ]
            let availability = AgentModelCatalog.AvailabilityContext(codexAvailable: true)
            let beforeOverrides = GlobalSettingsStore.shared.globalAgentModelsProfile().mcpAgentRoleOverrides
            let runtime = FakeRuntime()
            let store = PromptExperimentStore(rootURL: root)
            let service = PromptExperimentService(
                store: store,
                runtime: runtime,
                resolveTarget: { selector in
                    try PromptExperimentTargetCatalog.resolve(
                        selector,
                        availability: availability,
                        exactTargets: targets
                    )
                },
                availableTargets: { targets },
                now: { Date(timeIntervalSince1970: 1000) }
            )
            let harness = Harness(root: root, store: store, runtime: runtime, service: service)

            for target in targets {
                let id = try await preparedExperiment(harness, targetSelector: target.selector)
                let plan = try XCTUnwrap(service.record(id: id)?.currentPlan)
                XCTAssertEqual(plan.resolvedTarget, target)
                XCTAssertEqual(plan.resolvedTarget.canonicalSelectionID, target.selector)
            }
            XCTAssertEqual(GlobalSettingsStore.shared.globalAgentModelsProfile().mcpAgentRoleOverrides, beforeOverrides)
            XCTAssertTrue(runtime.submitted.isEmpty)

            await service.load()
            let invalidID = try await service.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            var invalidDraft = try XCTUnwrap(service.record(id: invalidID)?.draft)
            let invalidBaseDigest = try invalidDraft.contentDigest()
            invalidDraft.title = "Invalid target"
            invalidDraft.taskInput = "Task"
            invalidDraft.syntheticFixture = "Fixture"
            invalidDraft.originalInstructions = "Original"
            invalidDraft.candidateInstructions = "Candidate"
            invalidDraft.targetRole = "codexExec:not-in-capabilities"
            let updated = try await service.updateDraft(
                experimentID: invalidID,
                expectedDraftID: invalidDraft.id,
                expectedDraftVersion: invalidDraft.optimisticVersion,
                expectedDraftDigest: invalidBaseDigest,
                draft: invalidDraft
            )
            do {
                _ = try await service.seal(
                    experimentID: invalidID,
                    expectedDraftID: updated.id,
                    expectedDraftVersion: updated.optimisticVersion,
                    expectedDraftDigest: updated.contentDigest()
                )
                XCTFail("Unknown catalog selector must fail before approval or run")
            } catch let error as PromptExperimentAuthorityError {
                guard case .targetUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(runtime.submitted.isEmpty)
            XCTAssertEqual(GlobalSettingsStore.shared.globalAgentModelsProfile().mcpAgentRoleOverrides, beforeOverrides)
        }

        func testOptimizationPreflightRunsOnlyAfterNativeApprovalAndFailureDoesNotSubmit() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let (id, draft) = try await updatedOptimizationDraft(harness)
            harness.runtime.preflightError = .runtimeUnavailable("controlled pinned GEPA mismatch")

            let plan = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: draft.contentDigest()
            )
            XCTAssertTrue(harness.runtime.preflightedPlans.isEmpty)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)

            do {
                try await harness.service.run(experimentID: id)
                XCTFail("Failed GEPA preflight must reject runtime admission")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .runtimeUnavailable("controlled pinned GEPA mismatch"))
            }

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .approved)
            XCTAssertEqual(record.currentPlan?.id, plan.id)
            XCTAssertEqual(harness.runtime.preflightedPlans.map(\.id), [plan.id])
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertTrue(record.attempts(for: plan).isEmpty)
        }

        func testOptimizationResultPersistsCandidatesEvaluationsAndExactTargets() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            XCTAssertEqual(plan.schemaVersion, PromptExperimentPlan.optimizationSchemaVersion)
            XCTAssertEqual(plan.optimizationTargets?.reflection.role, "reflector")
            XCTAssertEqual(plan.optimizationTargets?.execution?.role, "executor")
            XCTAssertEqual(plan.trials.map(\.condition), [.optimization])

            var runtimeResult = FakeRuntime.result(
                handle: PromptExperimentRuntimeHandle(id: plan.trials[0].id, tabID: nil, runID: nil),
                disposition: .completed,
                output: nil,
                fixtureDigest: plan.environment.fixtureDigest,
                assistantOutput: nil
            )
            runtimeResult.optimizationResult = PromptExperimentOptimizationRuntimeResult(
                engine: "gepa",
                upstreamRevision: PromptExperimentGEPAConfiguration.pinnedRevision,
                baselineScore: 0,
                bestScore: 1,
                bestCandidateIndex: 1,
                candidates: ["baseline instructions", "improved instructions"],
                parentIndices: [[], [0]],
                aggregateScores: [0, 1],
                evaluations: [
                    PromptExperimentOptimizationRuntimeEvaluation(
                        candidateIndex: 1,
                        exampleID: "reviewed-1",
                        split: .validation,
                        score: 1,
                        feedback: "matched reviewed answer",
                        failureKind: nil,
                        output: "cobalt",
                        elapsedSeconds: 0.25
                    )
                ],
                totalEvaluations: 2,
                wallTimeSeconds: 1.5,
                proposerUsage: "unavailable_from_connected_model_completion_contract",
                runDirectoryRelativePath: "worker-runs/attempt/gepa-run",
                rawResultJSON: Data("{\"engine\":\"gepa\"}".utf8)
            )
            harness.runtime.immediateResults[1] = runtimeResult
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let record = try XCTUnwrap(reopened.record(id: id))
            let result = try XCTUnwrap(record.attempts(for: plan).first?.optimizationResult)
            XCTAssertEqual(result.bestCandidateIndex, 1)
            XCTAssertEqual(result.candidates.map(\.candidatePreview), ["baseline instructions", "improved instructions"])
            XCTAssertEqual(result.evaluations.first?.feedback, "matched reviewed answer")
            XCTAssertEqual(result.runDirectoryRelativePath, "worker-runs/attempt/gepa-run")
            XCTAssertEqual(result.proposerUsage, "unavailable_from_connected_model_completion_contract")
            XCTAssertNotNil(result.rawResultEvidence)
            let artifactText = try await reopened.readableArtifactText(for: record)
            for candidate in result.candidates {
                XCTAssertNotNil(artifactText[candidate.candidateEvidence.sha256])
            }
            let directory = try await reopened.recordDirectoryURL(experimentID: id)
            let overview = try String(contentsOf: directory.appendingPathComponent("overview.md"), encoding: .utf8)
            XCTAssertTrue(overview.contains("GEPA wall time: 1.500 seconds"))
            XCTAssertTrue(overview.contains("worker-runs/attempt/gepa-run"))
            XCTAssertTrue(overview.contains("matched reviewed answer"))
            XCTAssertTrue(overview.contains("Sealed optimization authority"))

            let cloneID = try await reopened.cloneExperiment(experimentID: id)
            let clone = try XCTUnwrap(reopened.record(id: cloneID))
            XCTAssertEqual(clone.phase, .drafting)
            XCTAssertEqual(clone.draft?.optimization, plan.optimization)
            XCTAssertTrue(clone.plans.isEmpty)
            XCTAssertTrue(clone.attempts.isEmpty)

            try await reopened.startNextRevision(experimentID: id, expectedPlanDigest: plan.digest)
            let next = try XCTUnwrap(reopened.record(id: id))
            XCTAssertEqual(next.draft?.optimization?.seedCandidate, "improved instructions")
            XCTAssertEqual(next.attempts(for: plan).first?.optimizationResult?.bestScore, 1)
            XCTAssertTrue(harness.runtime.submitted.count == 1)
        }

        func testOversizedOptimizationUpdatePreservesMemoryAndCanonicalStore() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let (id, current) = try await updatedOptimizationDraft(harness)
            let canonicalURL = harness.root.appendingPathComponent("experiments.json")
            let canonicalBefore = try Data(contentsOf: canonicalURL)
            var oversized = current
            let largeInput = String(repeating: "x", count: PromptExperimentDraft.maximumExampleCharacters)
            for index in 0 ..< 50 {
                oversized.optimization?.examples.append(PromptExperimentExample(
                    id: "large-\(index)",
                    split: .training,
                    input: largeInput,
                    expectedOutput: "ok",
                    reviewerNotes: nil
                ))
            }

            do {
                _ = try await harness.service.updateDraft(
                    experimentID: id,
                    expectedDraftID: current.id,
                    expectedDraftVersion: current.optimisticVersion,
                    expectedDraftDigest: current.contentDigest(),
                    draft: oversized
                )
                XCTFail("An aggregate specification over the encoded limit must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                guard case .invalidDraft = error else { return XCTFail("Unexpected error: \(error)") }
            }

            XCTAssertEqual(harness.service.record(id: id)?.draft, current)
            XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalBefore)
        }

        func testReviewedProjectSnapshotIsImmutableAndExcludesPrivateGradingData() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let sourceRoot = harness.root.appendingPathComponent("authorized-source", isDirectory: true)
            let sourceFile = sourceRoot.appendingPathComponent("Package.swift")
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            try Data("reviewed source v1".utf8).write(to: sourceFile)

            let environment = try await harness.store.materializeOptimizationEnvironment(
                experimentID: UUID(),
                planRevision: 1,
                project: PromptExperimentProjectSnapshotSpecification(
                    sourceRootPath: sourceRoot.path,
                    includedPaths: ["Package.swift"]
                ),
                authorizedSourceRoots: [sourceRoot.path]
            )
            XCTAssertEqual(environment.files.count, 2)
            let snapshot = environment.rootURL.appendingPathComponent("project/Package.swift")
            XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "reviewed source v1")
            try Data("source changed after sealing".utf8).write(to: sourceFile)
            XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "reviewed source v1")

            let visibleData = try environment.files
                .map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) }
                .reduce(into: Data()) { $0.append($1) }
            let visibleText = String(decoding: visibleData, as: UTF8.self)
            XCTAssertFalse(visibleText.contains("HOST_PRIVATE_EXPECTED_CANARY"))
            XCTAssertFalse(visibleText.contains("HOST_PRIVATE_REVIEWER_NOTES_CANARY"))
            XCTAssertEqual(
                environment.digest,
                PromptExperimentDigest.environmentInventorySHA256(
                    rootPath: environment.rootURL.path,
                    files: environment.files
                )
            )
        }

        func testOptimizationDigestBindsEvaluatorDataBudgetAndResolvedTargets() throws {
            let date = Date(timeIntervalSince1970: 123)
            let environment = try PromptExperimentEnvironment(
                workspaceID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                sourceTabID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                capturedAt: date,
                isolatedRootPath: "/tmp/gepa-digest",
                selection: StoredSelection(selectedPaths: ["reviewed-examples.json"]),
                fixtureFiles: [PromptExperimentFixtureFile(path: "reviewed-examples.json", byteCount: 10, sha256: "fixture")],
                fixtureDigest: "fixture",
                captureLimitations: ["isolated"]
            )
            let reflection = try XCTUnwrap(Self.fakeTarget("reflector"))
            let execution = try XCTUnwrap(Self.fakeTarget("executor"))
            let targets = PromptExperimentOptimizationTargets(reflection: reflection, execution: execution, judge: nil)

            func digest(_ specification: PromptExperimentOptimizationSpecification, targets selectedTargets: PromptExperimentOptimizationTargets = targets) throws -> String {
                let draft = PromptExperimentDraft(
                    revision: 1,
                    title: "Digest coverage",
                    optimization: specification,
                    createdAt: date,
                    updatedAt: date
                )
                return try PromptExperimentPlan.seal(
                    draft: draft,
                    target: execution,
                    optimizationTargets: selectedTargets,
                    environment: environment,
                    at: date
                ).digest
            }

            let original = Self.validOptimization()
            let originalDigest = try digest(original)
            var changedExample = original
            changedExample.examples[0].expectedOutput = "azure"
            var changedEvaluator = original
            changedEvaluator.evaluator.minimumScore = -1
            var changedBudget = original
            changedBudget.gepa.maxEvaluations += 1
            var changedGEPAOptions = original
            changedGEPAOptions.gepa.reflectionMinibatchSize = 7
            changedGEPAOptions.gepa.useMerge = true
            changedGEPAOptions.gepa.maxMergeInvocations = 4
            changedGEPAOptions.gepa.skipPerfectScore = false
            var changedProject = original
            changedProject.projectSnapshot = PromptExperimentProjectSnapshotSpecification(
                sourceRootPath: "/tmp/reviewed",
                includedPaths: ["Package.swift"]
            )
            let changedTargets = try PromptExperimentOptimizationTargets(
                reflection: XCTUnwrap(Self.fakeTarget("different-reflector")),
                execution: execution,
                judge: nil
            )

            XCTAssertNotEqual(try digest(changedExample), originalDigest)
            XCTAssertNotEqual(try digest(changedEvaluator), originalDigest)
            XCTAssertNotEqual(try digest(changedBudget), originalDigest)
            XCTAssertNotEqual(try digest(changedGEPAOptions), originalDigest)
            XCTAssertNotEqual(try digest(changedProject), originalDigest)
            XCTAssertNotEqual(try digest(original, targets: changedTargets), originalDigest)
        }

        func testSealedPlanDisclosureIncludesCompleteApprovalAuthority() throws {
            let date = Date(timeIntervalSince1970: 456)
            let environment = try PromptExperimentEnvironment(
                workspaceID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                sourceTabID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                capturedAt: date,
                isolatedRootPath: "/tmp/gepa-disclosure",
                selection: StoredSelection(selectedPaths: ["project/Package.swift"]),
                fixtureFiles: [PromptExperimentFixtureFile(
                    path: "project/Package.swift",
                    byteCount: 42,
                    sha256: "manifest-sha-256-canary"
                )],
                fixtureDigest: "aggregate-manifest-digest-canary",
                captureLimitations: ["reviewed snapshot"]
            )
            var specification = Self.validOptimization()
            specification.examples[0].expectedOutput = "expected-output-canary"
            specification.examples[0].reviewerNotes = "reviewer-notes-canary"
            specification.evaluator.candidateFileName = "candidate-instructions.md"
            specification.gepa.stopAtScore = 0.875
            specification.projectSnapshot = PromptExperimentProjectSnapshotSpecification(
                sourceRootPath: "/tmp/authorized-project",
                includedPaths: ["Package.swift"]
            )
            let reflection = try XCTUnwrap(Self.fakeTarget("reflector"))
            let execution = try XCTUnwrap(Self.fakeTarget("executor"))
            let plan = try PromptExperimentPlan.seal(
                draft: PromptExperimentDraft(
                    revision: 1,
                    title: "Disclosure coverage",
                    optimization: specification,
                    createdAt: date,
                    updatedAt: date
                ),
                target: execution,
                optimizationTargets: PromptExperimentOptimizationTargets(
                    reflection: reflection,
                    execution: execution,
                    judge: nil
                ),
                environment: environment,
                at: date
            )

            let rendered = try PromptExperimentSealedPlanPresentation.prettyPrintedJSON(plan)

            for expected in [
                "expectedOutput", "expected-output-canary",
                "reviewerNotes", "reviewer-notes-canary",
                "candidateFileName", "candidate-instructions.md",
                "stopAtScore", "0.875",
                "manifest-sha-256-canary", "aggregate-manifest-digest-canary"
            ] {
                XCTAssertTrue(rendered.contains(expected), "Missing sealed authority field/value: \(expected)")
            }
        }

        func testGEPASetupInstructionsRequireCompatiblePythonAndDescribePinScope() {
            let instructions = PromptExperimentGEPAWorker.setupInstructions

            XCTAssertTrue(instructions.contains("Python >=3.10,<3.15"))
            XCTAssertTrue(instructions.contains("python3.11 -c"))
            XCTAssertTrue(instructions.contains("(3, 10) <= sys.version_info < (3, 15)"))
            XCTAssertTrue(instructions.contains("transitive dependencies are not hash-locked"))
            XCTAssertFalse(instructions.contains("/usr/bin/python3 -m venv"))
        }

        func testCommandEvaluatorDistinguishesCandidateAndInfrastructureFailures() throws {
            let candidate = try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: #"{"score":0.25,"feedback":"candidate output was invalid","failure_kind":"candidate"}"#,
                minimumScore: 0,
                maximumScore: 1,
                elapsedSeconds: 0.1
            )
            XCTAssertFalse(candidate.ok)
            XCTAssertEqual(candidate.failureKind, .candidate)
            XCTAssertEqual(candidate.score, 0.25)

            XCTAssertThrowsError(try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: #"{"score":0,"feedback":"sandbox bootstrap failed","failure_kind":"infrastructure"}"#,
                minimumScore: 0,
                maximumScore: 1,
                elapsedSeconds: 0.1
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("infrastructure failure"))
            }
        }

        func testPromptOnlyClaudeProfileDisablesNativeAndWebTools() {
            let configuration = ClaudeCodeAgentConfig.promptExperiment(modelString: "claude-sonnet-4-6")
            XCTAssertFalse(configuration.allowNativeBashTool)
            XCTAssertTrue(configuration.mcpStrictMode)
            XCTAssertFalse(configuration.toolSearchEnabled)
            for tool in ["Bash", "Read", "Write", "Edit", "WebSearch", "WebFetch", "Task"] {
                XCTAssertTrue(configuration.disallowedBuiltInTools.contains(tool))
            }
            XCTAssertTrue(configuration.processEnvironmentOverrides.isEmpty)
        }

        func testGEPAWorkerEnvironmentDoesNotInheritProviderCredentials() {
            let environment = PromptExperimentGEPAWorker.workerEnvironment(home: URL(fileURLWithPath: "/tmp/gepa-home"))
            XCTAssertEqual(Set(environment.keys).subtracting(["HOME", "PATH", "PYTHONUNBUFFERED", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]), [])
            XCTAssertNil(environment["OPENAI_API_KEY"])
            XCTAssertNil(environment["ANTHROPIC_API_KEY"])
            XCTAssertNil(environment["CODEX_HOME"])
        }

        private func makeHarness() -> Harness {
            let root = temporaryRoot()
            let store = PromptExperimentStore(rootURL: root)
            let runtime = FakeRuntime()
            let service = PromptExperimentService(
                store: store,
                runtime: runtime,
                resolveTarget: Self.fakeTarget,
                now: { Date(timeIntervalSince1970: 1000) }
            )
            return Harness(root: root, store: store, runtime: runtime, service: service)
        }

        private func preparedExperiment(
            _ harness: Harness,
            targetSelector: String = "explore"
        ) async throws -> UUID {
            await harness.service.load()
            let id = try await harness.service.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            let record = try XCTUnwrap(harness.service.record(id: id))
            var draft = try XCTUnwrap(record.draft)
            let currentDigest = try draft.contentDigest()
            draft.title = "Native pilot"
            draft.taskInput = "Identify the named value in the fixture."
            draft.syntheticFixture = "# Synthetic fixture\n\nThe named value is cobalt."
            draft.originalInstructions = "Read the fixture and report the named value."
            draft.candidateInstructions = "Inspect only the fixture, then report the named value with one sentence of evidence."
            draft.targetRole = targetSelector
            let updated = try await harness.service.updateDraft(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: currentDigest,
                draft: draft
            )
            _ = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: updated.id,
                expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            )
            return id
        }

        private func updatedOptimizationDraft(
            _ harness: Harness
        ) async throws -> (id: UUID, draft: PromptExperimentDraft) {
            await harness.service.load()
            let id = try await harness.service.createOptimizationExperiment(
                controllerSessionID: UUID(),
                sourceTabID: UUID()
            )
            var draft = try XCTUnwrap(harness.service.record(id: id)?.draft)
            let currentDigest = try draft.contentDigest()
            draft.title = "Real GEPA test"
            draft.optimization = Self.validOptimization()
            let updated = try await harness.service.updateDraft(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: currentDigest,
                draft: draft
            )
            return (id, updated)
        }

        private func preparedOptimizationExperiment(_ harness: Harness) async throws -> UUID {
            let (id, draft) = try await updatedOptimizationDraft(harness)
            _ = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: draft.contentDigest()
            )
            return id
        }

        private func approvedExperiment(_ harness: Harness) async throws -> UUID {
            let id = try await preparedExperiment(harness)
            let digest = try XCTUnwrap(harness.service.record(id: id)?.currentPlan?.digest)
            try await harness.service.approve(experimentID: id, displayedDigest: digest)
            return id
        }

        private func temporaryRoot() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("PromptExperimentServiceTests-\(UUID().uuidString)", isDirectory: true)
        }

        private static func fakeTarget(_ role: String) -> PromptExperimentResolvedTarget? {
            PromptExperimentResolvedTarget(
                role: role,
                agentRaw: "fake",
                modelRaw: "fake-model",
                displayName: "Fake Model"
            )
        }

        private static func validOptimization() -> PromptExperimentOptimizationSpecification {
            PromptExperimentOptimizationSpecification(
                seedCandidate: nil,
                objective: "Improve the instructions so the reviewed answer is extracted exactly.",
                background: "Operate only on the reviewed example data.",
                examples: [
                    PromptExperimentExample(
                        id: "reviewed-1",
                        split: .validation,
                        input: "The named value is cobalt.",
                        expectedOutput: "cobalt",
                        reviewerNotes: "Reviewed synthetic example"
                    )
                ],
                evaluator: PromptExperimentEvaluatorSpecification(
                    kind: .exactMatch,
                    rubric: "",
                    judgeTargetSelector: nil,
                    command: nil,
                    candidateFileName: nil,
                    minimumScore: 0,
                    maximumScore: 1
                ),
                execution: PromptExperimentExecutionSpecification(
                    adapter: .contextBuilder,
                    targetSelector: "executor",
                    instructions: "Use the candidate as governing instructions and answer the example input."
                ),
                gepa: PromptExperimentGEPAConfiguration(
                    engine: "gepa",
                    pythonExecutablePath: "/usr/bin/python3",
                    reflectionTargetSelector: "reflector",
                    maxEvaluations: 20,
                    maxWallClockSeconds: 120,
                    stopAtScore: 1,
                    randomSeed: 0
                )
            )
        }

        private static func validDraft(date: Date, repetitions: Int) -> PromptExperimentDraft {
            PromptExperimentDraft(
                revision: 1,
                title: "Deterministic",
                taskInput: "Task",
                syntheticFixture: "Fixture",
                originalInstructions: "Original",
                candidateInstructions: "Candidate",
                targetRole: "explore",
                repetitions: repetitions,
                createdAt: date,
                updatedAt: date
            )
        }
    }
#endif
