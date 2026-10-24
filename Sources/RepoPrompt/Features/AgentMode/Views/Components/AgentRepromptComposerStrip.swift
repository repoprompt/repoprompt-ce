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
    @State private var confirmingReplacement = false
    @State private var confirmingOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let presentation = store.presentation, presentation.sourceTabID == tabID {
                let operation = viewModel.repromptOperation.flatMap { $0.id == presentation.id ? $0 : nil }
                TimelineView(.periodic(from: presentation.startedAt, by: 1)) { context in
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.sparkles")
                        Text("\(presentation.phase == .completed ? "Re-prompted" : "Re-prompting") · \(presentation.modelName)\(presentation.usesChatContext ? " · with chat context" : "")")
                            .lineLimit(1).layoutPriority(1)
                        if presentation.phase != .completed {
                            Text("\(Int(max(0, context.date.timeIntervalSince(presentation.startedAt))))s").monospacedDigit()
                        }
                        if presentation.phase == .completed {
                            Button { showingOriginal.toggle() } label: {
                                Text("Original: \(presentation.original.replacingOccurrences(of: "\n", with: " "))")
                                    .foregroundStyle(.secondary).strikethrough().lineLimit(1).truncationMode(.tail)
                            }
                            .buttonStyle(.plain)
                            .hoverTooltip("Expand the original message", .top)
                            Button {
                                if let onUndo { onUndo(presentation.id) } else { operation?.cancel() }
                            } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(.plain).accessibilityLabel("Revert to original")
                                .hoverTooltip("Revert to original (Esc)", .top)
                            Spacer(minLength: 4)
                            Text("↩ send · ⌘↩ re-prompt again · esc revert")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        } else {
                            Spacer(minLength: 4)
                            if presentation.phase == .failed { Button("Retry") { operation?.retry() } }
                            if context.date.timeIntervalSince(presentation.startedAt) >= 5 || presentation.phase == .failed {
                                Button("Send original") {
                                    if let onSendOriginal { onSendOriginal(presentation.id) } else { operation?.useOriginal() }
                                }
                                .hoverTooltip("Explicitly sends the original through a fresh composer claim.", .top)
                            }
                            Button("Cancel") { operation?.cancel() }
                        }
                    }
                }
                .font(.caption).controlSize(.small)
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
        .onChange(of: store.presentation?.id) { _, _ in showingOriginal = false }
        .onChange(of: tabID) { _, _ in confirmingReplacement = false
            confirmingOriginal = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Re-prompt")
    }
}

/// Transient presentation, deliberately outside AgentChatItem/provider history and runtime ask_user.
struct AgentRepromptQuestionsView: View {
    let viewModel: AgentModeViewModel
    @ObservedObject var store: AgentRepromptUIStore
    let tabID: UUID?

    var body: some View {
        if store.presentation?.sourceTabID == tabID, store.presentation?.phase == .clarifying,
           let pending = store.pendingQuestions
        {
            let operation = viewModel.repromptOperation
            VStack(alignment: .leading, spacing: 6) {
                Label("Before sending", systemImage: "wand.and.sparkles").font(.headline)
                AgentAskUserWizardCard(
                    pending: pending,
                    onDraftChange: { operation?.updateDraft(questionID: $0, draft: $1) },
                    onQuestionIndexChange: { operation?.setQuestionIndex($0) },
                    onSubmit: { operation?.completeQuestions() },
                    onSkipAll: { operation?.completeQuestions(skipAll: true) },
                    onUserActivity: {}, showsTimeout: false
                )
            }
        }
    }
}
