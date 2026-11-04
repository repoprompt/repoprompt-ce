import AppKit
import SwiftUI

/// Inline composer status only; the existing composer is the sole editable text authority.
struct AgentRepromptComposerStrip: View {
    let viewModel: AgentModeViewModel
    @ObservedObject var store: AgentRepromptUIStore
    let tabID: UUID?
    var onUndo: ((UUID) -> Void)?
    var onSendOriginal: ((UUID) -> Void)?
    @State private var showingOriginal = false
    @State private var showingRewrite = false
    @State private var confirmingReplacement = false
    @State private var confirmingOriginal = false
    /// Live assignments: both commands are user-configurable composer-local bindings.
    @ObservedObject private var shortcutDisplay = GlobalKeyboardShortcutsCoordinator.shared.bindingDisplay

    private var sendOriginalKey: String {
        shortcutDisplay.localLabel(for: .repromptSendOriginal)
    }

    private var rewriteHint: String {
        let key = shortcutDisplay.localLabel(for: .repromptDraft)
        guard !key.isEmpty else { return "" }
        return " · \(key) rewrite"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let presentation = store.presentation, presentation.sourceTabID == tabID {
                let operation = viewModel.repromptOperation.flatMap { $0.id == presentation.id ? $0 : nil }
                TimelineView(.periodic(from: presentation.startedAt, by: 1)) { context in
                    HStack(spacing: 6) {
                        Button {
                            if let onSendOriginal { onSendOriginal(presentation.id) } else { operation?.useOriginal() }
                        } label: { AgentRepromptShortcutLabel(title: "Send original", shortcut: sendOriginalKey) }
                            .localKeyboardShortcut(.repromptSendOriginal)
                            .hoverTooltip(
                                "Send your original text now\(sendOriginalKey.isEmpty ? "" : " (\(sendOriginalKey))"). Return sends the text currently in the composer.",
                                .top
                            )
                        if presentation.phase != .completed {
                            Button { operation?.cancel() } label: { AgentRepromptShortcutLabel(title: "Cancel", shortcut: "esc") }
                                .hoverTooltip("Stop rewriting and restore your original (Esc in the composer).", .top)
                        }
                        if presentation.phase.isStreaming {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: presentation.phase == .completed ? "checkmark.circle.fill" : "wand.and.sparkles")
                                .foregroundStyle(presentation.phase == .completed ? Color.green : Color.secondary)
                        }
                        Text("\(presentation.phase == .completed ? "Re-prompted" : "Re-prompting") · \(presentation.modelName)\(presentation.usesChatContext ? " · with chat context" : "")")
                            .lineLimit(1).layoutPriority(1)
                        if presentation.phase != .completed {
                            Text("\(Int(max(0, context.date.timeIntervalSince(presentation.startedAt))))s").monospacedDigit()
                        }
                        if presentation.phase == .completed {
                            Button { showingOriginal.toggle() } label: {
                                Text(showingOriginal ? "Hide original" : "Show original")
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .hoverTooltip(showingOriginal ? "Hide the original message" : "Expand the original message", .top)
                            Button {
                                if let onUndo { onUndo(presentation.id) } else { operation?.cancel() }
                            } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(.plain).accessibilityLabel("Revert to original")
                                .hoverTooltip("Revert to original (Esc)", .top)
                            Spacer(minLength: 4)
                            Text("↩ send\(rewriteHint) · esc revert")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        } else {
                            Spacer(minLength: 4)
                            if presentation.phase == .failed { Button("Retry") { operation?.retry() } }
                            Text("↩ send current · esc cancel")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
                .font(.caption).controlSize(.small)
                if presentation.phase == .completed {
                    HStack {
                        Label(operation?.hasUserEdits == true ? "Draft ready to send" : "Rewrite complete — ready to send", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Read rewrite…") { showingRewrite = true }
                    }
                    .font(.callout)
                    .padding(8)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if presentation.phase == .completed, presentation.startsWithProviderCommand {
                    Text("Starts with / — your agent may treat it as a command")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = presentation.error {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if showingOriginal {
                    ScrollView { Text(presentation.original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 100)
                }
            }
            if let tabID, let recovery = store.recoveries[tabID] {
                HStack(spacing: 6) {
                    Text(recovery.requiresDecision ? "Draft changed — choose what to keep" : "Recoverable Re-prompt draft").font(.caption)
                    Button(confirmingOriginal ? "Replace with original" : "Restore original") {
                        if viewModel.restoreRepromptOriginal(tabID: tabID, confirmedReplacement: confirmingOriginal) {
                            confirmingOriginal = false
                        } else { confirmingOriginal = true }
                    }
                    if recovery.requiresDecision {
                        Button("Keep rewrite") { viewModel.keepRepromptRewrite(tabID: tabID) }
                    } else {
                        Button(confirmingReplacement ? "Replace current draft" : "Restore rewrite") {
                            if viewModel.restoreRepromptRecovery(tabID: tabID, confirmedReplacement: confirmingReplacement) {
                                confirmingReplacement = false
                            } else { confirmingReplacement = true }
                        }
                    }
                    Button("Copy rewrite") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recovery.text, forType: .string)
                    }
                    if !recovery.requiresDecision, !recovery.bypassesPreparation {
                        Button("Dismiss") { store.recoveries[tabID] = nil
                            confirmingReplacement = false
                        }
                    }
                }.controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
        .sheet(isPresented: $showingRewrite) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Rewritten prompt").font(.title2.bold())
                    Spacer()
                    Button("Done") { showingRewrite = false }
                        .keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    MarkdownTextView(
                        text: viewModel.repromptOperation?.expectedDraft ?? "",
                        isMarkdown: true,
                        allowInteraction: true,
                        bareURLLinkificationPolicy: .httpHTTPSOnly
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                Text("Edit or send this prompt in the composer after closing this preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(minWidth: 680, idealWidth: 800, maxWidth: .infinity, minHeight: 440, idealHeight: 600, maxHeight: .infinity)
        }
        .onChange(of: store.presentation?.id) { _, _ in
            showingOriginal = false
            showingRewrite = false
        }
        .onChange(of: tabID) { _, _ in confirmingReplacement = false
            confirmingOriginal = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Re-prompt")
    }
}

/// A button title with its keyboard shortcut visible, not only in a tooltip.
struct AgentRepromptShortcutLabel: View {
    let title: String
    let shortcut: String
    var shortcutFirst = false

    var body: some View {
        HStack(spacing: 4) {
            if shortcutFirst, !shortcut.isEmpty { shortcutText }
            Text(title)
            if !shortcutFirst, !shortcut.isEmpty { shortcutText }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var shortcutText: some View {
        Text(shortcut).font(.caption2.monospaced()).foregroundStyle(.secondary)
    }
}

/// Transient presentation, deliberately outside AgentChatItem/provider history and runtime ask_user.
struct AgentRepromptQuestionsView: View {
    let viewModel: AgentModeViewModel
    @ObservedObject var store: AgentRepromptUIStore
    let tabID: UUID?
    var onReturnToComposer: () -> Void = {}
    @State private var contentHeight: CGFloat = 80

    var body: some View {
        if store.presentation?.sourceTabID == tabID, store.presentation?.phase == .clarifying,
           let pending = store.pendingQuestions, let question = pending.currentQuestion
        {
            let operation = viewModel.repromptOperation
            let draft = pending.draftsByQuestionID[question.id] ?? AgentAskUserDraft()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Keep rewrite") { completeQuestions(operation, skipAll: true) }
                    Button("Apply answer") { completeQuestions(operation) }
                        .disabled(!pending.isComplete)
                    Text("Optional clarification").font(.caption).foregroundStyle(.secondary)
                }.controlSize(.small)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.question).font(.callout).fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button {
                                operation?.updateDraft(questionID: question.id, draft: .init(selectedOptionLabels: [option.label], customResponse: draft.customResponse))
                                completeQuestions(operation)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                    if let description = option.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                        TextField("Or add your own answer", text: Binding(get: { draft.customResponse }, set: { text in
                            var updated = draft
                            updated.customResponse = text
                            updated.skipped = false
                            operation?.updateDraft(questionID: question.id, draft: updated)
                        }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { completeQuestions(operation) }
                        Text("Return applies your answer. Return in the composer sends the current draft.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { contentHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, height in contentHeight = height }
                    })
                }
                .frame(height: min(200, max(80, contentHeight)))
            }
        }
    }

    private func completeQuestions(_ operation: AgentRepromptOperation?, skipAll: Bool = false) {
        guard let operation, viewModel.currentTabID == tabID,
              store.presentation?.id == operation.id else { return }
        operation.completeQuestions(skipAll: skipAll)
        guard operation.phase != .clarifying else { return }
        Task { @MainActor in
            await Task.yield()
            guard viewModel.currentTabID == tabID, viewModel.repromptOperation?.id == operation.id else { return }
            onReturnToComposer()
        }
    }
}
