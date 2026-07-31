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
    @State private var searchText: String = ""
    @State private var showDuplicateCleanupConfirmation = false
    @State private var duplicateCleanupResultMessage: String?
    @State private var isRunningDuplicateCleanup = false
    @State private var isImportingClassicRepoPrompt = false
    @State private var classicRepoPromptImportResultMessage: String?
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
            classicRepoPromptImportCallout

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
            "Classic RepoPrompt Import",
            isPresented: Binding(
                get: { classicRepoPromptImportResultMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        classicRepoPromptImportResultMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                classicRepoPromptImportResultMessage = nil
            }
        } message: {
            Text(classicRepoPromptImportResultMessage ?? "")
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
    private var classicRepoPromptImportCallout: some View {
        if classicRepoPromptSourceExists {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(.secondary)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 18))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Classic RepoPrompt")
                        .font(fontPreset.subheadlineFont)
                        .fontWeight(.medium)
                    Text("Import workspaces, sessions, settings, presets, prompts, models, workflows, and CLI/provider settings")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    runClassicRepoPromptImport()
                } label: {
                    if isImportingClassicRepoPrompt {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing...")
                        }
                    } else {
                        Text("Import...")
                    }
                }
                .buttonStyle(CustomButtonStyle(verticalPadding: 6, horizontalPadding: 12, height: fontPreset.scaledMetric(32)))
                .disabled(isImportingClassicRepoPrompt)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var classicRepoPromptSourceExists: Bool {
        ClassicRepoPromptImportService().defaultClassicSourceExists()
    }

    private func runClassicRepoPromptImport() {
        guard !isImportingClassicRepoPrompt else { return }
        isImportingClassicRepoPrompt = true

        Task { @MainActor in
            let result = await workspaceManager.importClassicRepoPromptData()
            isImportingClassicRepoPrompt = false
            classicRepoPromptImportResultMessage = result.userFacingSummary()
        }
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
                ForEach(group.duplicateWorkspaceIDs.indices, id: \.self) { index in
                    let workspaceID = group.duplicateWorkspaceIDs[index]
                    let name = group.duplicateWorkspaceNames[index]
                    let windowIDs = group.windowIDsByWorkspaceID[workspaceID] ?? []
                    HStack(spacing: 0) {
                        Text("  • \(name)")
                            .font(fontPreset.captionFont)
                        Text(" — \(windowStatusText(for: windowIDs))")
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

        if result.groupsConsolidated == result.groupsDetected && result.skipped.isEmpty {
            return "Successfully consolidated \(result.groupsConsolidated) duplicate workspace \(result.groupsConsolidated == 1 ? "group" : "groups").\(backupNote)"
        }

        let skippedNote = result.skipped.isEmpty
            ? ""
            : " \(result.skipped.count) \(result.skipped.count == 1 ? "item was" : "items were") skipped due to active sessions or failed switches \u{2014} try again after those sessions finish."

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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Existing Workspaces")
                    .font(fontPreset.headlineFont)
                Spacer()
                // Search field
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
            }

            let userWorkspaces = workspaceManager.workspaces.filter { !$0.isSystemWorkspace }
            let filteredWorkspaces = filterWorkspaces(userWorkspaces)

            // Show count when filtering
            if !searchText.isEmpty, !filteredWorkspaces.isEmpty {
                Text("Showing \(filteredWorkspaces.count) of \(userWorkspaces.count) workspaces")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }

            if userWorkspaces.isEmpty {
                Text("No workspaces found. Create one below.")
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            } else if filteredWorkspaces.isEmpty {
                Text("No workspaces match '\(searchText)'")
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            } else {
                // Use LazyVStack for better performance with many workspaces
                LazyVStack(spacing: 12) {
                    ForEach(filteredWorkspaces) { ws in
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
        }
    }

    private func toggleHiddenState(for ws: WorkspaceModel) {
        workspaceManager.setWorkspaceHidden(ws, hidden: !ws.isHiddenInMenus)
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
