import AppKit
import Combine
import RepoPromptAIContracts
import RepoPromptSettingsCore

/// CC owns presentation/drafts only. The selected canonical runtime remains the sole writer.
@MainActor
final class CommandCenterComposerModel: ObservableObject {
    struct Draft {
        let id: UUID
        let projectID: UUID?
        var text = ""
        var selection: AgentSessionLanePolicy.RoleSelection?
        var attachments: [AgentFileAttachment] = []
        var windowID: Int?
        var autoEdit = ApplyEditsApprovalStore.globalDefaultAutoEditEnabled()
        var workflow: AgentWorkflowDefinition?
    }

    @Published private(set) var target: CommandCenterTarget
    @Published private(set) var props = AgentComposerProps.empty
    @Published private(set) var notice: String?
    @Published private(set) var draftText = ""
    @Published private(set) var destinations: [Int] = []
    @Published private(set) var isSending = false
    @Published private(set) var isConfiguring = false
    @Published private(set) var recoveredDraft: Draft?
    private(set) var window: WindowState?
    private var runtimeOwner: AgentSessionCarrierResolver.RuntimeOwner?
    private var drafts: [UUID: Draft] = [:]
    private var unassignedDraftID: UUID?
    let composerUI = AgentComposerUIStore()
    let statusPillsUI = AgentStatusPillsUIStore()
    var openInWorkspace: (() -> Void)?
    @Published private(set) var isOpeningFolder = false
    @Published private(set) var openedProject: WorkspaceModel?
    private var folderTask: Task<Void, Never>?
    private var folderGeneration = UUID()
    private var navigationTask: Task<Void, Never>?
    private let coordinator: CommandCenterSendCoordinator
    private var changes: AnyCancellable?
    private var safetyTimer: AnyCancellable?
    private var isActive = false
    var onCreatedSession: ((CommandCenterSessionRow.ID, CommandCenterConversationModel.Source?) -> Void)?

    init(coordinator: CommandCenterSendCoordinator? = nil) {
        let id = UUID()
        target = .draft(projectID: nil, draftID: id)
        drafts[id] = Draft(id: id, projectID: nil)
        unassignedDraftID = id
        self.coordinator = coordinator ?? CommandCenterSubmissionHost.coordinator()
    }

    var isUnavailableSession: Bool {
        guard case .session = target else { return false }
        guard let runtimeOwner else { return true }
        return !CommandCenterConversationHost.source(for: runtimeOwner).isCurrent()
    }

    var projectID: UUID? {
        switch target {
        case let .session(id): id.workspaceID
        case let .draft(projectID, _): projectID
        }
    }

    var chosenWindowID: Int? {
        guard case let .draft(_, id) = target else { return nil }
        return drafts[id]?.windowID
    }

    var presentationID: UUID? {
        props.currentTabID
    }

    func storeLocalDraftText(_ text: String) {
        guard case let .draft(_, id) = target else { return }
        drafts[id]?.text = text
        draftText = text
        if composerUI.props.currentTabID == id {
            var next = composerUI.props
            next.draftText = text
            props = next
            composerUI.update(next)
        }
    }

    func start() {
        guard GlobalSettingsStore.shared.experimentalCommandCenter(), safetyTimer == nil else { return }
        isActive = true
        // Re-enabling is an explicit user action. Ordinary refresh never follows a new incarnation.
        bindOwner()
        safetyTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        isActive = false
        onCreatedSession = nil
        openInWorkspace = nil
        changes = nil
        safetyTimer = nil
        navigationTask?.cancel()
        navigationTask = nil
        folderGeneration = UUID()
        folderTask?.cancel()
        folderTask = nil
        isOpeningFolder = false
        runtimeOwner = nil
        window = nil
        props = .empty
    }

    func selectSession(_ id: CommandCenterSessionRow.ID) {
        guard !isSending else { return }
        let sameTarget = target == .session(id)
        target = .session(id)
        if !sameTarget { notice = nil
            recoveredDraft = nil
        }
        bindOwner()
        refresh()
    }

    /// A user-selected saved row may finish loading later. A created session already holds its
    /// receipt's exact owner: this notification must never replace that captured incarnation.
    func selectedConversationLoaded(_ id: CommandCenterSessionRow.ID) {
        guard target == .session(id), runtimeOwner == nil else { refresh()
            return
        }
        bindOwner()
        refresh()
    }

    func newDraft(projectID: UUID?, selection: AgentSessionLanePolicy.RoleSelection? = nil) {
        guard !isSending else { return }
        let id = unassignedDraftID ?? UUID()
        if drafts[id] == nil { drafts[id] = Draft(id: id, projectID: projectID, selection: selection) }
        if let selection { drafts[id]?.selection = selection }
        unassignedDraftID = id
        target = .draft(projectID: drafts[id]?.projectID, draftID: id)
        runtimeOwner = nil
        changes = nil
        notice = nil
        recoveredDraft = nil
        if let projectID { chooseProject(projectID) }
        refresh()
    }

    /// A single unbound draft travels with the project selection. No text/settings replacement.
    func chooseProject(_ projectID: UUID?) {
        guard !isSending, case let .draft(_, id) = target, let old = drafts[id] else { return }
        var next = Draft(id: id, projectID: projectID, text: old.text, selection: old.selection, attachments: old.attachments)
        next.autoEdit = old.autoEdit
        next.workflow = old.workflow
        drafts[id] = next
        target = .draft(projectID: projectID, draftID: id)
        draftText = next.text
        notice = nil
        refresh()
    }

    func openFolder(pick: @escaping () async -> URL? = {
        await OpenPanelService.shared.pickFolder(title: PersistentFolderWorkspaceResolver.panelTitle, message: PersistentFolderWorkspaceResolver.panelMessage)
    }, resolve: @escaping (URL) async throws -> WorkspaceModel = {
        try await PersistentFolderWorkspaceResolver.resolve(folderURL: $0).workspace
    }) {
        guard !isOpeningFolder, !isSending else { return }
        isOpeningFolder = true
        let folderID = UUID()
        folderGeneration = folderID
        folderTask = Task { [weak self] in
            guard let self else { return }
            defer { if folderGeneration == folderID { isOpeningFolder = false
                folderTask = nil
            } }
            guard let url = await pick(), !Task.isCancelled else { return }
            do {
                let workspace = try await resolve(url)
                guard !Task.isCancelled, folderGeneration == folderID, GlobalSettingsStore.shared.experimentalCommandCenter() else { return }
                openedProject = workspace
                chooseProject(workspace.id)
                notice = "Selected \(workspace.name). The project was not activated."
            } catch is CancellationError {}
            catch { if !Task.isCancelled { notice = "Open Folder: \(error.localizedDescription). Open in workspace for recovery." } }
        }
    }

    var subject: AgentComposerSubject {
        if case let .draft(_, id) = target { return .draft(id) }
        return presentationID.map(AgentComposerSubject.tab) ?? .draft(UUID())
    }

    /// File search and selection resources belong to the presented workspace, not its catalog donor.
    var hasWorkspaceResources: Bool {
        guard case let .session(id) = target, let window else { return false }
        return window.workspaceManager.activeWorkspaceID == id.workspaceID && !isUnavailableSession
    }

    /// This is only a read-only catalog donor, never a session owner or Send destination.
    var catalogDonor: WindowState? {
        window ?? WindowStatesManager.shared.allWindows.first { !$0.isClosing }
    }

    private func draftState(_ draft: Draft) -> AgentComposerDraftState {
        var state = AgentComposerDraftState(id: draft.id, text: draft.text)
        if let selection = draft.selection { state.agent = AgentProviderKind(rawValue: selection.agentRaw) ?? .claudeCode
            state.model = selection.modelRaw
            state.effort = selection.reasoningEffortRaw
            state.parameters = selection.modelParameterSelections
        }
        state.attachments = draft.attachments
        state.autoEdit = draft.autoEdit
        state.workflow = draft.workflow
        return state
    }

    func openProject(workspaceID: UUID, row: CommandCenterSessionRow?) {
        guard navigationTask == nil else { return }
        navigationTask = Task { [weak self] in
            let message = await CommandCenterNavigation.open(workspaceID: workspaceID, session: row)
            guard !Task.isCancelled else { return }
            self?.notice = message
            self?.navigationTask = nil
        }
    }

    func selectWorkflow(_ workflow: AgentWorkflowDefinition?) {
        if case let .draft(_, id) = target { drafts[id]?.workflow = workflow
            refresh()
        } else if let owner = runtimeOwner, CommandCenterConversationHost.source(for: owner).isCurrent() {
            owner.location.window.agentModeViewModel.selectWorkflow(workflow, tabID: owner.session.tabID)
            refresh()
        }
    }

    func chooseWindow(_ id: Int?) {
        guard !isSending, case let .draft(_, draftID) = target else { return }
        drafts[draftID]?.windowID = id
        refresh()
    }

    private func bindOwner() {
        changes = nil
        runtimeOwner = nil
        guard isActive, GlobalSettingsStore.shared.experimentalCommandCenter() else { return }
        guard case let .session(id) = target, let owner = CommandCenterSubmissionHost.owner(id) else { return }
        runtimeOwner = owner
        changes = owner.session.objectWillChange.throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true).receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard isActive, GlobalSettingsStore.shared.experimentalCommandCenter() else { stop()
            return
        }
        switch target {
        case .session:
            guard let owner = runtimeOwner,
                  CommandCenterConversationHost.source(for: owner).isCurrent()
            else {
                window = nil
                props = .empty
                composerUI.update(.empty)
                statusPillsUI.update(.empty)
                return
            }
            window = owner.location.window
            let vm = owner.location.window.agentModeViewModel
            props = AgentComposerProjection.props(vm: vm, subject: .tab(owner.session.tabID))
            statusPillsUI.update(vm.makeStatusPillsSnapshot(subject: .tab(owner.session.tabID)))
            composerUI.update(props)
            draftText = vm.draftRuntime.text(for: owner.session.tabID)
        case let .draft(projectID, id):
            let hosts = projectID.map { CommandCenterSubmissionHost.destinations(projectID: $0) } ?? []
            destinations = hosts.map(\.windowID)
            // A stale explicit choice never silently retargets, even when only one host remains.
            window = if let chosen = drafts[id]?.windowID { hosts.first { $0.windowID == chosen } }
            else { hosts.count == 1 ? hosts[0] : nil }
            runtimeOwner = nil
            let vm = catalogDonor?.agentModeViewModel
            if drafts[id]?.selection == nil {
                let fresh = AgentModeViewModel.freshComposerSelection(
                    availability: vm?.agentAvailabilityContext ?? .current,
                    codexDynamicModels: vm?.codexDynamicModels
                )
                drafts[id]?.selection = .init(
                    role: .pair, agentRaw: fresh.agent.rawValue, modelRaw: fresh.modelRaw,
                    reasoningEffortRaw: nil, modelParameterSelections: []
                )
            }
            if let draft = drafts[id] {
                let state = draftState(draft)
                props = AgentComposerProjection.props(vm: vm, subject: .draft(id), draft: state, allowsWorkspaceScopedDiscovery: window != nil)
                statusPillsUI.update(.init(
                    currentTabID: id,
                    selectedWorkflow: state.workflow,
                    stagedSlashCommand: nil,
                    selectedAgent: state.agent,
                    autoEditPermissionGuidance: nil,
                    runState: .idle,
                    autoEditEnabled: state.autoEdit,
                    interviewFirst: false,
                    modelRouter: vm?.modelRouterPillProps(tabID: id) ?? .init(isOn: false, isAvailable: true, isRouting: false, disabledReason: nil, routedModelDisplayName: nil),
                    autoEffort: vm?.autoEffortPillProps(tabID: id) ?? .init(isOn: GlobalSettingsStore.shared.autoEffortEnabled(), isAvailable: true, isJudging: false, feedback: nil),
                    executionLocation: nil,
                    activeAgentSessionID: nil,
                    activeRunID: nil,
                    monitor: .empty
                ))
                composerUI.update(props)
            }
            draftText = drafts[id]?.text ?? ""
        }
    }

    func send(_ text: String) async -> AgentModeViewModel.UserTurnSubmissionResult {
        guard !isSending, !isConfiguring else { return .blocked(message: "A submission or configuration change is already in progress.") }
        let captured = target
        let draft: Draft? = if case let .draft(_, id) = captured { drafts[id] } else { nil }
        let sourceOwner = runtimeOwner
        var restorationSequence: UInt64 = 0
        // Separate the submitted snapshot from subsequent typing before the first await. The
        // reused editor observes draftText and clears visually; newer edits are an unsent draft.
        if draft != nil { storeLocalDraftText("") } else if let owner = sourceOwner, CommandCenterConversationHost.source(for: owner).isCurrent() {
            let vm = owner.location.window.agentModeViewModel
            let snapshot = vm.draftRuntime.loadSnapshot(tabID: owner.session.tabID)
            restorationSequence = snapshot.restorationSequence
            vm.storeDraftText(for: owner.session.tabID, "", acknowledgingThrough: restorationSequence)
            draftText = ""
        }
        isSending = true
        defer { isSending = false }
        let urls = draft?.attachments.compactMap { item -> URL? in
            if case let .localFile(path) = item.source { return URL(fileURLWithPath: path) }
            return nil
        } ?? []
        let receipt = await coordinator.send(
            target: captured,
            text: text,
            windowID: draft?.windowID,
            selection: draft?.selection,
            attachments: urls,
            openIfNeeded: true, draftConfiguration: draft.map(draftState)
        )
        notice = receipt.message
        guard target == captured else { return .blocked(message: receipt.message ?? "The composer changed.") }
        if let draft, let id = receipt.sessionID {
            let latestDraft = drafts[draft.id] ?? draft
            let newer = latestDraft.text
            let submittedAttachmentIDs = Set(draft.attachments.map(\.id))
            let remainingAttachments = receipt.outcome == .sent ? latestDraft.attachments.filter { !submittedAttachmentIDs.contains($0.id) } : latestDraft.attachments
            // The durable identity is consumed even if the first send failed: next Send is an
            // existing-session submission, never a second allocation.
            target = .session(id)
            changes = nil
            runtimeOwner = nil
            if receipt.remainsCurrent?() == true {
                bindOwner()
                if receipt.remainsCurrent?() != true { changes = nil
                    runtimeOwner = nil
                }
            }
            // Spend the draft identity even on partial creation, but keep its entire snapshot
            // visibly recoverable. It must not be silently reused to allocate a second session.
            let recoveryText = receipt.outcome == .sent ? newer : AgentComposerDraftRestorationReducer.compose(restoredText: text, above: newer)
            if !recoveryText.isEmpty || !remainingAttachments.isEmpty {
                var recovery = latestDraft
                recovery.text = recoveryText
                recovery.attachments = remainingAttachments
                recoveredDraft = recovery
                if let owner = runtimeOwner, CommandCenterConversationHost.source(for: owner).isCurrent() {
                    let vm = owner.location.window.agentModeViewModel
                    let existing = vm.draftRuntime.text(for: owner.session.tabID)
                    let backendRestored = receipt.outcome != .sent && (existing == text || existing.hasPrefix(text + "\n"))
                    let transfer = backendRestored ? newer : recoveryText
                    if !transfer.isEmpty {
                        vm.storeDraftText(for: owner.session.tabID, AgentComposerDraftRestorationReducer.compose(restoredText: transfer, above: existing))
                    }
                }
            }
            drafts[draft.id] = nil
            if unassignedDraftID == draft.id { unassignedDraftID = nil }
            let createdSource = runtimeOwner.flatMap { owner in
                receipt.remainsCurrent?() == true ? CommandCenterConversationHost.source(for: owner) : nil
            }
            onCreatedSession?(id, createdSource)
        } else if let draft {
            // Refusal before allocation: restore above newer typing, keeping the same draft ID.
            let newer = drafts[draft.id]?.text ?? ""
            drafts[draft.id]?.text = AgentComposerDraftRestorationReducer.compose(restoredText: text, above: newer)
            draftText = drafts[draft.id]?.text ?? text
        } else if receipt.outcome != .sent {
            var recovery = Draft(id: UUID(), projectID: projectID)
            let heldDraft = sourceOwner?.session.draftText ?? ""
            recovery.text = heldDraft == text || heldDraft.hasPrefix(text + "\n") ? heldDraft : AgentComposerDraftRestorationReducer.compose(restoredText: text, above: heldDraft)
            recoveredDraft = recovery
            if let owner = sourceOwner, CommandCenterConversationHost.source(for: owner).isCurrent() {
                let vm = owner.location.window.agentModeViewModel
                let latest = vm.draftRuntime.loadSnapshot(tabID: owner.session.tabID)
                if latest.restorationSequence <= restorationSequence {
                    vm.restoreComposerDraft(
                        tabID: owner.session.tabID,
                        text: AgentComposerDraftRestorationReducer.compose(restoredText: text, above: latest.text),
                        message: receipt.message ?? "Send did not complete.",
                        strategy: .replaceAlways
                    )
                }
            }
        }
        refresh()
        return receipt.outcome == .sent ? .submitted : .blocked(message: receipt.message ?? "Send did not complete.")
    }

    func actions() -> AgentComposerActions {
        let captured = target
        let localCurrent: () -> Bool = { [weak self] in self?.target == captured && GlobalSettingsStore.shared.experimentalCommandCenter() }
        if let owner = runtimeOwner {
            let source = CommandCenterConversationHost.source(for: owner)
            return .make(
                vm: owner.location.window.agentModeViewModel,
                subject: .tab(owner.session.tabID),
                composerUI: composerUI,
                windowID: owner.location.window.windowID,
                isCurrent: { localCurrent() && source.isCurrent() },
                openInWorkspace: { [weak self] in self?.openInWorkspace?() },
                reportFailure: { [weak self] in self?.notice = $0 }
            )
        }
        return .draft(
            props: props, donor: catalogDonor?.agentModeViewModel,
            isCurrent: localCurrent,
            store: { [weak self] text in self?.storeLocalDraftText(text) },
            load: { [weak self] in self?.draftText ?? "" },
            configure: { [weak self] agent, model, effort, parameters in self?.configure(agent: agent, model: model, effort: effort, parameters: parameters) },
            autoEdit: { [weak self] enabled in guard let self, case let .draft(_, id) = target else { return }
                drafts[id]?.autoEdit = enabled
                refresh()
            },
            attach: { [weak self] urls in guard let self, case let .draft(_, id) = target else { return }
                drafts[id]?.attachments += urls.map { .init(source: .localFile(path: $0.path), title: $0.lastPathComponent, fileName: $0.lastPathComponent) }
                refresh()
            },
            remove: { [weak self] attachmentID in guard let self, case let .draft(_, id) = target else { return }
                drafts[id]?.attachments.removeAll { $0.id == attachmentID }
                refresh()
            },
            notify: { [weak self] in self?.notice = $0 },
            open: { [weak self] in self?.openInWorkspace?() },
            send: { [weak self] in guard let self else { return .blocked(message: "Composer closed") }
                return await send($0)
            },
            sendTitle: destinations.isEmpty ? "Open & Send" : "Send Message (Return)", presentationIdentity: AnyHashable(captured)
        )
    }

    private func configure(
        agent: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        parameters: [ACPModelParameterSelection] = []
    ) {
        guard !isSending, !isConfiguring, !props.areModelControlsDisabled else { return }
        if case let .draft(_, id) = target, let old = drafts[id]?.selection {
            drafts[id]?.selection = .init(
                role: .pair,
                agentRaw: agent ?? old.agentRaw,
                modelRaw: model ?? old.modelRaw,
                reasoningEffortRaw: agent != nil || model != nil ? nil : (effort ?? old.reasoningEffortRaw),
                modelParameterSelections: agent != nil || model != nil ? [] : AgentComposerProjection.merging(parameters, into: old.modelParameterSelections)
            )
            refresh()
        } else if let owner = runtimeOwner {
            let source = CommandCenterConversationHost.source(for: owner)
            guard source.isCurrent() else { return }
            guard agent == nil || agent == owner.session.selectedAgent.rawValue else {
                notice = "Change provider in workspace."
                return
            }
            let expectedBinding = owner.session.persistentBindingTransitionToken()
            isConfiguring = true
            Task {
                defer { isConfiguring = false }
                do {
                    guard source.isCurrent(), !isSending else { return }
                    try await owner.location.window.agentModeViewModel.mcpConfigureSession(
                        tabID: owner.session.tabID, agentRaw: agent, modelRaw: model, reasoningEffortRaw: effort,
                        modelParameterSelections: parameters, requireInactiveRunState: true, expectedTarget: expectedBinding
                    )
                } catch { notice = "Configuration refused: \(error.localizedDescription)" }
                refresh()
            }
        }
    }
}
