#if DEBUG
    import SwiftUI

    /// In-session status and native approval surface for the `prompt_experiment` tool.
    /// Only the native controls here (or in the Studio) can approve an experiment.
    struct PromptExperimentResultCard: View {
        let item: AgentChatItem
        @EnvironmentObject private var service: PromptExperimentService
        @State private var isExpanded = true
        @State private var showsStudio = false
        @State private var reviewedProposal: PromptExperimentProposalSelection?

        private var experimentID: UUID? {
            resultID("experiment_id")
        }

        private var preparationID: UUID? {
            resultID("preparation_id")
        }

        private func resultID(_ key: String) -> UUID? {
            for raw in [item.toolResultJSON, item.toolArgsJSON] {
                guard let raw, let data = raw.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let id = (object[key] as? String).flatMap(UUID.init(uuidString:)) { return id }
            }
            return nil
        }

        private var experiment: PromptExperiment? {
            experimentID.flatMap(service.experiment(id:))
        }

        private var status: ToolCardStatus {
            if item.toolIsError == true { return .failure }
            switch experiment?.status {
            case .awaitingApproval, .running: return .running
            case .failed: return .warning
            case .cancelled, .budgetExhausted: return .neutral
            default: return .success
            }
        }

        var body: some View {
            Group {
                if let preparationID {
                    PromptLabPreparationToolCard(
                        item: item, preparations: service.preparationApprovals,
                        preparationID: preparationID, isExpanded: $isExpanded
                    ) { showsStudio = true }
                } else {
                    experimentCard
                }
            }
            .task { await service.load() }
            .sheet(isPresented: $showsStudio) {
                PromptExperimentStudioView(service: service, initialSelection: preparationID ?? experimentID)
            }
            .sheet(item: $reviewedProposal) { selection in
                if let experimentID {
                    PromptExperimentProposalReviewView(service: service, experimentID: experimentID, proposalID: selection.id)
                }
            }
        }

        private var experimentCard: some View {
            ToolCardContainer(
                iconName: "wand.and.stars",
                iconColor: .pink,
                title: "Prompt Experiment",
                detailText: nil,
                subtitle: experiment.map { "\($0.status.rawValue) · \($0.title)" },
                status: status,
                timestamp: item.timestamp,
                isExpandable: true,
                isExpanded: $isExpanded
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if let experiment {
                        Text(PromptExperimentMCPControl.nextAction(experiment).capitalizedFirstLetter)
                            .font(.caption).foregroundStyle(.secondary)
                        PromptExperimentAuthorityPanel(experiment: experiment)
                        PromptExperimentApprovalControls(service: service, experiment: experiment)
                        if let run = experiment.runs.last {
                            PromptExperimentRunSummary(run: run)
                        }
                        ForEach(experiment.proposals) { proposal in
                            Button("Review candidate #\(proposal.candidateIndex) · \(proposal.state.rawValue)") {
                                reviewedProposal = .init(id: proposal.id)
                            }
                            .font(.caption)
                        }
                    } else {
                        ToolMarkdownExpandedContent(item: item)
                    }
                    Button("Open Prompt Experiments") { showsStudio = true }
                        .font(.caption)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Observe preparation independently: its one-shot state is intentionally separate
    /// from persisted experiments, and changes must update an already-visible transcript.
    private struct PromptLabPreparationToolCard: View {
        let item: AgentChatItem
        @ObservedObject var preparations: PromptLabPreparationApprovals
        let preparationID: UUID
        @Binding var isExpanded: Bool
        let openStudio: () -> Void

        private var request: PromptLabPreparationRequest? {
            preparations.request(id: preparationID)
        }

        private var status: ToolCardStatus {
            if item.toolIsError == true { return .failure }
            switch request?.status {
            case .awaitingApproval, .running: return .running
            case .completed: return .success
            case .failed: return .warning
            case .rejected, .cancelled, nil: return .neutral
            }
        }

        var body: some View {
            ToolCardContainer(
                iconName: "doc.text.magnifyingglass",
                iconColor: .pink,
                title: "Prepare Prompt Experiment",
                detailText: nil,
                subtitle: request.map { "\($0.preparationStatusLabel) · \($0.title)" },
                status: status,
                timestamp: item.timestamp,
                isExpandable: true,
                isExpanded: $isExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if let request {
                        Text(request.preparationStatusSummary).font(.caption)
                        if let error = request.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        Text("This preparation request is no longer available. Ask the assistant to prepare it again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(request?.status == .awaitingApproval ? "Review preparation" : "Open Prompt Experiments", action: openStudio)
                        .font(.caption)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private extension String {
        var capitalizedFirstLetter: String {
            prefix(1).uppercased() + dropFirst()
        }
    }
#endif
