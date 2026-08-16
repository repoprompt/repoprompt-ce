import SwiftUI

func agentContextFileBrowseTreeRootTitle(_ root: AgentContextFileBrowseRoot) -> String {
    root.scopeLabel
}

/// Inline workspace browser for the Context Composer Selections tab.
/// Renders the browse-mode metarow, search field, scope chips, and tree/search rows
/// over `AgentContextFileBrowseModel`; enabled checkboxes mutate the captured chat
/// selection immediately through the model.
struct AgentContextFileBrowseView: View {
    @ObservedObject var model: AgentContextFileBrowseModel

    @ObservedObject private var fontScale = FontScaleManager.shared
    @FocusState private var focus: AgentContextFileBrowseFocusTarget?

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var isSearchMode: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.query },
            set: { model.setQuery($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            metarow
            searchRow
            scopeRow
            browseRegion
        }
        .onAppear {
            focus = model.focusTarget
        }
        .onChange(of: model.focusTarget) { _, target in
            guard focus != target else { return }
            focus = target
        }
        .onChange(of: focus) { _, newValue in
            guard let newValue, newValue != model.focusTarget else { return }
            model.setFocusTarget(newValue)
        }
        .onChange(of: model.accessibilityAnnouncement) { _, announcement in
            guard let announcement else { return }
            AccessibilityNotification.Announcement(announcement.message).post()
        }
    }

    // MARK: - Metarow

    private var metarow: some View {
        HStack(spacing: 10) {
            Text("Add files")
                .font(fontPreset.standardFont.weight(.semibold))
            if let notice = model.notice {
                Text(notice.message)
                    .font(fontPreset.captionFont)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button {
                model.end()
            } label: {
                Text("Done")
                    .font(fontPreset.captionFont)
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 4, horizontalPadding: 9))
            .hoverTooltip("Return to selection review")
        }
    }

    // MARK: - Search row

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search files", text: queryBinding)
                .textFieldStyle(.plain)
                .focused($focus, equals: .search)
                .onKeyPress(.downArrow) {
                    model.focusNextRow()
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.focusPreviousRow()
                    return .handled
                }
                .onExitCommand {
                    model.clearQueryOrEnd()
                }
            if !model.query.isEmpty {
                Button {
                    model.setQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .hoverTooltip("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.textBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Scope row

    private var scopeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopeChip(
                    title: "All roots",
                    isActive: model.rootScope == .allRoots,
                    tooltip: "Browse every workspace root"
                ) {
                    model.setRootScope(.allRoots)
                }
                ForEach(model.roots, id: \.id) { root in
                    scopeChip(
                        title: root.scopeLabel,
                        isActive: model.rootScope == .root(root.id),
                        tooltip: root.physicalPath
                    ) {
                        model.setRootScope(.root(root.id))
                    }
                }
                Divider()
                    .frame(height: fontPreset.scaledMetric(14))
                codemapChip
            }
        }
    }

    private func scopeChip(
        title: String,
        isActive: Bool,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    isActive ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: Capsule()
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .hoverTooltip(tooltip)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Active scope" : "Inactive scope")
    }

    private var codemapChip: some View {
        let isActive = model.addMode == .codemapOnly
        let isDisabled = model.codeMapsGloballyDisabled
        return Button {
            model.setAddMode(isActive ? .full : .codemapOnly)
        } label: {
            Text("Codemap")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    isActive ? Color.purple.opacity(0.16) : Color.clear,
                    in: Capsule()
                )
                .foregroundStyle(isDisabled ? Color.secondary.opacity(0.5) : (isActive ? Color.purple : Color.secondary))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .hoverTooltip(
            isDisabled
                ? "Codemaps are globally disabled in Settings"
                : "Add newly checked files as codemap-only entries"
        )
        .accessibilityLabel("Codemap add mode")
        .accessibilityValue(isDisabled ? "Unavailable, codemaps are globally disabled" : (isActive ? "On" : "Off"))
    }

    // MARK: - Browse region

    private var browseRegion: some View {
        Group {
            switch model.phase {
            case .inactive, .loadingRoots:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(reason):
                unavailableState(reason)
            case .ready:
                if isSearchMode, model.rows.isEmpty {
                    emptyState(
                        icon: "magnifyingglass",
                        title: "No matches",
                        subtitle: "No files match this search."
                    )
                } else {
                    rowsScrollView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var rowsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                }
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.focusTarget) { _, target in
                guard case let .row(nodeID) = target else { return }
                proxy.scrollTo(AgentContextFileBrowseRow.ID.node(nodeID))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: AgentContextFileBrowseRow) -> some View {
        switch row {
        case let .root(root):
            containerRow(
                nodeID: .root(root.id),
                iconName: "folder",
                title: agentContextFileBrowseTreeRootTitle(root),
                tooltip: root.physicalPath,
                depth: 0
            )
        case let .folder(folder, depth):
            containerRow(
                nodeID: .folder(folder.id),
                iconName: "folder",
                title: folder.name,
                tooltip: folder.standardizedFullPath,
                depth: depth
            )
        case let .file(file, depth):
            fileRow(file, depth: isSearchMode ? 1 : depth)
        case let .searchRootHeader(group):
            searchHeader("\(group.root.scopeLabel) · \(group.matchCount) \(group.matchCount == 1 ? "match" : "matches")")
        case let .searchDirectoryHeader(group):
            searchHeader(group.directoryPath)
        case let .loading(_, depth):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
            .padding(.leading, indent(for: depth) + 8)
        case let .emptyContainer(_, depth):
            VStack(alignment: .leading, spacing: 2) {
                Text("No files")
                    .font(fontPreset.captionFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("This folder contains no selectable files.")
                    .font(fontPreset.captionFont)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.leading, indent(for: depth) + 8)
        }
    }

    private func searchHeader(_ text: String) -> some View {
        Text(text)
            .font(fontPreset.captionFont.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Container rows

    private func containerRow(
        nodeID: AgentContextFileBrowseNodeID,
        iconName: String,
        title: String,
        tooltip: String,
        depth: Int
    ) -> some View {
        let status = model.containerStatus(for: nodeID)
        let isExpanded = model.expandedNodeIDs.contains(nodeID)
        let estimate = model.tokenEstimate(for: nodeID)
        return HStack(spacing: 8) {
            containerCheckbox(nodeID: nodeID, title: title, status: status)
            Button {
                model.toggleExpansion(nodeID)
            } label: {
                Image(systemName: "chevron.right")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(title)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            Image(systemName: iconName)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(fontPreset.captionFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            tokenEstimateText(estimate)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .padding(.leading, indent(for: depth))
        .background(focusHighlight(for: nodeID))
        .contentShape(Rectangle())
        .onTapGesture {
            model.toggleExpansion(nodeID)
        }
        .focusable()
        .focused($focus, equals: .row(nodeID))
        .onKeyPress(.upArrow) {
            model.focusPreviousRow()
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.focusNextRow()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if isExpanded { model.toggleExpansion(nodeID) }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if !isExpanded { model.toggleExpansion(nodeID) }
            return .handled
        }
        .onKeyPress(.space) {
            model.toggleContainer(nodeID) ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            model.clearQueryOrEnd()
            return .handled
        }
        .hoverTooltip(tooltip)
        .onAppear {
            model.rowBecameVisible(nodeID)
        }
    }

    private func containerCheckbox(
        nodeID: AgentContextFileBrowseNodeID,
        title: String,
        status: AgentContextFileBrowseContainerStatus?
    ) -> some View {
        let checkboxState: CheckboxState = switch model.containerDisplayMembership(for: nodeID) {
        case .all: .checked
        case .mixed: .mixed
        case .none: .unchecked
        }
        let isDisabled = status?.toggleEligibility.targetState == nil
        return CheckboxView(isChecked: checkboxState) {
            guard model.toggleContainer(nodeID) else { return }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .hoverTooltip(containerCheckboxTooltip(nodeID: nodeID, title: title, status: status))
        .accessibilityLabel(containerCheckboxLabel(nodeID: nodeID, title: title, status: status))
        .accessibilityValue(containerCheckboxValue(nodeID: nodeID, status: status))
    }

    /// Text for a container whose descendants are not resolved yet. A collapsed folder is not
    /// loading, so it explains that expanding it is what enables the checkbox.
    private func unresolvedContainerDescription(
        nodeID: AgentContextFileBrowseNodeID,
        title: String
    ) -> String {
        if model.expandedNodeIDs.contains(nodeID) { return "Loading folder contents" }
        return model.containerDisplayMembership(for: nodeID) == .mixed
            ? "\(title) contains selected files \u{2014} expand it to change the selection"
            : "Expand \(title) to change its selection"
    }

    private func containerCheckboxTooltip(
        nodeID: AgentContextFileBrowseNodeID,
        title: String,
        status: AgentContextFileBrowseContainerStatus?
    ) -> String {
        guard let status else { return unresolvedContainerDescription(nodeID: nodeID, title: title) }
        if status.totalFileCount == 0 { return "This folder contains no selectable files" }
        if status.membership == .all {
            return "Remove \(status.selectedFileCount) selected \(pluralFiles(status.selectedFileCount)) in \(title)"
        }
        var text = "Add \(status.addableFileCount) \(pluralFiles(status.addableFileCount)) in \(title)"
        if model.addMode == .codemapOnly, status.unsupportedFileCount > 0 {
            text += " — \(status.unsupportedFileCount) \(pluralFiles(status.unsupportedFileCount)) cannot be added as codemaps"
        }
        return text
    }

    private func containerCheckboxLabel(
        nodeID: AgentContextFileBrowseNodeID,
        title: String,
        status: AgentContextFileBrowseContainerStatus?
    ) -> String {
        guard let status else { return unresolvedContainerDescription(nodeID: nodeID, title: title) }
        if status.membership == .all {
            return "Remove \(status.selectedFileCount) selected \(pluralFiles(status.selectedFileCount)) in \(title)"
        }
        return "Add \(status.addableFileCount) \(pluralFiles(status.addableFileCount)) in \(title)"
    }

    private func containerCheckboxValue(
        nodeID: AgentContextFileBrowseNodeID,
        status: AgentContextFileBrowseContainerStatus?
    ) -> String {
        guard let status else {
            if model.expandedNodeIDs.contains(nodeID) { return "Loading" }
            return model.containerDisplayMembership(for: nodeID) == .mixed ? "Mixed" : "Unchecked"
        }
        var parts = ["\(status.selectedFileCount) of \(status.selectableFileCount) selected"]
        if model.addMode == .codemapOnly {
            parts.append("codemap add mode")
            if status.unsupportedFileCount > 0 {
                parts.append("\(status.unsupportedFileCount) unsupported")
            }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - File rows

    private func fileRow(_ file: AgentContextFileBrowseFile, depth: Int) -> some View {
        let nodeID = AgentContextFileBrowseNodeID.file(file.id)
        let status = model.fileStatus(for: file)
        let heldMode = status.heldMode
        let isAutoMapped = status.isAutomaticallyMapped
        let isDisabled = status.toggleEligibility.targetState == nil
        let estimate = model.tokenEstimate(for: nodeID)
        return HStack(spacing: 8) {
            CheckboxView(isChecked: heldMode == nil ? .unchecked : .checked) {
                guard model.toggleFile(file) else { return }
            }
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.4 : 1)
            .hoverTooltip(fileCheckboxTooltip(file: file, heldMode: heldMode, isCodemapBlocked: status.isCodemapBlocked))
            .accessibilityLabel(fileCheckboxLabel(file: file, heldMode: heldMode))
            .accessibilityValue(fileCheckboxValue(heldMode: heldMode, isAutoMapped: isAutoMapped, estimate: estimate))
            .accessibilityHint(status.isCodemapBlocked ? codemapBlockedExplanation(file: file) : "")
            Image(systemName: "doc.text")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(file.name)
                .font(fontPreset.captionFont)
                .foregroundStyle(status.isCodemapBlocked ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let heldMode {
                heldModeBadge(heldMode)
            } else if isAutoMapped {
                autoMapBadge
            }
            tokenEstimateText(estimate)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .padding(.leading, indent(for: depth))
        .background(focusHighlight(for: nodeID))
        .contentShape(Rectangle())
        .focusable()
        .focused($focus, equals: .row(nodeID))
        .onKeyPress(.upArrow) {
            model.focusPreviousRow()
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.focusNextRow()
            return .handled
        }
        .onKeyPress(.space) {
            model.toggleFile(file) ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            model.clearQueryOrEnd()
            return .handled
        }
        .hoverTooltip(file.projectedDisplayPath)
        .onAppear {
            model.rowBecameVisible(nodeID)
        }
        .onDisappear {
            model.rowDisappeared(nodeID)
        }
    }

    private func fileCheckboxTooltip(
        file: AgentContextFileBrowseFile,
        heldMode: AgentContextFileBrowseHeldMode?,
        isCodemapBlocked: Bool
    ) -> String {
        if heldMode != nil { return "Remove \(file.name) from selection" }
        if isCodemapBlocked { return codemapBlockedExplanation(file: file) }
        return model.addMode == .full ? "Add \(file.name) as full file" : "Add \(file.name) as codemap"
    }

    private func fileCheckboxLabel(
        file: AgentContextFileBrowseFile,
        heldMode: AgentContextFileBrowseHeldMode?
    ) -> String {
        if heldMode != nil { return "Remove \(file.name) from selection" }
        return model.addMode == .full ? "Add \(file.name) as full file" : "Add \(file.name) as codemap"
    }

    private func fileCheckboxValue(
        heldMode: AgentContextFileBrowseHeldMode?,
        isAutoMapped: Bool,
        estimate: AgentContextFileBrowseTokenEstimate
    ) -> String {
        var parts: [String] = []
        switch heldMode {
        case .full: parts.append("Selected as full file")
        case .slice: parts.append("Selected as sliced file")
        case .codemap: parts.append("Selected as codemap")
        case nil: parts.append(isAutoMapped ? "Not selected, automatically codemapped" : "Not selected")
        }
        if case let .known(tokens) = estimate {
            parts.append("approximately \(tokens) tokens as full file")
        }
        return parts.joined(separator: ", ")
    }

    private func codemapBlockedExplanation(file: AgentContextFileBrowseFile) -> String {
        model.codeMapsGloballyDisabled
            ? "Codemaps are globally disabled in Settings"
            : "\(file.name) does not support codemaps"
    }

    // MARK: - Badges and estimates

    private func heldModeBadge(_ mode: AgentContextFileBrowseHeldMode) -> some View {
        let (text, color): (String, Color) = switch mode {
        case .full: ("Full", Color.accentColor)
        case .slice: ("Slice", Color.orange)
        case .codemap: ("Map", Color.purple)
        }
        return badge(text: text, color: color)
    }

    private var autoMapBadge: some View {
        badge(text: "Auto Map", color: Color.purple.opacity(0.6))
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.14))
            )
    }

    private func tokenEstimateText(_ estimate: AgentContextFileBrowseTokenEstimate) -> some View {
        let isCodemapMode = model.addMode == .codemapOnly
        return Text(Self.tokenText(for: estimate))
            .font(fontPreset.captionFont.monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(isCodemapMode ? 0.5 : 1)
            .fixedSize()
            .hoverTooltip(
                isCodemapMode
                    ? "Estimated full-file cost; codemap cost is available after selection"
                    : "Approximate full-file token cost"
            )
    }

    static func tokenText(for estimate: AgentContextFileBrowseTokenEstimate) -> String {
        switch estimate {
        case .notRequested, .loading, .unavailable:
            return "—"
        case let .known(tokens):
            if tokens < 1000 { return "~\(tokens)" }
            if tokens < 1_000_000 { return "~" + String(format: "%.1fk", Double(tokens) / 1000) }
            return "~" + String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }

    // MARK: - Shared row chrome

    private func indent(for depth: Int) -> CGFloat {
        CGFloat(depth) * 16
    }

    @ViewBuilder
    private func focusHighlight(for nodeID: AgentContextFileBrowseNodeID) -> some View {
        if model.focusTarget == .row(nodeID) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                )
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private func unavailableState(_ reason: AgentContextFileBrowseUnavailableReason) -> some View {
        switch reason {
        case .noRoots:
            emptyState(
                icon: "folder.badge.questionmark",
                title: "No workspace roots",
                subtitle: "Add a folder to the workspace to browse files."
            )
        case .sessionRootsUnavailable:
            emptyState(
                icon: "externaldrive.badge.questionmark",
                title: "Workspace unavailable",
                subtitle: "The Agent worktree roots for this chat are no longer available."
            )
        case .catalogChanged:
            emptyState(
                icon: "arrow.clockwise",
                title: "Workspace changed",
                subtitle: "Select Done, then browse again to refresh files."
            )
        case .selectionTargetUnavailable:
            emptyState(
                icon: "doc.text.magnifyingglass",
                title: "Selection unavailable",
                subtitle: "Selection is no longer available."
            )
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.45))
            Text(title)
                .font(fontPreset.standardFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(fontPreset.captionFont)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pluralFiles(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }
}
