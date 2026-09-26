import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class BudgetLedgerTests: XCTestCase {
        private var roots: [URL] = []

        override func tearDown() async throws {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
            roots = []
            try await super.tearDown()
        }

        private func makeDirectory() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots.append(root)
            return root
        }

        private func open(
            _ directory: URL,
            cap: Int = 3,
            reserve: Int = 2,
            calibration: Int = 0,
            digest: String = "digest"
        ) throws -> PromptExperimentBudgetLedger {
            try PromptExperimentBudgetLedger.open(
                directory: directory,
                authorityDigest: digest,
                totalCap: cap,
                heldOutReserve: reserve,
                calibrationReserve: calibration,
                gepaStateURL: directory.appendingPathComponent("gepa-run/gepa_state.bin"),
                now: { Date(timeIntervalSince1970: 1000) }
            )
        }

        private let outcome = PromptExperimentBudgetLedger.Outcome(
            score: 1, proposerFeedback: "ok", outputExcerpt: "answer", failureKind: nil
        )

        func testAdmissionsAreDurableReplayableAndNeverRefunded() throws {
            let directory = try makeDirectory()
            let ledger = try open(directory, cap: 4)
            guard case let .admitted(first) = try ledger.admit(candidateSHA256: "a", exampleID: "t1", split: .training) else {
                return XCTFail("Expected an admission")
            }
            XCTAssertThrowsError(try ledger.admit(candidateSHA256: "a", exampleID: "t1", split: .training)) {
                XCTAssertEqual($0 as? PromptExperimentBudgetLedger.LedgerError, .duplicateInFlight)
            }
            try ledger.settle(first.evaluationID, outcome: outcome)
            XCTAssertEqual(
                try ledger.admit(candidateSHA256: "a", exampleID: "t1", split: .training),
                .recorded(PromptExperimentBudgetLedger.Entry(
                    evaluationID: first.evaluationID, logicalKey: first.logicalKey, pool: .search, exampleID: "t1",
                    split: .training, candidateSHA256: "a", replicate: 0, admittedAt: first.admittedAt, state: .completed, outcome: outcome
                ))
            )

            guard case let .admitted(failed) = try ledger.admit(candidateSHA256: "b", exampleID: "t1", split: .training) else {
                return XCTFail("Expected an admission")
            }
            try ledger.settle(failed.evaluationID, outcome: nil)
            // A failed evaluation was spent; retrying it takes a new admission.
            XCTAssertEqual(try ledger.admit(candidateSHA256: "b", exampleID: "t1", split: .training), .exhausted(.search))
            XCTAssertEqual(ledger.admittedCount(in: .search), 2)

            let reopened = try open(directory, cap: 4)
            XCTAssertEqual(reopened.document, ledger.document)
            XCTAssertEqual(reopened.totalAdmitted, 2)
        }

        func testSearchAndHeldOutPoolsCannotStarveEachOther() throws {
            let ledger = try open(makeDirectory(), cap: 3, reserve: 2)
            XCTAssertEqual(ledger.searchCap, 1)
            guard case let .admitted(search) = try ledger.admit(candidateSHA256: "a", exampleID: "t1", split: .training) else {
                return XCTFail("Expected a search admission")
            }
            try ledger.settle(search.evaluationID, outcome: outcome)
            XCTAssertEqual(try ledger.admit(candidateSHA256: "b", exampleID: "t1", split: .training), .exhausted(.search))
            for candidate in ["a", "b"] {
                guard case let .admitted(entry) = try ledger.admit(candidateSHA256: candidate, exampleID: "h1", split: .hiddenTest) else {
                    return XCTFail("Held-out reserve must remain available")
                }
                XCTAssertEqual(entry.pool, .heldOut)
                try ledger.settle(entry.evaluationID, outcome: outcome)
            }
            XCTAssertEqual(try ledger.admit(candidateSHA256: "c", exampleID: "h1", split: .hiddenTest), .exhausted(.heldOut))
            XCTAssertEqual(ledger.totalAdmitted, 3)
        }

        func testReopeningSettlesAnInterruptedAdmissionAsSpent() throws {
            let directory = try makeDirectory()
            let ledger = try open(directory, cap: 4)
            _ = try ledger.admit(candidateSHA256: "a", exampleID: "t1", split: .training)
            let resumed = try open(directory, cap: 4)
            XCTAssertEqual(resumed.interruptedSettledOnOpen, 1)
            XCTAssertEqual(resumed.document.entries.map(\.state), [.interrupted])
            XCTAssertEqual(resumed.totalAdmitted, 1, "an interrupted admission is never refunded")
            guard case .admitted = try resumed.admit(candidateSHA256: "a", exampleID: "t1", split: .training) else {
                return XCTFail("Re-evaluating the interrupted case takes a new admission")
            }
            XCTAssertEqual(resumed.totalAdmitted, 2)
            XCTAssertEqual(PromptExperimentBudgetLedger.peekCappedAdmitted(directory: directory), 2)
            XCTAssertEqual(try open(directory, cap: 4).interruptedSettledOnOpen, 1, "the new admission was itself left unsettled")
        }

        func testGEPACheckpointWithoutLedgerAndAuthorityDriftAreRefused() throws {
            let orphan = try makeDirectory()
            let state = orphan.appendingPathComponent("gepa-run/gepa_state.bin")
            try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("state".utf8).write(to: state)
            XCTAssertThrowsError(try open(orphan)) {
                XCTAssertEqual($0 as? PromptExperimentBudgetLedger.LedgerError, .checkpointWithoutLedger)
            }

            let directory = try makeDirectory()
            _ = try open(directory, cap: 3)
            XCTAssertThrowsError(try open(directory, cap: 4)) {
                XCTAssertEqual($0 as? PromptExperimentBudgetLedger.LedgerError, .authorityMismatch)
            }
            XCTAssertThrowsError(try open(directory, digest: "other")) {
                XCTAssertEqual($0 as? PromptExperimentBudgetLedger.LedgerError, .authorityMismatch)
            }
            XCTAssertThrowsError(try open(directory, cap: 3, calibration: 1)) {
                XCTAssertEqual($0 as? PromptExperimentBudgetLedger.LedgerError, .authorityMismatch)
            }
        }

        func testCalibrationIsASeparateLineAndItsHeldOutScoresReplayForTheSearch() throws {
            let directory = try makeDirectory()
            let ledger = try open(directory, cap: 2, reserve: 1, calibration: 1)
            guard case let .admitted(calibrated) = try ledger.admit(
                candidateSHA256: "seed", exampleID: "h1", split: .hiddenTest, pool: .calibration
            ) else { return XCTFail("Calibration admits on its own line") }
            XCTAssertEqual(calibrated.pool, .calibration)
            try ledger.settle(calibrated.evaluationID, outcome: outcome)
            XCTAssertEqual(ledger.calibrationAdmitted, 1)
            XCTAssertEqual(ledger.cappedAdmitted, 0, "calibration never consumes the approved search cap")
            XCTAssertEqual(ledger.remaining(in: .heldOut), 1)
            guard case let .recorded(entry) = try ledger.admit(candidateSHA256: "seed", exampleID: "h1", split: .hiddenTest) else {
                return XCTFail("The seed's calibrated held-out score replays for the held-out pass")
            }
            XCTAssertEqual(entry.evaluationID, calibrated.evaluationID)
            XCTAssertEqual(try ledger.admit(candidateSHA256: "x", exampleID: "h1", split: .hiddenTest, pool: .calibration), .exhausted(.calibration))
            XCTAssertEqual(PromptExperimentBudgetLedger.peekCappedAdmitted(directory: directory), 0)
        }

        func testReplicatesAreDistinctLogicalEvaluationsAndUsageSurvivesReopen() throws {
            let directory = try makeDirectory()
            let ledger = try open(directory, cap: 3, reserve: 0)
            let usage = PromptExperimentEvaluationUsage(promptCharacters: 10, outputCharacters: 42, promptTokens: 7, completionTokens: nil)
            var withUsage = outcome
            withUsage.usage = usage
            for replicate in 0 ... 2 {
                guard case let .admitted(entry) = try ledger.admit(
                    candidateSHA256: "seed", exampleID: "v1", split: .validation, replicate: replicate
                ) else { return XCTFail("Replicate \(replicate) must be a new admission") }
                XCTAssertEqual(entry.replicate, replicate)
                try ledger.settle(entry.evaluationID, outcome: withUsage)
            }
            XCTAssertEqual(ledger.remaining(in: .search), 0)
            XCTAssertEqual(Set(ledger.document.entries.map(\.logicalKey)).count, 3)
            XCTAssertEqual(
                PromptExperimentBudgetLedger.logicalKey(candidateSHA256: "seed", split: .validation, exampleID: "v1"),
                ledger.document.entries[0].logicalKey,
                "replicate 0 keeps the historical key"
            )
            XCTAssertEqual(try open(directory, cap: 3, reserve: 0).document.entries.map { $0.outcome?.usage }, [usage, usage, usage])
        }

        func testMinimumApprovableBudgetCoversSeedPassOneMutationCycleAndReserve() {
            func example(_ id: String, _ split: PromptExperimentDatasetSplit) -> PromptSuiteCase {
                PromptSuiteCase(id: id, split: split, input: id, expectedOutput: nil)
            }
            // 3 training, 2 validation, minibatch 2: seed pass 2 + parent 2 + child 2 + child pass 2 = 8.
            let examples = [
                example("t1", .training),
                example("t2", .training),
                example("t3", .training),
                example("v1", .validation),
                example("v2", .validation)
            ]
            XCTAssertEqual(PromptExperimentBudgetLedger.minimumApprovableEvaluations(cases: examples, reflectionMinibatchSize: 2), 8)
            // Validation-only suites train and validate on the same examples; hidden adds 1 each
            // (the seed's held-out baseline is calibration, not reserve).
            let validationOnly = [example("v1", .validation), example("v2", .validation), example("h1", .hiddenTest)]
            XCTAssertEqual(PromptExperimentBudgetLedger.minimumApprovableEvaluations(cases: validationOnly, reflectionMinibatchSize: 3), 9)
            XCTAssertEqual(PromptExperimentBudgetLedger.calibrationEvaluations(cases: validationOnly), 1)
        }

        /// oracle-plan-v1's shape (6 training, 3 validation, 3 held out) at the default minibatch 2:
        /// 25 − 3 reserve − 3 seed pass = 19; a rejected proposal costs 4, an accepted one 7, and
        /// no iteration starts with fewer than 7 left.
        func testExpectedProposalsForTheOraclePlanShapeAtTwentyFive() {
            func example(_ id: String, _ split: PromptExperimentDatasetSplit) -> PromptSuiteCase {
                PromptSuiteCase(id: id, split: split, input: id, expectedOutput: nil)
            }
            let cases = (1 ... 6).map { example("t\($0)", .training) }
                + (1 ... 3).map { example("v\($0)", .validation) }
                + (1 ... 3).map { example("h\($0)", .hiddenTest) }
            XCTAssertEqual(PromptExperimentBudgetLedger.minimumApprovableEvaluations(cases: cases, reflectionMinibatchSize: 2), 13)
            XCTAssertEqual(PromptExperimentBudgetLedger.searchShape(cases: cases, reflectionMinibatchSize: 2).iterationCost, 7)
            XCTAssertEqual(PromptExperimentBudgetLedger.expectedProposals(cap: 25, cases: cases, reflectionMinibatchSize: 2), 4)
            XCTAssertEqual(PromptExperimentBudgetLedger.expectedProposals(cap: 25, cases: cases, reflectionMinibatchSize: 2, acceptedProposals: 1), 3)
            XCTAssertEqual(PromptExperimentBudgetLedger.expectedProposals(cap: 25, cases: cases, reflectionMinibatchSize: 3), 2, "the old minibatch 3 affords only two")
        }
    }
#endif
