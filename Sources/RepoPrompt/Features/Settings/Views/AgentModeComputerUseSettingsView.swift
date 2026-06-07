import SwiftUI

private enum ComputerUseSetupRowTreatment {
    case satisfied
    case pending
    case neutral

    var iconName: String {
        switch self {
        case .satisfied: "checkmark.circle.fill"
        case .pending: "circle.dashed"
        case .neutral: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .satisfied: .green
        case .pending: .orange
        case .neutral: .secondary
        }
    }
}

struct AgentModeComputerUseSettingsView: View {
    @StateObject private var viewModel: AgentModeComputerUseSettingsViewModel
    private let onNavigate: ((SettingsTab) -> Void)?

    init(
        viewModel: AgentModeComputerUseSettingsViewModel? = nil,
        onNavigate: ((SettingsTab) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel ?? AgentModeComputerUseSettingsViewModel())
        self.onNavigate = onNavigate
    }

    private var status: CodexComputerUseStatus {
        viewModel.status
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection
                statusSection
                setupSection
                safetySection
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { viewModel.refresh() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Codex Computer Use")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Set up the explicit /computer-use workflow for Codex Agent Mode. RepoPrompt exposes it only after setup is ready, even if you enable the opt-in first.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: status.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(status.isReady ? .green : .orange)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(status.statusTitle)
                                .font(.system(size: 15, weight: .semibold))
                            statusPill(status.isReady ? "Available" : "Unavailable", color: status.isReady ? .green : .orange)
                        }

                        Text(status.statusDetail)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if case .unsupported = status.liveAvailability {
                            Text("Live Codex tool availability cannot be verified before a turn in this build; static config and macOS permissions remain the setup gate.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if case .unknown = status.liveAvailability {
                            Text(status.liveAvailability.detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 12)

                    Button {
                        viewModel.refresh()
                    } label: {
                        Label(viewModel.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isRefreshing)
                }

                Divider()

                Toggle(isOn: Binding(get: { viewModel.optInEnabled }, set: viewModel.setOptInEnabled)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Enable /computer-use in Agent Mode")
                            .font(.system(size: 13, weight: .semibold))
                        Text(toggleDetailText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                HStack(spacing: 10) {
                    if let lastRefreshedAt = status.lastRefreshedAt {
                        Text("Last checked \(lastRefreshedAt.formatted(date: .omitted, time: .standard)).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if let message = viewModel.lastActionMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var setupSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    icon: "checklist",
                    title: "Setup Checklist",
                    detail: "Complete each prerequisite, then click Refresh. macOS may list RepoPrompt, Codex, or the helper that prompts for access; Screen Recording changes may require restarting RepoPrompt or Codex."
                )

                setupRow(
                    title: "Enable RepoPrompt Computer Use",
                    detail: "This opt-in can be enabled before setup is complete. /computer-use remains hidden until the rest of the checklist is ready.",
                    isSatisfied: status.optInEnabled,
                    pendingText: "Off",
                    satisfiedText: "On"
                ) {
                    EmptyView()
                }

                Divider()

                setupRow(
                    title: "Install or enable the Codex Computer Use plugin",
                    detail: status.pluginConfiguration.detail,
                    isSatisfied: status.pluginConfiguration.isConfigured,
                    pendingText: status.pluginConfiguration.title,
                    satisfiedText: status.pluginConfiguration.title
                ) {
                    Button {
                        viewModel.openCodexComputerUseGuide()
                    } label: {
                        Label("Open Guide", systemImage: "book")
                    }
                    Button {
                        viewModel.copyManualSetupInstructions(for: .plugin)
                    } label: {
                        Label("Copy Steps", systemImage: "doc.on.doc")
                    }
                }

                liveAvailabilityRow

                Divider()

                setupRow(
                    title: "Verify Screen Recording",
                    detail: screenRecordingDetailText,
                    isSatisfied: status.screenRecordingSatisfied,
                    pendingText: status.screenRecording.title,
                    satisfiedText: status.screenRecording.title
                ) {
                    Button {
                        viewModel.requestScreenRecordingAccess()
                    } label: {
                        Label("Request", systemImage: "hand.raised")
                    }
                    Button {
                        viewModel.openScreenRecordingSettings()
                    } label: {
                        Label("Open Settings", systemImage: "rectangle.on.rectangle")
                    }
                    Button {
                        viewModel.copyManualSetupInstructions(for: .screenRecording)
                    } label: {
                        Label("Copy Steps", systemImage: "doc.on.doc")
                    }
                }

                Divider()

                setupRow(
                    title: "Verify Accessibility",
                    detail: accessibilityDetailText,
                    isSatisfied: status.accessibilitySatisfied,
                    pendingText: status.accessibility.title,
                    satisfiedText: status.accessibility.title
                ) {
                    Button {
                        viewModel.requestAccessibilityAccess()
                    } label: {
                        Label("Request", systemImage: "hand.raised")
                    }
                    Button {
                        viewModel.openAccessibilitySettings()
                    } label: {
                        Label("Open Settings", systemImage: "hand.point.up.left")
                    }
                    Button {
                        viewModel.copyManualSetupInstructions(for: .accessibility)
                    } label: {
                        Label("Copy Steps", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    private var liveAvailabilityRow: some View {
        setupRow(
            title: "Verify live Computer Use tool availability",
            detail: status.liveAvailability.detail,
            isSatisfied: !status.liveAvailability.blocksReadiness,
            pendingText: status.liveAvailability.title,
            satisfiedText: status.liveAvailability.title,
            treatment: liveAvailabilityTreatment
        ) {
            Button {
                viewModel.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                viewModel.copyManualSetupInstructions(for: .liveAvailability)
            } label: {
                Label("Copy Steps", systemImage: "doc.on.doc")
            }
        }
    }

    private var liveAvailabilityTreatment: ComputerUseSetupRowTreatment {
        switch status.liveAvailability {
        case .available:
            .satisfied
        case .unavailable:
            .pending
        case .unknown, .unsupported:
            .neutral
        }
    }

    private var screenRecordingDetailText: String {
        if status.usesCodexManagedMacPermissions, !status.screenRecording.isGranted {
            return "Codex Computer Use is app-managed, so RepoPrompt does not need its own Screen Recording permission. If Codex itself blocks, grant access to Codex Computer Use in System Settings."
        }
        return "Allows Codex computer use to see target app windows and browser content while a task runs."
    }

    private var accessibilityDetailText: String {
        if status.usesCodexManagedMacPermissions, !status.accessibility.isGranted {
            return "Codex Computer Use is app-managed, so RepoPrompt does not need its own Accessibility permission. If Codex itself blocks, grant access to Codex Computer Use in System Settings."
        }
        return "Allows Codex computer use to click, type, and navigate target apps after you approve app access."
    }

    private var safetySection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    icon: "lock.shield",
                    title: "Safety Boundaries",
                    detail: "Computer Use adds desktop automation, but it does not collapse the existing approval layers."
                )

                safetyBoundaryRow(
                    icon: "macwindow",
                    title: "macOS permissions",
                    detail: "Screen Recording and Accessibility let Codex see and operate apps; they do not grant access to every app automatically."
                )
                safetyBoundaryRow(
                    icon: "app.badge.checkmark",
                    title: "Allowed target apps",
                    detail: "Codex asks before using an app. Keep the allow-list narrow and revoke Always Allow entries in Codex Settings when they are no longer needed."
                )
                safetyBoundaryRow(
                    icon: "checkmark.bubble",
                    title: "Codex approvals",
                    detail: "Codex can still ask for sensitive or disruptive action approval during a Computer Use task. Review those prompts separately from RepoPrompt MCP approvals."
                )
                safetyBoundaryRow(
                    icon: "shippingbox",
                    title: "RepoPrompt sandbox policy",
                    detail: "File reads, file edits, and shell commands continue to follow the selected Codex sandbox and approval policy for this Agent Mode session."
                )
                safetyBoundaryRow(
                    icon: "exclamationmark.octagon",
                    title: "Destructive-action confirmations",
                    detail: "Purchasing, sending, publishing, account-changing, deleting, or externally visible actions still require explicit user confirmation."
                )

                HStack(spacing: 10) {
                    Button {
                        onNavigate?(.agentPermissions)
                    } label: {
                        Label("Review Agent Permissions", systemImage: "lock.shield")
                    }
                    Button {
                        onNavigate?(.cliProviders)
                    } label: {
                        Label("Review CLI Providers", systemImage: "terminal")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    private var toggleDetailText: String {
        if status.isReady {
            return "When enabled, /computer-use appears for Codex sessions and activates Computer Use for one explicit turn."
        }
        if status.optInEnabled {
            return "Enabled, but /computer-use stays hidden until Codex configuration and macOS permissions are ready."
        }
        return "You can enable this now; RepoPrompt will expose /computer-use only after setup is complete."
    }

    private func setupRow(
        title: String,
        detail: String,
        isSatisfied: Bool,
        pendingText: String,
        satisfiedText: String,
        treatment: ComputerUseSetupRowTreatment? = nil,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        let rowTreatment = treatment ?? (isSatisfied ? .satisfied : .pending)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: rowTreatment.iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(rowTreatment.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    statusPill(isSatisfied ? satisfiedText : pendingText, color: rowTreatment.color)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                actions()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func safetyBoundaryRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func settingsCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private func sectionHeader(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
