import SwiftUI

struct AgentNavigationHUDView: View {
    @ObservedObject var viewModel: AgentNavigationHUDViewModel
    let windowState: WindowState
    @FocusState private var queryFocused: Bool
    @State private var suppressHoverSelectionUntil = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { viewModel.dismiss() }
                    .accessibilityHidden(true)

                panel(maxSize: geometry.size)
                    .padding(.top, topInset(for: geometry.size))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                viewModel.refresh(currentWindow: windowState)
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Agent Session Switcher")
    }

    private func panel(maxSize: CGSize) -> some View {
        let width = min(CGFloat(520), max(360, maxSize.width - 48))
        let rowsHeight = rowListHeight(maxSize: maxSize)
        return VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            if viewModel.errorMessage != nil {
                errorSlot
            }
            rows(height: rowsHeight)
            footer
        }
        .padding(13)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(panelBackgroundStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.62), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 24, y: 14)
        .onAppear { queryFocused = true }
        .agentNavigationHUDKeys(
            viewModel: viewModel,
            onKeyboardNavigation: suppressHoverSelectionAfterKeyboardNavigation
        )
        .accessibilityElement(children: .contain)
    }

    private var panelBackgroundStyle: AnyShapeStyle {
        if reduceTransparency {
            AnyShapeStyle(Color(NSColor.windowBackgroundColor))
        } else {
            AnyShapeStyle(.regularMaterial)
        }
    }

    private func topInset(for size: CGSize) -> CGFloat {
        min(max(size.height * 0.10, 48), 104)
    }

    private var rowHeight: CGFloat {
        fontPreset.scaledClamped(46, min: 44, max: 58)
    }

    private func rowListHeight(maxSize: CGSize) -> CGFloat {
        guard !viewModel.filteredItems.isEmpty else { return 104 }
        let spacing: CGFloat = 4
        let visibleRows = CGFloat(min(viewModel.filteredItems.count, 6))
        let fullRowsHeight = visibleRows * rowHeight + max(0, visibleRows - 1) * spacing + 4
        let peekHeight = viewModel.filteredItems.count > 6 ? rowHeight * 0.55 : 0
        let maxRowsHeight = min(fullRowsHeight + peekHeight, max(160, maxSize.height * 0.56))
        let count = CGFloat(viewModel.filteredItems.count)
        let desired = count * rowHeight + max(0, count - 1) * spacing + 4
        return min(maxRowsHeight, max(96, desired))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.snapshot.title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 14, weight: .semibold))
                Text(summaryText)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            scopeControl
            Button {
                viewModel.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Agent Session Switcher")
        }
    }

    private var summaryText: String {
        var parts: [String] = [pluralized(viewModel.totalItemCount, singular: "session", plural: "sessions")]
        if viewModel.needsAttentionCount > 0 {
            parts.append("\(viewModel.needsAttentionCount) need attention")
        }
        if viewModel.isShowingLimitedResults {
            parts.append("showing \(viewModel.filteredItems.count); type to search all")
        }
        return parts.joined(separator: " · ")
    }

    private var scopeControl: some View {
        HStack(spacing: 2) {
            ForEach(AgentNavigationHUDMode.allCases) { mode in
                Button {
                    viewModel.setMode(mode, currentWindow: windowState)
                } label: {
                    Text(mode.scopeTitle)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            viewModel.snapshot.mode == mode
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear,
                            in: Capsule()
                        )
                        .foregroundStyle(viewModel.snapshot.mode == mode ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.scopeTitle)
            }
        }
        .padding(2)
        .background(Color(NSColor.controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.68), in: Capsule())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit {
                    Task { await viewModel.selectHighlighted(currentWindow: windowState) }
                }
            if viewModel.hiddenSubagentCount > 0 {
                subagentToggle
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.82), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 0.75)
        )
    }

    private var subagentToggle: some View {
        Button {
            viewModel.toggleSubagents()
        } label: {
            Text("Sub-agents")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    viewModel.showSubagents
                        ? Color.accentColor.opacity(0.16)
                        : Color(NSColor.controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.72),
                    in: Capsule()
                )
                .foregroundStyle(viewModel.showSubagents ? Color.accentColor : Color.secondary)
                .overlay(
                    Capsule()
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.showSubagents ? "Hide sub-agents" : "Show sub-agents")
        .hoverTooltip(viewModel.showSubagents ? "Hide sub-agent sessions (⌃S)" : "Show sub-agent sessions (⌃S)")
    }

    private var errorSlot: some View {
        Text(viewModel.errorMessage ?? "")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
            .foregroundStyle(.red)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.22), lineWidth: 0.75)
            )
    }

    private func rows(height: CGFloat) -> some View {
        let items = viewModel.filteredItems
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if items.isEmpty {
                        emptyState
                    } else {
                        ForEach(items) { item in
                            AgentNavigationHUDRow(
                                item: item,
                                isSelected: item.id == viewModel.selectedItemID,
                                fontPreset: fontPreset,
                                now: Date(),
                                showsSubagentRollup: !viewModel.showSubagents && viewModel.queryIsEmpty,
                                onHover: {
                                    guard Date() >= suppressHoverSelectionUntil else { return }
                                    viewModel.moveSelection(to: item.id)
                                }
                            ) {
                                Task { await viewModel.select(item, currentWindow: windowState) }
                            }
                            .frame(height: rowHeight)
                            .id(item.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: height)
            .onChange(of: viewModel.selectedItemID) { _, newValue in
                guard let newValue else { return }
                if reduceMotion {
                    proxy.scrollTo(newValue)
                } else {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(viewModel.queryIsEmpty ? viewModel.snapshot.mode.emptyTitle : "No matches for “\(viewModel.query)”")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                .foregroundStyle(.primary)
            Text(emptyHint)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .accessibilityElement(children: .combine)
    }

    private var emptyHint: String {
        if !viewModel.queryIsEmpty {
            return viewModel.snapshot.mode == .currentWindow
                ? "Press ⇧⌘K to search across all Agent sessions."
                : "Try a session title, workspace, worktree, or status."
        }
        return viewModel.snapshot.mode == .currentWindow
            ? "⌥⌘N starts a new Agent session."
            : "Recent, active, and attention-needing sessions appear here."
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerHint("↑↓", "Navigate")
            footerHint("↩", "Jump")
            footerHint(viewModel.snapshot.mode == .currentWindow ? "⇧⌘K" : "⌘K", viewModel.snapshot.mode == .currentWindow ? "All Agents" : "This Window")
            Spacer()
            footerHint("esc", viewModel.queryIsEmpty ? "Close" : "Clear")
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
        .foregroundStyle(.secondary)
    }

    private func suppressHoverSelectionAfterKeyboardNavigation() {
        suppressHoverSelectionUntil = Date().addingTimeInterval(0.28)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.55), lineWidth: 0.75)
                )
            Text(label)
        }
    }

    private func pluralized(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

private extension View {
    func agentNavigationHUDKeys(
        viewModel: AgentNavigationHUDViewModel,
        onKeyboardNavigation: @escaping () -> Void
    ) -> some View {
        onKeyPress(phases: [.down, .repeat]) { press in
            if press.modifiers == .control {
                if press.key == "n" {
                    onKeyboardNavigation()
                    viewModel.moveSelection(by: 1)
                    return .handled
                }
                if press.key == "p" {
                    onKeyboardNavigation()
                    viewModel.moveSelection(by: -1)
                    return .handled
                }
                if press.key == "s" {
                    viewModel.toggleSubagents()
                    return .handled
                }
            }
            switch press.key {
            case .escape:
                _ = viewModel.clearQueryOrDismiss()
                return .handled
            case .upArrow:
                onKeyboardNavigation()
                viewModel.moveSelection(by: -1)
                return .handled
            case .downArrow:
                onKeyboardNavigation()
                viewModel.moveSelection(by: 1)
                return .handled
            default:
                return .ignored
            }
        }
    }
}

private struct AgentNavigationHUDRow: View {
    let item: AgentNavigationHUDItem
    let isSelected: Bool
    let fontPreset: FontScalePreset
    let now: Date
    let showsSubagentRollup: Bool
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if item.displayDepth > 0 {
                    subagentIndent
                }
                AgentNavigationHUDStatusPlate(item: item, selected: isSelected)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if item.isActiveTab {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                                .accessibilityHidden(true)
                        }
                        Text(item.title)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                            .lineLimit(1)
                        if let status = item.statusLabel, status != "Idle" {
                            AgentNavigationHUDChip(text: status, tone: tone(for: item), selected: isSelected)
                        }
                        if showsSubagentRollup, let label = item.subagentChipLabel {
                            AgentNavigationHUDSubagentChip(
                                text: label,
                                attention: item.hasHiddenSubagentAttention,
                                selected: isSelected
                            )
                        }
                    }
                    HStack(spacing: 6) {
                        Text(item.workspaceTitle)
                            .lineLimit(1)
                        if item.windowTitle != item.workspaceTitle {
                            Text("·")
                            Text(item.windowTitle)
                                .lineLimit(1)
                        }
                        if item.isMCPControlled {
                            metadataPill("MCP", color: .orange)
                        }
                        if let worktree = item.worktree {
                            worktreeMetadata(worktree)
                        } else if let worktree = item.worktreeLabel {
                            Text("· worktree \(worktree)")
                        }
                        if let merge = item.mergeLabel {
                            Text("· Merge ready → \(merge)")
                        }
                    }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                }
                Spacer(minLength: 8)
                rowAccessory
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            if hovered { onHover() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var subagentIndent: some View {
        Color.clear
            .frame(width: CGFloat(item.displayDepth) * fontPreset.scaledClamped(9, min: 8, max: 12))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var rowAccessory: some View {
        if isSelected {
            Text("Jump ↩")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 42, alignment: .trailing)
        } else if !item.isActiveTab {
            Text(relativeActivityLabel)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(Color.secondary.opacity(0.82))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var relativeActivityLabel: String {
        let seconds = max(0, now.timeIntervalSince(item.latestActivityAt))
        if seconds < 60 { return "now" }
        if seconds < 60 * 60 { return "\(Int(seconds / 60))m" }
        if seconds < 24 * 60 * 60 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 24 * 60 * 60 { return "\(Int(seconds / 86400))d" }
        return DateFormatter.localizedString(from: item.latestActivityAt, dateStyle: .short, timeStyle: .none)
    }

    private var accessibilityLabel: String {
        var parts = [item.title]
        if item.isActiveTab { parts.append("current") }
        if !item.accessibilityStatusText.isEmpty { parts.append(item.accessibilityStatusText) }
        parts.append("workspace \(item.workspaceTitle)")
        if item.windowTitle != item.workspaceTitle { parts.append("window \(item.windowTitle)") }
        parts.append("active \(relativeActivityLabel) ago")
        return parts.joined(separator: ", ")
    }

    private func tone(for item: AgentNavigationHUDItem) -> AgentNavigationHUDChip.Tone {
        switch item.effectiveStatusState {
        case .waitingForUser, .waitingForQuestion, .waitingForApproval, .completed:
            .success
        case .failed, .cancelled:
            .danger
        case .running:
            item.isMCPControlled ? .mcp : .accent
        case .idle, .none:
            .secondary
        }
    }

    private func metadataPill(_ text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text("·")
            Text(text)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : color)
        }
    }

    private func worktreeMetadata(_ worktree: AgentWorktreeIndicator) -> some View {
        HStack(spacing: 4) {
            Text("·")
            AgentNavigationHUDWorktreeMarker(worktree: worktree, selected: isSelected)
                .frame(width: 7, height: 7)
            Text(worktree.label)
                .lineLimit(1)
        }
    }
}

private struct AgentNavigationHUDStatusPlate: View {
    let item: AgentNavigationHUDItem
    let selected: Bool

    private static let mcpAccentColor = Color.orange

    var body: some View {
        ZStack {
            Circle()
                .fill(plateFillColor)
            if showsWaitingHalo {
                Circle()
                    .stroke(Color.green.opacity(selected ? 0.9 : 0.55), lineWidth: 1.5)
            }
            if item.runState == .running {
                AgentNavigationHUDActivityArc(tint: runningAccentColor)
            }
            glyph
        }
        .overlay(alignment: .bottomTrailing) {
            if let worktree = item.worktree {
                AgentNavigationHUDWorktreeMarker(worktree: worktree, selected: selected)
                    .frame(width: 7, height: 7)
                    .padding(1.2)
                    .background(Circle().fill(selected ? Color.accentColor : Color(NSColor.controlBackgroundColor)))
                    .offset(x: 2.5, y: 2.5)
                    .accessibilityHidden(true)
            }
        }
    }

    private var runningAccentColor: Color {
        item.isMCPControlled && item.depth == 0 ? Self.mcpAccentColor : .accentColor
    }

    private var plateFillColor: Color {
        switch item.effectiveStatusState {
        case .running:
            .clear
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            Color.green.opacity(item.isUnseenAttention ? 0.22 : 0.15)
        case .completed:
            item.isUnseenAttention ? Color.green.opacity(0.18) : .clear
        case .failed:
            Color.red.opacity(item.isUnseenAttention ? 0.18 : 0.12)
        case .cancelled, .idle, .none:
            .clear
        }
    }

    private var showsWaitingHalo: Bool {
        guard item.isUnseenAttention else { return false }
        switch item.effectiveStatusState {
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if item.isUnseenAttention, item.effectiveStatusState == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(selected ? Color.white : Color.green)
        } else if item.isUnseenAttention, item.effectiveStatusState == .failed {
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(selected ? Color.white : Color.red)
        } else if item.isMCPControlled {
            Circle()
                .fill((selected ? Color.white : Self.mcpAccentColor).opacity(0.9))
                .frame(width: 5, height: 5)
        } else {
            Circle()
                .fill(dotColor.opacity(dotOpacity))
                .frame(width: item.runState == .running ? 4 : 3, height: item.runState == .running ? 4 : 3)
        }
    }

    private var dotColor: Color {
        if selected { return .white }
        if item.runState == .running { return runningAccentColor }
        return .secondary
    }

    private var dotOpacity: Double {
        if selected || item.runState == .running { return 1 }
        return 0.45
    }
}

private struct AgentNavigationHUDWorktreeMarker: View {
    let worktree: AgentWorktreeIndicator
    let selected: Bool

    var body: some View {
        if !worktree.isAvailable {
            Circle()
                .strokeBorder(selected ? Color.white.opacity(0.85) : Color.secondary, style: StrokeStyle(lineWidth: 1.3, dash: [1.6, 1.4]))
        } else if worktree.markerStyle == .ring {
            Circle()
                .strokeBorder(selected ? Color.white.opacity(0.9) : worktree.color, lineWidth: 1.7)
        } else {
            Circle()
                .fill(selected ? Color.white.opacity(0.92) : worktree.color)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        }
    }
}

private struct AgentNavigationHUDActivityArc: View {
    var tint: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.7)
            .stroke(
                tint.opacity(0.75),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .frame(width: 15, height: 15)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityLabel("Running")
    }
}

private struct AgentNavigationHUDSubagentChip: View {
    let text: String
    let attention: Bool
    let selected: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: attention ? .semibold : .medium))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundStyle, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(borderStyle, lineWidth: 0.75)
            )
    }

    private var foregroundStyle: Color {
        if selected { return Color.white.opacity(0.9) }
        return attention ? Color.orange : Color.secondary
    }

    private var backgroundStyle: Color {
        if selected { return Color.white.opacity(0.18) }
        return attention ? Color.orange.opacity(0.16) : Color(NSColor.systemGray).opacity(0.16)
    }

    private var borderStyle: Color {
        if selected { return Color.white.opacity(0.28) }
        return attention ? Color.orange.opacity(0.45) : Color.clear
    }
}

private struct AgentNavigationHUDChip: View {
    enum Tone {
        case accent
        case success
        case danger
        case mcp
        case secondary
    }

    let text: String
    let tone: Tone
    let selected: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(selected ? Color.white.opacity(0.18) : color.opacity(0.12), in: Capsule())
            .foregroundStyle(selected ? Color.white : color)
    }

    private var color: Color {
        switch tone {
        case .accent: .accentColor
        case .success: .green
        case .danger: .red
        case .mcp: .orange
        case .secondary: .secondary
        }
    }
}
