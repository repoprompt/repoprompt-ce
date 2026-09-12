#if DEBUG
    import SwiftUI

    /// In-session native authority and status surface for the `prompt_experiment` tool.
    /// The run request can wait here, but only these native actions can approve its exact digest.
    struct PromptExperimentResultCard: View {
        let item: AgentChatItem
        @ObservedObject private var availability = PromptExperimentService.liveAvailability

        var body: some View {
            if let service = availability.service {
                PromptExperimentLiveResultCard(item: item, service: service)
            } else {
                ToolMarkdownExpandedContent(item: item)
            }
        }
    }

    /// Observe the writer itself, not an unread refresh counter.
    private struct PromptExperimentLiveResultCard: View {
        let item: AgentChatItem
        @ObservedObject var service: PromptExperimentService
        @State private var isExpanded = true
        @State private var acknowledgedDigest: String?
        @State private var revisionFeedback = ""
        @State private var showsLibrary = false
        @State private var errorMessage: String?

        private var resultObject: [String: Any]? {
            jsonObject(item.toolResultJSON)
        }

        private var argumentsObject: [String: Any]? {
            jsonObject(item.toolArgsJSON)
        }

        private var experimentID: UUID? {
            ((resultObject?["experiment_id"] ?? argumentsObject?["experiment_id"]) as? String)
                .flatMap(UUID.init(uuidString:))
        }

        private var isRunRequest: Bool {
            (argumentsObject?["op"] as? String)?.lowercased() == "run"
        }

        private func jsonObject(_ raw: String?) -> [String: Any]? {
            guard let raw, let data = raw.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        private var record: PromptExperimentRecord? {
            guard let experimentID else { return nil }
            return service.record(id: experimentID)
        }

        private var phase: PromptExperimentPhase? {
            record?.phase ?? (resultObject?["phase"] as? String).flatMap(PromptExperimentPhase.init(rawValue:))
        }

        private var status: ToolCardStatus {
            if item.toolIsError == true { return .failure }
            switch phase {
            case .awaitingApproval where isRunRequest: return .running
            case .running, .cancelling: return .running
            case .completed: return .success
            case .inconclusive: return .warning
            case .cancelled: return .neutral
            default: return .success
            }
        }

        private var subtitle: String? {
            if let record { return "\(record.phase.rawValue) · \(record.title)" }
            if resultObject?["available_targets"] != nil { return "GEPA capabilities" }
            return phase?.rawValue
        }

        var body: some View {
            ToolCardContainer(
                iconName: "wand.and.stars",
                iconColor: .pink,
                title: "Prompt Experiment",
                detailText: nil,
                subtitle: subtitle,
                status: status,
                timestamp: item.timestamp,
                isExpandable: true,
                isExpanded: $isExpanded
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if let record {
                        Text(record.statusMessage)
                            .font(.subheadline)
                        if let guidance = PromptExperimentGuidance.evaluate(record) {
                            proposalField("Next decision", guidance.explanation)
                        }
                        if let plan = record.currentPlan {
                            if record.phase != .drafting {
                                planSummary(record: record, plan: plan)
                                nativeControls(record: record, plan: plan)
                            }
                        } else if let draft = record.draft {
                            Text("Draft version \(draft.optimisticVersion). Continue this Agent conversation to revise and seal the proposal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let plan = record.currentPlan, let attempt = record.attempts(for: plan).last,
                           let partials = attempt.partialEvaluations
                        {
                            Text("\(partials.count) evaluations saved incrementally. These are trial evidence, not a final winner ranking.")
                                .font(.caption)
                        }
                        if let plan = record.currentPlan, let grades = record.attempts(for: plan).last?.gradingEvidence {
                            Text("\(grades.count) target outputs saved before grading · \(grades.count(where: { $0.ordinal > 1 })) judge repairs · \(grades.count(where: { $0.state != .completed })) awaiting a valid grade. Inspect grading_evidence through lab read.")
                                .font(.caption)
                        }
                        if let plan = record.currentPlan, let calls = record.attempts(for: plan).last?.modelCalls {
                            Text("\(calls.count) model invocations recorded; \(calls.count(where: { $0.promptTokens == nil || $0.completionTokens == nil })) have unavailable or incomplete token usage. Inspect through lab read.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let currentPlan = record.currentPlan,
                           let result = record.attempts(for: currentPlan).last?.optimizationResult
                        {
                            resultSummary(result)
                        }
                    } else {
                        ToolMarkdownExpandedContent(item: item)
                    }
                    if let draft = record?.draft, let spec = draft.optimization {
                        proposalField("Draft goal", spec.objective)
                        proposalField("Next stage", spec.isPreparation ? "Preparation — test and refine" : "GEPA search")
                        if let seed = spec.seedCandidate { proposalField("Starting candidate", seed) }
                        Text("Continue the conversation to revise this draft. Prior sealed plans remain unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Past experiments") { showsLibrary = true }
                }
                .padding(.vertical, 2)
            }
            .sheet(isPresented: $showsLibrary) {
                PromptExperimentStudioView(service: service, controllerSessionID: nil, sourceTabID: nil)
            }
            .onChange(of: record?.currentPlan?.digest) { _, _ in
                acknowledgedDigest = nil
                revisionFeedback = ""
            }
            .alert("Prompt Experiment", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }

        private func proposalField(_ label: String, _ value: String) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption.bold()).foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func planSummary(record: PromptExperimentRecord, plan: PromptExperimentPlan) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                if let spec = plan.optimization {
                    Text(spec.isPreparation ? "Preparation round · revision \(plan.revision)" : "GEPA search · revision \(plan.revision)")
                        .font(.headline)
                    proposalField("What we're improving", spec.objective)
                    proposalField("Starting point", spec.startingPoint?.displayName ?? "Historical plan — starting-point choice not recorded")
                    if !spec.background.isEmpty { proposalField("Context and constraints", spec.background) }
                    proposalField("How we'll test", "\(spec.execution.adapter.rawValue) · \(plan.optimizationTargets?.execution?.displayName ?? "reviewed command")\n\(spec.evaluator.rubric)")
                    let training = spec.examples.count(where: { $0.split == .training })
                    let validation = spec.examples.count(where: { $0.split == .validation })
                    let hidden = spec.examples.count(where: { $0.split == .hiddenTest })
                    proposalField("Examples and budget", "\(training) development · \(validation) validation · \(hidden) hidden test\nUp to \(spec.gepa.maxEvaluations) evaluations · \(spec.gepa.maxWallClockSeconds.map { "historic \($0)s deadline" } ?? "no experiment-wide deadline")")
                    if spec.isPreparation {
                        Text("Only development examples run in this round. Inspect feedback and revise; preparation scores are not held-out quality evidence.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ForEach(Array((spec.preparationCandidates ?? []).enumerated()), id: \.offset) { index, candidate in
                            proposalField(index == 0 ? "Reference candidate" : "Candidate \(index + 1)", candidate)
                        }
                    } else {
                        proposalField("Starting candidate", spec.seedCandidate ?? "No tested seed supplied — GEPA will generate the starting candidate. This is not a comparison against an existing prompt.")
                        proposalField("Search model", plan.optimizationTargets?.reflection.displayName ?? "unavailable")
                    }
                    if let judge = plan.optimizationTargets?.judge { proposalField("Judge model", judge.displayName) }
                    proposalField("Fixed execution instructions", spec.execution.instructions)
                    proposalField("Permissions", "Only the sealed models, examples and project snapshot may be used. Source files are not changed. Applying a candidate is a separate decision.")
                    if let project = spec.projectSnapshot {
                        proposalField("Project snapshot", "\(project.sourceRootPath)\n\(project.includedPaths.joined(separator: "\n"))")
                    }
                    if let command = spec.evaluator.command { proposalField("Sandboxed evaluator command", command) }
                    DisclosureGroup("Technical settings and exact authority") {
                        VStack(alignment: .leading, spacing: 8) {
                            proposalField("Evaluator", "\(spec.evaluator.kind.rawValue) · range \(spec.evaluator.minimumScore)...\(spec.evaluator.maximumScore)")
                            proposalField("Judge recovery", "At most one invalid-JSON repair per evaluation and \(spec.gepa.maxJudgeRetries ?? 0) additional judge calls for the entire run. Saved target output is reused. Authentication, transport, cancellation and storage failures are not automatically retried.")
                            proposalField("Search settings", "Minibatch \(spec.gepa.reflectionMinibatchSize ?? 3) · merge \(spec.gepa.useMerge ?? false ? "on" : "off") · max merge \(spec.gepa.maxMergeInvocations ?? 5) · skip perfect \(spec.gepa.skipPerfectScore ?? true ? "yes" : "no") · seed \(String(spec.gepa.randomSeed))")
                            proposalField("Runtime", spec.gepa.pythonExecutablePath)
                            proposalField("Sealed digest", plan.digest)
                            PromptExperimentSealedPlanDisclosure(plan: plan)
                        }
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }

        @ViewBuilder
        private func nativeControls(record: PromptExperimentRecord, plan: PromptExperimentPlan) -> some View {
            let hasPendingRequest = service.hasPendingRunApproval(
                experimentID: record.id,
                planDigest: plan.digest
            ) == true
            switch record.phase {
            case .awaitingApproval:
                Toggle("I reviewed this proposal and its complete sealed authority", isOn: Binding(
                    get: { acknowledgedDigest == plan.digest },
                    set: { acknowledgedDigest = $0 ? plan.digest : nil }
                ))
                .font(.caption)
                VStack(alignment: .leading, spacing: 10) {
                    Button(plan.optimization?.isPreparation == true ? "Approve & test this round" : "Approve & run GEPA") {
                        perform {
                            try await service.approveAndRun(
                                experimentID: record.id,
                                displayedDigest: plan.digest,
                                source: .nativeUI
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(acknowledgedDigest != plan.digest || !hasPendingRequest)

                    TextField("What would you like to change? Goal, examples, scoring, models…", text: $revisionFeedback, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2 ... 5)
                        .accessibilityLabel("Experiment revision feedback")
                    Button("Revise with this feedback") {
                        perform {
                            try await service.declineRunAndRevise(
                                experimentID: record.id,
                                displayedDigest: plan.digest,
                                source: .nativeUI,
                                feedback: revisionFeedback
                            )
                        }
                    }
                    .disabled(!hasPendingRequest || revisionFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if hasPendingRequest {
                    Text("This Agent tool call is waiting. Approval starts automatically and wakes the conversation with running status; requesting changes returns the new draft.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The owning Agent session must call run with this exact digest before native approval is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .approved:
                Text("Approval is recorded. The owning Agent session can call run with this exact digest to resume safely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .running, .cancelling:
                Button("Stop after provider settlement", role: .destructive) {
                    perform { try await service.cancel(experimentID: record.id) }
                }
                .disabled(record.phase == .cancelling)
            case .completed, .inconclusive, .cancelled:
                if plan.optimization == nil {
                    Button("Next revision") {
                        perform { try await service.startNextRevision(experimentID: record.id) }
                    }
                } else {
                    HStack {
                        Button("Build on this result") {
                            perform {
                                try await service.startNextRevision(
                                    experimentID: record.id,
                                    revisionMode: .continueBest
                                )
                            }
                        }
                        Button("Run again") {
                            perform {
                                try await service.startNextRevision(
                                    experimentID: record.id,
                                    revisionMode: .repeatCurrentSeed
                                )
                            }
                        }
                        Button("Clone draft") {
                            perform { _ = try await service.cloneExperiment(experimentID: record.id) }
                        }
                    }
                }
            case .drafting:
                EmptyView()
            }
        }

        private func resultSummary(_ result: PromptExperimentOptimizationResult) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.assessment).font(.headline)
                Text("Best measured score \(result.bestScore.map { String($0) } ?? "unavailable") · starting/reference score \(result.baselineScore.map { String($0) } ?? "unavailable")")
                    .font(.subheadline)
                DisclosureGroup("Per-example feedback") {
                    ForEach(result.evaluations) { evaluation in
                        let candidateLabel = evaluation.candidateIndex < 0 ? "Unretained proposal" : "Candidate \(evaluation.candidateIndex + 1)"
                        proposalField("\(candidateLabel) · \(evaluation.exampleID) · \(evaluation.split.rawValue)", "Score \(evaluation.score.map { String($0) } ?? "unavailable"): \(evaluation.feedback)")
                    }
                }
                Text("\(result.totalEvaluations) evaluations · \(gepaWallTime(result)) · usage \(result.proposerUsage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Worker artifacts: \(gepaRunDirectory(result))")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                ForEach(result.candidates.filter(\.isBest)) { candidate in
                    Text(candidate.candidatePreview)
                        .font(.caption)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }

        private func gepaWallTime(_ result: PromptExperimentOptimizationResult) -> String {
            result.wallTimeSeconds.map { String(format: "%.3f s", $0) } ?? "wall time unavailable"
        }

        private func gepaRunDirectory(_ result: PromptExperimentOptimizationResult) -> String {
            result.runDirectoryRelativePath ?? "unavailable"
        }

        private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
            Task {
                do { try await operation() } catch { errorMessage = error.localizedDescription }
            }
        }
    }
#endif
