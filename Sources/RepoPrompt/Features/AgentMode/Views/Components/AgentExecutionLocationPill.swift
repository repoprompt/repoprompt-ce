import SwiftUI

struct AgentExecutionLocationPickerRegion<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    private let content: Content

    init(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.height = height
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }
}

enum AgentExecutionLocationPickerLayout {
    static let popoverBaseWidth: CGFloat = 300
    static let popoverMaxWidth: CGFloat = 360
    static let rowsBaseHeight: CGFloat = 288
    static let rowsMinHeight: CGFloat = 220
    static let rowsMaxHeight: CGFloat = 360

    static func popoverWidth(for fontPreset: FontScalePreset) -> CGFloat {
        fontPreset.scaledClamped(popoverBaseWidth, max: popoverMaxWidth)
    }

    static func rowsHeight(for fontPreset: FontScalePreset) -> CGFloat {
        fontPreset.scaledClamped(rowsBaseHeight, min: rowsMinHeight, max: rowsMaxHeight)
    }
}

// MARK: - Execution Location Pill

struct AgentExecutionLocationPill: View {
    let props: AgentExecutionLocationProps
    let loadExistingWorktrees: () async throws -> [AgentModeViewModel.AgentExecutionWorktreeSelection]
    let selectLocation: (AgentModeViewModel.InitialStartLocation, AgentModeViewModel.ExecutionLocationChangeConfirmation?) async -> AgentModeViewModel.ExecutionLocationChangeResult

    @State private var showPopover = false
    @State private var existingWorktrees: [AgentModeViewModel.AgentExecutionWorktreeSelection] = []
    @State private var isLoadingExistingWorktrees = false
    @State private var optionError: String?
    @State private var pendingConfirmedChoice: AgentModeViewModel.InitialStartLocation?
    @State private var pendingConfirmation: AgentModeViewModel.ExecutionLocationChangeConfirmation?
    @State private var showLocationChangeConfirmation = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var popoverWidth: CGFloat {
        AgentExecutionLocationPickerLayout.popoverWidth(for: fontPreset)
    }

    private var pillLabelMaxWidth: CGFloat {
        fontPreset.scaledClamped(170, max: 220)
    }

    private var existingWorktreeRowsMaxHeight: CGFloat {
        AgentExecutionLocationPickerLayout.rowsHeight(for: fontPreset)
    }

    private var optionRowWidth: CGFloat {
        popoverWidth - 16
    }

    private var optionRowContentWidth: CGFloat {
        optionRowWidth - 16
    }

    private var accentColor: Color {
        if let indicator = props.indicator {
            return indicator.isAvailable ? indicator.color : .orange
        }
        switch props.selection {
        case .local:
            return .secondary
        case .newWorktree:
            return .accentColor
        case let .existingWorktree(selection):
            return selection.colorHex.flatMap(Color.init(hex:)) ?? .accentColor
        }
    }

    private var iconName: String {
        switch props.selection {
        case .local:
            "laptopcomputer"
        case .newWorktree, .existingWorktree:
            "arrow.triangle.branch"
        }
    }

    private var label: String {
        props.indicator?.capsuleText ?? props.selection.label
    }

    private var usesNeutralChrome: Bool {
        guard props.indicator == nil,
              props.isEnabled,
              !props.isOperationInProgress
        else { return false }
        if case .local = props.selection {
            return true
        }
        return false
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius()
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                if props.isOperationInProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: iconName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
                Text(label)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: pillLabelMaxWidth, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, AgentPillMetrics.horizontalPadding())
            .frame(height: AgentPillMetrics.height())
            // Stay content-sized for ordinary labels while the text frame still caps and truncates long worktree names.
            .fixedSize(horizontal: true, vertical: false)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        usesNeutralChrome
                            ? Color.secondary.opacity(0.15)
                            : accentColor.opacity(0.35),
                        lineWidth: usesNeutralChrome ? 0.5 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-execution-location-pill")
        .disabled(!props.isEnabled)
        .hoverTooltip(props.indicator?.tooltipText ?? (props.disabledReason ?? "Choose this thread's execution location"), .top)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(props.isInitialSelection ? "Start in" : "Execution location")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                locationOption(.local, icon: "laptopcomputer")
                locationOption(.newWorktree, icon: "arrow.triangle.branch")

                Divider().padding(.vertical, 2)
                Text("Existing worktrees")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)

                existingWorktreePicker

                if props.isInitialSelection {
                    Text("Worktrees are applied when you first send.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 3)
                }
            }
            .padding(8)
            .frame(width: popoverWidth, alignment: .leading)
            .task(id: "\(props.tabID.uuidString):\(showPopover)") {
                let loadingTabID = props.tabID
                guard showPopover else {
                    existingWorktrees = []
                    optionError = nil
                    isLoadingExistingWorktrees = false
                    return
                }
                existingWorktrees = []
                isLoadingExistingWorktrees = true
                optionError = nil
                do {
                    let loaded = try await loadExistingWorktrees()
                    guard !Task.isCancelled, showPopover, props.tabID == loadingTabID else { return }
                    existingWorktrees = loaded
                } catch {
                    guard !Task.isCancelled, showPopover, props.tabID == loadingTabID else { return }
                    existingWorktrees = []
                    optionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                isLoadingExistingWorktrees = false
            }
        }
        .alert("Change execution location?", isPresented: $showLocationChangeConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingConfirmedChoice = nil
                pendingConfirmation = nil
            }
            Button(confirmationButtonTitle, role: .destructive) {
                guard let choice = pendingConfirmedChoice,
                      let confirmation = pendingConfirmation
                else { return }
                pendingConfirmedChoice = nil
                pendingConfirmation = nil
                applySelection(choice, confirmedBy: confirmation)
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var existingWorktreePicker: some View {
        AgentExecutionLocationPickerRegion(
            width: optionRowWidth,
            height: existingWorktreeRowsMaxHeight
        ) {
            if isLoadingExistingWorktrees {
                ProgressView().controlSize(.small).padding(.horizontal, 8).padding(.vertical, 6)
                    .accessibilityIdentifier("agent-execution-location-existing-loading")
            } else if let optionError {
                Text(optionError)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("agent-execution-location-existing-error")
            } else if existingWorktrees.isEmpty {
                Text("No other worktrees available")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("agent-execution-location-existing-empty")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(existingWorktrees) { selection in
                            existingWorktreeOption(ExistingWorktreePickerRow(selection: selection))
                        }
                    }
                    .frame(width: optionRowWidth, alignment: .leading)
                }
                .frame(width: optionRowWidth, height: existingWorktreeRowsMaxHeight)
                .scrollIndicators(.automatic)
                .accessibilityIdentifier("agent-execution-location-existing-list")
            }
        }
    }

    private struct ExistingWorktreePickerRow: Identifiable {
        let selection: AgentModeViewModel.AgentExecutionWorktreeSelection
        let title: String
        let subtitle: String
        let tooltip: String
        let iconName: String
        let isDisabled: Bool

        var id: String {
            selection.presentationID
        }

        init(selection: AgentModeViewModel.AgentExecutionWorktreeSelection) {
            self.selection = selection
            let worktreeName = Self.worktreeName(for: selection)
            let branchOrHead = Self.branchOrHeadLabel(for: selection)
            title = "\(branchOrHead) — \(worktreeName)"

            var subtitleParts = [Self.compactPath(selection.path)]
            if selection.isLocked {
                subtitleParts.append("locked")
            }
            if selection.isPrunable {
                subtitleParts.append("prunable")
            }
            subtitle = subtitleParts.joined(separator: " · ")

            var tooltipParts = [
                "Branch: \(branchOrHead)",
                "Worktree: \(worktreeName)",
                "Path: \(selection.path)"
            ]
            if selection.isLocked {
                tooltipParts.append("Locked: \(selection.lockReason ?? "no reason provided")")
            }
            if selection.isPrunable {
                tooltipParts.append("Prunable: \(selection.prunableReason ?? "Git reports this worktree as prunable")")
            }
            tooltip = tooltipParts.joined(separator: "\n")
            iconName = selection.isPrunable ? "exclamationmark.triangle" : "arrow.triangle.branch"
            isDisabled = selection.isPrunable
        }

        private static func branchOrHeadLabel(for selection: AgentModeViewModel.AgentExecutionWorktreeSelection) -> String {
            if let branch = selection.branch, !branch.isEmpty {
                return branch
            }
            if let head = selection.head, !head.isEmpty {
                return "Detached \(GitShortRef.shortHead(head))"
            }
            return selection.isDetached ? "Detached HEAD" : selection.label
        }

        private static func worktreeName(for selection: AgentModeViewModel.AgentExecutionWorktreeSelection) -> String {
            if let name = selection.name, !name.isEmpty {
                return name
            }
            let pathTail = URL(fileURLWithPath: selection.path).lastPathComponent
            return pathTail.isEmpty ? selection.label : pathTail
        }

        private static func compactPath(_ path: String) -> String {
            let url = URL(fileURLWithPath: path)
            let folder = url.lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            guard !folder.isEmpty else { return path }
            guard !parent.isEmpty else { return "…/\(folder)" }
            return "…/\(parent)/\(folder)"
        }
    }

    private func locationOption(_ selection: AgentModeViewModel.InitialStartLocation, icon: String) -> some View {
        let title: String?
        let subtitle: String?
        if case .local = selection {
            title = "Workspace checkout"
            subtitle = "Work locally in the open workspace"
        } else {
            title = nil
            subtitle = nil
        }
        return optionButton(selection: selection, icon: icon, title: title, subtitle: subtitle, isDisabled: false)
    }

    private func existingWorktreeOption(_ row: ExistingWorktreePickerRow) -> some View {
        optionButton(
            selection: .existingWorktree(row.selection),
            icon: row.iconName,
            title: row.title,
            subtitle: row.subtitle,
            tooltip: row.tooltip,
            isDisabled: row.isDisabled
        )
    }

    private func optionButton(
        selection: AgentModeViewModel.InitialStartLocation,
        icon: String,
        title: String? = nil,
        subtitle: String?,
        tooltip: String? = nil,
        isDisabled: Bool
    ) -> some View {
        ExecutionLocationOptionButton(
            selection: selection,
            icon: icon,
            title: title ?? selection.label,
            subtitle: subtitle,
            tooltip: tooltip,
            isSelected: isSelected(selection),
            isDisabled: isDisabled,
            fontPreset: fontPreset,
            rowWidth: optionRowContentWidth,
            applySelection: { selection in
                applySelection(selection)
            }
        )
    }

    private struct ExecutionLocationOptionButton: View {
        let selection: AgentModeViewModel.InitialStartLocation
        let icon: String
        let title: String
        let subtitle: String?
        let tooltip: String?
        let isSelected: Bool
        let isDisabled: Bool
        let fontPreset: FontScalePreset
        let rowWidth: CGFloat
        let applySelection: (AgentModeViewModel.InitialStartLocation) -> Void

        private var accessibilityIdentifier: String {
            switch selection {
            case .local:
                "agent-execution-location-option-local"
            case .newWorktree:
                "agent-execution-location-option-new-worktree"
            case let .existingWorktree(selection):
                "agent-execution-location-option-existing-\(selection.presentationID)"
            }
        }

        var body: some View {
            Button {
                guard !isDisabled else { return }
                applySelection(selection)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 12)
                    Image(systemName: icon)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(
                ExecutionLocationOptionRowButtonStyle(
                    isSelected: isSelected,
                    isDisabled: isDisabled,
                    rowWidth: rowWidth
                )
            )
            .accessibilityIdentifier(accessibilityIdentifier)
            .hoverTooltip(tooltip, .top)
            .accessibilityHint(isDisabled ? "Unavailable" : (tooltip ?? title))
        }
    }

    private struct ExecutionLocationOptionRowButtonStyle: ButtonStyle {
        let isSelected: Bool
        let isDisabled: Bool
        let rowWidth: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            HoverableButton(configuration: configuration) { isHovered in
                configuration.label
                    .frame(width: rowWidth, alignment: .leading)
                    .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(backgroundColor(isHovered: isHovered, isPressed: configuration.isPressed))
                    )
            }
        }

        private func backgroundColor(isHovered: Bool, isPressed: Bool) -> Color {
            if isSelected {
                return Color.accentColor.opacity(isPressed ? 0.28 : (isHovered ? 0.24 : 0.12))
            }
            return isPressed ? Color.accentColor.opacity(0.18) : (isHovered ? Color.accentColor.opacity(0.14) : .clear)
        }
    }

    private func isSelected(_ selection: AgentModeViewModel.InitialStartLocation) -> Bool {
        switch (props.selection, selection) {
        case (.local, .local), (.newWorktree, .newWorktree):
            true
        case let (.existingWorktree(current), .existingWorktree(candidate)):
            current.worktreeID == candidate.worktreeID && current.repositoryID == candidate.repositoryID
        default:
            false
        }
    }

    private var confirmationButtonTitle: String {
        pendingConfirmation == .activeRunStop ? "Stop Run and Change" : "Restart and Change"
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .activeRunStop:
            "Changing execution location stops the current run and restarts the agent/provider context for this thread. The in-flight request will not be replayed automatically."
        case .startedThreadRestart, nil:
            "Changing execution location restarts the agent/provider context for this thread. This may confuse the model or reduce conversational continuity."
        }
    }

    private func applySelection(
        _ selection: AgentModeViewModel.InitialStartLocation,
        confirmedBy confirmation: AgentModeViewModel.ExecutionLocationChangeConfirmation? = nil
    ) {
        Task {
            switch await selectLocation(selection, confirmation) {
            case .applied, .unchanged:
                showPopover = false
                optionError = nil
            case let .confirmationRequired(requiredConfirmation):
                pendingConfirmedChoice = selection
                pendingConfirmation = requiredConfirmation
                showLocationChangeConfirmation = true
            case let .blocked(message):
                optionError = message
            }
        }
    }
}
