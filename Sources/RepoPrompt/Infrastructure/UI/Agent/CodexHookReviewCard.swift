import SwiftUI

struct CodexHookReviewCardState: Equatable {
    private(set) var interactionID: UUID
    var selectedHookKeys = Set<String>()
    var isContinueConfirmationPresented = false
    var actionErrorMessage: String?

    mutating func synchronize(interactionID: UUID) {
        guard interactionID != self.interactionID else { return }
        self.interactionID = interactionID
        selectedHookKeys.removeAll()
        isContinueConfirmationPresented = false
        actionErrorMessage = nil
    }

    mutating func strictModeDidChange(isEnabled: Bool) {
        if isEnabled {
            isContinueConfirmationPresented = false
        }
    }
}

@MainActor
struct CodexHookReviewCard: View {
    let request: AgentCodexHookReviewRequest
    let isStrictModeEnabled: () -> Bool
    let onDecision: (AgentCodexHookReviewDecision) async throws -> Void

    /// Observed only to invalidate the card when the effective settings value may have changed.
    @ObservedObject private var settingsInvalidationSource: GlobalSettingsStore
    @State private var state: CodexHookReviewCardState

    init(
        request: AgentCodexHookReviewRequest,
        settingsInvalidationSource: GlobalSettingsStore = .shared,
        isStrictModeEnabled: @escaping () -> Bool,
        onDecision: @escaping (AgentCodexHookReviewDecision) async throws -> Void
    ) {
        self.request = request
        _settingsInvalidationSource = ObservedObject(wrappedValue: settingsInvalidationSource)
        self.isStrictModeEnabled = isStrictModeEnabled
        self.onDecision = onDecision
        _state = State(initialValue: CodexHookReviewCardState(interactionID: request.id))
    }

    private var isBusy: Bool {
        request.phase.isResolving
    }

    private var usesDiscoveryFailureLayout: Bool {
        request.phase == .discoveryFailed || (request.phase == .discovering && request.hooks.isEmpty)
    }

    var body: some View {
        let strictModeEnabled = isStrictModeEnabled()
        VStack(alignment: .leading, spacing: 12) {
            header
            if usesDiscoveryFailureLayout {
                discoveryFailureContent(strictModeEnabled: strictModeEnabled)
            } else {
                reviewContent(strictModeEnabled: strictModeEnabled)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .onChange(of: request.id) { _, newID in
            state.synchronize(interactionID: newID)
        }
        .onChange(of: strictModeEnabled) { _, isEnabled in
            state.strictModeDidChange(isEnabled: isEnabled)
        }
        .confirmationDialog(
            "Continue without enabling project hooks?",
            isPresented: $state.isContinueConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Continue Without Hooks", role: .destructive) {
                submit(.continueWithoutHooks)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(continueConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: usesDiscoveryFailureLayout ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.title2)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(usesDiscoveryFailureLayout ? "Project Hook Discovery Failed" : "Project Hooks Need Approval")
                    .font(.headline)
                Text("The initial Codex turn is paused")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func discoveryFailureContent(strictModeEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            metadataRow(label: "Execution directory", value: request.executionCWD, isCode: true)
            Text(request.errorMessage ?? "Codex could not discover project hooks for this directory.")
                .font(.callout)
                .foregroundColor(.red)
                .textSelection(.enabled)
            if let actionErrorMessage = state.actionErrorMessage, !actionErrorMessage.isEmpty {
                Text(actionErrorMessage)
                    .font(.callout)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if !strictModeEnabled {
                    continueButton
                }
                Spacer()
                Button {
                    submit(.retryDiscovery)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
    }

    private func reviewContent(strictModeEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review the repository-provided hooks below. No hook is selected by default.")
                .font(.callout)
                .foregroundColor(.secondary)
            metadataRow(label: "Execution directory", value: request.executionCWD, isCode: true)

            if let errorMessage = request.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }

            if let actionErrorMessage = state.actionErrorMessage, !actionErrorMessage.isEmpty {
                Text(actionErrorMessage)
                    .font(.callout)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }

            ForEach(request.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(request.hooks, id: \.key) { hook in
                    hookRow(hook)
                }
            }

            HStack {
                if !strictModeEnabled {
                    continueButton
                }
                Spacer()
                Button {
                    submit(.approveAll)
                } label: {
                    Label("Trust All Shown", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || request.hooks.isEmpty)

                Button {
                    submit(.approveSelected(hookKeys: request.hooks.compactMap { hook in
                        state.selectedHookKeys.contains(hook.key) ? hook.key : nil
                    }))
                } label: {
                    Label("Approve Selected & Continue", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || state.selectedHookKeys.isEmpty)
            }
        }
    }

    private var continueButton: some View {
        Button(role: .destructive) {
            state.isContinueConfirmationPresented = true
        } label: {
            Label("Continue Without Hooks", systemImage: "exclamationmark.triangle")
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
    }

    private func hookRow(_ hook: AgentCodexHookReviewHook) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if state.selectedHookKeys.contains(hook.key) {
                    state.selectedHookKeys.remove(hook.key)
                } else {
                    state.selectedHookKeys.insert(hook.key)
                }
            } label: {
                Image(systemName: state.selectedHookKeys.contains(hook.key) ? "checkmark.square.fill" : "square")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(state.selectedHookKeys.contains(hook.key) ? "Deselect hook" : "Select hook")

            VStack(alignment: .leading, spacing: 5) {
                Text(hook.key)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(hook.eventName)
                    Text(hook.enabled ? "Enabled" : "Disabled")
                    Text(hook.trustStatus.rawValue.capitalized)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                metadataRow(label: "Source", value: hook.sourcePath, isCode: true)
                metadataRow(label: "Current hash", value: hook.currentHash, isCode: true)
                if let command = hook.commandOrHandler, !command.isEmpty {
                    metadataRow(label: "Command / handler", value: command, isCode: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }

    private var continueConfirmationMessage: String {
        if request.phase == .discoveryFailed {
            return "This skips an unknown number of project hooks for the current Codex session. Repository guardrails may not run."
        }
        return "This skips \(request.hooks.count) project hook(s) for the current Codex session. Repository guardrails may not run."
    }

    private func submit(_ decision: AgentCodexHookReviewDecision) {
        state.actionErrorMessage = nil
        Task { @MainActor in
            do {
                try await onDecision(decision)
            } catch {
                state.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func metadataRow(label: String, value: String, isCode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(isCode ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
        }
    }
}
