import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext
import SwiftUI

/// Additive scene: no regular workspace sidebar, selection, or bottom panels are mounted here.
struct CommandCenterRootView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = CommandCenterReadModel.appModel()
    @StateObject private var conversation = CommandCenterConversationModel.appModel()
    @StateObject private var composer = CommandCenterComposerModel()
    @ObservedObject private var settings = GlobalSettingsStore.shared
    @ObservedObject private var fonts = FontScaleManager.shared
    @SceneStorage("commandCenterSidebarTab") private var sidebarTab = AgentSidebarTab.all.rawValue
    @State private var search = ""
    @State private var selected: CommandCenterSessionRow.ID?
    @State private var navigationError: String?
    @State private var navigationTask: Task<Void, Never>?
    @State private var editorReset = false
    @State private var composerInset: CGFloat = 0
    @State private var transcriptClearance: CGFloat = 0
    @State private var coveragePopover = false
    @FocusState private var editorFocused: Bool

    private var tab: AgentSidebarTab {
        AgentSidebarTab(rawValue: sidebarTab) ?? .all
    }

    private var metrics: AgentSidebarMetrics {
        .init(preset: fonts.preset)
    }

    var body: some View {
        Group {
            if settings.experimentalCommandCenter() { browser }
            else {
                ContentUnavailableView(
                    "Command Center is disabled",
                    systemImage: "rectangle.split.2x1",
                    description: Text("Enable Command Center (experimental) at the bottom of Settings → Overview.")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            AppWindowOpener.shared.install { openWindow(id: "main") }
            AppWindowOpener.shared.commandCenter.install { openWindow(id: "command-center") }
            installCreationCallback()
            if settings.experimentalCommandCenter() { model.start()
                composer.start()
            }
        }
        .onChange(of: settings.experimentalCommandCenter()) { _, enabled in
            navigationTask?.cancel()
            navigationTask = nil
            conversation.stop()
            composer.stop()
            if enabled { installCreationCallback()
                model.start()
                composer.start()
            } else { model.stop() }
        }
        .onChange(of: conversation.snapshot?.tabID) { _, tabID in
            if tabID != nil, let id = conversation.selectedID { composer.selectedConversationLoaded(id) }
        }
        .onDisappear {
            navigationTask?.cancel()
            navigationTask = nil
            conversation.stop()
            composer.stop()
            model.stop()
        }
    }

    private var browser: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(spacing: metrics.controlSpacing) {
                    AgentSidebarTabStrip(selection: tab, metrics: metrics) { sidebarTab = $0.rawValue }
                    AgentSidebarSearchField(text: $search, placeholder: tab.searchPlaceholder, metrics: metrics)
                }
                .padding(.horizontal, metrics.gutter).padding(.top, max(0, metrics.topInset)).padding(.bottom, metrics.bottomInset)
                List(selection: $selected) {
                    let rows = CommandCenterSidebarProjection.rows(snapshot: model.snapshot, tab: tab, search: search)
                    ForEach(rows) { item in
                        if item.showsHeader { Text(item.bucket.title).font(.caption).foregroundStyle(.secondary) }
                        sessionRow(item).tag(item.id)
                    }
                    if rows.isEmpty {
                        if model.snapshot.catalogCoverage?.contains("Loading") == true { ProgressView("Loading sessions…") }
                        else { Text(tab == .active && !model.snapshot.coverage.isEmpty ? "No matching live sessions witnessed; some owners or history are unavailable." : tab.emptyTitle).foregroundStyle(.secondary) }
                    }
                    ForEach(model.snapshot.workspaces.filter { ($0.savedCount ?? 0) > $0.savedLimit && $0.savedLimit < 1000 }) { workspace in
                        Button("More from \(workspace.name)…") { model.loadSaved(workspaceID: workspace.id, more: true) }
                    }
                }.listStyle(.sidebar).disabled(composer.isSending)
                    .onChange(of: selected) { _, id in
                        guard let id, composer.target != .session(id), let row = model.snapshot.sessions.first(where: { $0.id == id }) else { return }
                        conversation.select(row)
                        composer.selectSession(row.id)
                    }
                if !model.snapshot.coverage.isEmpty {
                    Button("Some project history is unavailable", systemImage: "info.circle") { coveragePopover.toggle() }
                        .font(.caption).foregroundStyle(.secondary).buttonStyle(.plain).padding(10)
                        .popover(isPresented: $coveragePopover) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(model.snapshot.coverage.enumerated()), id: \.offset) { _, text in Text(text).font(.caption) }
                                Button("Refresh saved inventory") { Task { await model.refresh() } }
                            }.padding().frame(width: 340)
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 440)
        } detail: {
            VStack(spacing: 0) {
                if let navigationError { Text(navigationError).foregroundStyle(.red).padding(8) }
                if let notice = composer.notice { Text(notice).font(.callout).foregroundStyle(.secondary).padding(8) }
                if composer.isSending { ProgressView("Preparing message…").controlSize(.small).padding(6) }
                if let recovery = composer.recoveredDraft {
                    VStack(alignment: .leading) {
                        Text("Preserved draft (not automatically resent)").font(.caption)
                        Text(recovery.text).textSelection(.enabled).lineLimit(8)
                        ForEach(recovery.attachments) { attachment in
                            if case let .localFile(path) = attachment.source { Text(path).font(.caption).textSelection(.enabled) }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                conversationContent
                composerContent
            }
            .navigationTitle(windowTitle)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("New session", systemImage: "square.and.pencil") {
                    selected = nil
                    conversation.newSession(projectID: composer.projectID)
                    composer.newDraft(projectID: composer.projectID)
                }.disabled(composer.isSending)
            }
            ToolbarItem(placement: .primaryAction) {
                if let projectID = composer.projectID {
                    Button("Open in workspace", systemImage: "arrow.up.right.square") { navigate(projectID, session: selectedRow) }
                        .disabled(navigationTask != nil)
                }
            }
        }
    }

    private func sessionRow(_ item: CommandCenterSidebarProjection.Item) -> some View {
        let row = item.row.session
        return CommandCenterRecentSessionRow(row: row, project: item.row.workspaceName)
            .contextMenu {
                Button("Open in workspace") { navigate(row.workspaceID, session: row) }
                Button("Reload conversation") { conversation.select(row)
                    composer.selectSession(row.id)
                }
                Button("Copy session ID") { NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.sessionID.uuidString, forType: .string)
                }
            }
    }

    @ViewBuilder private var conversationContent: some View {
        if conversation.isLoading {
            ProgressView("Loading selected conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot = conversation.snapshot {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if snapshot.hasEarlierRows {
                            Button("Show earlier messages") { conversation.showEarlier() }.disabled(conversation.rowLimit >= 5000)
                        }
                        ForEach(snapshot.rows.filter { !MCPIntegrationHelper.isRepoPromptAskUserToolName($0.toolName) }) { item in
                            AgentMessageBubble(
                                item: item,
                                windowID: snapshot.windowID,
                                currentWorkspaceID: snapshot.workspaceID,
                                currentTabID: snapshot.tabID,
                                suppressAskUserTranscriptUI: true
                            ).id(item.id)
                        }
                        if snapshot.hasPendingInteraction {
                            HStack {
                                Text("This session needs your response.")
                                Button("Open in workspace") { navigate(snapshot.workspaceID, session: selectedRow) }
                            }.font(.callout).padding(10)
                        }
                    }.padding(20)
                }
                .onAppear { if let id = snapshot.rows.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
        } else {
            ContentUnavailableView(
                selected == nil ? "New session" : "Conversation not loaded",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(conversation.message ?? "Choose a project, or select a recent session.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var composerContent: some View {
        let resources = composer.catalogDonor
        return AgentInputBar(
            agentModeVM: resources?.agentModeViewModel,
            composerUI: composer.composerUI,
            statusPillsUI: composer.statusPillsUI,
            openContextDrawerFiles: { if let id = composer.projectID { navigate(id, session: selectedRow) } },
            oracleViewModel: resources?.oracleViewModel,
            promptManager: composer.hasWorkspaceResources ? resources?.promptManager : nil,
            workspaceSearchService: composer.hasWorkspaceResources ? resources?.workspaceSearchService : nil,
            selectionCoordinator: composer.hasWorkspaceResources ? resources?.selectionCoordinator : nil,
            runtimeVM: resources?.agentModeViewModel.ui.runtimeMetrics.runtimeVM,
            windowID: resources?.windowID ?? 0,
            currentTabID: composer.presentationID,
            subject: composer.subject,
            actionsOverride: composer.actions(),
            ownerIsCurrent: { !composer.isConfiguring && settings.experimentalCommandCenter() },
            projectChip: AnyView(projectChip),
            selectWorkflowOverride: { composer.selectWorkflow($0) },
            resetTextFieldTrigger: $editorReset,
            composerBottomInset: $composerInset,
            transcriptBottomClearance: $transcriptClearance,
            isFocused: _editorFocused
        ).id(composer.presentationID)
            .disabled(composer.isConfiguring || composer.isUnavailableSession)
    }

    @ViewBuilder private var projectChip: some View {
        if case .draft = composer.target {
            CommandCenterProjectPicker(
                projects: model.snapshot.projects,
                selectedID: composer.projectID,
                selectedName: composer.openedProject.flatMap { $0.id == composer.projectID ? $0.name : nil },
                recentID: composer.openedProject?.id,
                isDisabled: { id in model.snapshot.workspaces.first { $0.id == id }?.unavailable == true },
                choose: composer.chooseProject, openFolder: { composer.openFolder() }
            ).disabled(composer.isSending || composer.isOpeningFolder)
            if composer.destinations.count > 1 || composer.chosenWindowID != nil {
                Menu {
                    Button("Choose exact destination") { composer.chooseWindow(nil) }
                    ForEach(composer.destinations, id: \.self) { id in Button("Window \(id)") { composer.chooseWindow(id) } }
                } label: { Label(composer.chosenWindowID.map { "Window \($0)" } ?? "Choose window", systemImage: "macwindow") }
            }
        } else if let project = composer.projectID {
            AgentWorkspaceContextPill(title: workspaceName(project), systemImage: "folder", action: { navigate(project, session: selectedRow) })
                .lineLimit(1).frame(maxWidth: fonts.preset.scaledClamped(170, max: 220), alignment: .leading)
        }
    }

    private func installCreationCallback() {
        let selection = $selected
        let conversation = conversation
        let readModel = model
        composer.openInWorkspace = { [weak composer, weak readModel] in
            guard let composer, let project = composer.projectID else { return }
            let row = readModel?.snapshot.sessions.first { .session($0.id) == composer.target }
            composer.openProject(workspaceID: project, row: row)
        }
        composer.onCreatedSession = { [weak conversation] id, source in
            selection.wrappedValue = id
            conversation?.presentCreatedSession(id, source: source)
        }
    }

    private var selectedRow: CommandCenterSessionRow? {
        model.snapshot.sessions.first { $0.id == selected }
    }

    private var windowTitle: String {
        let title = conversation.snapshot?.title ?? selectedRow?.name ?? "New session"
        return composer.projectID.map { "\(title) — \(workspaceName($0))" } ?? "Command Center"
    }

    private func workspaceName(_ id: UUID) -> String {
        model.snapshot.workspaces.first { $0.id == id }?.name ?? id.uuidString
    }

    private func projectLabel(_ workspace: CommandCenterWorkspaceRow) -> String {
        workspace.name + (model.snapshot.workspaces.count(where: { $0.name == workspace.name }) > 1 ? " · \(workspace.id.uuidString.prefix(8))" : "")
    }

    private func navigate(_ workspaceID: UUID, session: CommandCenterSessionRow? = nil) {
        guard navigationTask == nil else { return }
        navigationTask = Task {
            let result = await CommandCenterNavigation.open(workspaceID: workspaceID, session: session)
            guard !Task.isCancelled else { return }
            navigationError = result
            navigationTask = nil
        }
    }
}
