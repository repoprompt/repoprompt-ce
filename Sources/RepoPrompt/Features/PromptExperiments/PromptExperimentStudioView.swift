#if DEBUG
    import AppKit
    import SwiftUI

    /// App-wide library of experiments: authority, approval, runs, evidence, and proposals.
    struct PromptExperimentStudioView: View {
        @ObservedObject var service: PromptExperimentService
        var initialSelection: UUID?
        @Environment(\.dismiss) private var dismiss
        @State private var selectedExperimentID: UUID?

        private var sortedExperiments: [PromptExperiment] {
            service.experiments.sorted { $0.updatedAt > $1.updatedAt }
        }

        var body: some View {
            NavigationSplitView {
                List(selection: $selectedExperimentID) {
                    if let message = service.loadError ?? service.persistenceError {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else if !service.isLoaded {
                        ProgressView("Loading experiments…")
                    }
                    if service.discardedLegacyLabData {
                        Label("Experiment records from an earlier lab version were discarded.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let projectionError = service.projectionError {
                        Label(projectionError, systemImage: "doc.badge.gearshape").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(sortedExperiments) { experiment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(experiment.title).lineLimit(1)
                            Text("\(experiment.status.rawValue) · \(experiment.authority.promptID.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(experiment.id)
                    }
                }
                .navigationTitle("Prompt Experiments")
            } detail: {
                if let selectedExperimentID, let experiment = service.experiment(id: selectedExperimentID) {
                    PromptExperimentDetailView(service: service, experiment: experiment)
                } else {
                    ContentUnavailableView {
                        Label("No Prompt Experiment Selected", systemImage: "flask")
                    } description: {
                        Text("Experiments are created with the Prompt Experiment workflow or the prompt_experiment MCP tool. Approval happens here or on the in-session card.")
                    }
                }
            }
            .frame(minWidth: 920, minHeight: 650)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await service.load()
                if selectedExperimentID == nil {
                    selectedExperimentID = initialSelection ?? sortedExperiments.first?.id
                }
            }
        }
    }

    private struct PromptExperimentDetailView: View {
        @ObservedObject var service: PromptExperimentService
        let experiment: PromptExperiment
        @State private var selectedProposalID: UUID?
        @State private var showsProposalReview = false
        @State private var proposalError: String?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(experiment.title).font(.title2.bold())
                            if let supersedes = experiment.supersedes {
                                Text("Supersedes \(supersedes.uuidString.lowercased())").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(experiment.status.rawValue)
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.pink.opacity(0.15), in: Capsule())
                    }
                    GroupBox("Approved authority") {
                        PromptExperimentAuthorityPanel(experiment: experiment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Approval and runs") {
                        PromptExperimentApprovalControls(service: service, experiment: experiment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(experiment.runs.reversed()) { run in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                PromptExperimentRunSummary(run: run)
                                if let diagnostics = run.diagnostics {
                                    Text("Worker: \(diagnostics.processObservation.rawValue) · last event \(diagnostics.lastObservedEvent)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if let log = diagnostics.stderrLogRelativePath {
                                        Text("Logs: \(log)").font(.caption2.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                                    }
                                }
                                if let result = run.result {
                                    Text(result.assessment).font(.caption)
                                    ForEach(result.candidates) { candidate in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Candidate #\(candidate.index)\(candidate.isBaseline ? " · baseline" : "")\(candidate.isBest ? " · best" : "") · score \(candidate.aggregateScore.map { String(format: "%.3f", $0) } ?? "—") · parents \(candidate.parentIndices.map(String.init).joined(separator: ", "))")
                                                .font(.caption.bold())
                                            Text(candidate.candidatePreview).font(.caption).lineLimit(6).textSelection(.enabled)
                                            if run.state == .completed || run.state == .stoppedBudget {
                                                Button("Propose source patch") {
                                                    Task {
                                                        do {
                                                            let proposal = try await service.proposePatch(
                                                                experimentID: experiment.id, runID: run.id, candidateIndex: candidate.index
                                                            )
                                                            selectedProposalID = proposal.id
                                                            showsProposalReview = true
                                                        } catch {
                                                            proposalError = error.localizedDescription
                                                        }
                                                    }
                                                }
                                                .font(.caption)
                                            }
                                        }
                                        .padding(6)
                                        .background(candidate.isBest ? Color.green.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                                if let error = run.error {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text("Run \(run.ordinal)")
                        }
                    }
                    if let proposalError {
                        Text(proposalError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    GroupBox("Proposals") {
                        Group {
                            if experiment.proposals.isEmpty {
                                Text("No source patch proposals yet. Reviewed patches for retained candidates are created separately from run approval.")
                            } else {
                                ForEach(experiment.proposals) { proposal in
                                    Button("Review candidate #\(proposal.candidateIndex) · \(proposal.state.rawValue)") {
                                        selectedProposalID = proposal.id
                                        showsProposalReview = true
                                    }
                                }
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Reveal readable overview") {
                        Task {
                            let url = await service.recordDirectoryURL(experimentID: experiment.id)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .font(.caption)
                }
                .padding(20)
            }
            .sheet(isPresented: $showsProposalReview) {
                if let selectedProposalID {
                    PromptExperimentProposalReviewView(service: service, experimentID: experiment.id, proposalID: selectedProposalID)
                }
            }
        }
    }
#endif
