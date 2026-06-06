import SwiftUI

/// Structured multi-question ask_user card shared by Agent Mode and Context Builder.
/// Presents one question at a time while keeping all draft state in the owning view model.
struct AgentAskUserWizardCard: View {
    let pending: AgentAskUserPendingState
    let onDraftChange: (_ questionID: String, _ draft: AgentAskUserDraft) -> Void
    let onQuestionIndexChange: (_ index: Int) -> Void
    let onSubmit: () -> Void
    let onSkipAll: () -> Void
    let onUserActivity: () -> Void

    @State private var lastActivitySignalAt: Date?
    @State private var activityWorkGate = WorkItemGate()
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if let context = nonEmpty(pending.interaction.context) {
                contextBlock(context)
            }

            if let question = currentQuestion {
                questionSection(question)
            }

            actionButtons
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .onChange(of: pending.id) { _, _ in
            cancelPendingActivitySignal()
            lastActivitySignalAt = nil
        }
        .onChange(of: pending.currentQuestionIndex) { _, _ in
            noteUserActivity()
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue != nil {
                noteUserActivity()
            }
        }
        .onDisappear {
            cancelPendingActivitySignal()
        }
    }

    private var currentQuestion: AgentAskUserQuestion? {
        pending.currentQuestion
    }

    private var currentIndex: Int {
        pending.currentQuestionIndex
    }

    private var currentDraft: AgentAskUserDraft {
        guard let question = currentQuestion else { return AgentAskUserDraft() }
        return pending.draftsByQuestionID[question.id] ?? AgentAskUserDraft()
    }

    private var questionCount: Int {
        pending.interaction.questions.count
    }

    private var isFirstQuestion: Bool {
        currentIndex <= 0
    }

    private var isLastQuestion: Bool {
        currentIndex >= questionCount - 1
    }

    private var canMoveForward: Bool {
        guard let question = currentQuestion else { return false }
        let answer = question.answer(from: currentDraft)
        return answer.skipped || !answer.answers.isEmpty
    }

    private var headerTitle: String {
        nonEmpty(pending.interaction.title) ?? (questionCount > 1 ? "Agent Questions" : "Agent Question")
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                Text("Question \(min(currentIndex + 1, questionCount)) of \(questionCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            let countdownAnchor = pending.timeoutStartedAt ?? pending.interaction.askedAt
            TimeoutCountdownView(startedAt: countdownAnchor, timeoutSeconds: pending.interaction.timeoutSeconds)
                .id(countdownAnchor)
        }
    }

    private func questionSection(_ question: AgentAskUserQuestion) -> some View {
        let draft = pending.draftsByQuestionID[question.id] ?? AgentAskUserDraft()
        return VStack(alignment: .leading, spacing: 10) {
            if let header = nonEmpty(question.header) {
                Text(header)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }

            Text(question.question)
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

            if let context = nonEmpty(question.context) {
                contextBlock(context)
            }

            if !question.options.isEmpty {
                optionsSection(question: question, draft: draft)
            }

            if question.allowsCustom {
                customResponseField(question: question, draft: draft)
            }

            if draft.skipped {
                Label("This question is marked skipped.", systemImage: "forward.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.045))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.14), lineWidth: 1)
        )
    }

    private func contextBlock(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.05))
            .cornerRadius(6)
    }

    private func optionsSection(question: AgentAskUserQuestion, draft: AgentAskUserDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: question.allowsMultiple ? "checklist" : "list.bullet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(question.allowsMultiple ? "Select all that apply" : "Select one option")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(question.options, id: \.label) { option in
                optionButton(option: option, question: question, draft: draft)
            }
        }
    }

    private func optionButton(option: AgentAskUserOption, question: AgentAskUserQuestion, draft: AgentAskUserDraft) -> some View {
        let isSelected = draft.selectedOptionLabels.contains(option.label)
        return Button {
            toggleOption(option.label, for: question, draft: draft)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(
                    systemName: isSelected
                        ? (question.allowsMultiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                        : (question.allowsMultiple ? "square" : "circle")
                )
                .font(.callout)
                .foregroundColor(isSelected ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout)
                        .foregroundColor(.primary)
                    if let description = nonEmpty(option.description) {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.15) : Color.blue.opacity(0.05))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(draft.skipped)
        .focusable()
        .focused($focusedField, equals: .option(question.id, option.label))
        .onKeyPress(.space) {
            toggleOption(option.label, for: question, draft: draft)
            return .handled
        }
        .focusEffectDisabled()
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(focusedField == .option(question.id, option.label) ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private func customResponseField(question: AgentAskUserQuestion, draft: AgentAskUserDraft) -> some View {
        TextField(
            question.options.isEmpty ? "Type your response…" : "Other…",
            text: customResponseBinding(for: question),
            axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(1 ... 6)
        .disabled(draft.skipped)
        .focused($focusedField, equals: .custom(question.id))
        .onSubmit {
            if isLastQuestion, pending.isComplete {
                onSubmit()
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: onSkipAll) {
                Label("Skip All", systemImage: "forward.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            if let question = currentQuestion {
                Button(currentDraft.skipped ? "Answer Question" : "Skip Question") {
                    if currentDraft.skipped {
                        emitDraft(AgentAskUserDraft(), for: question)
                    } else {
                        skipCurrentQuestion(question)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button("Back") {
                goToQuestion(currentIndex - 1)
            }
            .disabled(isFirstQuestion)

            if isLastQuestion {
                Button(action: onSubmit) {
                    Label("Submit Answers", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!pending.isComplete)
                .keyboardShortcut(.return, modifiers: .shift)
            } else {
                Button("Next") {
                    goToQuestion(currentIndex + 1)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canMoveForward)
            }
        }
    }

    private func customResponseBinding(for question: AgentAskUserQuestion) -> Binding<String> {
        Binding(
            get: {
                (pending.draftsByQuestionID[question.id] ?? AgentAskUserDraft()).customResponse
            },
            set: { value in
                var draft = pending.draftsByQuestionID[question.id] ?? AgentAskUserDraft()
                draft.customResponse = value
                draft.skipped = false
                if !question.allowsMultiple, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.selectedOptionLabels = []
                }
                emitDraft(draft, for: question)
            }
        )
    }

    private func toggleOption(_ label: String, for question: AgentAskUserQuestion, draft: AgentAskUserDraft) {
        guard !draft.skipped else { return }
        var updated = draft
        if question.allowsMultiple {
            var selected = Set(updated.selectedOptionLabels)
            if selected.contains(label) {
                selected.remove(label)
            } else {
                selected.insert(label)
            }
            updated.selectedOptionLabels = question.optionLabels.filter { selected.contains($0) }
        } else {
            if updated.selectedOptionLabels.contains(label) {
                updated.selectedOptionLabels = []
            } else {
                updated.selectedOptionLabels = [label]
            }
            updated.customResponse = ""
        }
        updated.skipped = false
        emitDraft(updated, for: question)
    }

    private func skipCurrentQuestion(_ question: AgentAskUserQuestion) {
        emitDraft(AgentAskUserDraft(skipped: true), for: question)
        if !isLastQuestion {
            goToQuestion(currentIndex + 1)
        }
    }

    private func emitDraft(_ draft: AgentAskUserDraft, for question: AgentAskUserQuestion) {
        onDraftChange(question.id, draft)
        noteUserActivity()
    }

    private func goToQuestion(_ index: Int) {
        guard pending.interaction.questions.indices.contains(index) else { return }
        onQuestionIndexChange(index)
        noteUserActivity()
    }

    private var activitySignalInterval: TimeInterval {
        max(0.05, min(1.0, pending.interaction.timeoutSeconds / 3.0))
    }

    private func noteUserActivity() {
        let now = Date()
        let interval = activitySignalInterval
        if let lastActivitySignalAt {
            let elapsed = now.timeIntervalSince(lastActivitySignalAt)
            guard elapsed < interval else {
                cancelPendingActivitySignal()
                emitActivitySignal(at: now)
                return
            }

            activityWorkGate.schedule(after: interval - elapsed) {
                emitActivitySignal(at: Date())
            }
        } else {
            cancelPendingActivitySignal()
            emitActivitySignal(at: now)
        }
    }

    private func emitActivitySignal(at date: Date) {
        lastActivitySignalAt = date
        onUserActivity()
    }

    private func cancelPendingActivitySignal() {
        activityWorkGate.cancel()
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum FocusedField: Hashable {
        case option(String, String)
        case custom(String)
    }
}
