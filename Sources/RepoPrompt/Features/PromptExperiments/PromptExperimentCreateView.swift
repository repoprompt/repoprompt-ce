#if DEBUG
    import SwiftUI

    /// Native entry point into the same typed draft and approval flow used by MCP. Creating
    /// a draft never approves spend or starts a provider call.
    struct PromptExperimentCreateView: View {
        @ObservedObject var service: PromptExperimentService
        let onCreated: (UUID) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var prompts: [PromptExperimentPromptOption] = []
        @State private var targets: [PromptExperimentResolvedTarget] = []
        @State private var promptID = BuiltInPromptID.oraclePlan.rawValue
        @State private var title = ""
        @State private var executionTarget = ""
        @State private var reflectionTarget = ""
        @State private var judgeTarget = ""
        @State private var maxEvaluations = 25
        @State private var minibatchSize = 2
        @State private var noiseFloorReplicates = 2
        @State private var promptCharacterCeilingRatio = 1.0
        @State private var showsAdvanced = false
        @State private var isWorking = false
        @State private var errorMessage: String?

        private var selection: PromptExperimentPromptOption? {
            prompts.first { $0.id == promptID }
        }

        private var needsJudge: Bool {
            selection?.suite?.grader.kind == .modelJudge
        }

        private var judgeMatchesReflection: Bool {
            guard needsJudge,
                  let judge = targets.first(where: { $0.selector == judgeTarget }),
                  let reflection = targets.first(where: { $0.selector == reflectionTarget })
            else { return false }
            return judge.judgmentModelIdentity == reflection.judgmentModelIdentity
        }

        private var minimumEvaluations: Int {
            guard let suite = selection?.suite else { return 1 }
            return PromptExperimentBudgetLedger.minimumApprovableEvaluations(
                cases: suite.cases, reflectionMinibatchSize: minibatchSize
            )
        }

        private var calibrationEvaluations: Int {
            guard let suite = selection?.suite else { return 0 }
            return PromptExperimentBudgetLedger.calibrationEvaluations(cases: suite.cases, replicates: noiseFloorReplicates)
        }

        private var canCreate: Bool {
            service.isLoaded && service.loadError == nil && selection?.suite != nil
                && !executionTarget.isEmpty && !reflectionTarget.isEmpty
                && (!needsJudge || !judgeTarget.isEmpty) && !judgeMatchesReflection
                && maxEvaluations >= minimumEvaluations && maxEvaluations <= 10000 && !isWorking
        }

        var body: some View {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New Prompt Experiment").font(.title2.bold())
                    Text("Choose a prompt, compare candidates on saved examples, then review the results and source diff.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                Form {
                    promptSection
                    modelSection
                    budgetSection
                    advancedSection
                    if let errorMessage = errorMessage ?? service.loadError {
                        Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Text("Reviewing a draft makes no model calls.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isWorking)
                    Button(isWorking ? "Creating…" : "Review Experiment") { createDraft() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                }
                .padding(16)
            }
            .frame(width: 680, height: 720)
            .interactiveDismissDisabled(isWorking)
            .task {
                await service.load()
                refreshOptions()
            }
        }

        private var promptSection: some View {
            Section("1. Choose a built-in prompt") {
                Picker("Prompt", selection: $promptID) {
                    ForEach(prompts) { prompt in
                        Text(prompt.title + (prompt.suite == nil ? " · unavailable" : "")).tag(prompt.id)
                    }
                }
                TextField("Experiment name (optional)", text: $title)
                if let suite = selection?.suite {
                    Text("\(suite.cases(in: .training).count) training · \(suite.cases(in: .validation).count) validation · \(suite.cases(in: .hiddenTest).count) held-out examples")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The saved rubric defines success. These small starter suites help compare candidates; broader testing is needed before shipping a default.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let reason = selection?.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
                Text("This lab supports the four built-in Oracle prompts. Project prompts and tool-using Engineer agents need an evaluation adapter and are not supported here yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        private var modelSection: some View {
            Section("2. Choose the model to improve") {
                modelPicker("Execution model", selection: $executionTarget)
                Text("This model answers each example using the candidate prompt. Reflection proposes edits; the judge scores the answers.")
                    .font(.caption).foregroundStyle(.secondary)
                if targets.isEmpty {
                    Text("Connect a supported Claude-compatible provider in Settings → CLI Providers. This lab requires prompt-only calls; connected Codex and ACP targets are not supported yet.")
                        .font(.caption).foregroundStyle(.orange)
                } else if reflectionTarget.isEmpty || (needsJudge && judgeTarget.isEmpty) {
                    Text("Model-judged suites need two distinct models for reflection and judging. Connect another model in Settings → CLI Providers if needed, then choose the models under Advanced settings.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if judgeMatchesReflection {
                    Text("Choose a different judge under Advanced settings. Changing effort on the same model does not make it an independent judge.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Refresh available prompts and models") { refreshOptions() }
                    .font(.caption)
            }
        }

        private var budgetSection: some View {
            Section("3. Set a small budget") {
                HStack {
                    Text("Search budget")
                    Spacer()
                    Button("Small · 25") { maxEvaluations = max(25, minimumEvaluations) }
                    Button("Medium · 50") { maxEvaluations = max(50, minimumEvaluations) }
                }
                TextField("Search evaluations", value: $maxEvaluations, format: .number)
                if (1 ... 10000).contains(maxEvaluations) {
                    Text("Up to \(maxEvaluations + calibrationEvaluations) evaluations: \(maxEvaluations) search + \(calibrationEvaluations) baseline calibration.")
                        .font(.callout.bold())
                }
                Text("Calibration is reused when an identical baseline is cached. An evaluation runs one example and may also call a judge. Reflection, repairs and retries add model calls, so this is not a model-call or dollar cap.")
                    .font(.caption).foregroundStyle(.secondary)
                if maxEvaluations < minimumEvaluations || maxEvaluations > 10000 {
                    Text("Choose \(minimumEvaluations)–10000 search evaluations. The minimum includes seed validation, one complete proposal cycle and held-out reporting.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }

        private var advancedSection: some View {
            Section {
                DisclosureGroup("Advanced settings", isExpanded: $showsAdvanced) {
                    modelPicker("Reflection model", selection: $reflectionTarget)
                    if needsJudge { modelPicker("Judge model", selection: $judgeTarget) }
                    Stepper("Examples per proposal: \(minibatchSize)", value: $minibatchSize, in: 1 ... 100)
                    Stepper("Extra baseline passes: \(noiseFloorReplicates)", value: $noiseFloorReplicates, in: 0 ... 5)
                    Picker("Prompt length limit", selection: $promptCharacterCeilingRatio) {
                        Text("Same length as parent").tag(1.0)
                        Text("Up to 1.5× the parent").tag(1.5)
                        Text("Up to 2× the parent").tag(2.0)
                    }
                    Text("Shorter prompts break quality ties. Extra baseline passes estimate score variability; disabling them leaves that comparison unmeasured.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        private func modelPicker(_ label: String, selection: Binding<String>) -> some View {
            Picker(label, selection: selection) {
                Text("Choose a model").tag("")
                ForEach(targets, id: \.selector) { target in
                    Text(target.selector.contains(":") ? target.displayName : "\(target.displayName) (\(target.selector))")
                        .tag(target.selector)
                }
            }
        }

        private func refreshOptions() {
            prompts = service.promptOptions()
            targets = service.availableTargets()
            let defaults = service.targetDefaults()
            if !targets.contains(where: { $0.selector == executionTarget }) { executionTarget = defaults.execution?.selector ?? "" }
            if !targets.contains(where: { $0.selector == reflectionTarget }) { reflectionTarget = defaults.reflection?.selector ?? "" }
            if !targets.contains(where: { $0.selector == judgeTarget }) { judgeTarget = defaults.judge?.selector ?? "" }
        }

        private func createDraft() {
            isWorking = true
            errorMessage = nil
            Task { @MainActor in
                defer { isWorking = false }
                do {
                    let experiment = try await service.createOrUpdate(PromptExperimentCreateRequest(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title,
                        promptID: promptID,
                        executionTarget: executionTarget,
                        reflectionTarget: reflectionTarget,
                        judgeTarget: needsJudge ? judgeTarget : nil,
                        maxEvaluations: maxEvaluations,
                        reflectionMinibatchSize: minibatchSize,
                        promptCharacterCeilingRatio: promptCharacterCeilingRatio,
                        noiseFloorReplicates: noiseFloorReplicates
                    ))
                    onCreated(experiment.id)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
#endif
