import RepoPromptDomainRuntime
import SwiftUI

/// A reusable question card component for agent interactions.
/// Handles option selection, custom text input, and response submission.
struct AgentQuestionCard: View {
    let question: DiscoveryQuestion
    let onSubmit: (_ response: String) -> Void
    let onSkip: () -> Void
    var timeoutStartedAt: Date?
    var onUserActivity: ((_ questionID: UUID) -> Void)?

    /// Character to join multiple selections (default: newline)
    var responseJoiner: String = "\n"

    @State private var responseText: String = ""
    @State private var selectedOptions: Set<String> = []
    @State private var lastActivitySignalAt: Date?
    @State private var activityWorkGate = WorkItemGate()
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with question icon and timeout
            headerSection

            // Context (if provided)
            if let context = question.context, !context.isEmpty {
                Text(context)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(6)
            }

            // The question
            Text(question.question)
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

            // Options (if provided)
            if let options = question.options, !options.isEmpty {
                optionsSection(options: options)
            } else {
                // No options - just show text input
                TextField("Type your response...", text: $responseText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .other)
                    .onSubmit { submitIfValid() }
            }

            // Action buttons
            actionButtons
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .onAppear {
            resetDraftState()
        }
        .onChange(of: question.id) { _, _ in
            cancelPendingActivitySignal()
            lastActivitySignalAt = nil
            resetDraftState()
        }
        .onChange(of: responseText) { _, _ in
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

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.title2)
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Question")
                    .font(.headline)
                HStack(spacing: 4) {
                    Text("Waiting for your response...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if question.multiSelect {
                        Text("(multi-select)")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
            Spacer()
            let countdownAnchor = timeoutStartedAt ?? question.askedAt
            TimeoutCountdownView(startedAt: countdownAnchor, timeoutSeconds: question.timeoutSeconds)
                .id(countdownAnchor)
        }
    }

    // MARK: - Options

    private func optionsSection(options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Mode indicator
            HStack(spacing: 4) {
                Image(systemName: question.multiSelect ? "checklist" : "list.bullet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(question.multiSelect ? "Select all that apply" : "Select one option")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\u{21E5} Navigate  \u{2423} Toggle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)

            // Options list
            ForEach(options, id: \.self) { option in
                optionButton(option: option)
            }

            // "Other" text input
            otherInputRow
        }
    }

    private func optionButton(option: String) -> some View {
        Button(action: { toggleOption(option) }) {
            HStack {
                Image(
                    systemName: selectedOptions.contains(option) ?
                        (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle") :
                        (question.multiSelect ? "square" : "circle")
                )
                .font(.callout)
                .foregroundColor(selectedOptions.contains(option) ? .blue : .secondary)
                Text(option)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selectedOptions.contains(option) ? Color.blue.opacity(0.15) : Color.blue.opacity(0.05))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selectedOptions.contains(option) ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedField, equals: .option(option))
        .onKeyPress(.space) {
            toggleOption(option)
            return .handled
        }
        .focusEffectDisabled()
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(focusedField == .option(option) ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private var otherInputRow: some View {
        HStack {
            Image(
                systemName: !responseText.isEmpty ?
                    (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle") :
                    (question.multiSelect ? "square" : "circle")
            )
            .font(.callout)
            .foregroundColor(!responseText.isEmpty ? .blue : .secondary)
            TextField("Other...", text: $responseText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focusedField, equals: .other)
                .onSubmit { submitIfValid() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(!responseText.isEmpty ? Color.blue.opacity(0.15) : Color.blue.opacity(0.05))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(!responseText.isEmpty ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            Button(action: onSkip) {
                HStack(spacing: 4) {
                    Image(systemName: "forward.fill")
                        .font(.caption)
                    Text("Skip")
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: submitCombinedResponse) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(submitButtonLabel)
                    Text("\u{21E7}\u{23CE}")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasAnySelection)
            .keyboardShortcut(.return, modifiers: .shift)
        }
    }

    // MARK: - State Helpers

    private var hasAnySelection: Bool {
        !selectedOptions.isEmpty || !responseText.isEmpty
    }

    private var submitButtonLabel: String {
        if question.multiSelect, (selectedOptions.count + (responseText.isEmpty ? 0 : 1)) > 1 {
            return "Submit (\(selectedOptions.count + (responseText.isEmpty ? 0 : 1)))"
        }
        return "Submit"
    }

    private func toggleOption(_ option: String) {
        if question.multiSelect {
            if selectedOptions.contains(option) {
                selectedOptions.remove(option)
            } else {
                selectedOptions.insert(option)
            }
        } else {
            // Single select - clear others
            if selectedOptions.contains(option) {
                selectedOptions.removeAll()
            } else {
                selectedOptions = [option]
            }
            responseText = ""
        }
        noteUserActivity()
    }

    private func submitIfValid() {
        if hasAnySelection {
            submitCombinedResponse()
        }
    }

    private var activitySignalInterval: TimeInterval {
        max(0.05, min(1.0, question.timeoutSeconds / 3.0))
    }

    private func noteUserActivity() {
        guard onUserActivity != nil else { return }

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
        onUserActivity?(question.id)
    }

    private func cancelPendingActivitySignal() {
        activityWorkGate.cancel()
    }

    private func resetDraftState() {
        responseText = ""
        selectedOptions = []
    }

    // MARK: - Focus

    private enum FocusedField: Hashable {
        case option(String)
        case other
    }

    private func submitCombinedResponse() {
        var parts: [String] = []
        if !selectedOptions.isEmpty {
            parts.append(contentsOf: selectedOptions.sorted())
        }
        if !responseText.isEmpty {
            parts.append(responseText)
        }
        let response = parts.joined(separator: responseJoiner)
        onSubmit(response)
    }
}
