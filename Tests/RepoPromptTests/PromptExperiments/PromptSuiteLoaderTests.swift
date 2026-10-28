import Foundation
@testable import RepoPromptApp
import XCTest

final class PromptSuiteLoaderTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    // MARK: Checked-in suites

    func testCheckedInOraclePlanSuiteLoads() throws {
        let suite = try PromptSuiteLoader.load(promptID: .oraclePlan)
        XCTAssertEqual(suite.suiteID, "oracle-plan-v1")
        XCTAssertEqual(suite.promptID, .oraclePlan)
        XCTAssertEqual(suite.promptVariant, .builtIn)
        XCTAssertEqual(suite.grader.kind, .modelJudge)
        XCTAssertEqual(suite.grader.scoreRange, PromptSuiteScoreRange(min: 0, max: 1))
        XCTAssertEqual(suite.grader.rubric?.fileName, "rubric.md")
        XCTAssertEqual(suite.grader.rubric?.sha256.count, 64)
        XCTAssertEqual(suite.suiteSHA256.count, 64)
        XCTAssertEqual(suite.cases(in: .training).count, 6)
        XCTAssertEqual(suite.cases(in: .validation).count, 3)
        XCTAssertEqual(suite.cases(in: .hiddenTest).count, 3)
        XCTAssertEqual(Set(suite.cases.map(\.id)).count, 12)
        XCTAssertTrue(suite.cases.allSatisfy { $0.context?.fileTree != nil && !($0.context?.files.isEmpty ?? true) })
        XCTAssertFalse(suite.cases.contains { $0.input.contains("Frozen context") }, "context travels as packaged files, not prose")
    }

    func testCaseContextLoadsAndRejectsUnknownOrInvalidFileEntries() throws {
        let withContext = #"{"id": "train-1", "split": "training", "input": "q1", "expected_output": "A", "file_tree": "root\n└── a.swift", "files": [{"path": "a.swift", "content": "let a = 1"}]}"#
        let suite = try load(suiteJSON(cases: [withContext, validationCase]))
        XCTAssertEqual(
            suite.cases.first?.context,
            PromptSuiteCaseContext(fileTree: "root\n└── a.swift", files: [PromptSuiteContextFile(path: "a.swift", content: "let a = 1")])
        )
        XCTAssertNil(suite.cases.last?.context)

        assertRejects(
            suiteJSON(cases: [
                #"{"id": "t", "split": "training", "input": "q", "expected_output": "A", "files": [{"path": "a", "content": "x", "lines": "1-2"}]}"#,
                validationCase
            ]),
            .unknownFields(path: "cases.[0].files.[0]", fields: ["lines"])
        )
        assertRejects(
            suiteJSON(cases: [
                #"{"id": "t", "split": "training", "input": "q", "expected_output": "A", "files": [{"path": "a", "content": "x"}, {"path": "a", "content": "y"}]}"#,
                validationCase
            ]),
            .invalidContextFile(caseID: "t", path: "a")
        )
        assertRejects(
            suiteJSON(cases: [
                #"{"id": "t", "split": "training", "input": "q", "expected_output": "A", "files": [{"path": " ", "content": "x"}]}"#,
                validationCase
            ]),
            .invalidContextFile(caseID: "t", path: " ")
        )
    }

    func testEveryCheckedInSuiteValidates() throws {
        for id in BuiltInPromptID.allCases {
            let directory = try AppDomainRuntimeComposition.shared.builtInPromptRegistry.directory(for: id)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(PromptSuite.fileName).path) else {
                continue
            }
            XCTAssertNoThrow(try PromptSuiteLoader.load(promptID: id), id.rawValue)
        }
    }

    // MARK: Valid shapes

    func testExactMatchSuiteLoadsAndHashesBytes() throws {
        let json = suiteJSON()
        let suite = try load(json)
        XCTAssertEqual(suite.grader, PromptSuiteGrader(kind: .exactMatch, scoreRange: .init(min: 0, max: 1), rubric: nil))
        XCTAssertEqual(suite.cases.map(\.id), ["train-1", "val-1"])
        XCTAssertEqual(suite.cases.first?.expectedOutput, "A")
        XCTAssertEqual(suite.suiteSHA256, BuiltInPromptRegistry.sha256Hex(Data(json.utf8)))
    }

    // MARK: Rejections

    func testRejectsUnsupportedSchemaVersionBeforeFieldChecks() {
        assertRejects(suiteJSON(schemaVersion: 2, extraRoot: #", "future": true"#), .unsupportedSchemaVersion(2))
    }

    func testRejectsUnknownFieldsAtEveryLevel() {
        assertRejects(suiteJSON(extraRoot: #", "notes": "x""#), .unknownFields(path: "<root>", fields: ["notes"]))
        assertRejects(
            suiteJSON(grader: #"{"kind": "exact_match", "score_range": {"min": 0, "max": 1}, "weight": 2}"#),
            .unknownFields(path: "grader", fields: ["weight"])
        )
        assertRejects(
            suiteJSON(grader: #"{"kind": "exact_match", "score_range": {"min": 0, "max": 1, "step": 0.5}}"#),
            .unknownFields(path: "grader.score_range", fields: ["step"])
        )
        assertRejects(
            suiteJSON(cases: [
                #"{"id": "train-1", "split": "training", "input": "q", "expected_output": "A", "tags": []}"#,
                validationCase
            ]),
            .unknownFields(path: "cases.[0]", fields: ["tags"])
        )
    }

    func testRejectsMalformedJSONAndMissingFields() {
        assertRejects("{", nil)
        assertRejects(#"{"schema_version": 1}"#, nil)
    }

    func testRejectsPromptIdentityProblems() {
        assertRejects(suiteJSON(promptID: "oracle-unknown"), .unknownPromptID("oracle-unknown"))
        assertRejects(suiteJSON(promptID: "oracle-review"), .promptIDMismatch(expected: .oraclePlan, actual: .oracleReview))
        assertRejects(suiteJSON(promptVariant: "user_edited"), .unsupportedPromptVariant("user_edited"))
        assertRejects(suiteJSON(suiteID: "bad id"), .invalidIdentifier(field: "suite_id", value: "bad id"))
    }

    func testRejectsCaseProblems() {
        assertRejects(suiteJSON(cases: []), .noCases)
        assertRejects(suiteJSON(cases: [trainingCase, trainingCase, validationCase]), .duplicateCaseID("train-1"))
        assertRejects(
            suiteJSON(cases: [#"{"id": "", "split": "training", "input": "q", "expected_output": "A"}"#, validationCase]),
            .invalidIdentifier(field: "case id", value: "")
        )
        assertRejects(
            suiteJSON(cases: [#"{"id": "t", "split": "test", "input": "q", "expected_output": "A"}"#, validationCase]),
            .unknownSplit(caseID: "t", value: "test")
        )
        assertRejects(
            suiteJSON(cases: [#"{"id": "t", "split": "training", "input": "  ", "expected_output": "A"}"#, validationCase]),
            .emptyInput(caseID: "t")
        )
        assertRejects(
            suiteJSON(cases: [#"{"id": "t", "split": "training", "input": "q"}"#, validationCase]),
            .missingExpectedOutput(caseID: "t")
        )
    }

    func testRejectsEmptyDevelopmentSplits() {
        assertRejects(suiteJSON(cases: [validationCase, hiddenCase]), .emptyDevelopmentSplit(.training))
        assertRejects(suiteJSON(cases: [trainingCase, hiddenCase]), .emptyDevelopmentSplit(.validation))
    }

    func testRejectsGraderProblems() {
        assertRejects(
            suiteJSON(grader: #"{"kind": "vibes", "score_range": {"min": 0, "max": 1}}"#),
            .unknownGraderKind("vibes")
        )
        assertRejects(
            suiteJSON(grader: #"{"kind": "exact_match", "score_range": {"min": 1, "max": 1}}"#),
            .invalidScoreRange(min: 1, max: 1)
        )
        assertRejects(
            suiteJSON(grader: #"{"kind": "exact_match", "score_range": {"min": 2, "max": 0}}"#),
            .invalidScoreRange(min: 2, max: 0)
        )
        assertRejects(
            suiteJSON(grader: #"{"kind": "exact_match", "score_range": {"min": 0, "max": 1}, "rubric": "rubric.md"}"#),
            .unexpectedRubric
        )
        assertRejects(
            suiteJSON(grader: #"{"kind": "model_judge", "score_range": {"min": 0, "max": 1}}"#),
            .missingRubric
        )
    }

    func testRejectsRubricReferenceProblems() throws {
        for reference in ["../rubric.md", "nested/rubric.md", ".hidden", "suite.json", "prompt.md"] {
            assertRejects(judgeSuite(rubric: reference), .invalidRubricReference(reference))
        }
        assertRejects(judgeSuite(rubric: "missing.md"), .rubricUnreadable("missing.md"))
        assertRejects(judgeSuite(rubric: "empty.md"), .emptyRubric("empty.md"), files: ["empty.md": " \n"])

        let outside = try makeTemporaryRoot().appendingPathComponent("outside.md")
        try Data("outside rubric".utf8).write(to: outside)
        assertRejects(judgeSuite(rubric: "linked.md"), .rubricUnreadable("linked.md"), symlinks: ["linked.md": outside])

        let checklist = "Judge it.\n\n- `answers` (weight 2): Does it answer?\n- `short` (weight 1, host: no_code_patch max_block_lines=10): No patches.\n"
        let suite = try load(judgeSuite(rubric: "rubric.md"), files: ["rubric.md": checklist])
        XCTAssertEqual(suite.grader.rubric?.text, checklist)
        XCTAssertEqual(suite.grader.rubric?.sha256, BuiltInPromptRegistry.sha256Hex(Data(checklist.utf8)))
        XCTAssertEqual(suite.grader.rubric?.checks, [
            PromptSuiteRubricCheck(id: "answers", weight: 2, text: "Does it answer?", evaluator: .judge),
            PromptSuiteRubricCheck(id: "short", weight: 1, text: "No patches.", evaluator: .host(.noCodePatch(maxBlockLines: 10)))
        ])
        XCTAssertEqual(suite.grader.rubric?.guidance, "Judge it.")
    }

    func testHolisticOrMalformedChecklistRubricsAreRejected() {
        func assertChecklistRejected(_ text: String, _ detail: String) {
            assertRejects(
                judgeSuite(rubric: "rubric.md"),
                .invalidRubricChecklist(file: "rubric.md", detail: detail),
                files: ["rubric.md": text]
            )
        }
        assertChecklistRejected("Score it 0-10 holistically.", "no checks")
        assertChecklistRejected("- `a` (weight 0): zero weight?", "malformed check line '- `a` (weight 0): zero weight?'")
        assertChecklistRejected("- `a` (weight 1): one?\n- `a` (weight 2): again?", "duplicate check id 'a'")
        assertChecklistRejected("- `a` (weight 1, host: telepathy): mind reading", "unsupported host check 'telepathy'")
        assertChecklistRejected("- `a` (weight 1, host: required_sections): no sections", "unsupported host check 'required_sections needs sections='")
    }

    func testCheckedInOraclePlanRubricIsAWeightedChecklistWithHostChecks() throws {
        let rubric = try XCTUnwrap(PromptSuiteLoader.load(promptID: .oraclePlan).grader.rubric)
        XCTAssertEqual(rubric.checks.count, 13)
        XCTAssertEqual(rubric.checks.reduce(0) { $0 + $1.weight }, 25)
        let hosts = rubric.checks.compactMap { check -> PromptSuiteHostCheck? in
            if case let .host(kind) = check.evaluator { return kind }
            return nil
        }
        XCTAssertEqual(hosts, [
            .requiredSections(["Summary", "Current-state analysis", "Design", "File-by-file impact", "Implementation order"]),
            .noCodePatch(maxBlockLines: 25),
            .pathsInContext
        ])
        XCTAssertFalse(rubric.guidance.contains("(weight"), "check lines are not repeated as guidance")
    }

    func testMissingSuiteFileIsUnreadable() throws {
        let root = try makeTemporaryRoot()
        let registry = BuiltInPromptRegistry(promptsDirectory: root)
        let path = root.appendingPathComponent("oracle-plan/suite.json").path
        XCTAssertThrowsError(try PromptSuiteLoader.load(promptID: .oraclePlan, registry: registry)) {
            XCTAssertEqual($0 as? PromptSuiteValidationError, .suiteUnreadable(path: path))
        }
    }

    // MARK: Fixtures

    private let trainingCase = #"{"id": "train-1", "split": "training", "input": "q1", "expected_output": "A"}"#
    private let validationCase = #"{"id": "val-1", "split": "validation", "input": "q2", "expected_output": "B"}"#
    private let hiddenCase = #"{"id": "hidden-1", "split": "hidden_test", "input": "q3", "expected_output": "C"}"#

    private func suiteJSON(
        schemaVersion: Int = 1,
        suiteID: String = "unit-suite",
        promptID: String = "oracle-plan",
        promptVariant: String = "built_in",
        grader: String = #"{"kind": "exact_match", "score_range": {"min": 0, "max": 1}}"#,
        cases: [String]? = nil,
        extraRoot: String = ""
    ) -> String {
        let caseList = (cases ?? [trainingCase, validationCase]).joined(separator: ", ")
        return """
        {"schema_version": \(schemaVersion), "suite_id": "\(suiteID)", "prompt_id": "\(promptID)", \
        "prompt_variant": "\(promptVariant)", "grader": \(grader), "cases": [\(caseList)]\(extraRoot)}
        """
    }

    private func judgeSuite(rubric: String) -> String {
        suiteJSON(
            grader: #"{"kind": "model_judge", "score_range": {"min": 0, "max": 10}, "rubric": "\#(rubric)"}"#,
            cases: [
                #"{"id": "train-1", "split": "training", "input": "q1"}"#,
                #"{"id": "val-1", "split": "validation", "input": "q2", "expected_output": "reference"}"#
            ]
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func load(
        _ json: String,
        files: [String: String] = [:],
        symlinks: [String: URL] = [:]
    ) throws -> PromptSuite {
        let root = try makeTemporaryRoot()
        let directory = root.appendingPathComponent(BuiltInPromptID.oraclePlan.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent(PromptSuite.fileName))
        for (name, content) in files {
            try Data(content.utf8).write(to: directory.appendingPathComponent(name))
        }
        for (name, destination) in symlinks {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: destination)
        }
        return try PromptSuiteLoader.load(promptID: .oraclePlan, registry: BuiltInPromptRegistry(promptsDirectory: root))
    }

    /// Asserts the suite is rejected. A nil `expected` accepts any `malformedJSON` detail.
    private func assertRejects(
        _ json: String,
        _ expected: PromptSuiteValidationError?,
        files: [String: String] = [:],
        symlinks: [String: URL] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try load(json, files: files, symlinks: symlinks), file: file, line: line) { error in
            guard let error = error as? PromptSuiteValidationError else {
                return XCTFail("Unexpected error \(error)", file: file, line: line)
            }
            if let expected {
                XCTAssertEqual(error, expected, file: file, line: line)
            } else if case .malformedJSON = error {
                // Expected.
            } else {
                XCTFail("Expected malformedJSON, got \(error)", file: file, line: line)
            }
        }
    }
}
