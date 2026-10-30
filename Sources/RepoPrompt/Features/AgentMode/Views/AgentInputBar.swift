import RepoPromptSettingsCore

//
//  AgentInputBar.swift
//  RepoPrompt
//
//  Input bar for Agent Mode with shared send/cancel controls.
//  Uses ComposerChrome for the floating bubble container.
//

import AppKit
import RepoPromptInstrumentation
import SwiftUI
import UniformTypeIdentifiers

struct AgentComposerActions {
    var prepareReprompt: (AgentComposerSubmitTarget, String) -> Bool = { _, _ in false }
    var toggleComputerUse: (UUID, ObjectIdentifier) async -> Void = { _, _ in }
    let storeDraft: (_ tabID: UUID, _ text: String, _ acknowledgedSequence: UInt64) -> Void
    let loadDraft: (_ tabID: UUID) -> AgentComposerDraftSnapshot
    let claimSubmit: (_ attempt: AgentComposerSubmitAttempt) -> AgentModeViewModel.AgentComposerSubmitClaimResult
    let executeSubmit: (_ claim: AgentModeViewModel.AgentComposerSubmitClaim, _ text: String) async -> AgentModeViewModel.UserTurnSubmissionResult
    let cancelRun: (_ target: AgentRunCancelTarget) async -> Void
    let cancelRouting: (_ tabID: UUID) async -> Void
    let attachFiles: (_ tabID: UUID, _ urls: [URL]) async -> Void
    let reportAttachmentFailures: (_ tabID: UUID, _ failures: [AgentAttachmentFailure]) -> Void
    let removePendingAttachment: (_ tabID: UUID, _ attachmentID: UUID) -> Void
    let commitTaggedFile: (_ tabID: UUID, _ suggestion: MentionSuggestion, _ displayName: String) -> Void
    let removeTaggedFile: (_ tabID: UUID, _ attachmentID: UUID) -> Void
    let agentWorkspaceLookupContext: (_ tabID: UUID?) async -> WorkspaceLookupContext
    let slashSkillSuggestions: (_ query: String) async -> [MentionSuggestion]
    let modelOptions: (_ agent: AgentProviderKind, _ includeClaudeEffortVariants: Bool) -> [AgentModelOption]
    let canSelectAgentInCurrentChat: (_ agent: AgentProviderKind) -> Bool
    let selectAgentModel: (_ agent: AgentProviderKind, _ rawModel: String) -> Void
    let reasoningEffortOptionsForCurrentSelection: () -> [CodexReasoningEffort]
    let selectReasoningEffort: (_ effort: CodexReasoningEffort?) -> Void
    let selectACPModelParameter: (_ target: ACPModelParameterSelection, _ openCodeDiscoveryKey: OpenCodeACPModelParameterKey?) -> Void
    var clearCursorModelParameter: (ACPModelParameterIdentity) -> Void = { _ in }
    var canMutateCursorModel: (_ tabID: UUID?) -> Bool = { _ in false }
    let setAutoEditEnabled: (_ enabled: Bool) -> Void
    let setProviderPermissionLevel: (_ id: AgentProviderPermissionLevelID) -> Void
    let applyCodexToolSettingMutation: (_ mutation: CodexToolSettingMutation) -> Void
    let applyClaudeToolSettingMutation: (_ mutation: ClaudeToolSettingMutation) -> Void
    let setClaudeEffortLevel: (_ level: ClaudeCodeEffortLevel) -> Void
    let openCLIProvidersSettings: () -> Void
}

struct AgentInputBar: View {
    @Environment(\.agentModePerfRecorder) private var perfRecorder
    let agentModeVM: AgentModeViewModel
    @ObservedObject var composerUI: AgentComposerUIStore
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    let openContextDrawerFiles: () -> Void
    let oracleViewModel: OracleViewModel
    let promptManager: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let runtimeVM: AgentRuntimeSidebarViewModel
    let windowID: Int
    let currentTabID: UUID?

    @Binding var resetTextFieldTrigger: Bool
    @Binding var composerBottomInset: CGFloat
    @Binding var transcriptBottomClearance: CGFloat

    @FocusState var isFocused: Bool

    /// Height of the footer spacing below the composer chrome
    static let footerHeight: CGFloat = 28

    private var composerPlaceholderText: String {
        if let stagedSlashCommand = statusPillsUI.snapshot.stagedSlashCommand {
            switch stagedSlashCommand.action {
            case .setObjective where stagedSlashCommand.appliesSelectedWorkflowContext:
                return "Describe the Codex goal — selected workflow context will be included."
            case .setObjective:
                return "Describe the Codex goal..."
            case .show, .pause, .resume, .clear:
                return "Press Return to run the Codex goal command."
            }
        }
        if let workflow = statusPillsUI.snapshot.selectedWorkflow {
            if let builtIn = workflow.builtInWorkflow {
                return builtIn.composerGuidanceText
            }
            if let description = workflow.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                return description
            }
        }
        return "Send a message..."
    }

    var body: some View {
        #if DEBUG
            let _ = perfRecorder.increment("ui.body.inputBar")
        #endif
        AgentComposerView(
            props: composerUI.props,
            placeholderText: composerPlaceholderText,
            actions: composerActions,
            promptManager: promptManager,
            workspaceSearchService: workspaceSearchService,
            selectionCoordinator: selectionCoordinator,
            windowID: windowID,
            currentTabID: currentTabID,
            repromptViewModel: agentModeVM,
            repromptStore: agentModeVM.repromptUIStore,
            pendingSubmissionStore: composerUI,
            resetTextFieldTrigger: $resetTextFieldTrigger,
            composerBottomInset: $composerBottomInset,
            transcriptBottomClearance: $transcriptBottomClearance,
            isFocused: _isFocused
        )
        .equatable()
        .overlay(alignment: .bottom) {
            statusPills
                .padding(.bottom, Self.footerHeight + ComposerChrome<EmptyView, EmptyView>.baseBarHeight + composerBottomInset - 8)
        }
    }

    private var composerActions: AgentComposerActions {
        // Composer props carry the source session identity in submitTarget, so replacing
        // an idle session also invalidates the equatable view's retained actions.
        let cursorSession = agentModeVM.activeSession
        let attachmentAdmission: @MainActor (UUID) -> Bool = { [weak agentModeVM, weak composerUI] tabID in
            guard let agentModeVM, let composerUI else { return false }
            return !composerUI.hasPendingSubmission(tabID: tabID)
                && agentModeVM.repromptUIStore.allowsAttachmentMutation(tabID: tabID, currentTabID: agentModeVM.currentTabID)
        }
        return AgentComposerActions(
            prepareReprompt: { target, text in agentModeVM.prepareRepromptForComposerSend(target: target, text: text) },
            toggleComputerUse: { tabID, identity in await agentModeVM.toggleComputerUse(tabID: tabID, expectedSessionIdentity: identity) },
            storeDraft: { tabID, text, sequence in
                agentModeVM.storeDraftText(for: tabID, text, acknowledgingThrough: sequence)
            },
            loadDraft: { tabID in agentModeVM.loadDraftSnapshotForComposer(for: tabID) },
            claimSubmit: { attempt in agentModeVM.claimComposerSubmitForImmediatePresentation(attempt) },
            executeSubmit: { claim, text in
                await agentModeVM.executePresentedComposerSubmitAttempt(text: text, claim: claim)
            },
            cancelRun: { target in _ = await agentModeVM.cancelAgentRun(target: target) },
            cancelRouting: { tabID in await agentModeVM.cancelFreshTaskRouting(tabID: tabID) },
            attachFiles: { tabID, urls in
                await agentModeVM.attachFiles(tabID: tabID, urls: urls, admission: {
                    attachmentAdmission(tabID)
                }).value
            },
            reportAttachmentFailures: { tabID, failures in
                guard attachmentAdmission(tabID) else { return }
                agentModeVM.reportAttachmentFailures(tabID: tabID, failures)
            },
            removePendingAttachment: { tabID, attachmentID in agentModeVM.removePendingFileAttachment(tabID: tabID, attachmentID: attachmentID) },
            commitTaggedFile: { tabID, suggestion, displayName in
                agentModeVM.commitPendingTaggedFile(
                    tabID: tabID,
                    relativePath: suggestion.relativePath,
                    displayName: displayName
                )
            },
            removeTaggedFile: { tabID, attachmentID in agentModeVM.removePendingTaggedFile(tabID: tabID, attachmentID: attachmentID) },
            agentWorkspaceLookupContext: { tabID in
                guard let tabID else { return .visibleWorkspace }
                return await agentModeVM.agentWorkspaceLookupContext(tabID: tabID)
            },
            slashSkillSuggestions: { query in await agentModeVM.slashSkillSuggestions(for: query) },
            modelOptions: { agent, includeClaudeEffortVariants in
                agentModeVM.modelOptions(for: agent, includeClaudeEffortVariants: includeClaudeEffortVariants)
            },
            canSelectAgentInCurrentChat: { agent in agentModeVM.canSelectAgentInCurrentChat(agent) },
            selectAgentModel: { agent, rawModel in
                agentModeVM.selectedAgent = agent
                agentModeVM.selectModel(rawModel: rawModel)
            },
            reasoningEffortOptionsForCurrentSelection: { agentModeVM.reasoningEffortOptionsForCurrentSelection() },
            selectReasoningEffort: { effort in agentModeVM.selectReasoningEffort(effort) },
            selectACPModelParameter: { target, openCodeDiscoveryKey in
                agentModeVM.selectACPModelParameter(target, openCodeDiscoveryKey: openCodeDiscoveryKey)
            },
            clearCursorModelParameter: { agentModeVM.clearCursorModelParameter($0) },
            canMutateCursorModel: { tabID in
                agentModeVM.canMutateCursorComposerModel(expectedSession: cursorSession, expectedTabID: tabID)
            },
            setAutoEditEnabled: { enabled in agentModeVM.setAutoEditEnabled(enabled) },
            setProviderPermissionLevel: { id in agentModeVM.setProviderPermissionLevel(id) },
            applyCodexToolSettingMutation: { mutation in
                agentModeVM.applyCodexToolSettingMutation(mutation)
            },
            applyClaudeToolSettingMutation: { mutation in
                agentModeVM.applyClaudeToolSettingMutation(mutation)
            },
            setClaudeEffortLevel: { level in agentModeVM.setClaudeEffortLevel(level) },
            openCLIProvidersSettings: {
                NotificationCenter.default.post(
                    name: .showCLIProvidersTab,
                    object: nil,
                    userInfo: ["windowID": windowID]
                )
            }
        )
    }

    @ViewBuilder
    private var statusPills: some View {
        #if DEBUG
            let _ = perfRecorder.increment("ui.body.inputBar.statusPills")
        #endif
        AgentStatusPillsRow(
            agentModeVM: agentModeVM,
            statusPillsUI: statusPillsUI,
            computerUse: composerUI.props.computerUse,
            computerUseTarget: composerUI.props.submitTarget,
            toggleComputerUse: composerActions.toggleComputerUse,
            openContextDrawerFiles: openContextDrawerFiles,
            oracleViewModel: oracleViewModel,
            promptManager: promptManager,
            selectionCoordinator: selectionCoordinator,
            runtimeVM: runtimeVM,
            windowID: windowID
        )
        .padding(.horizontal, 28)
        .disabled(composerUI.hasPendingSubmission(tabID: currentTabID))
    }
}

enum AgentFileMentionText {
    static func attachmentDisplayName(for suggestion: MentionSuggestion) -> String {
        let trimmedPath = suggestion.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            return trimmedPath
        }
        return suggestion.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingTaggedMention(
        displayName: String,
        relativePath: String,
        from text: String
    ) -> String {
        guard !text.isEmpty else { return text }
        var candidates: [String] = []
        appendNonEmpty(displayName, to: &candidates)
        appendNonEmpty(relativePath, to: &candidates)
        guard !candidates.isEmpty else { return text }

        var reduced = text
        for candidate in candidates {
            reduced = removingTaggedPath(candidate, from: reduced)
        }
        return reduced
    }

    private static func appendNonEmpty(_ value: String, to candidates: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
        candidates.append(trimmed)
    }

    private static func removingTaggedPath(_ relativePath: String, from text: String) -> String {
        guard !relativePath.isEmpty, !text.isEmpty else { return text }
        let escapedPath = escapePathForAtCommand(relativePath)
        // Consume one trailing horizontal space after the token when present.
        // `FileTagMentionHelper.commitHighlighted` inserts mentions as "@path " and without
        // consuming that space explicit chip removal would leave a visible gap.
        let pattern = "(^|\\s)@\(NSRegularExpression.escapedPattern(for: escapedPath))(?=$|\\s)[ \\t]?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let reduced = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
        return reduced.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    }

    private static func escapePathForAtCommand(_ path: String) -> String {
        var escaped = ""
        for character in path {
            switch character {
            case "\\", " ", ",", ";", "!", "?", "(", ")", "[", "]", "{", "}":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}

struct AgentComposerView: View, Equatable {
    @Environment(\.agentModePerfRecorder) private var perfRecorder
    let props: AgentComposerProps
    let placeholderText: String
    let actions: AgentComposerActions
    let promptManager: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let windowID: Int
    let currentTabID: UUID?
    var repromptViewModel: AgentModeViewModel?
    @ObservedObject var repromptStore = AgentRepromptUIStore()
    @ObservedObject var pendingSubmissionStore = AgentComposerUIStore()

    @Binding var resetTextFieldTrigger: Bool
    @Binding var composerBottomInset: CGFloat
    @Binding var transcriptBottomClearance: CGFloat

    @FocusState var isFocused: Bool

    private func flushDraftOnDeparture(tabID: UUID) {
        guard AgentRepromptUIStore.shouldFlushDraftOnDeparture(
            tabID: tabID, presentation: repromptStore.presentation, publication: repromptStore.draftUpdate,
            acknowledged: acknowledgedRepromptPublicationsByTab[tabID]
        ) else { return }
        actions.storeDraft(tabID, localInputText, acknowledgedDraftRestorationSequenceByTab[tabID] ?? 0)
    }

    @State private var localInputText: String = ""
    @State private var nativeComposerEditor = TextFieldNativeEditor()
    @State private var externalTextUpdateTick: Int = 0
    @State private var submissionLatch = AgentComposerSubmissionLatch()
    @State private var acknowledgedDraftRestorationSequenceByTab: [UUID: UInt64] = [:]
    @State private var acknowledgedRepromptPublicationsByTab: [UUID: AgentRepromptUIStore.PublicationIdentity] = [:]
    @State private var repromptStripHeight: CGFloat = 0
    @State private var composerFocusRestoreRequest: UUID?
    @State private var editorTextFieldHeight: CGFloat = ResizableTextField.height(forPresetIndex: 0, preset: .normal)
    @State private var isInputEmpty: Bool = true
    @State private var chromeOcclusion: CGFloat = 0
    @State private var isSyncingDraftFromSession: Bool = false
    @State private var isAttachmentDropTargeted: Bool = false
    @State private var showCodexToolsPopover: Bool = false
    @State private var showPermissionPopover: Bool = false
    @State private var showClaudeToolsPopover: Bool = false
    @State private var steeringUnsupportedMessage: String? = nil
    @State private var steeringUnsupportedDismissTask: Task<Void, Never>?
    @State private var modelMenuSnapshotByAgent: [AgentProviderKind: [AgentModelOption]]? = nil
    @State private var modelMenuSnapshotReleaseTask: Task<Void, Never>? = nil

    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private let attachmentIntake = AgentAttachmentIntake()
    private static let staleSubmitTargetMessage = "This composer changed before the message could be sent. Please try again."

    static func hasEquivalentRenderIdentity(
        lhsProps: AgentComposerProps,
        lhsPlaceholderText: String,
        lhsCurrentTabID: UUID?,
        rhsProps: AgentComposerProps,
        rhsPlaceholderText: String,
        rhsCurrentTabID: UUID?
    ) -> Bool {
        lhsProps == rhsProps &&
            lhsPlaceholderText == rhsPlaceholderText &&
            lhsCurrentTabID == rhsCurrentTabID
    }

    static func == (lhs: AgentComposerView, rhs: AgentComposerView) -> Bool {
        hasEquivalentRenderIdentity(
            lhsProps: lhs.props,
            lhsPlaceholderText: lhs.placeholderText,
            lhsCurrentTabID: lhs.currentTabID,
            rhsProps: rhs.props,
            rhsPlaceholderText: rhs.placeholderText,
            rhsCurrentTabID: rhs.currentTabID
        )
    }

    private var hasPendingFileAttachments: Bool {
        props.attachments.hasAttachments
    }

    private var hasPendingTaggedFileAttachments: Bool {
        props.attachments.hasTaggedFiles
    }

    private var hasPendingAttachments: Bool {
        hasPendingFileAttachments || hasPendingTaggedFileAttachments
    }

    private var isCodexRunActive: Bool {
        props.isCodexRunActive
    }

    private var canUseLinkedAgentSession: Bool {
        props.canUseLinkedAgentSession
    }

    private static let attachmentDropTypes: [UTType] = [.fileURL, .image]

    private var canAttachFiles: Bool {
        // Grok Build advertises no ACP image capability; its provider rejects attachments.
        !props.isAgentBusy && currentTabID.map(canMutateAttachments) == true && props.selectedAgent != .grokBuild
    }

    private var renderedSubmitTarget: AgentComposerSubmitTarget? {
        guard let target = props.submitTarget,
              target.tabID == props.currentTabID,
              target.tabID == currentTabID
        else { return nil }
        if let viewModel = repromptViewModel {
            guard viewModel.currentTabID == target.tabID, let session = viewModel.sessions[target.tabID],
                  viewModel.makeComposerSubmitTarget(tabID: target.tabID, session: session) == target else { return nil }
        }
        return target
    }

    private var repromptPresentation: AgentRepromptUIStore.Presentation? {
        repromptStore.presentation.flatMap { $0.sourceTabID == currentTabID ? $0 : nil }
    }

    private var repromptUndoRecovery: AgentRepromptUIStore.Recovery? {
        guard repromptPresentation == nil, let tabID = currentTabID,
              let recovery = repromptStore.recoveries[tabID], recovery.reason == "Original restored",
              localInputText == recovery.originalDraft else { return nil }
        return recovery
    }

    private var repromptEditTransaction: TextFieldExternalEditTransaction? {
        if let presentation = repromptPresentation { return .init(id: presentation.id, isComplete: presentation.phase == .completed) }
        return repromptUndoRecovery.map { .init(id: $0.id, isComplete: true) }
    }

    private var isSubmissionPending: Bool {
        if let viewModel = repromptViewModel, let tabID = currentTabID {
            // Cancel releases admission immediately, even if the old backend call is settling.
            return pendingSubmissionStore.hasPendingSubmission(tabID: tabID)
                || viewModel.sessions[tabID]?.activeComposerSubmitAttempt != nil
        }
        return submissionLatch.isLatched(for: currentTabID)
            || pendingSubmissionStore.hasPendingSubmission(tabID: currentTabID)
    }

    private func retireUnownedSubmissionLatch() {
        guard let viewModel = repromptViewModel, let tabID = currentTabID,
              !isSubmissionPending, let attempt = submissionLatch.activeAttemptsByTabID[tabID],
              viewModel.sessions[tabID]?.activeComposerSubmitAttempt?.id != attempt.id else { return }
        submissionLatch.cancel(attempt)
    }

    private var canSubmitToRenderedTarget: Bool {
        props.canSendWithCurrentProvider
            && renderedSubmitTarget != nil
            && !isSubmissionPending
    }

    private var localInputTextBinding: Binding<String> {
        Binding(
            get: { localInputText },
            set: { text in
                guard let tabID = currentTabID,
                      repromptViewModel == nil || repromptViewModel?.currentTabID == tabID else { return }
                setLocalInputText(text)
                actions.storeDraft(tabID, text, acknowledgedDraftRestorationSequenceByTab[tabID] ?? 0)
            }
        )
    }

    private var isCurrentTabMCPControlled: Bool {
        props.isCurrentTabMCPControlled
    }

    private var modelControlsDisabled: Bool {
        props.areModelControlsDisabled
    }

    private var modelControlsDisabledTooltip: String {
        if props.isCurrentTabMCPControlled {
            return "Model and effort controls are locked while this session is controlled by an MCP agent."
        }
        if props.selectedAgent == .cursor, props.runState.isActive {
            return "Cursor model, effort, and speed controls are locked while this run is active."
        }
        return "Model controls are temporarily unavailable."
    }

    private var permissionBinding: AgentPermissionChromeBinding? {
        props.providerControls?.permission
    }

    private var permissionControlsDisabled: Bool {
        permissionBinding?.externallyManagedReason != nil
    }

    private var hasSteeringUnsupportedNotice: Bool {
        guard let message = steeringUnsupportedMessage else { return false }
        return !message.isEmpty
    }

    private var steeringUnsupportedInfoBoxHeight: CGFloat {
        fontPreset.scaledClamped(48, min: 48, max: 62)
    }

    private var steeringUnsupportedInfoBoxReservedHeight: CGFloat {
        guard hasSteeringUnsupportedNotice else { return 0 }
        return steeringUnsupportedInfoBoxHeight + AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent
    }

    private var mainContentHeight: CGFloat {
        editorTextFieldHeight + AgentAttachmentStripLayout.reservedHeight(
            hasAttachments: hasPendingFileAttachments,
            hasTaggedFiles: hasPendingTaggedFileAttachments
        ) + steeringUnsupportedInfoBoxReservedHeight + repromptStripHeight
    }

    private var composerChromeVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 8)
    }

    private var composerChromeInnerSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 2)
    }

    private var composerControlStripHeight: CGFloat {
        fontPreset.scaledClamped(40, min: 40, max: 44)
    }

    /// Height of the footer spacing below the composer chrome
    static let footerHeight: CGFloat = 28
    /// Extra transcript clearance needed so the overlaid status pills don't cover
    /// the in-transcript running indicator when we restore/scroll to the bottom.
    /// The pills sit 8pt into the transcript area and are 28pt tall, so we need
    /// 20pt beyond the composer's own occlusion to keep the spinner fully visible.
    private static let transcriptBottomExtraPadding: CGFloat = 20

    /// Agent mode uses ComposerChrome's upward counter-shift behavior.
    /// Chrome occlusion includes that half-shift, which can over-push transcript/pills.
    /// Subtract half of total main-content growth so overlays track the composer's
    /// visual top consistently whether growth comes from text or attachments.
    private var adjustedOcclusion: CGFloat {
        let baseHeight = ResizableTextField.height(forPresetIndex: 0, preset: fontPreset)
        let growth = max(0, mainContentHeight - baseHeight)
        return max(0, chromeOcclusion - (growth * 0.5)).rounded(.up)
    }

    /// Single transcript-facing bottom clearance contract consumed by AgentModeView.
    /// Keeps the composer growth math local to the input bar while preserving a small
    /// extra cushion above the overlaid status pills.
    private var currentTranscriptBottomClearance: CGFloat {
        max(0, adjustedOcclusion + Self.transcriptBottomExtraPadding).rounded(.up)
    }

    private func syncTranscriptGeometry() {
        assignGeometryValue(adjustedOcclusion, to: $composerBottomInset)
        assignGeometryValue(currentTranscriptBottomClearance, to: $transcriptBottomClearance)
    }

    private func assignGeometryValue(_ newValue: CGFloat, to binding: Binding<CGFloat>) {
        guard abs(binding.wrappedValue - newValue) >= 0.5 else { return }
        binding.wrappedValue = newValue
    }

    var body: some View {
        #if DEBUG
            let _ = perfRecorder.increment("ui.body.composer")
        #endif
        VStack(spacing: 0) {
            ComposerChrome(
                bottomOcclusion: $chromeOcclusion,
                mainContentHeight: mainContentHeight,
                highlightColor: isCurrentTabMCPControlled ? .orange : nil,
                bubbleVerticalPaddingOverride: composerChromeVerticalPadding,
                bubbleInnerSpacingOverride: composerChromeInnerSpacing,
                controlStripHeightOverride: composerControlStripHeight,
                main: { mainContent },
                strip: { controlStrip }
            )

            // Bottom spacing to keep bar off the very bottom
            Spacer()
                .frame(height: Self.footerHeight)
        }
        .onChange(of: chromeOcclusion) { _, _ in
            // Bubble overlap above the base bar (used to offset transcript and overlays).
            syncTranscriptGeometry()
        }
        .onChange(of: mainContentHeight) { _, _ in
            // Keep in sync when composer growth compensation changes.
            syncTranscriptGeometry()
        }
        .onAppear {
            // Initialize transcript clearance from the current composer geometry.
            syncTranscriptGeometry()
        }
        .onAppear {
            // Restore draft if we have one stored
            if let tabID = currentTabID {
                loadDraftFromSession(for: tabID)
            }
        }
        .onDisappear {
            // Store draft when leaving
            if let tabID = currentTabID { flushDraftOnDeparture(tabID: tabID) }
            steeringUnsupportedDismissTask?.cancel()
            steeringUnsupportedDismissTask = nil
            modelMenuSnapshotReleaseTask?.cancel()
            modelMenuSnapshotReleaseTask = nil
            modelMenuSnapshotByAgent = nil
        }
        .onChange(of: currentTabID) { oldTabID, newTabID in
            composerFocusRestoreRequest = nil
            // Switch drafts when tab changes
            if let oldTabID { flushDraftOnDeparture(tabID: oldTabID) }
            if let newTabID {
                loadDraftFromSession(for: newTabID)
            }
        }
        .onChange(of: localInputText) { _, newValue in
            isInputEmpty = newValue.isEmpty
            guard let tabID = currentTabID, !isSyncingDraftFromSession else { return }
            actions.storeDraft(tabID, newValue, acknowledgedDraftRestorationSequenceByTab[tabID] ?? 0)
        }
        .onChange(of: repromptStore.composerFocusRestoreRequest) { _, request in
            guard let request, request.tabID == currentTabID,
                  repromptViewModel?.currentTabID == request.tabID else { return }
            composerFocusRestoreRequest = request.id
        }
        .onReceive(repromptStore.$draftUpdate) { update in
            guard let update, update.tabID == currentTabID else { return }
            // Read the canonical draft, not a queued older payload, and acknowledge restoration fragments.
            loadDraftFromSession(for: update.tabID)
            // @Published delivers before the stored property changes; acknowledge the incoming revision.
            acknowledgedRepromptPublicationsByTab[update.tabID] = update.identity
        }
        .task(id: repromptStore.autoSendRequest?.operationID) { @MainActor in
            // Submit after publication commits, never reentrantly inside @Published.willSet.
            // Automatic mode sends the operation-owned draft, not a possibly older native
            // streaming chunk. Native edits already revoke the operation before mutation.
            await Task.yield()
            guard !Task.isCancelled, let request = repromptStore.autoSendRequest,
                  request.tabID == currentTabID,
                  let viewModel = repromptViewModel,
                  viewModel.consumeRepromptAutoSend(
                      request, tabID: currentTabID, visibleDraft: localInputText,
                      hasMarkedText: nativeComposerEditor.snapshot(matching: AnyHashable(request.tabID))?.hasMarkedText == true
                  ) else { return }
            submitMessage(rawDraftSnapshot: request.text, restoreFocus: false)
        }
        .onChange(of: props.draftRestorationEvent) { _, event in
            guard let event, event.tabID == currentTabID else { return }
            isSyncingDraftFromSession = true
            let restoredText: String
            switch event.strategy {
            case .replaceIfEmpty:
                let trimmed = localInputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty else {
                    isSyncingDraftFromSession = false
                    return
                }
                restoredText = event.text
            case .prependAlways:
                let existing = localInputText.trimmingCharacters(in: .whitespacesAndNewlines)
                if existing.isEmpty {
                    restoredText = event.text
                } else {
                    restoredText = event.text + "\n" + existing
                }
            case .replaceAlways:
                if let operation = event.operation {
                    restoredText = AgentComposerDraftRestorationReducer.apply(
                        operation,
                        to: localInputText,
                        acknowledgedSequence: acknowledgedDraftRestorationSequenceByTab[event.tabID] ?? 0
                    )
                } else {
                    restoredText = event.text
                }
            }
            let sequence = max(
                acknowledgedDraftRestorationSequenceByTab[event.tabID] ?? 0,
                event.operation?.fragments.last?.sequence ?? 0
            )
            acknowledgedDraftRestorationSequenceByTab[event.tabID] = sequence
            setLocalInputText(restoredText, forceRevision: true, isExternalUpdate: true)
            composerFocusRestoreRequest = UUID()
            actions.storeDraft(event.tabID, restoredText, sequence)
            DispatchQueue.main.async {
                isSyncingDraftFromSession = false
            }
            if !event.message.isEmpty {
                showSteeringUnsupportedNotice(event.message)
            }
        }
        .onDrop(of: Self.attachmentDropTypes, isTargeted: $isAttachmentDropTargeted, perform: handleAttachmentDrop(providers:))
        .overlay(attachmentDropOutline)
    }

    // MARK: - Transient Submit Guidance

    @ViewBuilder
    private var steeringUnsupportedInfoBox: some View {
        if let message = steeringUnsupportedMessage, !message.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .padding(.top, 1)
                Text(message)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: steeringUnsupportedInfoBoxHeight, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Main Content (ResizableTextField)

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent) {
            if let repromptViewModel {
                VStack(alignment: .leading, spacing: 6) {
                    AgentRepromptQuestionsView(viewModel: repromptViewModel, store: repromptStore, tabID: currentTabID, onReturnToComposer: { [tabID = currentTabID] in
                        guard repromptViewModel.currentTabID == tabID else { return }
                        repromptStore.requestComposerFocus(tabID: tabID)
                    })
                    AgentRepromptComposerStrip(
                        viewModel: repromptViewModel,
                        store: repromptStore,
                        tabID: currentTabID,
                        onUndo: { undoRepromptDraft(expectedID: $0) },
                        onSendOriginal: { sendRepromptOriginal(expectedID: $0) }
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { repromptStripHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in repromptStripHeight = height }
                })
            }
            if hasSteeringUnsupportedNotice {
                steeringUnsupportedInfoBox
            }

            if hasPendingAttachments {
                AgentAttachmentsStrip(
                    snapshot: props.attachments,
                    allowsRemoval: currentTabID.map(canMutateAttachments) == true,
                    onRemoveAttachment: removeAttachment,
                    onRemoveTaggedFile: removeTaggedFileAttachment
                )
                .equatable()
            }

            ResizableTextField(
                text: localInputTextBinding,
                placeholder: placeholderText,
                onReturn: sendMessage,
                resetTrigger: $resetTextFieldTrigger,
                onAttachmentPaste: handleAttachmentPaste(pasteboard:),
                features: .agentInputBar(
                    fileTagStore: promptManager.fileManager.workspaceFileContextStore,
                    fileTagSearchService: workspaceSearchService,
                    fileTagSelectionCoordinator: selectionCoordinator,
                    fileTagLookupContextIdentity: AnyHashable(props.fileTagLookupContextIdentity),
                    fileTagLookupContextProvider: { [tabID = props.currentTabID] in
                        await actions.agentWorkspaceLookupContext(tabID)
                    },
                    fileMentionPickerConfiguration: globalSettings.fileMentionPickerConfiguration(),
                    onFileTagCommitted: handleFileTagCommitted(_:),
                    slashSkillSuggestionsProvider: { query in
                        await actions.slashSkillSuggestions(query)
                    }
                ),
                externalUpdateTick: externalTextUpdateTick,
                externalEditTransaction: repromptEditTransaction,
                onUndoExternalEdit: { [id = repromptPresentation?.id, recoveryID = repromptUndoRecovery?.id, tabID = currentTabID] in
                    if let id { undoRepromptDraft(expectedID: id) }
                    else if let tabID, let recoveryID, repromptStore.recoveries[tabID]?.id == recoveryID {
                        _ = repromptViewModel?.restoreRepromptRecovery(tabID: tabID, confirmedReplacement: false)
                    }
                },
                onBeginUserEditing: repromptViewModel == nil ? nil : { [tabID = currentTabID] text, yieldedID in
                    guard let tabID, let viewModel = repromptViewModel,
                          viewModel.currentTabID == tabID, let operation = viewModel.repromptOperation,
                          operation.sourceTabID == tabID, operation.id != yieldedID, operation.beginUserEditing() else { return nil }
                    setLocalInputText(text)
                    actions.storeDraft(tabID, text, acknowledgedDraftRestorationSequenceByTab[tabID] ?? 0)
                    return .init(id: operation.id, revision: externalTextUpdateTick)
                },
                onEscape: repromptPresentation == nil ? nil : { [id = repromptPresentation?.id] in
                    guard let id, let operation = repromptViewModel?.repromptOperation, operation.id == id else { return }
                    if operation.phase == .completed { undoRepromptDraft(expectedID: id) }
                    else { operation.cancel() }
                },
                onCommandReturn: repromptViewModel == nil ? nil : repromptAgain,
                commandReturnMatcher: { LocalKeyboardShortcut.matches($0, .repromptDraft) },
                focusRestoreRequest: composerFocusRestoreRequest,
                nativeEditor: nativeComposerEditor,
                nativeEditorIdentity: currentTabID.map { AnyHashable($0) },
                onHeightChange: { newHeight in
                    editorTextFieldHeight = newHeight
                }
            )
            .frame(height: editorTextFieldHeight)
            .focused($isFocused)
            .overlay(
                Text(placeholderText)
                    .font(fontPreset.standardFont)
                    .foregroundColor(.secondary)
                    .opacity(isInputEmpty ? 1 : 0)
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false),
                alignment: .topLeading
            )
        }
    }

    // MARK: - Control Strip

    private var controlStrip: some View {
        HStack(spacing: 0) {
            // Left side: Combined provider/model + effort + tool/permission controls.
            // Keep this horizontally scrollable so lower-priority chips do not get clipped
            // out of view in narrower windows.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if isCurrentTabMCPControlled {
                        mcpControlChip
                    }
                    if props.hasAvailableAgentProviders {
                        if props.isGlobalModelRouterControllingFreshTask {
                            automaticRouterTargetChip
                            if let autoEffortServiceName = props.autoEffortServiceName {
                                automaticEffortChip(serviceName: autoEffortServiceName)
                            }
                        } else {
                            agentProviderModelPicker
                            acpModelParameterPickers
                            reasoningEffortPicker
                            claudeEffortPicker
                            if let autoEffortServiceName = props.autoEffortServiceName,
                               props.manualEffortControl != nil
                            {
                                automaticEffortChip(serviceName: autoEffortServiceName)
                            }
                            codexToolsButton
                            claudeToolsButton
                        }
                    } else {
                        connectAgentProvidersButton
                    }
                    approvalPopoverChip
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { transaction in
                transaction.animation = nil
            }

            // Right side: Attach + Send/Cancel button
            HStack(spacing: 8) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip")
                        .foregroundColor(canAttachFiles ? .secondary : .gray)
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canAttachFiles)
                .hoverTooltip("Attach Files")
                .transaction { transaction in
                    transaction.animation = nil
                }

                if props.isRoutingFreshTask, let tabID = props.currentTabID {
                    CancelButton(action: { Task { await actions.cancelRouting(tabID) } })
                } else if let cancelTarget = props.cancelTarget {
                    CancelButton(action: { cancelRun(cancelTarget) })
                } else {
                    SendOrResendButton(
                        inputText: localInputText,
                        hasMessages: false, // Disable resend in agent mode - just show greyed send button
                        sendWhenEmpty: hasPendingAttachments,
                        sendTooltip: repromptPresentation == nil ? "Send Message (Return)" : "Send Current Text (Return)",
                        foregroundColor: .accentColor,
                        sendAction: sendMessage,
                        resendAction: {}
                    )
                    .disabled(!canSubmitToRenderedTarget)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: composerControlStripHeight)
    }

    // MARK: - MCP Control Chip

    private var mcpControlChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundColor(.orange)
            Text("MCP")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundColor(.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(4)
        .hoverTooltip("This session is controlled by an MCP agent")
    }

    // MARK: - Agent Pickers

    private var automaticRouterTargetChip: some View {
        let serviceName = props.automaticRouterServiceName
        return Button {
            openAgentDecisionsSettings(section: .modelRouter)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                Text(serviceName.map { "Model Router · \($0)" } ?? "Model Router")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.10))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model Router")
        .accessibilityValue(serviceName.map { "Using \($0)" } ?? "On")
        .hoverTooltip("Model Router asks \(serviceName ?? "the selected service") to choose a model and reasoning effort for this new task. Click to open Model Router settings.")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func automaticEffortChip(serviceName: String) -> some View {
        Button {
            openAgentDecisionsSettings(section: .autoEffort)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.open.with.lines.needle.33percent")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .regular))
                Text("Auto Effort · \(serviceName)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.10))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto Effort")
        .accessibilityValue("Using \(serviceName)")
        .hoverTooltip("Auto Effort uses \(serviceName) before eligible turns; otherwise, your current effort applies. Click to open Auto Effort settings.")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func effortPickerLabel(_ manualDisplayName: String) -> some View {
        Text(manualDisplayName)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(pickerChipColor)
            .cornerRadius(4)
    }

    private enum LayoutMetrics {
        static let providerChipMaxWidth: CGFloat = 250
        static let permissionChipMaxWidth: CGFloat = 120
    }

    private var providerChipMaxWidth: CGFloat {
        fontPreset.scaledClamped(LayoutMetrics.providerChipMaxWidth, max: 340)
    }

    private var approvalPopoverWidth: CGFloat {
        fontPreset.scaledClamped(280, max: 380)
    }

    private var codexToolsPopoverWidth: CGFloat {
        fontPreset.scaledClamped(300, max: 400)
    }

    private var claudeToolsPopoverWidth: CGFloat {
        fontPreset.scaledClamped(280, max: 380)
    }

    private var pickerChipColor: Color {
        Color.secondary.opacity(0.1)
    }

    private var providerChipTitle: String {
        let modelDisplayName = inputBarSelectedModelDisplayName
        let truncatedModelName = String.truncateModelName(
            modelDisplayName,
            maxLength: 28
        )
        return "\(props.selectedAgent.displayName) · \(truncatedModelName)"
    }

    private var isSelectedCodexSpeedTier: Bool {
        AgentModelSelectionWarningVisuals.showsWarning(
            agent: props.selectedAgent,
            rawModel: props.selectedModelRaw
        )
    }

    private func providerChipTooltip(isLocked: Bool, lockedMessage: String?) -> String {
        let baseTooltip: String = if modelControlsDisabled {
            modelControlsDisabledTooltip
        } else if isLocked {
            lockedMessage ?? "This chat is limited to this agent family."
        } else {
            "Choose agent and model"
        }
        guard isSelectedCodexSpeedTier else { return baseTooltip }
        return "\(baseTooltip)\n\(AgentModelSelectionWarningVisuals.tooltip(agent: props.selectedAgent, rawModel: props.selectedModelRaw))"
    }

    private var inputBarSelectedModelDisplayName: String {
        props.selectedModelDisplayName
    }

    private var connectAgentProvidersButton: some View {
        Button(action: openCLIProvidersSettings) {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Connect CLI Providers")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.10))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .hoverTooltip("Open Settings to connect Claude Code, Codex, OpenCode, or Cursor for Agent Mode")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func openCLIProvidersSettings() {
        actions.openCLIProvidersSettings()
    }

    private func openAgentDecisionsSettings(section: SettingsWindowCoordinator.AgentDecisionsSection) {
        NotificationCenter.default.post(
            name: .showModelRouterSettingsTab,
            object: nil,
            userInfo: [
                "windowID": windowID,
                "agentDecisionsSection": section
            ]
        )
    }

    @ViewBuilder
    private var agentProviderModelPicker: some View {
        let isLocked = props.isProviderPickerLockedForCurrentTab
        let lockedMessage = props.lockedAgentSelectionMessage
        StableMenuButton(
            items: agentProviderModelMenuItems,
            triggerStyle: .plain,
            onOpen: captureModelMenuSnapshot
        ) {
            HStack(spacing: 4) {
                Image(systemName: props.selectedAgent.iconName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                if isSelectedCodexSpeedTier {
                    AgentModelSpeedIcon(
                        agent: props.selectedAgent, rawModel: props.selectedModelRaw,
                        font: fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold)
                    )
                }
                Text(providerChipTitle)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9))
                }
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: providerChipMaxWidth, alignment: .leading)
            .foregroundColor(isSelectedCodexSpeedTier ? AgentModelSelectionWarningVisuals.color(agent: props.selectedAgent, rawModel: props.selectedModelRaw) : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .disabled(modelControlsDisabled)
        .opacity(modelControlsDisabled ? 0.55 : 1.0)
        .hoverTooltip(providerChipTooltip(isLocked: isLocked, lockedMessage: lockedMessage))
        .frame(maxWidth: providerChipMaxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func agentProviderModelMenuItems() -> [StableMenuItem] {
        var items: [StableMenuItem] = []
        if let lockedMessage = props.lockedAgentSelectionMessage {
            items.append(.message(lockedMessage))
            items.append(.separator)
        }

        items.append(.header("Model"))
        for agent in props.availableAgents {
            let canSelectAgent = actions.canSelectAgentInCurrentChat(agent)
            if canSelectAgent {
                let modelItems = inputBarModelMenuItems(for: agent)
                items.append(.submenu(agent.displayName, items: modelItems))
            } else {
                items.append(.action(
                    agent.displayName,
                    isEnabled: false,
                    imageSystemName: "lock.fill"
                ) {})
            }
        }
        AgentProviderSettingsMenuAction.appendStableMenuItem(
            to: &items,
            windowID: windowID,
            availableAgents: props.availableAgents
        )
        return items
    }

    private func inputBarModelMenuItems(for agent: AgentProviderKind) -> [StableMenuItem] {
        let options = inputBarModelOptions(for: agent)
        if options.isEmpty {
            return [.action("Use \(agent.displayName)", isEnabled: true, imageSystemName: agent.iconName) {
                actions.selectAgentModel(agent, "")
            }]
        }
        if agent == .cursor {
            return AgentModelStableMenuItems.cursorModelItems(
                options: options,
                selectedModelRaw: props.selectedAgent == .cursor ? ((try? CursorAIModelCatalog.ModelSpecifier(raw: props.selectedModelRaw).baseModelRaw) ?? props.selectedModelRaw) : "",
                selections: props.acpModelParameterControls.filter { $0.providerID == .cursor }.compactMap {
                    guard let savedValueRaw = $0.savedValueRaw else { return nil }
                    return ACPModelParameterSelection(
                        providerID: .cursor,
                        baseModelRaw: $0.baseModelRaw,
                        kind: $0.kind,
                        configID: $0.configID,
                        valueRaw: savedValueRaw
                    )
                },
                onSelectModel: { model in
                    guard !modelControlsDisabled, actions.canMutateCursorModel(props.currentTabID), actions.canSelectAgentInCurrentChat(.cursor) else { return }
                    actions.selectAgentModel(.cursor, model.rawValue)
                },
                onSelectParameter: { model, parameter in
                    guard !modelControlsDisabled, actions.canMutateCursorModel(props.currentTabID), actions.canSelectAgentInCurrentChat(.cursor) else { return }
                    if props.selectedAgent != .cursor || (try? CursorAIModelCatalog.ModelSpecifier(raw: props.selectedModelRaw).baseModelRaw) != model.rawValue {
                        actions.selectAgentModel(.cursor, model.rawValue)
                    }
                    actions.selectACPModelParameter(parameter, nil)
                },
                onClearParameter: { model, identity in
                    guard !modelControlsDisabled, actions.canMutateCursorModel(props.currentTabID), actions.canSelectAgentInCurrentChat(.cursor) else { return }
                    if props.selectedAgent != .cursor || (try? CursorAIModelCatalog.ModelSpecifier(raw: props.selectedModelRaw).baseModelRaw) != model.rawValue {
                        actions.selectAgentModel(.cursor, model.rawValue)
                    }
                    actions.clearCursorModelParameter(identity)
                }
            )
        }
        if agent == .devin {
            return DevinModelCatalog.current.menuGroups(for: options).flatMap { group -> [StableMenuItem] in
                guard group.rendersAsSubmenu else {
                    return group.entries.map { inputBarModelMenuItem(agent: agent, model: $0.option) }
                }
                return [.submenu(group.displayName, items: group.entries.map {
                    inputBarModelMenuItem(agent: agent, model: $0.option, title: $0.effortDisplayName)
                })]
            }
        }
        guard agent == .openCode else {
            return options.map { inputBarModelMenuItem(agent: agent, model: $0) }
        }
        return AgentModelCatalog.openCodeMenu(for: options).providerGroups.flatMap { providerGroup -> [StableMenuItem] in
            let modelItems = providerGroup.groups.map { inputBarOpenCodeModelMenuItem(agent: agent, group: $0) }
            guard providerGroup.rendersAsSubmenu else { return modelItems }
            return [.submenu(providerGroup.displayName, items: modelItems)]
        }
    }

    private func inputBarOpenCodeModelMenuItem(agent: AgentProviderKind, group: AgentModelCatalog.OpenCodeMenuGroup) -> StableMenuItem {
        if group.rendersAsSubmenu {
            return StableMenuItem.submenu(
                group.modelDisplayName,
                items: group.options.map { menuOption in
                    inputBarModelMenuItem(agent: agent, model: menuOption.option, title: menuOption.displayName)
                }
            )
        }
        if let menuOption = group.options.first {
            return inputBarModelMenuItem(agent: agent, model: menuOption.option, title: menuOption.displayName)
        }
        return .separator
    }

    private func inputBarModelMenuItem(agent: AgentProviderKind, model: AgentModelOption, title: String? = nil) -> StableMenuItem {
        let isSelected = props.selectedAgent == agent && AgentModelCatalog.modelOptionIsSelected(
            optionRaw: model.rawValue,
            selectedRaw: props.selectedModelRaw,
            agentKind: agent
        )
        return StableMenuItem.action(
            title ?? model.displayName,
            isEnabled: true,
            isSelected: isSelected,
            imageSystemName: AgentModelSelectionWarningVisuals.stableMenuImageSystemName(agent: agent, rawModel: model.rawValue),
            style: AgentModelSelectionWarningVisuals.stableMenuStyle(agent: agent, rawModel: model.rawValue)
        ) {
            AgentModelCatalog.updateLastUsedEffortIfEncoded(
                agentKind: agent,
                rawModel: model.rawValue
            )
            actions.selectAgentModel(agent, model.rawValue)
        }
    }

    private func inputBarModelOptions(for agent: AgentProviderKind) -> [AgentModelOption] {
        let sourceOptions: [AgentModelOption]
        let includeClaudeEffortVariants = !agent.usesClaudeTooling
        if let snapshot = modelMenuSnapshotByAgent?[agent] {
            sourceOptions = snapshot
        } else {
            sourceOptions = actions.modelOptions(agent, includeClaudeEffortVariants)
        }
        let filtered = sourceOptions.filter { !$0.isPlaceholderDefault }
        return filtered.isEmpty ? sourceOptions : filtered
    }

    @MainActor
    private func captureModelMenuSnapshot() {
        modelMenuSnapshotReleaseTask?.cancel()
        var snapshot: [AgentProviderKind: [AgentModelOption]] = [:]
        for agent in props.availableAgents {
            snapshot[agent] = actions.modelOptions(agent, !agent.usesClaudeTooling)
        }
        modelMenuSnapshotByAgent = snapshot
        modelMenuSnapshotReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            modelMenuSnapshotByAgent = nil
            modelMenuSnapshotReleaseTask = nil
        }
    }

    @ViewBuilder
    private var reasoningEffortPicker: some View {
        if props.manualEffortControl == .codex {
            let efforts = actions.reasoningEffortOptionsForCurrentSelection()
            Menu {
                ForEach(efforts, id: \.rawValue) { effort in
                    Button {
                        actions.selectReasoningEffort(effort)
                    } label: {
                        HStack {
                            Text(effort.displayName)
                            if props.selectedReasoningEffortRaw == effort.rawValue {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                effortPickerLabel(props.selectedReasoningEffortDisplayName)
            }
            .menuStyle(.borderlessButton)
            .disabled(efforts.isEmpty || modelControlsDisabled)
            .opacity(modelControlsDisabled ? 0.55 : 1.0)
            .hoverTooltip(modelControlsDisabled ? modelControlsDisabledTooltip : "Codex reasoning effort")
            .fixedSize()
        }
    }

    private var acpModelParameterPickers: some View {
        ForEach(props.acpModelParameterControls) { control in
            Menu {
                ForEach(control.choices, id: \.rawValue) { choice in
                    Button {
                        actions.selectACPModelParameter(
                            ACPModelParameterSelection(
                                providerID: control.providerID,
                                baseModelRaw: control.baseModelRaw,
                                kind: control.kind,
                                configID: control.configID,
                                valueRaw: choice.rawValue
                            ),
                            control.openCodeDiscoveryKey
                        )
                    } label: {
                        HStack {
                            Text(choice.displayName)
                            if choice.rawValue == control.selectedValueRaw {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(control.selectedDisplayName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
                .foregroundColor(
                    control.isSavedValueUnavailable || (
                        control.kind == .speed
                            && control.selectedDisplayName.caseInsensitiveCompare("fast") == .orderedSame
                    )
                        ? .orange
                        : .secondary
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pickerChipColor)
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(Text(control.accessibilityLabel))
            .accessibilityValue(Text(control.accessibilityValue))
            .disabled(modelControlsDisabled || control.choices.isEmpty)
            .opacity(modelControlsDisabled ? 0.55 : 1.0)
            .hoverTooltip(modelControlsDisabled ? modelControlsDisabledTooltip : control.tooltip)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var claudeEffortPicker: some View {
        if props.manualEffortControl == .claude,
           let claudeTools = props.providerControls?.claudeTools
        {
            let efforts = AgentModelCatalog.supportedClaudeEfforts(
                forSelectedModelRaw: props.selectedModelRaw,
                agentKind: props.selectedAgent
            )
            Menu {
                ForEach(efforts, id: \.rawValue) { level in
                    Button {
                        actions.setClaudeEffortLevel(level)
                    } label: {
                        HStack {
                            Text(level.displayName)
                            if claudeTools.effortLevel == level {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                effortPickerLabel(claudeTools.effortLevel.displayName)
            }
            .menuStyle(.borderlessButton)
            .disabled(modelControlsDisabled || efforts.isEmpty)
            .opacity(modelControlsDisabled ? 0.55 : 1.0)
            .fixedSize()
            .hoverTooltip(modelControlsDisabled ? modelControlsDisabledTooltip : "Claude effort level")
        }
    }

    @ViewBuilder
    private var codexToolsButton: some View {
        if props.selectedAgent == .codexExec {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Tools")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isCodexRunActive else { return }
                showCodexToolsPopover.toggle()
            }
            .popover(isPresented: $showCodexToolsPopover, arrowEdge: .bottom) {
                codexToolsPopoverContent
            }
            .opacity(isCodexRunActive ? 0.4 : 1.0)
            .hoverTooltip(isCodexRunActive ? "Tool controls locked during active run" : "Configure Codex tools & MCP servers")
            .fixedSize()
        }
    }

    @ViewBuilder
    private var claudeToolsButton: some View {
        if props.selectedAgent.usesClaudeTooling {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Tools")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                showClaudeToolsPopover.toggle()
            }
            .popover(isPresented: $showClaudeToolsPopover, arrowEdge: .bottom) {
                claudeToolsPopoverContent
            }
            .hoverTooltip("Configure Claude tools")
            .fixedSize()
        }
    }

    private var permissionChipIconName: String {
        permissionBinding?.iconName ?? "shield"
    }

    private var permissionChipDisplayName: String {
        permissionBinding?.displayName ?? "Default"
    }

    private var permissionChipIsWarning: Bool {
        permissionBinding?.isWarning ?? false
    }

    @ViewBuilder
    private var approvalPopoverChip: some View {
        let warn = permissionChipIsWarning
        Button {
            showPermissionPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: permissionChipIconName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Permissions · \(permissionChipDisplayName)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
            }
            .foregroundColor(warn ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .hoverTooltip("Permissions & approval settings")
        .popover(isPresented: $showPermissionPopover, arrowEdge: .bottom) {
            approvalPopoverContent
        }
    }

    @ViewBuilder
    private var managedPermissionInfoBlock: some View {
        if let reason = permissionBinding?.externallyManagedReason {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(reason)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
    }

    private var approvalPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                .padding(.bottom, 2)

            managedPermissionInfoBlock

            VStack(alignment: .leading, spacing: 6) {
                Text("Sandbox Level")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                if let permissionBinding {
                    ForEach(permissionBinding.options) { option in
                        permissionRow(
                            title: option.title,
                            icon: option.iconName,
                            isSelected: option.isSelected,
                            disabled: !option.isEnabled
                        ) {
                            actions.setProviderPermissionLevel(option.id)
                        }
                    }

                    if let detailText = permissionBinding.options.first(where: { $0.isSelected })?.detailText,
                       !detailText.isEmpty
                    {
                        Text(detailText)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundStyle(permissionBinding.isWarning ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Permission settings are unavailable until a session is active.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { props.autoEditEnabled },
                set: { actions.setAutoEditEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Edit")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    Text("Apply file edits without approval")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(permissionControlsDisabled)
        }
        .padding(14)
        .frame(width: approvalPopoverWidth)
    }

    private func permissionRow(
        title: String,
        icon: String,
        isSelected: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .frame(width: fontPreset.scaledClamped(16, max: 22))
                Text(title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? .tertiary : .primary)
    }

    @ViewBuilder
    private var codexToolsPopoverContent: some View {
        if let codexTools = props.providerControls?.codexTools {
            Form {
                if isCodexRunActive {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            Text("Tool settings are locked during an active run")
                                .font(fontPreset.captionFont)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section {
                    Toggle("Bash", isOn: Binding(
                        get: { codexTools.bashToolEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.bashTool(enabled: newValue))
                        }
                    ))

                    Toggle("Search", isOn: Binding(
                        get: { codexTools.searchToolEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.searchTool(enabled: newValue))
                        }
                    ))

                    Toggle("Goals", isOn: Binding(
                        get: { codexTools.goalSupportEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.goalSupport(enabled: newValue))
                        }
                    ))
                    .hoverTooltip("Codex /goal support is enabled by default. Turn this off to stop RepoPrompt from enabling features.goals for Codex app-server launch and thread config.")

                    Toggle("Reasoning Summaries", isOn: Binding(
                        get: { codexTools.reasoningSummariesEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.reasoningSummaries(enabled: newValue))
                        }
                    ))
                    .hoverTooltip("Controls model_reasoning_summary for Codex Agent Mode app-server thread start/resume. Off sends none; on sends auto.")

                    Toggle("Local Memories", isOn: Binding(
                        get: { codexTools.memoriesEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.memories(enabled: newValue))
                        }
                    ))
                    .hoverTooltip("Let Codex generate and reuse local memories across Agent Mode chats. Generation may perform model-backed background or startup work and use Codex quota. A new or restarted Codex session may be required.")
                } header: {
                    Text("Tools")
                }

                Section {
                    if codexTools.mcpServerEntries.isEmpty {
                        Text("No servers in RepoPrompt's isolated Codex config")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(codexTools.mcpServerEntries, id: \.normalizedName) { entry in
                            let isRepoPromptServer = entry.normalizedName.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
                            Toggle(
                                isOn: Binding(
                                    get: {
                                        codexTools.mcpServerStatesByNormalizedName[normalizedServerToggleKey(entry.normalizedName)] ?? isRepoPromptServer
                                    },
                                    set: { newValue in
                                        actions.applyCodexToolSettingMutation(
                                            .mcpServer(normalizedName: entry.normalizedName, enabled: newValue)
                                        )
                                    }
                                )
                            ) {
                                HStack(spacing: 4) {
                                    Text(entry.normalizedName)
                                    if isRepoPromptServer {
                                        Text("(required)")
                                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .disabled(isRepoPromptServer)
                        }
                    }
                } header: {
                    Text("MCP Servers")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: codexToolsPopoverWidth)
            .disabled(isCodexRunActive)
        } else {
            Text("Codex tool settings are unavailable until a session is active.")
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(width: codexToolsPopoverWidth)
        }
    }

    @ViewBuilder
    private var claudeToolsPopoverContent: some View {
        if let claudeTools = props.providerControls?.claudeTools {
            Form {
                ClaudeToolSettingsActiveRunNotice(
                    isVisible: props.selectedAgent.usesClaudeTooling && props.runState.isActive,
                    fontPreset: fontPreset
                )

                Section {
                    Toggle("Bash", isOn: Binding(
                        get: { claudeTools.bashToolEnabled },
                        set: { newValue in
                            actions.applyClaudeToolSettingMutation(.bashTool(enabled: newValue))
                        }
                    ))
                } header: {
                    Text("Tools")
                }

                Section {
                    Toggle("RepoPrompt Only", isOn: Binding(
                        get: { claudeTools.mcpStrictModeEnabled },
                        set: { newValue in
                            actions.applyClaudeToolSettingMutation(.mcpStrictMode(enabled: newValue))
                        }
                    ))
                } header: {
                    Text("MCP Servers")
                } footer: {
                    Text(
                        claudeTools.mcpStrictModeEnabled
                            ? "Only RepoPrompt MCP is active. Other MCP servers are ignored."
                            : "Other MCP servers from your Claude config will also be loaded."
                    )
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Lazy Tool Loading", isOn: Binding(
                        get: { claudeTools.toolSearchEnabled },
                        set: { newValue in
                            actions.applyClaudeToolSettingMutation(.toolSearch(enabled: newValue))
                        }
                    ))
                } header: {
                    Text("Tool Search")
                } footer: {
                    Text(
                        claudeTools.toolSearchEnabled
                            ? "Claude searches for each tool before using it. Uses less context but adds latency."
                            : "All tools are preloaded into context. Faster but uses more tokens."
                    )
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                }

                Section {
                    Picker(selection: Binding(
                        get: { claudeTools.agentModePromptDelivery },
                        set: { newValue in
                            actions.applyClaudeToolSettingMutation(
                                .agentModePromptDelivery(delivery: newValue)
                            )
                        }
                    )) {
                        ForEach(ClaudeAgentToolPreferences.AgentModePromptDelivery.allCases, id: \.rawValue) { delivery in
                            Text(delivery.displayName).tag(delivery)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } header: {
                    Text("Sys Prompt Packaging")
                } footer: {
                    Text(claudeTools.agentModePromptDelivery.detailText)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: claudeToolsPopoverWidth)
        } else {
            Text("Claude tool settings are unavailable until a session is active.")
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(width: claudeToolsPopoverWidth)
        }
    }

    @ViewBuilder
    private var attachmentDropOutline: some View {
        if isAttachmentDropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 2)
                .padding(.bottom, Self.footerHeight)
        }
    }

    // MARK: - Actions

    private func sendRepromptOriginal(expectedID: UUID) {
        guard let operation = repromptViewModel?.repromptOperation, operation.id == expectedID,
              let tabID = currentTabID, operation.sourceTabID == tabID else { return }
        operation.useOriginal()
        guard operation.phase == .completed else { return }
        loadDraftFromSession(for: tabID)
        submitMessage(rawDraftSnapshot: localInputText, restoreFocus: true)
    }

    private func undoRepromptDraft(expectedID: UUID?) {
        guard let expectedID, let viewModel = repromptViewModel, let operation = viewModel.repromptOperation,
              operation.id == expectedID, viewModel.currentTabID == operation.sourceTabID,
              operation.validate() else { return }
        // Flush a last keystroke even if SwiftUI's onChange has not run yet.
        if let tabID = currentTabID {
            actions.storeDraft(tabID, localInputText, acknowledgedDraftRestorationSequenceByTab[tabID] ?? 0)
        }
        repromptViewModel?.undoReprompt()
    }

    private func repromptAgain() -> Bool {
        retireUnownedSubmissionLatch()
        if repromptViewModel?.repromptOperation?.phase.isBusy == true || isSubmissionPending { return true }
        guard props.canSendWithCurrentProvider,
              let target = renderedSubmitTarget, let repromptViewModel else { return false }
        guard let native = nativeComposerEditor.snapshot(matching: AnyHashable(target.tabID)), !native.hasMarkedText else { return true }
        setLocalInputText(native.text)
        actions.storeDraft(target.tabID, localInputText, acknowledgedDraftRestorationSequenceByTab[target.tabID] ?? 0)
        return repromptViewModel.requestComposerRepromptAgain(target: target, text: localInputText)
    }

    private func sendMessage() {
        guard let tabID = currentTabID,
              let native = nativeComposerEditor.snapshot(matching: AnyHashable(tabID)), !native.hasMarkedText else { return }
        submitMessage(rawDraftSnapshot: native.text, restoreFocus: true)
    }

    private func submitMessage(rawDraftSnapshot: String, restoreFocus: Bool) {
        retireUnownedSubmissionLatch()
        guard !isSubmissionPending else {
            logViewSubmitRejection(reason: "local_attempt_latched", target: renderedSubmitTarget)
            return
        }
        guard props.canSendWithCurrentProvider else {
            if props.hasAvailableAgentProviders {
                showSteeringUnsupportedNotice(props.unavailableSelectedAgentMessage ?? "Connect this agent provider in Settings before sending.")
            } else {
                openCLIProvidersSettings()
            }
            return
        }
        let trimmed = rawDraftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasPendingAttachments else { return }
        guard let submitTarget = renderedSubmitTarget else {
            logViewSubmitRejection(reason: "view_nil_target", target: props.submitTarget)
            showSteeringUnsupportedNotice(Self.staleSubmitTargetMessage)
            return
        }
        setLocalInputText(rawDraftSnapshot)
        actions.storeDraft(submitTarget.tabID, rawDraftSnapshot, acknowledgedDraftRestorationSequenceByTab[submitTarget.tabID] ?? 0)
        if actions.prepareReprompt(submitTarget, rawDraftSnapshot) { return }
        guard let attempt = submissionLatch.begin(
            target: submitTarget,
            rawDraftSnapshot: rawDraftSnapshot
        ) else {
            logViewSubmitRejection(reason: "local_attempt_latched", target: submitTarget)
            return
        }

        actions.storeDraft(
            attempt.sourceTabID,
            rawDraftSnapshot,
            acknowledgedDraftRestorationSequenceByTab[attempt.sourceTabID] ?? 0
        )
        switch actions.claimSubmit(attempt) {
        case let .claimed(claim):
            // Admission owns this snapshot now; routing must not leave a duplicate in the editor.
            setLocalInputText("", isExternalUpdate: true)
            resetTextFieldTrigger.toggle()
            if restoreFocus { composerFocusRestoreRequest = UUID() }
            Task { @MainActor in
                let submissionResult = await actions.executeSubmit(claim, trimmed)
                let effects = submissionLatch.complete(
                    attempt,
                    result: submissionResult,
                    currentTabID: currentTabID,
                    currentRawDraft: localInputText
                )
                guard effects.matchedAttempt else {
                    logViewSubmitRejection(reason: "stale_completion", target: attempt.target)
                    return
                }
                if effects.shouldClearInput {
                    setLocalInputText("", isExternalUpdate: true)
                    resetTextFieldTrigger.toggle()
                }
                if let blockedMessage = effects.blockedMessage {
                    showSteeringUnsupportedNotice(blockedMessage)
                }
            }
        case let .rejected(rejection):
            submissionLatch.cancel(attempt)
            if case .activeAttemptExists = rejection {
                return
            }
            showSteeringUnsupportedNotice(Self.staleSubmitTargetMessage)
        }
    }

    private func showSteeringUnsupportedNotice(_ message: String) {
        guard !message.isEmpty else { return }
        submissionLatch.advanceNoticeRevision()
        let noticeRevision = submissionLatch.noticeRevision
        steeringUnsupportedDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            steeringUnsupportedMessage = message
        }
        steeringUnsupportedDismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard submissionLatch.noticeRevision == noticeRevision,
                      steeringUnsupportedMessage == message
                else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    steeringUnsupportedMessage = nil
                }
                steeringUnsupportedDismissTask = nil
            }
        }
    }

    private func logViewSubmitRejection(reason: String, target: AgentComposerSubmitTarget?) {
        #if DEBUG
            perfRecorder.event(
                "agent.composer.submit.rejected",
                tabID: currentTabID,
                fields: [
                    "reason": reason,
                    "currentTabID": perfRecorder.shortID(currentTabID),
                    "propsTabID": perfRecorder.shortID(props.currentTabID),
                    "targetTabID": perfRecorder.shortID(target?.tabID),
                    "attemptID": perfRecorder.shortID(submissionLatch.activeAttemptID(for: currentTabID)),
                    "inputRevision": String(submissionLatch.inputRevision),
                    "expectedSubmissionToken": perfRecorder.shortID(target?.expectedSubmissionToken),
                    "expectedSourceAgentSessionID": perfRecorder.shortID(target?.expectedSourceAgentSessionID),
                    "expectedPersistentBindingGeneration": perfRecorder.shortID(target?.expectedPersistentBindingIdentity?.generation),
                    "expectedBindingTransitionGeneration": target.map { String($0.expectedBindingTransitionGeneration) } ?? "nil"
                ]
            )
        #endif
    }

    private func cancelRun(_ target: AgentRunCancelTarget) {
        Task {
            await actions.cancelRun(target)
        }
    }

    private func canMutateAttachments(tabID: UUID) -> Bool {
        let liveTabID: UUID? = if let repromptViewModel { repromptViewModel.currentTabID }
        else { currentTabID }
        return !pendingSubmissionStore.hasPendingSubmission(tabID: tabID)
            && repromptStore.allowsAttachmentMutation(tabID: tabID, currentTabID: liveTabID)
    }

    private func pickFiles() {
        guard canAttachFiles, let tabID = currentTabID else { return }
        Task { @MainActor in
            let targetWindow = WindowStatesManager.shared.allWindows.first { $0.windowID == windowID }?.nsWindow
            let urls = await OpenPanelService.shared.pickFiles(
                title: "Choose Files",
                message: "Attach one or more files for the next turn.",
                attachedTo: targetWindow
            )
            guard canMutateAttachments(tabID: tabID) else { return }
            await actions.attachFiles(tabID, urls)
        }
    }

    private func handleFileTagCommitted(_ suggestion: MentionSuggestion) {
        guard let tabID = currentTabID, canMutateAttachments(tabID: tabID) else { return }
        let attachmentDisplayName = AgentFileMentionText.attachmentDisplayName(for: suggestion)
        actions.commitTaggedFile(tabID, suggestion, attachmentDisplayName)
    }

    private func removeAttachment(_ attachmentID: UUID) {
        guard let tabID = currentTabID, canMutateAttachments(tabID: tabID) else { return }
        actions.removePendingAttachment(tabID, attachmentID)
    }

    private func removeTaggedFileAttachment(_ attachmentID: UUID) {
        guard let tabID = currentTabID, canMutateAttachments(tabID: tabID) else { return }
        let attachment = props.attachments.taggedFileAttachments
            .first(where: { $0.id == attachmentID })
        actions.removeTaggedFile(tabID, attachmentID)
        if let attachment {
            setLocalInputText(
                AgentFileMentionText.removingTaggedMention(
                    displayName: attachment.displayName,
                    relativePath: attachment.relativePath,
                    from: localInputText
                ),
                isExternalUpdate: true
            )
        }
    }

    private func handleAttachmentDrop(providers: [NSItemProvider]) -> Bool {
        guard let tabID = currentTabID, canMutateAttachments(tabID: tabID) else {
            return false
        }
        return attachmentIntake.loadPreparedAttachments(from: providers) { prepared, failures in
            guard !prepared.isEmpty || !failures.isEmpty else { return }
            Task { @MainActor in
                actions.reportAttachmentFailures(tabID, failures)
                if !prepared.isEmpty {
                    attachPreparedAttachments(prepared, tabID: tabID)
                }
            }
        }
    }

    private func handleAttachmentPaste(pasteboard: NSPasteboard) -> Bool {
        guard let tabID = currentTabID, canMutateAttachments(tabID: tabID) else {
            return false
        }
        guard attachmentIntake.shouldConsumePasteAsAttachment(from: pasteboard) else {
            return false
        }
        let prepared = attachmentIntake.preparedAttachments(from: pasteboard)
        guard !prepared.isEmpty else {
            return false
        }
        attachPreparedAttachments(prepared, tabID: tabID)
        return true
    }

    private func attachPreparedAttachments(_ prepared: [AgentAttachmentIntake.Prepared], tabID: UUID) {
        let urls = prepared.map(\.url)
        let intake = attachmentIntake
        Task { @MainActor in
            defer { intake.cleanupTemporaryFiles(prepared) }
            guard canMutateAttachments(tabID: tabID) else { return }
            await actions.attachFiles(tabID, urls)
        }
    }

    private func normalizedServerToggleKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func setLocalInputText(
        _ newValue: String,
        forceRevision: Bool = false,
        isExternalUpdate: Bool = false
    ) {
        if isExternalUpdate {
            externalTextUpdateTick &+= 1
        }
        guard forceRevision || localInputText != newValue else {
            isInputEmpty = newValue.isEmpty
            return
        }
        submissionLatch.advanceInputRevision()
        localInputText = newValue
        isInputEmpty = newValue.isEmpty
    }

    private func loadDraftFromSession(for tabID: UUID) {
        isSyncingDraftFromSession = true
        let snapshot = actions.loadDraft(tabID)
        if let update = repromptStore.draftUpdate, update.tabID == tabID {
            acknowledgedRepromptPublicationsByTab[tabID] = update.identity
        }
        acknowledgedDraftRestorationSequenceByTab[tabID] = snapshot.restorationSequence
        setLocalInputText(
            snapshot.text,
            forceRevision: true,
            isExternalUpdate: true
        )
        DispatchQueue.main.async {
            isSyncingDraftFromSession = false
        }
    }
}

struct AgentAttachmentIntake {
    struct Prepared: Equatable {
        let url: URL
        let isTemporary: Bool
    }

    private let fileManager: FileManager
    private let temporaryRoot: URL
    private let preferredImageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .bmp, .tiff]

    init(fileManager: FileManager = .default, temporaryRoot: URL? = nil) {
        self.fileManager = fileManager
        self.temporaryRoot = temporaryRoot
            ?? MCPFilesystemConstants.identity.temporaryRootURL(fileManager: fileManager)
            .appendingPathComponent("AgentAttachmentInput", isDirectory: true)
    }

    /// Files copied from Finder or any file URL on the pasteboard come first; raw image data, such as a
    /// screenshot, is the fallback. Plain text is never read as a reference to a file.
    func preparedAttachments(from pasteboard: NSPasteboard) -> [Prepared] {
        let files = preparedFileURLs(from: pasteboard)
        if !files.isEmpty {
            return files
        }

        var prepared = preparedImageDataRepresentations(from: pasteboard)
        if prepared.isEmpty {
            prepared = preparedNSImageObjects(from: pasteboard)
        }

        return deduplicated(prepared)
    }

    func shouldConsumePasteAsAttachment(from pasteboard: NSPasteboard) -> Bool {
        if !AttachmentPasteboard.regularFileURLs(in: pasteboard).isEmpty {
            return true
        }
        if hasExplicitImagePasteboardType(in: pasteboard) {
            return true
        }
        return shouldConsumeNSImageReadablePasteboard(pasteboard)
    }

    func loadPreparedAttachments(
        from providers: [NSItemProvider],
        completion: @escaping (_ prepared: [Prepared], _ failures: [AgentAttachmentFailure]) -> Void
    ) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || bestImageTypeIdentifier(from: $0.registeredTypeIdentifiers) != nil
        }
        guard !candidates.isEmpty else {
            return false
        }

        let lockQueue = DispatchQueue(label: "AgentAttachmentIntake.lock")
        let group = DispatchGroup()
        var prepared: [Prepared] = []
        var failures: [AgentAttachmentFailure] = []

        func fail(_ fileName: String, _ reason: String) {
            lockQueue.sync {
                failures.append(AgentAttachmentFailure(fileName: fileName, reason: reason))
            }
        }

        func appendImageData(from provider: NSItemProvider, typeIdentifier: String) {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                defer { group.leave() }
                guard let data, !data.isEmpty,
                      let fileURL = try? writeTemporaryImageData(data, typeIdentifier: typeIdentifier)
                else {
                    fail(provider.suggestedName ?? "image", "The dropped image could not be read.")
                    return
                }
                lockQueue.sync {
                    prepared.append(Prepared(url: fileURL, isTemporary: true))
                }
            }
        }

        for provider in candidates {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let fileURL = droppedFileURL(from: item)
                    if let fileURL, AttachmentPasteboard.isRegularFile(fileURL) {
                        lockQueue.sync {
                            prepared.append(Prepared(url: fileURL.standardizedFileURL, isTemporary: false))
                        }
                        group.leave()
                        return
                    }

                    guard let imageTypeIdentifier = bestImageTypeIdentifier(from: provider.registeredTypeIdentifiers) else {
                        if let fileURL {
                            fail(
                                fileURL.lastPathComponent,
                                AttachmentPasteboard.isDirectory(fileURL)
                                    ? AgentAttachmentStore.Error.sourceIsNotFile.localizedDescription
                                    : "The item is not a regular file."
                            )
                        } else {
                            fail(provider.suggestedName ?? "dropped item", "The dropped item could not be read.")
                        }
                        group.leave()
                        return
                    }
                    appendImageData(from: provider, typeIdentifier: imageTypeIdentifier)
                }
                continue
            }

            guard let imageTypeIdentifier = bestImageTypeIdentifier(from: provider.registeredTypeIdentifiers) else {
                continue
            }
            group.enter()
            appendImageData(from: provider, typeIdentifier: imageTypeIdentifier)
        }

        group.notify(queue: .main) {
            lockQueue.sync {
                let deduplicatedPrepared = deduplicated(prepared)
                let reportedFailures = failures
                DispatchQueue.main.async {
                    completion(deduplicatedPrepared, reportedFailures)
                }
            }
        }
        return true
    }

    func cleanupTemporaryFiles(_ prepared: [Prepared]) {
        let temporaryPrefix = temporaryRoot.path + "/"
        for entry in prepared where entry.isTemporary {
            let standardized = entry.url.standardizedFileURL
            guard standardized.path.hasPrefix(temporaryPrefix) else { continue }
            try? fileManager.removeItem(at: standardized)
        }
    }

    private func writeTemporaryImageData(_ data: Data, typeIdentifier: String) throws -> URL {
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let fileExtension = (UTType(typeIdentifier)?.preferredFilenameExtension ?? "png")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationURL = temporaryRoot
            .appendingPathComponent("pasted-image-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension.isEmpty ? "png" : fileExtension)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    private func bestImageTypeIdentifier(from identifiers: [String]) -> String? {
        let imageIdentifiers = identifiers.compactMap { identifier -> (raw: String, canonical: UTType)? in
            guard let canonical = canonicalImageType(forIdentifier: identifier) else { return nil }
            return (identifier, canonical)
        }
        guard !imageIdentifiers.isEmpty else { return nil }

        for preferred in preferredImageTypes {
            if let match = imageIdentifiers.first(where: { $0.canonical == preferred }) {
                return match.raw
            }
        }
        return imageIdentifiers.first?.raw
    }

    private func bestImagePasteboardType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        imagePasteboardTypeCandidates(from: types).first
    }

    private func imagePasteboardTypeCandidates(from types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        let imageTypes = types.compactMap { type -> (raw: NSPasteboard.PasteboardType, canonical: UTType)? in
            guard let canonical = canonicalImageType(forPasteboardType: type) else { return nil }
            return (type, canonical)
        }
        guard !imageTypes.isEmpty else { return [] }

        var ordered: [NSPasteboard.PasteboardType] = []
        for preferred in preferredImageTypes {
            for candidate in imageTypes where candidate.canonical == preferred {
                if !ordered.contains(candidate.raw) {
                    ordered.append(candidate.raw)
                }
            }
        }
        for candidate in imageTypes where !ordered.contains(candidate.raw) {
            ordered.append(candidate.raw)
        }
        return ordered
    }

    private func canonicalImageType(forIdentifier identifier: String) -> UTType? {
        ImagePasteboardTypes.canonicalImageType(forIdentifier: identifier)
    }

    private func canonicalImageType(forPasteboardType type: NSPasteboard.PasteboardType) -> UTType? {
        canonicalImageType(forIdentifier: type.rawValue)
    }

    private func preparedImageDataRepresentations(from pasteboard: NSPasteboard) -> [Prepared] {
        var prepared: [Prepared] = []

        for item in pasteboard.pasteboardItems ?? [] {
            guard let representation = firstImageDataRepresentation(in: item),
                  let fileURL = try? writeTemporaryImageData(
                      representation.data,
                      typeIdentifier: representation.typeIdentifier
                  )
            else { continue }
            prepared.append(Prepared(url: fileURL, isTemporary: true))
        }

        if prepared.isEmpty,
           let representation = firstImageDataRepresentation(in: pasteboard),
           let fileURL = try? writeTemporaryImageData(
               representation.data,
               typeIdentifier: representation.typeIdentifier
           )
        {
            prepared.append(Prepared(url: fileURL, isTemporary: true))
        }

        return prepared
    }

    private func preparedNSImageObjects(from pasteboard: NSPasteboard) -> [Prepared] {
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] else {
            return []
        }

        var prepared: [Prepared] = []
        for image in images {
            guard let representation = imageDataRepresentation(from: image),
                  let fileURL = try? writeTemporaryImageData(
                      representation.data,
                      typeIdentifier: representation.typeIdentifier
                  )
            else { continue }
            prepared.append(Prepared(url: fileURL, isTemporary: true))
        }
        return prepared
    }

    private func firstImageDataRepresentation(
        in item: NSPasteboardItem
    ) -> (data: Data, typeIdentifier: String)? {
        for pasteboardType in imagePasteboardTypeCandidates(from: item.types) {
            guard let data = item.data(forType: pasteboardType), !data.isEmpty else { continue }
            let typeIdentifier = canonicalImageType(forPasteboardType: pasteboardType)?.identifier ?? pasteboardType.rawValue
            return (data, typeIdentifier)
        }
        return nil
    }

    private func firstImageDataRepresentation(
        in pasteboard: NSPasteboard
    ) -> (data: Data, typeIdentifier: String)? {
        guard let types = pasteboard.types else { return nil }
        for pasteboardType in imagePasteboardTypeCandidates(from: types) {
            guard let data = pasteboard.data(forType: pasteboardType), !data.isEmpty else { continue }
            let typeIdentifier = canonicalImageType(forPasteboardType: pasteboardType)?.identifier ?? pasteboardType.rawValue
            return (data, typeIdentifier)
        }
        return nil
    }

    private func imageDataRepresentation(from image: NSImage) -> (data: Data, typeIdentifier: String)? {
        guard let tiffData = image.tiffRepresentation, !tiffData.isEmpty else {
            return nil
        }
        if let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]),
           !pngData.isEmpty
        {
            return (pngData, UTType.png.identifier)
        }
        return (tiffData, UTType.tiff.identifier)
    }

    private func preparedFileURLs(from pasteboard: NSPasteboard) -> [Prepared] {
        deduplicated(
            AttachmentPasteboard.regularFileURLs(in: pasteboard).map { Prepared(url: $0, isTemporary: false) }
        )
    }

    private func shouldConsumeNSImageReadablePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) else {
            return false
        }
        let plainString = pasteboard.string(forType: .string) ?? ""
        return plainString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasExplicitImagePasteboardType(in pasteboard: NSPasteboard) -> Bool {
        if let types = pasteboard.types,
           bestImagePasteboardType(from: types) != nil
        {
            return true
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if bestImagePasteboardType(from: item.types) != nil {
                return true
            }
        }
        return false
    }

    private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let nsURL = item as? NSURL {
            return nsURL as URL
        }
        if let string = item as? String, let url = URL(string: string), url.isFileURL {
            return url
        }
        return nil
    }

    private func deduplicated(_ prepared: [Prepared]) -> [Prepared] {
        var seenPaths: Set<String> = []
        var result: [Prepared] = []
        for entry in prepared {
            let path = entry.url.standardizedFileURL.path
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            result.append(entry)
        }
        return result
    }
}
