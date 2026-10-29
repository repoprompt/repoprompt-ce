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
        @ObservedObject private var preparations: PromptLabPreparationApprovals
        var initialSelection: UUID?
        /// Sheets need an explicit Close button; the standalone window uses its title bar.
        var showsCloseButton = true
        @Environment(\.dismiss) private var dismiss
        @State private var selectedExperimentID: UUID?
        @State private var showsCreateExperiment = false

        init(service: PromptExperimentService, initialSelection: UUID? = nil, showsCloseButton: Bool = true) {
            self.service = service
            preparations = service.preparationApprovals
            self.initialSelection = initialSelection
            self.showsCloseButton = showsCloseButton
        }

        private var sortedPreparations: [PromptLabPreparationRequest] {
            preparations.requests.sorted { $0.createdAt > $1.createdAt }
        }

        private var hasSelectedItem: Bool {
            guard let selectedExperimentID else { return false }
            return service.experiment(id: selectedExperimentID) != nil || preparations.request(id: selectedExperimentID) != nil
        }

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
                    if !sortedPreparations.isEmpty {
                        Section("Preparation requests") {
                            ForEach(sortedPreparations) { request in
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(request.title, systemImage: request.status == .awaitingApproval ? "hand.raised.fill" : "doc.text.magnifyingglass")
                                        .lineLimit(1)
                                    Text(request.preparationStatusLabel)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .tag(request.id)
                            }
                        }
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
                                Text("\(experiment.status.rawValue) · \(experiment.authority.promptDisplayName)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(experiment.id)
                        }
                    }
                }
                .navigationTitle("Prompt Experiments")
            } detail: {
                if let selectedExperimentID, let request = preparations.request(id: selectedExperimentID) {
                    PromptLabPreparationReviewView(service: service, preparations: preparations, request: request)
                        .id(request.id)
                } else if let selectedExperimentID, let experiment = service.experiment(id: selectedExperimentID) {
                    PromptExperimentDetailView(service: service, experiment: experiment)
                } else {
                    ContentUnavailableView {
                        Label("No Prompt Experiment Selected", systemImage: "flask")
                    } description: {
                        Text("Improve a RepoPrompt prompt, a project's prompt file, pasted text, or an AI program. Describe your goal, review examples and checks, and compare the results before using a candidate.")
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
                    selectedExperimentID = initialSelection
                        ?? sortedPreparations.first(where: { $0.status == .awaitingApproval })?.id
                        ?? awaitingApproval.first?.id ?? sortedExperiments.first?.id ?? sortedPreparations.first?.id
                }
            }
            .onChange(of: initialSelection) { _, newSelection in
                // The standalone window is reused; retargeting it selects the requested experiment.
                if let newSelection { selectedExperimentID = newSelection }
            }
            .onChange(of: awaitingApproval.map(\.id)) { oldIDs, newIDs in
                // Surface a newly requested approval when nothing is selected yet.
                if hasSelectedItem { return }
                if let newID = newIDs.first(where: { !oldIDs.contains($0) }) ?? newIDs.first {
                    selectedExperimentID = newID
                }
            }
            .onChange(of: sortedPreparations.map(\.id)) { oldIDs, newIDs in
                if hasSelectedItem { return }
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
                Text("\(experiment.authority.promptDisplayName) · up to \(experiment.authority.maximumTotalEvaluations) evaluations")
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
                                    PromptLabRunResultsView(service: service, experiment: experiment, run: run, result: result) { proposalID in
                                        reviewedProposal = .init(id: proposalID)
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
                    GroupBox("Proposals") {
                        Group {
                            if experiment.proposals.isEmpty {
                                Text(
                                    experiment.authority.definition?.source.kind == .pasted
                                        ? "Copy or save a candidate prompt from the results above."
                                        : "Review a retained candidate's source change from the results above before applying it."
                                )
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

    /// Native, one-shot consent for preparation requested through MCP. Merely displaying
    /// this view never reads the requested file or imports the requested project module.
    private struct PromptLabPreparationReviewView: View {
        @ObservedObject var service: PromptExperimentService
        @ObservedObject var preparations: PromptLabPreparationApprovals
        let request: PromptLabPreparationRequest
        @State private var actionError: String?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(request.title).font(.title2.bold())
                        Spacer()
                        Text(request.preparationStatusLabel).font(.caption.bold())
                    }
                    Text(request.preparationStatusSummary).foregroundStyle(.secondary)
                    GroupBox("Preparation to review") {
                        VStack(alignment: .leading, spacing: 12) {
                            switch request.payload {
                            case let .file(file): fileDetails(file)
                            case let .program(program, runner): programDetails(program, runner: runner)
                            }
                            Text("Approval uses the current contents at the shown path once. You will review the prepared experiment and its budget before optimization begins.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                    if let definition = request.definition {
                        GroupBox("Prepared draft") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(definition.goal)
                                Text("\(definition.examples.count) examples · \(definition.source.title)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("The assistant can retrieve this draft and prepare the experiment for your review.")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let error = actionError ?? request.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    controls
                }
                .padding(20)
            }
        }

        private func fileDetails(_ file: PromptLabFilePreparationRequest) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Read the selected prompt and send it, along with your goal and examples, to the model below. One model call prepares an editable draft of examples and checks.")
                LabeledContent("Source file") {
                    Text(file.path).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Preparation model", value: file.target.displayName)
                LabeledContent("Time limit", value: "60 seconds")
                if let selection = file.selection {
                    Text(selection.count > 4000 ? "Selected source text (first 4,000 characters)" : "Selected source text")
                        .font(.caption.bold())
                    Text(String(selection.prefix(4000))).font(.caption.monospaced()).textSelection(.enabled)
                } else {
                    Text("Use the whole prompt file.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Goal").font(.caption.bold())
                Text(file.goal).textSelection(.enabled)
                if !file.exampleInputs.isEmpty {
                    Text("Example inputs").font(.caption.bold())
                    Text(file.exampleInputs).font(.caption).textSelection(.enabled)
                }
                if !file.criteria.isEmpty {
                    Text("Success criteria").font(.caption.bold())
                    Text(file.criteria).font(.caption).textSelection(.enabled)
                }
            }
        }

        private func programDetails(_ program: PromptLabProgram, runner: PromptLabRunnerKind) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Load the project's examples and checks with its Python interpreter. Importing this module executes project code with normal access to files and the network; the project may also use the environment variables listed below.")
                LabeledContent("Program type", value: runner == .dspy ? "DSPy program" : "Python evaluator")
                LabeledContent("Project folder") {
                    Text(program.projectRoot).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Python interpreter") {
                    Text(program.pythonExecutable).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Module") {
                    Text(program.modulePath).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Evaluation function", value: program.callable)
                LabeledContent("Time limit", value: "\(program.timeoutSeconds.formatted()) seconds")
                LabeledContent("Environment variables", value: program.environmentKeys.isEmpty ? "None requested" : program.environmentKeys.joined(separator: ", "))
                Text("RepoPrompt loads the draft without starting an optimization run. Any work performed while importing the module is controlled by the project's code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        @ViewBuilder private var controls: some View {
            switch request.status {
            case .awaitingApproval:
                HStack {
                    Button("Approve and prepare") {
                        actionError = nil
                        Task {
                            do { try await preparations.approve(requestID: request.id, service: service) }
                            catch { actionError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Decline") {
                        do { try preparations.reject(requestID: request.id) }
                        catch { actionError = error.localizedDescription }
                    }
                }
            case .running:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Preparing examples and checks…").font(.caption)
                    Button("Cancel preparation") {
                        do { try preparations.cancel(requestID: request.id) }
                        catch { actionError = error.localizedDescription }
                    }
                }
            case .completed, .failed, .rejected, .cancelled:
                EmptyView()
            }
        }
    }

    extension PromptLabPreparationRequest {
        var preparationStatusLabel: String {
            switch status {
            case .awaitingApproval: "Review preparation"
            case .running: "Preparing"
            case .completed: "Draft ready"
            case .failed: "Preparation failed"
            case .rejected: "Declined"
            case .cancelled: "Cancelled"
            }
        }

        var preparationStatusSummary: String {
            switch status {
            case .awaitingApproval:
                switch payload {
                case .file: "Review the file and model before preparing examples and checks."
                case .program: "Review the project and Python interpreter before loading examples and checks."
                }
            case .running: "Preparing examples and checks for your experiment."
            case .completed: "The draft is ready for the assistant to turn into an experiment for your review."
            case .failed: "Preparation could not finish. The assistant can submit a corrected request."
            case .rejected: "Preparation was declined. A new request is needed to try again."
            case .cancelled: "Preparation was cancelled. A new request is needed to try again."
            }
        }
    }
#endif
