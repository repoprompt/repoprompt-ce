#if DEBUG
    import SwiftUI

    /// Every authority field the native approval covers, including the cumulative cap.
    struct PromptExperimentAuthorityPanel: View {
        let experiment: PromptExperiment

        var body: some View {
            let authority = experiment.authority
            let settings = authority.settings
            VStack(alignment: .leading, spacing: 6) {
                field("Built-in prompt", "\(authority.promptID.rawValue) · resource \(authority.promptResourceSHA256.prefix(12))")
                field("Suite", "\(authority.suiteID) · \(authority.suiteSHA256.prefix(12))\(authority.rubricSHA256.map { " · rubric \($0.prefix(12))" } ?? "")")
                field("Execution model", authority.targets.execution.displayName)
                field("Reflection model", authority.targets.reflection.displayName)
                field("Judge", authority.targets.judge?.displayName ?? "Exact match (no judge model)")
                field("Evaluation cap", "\(authority.maxEvaluations) total · \(experiment.admissionsUsed) used · \(experiment.remainingEvaluations) remaining")
                field("Calibration", "up to \(authority.calibrationEvaluations) more for the seed baseline (held-out + \(settings.noiseFloorReplicates) noise-floor pass\(settings.noiseFloorReplicates == 1 ? "" : "es")) · \(experiment.calibrationAdmissionsUsed) used · none when the cross-experiment cache already has it")
                field("GEPA", "minibatch \(settings.reflectionMinibatchSize) · \(settings.candidateSelectionStrategy) · merge \(settings.useMerge ? "on" : "off") · provider retries \(settings.maxProviderRetries) · judge repairs 1 per evaluation · seed \(settings.randomSeed)")
                field("Objectives", "quality first, then brevity (prompt and answer length) · proposals ≤ \(String(format: "%.2f", settings.promptCharacterCeilingRatio))× the edited prompt\(settings.maxPromptCharacters.map { " and ≤ \($0) chars" } ?? "")")
                field("Authority digest", String(experiment.authorityDigest.prefix(24)))
            }
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
                ("Beyond noise", "checkmark.seal", .green)
            }
            Label(title, systemImage: symbol)
                .font(.caption.bold())
                .foregroundStyle(color)
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
                        "I reviewed this exact authority and approve up to \(experiment.authority.maxEvaluations) evaluations",
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
                    Text("Not approved. The agent or MCP client must request approval before this card can approve it.")
                        .font(.caption).foregroundStyle(.secondary)
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
