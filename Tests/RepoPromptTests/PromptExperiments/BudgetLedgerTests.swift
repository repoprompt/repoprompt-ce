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

        private func open(_ directory: URL, cap: Int = 3, reserve: Int = 2, digest: String = "digest") throws -> PromptExperimentBudgetLedger {
            try PromptExperimentBudgetLedger.open(
                directory: directory,
                authorityDigest: digest,
                totalCap: cap,
                heldOutReserve: reserve,
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
                    split: .training, candidateSHA256: "a", admittedAt: first.admittedAt, state: .completed, outcome: outcome
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
            XCTAssertEqual(PromptExperimentBudgetLedger.peekTotalAdmitted(directory: directory), 2)
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
            // Validation-only suites train and validate on the same examples; hidden adds 2 each.
            let validationOnly = [example("v1", .validation), example("v2", .validation), example("h1", .hiddenTest)]
            XCTAssertEqual(PromptExperimentBudgetLedger.minimumApprovableEvaluations(cases: validationOnly, reflectionMinibatchSize: 3), 10)
        }
    }
#endif
