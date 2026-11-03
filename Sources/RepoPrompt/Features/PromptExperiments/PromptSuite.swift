import Foundation

// MARK: - Model

/// Split a suite case belongs to. `training` and `validation` form the development set the
/// optimizer may learn from; `hidden_test` is held out from reflection.
enum PromptSuiteSplit: String, CaseIterable, Codable {
    case training
    case validation
    case hiddenTest = "hidden_test"
}

/// Whether the suite comes from a bundled prompt resource or a frozen lab definition.
enum PromptSuitePromptVariant: String, CaseIterable {
    case builtIn = "built_in"
    case project
}

enum PromptSuiteGraderKind: String, CaseIterable {
    /// Score `max` when the output equals the case's `expected_output`, else `min`.
    case exactMatch = "exact_match"
    /// A judge model scores the output against the suite rubric within `score_range`.
    case modelJudge = "model_judge"
    case external
}

struct PromptSuiteScoreRange: Equatable {
    let min: Double
    let max: Double
}

struct PromptSuiteRubric: Equatable {
    /// Sibling file name inside the prompt's resource directory.
    let fileName: String
    let text: String
    let sha256: String
    /// Weighted binary checks parsed from `text` (judge- or host-evaluated).
    var checks: [PromptSuiteRubricCheck] = []
    /// The rubric's free-text guidance for the judge (everything except the check lines).
    var guidance: String = ""

    /// A rubric whose checklist was parsed from `text`; throws for a malformed checklist.
    static func checklist(fileName: String, text: String, sha256: String) throws -> Self {
        let parsed = try PromptSuiteChecklistParser.parse(text)
        return Self(fileName: fileName, text: text, sha256: sha256, checks: parsed.checks, guidance: parsed.guidance)
    }
}

struct PromptSuiteGrader: Equatable {
    let kind: PromptSuiteGraderKind
    let scoreRange: PromptSuiteScoreRange
    /// Present exactly when `kind == .modelJudge`.
    let rubric: PromptSuiteRubric?
}

/// One file of a case's frozen context, packaged like a selected file in production.
struct PromptSuiteContextFile: Codable, Equatable {
    let path: String
    let content: String
}

/// Frozen workspace context for a case. Evaluation packages it with the case input exactly
/// like a production Oracle request (file map, file contents, `<user_instructions>`).
struct PromptSuiteCaseContext: Codable, Equatable {
    let fileTree: String?
    let files: [PromptSuiteContextFile]
}

struct PromptSuiteCase: Codable, Equatable {
    let id: String
    let split: PromptSuiteSplit
    /// The user's instructions for this case (the `<user_instructions>` body).
    let input: String
    /// Required for `exact_match`; optional reference answer for `model_judge`.
    let expectedOutput: String?
    /// Optional frozen file tree and file contents sent alongside `input`.
    var context: PromptSuiteCaseContext?
    var variables: [String: String] = [:]
    var payload: [String: PromptExperimentExampleValue]?
}

extension PromptSuiteCase {
    private enum CodingKeys: String, CodingKey { case id, split, input, expectedOutput, context, variables, payload }
    private enum LegacyCodingKeys: String, CodingKey { case expectedOutput = "expected_output" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        split = try values.decode(PromptSuiteSplit.self, forKey: .split)
        input = try values.decode(String.self, forKey: .input)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        expectedOutput = try values.decodeIfPresent(String.self, forKey: .expectedOutput)
            ?? legacy.decodeIfPresent(String.self, forKey: .expectedOutput)
        context = try values.decodeIfPresent(PromptSuiteCaseContext.self, forKey: .context)
        variables = try values.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
        payload = try values.decodeIfPresent([String: PromptExperimentExampleValue].self, forKey: .payload)
    }
}

/// A validated evaluation suite for a built-in prompt or project task.
struct PromptSuite: Equatable {
    static let schemaVersion = 1
    static let fileName = "suite.json"

    let suiteID: String
    let promptID: BuiltInPromptID?
    let promptVariant: PromptSuitePromptVariant
    let grader: PromptSuiteGrader
    let cases: [PromptSuiteCase]
    /// Lowercase hex SHA-256 of the `suite.json` bytes.
    let suiteSHA256: String

    func cases(in split: PromptSuiteSplit) -> [PromptSuiteCase] {
        cases.filter { $0.split == split }
    }
}

// MARK: - Errors

enum PromptSuiteValidationError: Error, Equatable, LocalizedError {
    case suiteUnreadable(path: String)
    case malformedJSON(String)
    case unsupportedSchemaVersion(Int)
    case unknownFields(path: String, fields: [String])
    case unknownPromptID(String)
    case promptIDMismatch(expected: BuiltInPromptID, actual: BuiltInPromptID)
    case unsupportedPromptVariant(String)
    case invalidIdentifier(field: String, value: String)
    case unknownGraderKind(String)
    case invalidScoreRange(min: Double, max: Double)
    case missingRubric
    case unexpectedRubric
    case invalidRubricReference(String)
    case rubricUnreadable(String)
    case emptyRubric(String)
    case invalidRubricChecklist(file: String, detail: String)
    case noCases
    case duplicateCaseID(String)
    case unknownSplit(caseID: String, value: String)
    case emptyInput(caseID: String)
    case invalidContextFile(caseID: String, path: String)
    case missingExpectedOutput(caseID: String)
    case emptyDevelopmentSplit(PromptSuiteSplit)

    var errorDescription: String? {
        switch self {
        case let .suiteUnreadable(path): "Suite file could not be read at \(path)."
        case let .malformedJSON(detail): "Suite JSON is malformed: \(detail)"
        case let .unsupportedSchemaVersion(version): "Suite schema_version \(version) is unsupported; expected \(PromptSuite.schemaVersion)."
        case let .unknownFields(path, fields): "Unknown suite field(s) at \(path): \(fields.joined(separator: ", "))."
        case let .unknownPromptID(value): "Unknown prompt_id '\(value)'."
        case let .promptIDMismatch(expected, actual): "Suite prompt_id '\(actual.rawValue)' does not match its directory '\(expected.rawValue)'."
        case let .unsupportedPromptVariant(value): "Unsupported prompt_variant '\(value)'."
        case let .invalidIdentifier(field, value): "Invalid \(field) '\(value)'; use 1-128 characters from [A-Za-z0-9._-]."
        case let .unknownGraderKind(value): "Unknown grader kind '\(value)'."
        case let .invalidScoreRange(min, max): "Invalid score_range [\(min), \(max)]; min must be finite and less than max."
        case .missingRubric: "A model_judge grader requires a rubric file."
        case .unexpectedRubric: "An exact_match grader must not declare a rubric."
        case let .invalidRubricReference(value): "Rubric reference '\(value)' must be a plain sibling file name."
        case let .rubricUnreadable(value): "Rubric '\(value)' could not be read as a regular UTF-8 file."
        case let .emptyRubric(value): "Rubric '\(value)' is empty."
        case let .invalidRubricChecklist(file, detail): "Rubric '\(file)' is not a valid weighted checklist: \(detail). Use lines like - `id` (weight 2): question, or - `id` (weight 1, host: required_sections sections=A|B): description."
        case .noCases: "Suite has no cases."
        case let .duplicateCaseID(id): "Duplicate case id '\(id)'."
        case let .unknownSplit(caseID, value): "Case '\(caseID)' has unknown split '\(value)'."
        case let .emptyInput(caseID): "Case '\(caseID)' has an empty input."
        case let .invalidContextFile(caseID, path): "Case '\(caseID)' has an empty or duplicate context file path '\(path)'."
        case let .missingExpectedOutput(caseID): "Case '\(caseID)' requires expected_output for exact_match grading."
        case let .emptyDevelopmentSplit(split): "Suite has no \(split.rawValue) cases."
        }
    }
}

// MARK: - Loader

/// Loads and validates `AppResources/Prompts/<prompt-id>/suite.json`.
///
/// Validation is complete before any caller can spend a model call: every structural,
/// referential and range error is reported as a `PromptSuiteValidationError`.
enum PromptSuiteLoader {
    static func load(
        promptID: BuiltInPromptID,
        registry: BuiltInPromptRegistry = AppDomainRuntimeComposition.shared.builtInPromptRegistry
    ) throws -> PromptSuite {
        let directory = try registry.directory(for: promptID)
        let url = directory.appendingPathComponent(PromptSuite.fileName)
        guard isRegularFile(url), let data = try? Data(contentsOf: url) else {
            throw PromptSuiteValidationError.suiteUnreadable(path: url.path)
        }
        return try decode(data, promptID: promptID, directory: directory)
    }

    static func decode(_ data: Data, promptID: BuiltInPromptID, directory: URL) throws -> PromptSuite {
        let document: SuiteDocument
        do {
            document = try JSONDecoder().decode(SuiteDocument.self, from: data)
        } catch let error as PromptSuiteValidationError {
            throw error
        } catch let error as DecodingError {
            throw PromptSuiteValidationError.malformedJSON(describe(error))
        } catch {
            throw PromptSuiteValidationError.malformedJSON(error.localizedDescription)
        }

        guard let declaredPromptID = BuiltInPromptID(rawValue: document.promptID) else {
            throw PromptSuiteValidationError.unknownPromptID(document.promptID)
        }
        guard declaredPromptID == promptID else {
            throw PromptSuiteValidationError.promptIDMismatch(expected: promptID, actual: declaredPromptID)
        }
        try requireIdentifier(document.suiteID, field: "suite_id")
        guard let variant = PromptSuitePromptVariant(rawValue: document.promptVariant) else {
            throw PromptSuiteValidationError.unsupportedPromptVariant(document.promptVariant)
        }

        let grader = try validateGrader(document.grader, directory: directory)
        let cases = try validateCases(document.cases, graderKind: grader.kind)

        return PromptSuite(
            suiteID: document.suiteID,
            promptID: promptID,
            promptVariant: variant,
            grader: grader,
            cases: cases,
            suiteSHA256: BuiltInPromptRegistry.sha256Hex(data)
        )
    }

    private static func validateGrader(_ grader: GraderDocument, directory: URL) throws -> PromptSuiteGrader {
        guard let kind = PromptSuiteGraderKind(rawValue: grader.kind) else {
            throw PromptSuiteValidationError.unknownGraderKind(grader.kind)
        }
        let range = PromptSuiteScoreRange(min: grader.scoreRange.min, max: grader.scoreRange.max)
        guard range.min.isFinite, range.max.isFinite, range.min < range.max else {
            throw PromptSuiteValidationError.invalidScoreRange(min: range.min, max: range.max)
        }
        let rubric: PromptSuiteRubric?
        switch kind {
        case .exactMatch, .external:
            guard grader.rubric == nil else { throw PromptSuiteValidationError.unexpectedRubric }
            rubric = nil
        case .modelJudge:
            guard let reference = grader.rubric else { throw PromptSuiteValidationError.missingRubric }
            rubric = try loadRubric(reference, directory: directory)
        }
        return PromptSuiteGrader(kind: kind, scoreRange: range, rubric: rubric)
    }

    private static func loadRubric(_ reference: String, directory: URL) throws -> PromptSuiteRubric {
        guard !reference.isEmpty,
              !reference.hasPrefix("."),
              !reference.contains("/"),
              !reference.contains("\\"),
              reference != PromptSuite.fileName,
              reference != BuiltInPromptID.promptFileName
        else {
            throw PromptSuiteValidationError.invalidRubricReference(reference)
        }
        let url = directory.appendingPathComponent(reference)
        guard isRegularFile(url),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            throw PromptSuiteValidationError.rubricUnreadable(reference)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptSuiteValidationError.emptyRubric(reference)
        }
        do {
            return try PromptSuiteRubric.checklist(fileName: reference, text: text, sha256: BuiltInPromptRegistry.sha256Hex(data))
        } catch let failure as PromptSuiteChecklistParser.Failure {
            let detail = switch failure {
            case let .malformedCheck(line): "malformed check line '\(line.prefix(120))'"
            case let .duplicateCheck(id): "duplicate check id '\(id)'"
            case let .unknownHostCheck(kind): "unsupported host check '\(kind)'"
            case .noChecks: "no checks"
            }
            throw PromptSuiteValidationError.invalidRubricChecklist(file: reference, detail: detail)
        }
    }

    private static func validateCases(_ documents: [CaseDocument], graderKind: PromptSuiteGraderKind) throws -> [PromptSuiteCase] {
        guard !documents.isEmpty else { throw PromptSuiteValidationError.noCases }
        var seen: Set<String> = []
        var cases: [PromptSuiteCase] = []
        for document in documents {
            try requireIdentifier(document.id, field: "case id")
            guard seen.insert(document.id).inserted else {
                throw PromptSuiteValidationError.duplicateCaseID(document.id)
            }
            guard let split = PromptSuiteSplit(rawValue: document.split) else {
                throw PromptSuiteValidationError.unknownSplit(caseID: document.id, value: document.split)
            }
            guard !document.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PromptSuiteValidationError.emptyInput(caseID: document.id)
            }
            if graderKind == .exactMatch, document.expectedOutput == nil {
                throw PromptSuiteValidationError.missingExpectedOutput(caseID: document.id)
            }
            var paths: Set<String> = []
            for file in document.files ?? [] {
                let path = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, path == file.path, paths.insert(path).inserted else {
                    throw PromptSuiteValidationError.invalidContextFile(caseID: document.id, path: file.path)
                }
            }
            let fileTree = document.fileTree.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let files = (document.files ?? []).map { PromptSuiteContextFile(path: $0.path, content: $0.content) }
            cases.append(PromptSuiteCase(
                id: document.id,
                split: split,
                input: document.input,
                expectedOutput: document.expectedOutput,
                context: fileTree == nil && files.isEmpty ? nil : PromptSuiteCaseContext(fileTree: fileTree, files: files)
            ))
        }
        for split in [PromptSuiteSplit.training, .validation] where !cases.contains(where: { $0.split == split }) {
            throw PromptSuiteValidationError.emptyDevelopmentSplit(split)
        }
        return cases
    }

    private static func requireIdentifier(_ value: String, field: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1 ... 128).contains(value.count),
              value.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw PromptSuiteValidationError.invalidIdentifier(field: field, value: value)
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let components = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return components.isEmpty ? "<root>" : components.joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            return "missing field '\(key.stringValue)' at \(path(context))"
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "wrong type at \(path(context))"
        case let .dataCorrupted(context):
            return "invalid data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

// MARK: - Strict wire documents

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys<Key: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    knownKeys _: Key.Type
) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let known = Set(Key.allCases.map(\.stringValue))
    let unknown = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
    guard unknown.isEmpty else {
        let components = decoder.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
        throw PromptSuiteValidationError.unknownFields(
            path: components.isEmpty ? "<root>" : components.joined(separator: "."),
            fields: unknown
        )
    }
}

private struct SuiteDocument: Decodable {
    let suiteID: String
    let promptID: String
    let promptVariant: String
    let grader: GraderDocument
    let cases: [CaseDocument]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case suiteID = "suite_id"
        case promptID = "prompt_id"
        case promptVariant = "prompt_variant"
        case grader
        case cases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The version gate runs first so a newer suite reports its version, not its new fields.
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == PromptSuite.schemaVersion else {
            throw PromptSuiteValidationError.unsupportedSchemaVersion(version)
        }
        try rejectUnknownKeys(decoder, knownKeys: CodingKeys.self)
        suiteID = try container.decode(String.self, forKey: .suiteID)
        promptID = try container.decode(String.self, forKey: .promptID)
        promptVariant = try container.decode(String.self, forKey: .promptVariant)
        grader = try container.decode(GraderDocument.self, forKey: .grader)
        cases = try container.decode([CaseDocument].self, forKey: .cases)
    }
}

private struct GraderDocument: Decodable {
    let kind: String
    let scoreRange: ScoreRangeDocument
    let rubric: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case scoreRange = "score_range"
        case rubric
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, knownKeys: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        scoreRange = try container.decode(ScoreRangeDocument.self, forKey: .scoreRange)
        rubric = try container.decodeIfPresent(String.self, forKey: .rubric)
    }
}

private struct ScoreRangeDocument: Decodable {
    let min: Double
    let max: Double

    enum CodingKeys: String, CodingKey, CaseIterable {
        case min
        case max
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, knownKeys: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        min = try container.decode(Double.self, forKey: .min)
        max = try container.decode(Double.self, forKey: .max)
    }
}

private struct CaseDocument: Decodable {
    let id: String
    let split: String
    let input: String
    let expectedOutput: String?
    let fileTree: String?
    let files: [ContextFileDocument]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case split
        case input
        case expectedOutput = "expected_output"
        case fileTree = "file_tree"
        case files
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, knownKeys: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        split = try container.decode(String.self, forKey: .split)
        input = try container.decode(String.self, forKey: .input)
        expectedOutput = try container.decodeIfPresent(String.self, forKey: .expectedOutput)
        fileTree = try container.decodeIfPresent(String.self, forKey: .fileTree)
        files = try container.decodeIfPresent([ContextFileDocument].self, forKey: .files)
    }
}

private struct ContextFileDocument: Decodable {
    let path: String
    let content: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case path
        case content
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, knownKeys: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        content = try container.decode(String.self, forKey: .content)
    }
}
