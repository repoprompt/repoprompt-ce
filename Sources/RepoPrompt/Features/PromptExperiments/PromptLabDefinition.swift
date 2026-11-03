#if DEBUG
    import Foundation

    enum PromptLabSourceKind: String, Codable, CaseIterable {
        case builtIn, file, pasted
    }

    enum PromptLabRunnerKind: String, Codable, CaseIterable {
        case plainPrompt, oracle, engineer, program, dspy
    }

    struct PromptLabSource: Codable, Equatable {
        var kind: PromptLabSourceKind
        var title: String
        var prompt: String
        var builtInPromptID: BuiltInPromptID?
        var filePath: String?
        var originalFileSHA256: String?
        /// Exact source bytes selected by the user; a literal's decoded value lives in prompt.
        /// Nil is an editable whole-file prompt only for recognized text/template extensions.
        var selection: String?
        var literal: PromptLabSourceLiteral?

        static func importFile(url: URL, selection: String? = nil) throws -> Self {
            let file = try canonicalSource(url)
            let data = try Data(contentsOf: file)
            guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else {
                throw PromptExperimentAuthorityError.invalidRequest("Choose a UTF-8 prompt or source file smaller than 2 MB.")
            }
            var prompt = text
            var literal: PromptLabSourceLiteral?
            if let selection {
                guard !selection.isEmpty, text.components(separatedBy: selection).count == 2 else {
                    throw PromptExperimentAuthorityError.invalidRequest("The selected source text must occur exactly once in the file.")
                }
                if PromptLabSourceCodec.isPlainText(file) { prompt = selection }
                else {
                    let imported = try PromptLabSourceCodec.importLiteral(source: text, selection: selection, url: file)
                    prompt = imported.prompt
                    literal = imported.literal
                }
            }
            return Self(
                kind: .file, title: file.lastPathComponent, prompt: prompt,
                filePath: file.path, originalFileSHA256: PromptExperimentDigest.sha256(data), selection: selection, literal: literal
            )
        }

        static func requireRegularSource(_ url: URL) throws {
            _ = try canonicalSource(url)
        }

        /// User-selected ancestor aliases (including macOS /tmp and /var) resolve once at
        /// import. The final file cannot be a link; saved authorities contain the resolved path.
        static func canonicalSource(_ url: URL) throws -> URL {
            let selected = url.standardizedFileURL
            guard selected.path.hasPrefix("/"), !selected.pathComponents.contains(where: { $0.hasSuffix(".app") }) else {
                throw PromptExperimentAuthorityError.invalidRequest("Choose an absolute source path outside an application bundle.")
            }
            guard try selected.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw PromptExperimentAuthorityError.invalidRequest("Choose the actual source file, not a symbolic link to it.")
            }
            let canonical = selected.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(selected.lastPathComponent).standardizedFileURL
            guard !canonical.pathComponents.contains(where: { $0.hasSuffix(".app") }),
                  try canonical.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                  try canonical.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else {
                throw PromptExperimentAuthorityError.invalidRequest("The selected source must be a regular file.")
            }
            return canonical
        }

        func validated() throws -> Self {
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 500_000 else {
                throw PromptExperimentAuthorityError.invalidRequest("The starting prompt must contain text and be at most 500 KB.")
            }
            if kind == .file {
                guard let filePath, let originalFileSHA256 else {
                    throw PromptExperimentAuthorityError.invalidRequest("Import the source file before creating the experiment.")
                }
                let snapshot = try Self.importFile(url: URL(fileURLWithPath: filePath), selection: selection)
                guard selection != nil || PromptLabSourceCodec.isPlainText(URL(fileURLWithPath: filePath)) else {
                    throw PromptExperimentAuthorityError.invalidRequest("Select one complete static prompt string inside this code file. The complete source file cannot be optimized or replaced as a prompt. Plain .md, .txt and .prompt files can be used directly.")
                }
                guard snapshot.originalFileSHA256 == originalFileSHA256, snapshot.prompt == prompt,
                      literal == nil || snapshot.literal == literal
                else {
                    throw PromptExperimentAuthorityError.invalidRequest("The source changed after import. Reimport it to start from the current prompt.")
                }
                var value = snapshot
                value.title = title
                return value
            }
            return self
        }
    }

    struct PromptLabObjective: Codable, Equatable {
        enum Mode: String, Codable, CaseIterable { case quality, efficiency }
        var mode: Mode = .quality
        var qualityTolerance: Double = 0
        var inputWeight: Double = 1
        var outputWeight: Double = 1

        func validate() throws {
            guard qualityTolerance.isFinite, (0 ... 0.25).contains(qualityTolerance),
                  inputWeight.isFinite, outputWeight.isFinite,
                  (0 ... 100).contains(inputWeight), (0 ... 100).contains(outputWeight),
                  inputWeight + outputWeight > 0
            else { throw PromptExperimentAuthorityError.invalidRequest("Choose a quality tolerance from 0 to 0.25 and nonnegative input/output weights with a positive total.") }
        }
    }

    struct PromptLabProgram: Codable, Equatable {
        enum ModelRouting: String, Codable { case connected, project }
        var pythonExecutable: String
        var projectRoot: String
        var modulePath: String
        var callable: String = "evaluate"
        var timeoutSeconds: Double = 120
        var moduleSHA256: String?
        var environmentKeys: [String] = []
        var modelRouting: ModelRouting?
        var dependencySHA256: [String: String]?

        func sealed() throws -> Self {
            guard pythonExecutable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: pythonExecutable),
                  projectRoot.hasPrefix("/"), timeoutSeconds.isFinite, (1 ... 900).contains(timeoutSeconds)
            else { throw PromptExperimentAuthorityError.invalidRequest("Select an executable Python interpreter, an absolute project folder and a timeout from 1 to 900 seconds.") }
            guard environmentKeys.count <= 32, Set(environmentKeys).count == environmentKeys.count,
                  environmentKeys.allSatisfy({ $0.range(of: #"^[A-Z][A-Z0-9_]{0,127}$"#, options: .regularExpression) != nil
                          && !["HOME", "PATH", "TMPDIR"].contains($0) && !$0.hasPrefix("PYTHON") && !$0.hasPrefix("DYLD_") && !$0.hasPrefix("LD_") })
            else { throw PromptExperimentAuthorityError.invalidRequest("Choose at most 32 distinct environment variable names; runtime and loader settings cannot be overridden.") }
            let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let selectedModule = modulePath.hasPrefix("/") ? URL(fileURLWithPath: modulePath).standardizedFileURL : root.appendingPathComponent(modulePath).standardizedFileURL
            let module = try PromptLabSource.canonicalSource(selectedModule)
            guard module.path.hasPrefix(root.path + "/"), module.pathExtension == "py" else {
                throw PromptExperimentAuthorityError.invalidRequest("The Python module must be a .py file inside the selected project.")
            }
            let digest = try PromptExperimentDigest.sha256(Data(contentsOf: module))
            if let moduleSHA256, moduleSHA256 != digest {
                throw PromptExperimentAuthorityError.invalidRequest("The project evaluator changed. Create a new experiment for the updated evaluator.")
            }
            let dependencies = try PromptLabProgramDependencies.snapshot(root: root)
            if let dependencySHA256, dependencySHA256 != dependencies {
                throw PromptExperimentAuthorityError.invalidRequest("The evaluator's Python sources or dependency declarations changed. Reload the program and create a new experiment.")
            }
            var value = self
            value.modulePath = module.path
            value.projectRoot = root.path
            value.moduleSHA256 = digest
            value.dependencySHA256 = dependencies
            return value
        }
    }

    /// Frozen, backend-independent experiment input. Source identity and execution are separate.
    struct PromptLabDefinition: Codable, Equatable {
        static let contractVersion = 1
        var source: PromptLabSource
        var goal: String
        var objective: PromptLabObjective = .init()
        var runner: PromptLabRunnerKind = .plainPrompt
        var examples: [PromptSuiteCase]
        var criteria: String
        var program: PromptLabProgram?
        var contractVersion: Int = Self.contractVersion
        var relativePromptLimit: Double?

        func validated() throws -> Self {
            guard contractVersion == Self.contractVersion else {
                throw PromptExperimentAuthorityError.invalidRequest("This experiment uses an unsupported task-runner contract. Create a new experiment.")
            }
            guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.count <= 16000 else {
                throw PromptExperimentAuthorityError.invalidRequest("Describe the desired improvement in 1–16,000 characters.")
            }
            try objective.validate()
            if let relativePromptLimit, !relativePromptLimit.isFinite || !(0.25 ... 4).contains(relativePromptLimit) {
                throw PromptExperimentAuthorityError.invalidRequest("The relative prompt limit must be between 0.25 and 4, or absent.")
            }
            if source.kind == .builtIn {
                guard let id = source.builtInPromptID,
                      runner == (id == .engineer ? .engineer : .oracle)
                else { throw PromptExperimentAuthorityError.invalidRequest("A built-in prompt must use its production task runner.") }
            } else if source.builtInPromptID != nil || runner == .oracle {
                throw PromptExperimentAuthorityError.invalidRequest("Project prompts cannot impersonate an RPCE built-in prompt.")
            }
            var value = self
            value.source = try source.validated()
            if runner == .program || runner == .dspy {
                guard let program else { throw PromptExperimentAuthorityError.invalidRequest("Choose the project's Python interpreter and evaluation module.") }
                value.program = try program.sealed()
            }
            guard (3 ... 1000).contains(examples.count), Set(examples.map(\.id)).count == examples.count,
                  examples.allSatisfy({ !$0.id.isEmpty && !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  PromptSuiteSplit.allCases.allSatisfy({ split in examples.contains { $0.split == split } })
            else { throw PromptExperimentAuthorityError.invalidRequest("Provide distinct, nonempty examples for training, validation and final checks (at least one in each group).") }
            if runner == .plainPrompt {
                for example in examples {
                    var variables = example.variables
                    variables["input"] = variables["input"] ?? example.input
                    _ = try PromptLabTemplate.render(source.prompt, variables: variables)
                    _ = try PromptLabTemplate.render(example.input, variables: variables)
                }
            }
            _ = try value.makeSuite()
            return value
        }

        func makeSuite() throws -> PromptSuite {
            let rubricText: String
            if criteria.contains("(weight ") {
                rubricText = criteria
            } else {
                let lines = criteria.components(separatedBy: .newlines).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "-• "))
                }.filter { !$0.isEmpty }
                guard !lines.isEmpty || runner == .program || runner == .dspy || runner == .engineer else {
                    throw PromptExperimentAuthorityError.invalidRequest("Add at least one success criterion.")
                }
                rubricText = (lines.isEmpty ? ["The task satisfies its independent acceptance checks."] : lines).enumerated().map {
                    "- `check_\($0.offset + 1)` (weight 1): \($0.element)"
                }.joined(separator: "\n")
            }
            let rubric = try PromptSuiteRubric.checklist(
                fileName: "criteria.md", text: rubricText,
                sha256: PromptExperimentDigest.sha256(Data(rubricText.utf8))
            )
            let externalGrader = runner == .program || runner == .dspy || runner == .engineer
            return try PromptSuite(
                suiteID: "lab-\(PromptExperimentDigest.canonicalSHA256(self).prefix(16))",
                promptID: source.builtInPromptID, promptVariant: .project,
                grader: .init(kind: externalGrader ? .external : .modelJudge, scoreRange: .init(min: 0, max: 1), rubric: externalGrader ? nil : rubric),
                cases: examples, suiteSHA256: PromptExperimentDigest.canonicalSHA256(self)
            )
        }

        var background: String {
            switch runner {
            case .plainPrompt:
                "The candidate is the user's prompt template. Preserve all {{variable}} placeholders. The task runner renders variables and sends the case input as the user message. Improve the stated goal on representative cases without memorizing them."
            case .oracle:
                "The candidate is an RPCE Oracle system prompt body. Production rendering adds fixed format instructions and frozen repository context. Preserve the role and required output contract."
            case .engineer:
                "The candidate is RPCE's Engineer system prompt. It runs real file-editing tasks in fresh isolated fixtures; independent tests grade the resulting files. Preserve runtime template placeholders and tool protocols."
            case .program:
                "The candidate is passed to the selected project's evaluator. Optimize the actual program's behavior using its task feedback and measured usage. Preserve the candidate's format and required variables."
            case .dspy:
                "The candidate contains the DSPy program's named predictor instructions. Preserve predictor names and the JSON object structure; refine the instructions using actual program evaluations."
            }
        }
    }

    enum PromptLabTemplate {
        private static let pattern = #"\{\{([A-Za-z_][A-Za-z0-9_.]*)\}\}|\$\{([A-Za-z_][A-Za-z0-9_.]*)\}|\{([A-Za-z_][A-Za-z0-9_.]*)\}"#

        static func variables(in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let source = text as NSString
            return Array(Set(regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
                (1 ..< match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound }).map {
                    source.substring(with: match.range(at: $0))
                }
            })).sorted()
        }

        static func render(_ text: String, variables: [String: String]) throws -> String {
            let regex = try NSRegularExpression(pattern: pattern)
            let source = text as NSString
            var rendered = text
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
                guard let index = (1 ..< match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
                let name = source.substring(with: match.range(at: index))
                guard let value = variables[name], let range = Range(match.range, in: rendered) else {
                    throw PromptExperimentAuthorityError.invalidRequest("Example is missing the template variable '\(name)'.")
                }
                rendered.replaceSubrange(range, with: value)
            }
            return rendered
        }
    }

    extension PromptExperimentAuthority {
        var promptIdentifier: String {
            promptID?.rawValue ?? definition?.source.title ?? "project-prompt"
        }

        var promptDisplayName: String {
            definition?.source.title ?? promptIdentifier
        }

        var sourceDescription: String {
            definition?.source.filePath ?? (promptID == nil ? "Pasted prompt" : "RPCE built-in prompt")
        }
    }
#endif
