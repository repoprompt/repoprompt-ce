#if DEBUG
    import AppKit
    import SwiftUI

    struct PromptExperimentStudioView: View {
        @ObservedObject var service: PromptExperimentService
        let controllerSessionID: UUID?
        let sourceTabID: UUID?
        @Environment(\.dismiss) private var dismiss
        @State private var selectedExperimentID: UUID?
        @State private var errorMessage: String?

        private var linkedRecords: [PromptExperimentRecord] {
            guard let controllerSessionID else { return service.records }
            return service.records.filter { $0.controllerSessionID == controllerSessionID }
        }

        var body: some View {
            NavigationSplitView {
                List(selection: $selectedExperimentID) {
                    if let loadError = service.loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if !service.isLoaded {
                        ProgressView("Loading durable experiments…")
                    }
                    if let projectionError = service.projectionError {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(projectionError, systemImage: "doc.badge.gearshape")
                                .foregroundStyle(.orange)
                            Button("Rebuild readable views") {
                                Task { try? await service.rebuildReadableViews() }
                            }
                            .font(.caption)
                        }
                    }
                    ForEach(linkedRecords) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).lineLimit(1)
                            Text(record.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(record.id)
                    }
                }
                .navigationTitle("Prompt Experiments")
                .toolbar {
                    ToolbarItem {
                        Button {
                            createExperiment()
                        } label: {
                            Label("New Experiment", systemImage: "plus")
                        }
                        .disabled(controllerSessionID == nil || sourceTabID == nil || !service.isLoaded || service.loadError != nil)
                    }
                }
            } detail: {
                if let selectedExperimentID,
                   let record = service.record(id: selectedExperimentID)
                {
                    PromptExperimentRecordView(service: service, record: record)
                        .id("\(record.id.uuidString)-\(record.updatedAt.timeIntervalSinceReferenceDate)")
                } else {
                    ContentUnavailableView {
                        Label("No Prompt Experiment Selected", systemImage: "flask")
                    } description: {
                        if controllerSessionID == nil {
                            Text("Start or select a persisted Agent session first. Experiments are linked to that session.")
                        } else {
                            Text("Start the Prompt Experiment workflow so its Agent session can shape and seal a real GEPA optimization proposal.")
                        }
                    }
                }
            }
            .frame(minWidth: 920, minHeight: 650)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Prompt Experiment", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if selectedExperimentID == nil { selectedExperimentID = linkedRecords.first?.id }
            }
        }

        private func createExperiment() {
            guard let controllerSessionID, let sourceTabID else { return }
            Task {
                do {
                    selectedExperimentID = try await service.createOptimizationExperiment(
                        controllerSessionID: controllerSessionID,
                        sourceTabID: sourceTabID
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private struct PromptExperimentRecordView: View {
        @ObservedObject var service: PromptExperimentService
        let record: PromptExperimentRecord
        @State private var acknowledgedDigest: String?
        @State private var errorMessage: String?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title).font(.title2.bold())
                            Text("Agent session \(record.controllerSessionID.uuidString.lowercased())")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        phaseBadge
                    }
                    statusPanel
                    if let draft = record.draft {
                        GroupBox("Agent-owned proposal draft") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Draft version \(draft.optimisticVersion) · revision \(draft.revision)")
                                    .font(.subheadline.bold())
                                Text("Continue the linked Agent conversation to revise the objective, reviewed examples, evaluator, targets, and budget. Native controls intentionally do not duplicate that schema.")
                                    .foregroundStyle(.secondary)
                                if let optimization = draft.optimization {
                                    LabeledContent("Objective", value: optimization.objective.isEmpty ? "Not yet proposed" : optimization.objective)
                                    LabeledContent("Reviewed examples", value: "\(optimization.examples.count)")
                                    LabeledContent(
                                        "Budget",
                                        value: optimization.gepa.maxWallClockSeconds.map {
                                            "\(optimization.gepa.maxEvaluations) evaluations · historic \($0)s deadline"
                                        } ?? "\(optimization.gepa.maxEvaluations) evaluations · no experiment deadline"
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                    }
                    if let plan = record.currentPlan {
                        planPanel(plan)
                        revisionHistoryPanel(currentPlan: plan)
                        controls(plan)
                    }
                    attemptsPanel
                }
                .padding(24)
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

        private var phaseBadge: some View {
            Text(record.phase.rawValue)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.12), in: Capsule())
        }

        private var statusPanel: some View {
            GroupBox("Status") {
                Text(record.statusMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }

        private func planPanel(_ plan: PromptExperimentPlan) -> some View {
            GroupBox("Immutable plan revision \(plan.revision)") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Target", value: plan.resolvedTarget.displayName)
                    if let optimization = plan.optimization {
                        LabeledContent("Engine", value: "Upstream GEPA \(PromptExperimentGEPAConfiguration.packageVersion)")
                        LabeledContent(
                            "Budget",
                            value: optimization.gepa.maxWallClockSeconds.map {
                                "\(optimization.gepa.maxEvaluations) evaluations · historic \($0)s deadline"
                            } ?? "\(optimization.gepa.maxEvaluations) evaluations · no experiment deadline"
                        )
                        LabeledContent("Objective", value: optimization.objective)
                        LabeledContent("Background", value: optimization.background.isEmpty ? "None" : optimization.background)
                        LabeledContent("Seed candidate", value: optimization.seedCandidate ?? "GEPA proposes from objective and evidence")
                        LabeledContent("Reflection", value: plan.optimizationTargets?.reflection.displayName ?? "unavailable")
                        LabeledContent("Execution", value: "\(optimization.execution.adapter.rawValue) · \(plan.optimizationTargets?.execution?.displayName ?? "no model target")")
                        LabeledContent("Judge", value: plan.optimizationTargets?.judge?.displayName ?? "not used")
                        LabeledContent("Examples", value: optimization.examples.map { "\($0.id)=\($0.split.rawValue)" }.joined(separator: ", "))
                        LabeledContent("Evaluator", value: "\(optimization.evaluator.kind.rawValue) · \(optimization.evaluator.minimumScore)...\(optimization.evaluator.maximumScore)")
                        LabeledContent("Rubric", value: optimization.evaluator.rubric)
                        LabeledContent("Command", value: optimization.evaluator.command ?? "not used")
                        LabeledContent("Project root", value: optimization.projectSnapshot?.sourceRootPath ?? "none")
                        LabeledContent("Reviewed paths", value: optimization.projectSnapshot?.includedPaths.joined(separator: ", ") ?? "none")
                        LabeledContent("GEPA options", value: "minibatch \(optimization.gepa.reflectionMinibatchSize ?? 1) · merge \((optimization.gepa.useMerge ?? false) ? "on" : "off") · max merge \(optimization.gepa.maxMergeInvocations ?? 0) · skip perfect \((optimization.gepa.skipPerfectScore ?? true) ? "yes" : "no") · seed \(optimization.gepa.randomSeed)")
                        LabeledContent("Python", value: optimization.gepa.pythonExecutablePath)
                        LabeledContent("Environment", value: "App-owned reviewed dataset; command code Seatbelt-confined")
                        Text("Permissions: connected model roles are prompt-only. Commands can read the immutable project copy and write only app-owned scratch. The source workspace and hidden expected outputs are unavailable to proposers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Schedule", value: "\(plan.trials.count) serial trials")
                        LabeledContent("Environment", value: "Legacy synthetic fixture")
                    }
                    Text(plan.digest)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    PromptExperimentSealedPlanDisclosure(plan: plan)
                    DisclosureGroup("Isolation and pilot limitations") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(plan.environment.captureLimitations + plan.limitations, id: \.self) { limitation in
                                Text("• \(limitation)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }

        @ViewBuilder
        private func revisionHistoryPanel(currentPlan: PromptExperimentPlan) -> some View {
            let priorPlans = record.plans.filter { $0.id != currentPlan.id }
            if !priorPlans.isEmpty {
                GroupBox("Prior immutable revisions") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(priorPlans) { plan in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Revision \(plan.revision) · \(plan.trials.count) trials")
                                    .font(.subheadline.bold())
                                Text(plan.digest)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
        }

        @ViewBuilder
        private func controls(_ plan: PromptExperimentPlan) -> some View {
            let hasPendingRequest = service.hasPendingRunApproval(
                experimentID: record.id,
                planDigest: plan.digest
            )
            if record.phase == .awaitingApproval {
                GroupBox("Native approval") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("I reviewed every sealed field for the exact digest displayed above", isOn: Binding(
                            get: { acknowledgedDigest == plan.digest },
                            set: { acknowledgedDigest = $0 ? plan.digest : nil }
                        ))
                        HStack {
                            Button("Approve & Run exact proposal") {
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

                            Button("Request changes") {
                                perform {
                                    try await service.declineRunAndRevise(
                                        experimentID: record.id,
                                        displayedDigest: plan.digest,
                                        source: .nativeUI
                                    )
                                }
                            }
                            .disabled(!hasPendingRequest)
                        }
                        Text(
                            hasPendingRequest
                                ? "Only this native action can approve. Approval starts the exact sealed run automatically; requesting changes preserves the plan and opens a new draft revision."
                                : "Return to the owning Agent session and call run with this exact digest to open native approval."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            } else if record.phase == .approved {
                Text("Approval is recorded. Resume from the owning Agent session with this exact digest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if record.phase == .running || record.phase == .cancelling {
                Button("Request cancellation", role: .destructive) {
                    perform { try await service.cancel(experimentID: record.id) }
                }
                .disabled(record.phase == .cancelling)
            }

            if record.phase == .completed || record.phase == .inconclusive || record.phase == .cancelled {
                HStack {
                    if plan.optimization == nil {
                        Button("Next revision") {
                            perform { try await service.startNextRevision(experimentID: record.id) }
                        }
                    } else {
                        Button("Continue best") {
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
                        Button("Clone as draft") {
                            perform { _ = try await service.cloneExperiment(experimentID: record.id) }
                        }
                    }
                    Button("Reveal readable results") {
                        perform {
                            let url = try await service.recordDirectoryURL(experimentID: record.id)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
        }

        private var attemptsPanel: some View {
            GroupBox("Results and evidence") {
                if record.attempts.isEmpty {
                    Text("No trial has been admitted.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        let sortedAttempts = record.attempts.sorted {
                            ($0.planRevision ?? 0, $0.ordinal) < ($1.planRevision ?? 0, $1.ordinal)
                        }
                        ForEach(sortedAttempts) { attempt in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Revision \(attempt.planRevision ?? 0) · \(attempt.ordinal). \(attempt.condition.displayName) · repetition \(attempt.repetition)")
                                        .font(.headline)
                                    Spacer()
                                    Text(attempt.status.rawValue).font(.caption.monospaced())
                                }
                                Text(attempt.statusText).font(.subheadline)
                                if let runtime = attempt.runtimeLink {
                                    Text("tab \(runtime.tabID?.uuidString ?? "pending") · run \(runtime.runID?.uuidString ?? "pending")")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if let diagnostics = attempt.diagnostics {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Diagnostics · \(diagnostics.processObservation.rawValue)")
                                            .font(.caption.bold())
                                        Text("Last event \(diagnostics.lastObservedEvent) · \(diagnostics.lastObservedAt.formatted())")
                                            .font(.caption)
                                        Text("PID \(diagnostics.workerPID.map(String.init) ?? "unavailable") is historical observation only; current liveness is not inferred.")
                                            .font(.caption)
                                        Text("stderr \(diagnostics.stderrLogRelativePath ?? "unavailable") · protocol \(diagnostics.stdoutProtocolLogRelativePath ?? "unavailable")")
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                if let handoff = attempt.committedHandoff {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Committed handoff").font(.caption.bold())
                                        Text(handoff.promptPreview)
                                            .font(.caption)
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                        Text("Prompt SHA-256: \(handoff.promptEvidence.sha256)")
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                        Text("Final selection revision \(handoff.selectionRevision) · \(selectionSummary(handoff.selection))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                        Text("Agent output copied as prompt: \(handoff.usedAgentOutputAsPrompt ? "yes" : "no")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else if let reason = attempt.handoffUnavailableReason {
                                    Label("Committed handoff unavailable/inconclusive: \(reason)", systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else if let preview = attempt.outputPreview, !preview.isEmpty {
                                    Text("Legacy unclassified output: \(preview)")
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                if let assistant = attempt.assistantOutputPreview, !assistant.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Assistant runtime output (not the handoff)").font(.caption.bold())
                                        Text(assistant)
                                            .font(.caption)
                                            .textSelection(.enabled)
                                    }
                                }
                                if let result = attempt.optimizationResult {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("Upstream GEPA \(result.upstreamRevision.prefix(12))")
                                                .font(.caption.bold())
                                            Spacer()
                                            Text("\(result.totalEvaluations) evaluations")
                                                .font(.caption.monospaced())
                                        }
                                        Text("Best \(result.bestScore.map { String($0) } ?? "unavailable") vs baseline \(result.baselineScore.map { String($0) } ?? "unavailable")")
                                            .font(.headline)
                                        ForEach(result.candidates.sorted { ($0.aggregateScore ?? -.infinity) > ($1.aggregateScore ?? -.infinity) }) { candidate in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("Candidate #\(candidate.index)\(candidate.isBaseline ? " · baseline" : "")\(candidate.isBest ? " · best" : "") · score \(candidate.aggregateScore.map { String($0) } ?? "unavailable")")
                                                    .font(.subheadline.bold())
                                                Text(candidate.candidatePreview)
                                                    .font(.caption)
                                                    .lineLimit(8)
                                                    .textSelection(.enabled)
                                                let feedback = result.evaluations.filter { $0.candidateIndex == candidate.index }
                                                ForEach(feedback.prefix(3)) { evaluation in
                                                    Text("\(evaluation.exampleID): \(evaluation.feedback)")
                                                        .font(.caption)
                                                        .foregroundStyle(evaluation.failureKind == .infrastructure ? .red : .secondary)
                                                }
                                            }
                                            .padding(8)
                                            .background(candidate.isBest ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                        }
                                        Text("Proposer usage: \(result.proposerUsage)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("GEPA wall time: \(gepaWallTime(result))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("Worker artifacts: \(gepaRunDirectory(result))")
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let submittedAt = attempt.submittedAt, let settledAt = attempt.settledAt {
                                    Text("Elapsed \(settledAt.timeIntervalSince(submittedAt), format: .number.precision(.fractionLength(3))) s · provider token usage unavailable from completion contract")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Elapsed and provider token usage unavailable")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 10)
                            if attempt.id != sortedAttempts.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }

        private func gepaWallTime(_ result: PromptExperimentOptimizationResult) -> String {
            result.wallTimeSeconds.map { String(format: "%.3f s", $0) } ?? "unavailable"
        }

        private func gepaRunDirectory(_ result: PromptExperimentOptimizationResult) -> String {
            result.runDirectoryRelativePath ?? "unavailable"
        }

        private func selectionSummary(_ selection: StoredSelection) -> String {
            let paths = selection.selectedPaths.isEmpty
                ? "no selected paths"
                : selection.selectedPaths.joined(separator: ", ")
            let slices = selection.slices.keys.sorted().map { path in
                let ranges = selection.slices[path, default: []]
                    .map { "\($0.start)-\($0.end)" }
                    .joined(separator: ",")
                return "\(path):\(ranges)"
            }.joined(separator: "; ")
            return slices.isEmpty ? paths : "\(paths); slices \(slices)"
        }

        private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
            Task {
                do { try await operation() } catch { errorMessage = error.localizedDescription }
            }
        }
    }
#endif
