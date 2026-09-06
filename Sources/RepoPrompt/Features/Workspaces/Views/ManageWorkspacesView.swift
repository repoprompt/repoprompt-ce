import SwiftUI

struct ManageWorkspacesView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManagerViewModel
    @EnvironmentObject var windowStatesManager: WindowStatesManager

    /// Whether this sheet/view is currently visible
    @Binding var isPresented: Bool

    // NEW: Optional param to control close button visibility
    var showCloseButton: Bool = true

    @State private var workspaceBeingRenamed: WorkspaceModel?
    @State private var renameField: String = ""
    @State private var showGlobalStorage: Bool = false
    @State private var showConsolidatedWorkspaces = false
    @State private var searchText: String = ""
    @State private var showDuplicateCleanupConfirmation = false
    @State private var duplicateCleanupResultMessage: String?
    @State private var isRunningDuplicateCleanup = false
    @State private var managementSelection = WorkspaceManagementSelectionState()
    @State private var leakCleanupPreview = WorkspaceLeakCleanupPreview.empty
    @State private var showBulkDeleteConfirmation = false
    @State private var isRunningBulkDelete = false
    @State private var bulkDeleteResultMessage: String?
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    /// Computed property for workspace name placeholder
    private var workspaceNamePlaceholder: String {
        guard !workspaceManager.creationDraft.selectedRepoPaths.isEmpty else {
            return "Workspace name"
        }

        // Get last components of each folder path
        let lastComponents = workspaceManager.creationDraft.selectedRepoPaths.map { path in
            URL(fileURLWithPath: path).lastPathComponent
        }

        return lastComponents.joined(separator: ", ")
    }

    private var duplicateGroups: [WorkspaceDuplicateGroupSummary] {
        workspaceManager.duplicateWorkspaceGroups(windowStates: windowStatesManager)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            autoRestoreToggle
            duplicateCleanupCallout
            leakedWorkspaceCleanupCallout

            // Collapsible Global Storage Management Section
            DisclosureGroup(
                isExpanded: $showGlobalStorage,
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if let globalURL = workspaceManager.globalCustomStorageURL {
                                Text("\(globalURL.path)")
                                    .truncationMode(.head)
                                    .font(fontPreset.subheadlineFont)
                            } else {
                                Text("Using Default Storage")
                                    .font(fontPreset.subheadlineFont)
                            }
                            Spacer()
                            Button {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let chosenURL = panel.urls.first {
                                    do {
                                        try workspaceManager.updateGlobalStoragePath(chosenURL)
                                    } catch {
                                        print("Failed to update global storage location: \(error)")
                                    }
                                }
                            } label: {
                                Text("Set Storage Location")
                            }
                            .buttonStyle(CustomButtonStyle())

                            if workspaceManager.globalCustomStorageURL != nil {
                                Button {
                                    do {
                                        try workspaceManager.resetGlobalStorageToDefault()
                                    } catch {
                                        print("Failed to reset global storage: \(error)")
                                    }
                                } label: {
                                    Text("Reset to Default")
                                }
                                .buttonStyle(CustomButtonStyle())
                            }
                        }
                    }
                    .padding(.top, 8)
                },
                label: {
                    Text("Global Storage Location")
                        .font(fontPreset.headlineFont)
                }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    createNewWorkspaceSection
                    Divider()
                    existingWorkspacesSection
                }
                .padding(16)
            }
        }
        .sheet(item: $workspaceBeingRenamed) { ws in
            renameSheet(workspace: ws)
        }
        .sheet(isPresented: $showDuplicateCleanupConfirmation) {
            duplicateCleanupConfirmationSheet(groups: duplicateGroups)
        }
        .sheet(isPresented: $showBulkDeleteConfirmation) {
            bulkDeleteConfirmationSheet
        }
        .task {
            await refreshLeakCleanupPreview()
        }
        .alert(
            "Workspace Cleanup",
            isPresented: Binding(
                get: { duplicateCleanupResultMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        duplicateCleanupResultMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                duplicateCleanupResultMessage = nil
            }
        } message: {
            Text(duplicateCleanupResultMessage ?? "")
        }
        .alert(
            "Bulk Delete Workspaces",
            isPresented: Binding(
                get: { bulkDeleteResultMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        bulkDeleteResultMessage = nil
                    }
                }
            )
        ) {
            Button("OK") { bulkDeleteResultMessage = nil }
        } message: {
            Text(bulkDeleteResultMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manage Workspaces")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .semibold))
                Text("Edit existing or create new workspaces")
                    .foregroundColor(.secondary)
                    .font(fontPreset.subheadlineFont)
            }
            Spacer()

            // Only show the x close button if showCloseButton is true
            if showCloseButton {
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var autoRestoreToggle: some View {
        Toggle("Restore workspaces on launch", isOn: $windowStatesManager.autoRestoreWorkspacesEnabled)
            .toggleStyle(.checkbox)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var duplicateCleanupCallout: some View {
        let groups = duplicateGroups
        if !groups.isEmpty {
            let dupCount = duplicateRecordCount(in: groups)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 20))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duplicate Workspaces Detected")
                            .font(fontPreset.headlineFont)
                        Text("Multiple workspace records share the same folders, which can cause MCP tools to open extra windows or route to the wrong workspace.")
                            .font(fontPreset.subheadlineFont)
                            .foregroundColor(.secondary)
                        Text("\(groups.count) \(groups.count == 1 ? "group" : "groups") with duplicates — \(dupCount) extra \(dupCount == 1 ? "record" : "records")")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        showDuplicateCleanupConfirmation = true
                    } label: {
                        Text("Consolidate Duplicates…")
                    }
                    .buttonStyle(CustomButtonStyle(verticalPadding: 6, horizontalPadding: 12, height: fontPreset.scaledMetric(32)))
                    .disabled(isRunningDuplicateCleanup)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var leakedWorkspaceCleanupCallout: some View {
        if !leakCleanupPreview.records.isEmpty {
            let deletableCount = leakCleanupPreview.deletableRecords.count
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "testtube.2")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Leaked Test Workspaces Detected")
                        .font(fontPreset.headlineFont)
                    Text("\(leakCleanupPreview.records.count) runtime-catalog \(leakCleanupPreview.records.count == 1 ? "record matches" : "records match") narrow persisted test-fixture evidence. No catalog records are removed until you review and confirm.")
                        .font(fontPreset.subheadlineFont)
                        .foregroundColor(.secondary)
                    if deletableCount != leakCleanupPreview.records.count {
                        Text("\(leakCleanupPreview.records.count - deletableCount) active or referenced \(leakCleanupPreview.records.count - deletableCount == 1 ? "record is" : "records are") protected.")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("Review…") {
                    managementSelection.begin()
                }
                .buttonStyle(CustomButtonStyle(verticalPadding: 6, horizontalPadding: 12, height: fontPreset.scaledMetric(32)))
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func duplicateCleanupConfirmationSheet(groups: [WorkspaceDuplicateGroupSummary]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Consolidate Duplicate Workspaces")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("What happens:")
                    .font(fontPreset.subheadlineFont)
                    .fontWeight(.medium)
                VStack(alignment: .leading, spacing: 4) {
                    cleanupBullet("A backup of all affected workspace records is created first")
                    cleanupBullet("Each group of duplicates is merged into a single record")
                    cleanupBullet("Windows with active chat, agent, or MCP sessions are left untouched")
                    cleanupBullet("Duplicate records still in active use are preserved")
                    cleanupBullet("No windows are closed automatically")
                }
            }
            .foregroundColor(.secondary)

            Text("The following \(groups.count == 1 ? "group" : "\(groups.count) groups") will be consolidated:")
                .font(fontPreset.subheadlineFont)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        duplicateGroupConfirmationRow(group)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: fontPreset.scaledClamped(320, max: 440))

            HStack {
                Spacer()
                Button("Cancel") {
                    showDuplicateCleanupConfirmation = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunningDuplicateCleanup)

                Button {
                    runDuplicateCleanup()
                } label: {
                    if isRunningDuplicateCleanup {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Consolidating…")
                        }
                    } else {
                        Text("Consolidate")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunningDuplicateCleanup || groups.isEmpty)
            }
        }
        .padding(20)
        .frame(width: fontPreset.scaledClamped(620, max: 760))
        .interactiveDismissDisabled(isRunningDuplicateCleanup)
    }

    private func duplicateGroupConfirmationRow(_ group: WorkspaceDuplicateGroupSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Keep (canonical)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(fontPreset.captionFont)
                Text("Keep:")
                    .font(fontPreset.subheadlineFont)
                    .fontWeight(.medium)
                Text(group.canonicalWorkspaceName)
                    .font(fontPreset.subheadlineFont)
            }
            Text("— \(windowStatusText(for: group.windowIDsByWorkspaceID[group.canonicalWorkspaceID] ?? []))")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .padding(.leading, 22)

            // Merge & remove (duplicates)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.orange)
                        .font(fontPreset.captionFont)
                    Text("Merge & remove:")
                        .font(fontPreset.subheadlineFont)
                        .fontWeight(.medium)
                }
                ForEach(group.duplicateWorkspaceRows) { row in
                    HStack(spacing: 0) {
                        Text("  • \(row.name)")
                            .font(fontPreset.captionFont)
                        Text(" — \(windowStatusText(for: row.windowIDs))")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Shared folders
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.secondary)
                        .font(fontPreset.captionFont)
                    Text("Shared folders:")
                        .font(fontPreset.subheadlineFont)
                        .fontWeight(.medium)
                }
                ForEach(group.normalizedRepoPaths, id: \.self) { path in
                    Text("  • \(abbreviatedPath(path))")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .hoverTooltip(path)
                        .accessibilityLabel(path)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func runDuplicateCleanup() {
        guard !isRunningDuplicateCleanup else { return }
        isRunningDuplicateCleanup = true

        Task {
            let result = await workspaceManager.consolidateDuplicateWorkspaces(windowStates: windowStatesManager)
            isRunningDuplicateCleanup = false
            showDuplicateCleanupConfirmation = false
            duplicateCleanupResultMessage = makeDuplicateCleanupResultMessage(for: result)
        }
    }

    private func makeDuplicateCleanupResultMessage(for result: WorkspaceDuplicateCleanupResult) -> String {
        if result.groupsDetected == 0 {
            return "No duplicate workspaces were found."
        }

        let backupNote = result.backupURL.map { "\n\nBackup saved at:\n\($0.path)" } ?? ""

        if result.groupsConsolidated == result.groupsDetected, result.skipped.isEmpty {
            return "Successfully consolidated \(result.groupsConsolidated) duplicate workspace \(result.groupsConsolidated == 1 ? "group" : "groups").\(backupNote)"
        }

        let skippedNote: String
        if result.skipped.isEmpty {
            skippedNote = ""
        } else {
            let itemDescription = result.skipped.count == 1 ? "item was" : "items were"
            skippedNote = " \(result.skipped.count) \(itemDescription) not fully consolidated."
                + " Some steps may have partially completed, but the original recovery copies were preserved."
                + " Review the remaining entries and retry."
        }

        return "Consolidated \(result.groupsConsolidated) of \(result.groupsDetected) duplicate \(result.groupsDetected == 1 ? "group" : "groups").\(skippedNote)\(backupNote)"
    }

    private func duplicateRecordCount(in groups: [WorkspaceDuplicateGroupSummary]) -> Int {
        groups.reduce(0) { $0 + $1.duplicateWorkspaceIDs.count }
    }

    private func windowStatusText(for windowIDs: [Int]) -> String {
        if windowIDs.isEmpty {
            "not currently open"
        } else if windowIDs.count == 1 {
            "open in window \(windowIDs[0])"
        } else {
            "open in windows \(windowIDs.map(String.init).joined(separator: ", "))"
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func cleanupBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(fontPreset.subheadlineFont)
    }

    // MARK: - Existing Workspaces

    private var existingWorkspacesSection: some View {
        let userWorkspaces = workspaceManager.workspaces.filter { !$0.isSystemWorkspace }
        let ordinaryWorkspaces = userWorkspaces.filter {
            $0.consolidatedIntoWorkspaceID == nil
                && !workspaceManager.pendingConsolidatedRestoreIDs.contains($0.id)
        }
        let consolidatedWorkspaces = userWorkspaces.filter {
            $0.consolidatedIntoWorkspaceID != nil
                || workspaceManager.pendingConsolidatedRestoreIDs.contains($0.id)
        }
        let ordinaryFilteredWorkspaces = filterWorkspaces(ordinaryWorkspaces)
        let filteredConsolidatedWorkspaces = filterWorkspaces(consolidatedWorkspaces)
        let filteredWorkspaceCount = ordinaryFilteredWorkspaces.count + filteredConsolidatedWorkspaces.count
        let managementItems = workspaceManagementItems(userWorkspaces: userWorkspaces)
        let filteredManagementItems = filterManagementItems(managementItems)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Existing Workspaces")
                    .font(fontPreset.headlineFont)
                Spacer()
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search workspaces...", text: $searchText)
                        .textFieldStyle(PlainTextFieldStyle())
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Clear workspace search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(6)
                .frame(width: fontPreset.scaledClamped(200, max: 280))

                if !managementSelection.isSelecting, !managementItems.isEmpty {
                    Button("Select") {
                        managementSelection.begin()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Enter workspace selection mode for bulk deletion")
                }
            }

            if managementSelection.isSelecting {
                selectionActionBar(filteredItems: filteredManagementItems)
            } else if !searchText.isEmpty, filteredWorkspaceCount > 0 {
                Text("Showing \(filteredWorkspaceCount) of \(userWorkspaces.count) workspaces")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }

            if managementSelection.isSelecting {
                if filteredManagementItems.isEmpty {
                    Text("No workspaces match '\(searchText)'")
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredManagementItems) { item in
                            selectionWorkspaceRow(item)
                        }
                    }
                }
            } else if userWorkspaces.isEmpty {
                Text("No workspaces found. Create one below.")
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            } else if ordinaryFilteredWorkspaces.isEmpty, filteredConsolidatedWorkspaces.isEmpty {
                Text("No workspaces match '\(searchText)'")
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(ordinaryFilteredWorkspaces) { ws in
                        OptimizedWorkspaceRow(
                            workspace: ws,
                            onSwitch: {
                                Task {
                                    let result = await workspaceManager.requestWorkspaceSwitch(to: ws)
                                    if result.didSwitch {
                                        isPresented = false
                                    }
                                }
                            },
                            onRename: {
                                workspaceBeingRenamed = ws
                                renameField = ws.name
                            },
                            onToggleHidden: {
                                toggleHiddenState(for: ws)
                            },
                            onDelete: {
                                workspaceManager.deleteWorkspace(ws)
                            }
                        )
                    }
                }
            }

            if !managementSelection.isSelecting, !filteredConsolidatedWorkspaces.isEmpty {
                consolidatedWorkspacesSection(filteredConsolidatedWorkspaces)
            }
        }
    }

    private func consolidatedWorkspacesSection(_ workspaces: [WorkspaceModel]) -> some View {
        DisclosureGroup(isExpanded: $showConsolidatedWorkspaces) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hidden recovery copies retained by workspace consolidation. Use the eye control to restore one.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)

                ForEach(workspaces) { workspace in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Consolidated into \(canonicalWorkspaceName(for: workspace))")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                        OptimizedWorkspaceRow(
                            workspace: workspace,
                            onSwitch: nil,
                            onRename: {
                                workspaceBeingRenamed = workspace
                                renameField = workspace.name
                            },
                            onToggleHidden: {
                                toggleHiddenState(for: workspace)
                            },
                            onDelete: {
                                workspaceManager.deleteWorkspace(workspace)
                            }
                        )
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Consolidated workspaces (\(workspaces.count))")
                .font(fontPreset.subheadlineFont)
        }
    }

    private func canonicalWorkspaceName(for workspace: WorkspaceModel) -> String {
        guard let canonicalID = workspace.consolidatedIntoWorkspaceID,
              let canonical = workspaceManager.workspaces.first(where: { $0.id == canonicalID })
        else {
            return "another workspace"
        }
        return canonical.name
    }

    private func workspaceManagementItems(
        userWorkspaces: [WorkspaceModel]
    ) -> [WorkspaceManagementItem] {
        let activeIDs = activeWorkspaceIDs
        var items = userWorkspaces.map { workspace in
            WorkspaceManagementItem(
                workspace: workspace,
                isLeakCleanupCandidate: false,
                evidence: [],
                deletionBlockReason: deletionBlockReason(for: workspace, activeWorkspaceIDs: activeIDs)
            )
        }
        let existingIDs = Set(items.map(\.id))
        items.append(contentsOf: leakCleanupPreview.records.compactMap { record in
            guard !existingIDs.contains(record.id) else { return nil }
            return WorkspaceManagementItem(
                workspace: record.workspace,
                isLeakCleanupCandidate: true,
                evidence: record.evidence,
                deletionBlockReason: record.deletionBlockReason
            )
        })
        return items.sorted {
            let comparison = $0.workspace.name.localizedCaseInsensitiveCompare($1.workspace.name)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
    }

    private func filterManagementItems(_ items: [WorkspaceManagementItem]) -> [WorkspaceManagementItem] {
        let matchingIDs = Set(filterWorkspaces(items.map(\.workspace)).map(\.id))
        return items.filter { matchingIDs.contains($0.id) }
    }

    private var activeWorkspaceIDs: Set<UUID> {
        Set(windowStatesManager.allWindows.compactMap { $0.workspaceManager.activeWorkspace?.id })
    }

    private func deletionBlockReason(
        for workspace: WorkspaceModel,
        activeWorkspaceIDs: Set<UUID>
    ) -> String? {
        if workspace.isSystemWorkspace {
            return "System workspaces cannot be deleted."
        }
        if activeWorkspaceIDs.contains(workspace.id) {
            return "Active in an open window."
        }
        let protectedTabs = workspace.composeTabs + workspace.stashedTabs.map(\.tab)
        if protectedTabs.contains(where: { $0.activeAgentSessionID != nil || $0.isPinned }) {
            return "Contains an active or pinned agent session."
        }
        return nil
    }

    private func selectionActionBar(filteredItems: [WorkspaceManagementItem]) -> some View {
        let matchingIDs = Set(filteredItems.map(\.id))
        let deletableMatchingIDs = filteredItems.compactMap { $0.isDeletable ? $0.id : nil }
        let selectedMatchingCount = managementSelection.selectedCount(in: matchingIDs)
        return HStack(spacing: 10) {
            Button("Select All Results") {
                handleSelectionMutation(managementSelection.selectAllResults(deletableMatchingIDs))
            }
            .disabled(deletableMatchingIDs.isEmpty)
            Text("\(managementSelection.selectedWorkspaceIDs.count) selected (\(selectedMatchingCount) of \(filteredItems.count) matching)")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
            Spacer()
            Button("Clear") { managementSelection.clear() }
                .disabled(managementSelection.selectedWorkspaceIDs.isEmpty)
            Button("Cancel") { managementSelection.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("Delete…") { showBulkDeleteConfirmation = true }
                .disabled(
                    managementSelection.selectedWorkspaceIDs.isEmpty
                        || managementSelection.selectedWorkspaceIDs.count > WorkspaceBulkDeletePolicy.maximumWorkspaceCount
                        || isRunningBulkDelete
                )
                .foregroundColor(.red)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(7)
    }

    private func selectionWorkspaceRow(_ item: WorkspaceManagementItem) -> some View {
        let selected = managementSelection.selectedWorkspaceIDs.contains(item.id)
        let consolidatedDescription = item.workspace.consolidatedIntoWorkspaceID == nil
            ? ""
            : ", consolidated recovery copy"
        return Button {
            handleSelectionMutation(
                managementSelection.toggle(item.id, isDeletable: item.isDeletable)
            )
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundColor(item.isDeletable ? (selected ? .accentColor : .secondary) : .secondary.opacity(0.5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.workspace.name)
                            .font(fontPreset.subheadlineFont)
                        if item.workspace.consolidatedIntoWorkspaceID != nil {
                            Text("CONSOLIDATED")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        if item.isLeakCleanupCandidate {
                            Text("TEST CLEANUP")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                    }
                    if let path = item.workspace.repoPaths.first {
                        Text(abbreviatedPath(path))
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if let reason = item.deletionBlockReason {
                        Text(reason)
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    } else if item.isLeakCleanupCandidate {
                        Text(item.evidence.joined(separator: " • "))
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(9)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
        .disabled(!item.isDeletable)
        .accessibilityLabel("\(item.workspace.name)\(consolidatedDescription), \(selected ? "selected" : "not selected")")
        .accessibilityHint(item.deletionBlockReason ?? "Toggle workspace selection")
    }

    private var bulkDeleteConfirmationSheet: some View {
        let allItems = workspaceManagementItems(
            userWorkspaces: workspaceManager.workspaces.filter { !$0.isSystemWorkspace }
        )
        let selectedItems = allItems.filter {
            managementSelection.selectedWorkspaceIDs.contains($0.id)
        }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Delete \(selectedItems.count) \(selectedItems.count == 1 ? "Workspace" : "Workspaces")?")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 21, weight: .semibold))
            Text("This deletes the selected workspaces. Persisted records are removed from the authoritative runtime catalog; local temporary workspaces are discarded from this app session. Saved artifacts are then cleaned up on a best-effort basis, and any files that could not be removed will be reported. This cannot be undone.")
                .font(fontPreset.subheadlineFont)
                .foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(selectedItems.prefix(20)) { item in
                        Text("• \(item.workspace.name)")
                            .font(fontPreset.subheadlineFont)
                    }
                    if selectedItems.count > 20 {
                        Text("…and \(selectedItems.count - 20) more")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { showBulkDeleteConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunningBulkDelete)
                Button("Delete \(selectedItems.count)") {
                    runBulkDelete(approvedItems: selectedItems)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedItems.isEmpty
                        || selectedItems.count > WorkspaceBulkDeletePolicy.maximumWorkspaceCount
                        || isRunningBulkDelete
                )
            }
        }
        .padding(20)
        .frame(width: fontPreset.scaledClamped(520, max: 680))
        .interactiveDismissDisabled(isRunningBulkDelete)
    }

    private func runBulkDelete(approvedItems: [WorkspaceManagementItem]) {
        guard !approvedItems.isEmpty, !isRunningBulkDelete else { return }
        guard approvedItems.count <= WorkspaceBulkDeletePolicy.maximumWorkspaceCount else {
            bulkDeleteResultMessage = bulkDeleteLimitMessage(attemptedCount: approvedItems.count)
            return
        }
        isRunningBulkDelete = true
        let namesByWorkspaceID = Dictionary(uniqueKeysWithValues: approvedItems.map {
            ($0.id, $0.workspace.name)
        })
        Task {
            let result = await workspaceManager.deleteWorkspacesAsync(
                workspaceIDs: Set(approvedItems.map(\.id)),
                leakedTestFixtureWorkspaceIDs: Set(
                    approvedItems.filter(\.isLeakCleanupCandidate).map(\.id)
                )
            )
            await refreshLeakCleanupPreview()
            isRunningBulkDelete = false
            showBulkDeleteConfirmation = false
            if result.requestFailureReason == nil, result.retryableWorkspaceIDs.isEmpty {
                managementSelection.cancel()
            } else if result.requestFailureReason == nil {
                managementSelection.retainWorkspaceIDs(result.retryableWorkspaceIDs)
            }
            bulkDeleteResultMessage = makeBulkDeleteResultMessage(
                result,
                namesByWorkspaceID: namesByWorkspaceID
            )
        }
    }

    private func handleSelectionMutation(_ result: WorkspaceSelectionMutationResult) {
        guard case let .limitExceeded(maximum, attemptedCount) = result else { return }
        bulkDeleteResultMessage = "You tried to select \(attemptedCount) workspaces. Bulk deletion is limited to \(maximum) per request; the existing selection was kept. Narrow the search or clear the selection and try again."
    }

    private func bulkDeleteLimitMessage(attemptedCount: Int) -> String {
        "Bulk deletion is limited to \(WorkspaceBulkDeletePolicy.maximumWorkspaceCount) workspaces per request. The \(attemptedCount)-workspace request was not submitted and no records were changed."
    }

    private func makeBulkDeleteResultMessage(
        _ result: WorkspaceBulkDeleteResult,
        namesByWorkspaceID: [UUID: String]
    ) -> String {
        if let requestFailureReason = result.requestFailureReason {
            return requestFailureReason
        }
        var sections = [
            "Deleted \(result.deletedWorkspaceIDs.count) \(result.deletedWorkspaceIDs.count == 1 ? "workspace" : "workspaces"). \(result.alreadyAbsentWorkspaceIDs.count) were already absent."
        ]
        sections.append(contentsOf: formattedReasonGroups(
            title: "Protected or skipped",
            reasonsByWorkspaceID: result.skippedReasonsByWorkspaceID,
            namesByWorkspaceID: namesByWorkspaceID
        ))
        sections.append(contentsOf: formattedReasonGroups(
            title: "Failed; still selected for retry",
            reasonsByWorkspaceID: result.failedReasonsByWorkspaceID,
            namesByWorkspaceID: namesByWorkspaceID
        ))
        sections.append(contentsOf: formattedReasonGroups(
            title: "Catalog removal succeeded, but saved artifact cleanup was incomplete",
            reasonsByWorkspaceID: result.artifactCleanupWarningsByWorkspaceID,
            namesByWorkspaceID: namesByWorkspaceID
        ))
        if !result.retryableWorkspaceIDs.isEmpty {
            sections.append("\(result.retryableWorkspaceIDs.count) unresolved \(result.retryableWorkspaceIDs.count == 1 ? "workspace remains" : "workspaces remain") selected for targeted retry.")
        }
        return sections.joined(separator: "\n\n")
    }

    private func formattedReasonGroups(
        title: String,
        reasonsByWorkspaceID: [UUID: String],
        namesByWorkspaceID: [UUID: String]
    ) -> [String] {
        let grouped = Dictionary(grouping: reasonsByWorkspaceID.keys) {
            reasonsByWorkspaceID[$0] ?? "Unknown reason."
        }
        return grouped.keys.sorted().map { reason in
            let ids = grouped[reason, default: []]
            let names = ids.map { namesByWorkspaceID[$0] ?? $0.uuidString }
                .sorted()
            let shownNames = names.prefix(8).joined(separator: ", ")
            let remainder = names.count > 8 ? " and \(names.count - 8) more" : ""
            return "\(title) (\(names.count)): \(shownNames)\(remainder) — \(reason)"
        }
    }

    private func refreshLeakCleanupPreview() async {
        leakCleanupPreview = await workspaceManager.previewLeakedTestWorkspaces(
            protectedWorkspaceIDs: activeWorkspaceIDs
        )
        let availableIDs = Set(workspaceManagementItems(
            userWorkspaces: workspaceManager.workspaces.filter { !$0.isSystemWorkspace }
        ).map(\.id))
        managementSelection.removeUnavailableWorkspaceIDs(availableIDs)
    }

    private func toggleHiddenState(for ws: WorkspaceModel) {
        let isRecoveryCopy = ws.consolidatedIntoWorkspaceID != nil
            || workspaceManager.pendingConsolidatedRestoreIDs.contains(ws.id)
        workspaceManager.setWorkspaceHidden(
            ws,
            hidden: isRecoveryCopy ? false : !ws.isHiddenInMenus
        )
    }

    // MARK: - Create New Workspace

    private var createNewWorkspaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a New Workspace")
                .font(fontPreset.headlineFont)

            HStack(spacing: 8) {
                TextField(
                    "Workspace name",
                    text: $workspaceManager.creationDraft.name,
                    prompt: Text(workspaceNamePlaceholder)
                )
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(minWidth: fontPreset.scaledMetric(150))

                Button(action: pickFoldersForNewWorkspace) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Add Folders")
                    }
                }
                .buttonStyle(CustomButtonStyle(
                    verticalPadding: 4,
                    horizontalPadding: 8,
                    height: fontPreset.scaledMetric(28)
                ))
            }

            if !workspaceManager.creationDraft.selectedRepoPaths.isEmpty {
                Text("Folders: \(workspaceManager.creationDraft.selectedRepoPaths.joined(separator: ", "))")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Button(action: createWorkspaceFromDraft) {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("Create Workspace")
                }
            }
            .buttonStyle(CustomButtonStyle(
                verticalPadding: 6,
                horizontalPadding: 12,
                height: fontPreset.scaledMetric(32)
            ))
            .disabled(workspaceManager.creationDraft.name.trimmingCharacters(in: .whitespaces).isEmpty && workspaceManager.creationDraft.selectedRepoPaths.isEmpty)
        }
    }

    private func pickFoldersForNewWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            for url in panel.urls {
                let stdURL = url.standardizedFileURL
                workspaceManager.creationDraft.selectedRepoPaths.append(stdURL.path)
            }
        }
    }

    private func createWorkspaceFromDraft() {
        // Use the placeholder as the name if user didn't enter one
        let trimmedName = workspaceManager.creationDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty, !workspaceManager.creationDraft.selectedRepoPaths.isEmpty {
            workspaceManager.creationDraft.name = workspaceNamePlaceholder
        }

        if let created = workspaceManager.createWorkspaceFromDraft() {
            Task {
                let result = await workspaceManager.requestWorkspaceSwitch(to: created)
                if result.didSwitch {
                    isPresented = false
                }
            }
        }
    }

    // MARK: - Rename Sheet

    private func renameSheet(workspace: WorkspaceModel) -> some View {
        VStack(spacing: 16) {
            Text("Rename Workspace")
                .font(fontPreset.headlineFont)
            TextField("New name", text: $renameField)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(minWidth: fontPreset.scaledMetric(200))

            HStack {
                Spacer()
                Button("Cancel") {
                    workspaceBeingRenamed = nil
                }
                Button("Save") {
                    let finalName = renameField.trimmingCharacters(in: .whitespaces)
                    guard !finalName.isEmpty else { return }
                    workspaceManager.renameWorkspace(workspace, newName: finalName)
                    workspaceBeingRenamed = nil
                }
            }
        }
        .padding()
        .frame(width: fontPreset.scaledClamped(360, max: 460))
    }

    // MARK: - Workspace Filtering

    private func filterWorkspaces(_ workspaces: [WorkspaceModel]) -> [WorkspaceModel] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return workspaces
        }

        let searchLower = searchText.lowercased()

        return workspaces.filter { workspace in
            // Check workspace name
            if workspace.name.lowercased().contains(searchLower) {
                return true
            }

            // Check paths in the workspace
            for path in workspace.repoPaths {
                // Check last component (folder name)
                let lastComponent = URL(fileURLWithPath: path).lastPathComponent.lowercased()
                if lastComponent.contains(searchLower) {
                    return true
                }

                // Also check if search term appears anywhere in the full path
                if path.lowercased().contains(searchLower) {
                    return true
                }
            }

            return false
        }
    }
}

private struct WorkspaceManagementItem: Identifiable {
    let workspace: WorkspaceModel
    let isLeakCleanupCandidate: Bool
    let evidence: [String]
    let deletionBlockReason: String?

    var id: UUID {
        workspace.id
    }

    var isDeletable: Bool {
        deletionBlockReason == nil
    }
}
