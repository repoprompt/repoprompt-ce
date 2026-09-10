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
                        .disabled(controllerSessionID == nil || sourceTabID == nil || service.loadError != nil)
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
                            Text("Create a fixed, synthetic-fixture-only original/candidate comparison.")
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
                    selectedExperimentID = try await service.createExperiment(
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
        @State private var approvalAcknowledged = false
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
                        PromptExperimentDraftEditor(
                            service: service,
                            experimentID: record.id,
                            draft: draft,
                            errorMessage: $errorMessage
                        )
                    }
                    if let plan = record.currentPlan {
                        planPanel(plan)
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
                    LabeledContent("Schedule", value: "\(plan.trials.count) serial trials")
                    LabeledContent("Environment", value: "Synthetic fixture only")
                    Text(plan.digest)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
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
        private func controls(_ plan: PromptExperimentPlan) -> some View {
            if record.phase == .awaitingApproval {
                GroupBox("Native approval") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("I reviewed the exact digest displayed above", isOn: $approvalAcknowledged)
                        Button("Approve sealed plan") {
                            perform {
                                try await service.approve(
                                    experimentID: record.id,
                                    displayedDigest: plan.digest,
                                    source: .nativeUI
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!approvalAcknowledged)
                        Text("Agents cannot invoke this authority. Approval does not start provider work.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            } else if record.phase == .approved {
                Button("Run \(plan.trials.count) serial trials") {
                    perform { try await service.run(experimentID: record.id) }
                }
                .buttonStyle(.borderedProminent)
            } else if record.phase == .running || record.phase == .cancelling {
                Button("Request cancellation", role: .destructive) {
                    perform { try await service.cancel(experimentID: record.id) }
                }
                .disabled(record.phase == .cancelling)
            }

            if record.phase == .completed || record.phase == .inconclusive || record.phase == .cancelled {
                HStack {
                    Button("Next revision") {
                        perform { try await service.startNextRevision(experimentID: record.id) }
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
                        ForEach(record.attempts.sorted(by: { $0.ordinal < $1.ordinal })) { attempt in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("\(attempt.ordinal). \(attempt.condition.displayName) · repetition \(attempt.repetition)")
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
                                if let preview = attempt.outputPreview, !preview.isEmpty {
                                    Text(preview)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                }
                                if let evidence = attempt.evidence {
                                    Text("Evidence SHA-256: \(evidence.sha256)")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 10)
                            if attempt.id != record.attempts.sorted(by: { $0.ordinal < $1.ordinal }).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }

        private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
            Task {
                do { try await operation() } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private struct PromptExperimentDraftEditor: View {
        @ObservedObject var service: PromptExperimentService
        let experimentID: UUID
        @Binding var errorMessage: String?
        @State private var draft: PromptExperimentDraft

        init(
            service: PromptExperimentService,
            experimentID: UUID,
            draft: PromptExperimentDraft,
            errorMessage: Binding<String?>
        ) {
            self.service = service
            self.experimentID = experimentID
            _draft = State(initialValue: draft)
            _errorMessage = errorMessage
        }

        var body: some View {
            GroupBox("Editable draft revision \(draft.revision)") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title", text: $draft.title)
                    VStack(alignment: .leading) {
                        Text("Fixed evaluation task").font(.caption.bold())
                        TextEditor(text: $draft.taskInput).frame(minHeight: 70)
                    }
                    VStack(alignment: .leading) {
                        Text("Synthetic fixture (the only trial-visible file)").font(.caption.bold())
                        TextEditor(text: $draft.syntheticFixture).frame(minHeight: 100)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        instructionEditor("Original instructions", text: $draft.originalInstructions)
                        instructionEditor("Candidate instructions", text: $draft.candidateInstructions)
                    }
                    HStack {
                        Picker("Catalog role", selection: $draft.targetRole) {
                            Text("Explore").tag("explore")
                            Text("Engineer").tag("engineer")
                            Text("Pair").tag("pair")
                            Text("Design").tag("design")
                        }
                        Stepper("Repetitions: \(draft.repetitions)", value: $draft.repetitions, in: 1 ... 3)
                        Spacer()
                        Button("Save draft") { save() }
                        Button("Save and seal") { seal() }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Loaded workspace content is intentionally unsupported. Sealing copies this synthetic fixture into app-owned durable storage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }

        private func instructionEditor(_ title: String, text: Binding<String>) -> some View {
            VStack(alignment: .leading) {
                Text(title).font(.caption.bold())
                TextEditor(text: text).frame(minHeight: 120)
            }
        }

        private func save() {
            Task {
                do {
                    try await service.updateDraft(
                        experimentID: experimentID,
                        expectedRevision: draft.revision,
                        draft: draft
                    )
                } catch { errorMessage = error.localizedDescription }
            }
        }

        private func seal() {
            Task {
                do {
                    try await service.updateDraft(
                        experimentID: experimentID,
                        expectedRevision: draft.revision,
                        draft: draft
                    )
                    _ = try await service.seal(experimentID: experimentID, expectedDraftRevision: draft.revision)
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
#endif
