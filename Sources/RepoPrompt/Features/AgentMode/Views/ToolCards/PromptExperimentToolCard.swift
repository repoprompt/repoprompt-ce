#if DEBUG
    import Combine
    import SwiftUI

    /// In-session native authority and status surface for the `prompt_experiment` tool.
    /// Agent tool calls may shape/query records, but these buttons are deliberately local UI actions.
    struct PromptExperimentResultCard: View {
        let item: AgentChatItem
        @State private var isExpanded = true
        @State private var acknowledgedDigest: String?
        @State private var serviceRevision = 0
        @State private var showsLibrary = false
        @State private var errorMessage: String?

        private var resultObject: [String: Any]? {
            guard let raw = item.toolResultJSON,
                  let data = raw.data(using: .utf8)
            else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        private var experimentID: UUID? {
            (resultObject?["experiment_id"] as? String).flatMap(UUID.init(uuidString:))
        }

        private var service: PromptExperimentService? {
            PromptExperimentService.currentLiveInstance
        }

        private var record: PromptExperimentRecord? {
            guard let experimentID else { return nil }
            return service?.record(id: experimentID)
        }

        private var serviceChanges: AnyPublisher<Void, Never> {
            service?.objectWillChange.eraseToAnyPublisher()
                ?? Empty<Void, Never>().eraseToAnyPublisher()
        }

        private var phase: PromptExperimentPhase? {
            record?.phase ?? (resultObject?["phase"] as? String).flatMap(PromptExperimentPhase.init(rawValue:))
        }

        private var status: ToolCardStatus {
            if item.toolIsError == true { return .failure }
            switch phase {
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
                        if let plan = record.currentPlan {
                            planSummary(record: record, plan: plan)
                            nativeControls(record: record, plan: plan)
                        } else if let draft = record.draft {
                            Text("Draft version \(draft.optimisticVersion). Continue this Agent conversation to revise and seal the proposal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let currentPlan = record.currentPlan,
                           let result = record.attempts(for: currentPlan).last?.optimizationResult
                        {
                            resultSummary(result)
                        }
                    } else {
                        ToolMarkdownExpandedContent(item: item)
                    }
                    HStack {
                        Button("Past experiments") { showsLibrary = true }
                        if service == nil {
                            Text("Native experiment service unavailable in this window")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onReceive(serviceChanges) {
                serviceRevision &+= 1
            }
            .sheet(isPresented: $showsLibrary) {
                if let service {
                    PromptExperimentStudioView(service: service, controllerSessionID: nil, sourceTabID: nil)
                } else {
                    ContentUnavailableView("Prompt Experiments Unavailable", systemImage: "exclamationmark.triangle")
                        .frame(width: 480, height: 320)
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
        }

        private func planSummary(record: PromptExperimentRecord, plan: PromptExperimentPlan) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Revision \(plan.revision) · \(plan.optimization?.gepa.engine.uppercased() ?? "legacy comparison")")
                    .font(.caption.bold())
                Text(plan.digest)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if let optimization = plan.optimization {
                    Text("\(optimization.examples.count) reviewed examples · \(optimization.gepa.maxEvaluations) evaluations · \(optimization.gepa.maxWallClockSeconds)s · reflection \(plan.optimizationTargets?.reflection.displayName ?? "unavailable")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        @ViewBuilder
        private func nativeControls(record: PromptExperimentRecord, plan: PromptExperimentPlan) -> some View {
            switch record.phase {
            case .awaitingApproval:
                Toggle("I reviewed this exact digest", isOn: Binding(
                    get: { acknowledgedDigest == plan.digest },
                    set: { acknowledgedDigest = $0 ? plan.digest : nil }
                ))
                .font(.caption)
                Button("Approve exact sealed proposal") {
                    perform {
                        try await service?.approve(
                            experimentID: record.id,
                            displayedDigest: plan.digest,
                            source: .nativeUI
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(acknowledgedDigest != plan.digest)
            case .approved:
                Button("Run approved GEPA search") {
                    perform { try await service?.run(experimentID: record.id) }
                }
                .buttonStyle(.borderedProminent)
            case .running, .cancelling:
                Button("Stop after provider settlement", role: .destructive) {
                    perform { try await service?.cancel(experimentID: record.id) }
                }
                .disabled(record.phase == .cancelling)
            case .completed, .inconclusive, .cancelled:
                Button(plan.optimization == nil ? "Next revision" : "Continue from best candidate") {
                    perform { try await service?.startNextRevision(experimentID: record.id) }
                }
            case .drafting:
                EmptyView()
            }
        }

        private func resultSummary(_ result: PromptExperimentOptimizationResult) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Best \(result.bestScore.map { String($0) } ?? "unavailable") vs baseline \(result.baselineScore.map { String($0) } ?? "unavailable")")
                    .font(.headline)
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
