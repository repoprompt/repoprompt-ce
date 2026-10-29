#if DEBUG
    import AppKit
    import SwiftUI

    /// Native editing of the same frozen experiment definition accepted by MCP.
    /// Preparation is an explicit bounded call; optimization starts after native review.
    struct PromptExperimentCreateView: View {
        @ObservedObject var service: PromptExperimentService
        let onCreated: (UUID) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var prompts: [PromptExperimentPromptOption] = []
        @State private var targets: [PromptExperimentResolvedTarget] = []
        @State private var sourceChoice = PromptLabSourceChoice.builtIn
        @State private var preserveImportedSource = false
        @State private var promptID = BuiltInPromptID.oraclePlan.rawValue
        @State private var source: PromptLabSource?
        @State private var pastedPrompt = ""
        @State private var selectedPassage = ""
        @State private var title = ""
        @State private var goal = "Improve the quality of the answers while keeping the prompt concise."
        @State private var exampleInputs = ""
        @State private var examples: [PromptLabExampleDraft] = []
        @State private var criteria = ""
        @State private var generatedExamples = false
        @State private var runner = PromptLabRunnerKind.plainPrompt
        @State private var programPython = PromptExperimentGEPAWorker.configuredPythonExecutable() ?? ""
        @State private var programPythonWasChosen = false
        @State private var programRoot = ""
        @State private var programModule = ""
        @State private var programCallable = "evaluate"
        @State private var programTimeout = 120.0
        @State private var programEnvironmentKeys = ""
        @State private var programLoaded = false
        @State private var inspectedProgram: PromptLabProgram?
        @State private var executionTarget = ""
        @State private var reflectionTarget = ""
        @State private var judgeTarget = ""
        @State private var efficiencyObjective = false
        @State private var qualityTolerance = 0.0
        @State private var inputWeight = 1.0
        @State private var outputWeight = 1.0
        @State private var maxEvaluations = 25
        @State private var minibatchSize = 2
        @State private var noiseFloorReplicates = 2
        @State private var promptCharacterCeilingRatio = 0.0
        @State private var showsAdvanced = false
        @State private var showsExamples = true
        @State private var isWorking = false
        @State private var workLabel = ""
        @State private var pendingTask: Task<Void, Never>?
        @State private var errorMessage: String?

        private var selection: PromptExperimentPromptOption? {
            prompts.first { $0.id == promptID }
        }

        private var cases: [PromptSuiteCase] {
            examples.map(\.example).filter { !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        private var minimumEvaluations: Int {
            PromptExperimentBudgetLedger.minimumApprovableEvaluations(cases: cases, reflectionMinibatchSize: minibatchSize)
        }

        private var calibrationEvaluations: Int {
            PromptExperimentBudgetLedger.calibrationEvaluations(cases: cases, replicates: noiseFloorReplicates)
        }

        private var judgeMatchesReflection: Bool {
            guard runner.usesModelJudge,
                  let judge = targets.first(where: { $0.selector == judgeTarget }),
                  let reflection = targets.first(where: { $0.selector == reflectionTarget })
            else { return false }
            return judge.judgmentModelIdentity == reflection.judgmentModelIdentity
        }

        private var sourceReady: Bool {
            sourceChoice == .pasted ? !pastedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : source != nil
        }

        private var canCreate: Bool {
            service.isLoaded && service.loadError == nil && sourceReady && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && PromptSuiteSplit.allCases.allSatisfy { split in cases.contains { $0.split == split } }
                && (!runner.usesModelJudge || (!criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !judgeTarget.isEmpty))
                && (!runner.usesProgram || programLoaded)
                && !executionTarget.isEmpty && !reflectionTarget.isEmpty
                && maxEvaluations >= minimumEvaluations && maxEvaluations <= 10000 && !isWorking
        }

        var body: some View {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Improve a Prompt").font(.title2.bold())
                    Text("Choose the prompt, describe success, and compare changes on examples before using the result.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                Form {
                    sourceSection
                    goalSection
                    examplesSection
                    modelSection
                    budgetSection
                    advancedSection
                    if let errorMessage = errorMessage ?? service.loadError {
                        Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .formStyle(.grouped)
                .disabled(isWorking)
                Divider()
                HStack {
                    if isWorking {
                        ProgressView().controlSize(.small)
                        Text(workLabel).font(.caption)
                    } else {
                        Text("Next: review the complete experiment and approve the run.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isWorking ? "Cancel preparation" : "Cancel") {
                        if isWorking { pendingTask?.cancel() } else { dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Review Experiment") { createDraft() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canCreate)
                }
                .padding(16)
            }
            .frame(width: 800, height: 840)
            .interactiveDismissDisabled(isWorking)
            .task { await service.load()
                refreshOptions()
                loadBuiltIn()
            }
            .onChange(of: promptID) { _, _ in if sourceChoice == .builtIn { loadBuiltIn() } }
            .onChange(of: sourceChoice) { _, choice in
                if preserveImportedSource { preserveImportedSource = false }
                else { changeSource(to: choice) }
            }
            .onChange(of: pastedPrompt) { _, _ in addTemplateFields() }
            .onChange(of: selectedPassage) { _, _ in addTemplateFields() }
            .onChange(of: source?.prompt) { _, _ in addTemplateFields() }
            .onChange(of: runner) { _, _ in programLoaded = false
                suggestProgramPython()
                addTemplateFields()
            }
            .onDisappear { pendingTask?.cancel() }
        }

        private var sourceSection: some View {
            Section("1. Choose a prompt") {
                Picker("Source", selection: $sourceChoice) {
                    ForEach(PromptLabSourceChoice.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Experiment name (optional)", text: $title)
                if sourceChoice == .builtIn {
                    Picker("RepoPrompt prompt", selection: $promptID) {
                        ForEach(prompts) { Text($0.title).tag($0.id) }
                    }
                    if let reason = selection?.unavailableReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                } else if sourceChoice == .file {
                    HStack {
                        Button("Choose prompt or source file…") { chooseFile() }
                        Text(source?.filePath ?? source?.title ?? "Choose a file from any project.").font(.caption).textSelection(.enabled)
                    }
                    DisclosureGroup("Select the prompt inside a source file") {
                        Text("For code, paste one complete static string literal or its exact contents. For a prompt text file, leave this empty to optimize the whole file. Applying a result preserves the surrounding source and its supported string encoding.")
                            .font(.caption).foregroundStyle(.secondary)
                        editor($selectedPassage, height: 90)
                    }
                } else {
                    Text("Prompt text").font(.caption.bold())
                    editor($pastedPrompt, height: 130)
                }
                if let source, sourceChoice != .pasted {
                    DisclosureGroup("Read current prompt") {
                        ScrollView {
                            Text(source.prompt).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 180)
                    }
                }
            }
        }

        private var goalSection: some View {
            Section("2. Describe the outcome") {
                TextField("What should improve?", text: $goal, axis: .vertical).lineLimit(2 ... 5)
                Picker("Priority", selection: $efficiencyObjective) {
                    Text("Best quality, then shorter prompts").tag(false)
                    Text("Fewer tokens while preserving quality").tag(true)
                }
                if efficiencyObjective {
                    TextField("Acceptable quality decrease (0 means none)", value: $qualityTolerance, format: .number)
                    Text("Quality is scored from 0 to 1. Token savings are compared on matching examples with reported usage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if sourceChoice != .builtIn {
                    Picker("How your prompt is used", selection: $runner) {
                        Text(PromptLabRunnerKind.plainPrompt.labDisplayName).tag(PromptLabRunnerKind.plainPrompt)
                        Text(PromptLabRunnerKind.program.labDisplayName).tag(PromptLabRunnerKind.program)
                        Text(PromptLabRunnerKind.dspy.labDisplayName).tag(PromptLabRunnerKind.dspy)
                    }
                }
                if runner.usesProgram { programSection }
                if runner == .engineer {
                    Text("Each task runs the Engineer prompt with file read/edit tools in its own fixture. Private acceptance checks stay outside the files the agent can edit. Shell, web access and delegation are disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        private var programSection: some View {
            Group {
                HStack {
                    TextField("Python interpreter", text: Binding(
                        get: { programPython },
                        set: { programPython = $0
                            programPythonWasChosen = true
                        }
                    ))
                    Button("Choose…") {
                        chooseProgramPath(directory: false) { programPython = $0.path
                            programPythonWasChosen = true
                        }
                    }
                }
                if runner == .dspy {
                    Text("Choose the Python interpreter from your project's environment with DSPy 3.4.1 installed. A .venv or venv inside the selected project is detected automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Project directory", text: $programRoot)
                    Button("Choose…") { chooseProgramPath(directory: true) { programRoot = $0.path } }
                }
                HStack {
                    TextField("Evaluation module path", text: $programModule)
                    Button("Choose…") { chooseProgramPath(directory: false) { programModule = $0.path } }
                }
                TextField("Evaluation function", text: $programCallable)
                TextField("Timeout per example (seconds)", value: $programTimeout, format: .number)
                Button("Load program examples and checks") { loadProgram() }
                    .disabled(programPython.isEmpty || programRoot.isEmpty || programModule.isEmpty)
                if programLoaded, let routing = inspectedProgram?.modelRouting {
                    Text(routing == .project ? "Model calls use the project's configured client and settings. Reported usage comes from the evaluator's measurements." : "Model calls use the selected RPCE connected model through the program callback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if programLoaded, !sourceReady {
                    Text("Paste or choose the starting prompt to complete this experiment.").font(.caption).foregroundStyle(.orange)
                }
                Button("Save a starter evaluator…") { saveProgramExample() }
                Text("Load program runs the selected local Python module to read its experiment description. Only load code you intend to execute. Your project environment supplies its dependencies, including DSPy when selected.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Program integration details") {
                    TextField("Environment variable names (comma separated)", text: $programEnvironmentKeys)
                    Text("Names of environment variables this evaluator may inherit, such as OPENAI_API_KEY. Values stay outside experiment files.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The RPCE model callback accepts a system message and one user message. For a conversation or custom provider settings, use the project's own model client in the evaluator. Return its measured token usage to include it in the efficiency comparison.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("A project's own client manages its calls and limits. RPCE still bounds evaluator time and evaluation count; its provider-session cap counts calls routed through RPCE.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: programPython) { _, _ in programLoaded = false }
            .onChange(of: programRoot) { _, _ in programLoaded = false
                suggestProgramPython()
            }
            .onChange(of: programModule) { _, _ in programLoaded = false }
            .onChange(of: programCallable) { _, _ in programLoaded = false }
            .onChange(of: programEnvironmentKeys) { _, _ in programLoaded = false }
        }

        private var examplesSection: some View {
            Section("3. Examples and success checks") {
                if !runner.usesProgram, runner != .engineer {
                    TextField("Optional example requests or topics, one per line", text: $exampleInputs, axis: .vertical).lineLimit(2 ... 5)
                    Button("Generate examples and checks") { prepareExamples() }
                        .disabled(!sourceReady || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reflectionTarget.isEmpty)
                    Text("Uses one model call to draft a small experiment. Review the proposed examples and checks before approving the optimization.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if generatedExamples {
                    Label("These examples were generated. Check that they represent real requests and that the expected results are correct.", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("\(cases.count) examples · review and edit", isExpanded: $showsExamples) {
                    ForEach($examples) { $example in
                        PromptLabExampleEditor(example: $example) { examples.removeAll { $0.id == example.id } }
                    }
                    Button("Add example") {
                        examples.append(PromptLabExampleDraft(index: examples.count))
                        addTemplateFields()
                    }
                }
                if !cases.isEmpty {
                    Text("\(cases.count(where: { $0.split == .training })) used to improve · \(cases.count(where: { $0.split == .validation })) to compare · \(cases.count(where: { $0.split == .hiddenTest })) final checks")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let parsed = try? PromptSuiteChecklistParser.parse(criteria) {
                    DisclosureGroup("Saved success checks (\(parsed.checks.count))") {
                        ForEach(parsed.checks, id: \.id) { Text("• \($0.text)").font(.caption) }
                        Text("The saved weights and deterministic checks are preserved.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Success checks — one concrete requirement per line").font(.caption.bold())
                    editor($criteria, height: 110)
                }
                if !cases.contains(where: { $0.split == .hiddenTest }) {
                    Text("Add a final-check example to assess the result on a request that does not guide edits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        private var modelSection: some View {
            Section("4. Choose a model") {
                modelPicker(programLoaded && inspectedProgram?.modelRouting == .project ? "RPCE model for explicit callbacks" : "Model using the prompt", selection: $executionTarget)
                if targets.isEmpty {
                    Text("Connect a model in Settings → CLI Providers, then refresh.").font(.caption).foregroundStyle(.orange)
                }
                if judgeMatchesReflection {
                    Text("The same model proposes and judges changes. A separate judge can reduce self-preference; you can choose one under Advanced settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Refresh connected models") { refreshOptions() }.font(.caption)
            }
        }

        private var budgetSection: some View {
            Section("5. Choose a small run") {
                HStack {
                    Text("Search budget")
                    Spacer()
                    Button("Small · 25") { maxEvaluations = max(25, minimumEvaluations) }
                    Button("Medium · 50") { maxEvaluations = max(50, minimumEvaluations) }
                }
                TextField("Search evaluations", value: $maxEvaluations, format: .number)
                if (1 ... 10000).contains(maxEvaluations) {
                    Text("Up to \(maxEvaluations + calibrationEvaluations) evaluations: \(maxEvaluations) search + \(calibrationEvaluations) baseline checks.").font(.callout.bold())
                }
                Text("Each evaluation runs one example. Judging, reflection, repairs and retries add model calls; this is not a dollar or model-call cap.")
                    .font(.caption).foregroundStyle(.secondary)
                if maxEvaluations < minimumEvaluations || maxEvaluations > 10000 {
                    Text("These examples require \(minimumEvaluations)–10000 search evaluations.").font(.caption).foregroundStyle(.red)
                }
            }
        }

        private var advancedSection: some View {
            Section {
                DisclosureGroup("Advanced settings", isExpanded: $showsAdvanced) {
                    modelPicker("Model proposing edits", selection: $reflectionTarget)
                    if runner.usesModelJudge || runner.usesProgram {
                        modelPicker(runner.usesProgram ? "Optional judge for program callbacks" : "Model judging answers", selection: $judgeTarget)
                    }
                    if efficiencyObjective {
                        TextField("Relative input-token weight", value: $inputWeight, format: .number)
                        TextField("Relative output-token weight", value: $outputWeight, format: .number)
                        Text("Weights express your priorities. They are not model prices.").font(.caption).foregroundStyle(.secondary)
                    }
                    Stepper("Examples per proposal: \(minibatchSize)", value: $minibatchSize, in: 1 ... 100)
                    Stepper("Extra baseline passes: \(noiseFloorReplicates)", value: $noiseFloorReplicates, in: 0 ... 5)
                    Picker("Prompt length limit", selection: $promptCharacterCeilingRatio) {
                        Text("No relative limit").tag(0.0)
                        Text("Same length as parent").tag(1.0)
                        Text("Up to 1.5× the parent").tag(1.5)
                        Text("Up to 2× the parent").tag(2.0)
                    }
                    Text("Repeated baseline passes estimate variability. They do not establish statistical confidence.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
            TextEditor(text: text).font(.body.monospaced()).frame(minHeight: height, maxHeight: height).padding(5)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
        }

        private func modelPicker(_ label: String, selection: Binding<String>) -> some View {
            Picker(label, selection: selection) {
                Text("Choose a model").tag("")
                ForEach(targets, id: \.selector) { Text($0.displayName).tag($0.selector) }
            }
        }

        private func refreshOptions() {
            prompts = service.promptOptions()
            targets = service.availableTargets()
            let defaults = service.targetDefaults()
            if !targets.contains(where: { $0.selector == executionTarget }) { executionTarget = defaults.execution?.selector ?? targets.first?.selector ?? "" }
            if !targets.contains(where: { $0.selector == reflectionTarget }) { reflectionTarget = defaults.reflection?.selector ?? executionTarget }
            if !targets.contains(where: { $0.selector == judgeTarget }) { judgeTarget = defaults.judge?.selector ?? executionTarget }
        }

        private func loadBuiltIn() {
            guard let option = selection else { return }
            do {
                source = try service.source(for: option.promptID)
                runner = option.promptID == .engineer ? .engineer : .oracle
                examples = (option.suite?.cases ?? []).map(PromptLabExampleDraft.init(example:))
                criteria = option.suite?.grader.rubric?.text ?? ""
                generatedExamples = false
            } catch { errorMessage = error.localizedDescription
                source = nil
            }
        }

        private func changeSource(to choice: PromptLabSourceChoice) {
            errorMessage = nil
            source = nil
            selectedPassage = ""
            generatedExamples = false
            programLoaded = false
            if choice == .builtIn { loadBuiltIn() }
            else { runner = .plainPrompt
                examples = (0 ..< 3).map(PromptLabExampleDraft.init(index:))
                criteria = ""
            }
        }

        private func chooseFile() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = "Choose the prompt file, or a source file containing a prompt you want to improve."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { source = try PromptLabSource.importFile(url: url)
                selectedPassage = ""
            } catch { errorMessage = error.localizedDescription }
        }

        private func addTemplateFields() {
            guard runner == .plainPrompt else { return }
            let text: String = if sourceChoice == .pasted { pastedPrompt }
            else if sourceChoice == .file, !selectedPassage.isEmpty { (try? currentSource().prompt) ?? "" }
            else { source?.prompt ?? "" }
            let variables = PromptLabTemplate.variables(in: text)
            for index in examples.indices {
                for name in variables where examples[index].variables[name] == nil {
                    examples[index].variables[name] = ""
                }
            }
        }

        private func chooseProgramPath(directory: Bool, onChoose: (URL) -> Void) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = directory
            panel.canChooseFiles = !directory
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            onChoose(url)
        }

        private func suggestProgramPython() {
            guard !programPythonWasChosen else { return }
            let root = URL(fileURLWithPath: programRoot, isDirectory: true)
            let candidates = [".venv/bin/python", ".venv/bin/python3", "venv/bin/python", "venv/bin/python3"]
            if !programRoot.isEmpty, let executable = candidates.map({ root.appendingPathComponent($0).path }).first(where: FileManager.default.isExecutableFile(atPath:)) {
                programPython = executable
            } else {
                programPython = runner == .dspy ? "" : PromptExperimentGEPAWorker.configuredPythonExecutable() ?? ""
            }
        }

        private func saveProgramExample() {
            do {
                let name = runner == .dspy ? "support_router_dspy.py" : "support_router.py"
                let examples = try PromptExperimentGEPAWorker.resolveWorkerURL().deletingLastPathComponent().appendingPathComponent("examples", isDirectory: true)
                let data = try Data(contentsOf: examples.appendingPathComponent(name))
                let panel = NSSavePanel()
                panel.title = "Save a starter evaluator in your project"
                panel.nameFieldStringValue = name
                guard panel.runModal() == .OK, let url = panel.url else { return }
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw PromptExperimentAuthorityError.invalidRequest("Choose a new file name for the starter evaluator.")
                }
                try data.write(to: url, options: .withoutOverwriting)
                programRoot = url.deletingLastPathComponent().path
                programModule = url.path
            } catch { errorMessage = error.localizedDescription }
        }

        private func currentSource() throws -> PromptLabSource {
            if sourceChoice == .pasted {
                return PromptLabSource(kind: .pasted, title: title.isEmpty ? source?.title ?? "Pasted prompt" : title, prompt: pastedPrompt)
            }
            guard let source else { throw PromptExperimentAuthorityError.invalidRequest("Choose a prompt first.") }
            guard sourceChoice == .file else { return source }
            guard let path = source.filePath else {
                throw PromptExperimentAuthorityError.invalidRequest("Choose the source file again.")
            }
            let imported = try PromptLabSource.importFile(url: URL(fileURLWithPath: path), selection: selectedPassage.isEmpty ? nil : selectedPassage)
            guard imported.originalFileSHA256 == source.originalFileSHA256 else {
                throw PromptExperimentAuthorityError.invalidRequest("The source file changed after you selected it. Choose the file again to review the current prompt.")
            }
            return imported
        }

        private var program: PromptLabProgram {
            PromptLabProgram(
                pythonExecutable: programPython, projectRoot: programRoot, modulePath: programModule,
                callable: programCallable, timeoutSeconds: programTimeout,
                moduleSHA256: programLoaded ? inspectedProgram?.moduleSHA256 : nil,
                environmentKeys: programEnvironmentKeys.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                modelRouting: programLoaded ? inspectedProgram?.modelRouting : nil,
                dependencySHA256: programLoaded ? inspectedProgram?.dependencySHA256 : nil
            )
        }

        private func perform(_ label: String, action: @escaping @MainActor () async throws -> Void) {
            isWorking = true
            workLabel = label
            errorMessage = nil
            pendingTask = Task { @MainActor in
                defer { isWorking = false
                    pendingTask = nil
                }
                do { try await action() }
                catch is CancellationError {}
                catch { errorMessage = error.localizedDescription }
            }
        }

        private func prepareExamples() {
            perform("Drafting examples and checks…") {
                let definition = try await service.prepareDefinition(source: currentSource(), goal: goal, exampleInputs: exampleInputs, criteria: criteria, targetSelector: reflectionTarget)
                try Task.checkCancellation()
                examples = definition.examples.map(PromptLabExampleDraft.init(example:))
                criteria = definition.criteria
                generatedExamples = true
                showsExamples = true
            }
        }

        private func loadProgram() {
            perform("Reading the program's experiment description…") {
                let chosenSource = sourceReady ? try currentSource() : nil
                let definition = try await service.describeProgram(program, runner: runner)
                try Task.checkCancellation()
                if chosenSource == nil {
                    if sourceChoice != .pasted {
                        preserveImportedSource = true
                        sourceChoice = .pasted
                    }
                    source = definition.source
                    pastedPrompt = definition.source.prompt
                    selectedPassage = ""
                }
                if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || goal == "Improve the quality of the answers while keeping the prompt concise." {
                    goal = definition.goal
                }
                examples = definition.examples.map(PromptLabExampleDraft.init(example:))
                criteria = definition.criteria
                inspectedProgram = definition.program
                programLoaded = true
                generatedExamples = false
            }
        }

        private func createDraft() {
            perform("Preparing your review…") {
                var request = PromptExperimentCreateRequest()
                request.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
                request.definition = try PromptLabDefinition(
                    source: currentSource(), goal: goal,
                    objective: PromptLabObjective(mode: efficiencyObjective ? .efficiency : .quality, qualityTolerance: qualityTolerance, inputWeight: inputWeight, outputWeight: outputWeight),
                    runner: runner, examples: cases, criteria: criteria, program: runner.usesProgram ? program : nil
                )
                request.executionTarget = executionTarget
                request.reflectionTarget = reflectionTarget
                request.judgeTarget = (runner.usesModelJudge || runner.usesProgram) && !judgeTarget.isEmpty ? judgeTarget : nil
                request.maxEvaluations = maxEvaluations
                request.reflectionMinibatchSize = minibatchSize
                request.promptCharacterCeilingRatio = promptCharacterCeilingRatio == 0 ? nil : promptCharacterCeilingRatio
                request.noiseFloorReplicates = noiseFloorReplicates
                let experiment = try await service.createOrUpdate(request)
                _ = try await service.requestApproval(experimentID: experiment.id, expectedAuthorityDigest: experiment.authorityDigest)
                onCreated(experiment.id)
                dismiss()
            }
        }
    }
#endif
