#if DEBUG
    import SwiftUI

    /// Every authority field the native approval covers, including the cumulative cap.
    struct PromptExperimentAuthorityPanel: View {
        let experiment: PromptExperiment

        var body: some View {
            let authority = experiment.authority
            let settings = authority.settings
            VStack(alignment: .leading, spacing: 6) {
                field("Prompt", authority.promptDisplayName)
                field("Source", authority.sourceDescription)
                if let definition = authority.definition {
                    definitionDetails(definition)
                }
                field(authority.definition?.program?.modelRouting == .project ? "RPCE callbacks" : "Execution model", authority.targets.execution.displayName)
                field("Proposes changes", authority.targets.reflection.displayName)
                field("Judge", authority.targets.judge?.displayName ?? (authority.definition?.runner.usesModelJudge == false ? "Task acceptance checks" : "Exact match (no judge model)"))
                if let judge = authority.targets.judge, judge.judgmentModelIdentity == authority.targets.reflection.judgmentModelIdentity {
                    Text("The same model proposes changes and judges answers. The evaluation may share that model's preferences.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                field("Maximum work", authority.approvalBudgetSummary)
                if let cap = authority.maxProviderInvocations {
                    field("RPCE sessions", "Up to \(cap) provider sessions across all runs, including execution, proposed changes, judging and retries. Agent turns are also bounded within each session.")
                }
                field("Search cap", "\(authority.maxEvaluations) · \(experiment.admissionsUsed) used · \(experiment.remainingEvaluations) remaining")
                field("Calibration", "up to \(authority.calibrationEvaluations) more for the seed baseline (held-out + \(settings.noiseFloorReplicates) noise-floor pass\(settings.noiseFloorReplicates == 1 ? "" : "es")) · \(experiment.calibrationAdmissionsUsed) used" + (authority.definition == nil ? " · matching legacy calibration may be reused" : " · fresh baseline for this experiment"))
                Text("An evaluation may call both the target and a judge. Proposed changes, repairs and retries add provider sessions. The evaluation count is not a dollar cap; the separate provider-session limit applies when shown.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Experiment settings and integrity") {
                    field("Suite", "\(authority.suiteID) · \(authority.suiteSHA256.prefix(12))\(authority.rubricSHA256.map { " · rubric \($0.prefix(12))" } ?? "")")
                    field("Prompt hash", authority.promptResourceSHA256)
                    field("GEPA", "minibatch \(settings.reflectionMinibatchSize) · \(settings.candidateSelectionStrategy) · merge \(settings.useMerge ? "on" : "off") · provider retries \(settings.maxProviderRetries) · judge repairs 1 per evaluation · seed \(settings.randomSeed)")
                    let relativeLimit = authority.definition.map { definition in
                        definition.relativePromptLimit.map { "\(String(format: "%.2f", $0))× the edited prompt" } ?? "No relative prompt length limit"
                    } ?? "\(String(format: "%.2f", settings.promptCharacterCeilingRatio))× the edited prompt"
                    field("Prompt ceiling", relativeLimit + (settings.maxPromptCharacters.map { " · ≤ \($0) chars" } ?? ""))
                    field("Authority digest", experiment.authorityDigest)
                }
            }
        }

        @ViewBuilder
        private func definitionDetails(_ definition: PromptLabDefinition) -> some View {
            field("Goal", definition.goal)
            field("Task runner", definition.runner.labDisplayName)
            let objective = definition.objective
            field(
                "Priority",
                objective.mode == .efficiency
                    ? "Fewer reported tokens; maximum quality decrease \(String(format: "%.3f", objective.qualityTolerance)) · input weight \(objective.inputWeight) · output weight \(objective.outputWeight)"
                    : "Quality first, then prompt and output brevity"
            )
            field("Examples", "\(definition.examples.count(where: { $0.split == .training })) used to improve · \(definition.examples.count(where: { $0.split == .validation })) to compare · \(definition.examples.count(where: { $0.split == .hiddenTest })) final checks")
            if definition.runner == .engineer {
                field("Agent scope", "Fresh fixture for each task · file read/edit tools only · no shell, web or delegation. Private acceptance checks stay outside writable files.")
                field("Agent limits", agentLimits(definition))
            }
            if let program = definition.program {
                field("Model routing", program.modelRouting == .project ? "Project's configured model client and settings; usage must be reported by its evaluator" : "Selected RPCE model for context callbacks; project code may also use its own client")
                field("Local program", "\(program.pythonExecutable) · \(program.modulePath) · \(program.callable)")
                field("Project", program.projectRoot)
                field("Program limit", "\(String(format: "%.0f", program.timeoutSeconds)) seconds per example. The selected code runs with the local interpreter's access and installed dependencies.")
                field("Environment", program.environmentKeys.isEmpty ? "No additional environment variables inherited" : program.environmentKeys.joined(separator: ", "))
                Text("Calls made through the project's own model client are governed by that client, outside the RPCE provider-session cap. Environment values are not saved in the experiment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Prompt, examples and success checks") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(definition.source.prompt).font(.caption.monospaced()).textSelection(.enabled)
                        Divider()
                        Text("Success checks").font(.caption.bold())
                        if let checks = try? PromptSuiteChecklistParser.parse(definition.criteria).checks {
                            ForEach(checks, id: \.id) { Text("• \($0.text)").font(.caption) }
                        } else { Text(definition.criteria).font(.caption).textSelection(.enabled) }
                        ForEach(definition.examples, id: \.id) { example in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(example.id) · \(example.split.labDisplayName)").font(.caption.bold())
                                Text(example.input).font(.caption).textSelection(.enabled)
                                if let reference = example.expectedOutput {
                                    DisclosureGroup("Private reference / acceptance checks") {
                                        Text(reference).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }
                                if let context = example.context {
                                    Text("Frozen files: \(context.files.map(\.path).joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        }

        private func agentLimits(_ definition: PromptLabDefinition) -> String {
            let checks = definition.examples.compactMap { example in
                example.expectedOutput.flatMap { try? PromptExperimentAgentAcceptance.decode($0) }
            }
            guard checks.count == definition.examples.count,
                  let turns = checks.map(\.maximumTurns).max(),
                  let duration = checks.map(\.duration).max()
            else { return "Each task requires explicit acceptance checks with bounded turns and time." }
            return "At most \(turns) turns and \(Int(duration)) seconds per evaluation; individual tasks may have lower limits."
        }

        private func field(_ label: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                Text(value).font(.caption).textSelection(.enabled)
            }
        }
    }

    /// Whether the best candidate's paired improvement exceeds the seed's replicate spread.
    struct PromptExperimentNoiseVerdict: View {
        let noise: PromptExperimentNoiseFloor

        var body: some View {
            let (title, symbol, color): (String, String, Color) = if noise.bestIsBaseline {
                ("Seed stayed best", "equal.circle", .secondary)
            } else if !noise.measured {
                ("Noise not measured", "questionmark.circle", .secondary)
            } else if noise.withinNoise {
                ("Within noise — not a demonstrated improvement", "exclamationmark.triangle", .orange)
            } else {
                ("Exceeds observed baseline spread", "chart.bar", .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                if noise.measured, !noise.bestIsBaseline {
                    Text("Exploratory comparison with a small number of baseline repeats; this is not a statistical confidence test.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let delta = noise.heldOutMeanDelta, delta < 0 {
                    Label("Held-out performance regressed", systemImage: "exclamationmark.triangle")
                        .font(.caption.bold()).foregroundStyle(.orange)
                }
            }
        }
    }

    /// Native approval and run controls. The only place an experiment can be approved.
    struct PromptExperimentApprovalControls: View {
        @ObservedObject var service: PromptExperimentService
        let experiment: PromptExperiment
        @State private var acknowledgedDigest: String?
        @State private var errorMessage: String?
        @State private var isWorking = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                switch experiment.status {
                case .awaitingApproval:
                    Toggle(
                        "I reviewed this experiment and approve \(experiment.authority.approvalBudgetSummary)",
                        isOn: Binding(
                            get: { acknowledgedDigest == experiment.authorityDigest },
                            set: { acknowledgedDigest = $0 ? experiment.authorityDigest : nil }
                        )
                    )
                    .font(.caption)
                    HStack {
                        Button("Approve & Run") {
                            perform { try await service.approve(experimentID: experiment.id, authorityDigest: experiment.authorityDigest) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(acknowledgedDigest != experiment.authorityDigest || isWorking)
                        Button("Decline") {
                            perform { try await service.decline(experimentID: experiment.id) }
                        }
                        .disabled(isWorking)
                    }
                case .running:
                    Button("Cancel run") {
                        perform { _ = try await service.cancel(experimentID: experiment.id) }
                    }
                    .disabled(isWorking || experiment.activeRun?.cancellationRequestedAt != nil)
                case .approved, .completed, .stoppedBudget, .failed, .cancelled:
                    Button(experiment.runs.isEmpty ? "Run" : "Run again (resume within \(experiment.remainingEvaluations) evaluations)") {
                        perform { _ = try await service.run(experimentID: experiment.id) }
                    }
                    .disabled(isWorking)
                case .unapproved:
                    Button("Review for approval") {
                        perform {
                            _ = try await service.requestApproval(
                                experimentID: experiment.id, expectedAuthorityDigest: experiment.authorityDigest
                            )
                        }
                    }
                    .disabled(isWorking)
                case .budgetExhausted:
                    Text("The approved cap is used up. A new experiment is needed for more evaluations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
        }

        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            isWorking = true
            errorMessage = nil
            Task { @MainActor in
                defer { isWorking = false }
                do { try await action() } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    /// Compact state of one run.
    struct PromptExperimentRunSummary: View {
        let run: PromptExperimentRun

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run \(run.ordinal) · \(run.state.rawValue)").font(.caption.bold())
                Text(run.statusText).font(.caption)
                Text("Admissions \(run.admissionsBefore) → \(run.admissionsAfter.map(String.init) ?? "…") · \(run.evaluations.count) scored evaluations · \(run.modelCalls.count) model calls")
                    .font(.caption2).foregroundStyle(.secondary)
                if run.interruptedAdmissionsSettled > 0 {
                    Text("\(run.interruptedAdmissionsSettled) evaluation(s) from an interrupted run were settled as spent.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if run.uncertainRemoteSettlement {
                    Text("The app restarted during this run; provider-side settlement is unknown.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if let result = run.result {
                    Text("Baseline \(result.baselineScore.map { String(format: "%.3f", $0) } ?? "—") · best \(result.bestScore.map { String(format: "%.3f", $0) } ?? "—") (candidate #\(result.bestCandidateIndex.map(String.init) ?? "—")) · \(result.candidates.count) retained")
                        .font(.caption2)
                }
            }
        }
    }
#endif
