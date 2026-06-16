import AppKit
import SwiftUI

/// Always-visible workspace roots section for Agent Mode sidebar.
/// One cohesive rounded card with material background containing:
///   - Workspace header (label, picker, exit)
///   - Folder list with add/remove
///   - Models + Permissions + Settings buttons at the bottom
///
/// SEARCH-HELPER: Agent Mode sidebar bottom bar, Models popover button,
/// Permissions popover button, Agent Mode settings gear, sidebar roots bottom bar
struct AgentWorkspaceRootsSectionView: View {
    @ObservedObject var rootsStore: AgentWorkspaceRootsSidebarStore
    let promptManager: PromptViewModel
    /// Plain `let` — the roots section forwards the reference into the Models
    /// popover, which reads availability lazily when its menu is opened. The
    /// bottom bar itself does not depend on API settings state.
    let apiSettingsVM: APISettingsViewModel
    let onManageWorkspaces: () -> Void
    /// Worktree indicators for the active Agent session, keyed by logical
    /// workspace-root path (raw and standardized forms). Empty when the active
    /// session has no worktree bindings.
    var worktreeIndicatorsByLogicalRootPath: [String: AgentWorktreeIndicator] = [:]
    /// Active worktree merge attentions for the active Agent session, keyed
    /// by logical workspace-root path. When non-empty, the matching root rows
    /// render a `MERGE → <target>` capsule beside the worktree capsule.
    var worktreeMergeAttentionsByLogicalRootPath: [String: AgentWorktreeMergeAttention] = [:]
    var branchSwitchActions: AgentWorkspaceBranchSwitchActions = .unavailable

    @State private var addFolderError: String?
    @State private var hoveredRootID: UUID?
    @FocusState private var focusedRootAction: RootActionFocus?
    @State private var showModelsPopover = false
    @State private var showPermissionsPopover = false
    @State private var isAddFolderHovered = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private struct RootActionFocus: Hashable {
        enum Action: Hashable {
            case moveUp
            case moveDown
            case remove
        }

        let rowID: UUID
        let action: Action
    }

    private static let estimatedFolderRowHeight: CGFloat = 28
    private static let folderListMaxHeight: CGFloat = 118
    private var estimatedFolderRowHeight: CGFloat {
        fontPreset.scaledMetric(Self.estimatedFolderRowHeight)
    }

    private var folderListMaxHeight: CGFloat {
        fontPreset.scaledClamped(Self.folderListMaxHeight, max: 170)
    }

    private var panelCornerRadius: CGFloat {
        fontPreset.scaledClamped(16, max: 22)
    }

    private var panelHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 10)
    }

    private var panelBottomPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 10)
    }

    private var headerHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(12, max: 18)
    }

    private var headerTopPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var headerBottomPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var headerVerticalSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var headerButtonSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var folderRowSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var folderCardVerticalPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    private var folderCardHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(2, max: 4)
    }

    private var rootRowSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var rootContextSpacing: CGFloat {
        fontPreset.scaledClamped(5, max: 7)
    }

    private var rootLineSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var rootFolderIconWidth: CGFloat {
        fontPreset.scaledClamped(14, min: 14, max: 18)
    }

    private var rootContextRowMinHeight: CGFloat {
        fontPreset.scaledClamped(39, min: 38, max: 52)
    }

    private var rootActionOverlaySpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var rootRowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var rootRowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 5)
    }

    private var rootRowCornerRadius: CGFloat {
        min(estimatedFolderRowHeight / 2, fontPreset.scaledClamped(16, max: 20))
    }

    private var addFolderCornerRadius: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var rootIconButtonSize: CGFloat {
        fontPreset.scaledClamped(20, min: 20, max: 26)
    }

    private var rootIconButtonIconSize: CGFloat {
        fontPreset.scaledClamped(9, min: 9, max: 12)
    }

    private var rootIconButtonCornerRadius: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    private var bottomBarSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var gearIconSize: CGFloat {
        fontPreset.scaledClamped(11, max: 14)
    }

    private var bottomBarHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var bottomBarBottomPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var worktreeCapsuleLabelMaxWidth: CGFloat {
        fontPreset.scaledClamped(118, min: 62, max: 154)
    }

    private var mergeCapsuleLabelMaxWidth: CGFloat {
        fontPreset.scaledClamped(92, min: 44, max: 126)
    }

    private var roots: [AgentWorkspaceRootRow] {
        rootsStore.rootRows.map { row in
            row.withWorktree(worktreeIndicator(for: row))
        }
    }

    /// Resolves the active session's worktree indicator bound to `row`, if any.
    private func worktreeIndicator(for row: AgentWorkspaceRootRow) -> AgentWorktreeIndicator? {
        if let direct = worktreeIndicatorsByLogicalRootPath[row.fullPath] {
            return direct
        }
        return worktreeIndicatorsByLogicalRootPath[row.standardizedFullPath]
    }

    /// Resolves the active worktree merge attention for `row`, if any.
    private func mergeAttention(for row: AgentWorkspaceRootRow) -> AgentWorktreeMergeAttention? {
        if let direct = worktreeMergeAttentionsByLogicalRootPath[row.fullPath] {
            return direct
        }
        return worktreeMergeAttentionsByLogicalRootPath[row.standardizedFullPath]
    }

    private var estimatedFolderListHeight: CGFloat {
        guard !roots.isEmpty else { return 0 }
        let rowHeights = roots.reduce(CGFloat(0)) { total, row in
            total + (rowHasContextLine(row) ? rootContextRowMinHeight : estimatedFolderRowHeight)
        }
        return rowHeights + CGFloat(max(roots.count - 1, 0)) * folderRowSpacing
    }

    private func rowHasContextLine(_ row: AgentWorkspaceRootRow) -> Bool {
        row.gitContext != nil || row.worktree != nil || mergeAttention(for: row) != nil
    }

    private var shouldScrollFolderList: Bool {
        estimatedFolderListHeight > folderListMaxHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────
            headerSection
                .padding(.horizontal, headerHorizontalPadding)
                .padding(.top, headerTopPadding)
                .padding(.bottom, headerBottomPadding)

            // ── Folders (add + list) ─────────────────────────
            foldersCard
                .padding(.horizontal, fontPreset.scaledClamped(4, max: 6))
                .padding(.bottom, fontPreset.scaledClamped(6, max: 9))

            // ── Bottom bar: Models + Settings ───────────────
            bottomBar
                .padding(.horizontal, bottomBarHorizontalPadding)
                .padding(.bottom, bottomBarBottomPadding)
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: -2)
        .padding(.horizontal, panelHorizontalPadding)
        .padding(.bottom, panelBottomPadding)
        .alert("Error Adding Folder", isPresented: Binding(
            get: { addFolderError != nil },
            set: { if !$0 { addFolderError = nil } }
        )) {
            Button("OK") { addFolderError = nil }
        } message: {
            if let error = addFolderError {
                Text(error)
            }
        }
    }

    // MARK: - Panel Background

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(.regularMaterial)

            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: headerButtonSpacing) {
            Text("Workspace")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            workspaceDropdown
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Button(action: {
                Task { await rootsStore.exitWorkspace() }
            }) {
                HStack(spacing: fontPreset.scaledClamped(4, max: 6)) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Exit")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                }
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 26))
            .hoverTooltip("Exit Workspace", .top)
            .disabled(rootsStore.isExitDisabled)
            .opacity(rootsStore.isExitDisabled ? 0.5 : 1)
        }
    }

    // MARK: - Workspace Dropdown

    private var workspaceDropdown: some View {
        WorkspacePickerMenu(
            workspaceManager: rootsStore.workspaceManagerForPicker,
            onManageWorkspaces: onManageWorkspaces
        ) {
            HStack(spacing: fontPreset.scaledClamped(4, max: 6)) {
                Text(rootsStore.workspaceLabel)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9))
            }
        }
        .buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 26))
        .hoverTooltip("Switch workspace", .top)
    }

    // MARK: - Folders Card

    private var foldersCard: some View {
        VStack(spacing: folderRowSpacing) {
            folderList

            addFolderRow
        }
        .padding(.vertical, folderCardVerticalPadding)
        .padding(.horizontal, folderCardHorizontalPadding)
        .overlay(alignment: .top) {
            Divider().opacity(0.4).padding(.horizontal, fontPreset.scaledClamped(8, max: 12))
        }
    }

    @ViewBuilder
    private var folderList: some View {
        if shouldScrollFolderList {
            ScrollView(.vertical) {
                folderRows
            }
            .frame(maxHeight: folderListMaxHeight)
            .scrollIndicators(.automatic)
        } else {
            folderRows
        }
    }

    private var folderRows: some View {
        VStack(spacing: folderRowSpacing) {
            ForEach(roots, id: \.id) { folder in
                rootRow(folder)
            }
        }
    }

    // MARK: - Add Folder Row

    private var addFolderRow: some View {
        Button(action: {
            Task {
                do {
                    try await rootsStore.addFolder()
                } catch {
                    addFolderError = error.localizedDescription
                }
            }
        }) {
            HStack(spacing: fontPreset.scaledClamped(5, max: 7)) {
                Image(systemName: "plus")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                Text("Add Folder")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, rootRowHorizontalPadding)
            .padding(.vertical, fontPreset.scaledClamped(4, max: 6))
            .frame(minHeight: estimatedFolderRowHeight)
            .background(
                RoundedRectangle(cornerRadius: addFolderCornerRadius)
                    .fill(isAddFolderHovered ? Color(NSColor.quaternaryLabelColor).opacity(0.5) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isAddFolderHovered = $0 }
    }

    // MARK: - Root Row

    private func rootRow(_ row: AgentWorkspaceRootRow) -> some View {
        let hasMultipleRoots = roots.count > 1
        let isHovered = hoveredRootID == row.id
        let hasFocusedAction = focusedRootAction?.rowID == row.id
        let hasContextLine = rowHasContextLine(row)

        return VStack(alignment: .leading, spacing: rootLineSpacing) {
            rootIdentityLine(row)

            if hasContextLine {
                rootContextLine(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            rootActionsOverlay(row, hasMultipleRoots: hasMultipleRoots)
                .opacity(isHovered || hasFocusedAction ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(false)
        }
        .padding(.horizontal, rootRowHorizontalPadding)
        .padding(.vertical, rootRowVerticalPadding)
        .frame(minHeight: hasContextLine ? rootContextRowMinHeight : estimatedFolderRowHeight)
        .background(
            RoundedRectangle(cornerRadius: rootRowCornerRadius)
                .fill(isHovered ? Color(NSColor.quaternaryLabelColor).opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        .contextMenu {
            rootRowContextMenu(row, hasMultipleRoots: hasMultipleRoots)
        }
        .onHover { hovered in
            hoveredRootID = hovered ? row.id : nil
        }
        .hoverTooltip(row.fullPath, .top)
    }

    private func rootIdentityLine(_ row: AgentWorkspaceRootRow) -> some View {
        HStack(spacing: rootRowSpacing) {
            Image(systemName: "folder.fill")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .foregroundColor(.secondary)
                .frame(width: rootFolderIconWidth, alignment: .leading)

            Text(row.name)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)

            if row.isPrimary {
                primaryBadge
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var primaryBadge: some View {
        Text("PRIMARY")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, fontPreset.scaledClamped(4, max: 6))
            .padding(.vertical, fontPreset.scaledClamped(1, max: 2))
            .background(
                Capsule()
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.75)
            )
    }

    private func rootContextLine(_ row: AgentWorkspaceRootRow) -> some View {
        HStack(spacing: rootContextSpacing) {
            if let gitContext = row.gitContext {
                gitContextCapsule(gitContext, row: row)
                    .layoutPriority(3)
            }

            if let worktree = row.worktree {
                worktreeCapsule(worktree)
                    .layoutPriority(2)
            }

            if let attention = mergeAttention(for: row) {
                mergeAttentionCapsule(attention)
                    .layoutPriority(0)
            }

            Spacer(minLength: 0)
        }
    }

    private func rootActionsOverlay(_ row: AgentWorkspaceRootRow, hasMultipleRoots: Bool) -> some View {
        HStack(spacing: rootActionOverlaySpacing) {
            if hasMultipleRoots {
                RootIconButton(
                    systemName: "chevron.up",
                    tooltip: "Move up",
                    size: rootIconButtonSize,
                    iconSize: rootIconButtonIconSize,
                    cornerRadius: rootIconButtonCornerRadius
                ) {
                    rootsStore.moveRootUp(rowID: row.id)
                }
                .focused($focusedRootAction, equals: RootActionFocus(rowID: row.id, action: .moveUp))
                .disabled(!row.canMoveUp)
                .opacity(row.canMoveUp ? 1 : 0.3)

                RootIconButton(
                    systemName: "chevron.down",
                    tooltip: "Move down",
                    size: rootIconButtonSize,
                    iconSize: rootIconButtonIconSize,
                    cornerRadius: rootIconButtonCornerRadius
                ) {
                    rootsStore.moveRootDown(rowID: row.id)
                }
                .focused($focusedRootAction, equals: RootActionFocus(rowID: row.id, action: .moveDown))
                .disabled(!row.canMoveDown)
                .opacity(row.canMoveDown ? 1 : 0.3)
            }

            RootIconButton(
                systemName: "xmark",
                tooltip: "Remove from workspace",
                size: rootIconButtonSize,
                iconSize: rootIconButtonIconSize,
                cornerRadius: rootIconButtonCornerRadius
            ) {
                rootsStore.removeRoot(rowID: row.id)
            }
            .focused($focusedRootAction, equals: RootActionFocus(rowID: row.id, action: .remove))
        }
        .padding(.horizontal, fontPreset.scaledClamped(3, max: 5))
        .padding(.vertical, fontPreset.scaledClamped(2, max: 3))
        .background(
            RoundedRectangle(cornerRadius: fontPreset.scaledClamped(7, max: 9), style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.14), radius: 4, x: 0, y: 1)
        )
    }

    // MARK: - Root Row Context Menu

    @ViewBuilder
    private func rootRowContextMenu(_ row: AgentWorkspaceRootRow, hasMultipleRoots: Bool) -> some View {
        Button("Copy Root Path") {
            copyToPasteboard(row.fullPath)
        }

        Button("Copy Root Name") {
            copyToPasteboard(row.name)
        }

        if let checkout = AgentWorkspaceRootContextValues.rootCheckout(for: row.gitContext) {
            Button(checkout.menuTitle) {
                copyToPasteboard(checkout.value)
            }
        }

        if let worktree = row.worktree {
            Divider()

            if let path = AgentWorkspaceRootContextValues.worktreePath(for: worktree) {
                Button(worktree.isAvailable ? "Copy Active Worktree Path" : "Copy Missing Worktree Path") {
                    copyToPasteboard(path)
                }
            }

            Button("Copy Bound Worktree Name") {
                copyToPasteboard(AgentWorkspaceRootContextValues.worktreeName(for: worktree))
            }

            if let branch = AgentWorkspaceRootContextValues.worktreeBranch(for: worktree) {
                Button("Copy Bound Worktree Branch") {
                    copyToPasteboard(branch)
                }
            }

            if worktree.isAvailable {
                Button("Reveal Active Worktree in Finder") {
                    if let path = AgentWorkspaceRootContextValues.worktreePath(for: worktree) {
                        revealInFinder(path: path)
                    }
                }
            }
        }

        Divider()

        if hasMultipleRoots {
            Button("Move Root Up") {
                rootsStore.moveRootUp(rowID: row.id)
            }
            .disabled(!row.canMoveUp)

            Button("Move Root Down") {
                rootsStore.moveRootDown(rowID: row.id)
            }
            .disabled(!row.canMoveDown)
        }

        Button("Remove from Workspace") {
            rootsStore.removeRoot(rowID: row.id)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Git Context Capsule

    private func gitContextCapsule(_ context: GitWorktreeContextSummary, row: AgentWorkspaceRootRow) -> some View {
        GitContextBranchSwitchCapsule(
            row: row,
            context: context,
            actions: branchSwitchActions
        )
    }

    // MARK: - Worktree Capsule

    /// Compact `WT <label>` capsule shown for a workspace root bound to a
    /// worktree in the active Agent session. Available worktrees keep their
    /// configured identity color; unavailable worktrees preserve the `WT label`
    /// text and add warning treatment without changing the saved identity color.
    @ViewBuilder
    private func worktreeCapsule(_ worktree: AgentWorktreeIndicator) -> some View {
        let tint = worktree.isAvailable ? worktree.color : Color.orange
        Group {
            if worktree.allowsCompactCapsule {
                ViewThatFits(in: .horizontal) {
                    worktreeCapsuleBody(worktree, tint: tint, isCompact: false)
                    worktreeCapsuleBody(worktree, tint: tint, isCompact: true)
                }
            } else {
                worktreeCapsuleBody(worktree, tint: tint, isCompact: false)
            }
        }
        .hoverTooltip(worktree.tooltipText, .top)
        .accessibilityLabel(worktree.accessibilityText)
    }

    private func worktreeCapsuleBody(
        _ worktree: AgentWorktreeIndicator,
        tint: Color,
        isCompact: Bool
    ) -> some View {
        let glyph = worktree.isAvailable ? worktree.iconName : "exclamationmark.triangle.fill"
        return HStack(spacing: fontPreset.scaledClamped(3, max: 4)) {
            Image(systemName: glyph)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 7, weight: .semibold))
            if isCompact {
                Text("WT")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
                    .lineLimit(1)
            } else {
                Text(worktree.capsuleText)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: worktreeCapsuleLabelMaxWidth, alignment: .leading)
            }
        }
        .foregroundColor(tint)
        .padding(.horizontal, fontPreset.scaledClamped(4, max: 6))
        .padding(.vertical, fontPreset.scaledClamped(1, max: 2))
        .background(
            Capsule().fill(tint.opacity(worktree.isAvailable ? 0.14 : 0.12))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(worktree.isAvailable ? 0.5 : 0.7), lineWidth: 0.75)
        )
    }

    // MARK: - Merge Attention Capsule

    /// `MERGE → <target>` capsule shown for workspace roots that participate
    /// in an active worktree merge for the active Agent session. It has the
    /// lowest row priority so it truncates before WT/branch at narrow widths.
    private func mergeAttentionCapsule(_ attention: AgentWorktreeMergeAttention) -> some View {
        let tint: Color = switch attention.kind {
        case .conflicted: .orange
        case .awaitingApproval: .purple
        case .awaitingCommit: .yellow
        }
        let glyph = switch attention.kind {
        case .conflicted: "exclamationmark.triangle.fill"
        case .awaitingApproval: "arrow.triangle.merge"
        case .awaitingCommit: "checkmark.circle"
        }
        return HStack(spacing: fontPreset.scaledClamped(3, max: 4)) {
            Image(systemName: glyph)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 7, weight: .semibold))
            Text("MERGE")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("→")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(attention.targetLabel)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: mergeCapsuleLabelMaxWidth, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: true)
        .foregroundColor(tint)
        .padding(.horizontal, fontPreset.scaledClamped(4, max: 6))
        .padding(.vertical, fontPreset.scaledClamped(1, max: 2))
        .background(
            Capsule().fill(tint.opacity(0.14))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 0.75)
        )
        .hoverTooltip(attention.tooltipText, .top)
        .accessibilityLabel(attention.tooltipText)
    }

    // MARK: - Bottom Bar (Models + Permissions + Settings)

    /// Bottom bar for the workspace roots card. Three controls:
    ///   - Models popover: Oracle / Plan model, Context Builder agent, sub-agent
    ///     role defaults (explore / engineer / pair / design)
    ///   - Permissions popover: sub-agent sandbox policy + deep links to the
    ///     full Agent Permissions page
    ///   - Gear: opens the Agent Mode settings Overview for everything else
    private var bottomBar: some View {
        HStack(spacing: bottomBarSpacing) {
            // Models button (Oracle + Context Builder + Role Defaults)
            Button(action: { showModelsPopover.toggle() }) {
                HStack(spacing: fontPreset.scaledClamped(4, max: 6)) {
                    Image(systemName: "brain")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    Text("Models")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                }
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 24))
            .hoverTooltip("Oracle, Context Builder, and sub-agent role models", .top)
            .popover(isPresented: $showModelsPopover, arrowEdge: .trailing) {
                AgentModelsPopoverView(
                    promptViewModel: promptManager,
                    apiSettingsVM: apiSettingsVM,
                    windowID: rootsStore.windowID
                )
            }

            // Permissions button (sub-agent sandbox policy + deep links)
            Button(action: { showPermissionsPopover.toggle() }) {
                HStack(spacing: fontPreset.scaledClamped(4, max: 6)) {
                    Image(systemName: "lock.shield")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    Text("Permissions")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                }
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 8, height: 24))
            .hoverTooltip("Sub-agent sandbox policy and Agent Permissions", .top)
            .popover(isPresented: $showPermissionsPopover, arrowEdge: .trailing) {
                AgentPermissionsPopoverView(
                    windowID: rootsStore.windowID
                )
            }

            Spacer()

            // Settings gear — opens Agent Mode Overview for everything else
            Button(action: {
                NotificationCenter.default.post(
                    name: .showAgentModeSettingsTab,
                    object: nil,
                    userInfo: ["windowID": rootsStore.windowID]
                )
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: gearIconSize))
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 0, horizontalPadding: 6, height: 24))
            .hoverTooltip("Agent Mode Settings", .top)
        }
    }
}

enum AgentWorkspaceRootCheckoutValue: Equatable {
    case branch(String)
    case head(String)

    var menuTitle: String {
        switch self {
        case .branch:
            "Copy Root Branch"
        case .head:
            "Copy Root HEAD"
        }
    }

    var value: String {
        switch self {
        case let .branch(value), let .head(value):
            value
        }
    }
}

enum AgentWorkspaceRootContextValues {
    static func rootCheckout(for context: GitWorktreeContextSummary?) -> AgentWorkspaceRootCheckoutValue? {
        guard let context else { return nil }
        if let branch = normalized(context.branch) {
            return .branch(branch)
        }
        if let head = normalized(context.head) {
            return .head(head)
        }
        return nil
    }

    static func worktreePath(for worktree: AgentWorktreeIndicator) -> String? {
        if worktree.isAvailable {
            return normalized(worktree.worktreeRootPath)
        }
        return worktree.missingWorktreePath
    }

    static func worktreeName(for worktree: AgentWorktreeIndicator) -> String {
        if let name = normalized(worktree.worktreeName) {
            return name
        }
        if let path = normalized(worktree.worktreeRootPath) {
            let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
            if !lastPathComponent.isEmpty {
                return lastPathComponent
            }
        }
        return worktree.label
    }

    static func worktreeBranch(for worktree: AgentWorktreeIndicator) -> String? {
        normalized(worktree.branch)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

// MARK: - Root Icon Button

private struct RootIconButton: View {
    let systemName: String
    let tooltip: String
    let size: CGFloat
    let iconSize: CGFloat
    let cornerRadius: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isHovered ? Color(NSColor.quaternaryLabelColor) : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(tooltip)
        .onHover { isHovered = $0 }
        .hoverTooltip(tooltip, .top)
    }
}
