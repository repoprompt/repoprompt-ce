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
            let keys = ["experiment_id"]
            for raw in [item.toolResultJSON, item.toolArgsJSON] {
                guard let raw, let data = raw.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                for key in keys {
                    if let id = (object[key] as? String).flatMap(UUID.init(uuidString:)) { return id }
                }
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
            .task { await service.load() }
            .sheet(isPresented: $showsStudio) {
                PromptExperimentStudioView(service: service, initialSelection: experimentID)
            }
            .sheet(item: $reviewedProposal) { selection in
                if let experimentID {
                    PromptExperimentProposalReviewView(service: service, experimentID: experimentID, proposalID: selection.id)
                }
            }
        }
    }

    private extension String {
        var capitalizedFirstLetter: String {
            prefix(1).uppercased() + dropFirst()
        }
    }
#endif
