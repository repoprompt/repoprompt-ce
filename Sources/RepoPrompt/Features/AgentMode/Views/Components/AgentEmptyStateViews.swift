import SwiftUI

// MARK: - Empty State Models

struct AgentEmptyStateWorkflowItem: Identifiable {
    let definition: AgentWorkflowDefinition
    let description: String

    var id: String {
        definition.id
    }
}

struct AgentTipItem: Identifiable {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var id: String {
        "\(icon)-\(title)"
    }
}

// MARK: - Workflow Launch Card

struct AgentWorkflowLaunchCard: View {
    let item: AgentEmptyStateWorkflowItem
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: item.definition.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.definition.accentColor)
                        .frame(width: 26, height: 26)
                        .background(item.definition.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Text(item.definition.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text("Selected")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.definition.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(item.definition.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(!isSelected)
                }

                Text(item.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .background(backgroundShape.fill(cardBackgroundColor))
            .overlay(
                backgroundShape.stroke(cardBorderColor, lineWidth: isSelected ? 1 : 0.5)
            )
            .contentShape(backgroundShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    private var cardBackgroundColor: Color {
        if isSelected {
            return item.definition.accentColor.opacity(0.12)
        }
        if isHovered {
            return Color.primary.opacity(0.04)
        }
        return Color.primary.opacity(0.02)
    }

    private var cardBorderColor: Color {
        if isSelected {
            return item.definition.accentColor.opacity(0.55)
        }
        if isHovered {
            return Color.primary.opacity(0.12)
        }
        return Color.primary.opacity(0.06)
    }
}

// MARK: - Paginated Workflows

struct AgentPaginatedWorkflowsView: View {
    let workflows: [AgentEmptyStateWorkflowItem]
    let selectedWorkflowID: String?
    let onSelect: (AgentEmptyStateWorkflowItem) -> Void
    var editAction: (() -> Void)?

    @State private var selectedPageIndex = 0

    private static let pageSize = 4

    private var pages: [[AgentEmptyStateWorkflowItem]] {
        stride(from: 0, to: workflows.count, by: Self.pageSize).map { start in
            Array(workflows[start ..< min(start + Self.pageSize, workflows.count)])
        }
    }

    private var activePageIndex: Int {
        guard !pages.isEmpty else { return 0 }
        return min(selectedPageIndex, pages.count - 1)
    }

    private var hasPagination: Bool {
        pages.count > 1
    }

    var body: some View {
        if workflows.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 10) {
                headerRow

                let items = hasPagination ? pages[activePageIndex] : workflows
                workflowGrid(for: items)
                    .id(hasPagination ? activePageIndex : 0)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("Workflows")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if let editAction {
                Button(action: editAction) {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .medium))
                        Text("Edit")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .hoverTooltip("Browse and edit workflows")
            }

            Spacer()

            if hasPagination {
                paginationControls
            }
        }
    }

    private var paginationControls: some View {
        agentPaginationControls(
            count: pages.count,
            selectedIndex: activePageIndex,
            previous: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectedPageIndex = (activePageIndex - 1 + pages.count) % pages.count
                }
            },
            select: { index in
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedPageIndex = index
                }
            },
            next: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectedPageIndex = (activePageIndex + 1) % pages.count
                }
            }
        )
    }

    private func workflowGrid(for items: [AgentEmptyStateWorkflowItem]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10, alignment: .top),
                GridItem(.flexible(), spacing: 10, alignment: .top)
            ],
            spacing: 10
        ) {
            ForEach(items) { workflow in
                AgentWorkflowLaunchCard(
                    item: workflow,
                    isSelected: selectedWorkflowID == workflow.definition.id
                ) {
                    onSelect(workflow)
                }
            }
        }
    }
}

@MainActor
private func agentPaginationControls(
    count: Int,
    selectedIndex: Int,
    previous: @escaping () -> Void,
    select: @escaping (Int) -> Void,
    next: @escaping () -> Void
) -> some View {
    HStack(spacing: 8) {
        Button(action: previous) {
            Image(systemName: "chevron.left")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        HStack(spacing: 6) {
            ForEach(Array(0 ..< count), id: \.self) { index in
                Button { select(index) } label: {
                    Circle()
                        .fill(index == selectedIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
                .buttonStyle(.plain)
            }
        }

        Button(action: next) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rotating Tips

struct AgentRotatingTipsView: View {
    let tips: [AgentTipItem]

    @State private var selectedTipIndex: Int
    @State private var rotationRestartToken = UUID()

    init(tips: [AgentTipItem]) {
        self.tips = tips
        let startIndex = tips.isEmpty ? 0 : Int.random(in: 0 ..< tips.count)
        _selectedTipIndex = State(initialValue: startIndex)
    }

    private var activeTipIndex: Int {
        guard !tips.isEmpty else { return 0 }
        return min(selectedTipIndex, tips.count - 1)
    }

    var body: some View {
        if tips.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tips")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if tips.count > 1 {
                        agentPaginationControls(
                            count: tips.count,
                            selectedIndex: activeTipIndex,
                            previous: {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    selectedTipIndex = (activeTipIndex - 1 + tips.count) % tips.count
                                    rotationRestartToken = UUID()
                                }
                            },
                            select: { index in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedTipIndex = index
                                    rotationRestartToken = UUID()
                                }
                            },
                            next: {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    selectedTipIndex = (activeTipIndex + 1) % tips.count
                                    rotationRestartToken = UUID()
                                }
                            }
                        )
                    }
                }

                AgentTipCard(tip: tips[activeTipIndex])
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                    .id(tips[activeTipIndex].id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
            }
            .task(id: "\(tips.map(\.id).joined(separator: "|"))-\(rotationRestartToken.uuidString)") {
                selectedTipIndex = min(selectedTipIndex, max(tips.count - 1, 0))
                guard tips.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedTipIndex = (selectedTipIndex + 1) % tips.count
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tip Card

struct AgentTipCard: View {
    let tip: AgentTipItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tip.icon)
                .font(.system(size: 14))
                .foregroundStyle(tip.iconColor)
                .frame(width: 28, height: 28)
                .background(tip.iconColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(tip.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Text(tip.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Apply Edits Review Card

struct AgentApplyEditsReviewCard: View {
    let review: PendingApplyEditsReview
    let onAccept: () -> Void
    let onReject: (_ reason: String) -> Void

    @State private var rejectReason = ""
    @FocusState private var isReasonFieldFocused: Bool

    private var trimmedReason: String {
        rejectReason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canReject: Bool {
        !trimmedReason.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.line")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply Edits Review")
                        .font(.headline)
                    Text(review.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            if review.unifiedDiff.isEmpty {
                Text("No diff available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                UnifiedDiffView(diff: review.unifiedDiff, largeBodyMaxHeight: 340)
            }

            ZStack(alignment: .trailing) {
                TextField("Rejection reason", text: $rejectReason)
                    .textFieldStyle(.roundedBorder)
                    .focused($isReasonFieldFocused)
                    .onSubmit {
                        if canReject {
                            onReject(trimmedReason)
                        }
                    }

                if !rejectReason.isEmpty {
                    Button {
                        rejectReason = ""
                        isReasonFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .hoverTooltip("Clear")
                }
            }

            HStack {
                Button {
                    onReject(trimmedReason)
                } label: {
                    HStack(spacing: 4) {
                        Text("Reject")
                        Text("⌘⌫")
                            .font(.caption2)
                            .opacity(0.6)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canReject)
                .keyboardShortcut(.delete, modifiers: .command)
                .hoverTooltip("Reject edits (⌘⌫)")

                Spacer()

                Button {
                    onAccept()
                } label: {
                    HStack(spacing: 4) {
                        Text("Accept")
                        Text("⌘⏎")
                            .font(.caption2)
                            .opacity(0.6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .hoverTooltip("Accept edits (⌘⏎)")
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        )
    }
}
