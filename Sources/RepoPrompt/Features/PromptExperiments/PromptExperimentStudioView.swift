#if DEBUG
    import AppKit
    import SwiftUI

    /// App-wide library of experiments: authority, approval, runs, evidence, and proposals.
    ///
    /// Presented as a sheet from the in-session tool card, or standalone in its own window
    /// (Window ▸ Prompt Experiments…) so experiments created by external MCP/CLI clients can
    /// be reviewed and approved without an Agent Mode transcript.
    struct PromptExperimentStudioView: View {
        @ObservedObject var service: PromptExperimentService
        var initialSelection: UUID?
        /// Sheets need an explicit Close button; the standalone window uses its title bar.
        var showsCloseButton = true
        @Environment(\.dismiss) private var dismiss
        @State private var selectedExperimentID: UUID?
        @State private var showsCreateExperiment = false

        private var sortedExperiments: [PromptExperiment] {
            service.experiments.sorted { $0.updatedAt > $1.updatedAt }
        }

        /// Experiments with an outstanding approval request, newest request first.
        private var awaitingApproval: [PromptExperiment] {
            service.experiments
                .filter { $0.status == .awaitingApproval }
                .sorted { ($0.approvalRequest?.requestedAt ?? $0.updatedAt) > ($1.approvalRequest?.requestedAt ?? $1.updatedAt) }
        }

        private var otherExperiments: [PromptExperiment] {
            sortedExperiments.filter { $0.status != .awaitingApproval }
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
                    if !awaitingApproval.isEmpty {
                        Section {
                            ForEach(awaitingApproval) { experiment in
                                PromptExperimentAwaitingApprovalRow(experiment: experiment)
                                    .tag(experiment.id)
                            }
                        } header: {
                            Label("Awaiting approval (\(awaitingApproval.count))", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section(awaitingApproval.isEmpty ? "Experiments" : "Other experiments") {
                        ForEach(otherExperiments) { experiment in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(experiment.title).lineLimit(1)
                                Text("\(experiment.status.rawValue) · \(experiment.authority.promptID.rawValue)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(experiment.id)
                        }
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
                        Text("Choose a built-in prompt and connected models, compare candidates on saved examples, then review the evidence and source diff.")
                    } actions: {
                        Button("New Experiment") { showsCreateExperiment = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!service.isLoaded || service.loadError != nil)
                    }
                }
            }
            .frame(minWidth: 920, minHeight: 650)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Experiment", systemImage: "plus") { showsCreateExperiment = true }
                        .disabled(!service.isLoaded || service.loadError != nil)
                }
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showsCreateExperiment) {
                PromptExperimentCreateView(service: service) { selectedExperimentID = $0 }
            }
            .task {
                await service.load()
                if selectedExperimentID == nil {
                    selectedExperimentID = initialSelection ?? awaitingApproval.first?.id ?? sortedExperiments.first?.id
                }
            }
            .onChange(of: initialSelection) { _, newSelection in
                // The standalone window is reused; retargeting it selects the requested experiment.
                if let newSelection { selectedExperimentID = newSelection }
            }
            .onChange(of: awaitingApproval.map(\.id)) { oldIDs, newIDs in
                // Surface a newly requested approval when nothing is selected yet.
                if let selectedExperimentID, service.experiment(id: selectedExperimentID) != nil { return }
                if let newID = newIDs.first(where: { !oldIDs.contains($0) }) ?? newIDs.first {
                    selectedExperimentID = newID
                }
            }
        }
    }

    /// Sidebar row for an experiment whose approval was requested but not yet decided.
    private struct PromptExperimentAwaitingApprovalRow: View {
        let experiment: PromptExperiment

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text(experiment.title).lineLimit(1).fontWeight(.semibold)
                }
                Text("\(experiment.authority.promptID.rawValue) · cap \(experiment.authority.maxEvaluations) evaluations")
                    .font(.caption).foregroundStyle(.secondary)
                if let requestedAt = experiment.approvalRequest?.requestedAt {
                    Text("Requested \(requestedAt, style: .relative) ago")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private struct PromptExperimentDetailView: View {
        @ObservedObject var service: PromptExperimentService
        let experiment: PromptExperiment
        /// Presented via `sheet(item:)` so the sheet never renders before its ID is set
        /// (an `isPresented` sheet here showed an empty, undismissable modal).
        @State private var reviewedProposal: PromptExperimentProposalSelection?
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
                    if experiment.status == .awaitingApproval {
                        PromptExperimentApprovalRequestCallout(experiment: experiment)
                    }
                    GroupBox(experiment.isApproved ? "Approved experiment" : "Experiment to review") {
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
                                    if let noise = result.noiseFloor, !noise.bestIsBaseline {
                                        PromptExperimentNoiseVerdict(noise: noise)
                                    }
                                    Text(result.assessment).font(.caption)
                                    ForEach(result.candidates) { candidate in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Candidate #\(candidate.index)\(candidate.isBaseline ? " · baseline" : "")\(candidate.isBest ? " · best" : "") · score \(candidate.aggregateScore.map { String(format: "%.3f", $0) } ?? "—") · parents \(candidate.parentIndices.map(String.init).joined(separator: ", "))")
                                                .font(.caption.bold())
                                            if let usage = candidate.usage {
                                                Text(usage.summary).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Text(candidate.candidatePreview).font(.caption).lineLimit(6).textSelection(.enabled)
                                            if run.state == .completed || run.state == .stoppedBudget {
                                                Button("Propose source patch") {
                                                    Task {
                                                        do {
                                                            let proposal = try await service.proposePatch(
                                                                experimentID: experiment.id, runID: run.id, candidateIndex: candidate.index
                                                            )
                                                            reviewedProposal = .init(id: proposal.id)
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
                                        reviewedProposal = .init(id: proposal.id)
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
            .sheet(item: $reviewedProposal) { selection in
                PromptExperimentProposalReviewView(service: service, experimentID: experiment.id, proposalID: selection.id)
            }
        }
    }

    /// Prominent banner for an outstanding approval request.
    private struct PromptExperimentApprovalRequestCallout: View {
        let experiment: PromptExperiment

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approval requested").font(.headline)
                    if let requestedAt = experiment.approvalRequest?.requestedAt {
                        Text("Requested \(requestedAt.formatted(date: .abbreviated, time: .standard)).")
                            .font(.caption)
                    }
                    Text("Review the experiment below, then approve \(experiment.authority.approvalBudgetSummary) or decline under Approval and runs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))
        }
    }
#endif
