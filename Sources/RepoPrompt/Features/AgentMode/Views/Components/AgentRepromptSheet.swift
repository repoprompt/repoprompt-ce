import AppKit
import SwiftUI

struct AgentRepromptSheet: View {
    let viewModel: AgentModeViewModel
    @ObservedObject var store: AgentRepromptUIStore
    let presentationID: UUID
    @State private var showingOriginal = false
    @FocusState private var editorFocused: Bool

    private var operation: AgentRepromptOperation? {
        guard viewModel.repromptOperation?.id == presentationID else { return nil }
        return viewModel.repromptOperation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let presentation = store.presentation, presentation.id == presentationID {
                Text("Re-prompt").font(.title2.bold())
                Text("Balanced task brief · \(presentation.modelName)").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch presentation.phase {
                        case .generating, .refining:
                            ProgressView(presentation.phase == .generating ? "Writing your brief…" : "Refining your brief…")
                        case .clarifying:
                            if let pending = store.pendingQuestions {
                                AgentAskUserWizardCard(
                                    pending: pending,
                                    onDraftChange: { operation?.updateDraft(questionID: $0, draft: $1) },
                                    onQuestionIndexChange: { operation?.setQuestionIndex($0) },
                                    onSubmit: { operation?.completeQuestions() },
                                    onSkipAll: { operation?.completeQuestions(skipAll: true) },
                                    onUserActivity: {}, showsTimeout: false
                                )
                            }
                        case .gatheringContext:
                            ProgressView("Gathering repository context…")
                        case .reviewing:
                            DisclosureGroup("Original message", isExpanded: $showingOriginal) {
                                Text(presentation.original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            TextEditor(text: $store.reviewText)
                                .font(.body).frame(minHeight: 260).focused($editorFocused)
                                .accessibilityLabel("Editable Re-prompt brief")
                            if !store.canApprove {
                                Text("Enter a non-blank brief of at most 64 KiB.").foregroundStyle(.red).font(.caption)
                            }
                            if presentation.hasUnresolvedQuestions {
                                Label("Open questions remain unresolved in this brief.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange).font(.caption)
                            }
                            if !presentation.consults.isEmpty {
                                DisclosureGroup("Context used") {
                                    ForEach(presentation.consults, id: \.kind) { result in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(result.kind == .oracle ? "Oracle" : "Context Builder"): \(result.status)")
                                            if let count = result.selectedFileCount {
                                                Text("Context Builder selected \(count) files. Sending keeps this selection.")
                                            }
                                            if let chatID = result.chatID {
                                                Button("Open Oracle consult") { openConsult(chatID, tabID: presentation.sourceTabID) }
                                            }
                                            Text(result.text).font(.caption).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            Text("Review edits are not sent back to the rewriter. Your enabled Router/Auto Effort services may judge the approved brief; a judgment on the generated brief may already have started.")
                                .font(.caption).foregroundStyle(.secondary)
                        case .failed:
                            Label(presentation.error ?? "Re-prompt could not finish.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).textSelection(.enabled)
                            Button("Retry") { operation?.retry() }
                                .accessibilityLabel("Retry Re-prompt")
                        }
                        if presentation.isGatheringContext {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                HStack {
                                    VStack(alignment: .leading) {
                                        ForEach(presentation.consultKinds, id: \.self) { kind in
                                            Text(kind == .oracle ? "Oracle: answering…" : "Context Builder: discovering files…")
                                        }
                                    }
                                    Text("\(Int(max(0, context.date.timeIntervalSince(presentation.contextStartedAt))))s")
                                        .monospacedDigit().foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Skip context") { operation?.skipContext() }
                                }.font(.caption)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Button("Cancel", role: .cancel) { operation?.finish(.cancelled) }
                        .keyboardShortcut(.cancelAction)
                    Button("Send Original") { operation?.sendOriginal() }
                        .accessibilityHint("Skips rewriting; workflow, Interview and attachments still apply.")
                    Spacer()
                    if presentation.phase == .reviewing {
                        Button("Send Brief") { operation?.approve() }
                            .buttonStyle(.borderedProminent).disabled(!store.canApprove)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 620, idealWidth: 700, minHeight: 400, idealHeight: 600)
        .onChange(of: store.presentation?.phase) { _, phase in editorFocused = phase == .reviewing }
        .onExitCommand { operation?.finish(.cancelled) }
        .onDisappear {
            guard let operation, operation.validate() else { return }
            operation.finish(.cancelled)
        }
    }

    private func openConsult(_ chatID: String, tabID: UUID) {
        let context = AgentOracleOpenContext(windowID: viewModel.windowID, workspaceID: viewModel.workspaceManager?.activeWorkspaceID, tabID: tabID)
        guard let route = AgentOracleToolRouting.operationPopoverUserInfo(openContext: context, chatID: chatID) else { return }
        NotificationCenter.default.post(name: .showAgentOraclePopover, object: nil, userInfo: route)
    }
}

struct AgentRepromptPresentationHost: ViewModifier {
    let viewModel: AgentModeViewModel
    @ObservedObject var store: AgentRepromptUIStore
    let tabID: UUID?
    let returnFocus: () -> Void
    @State private var confirmingRestore = false

    func body(content: Content) -> some View {
        VStack(spacing: 6) {
            if let tabID, let recovery = store.recoveries[tabID] {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Re-prompt cancelled: \(recovery.reason)").font(.caption)
                    HStack {
                        Button("Restore brief to composer") {
                            if viewModel.restoreRepromptRecovery(tabID: tabID) {
                                returnFocus()
                            } else {
                                confirmingRestore = true
                            }
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recovery.text, forType: .string)
                        }
                        Button("Dismiss") { store.recoveries[tabID] = nil }
                    }.controlSize(.small)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .alert("Replace the current composer draft?", isPresented: $confirmingRestore) {
                        Button("Replace Draft") {
                            _ = viewModel.restoreRepromptRecovery(tabID: tabID, confirmedReplacement: true)
                            returnFocus()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("Your draft changed after Re-prompt was cancelled. Replacing it will discard the current draft.") }
            }
            content
        }
        .sheet(item: Binding(get: { store.presentation }, set: { next in
            if next == nil {
                viewModel.cancelReprompt()
            }
        }), onDismiss: returnFocus) { presentation in
            AgentRepromptSheet(viewModel: viewModel, store: store, presentationID: presentation.id)
        }
    }
}
