import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentServiceTests: XCTestCase {
        private final class FakeRuntime: PromptExperimentRuntime {
            var submitted: [PromptExperimentRunRequest] = []
            var cancelled: [PromptExperimentRuntimeHandle] = []
            var immediateResults: [Int: PromptExperimentRuntimeResult] = [:]
            var submissionErrors: [Int: PromptExperimentSubmissionError] = [:]
            var holdResults = false
            var holdSubmission = false
            private var submissionGate: CheckedContinuation<Void, Never>?
            private var blockedSubmissionWaiters: [CheckedContinuation<Void, Never>] = []
            private var resultContinuations: [UUID: CheckedContinuation<PromptExperimentRuntimeResult, Never>] = [:]
            private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
            private var resultWaiters: [CheckedContinuation<Void, Never>] = []

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
                fixtureDigest: String = "fixture"
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
                    output: output,
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
            XCTAssertNotNil(record.attempts.first?.evidence)
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
            XCTAssertNotNil(record.attempts.first?.evidence)
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
                    repetitions: 1
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
            XCTAssertNil(PromptExperimentAgentOperation(rawValue: "approve"))
            XCTAssertNil(PromptExperimentAgentOperation(rawValue: "run"))

            let plan = try XCTUnwrap(sealed.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            XCTAssertEqual(harness.service.record(id: id)?.phase, .approved)
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
            XCTAssertTrue(firstAttempts.allSatisfy { $0.evidence != nil })

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
            XCTAssertTrue(record.attempts(for: firstPlan).allSatisfy { $0.evidence != nil })
            XCTAssertTrue(record.attempts(for: secondPlan).allSatisfy { $0.evidence != nil })
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

        private func preparedExperiment(_ harness: Harness) async throws -> UUID {
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
