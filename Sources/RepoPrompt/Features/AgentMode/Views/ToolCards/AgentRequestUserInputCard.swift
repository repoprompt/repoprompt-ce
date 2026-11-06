import SwiftUI

struct AgentRequestUserInputCard: View {
    private static let otherOptionDescription = "Optionally, add details below."

    let request: AgentRequestUserInputRequest
    let allowsRememberedDecision: Bool
    let onSubmit: (AgentRequestUserInputResponse) -> Void
    let onStop: () -> Void

    private let pendingFocusStore: AgentRunInteractionUIStore
    private let pendingFocusTabID: UUID?

    @State private var draftsByQuestionID: [String: AgentRequestUserInputQuestionDraft]
    @FocusState private var focusedNoteQuestionID: String?

    init(
        request: AgentRequestUserInputRequest,
        allowsRememberedDecision: Bool = true,
        pendingFocusStore: AgentRunInteractionUIStore = .inertFocusSource,
        pendingFocusTabID: UUID? = nil,
        onSubmit: @escaping (AgentRequestUserInputResponse) -> Void,
        onStop: @escaping () -> Void
    ) {
        self.request = request
        self.allowsRememberedDecision = allowsRememberedDecision
        self.pendingFocusStore = pendingFocusStore
        self.pendingFocusTabID = pendingFocusTabID
        self.onSubmit = onSubmit
        self.onStop = onStop
        _draftsByQuestionID = State(initialValue: Self.makeDrafts(for: request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection

            ForEach(request.questions, id: \.id) { question in
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
        .agentPendingCardFocus(store: pendingFocusStore, tabID: pendingFocusTabID, focusTarget: focusFirstNote)
        .onChange(of: request.id) { _, _ in
            draftsByQuestionID = Self.makeDrafts(for: request)
        }
    }

    private func showsNoteField(for question: AgentRequestUserInputQuestion) -> Bool {
        // CU legacy approval answers are literal one-shot choices, never arbitrary scope text.
        allowsRememberedDecision || !question.isLegacyMCPToolApproval
    }

    /// Answers are typed, so the first note field is the natural target.
    private func focusFirstNote() {
        guard let question = request.questions.first, showsNoteField(for: question) else { return }
        focusedNoteQuestionID = question.id
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.title2)
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Questions")
                    .font(.headline)
                Text("Codex is waiting for your answers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(DateFormatter.localizedString(from: request.askedAt, dateStyle: .none, timeStyle: .short))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func questionSection(_ question: AgentRequestUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.header)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            Text(question.question)
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        optionRow(
                            question: question,
                            index: index,
                            label: option.label,
                            description: option.description
                        )
                    }
                    if question.isOtherOptionEnabled {
                        optionRow(
                            question: question,
                            index: question.options.count,
                            label: AgentRequestUserInputQuestion.otherOptionLabel,
                            description: Self.otherOptionDescription
                        )
                    }
                }
            }

            if showsNoteField(for: question) {
                if question.isSecret {
                    SecureField(notePlaceholder(for: question), text: noteBinding(for: question))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedNoteQuestionID, equals: question.id)
                } else {
                    TextField(notePlaceholder(for: question), text: noteBinding(for: question), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2 ... 6)
                        .focused($focusedNoteQuestionID, equals: question.id)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.35))
        .cornerRadius(8)
    }

    private func optionRow(
        question: AgentRequestUserInputQuestion,
        index: Int,
        label: String,
        description: String
    ) -> some View {
        let isSelected = selectedOptionIndex(for: question) == index
        return Button {
            selectOption(index, for: question)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .foregroundColor(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.15) : Color.blue.opacity(0.05))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.blue.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var actionButtons: some View {
        HStack {
            Button(action: onStop) {
                Label("Stop Turn", systemImage: "stop.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                onSubmit(request.buildResponse(from: draftsByQuestionID))
            } label: {
                Label("Submit Answers", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!Self.canSubmit(
                request: request,
                drafts: draftsByQuestionID,
                allowsRememberedDecision: allowsRememberedDecision
            ))
        }
    }

    /// Armed CU chats only accept the same one-shot answers the coordinator enforces;
    /// disabling Submit avoids a silent no-op when the draft would be rejected.
    static func canSubmit(
        request: AgentRequestUserInputRequest,
        drafts: [String: AgentRequestUserInputQuestionDraft],
        allowsRememberedDecision: Bool
    ) -> Bool {
        guard !allowsRememberedDecision else { return true }
        return request.allowsComputerUseResponse(request.buildResponse(from: drafts))
    }

    private func notePlaceholder(for question: AgentRequestUserInputQuestion) -> String {
        question.options.isEmpty ? "Type your answer" : "Add details (optional)"
    }

    private func selectedOptionIndex(for question: AgentRequestUserInputQuestion) -> Int? {
        draftsByQuestionID[question.id]?.selectedOptionIndex
    }

    private func selectOption(_ index: Int, for question: AgentRequestUserInputQuestion) {
        var draft = draftsByQuestionID[question.id] ?? .init()
        draft.selectedOptionIndex = draft.selectedOptionIndex == index ? nil : index
        draftsByQuestionID[question.id] = draft
    }

    private func noteBinding(for question: AgentRequestUserInputQuestion) -> Binding<String> {
        Binding(
            get: {
                draftsByQuestionID[question.id]?.note ?? ""
            },
            set: { newValue in
                var draft = draftsByQuestionID[question.id] ?? .init()
                draft.note = newValue
                draftsByQuestionID[question.id] = draft
            }
        )
    }

    private static func makeDrafts(for request: AgentRequestUserInputRequest) -> [String: AgentRequestUserInputQuestionDraft] {
        request.questions.reduce(into: [String: AgentRequestUserInputQuestionDraft]()) { partialResult, question in
            partialResult[question.id] = .init()
        }
    }
}
