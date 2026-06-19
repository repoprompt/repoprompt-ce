//
//  AgentInputBar.swift
//  RepoPrompt
//
//  Input bar for Agent Mode with shared send/cancel controls.
//  Uses ComposerChrome for the floating bubble container.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentComposerActions {
    let storeDraft: (_ tabID: UUID, _ text: String) -> Void
    let retrieveDraft: (_ tabID: UUID) -> String
    let claimSubmit: (_ attempt: AgentComposerSubmitAttempt) -> AgentModeViewModel.AgentComposerSubmitClaimResult
    let executeSubmit: (_ claim: AgentModeViewModel.AgentComposerSubmitClaim, _ text: String) async -> AgentModeViewModel.UserTurnSubmissionResult
    let cancelRun: (_ target: AgentRunCancelTarget) async -> Void
    let attachImages: (_ tabID: UUID, _ urls: [URL]) -> Void
    let removeImage: (_ tabID: UUID, _ attachmentID: UUID) -> Void
    let commitTaggedFile: (_ tabID: UUID, _ suggestion: MentionSuggestion, _ displayName: String) -> Void
    let removeTaggedFile: (_ tabID: UUID, _ attachmentID: UUID) -> Void
    let agentWorkspaceLookupContext: (_ tabID: UUID?) async -> WorkspaceLookupContext
    let slashSkillSuggestions: (_ query: String) async -> [MentionSuggestion]
    let modelOptions: (_ agent: AgentProviderKind, _ includeClaudeEffortVariants: Bool) -> [AgentModelOption]
    let canSelectAgentInCurrentChat: (_ agent: AgentProviderKind) -> Bool
    let selectAgentModel: (_ agent: AgentProviderKind, _ rawModel: String) -> Void
    let reasoningEffortOptionsForCurrentSelection: () -> [CodexReasoningEffort]
    let selectReasoningEffort: (_ effort: CodexReasoningEffort?) -> Void
    let setAutoEditEnabled: (_ enabled: Bool) -> Void
    let setProviderPermissionLevel: (_ id: AgentProviderPermissionLevelID) -> Void
    let setCodexBashToolEnabled: (_ enabled: Bool) -> Void
    let setCodexSearchToolEnabled: (_ enabled: Bool) -> Void
    let setCodexGoalSupportEnabled: (_ enabled: Bool) -> Void
    let setCodexMCPServerEnabled: (_ normalizedName: String, _ enabled: Bool) -> Void
    let setClaudeBashToolEnabled: (_ enabled: Bool) -> Void
    let setClaudeMCPStrictModeEnabled: (_ enabled: Bool) -> Void
    let setClaudeToolSearchEnabled: (_ enabled: Bool) -> Void
    let setClaudeEffortLevel: (_ level: ClaudeCodeEffortLevel) -> Void
    let setClaudeAgentModePromptDelivery: (_ delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery) -> Void
    let openCLIProvidersSettings: () -> Void
}

struct AgentInputBar: View {
    let agentModeVM: AgentModeViewModel
    @ObservedObject var composerUI: AgentComposerUIStore
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
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
            let _ = AgentModePerfDiagnostics.increment("ui.body.inputBar")
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
        AgentComposerActions(
            storeDraft: { tabID, text in agentModeVM.storeDraftText(for: tabID, text) },
            retrieveDraft: { tabID in agentModeVM.retrieveDraftText(for: tabID) },
            claimSubmit: { attempt in agentModeVM.claimComposerSubmitAttempt(attempt) },
            executeSubmit: { claim, text in
                await agentModeVM.executeComposerSubmitAttempt(text: text, claim: claim)
            },
            cancelRun: { target in _ = await agentModeVM.cancelAgentRun(target: target) },
            attachImages: { tabID, urls in agentModeVM.attachImages(tabID: tabID, urls: urls) },
            removeImage: { tabID, attachmentID in agentModeVM.removePendingImage(tabID: tabID, attachmentID: attachmentID) },
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
            setAutoEditEnabled: { enabled in agentModeVM.setAutoEditEnabled(enabled) },
            setProviderPermissionLevel: { id in agentModeVM.setProviderPermissionLevel(id) },
            setCodexBashToolEnabled: { enabled in agentModeVM.setCodexBashToolEnabled(enabled) },
            setCodexSearchToolEnabled: { enabled in agentModeVM.setCodexSearchToolEnabled(enabled) },
            setCodexGoalSupportEnabled: { enabled in agentModeVM.setCodexGoalSupportEnabled(enabled) },
            setCodexMCPServerEnabled: { normalizedName, enabled in agentModeVM.setCodexMCPServerEnabled(normalizedName: normalizedName, enabled: enabled) },
            setClaudeBashToolEnabled: { enabled in agentModeVM.setClaudeBashToolEnabled(enabled) },
            setClaudeMCPStrictModeEnabled: { enabled in agentModeVM.setClaudeMCPStrictModeEnabled(enabled) },
            setClaudeToolSearchEnabled: { enabled in agentModeVM.setClaudeToolSearchEnabled(enabled) },
            setClaudeEffortLevel: { level in agentModeVM.setClaudeEffortLevel(level) },
            setClaudeAgentModePromptDelivery: { delivery in agentModeVM.setClaudeAgentModePromptDelivery(delivery) },
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
            let _ = AgentModePerfDiagnostics.increment("ui.body.inputBar.statusPills")
        #endif
        AgentStatusPillsRow(
            agentModeVM: agentModeVM,
            statusPillsUI: statusPillsUI,
            oracleViewModel: oracleViewModel,
            promptManager: promptManager,
            selectionCoordinator: selectionCoordinator,
            runtimeVM: runtimeVM,
            windowID: windowID
        )
        .padding(.horizontal, 28)
    }
}

enum AgentFileMentionText {
    static func attachmentDisplayName(for suggestion: MentionSuggestion) -> String {
        if let commitDisplayText = suggestion.commitDisplayText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !commitDisplayText.isEmpty
        {
            return commitDisplayText
        }

        let normalizedPath = suggestion.relativePath.replacingOccurrences(of: "\\", with: "/")
        if let fileName = normalizedPath.split(separator: "/").last {
            let value = String(fileName).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return suggestion.displayName
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
    let props: AgentComposerProps
    let placeholderText: String
    let actions: AgentComposerActions
    let promptManager: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let windowID: Int
    let currentTabID: UUID?

    @Binding var resetTextFieldTrigger: Bool
    @Binding var composerBottomInset: CGFloat
    @Binding var transcriptBottomClearance: CGFloat

    @FocusState var isFocused: Bool

    @State private var localInputText: String = ""
    @State private var submissionLatch = AgentComposerSubmissionLatch()
    @State private var editorTextFieldHeight: CGFloat = ResizableTextField.height(forPresetIndex: 0, preset: .normal)
    @State private var isInputEmpty: Bool = true
    @State private var chromeOcclusion: CGFloat = 0
    @State private var isSyncingDraftFromSession: Bool = false
    @State private var isImageDropTargeted: Bool = false
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

    private let imageInputAdapter = AgentImageInputAdapter()
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

    private var hasPendingImageAttachments: Bool {
        props.attachments.hasImages
    }

    private var hasPendingTaggedFileAttachments: Bool {
        props.attachments.hasTaggedFiles
    }

    private var hasPendingAttachments: Bool {
        hasPendingImageAttachments || hasPendingTaggedFileAttachments
    }

    private var isCodexRunActive: Bool {
        props.isCodexRunActive
    }

    private var canUseLinkedAgentSession: Bool {
        props.canUseLinkedAgentSession
    }

    private var canAttachImages: Bool {
        !props.isAgentBusy && currentTabID != nil
    }

    private var renderedSubmitTarget: AgentComposerSubmitTarget? {
        guard let target = props.submitTarget,
              target.tabID == props.currentTabID,
              target.tabID == currentTabID
        else { return nil }
        return target
    }

    private var canSubmitToRenderedTarget: Bool {
        props.canSendWithCurrentProvider
            && renderedSubmitTarget != nil
            && !submissionLatch.isLatched(for: currentTabID)
    }

    private var localInputTextBinding: Binding<String> {
        Binding(
            get: { localInputText },
            set: { setLocalInputText($0) }
        )
    }

    private var isCurrentTabMCPControlled: Bool {
        props.isCurrentTabMCPControlled
    }

    private var modelControlsDisabled: Bool {
        props.areModelControlsDisabled
    }

    private var modelControlsDisabledTooltip: String {
        "Model and effort controls are locked while this session is controlled by an MCP agent."
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
            hasImages: hasPendingImageAttachments,
            hasTaggedFiles: hasPendingTaggedFileAttachments
        ) + steeringUnsupportedInfoBoxReservedHeight
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
            let _ = AgentModePerfDiagnostics.increment("ui.body.composer")
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
            if let tabID = currentTabID {
                actions.storeDraft(tabID, localInputText)
            }
            steeringUnsupportedDismissTask?.cancel()
            steeringUnsupportedDismissTask = nil
            modelMenuSnapshotReleaseTask?.cancel()
            modelMenuSnapshotReleaseTask = nil
            modelMenuSnapshotByAgent = nil
        }
        .onChange(of: currentTabID) { oldTabID, newTabID in
            // Switch drafts when tab changes
            if let oldTabID {
                actions.storeDraft(oldTabID, localInputText)
            }
            if let newTabID {
                loadDraftFromSession(for: newTabID)
            }
        }
        .onChange(of: localInputText) { _, newValue in
            isInputEmpty = newValue.isEmpty
            guard let tabID = currentTabID, !isSyncingDraftFromSession else { return }
            actions.storeDraft(tabID, newValue)
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
            }
            setLocalInputText(restoredText, forceRevision: true)
            actions.storeDraft(event.tabID, restoredText)
            DispatchQueue.main.async {
                isSyncingDraftFromSession = false
            }
            if !event.message.isEmpty {
                showSteeringUnsupportedNotice(event.message)
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isImageDropTargeted, perform: handleImageDrop(providers:))
        .overlay(imageDropOutline)
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
            if hasSteeringUnsupportedNotice {
                steeringUnsupportedInfoBox
            }

            if hasPendingAttachments {
                AgentAttachmentsStrip(
                    snapshot: props.attachments,
                    allowsRemoval: true,
                    onRemoveImage: removeImageAttachment,
                    onRemoveTaggedFile: removeTaggedFileAttachment
                )
                .equatable()
            }

            ResizableTextField(
                text: localInputTextBinding,
                placeholder: placeholderText,
                onReturn: sendMessage,
                resetTrigger: $resetTextFieldTrigger,
                onImagePaste: handleImagePaste(pasteboard:),
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
                        agentProviderModelPicker
                        reasoningEffortPicker
                        claudeEffortPicker
                        codexToolsButton
                        claudeToolsButton
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

            // Right side: Attach + Context indicator + Send/Cancel button
            HStack(spacing: 8) {
                Button(action: pickImages) {
                    Image(systemName: "photo.badge.plus")
                        .foregroundColor(canAttachImages ? .secondary : .gray)
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canAttachImages)
                .hoverTooltip("Attach Images")
                .transaction { transaction in
                    transaction.animation = nil
                }

                if let cancelTarget = props.cancelTarget {
                    CancelButton(action: { cancelRun(cancelTarget) })
                } else {
                    SendOrResendButton(
                        inputText: localInputText,
                        hasMessages: false, // Disable resend in agent mode - just show greyed send button
                        sendWhenEmpty: hasPendingAttachments,
                        sendTooltip: "Send Message",
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

    private var isSelectedCodexFastModel: Bool {
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
        guard isSelectedCodexFastModel else { return baseTooltip }
        return "\(baseTooltip)\n\(AgentModelSelectionWarningVisuals.warningTooltip)"
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
                if isSelectedCodexFastModel {
                    Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                        .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
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
            .foregroundColor(isSelectedCodexFastModel ? .orange : .primary)
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
        if props.selectedAgent == .codexExec {
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
                HStack(spacing: 4) {
                    Text(props.selectedReasoningEffortDisplayName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pickerChipColor)
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .disabled(efforts.isEmpty || modelControlsDisabled)
            .opacity(modelControlsDisabled ? 0.55 : 1.0)
            .hoverTooltip(modelControlsDisabled ? modelControlsDisabledTooltip : "Codex reasoning effort")
            .fixedSize()
        }
    }

    @ViewBuilder
    private var claudeEffortPicker: some View {
        if props.selectedAgent.usesClaudeTooling,
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
                HStack(spacing: 4) {
                    Text(claudeTools.effortLevel.displayName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pickerChipColor)
                .cornerRadius(4)
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
                            actions.setCodexBashToolEnabled(newValue)
                        }
                    ))

                    Toggle("Search", isOn: Binding(
                        get: { codexTools.searchToolEnabled },
                        set: { newValue in
                            actions.setCodexSearchToolEnabled(newValue)
                        }
                    ))

                    Toggle("Goals", isOn: Binding(
                        get: { codexTools.goalSupportEnabled },
                        set: { newValue in
                            actions.setCodexGoalSupportEnabled(newValue)
                        }
                    ))
                    .hoverTooltip("Codex /goal support is enabled by default. Turn this off to stop RepoPrompt from enabling features.goals for Codex app-server launch and thread config.")
                } header: {
                    Text("Tools")
                }

                Section {
                    if codexTools.mcpServerEntries.isEmpty {
                        Text("No servers in ~/.codex/config.toml")
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
                                        actions.setCodexMCPServerEnabled(entry.normalizedName, newValue)
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
                            actions.setClaudeBashToolEnabled(newValue)
                        }
                    ))
                } header: {
                    Text("Tools")
                }

                Section {
                    Toggle("RepoPrompt Only", isOn: Binding(
                        get: { claudeTools.mcpStrictModeEnabled },
                        set: { newValue in
                            actions.setClaudeMCPStrictModeEnabled(newValue)
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
                            actions.setClaudeToolSearchEnabled(newValue)
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
                            actions.setClaudeAgentModePromptDelivery(newValue)
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

    private var imageDropOutline: some View {
        Group {
            if isImageDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 2)
                    .padding(.bottom, Self.footerHeight)
            }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !submissionLatch.isLatched(for: currentTabID) else {
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
        let rawDraftSnapshot = localInputText
        let trimmed = rawDraftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasPendingAttachments else { return }
        guard let submitTarget = renderedSubmitTarget else {
            logViewSubmitRejection(reason: "view_nil_target", target: props.submitTarget)
            showSteeringUnsupportedNotice(Self.staleSubmitTargetMessage)
            return
        }
        guard let attempt = submissionLatch.begin(
            target: submitTarget,
            rawDraftSnapshot: rawDraftSnapshot
        ) else {
            logViewSubmitRejection(reason: "local_attempt_latched", target: submitTarget)
            return
        }

        actions.storeDraft(attempt.sourceTabID, rawDraftSnapshot)
        switch actions.claimSubmit(attempt) {
        case let .claimed(claim):
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
                    setLocalInputText("")
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
            AgentModePerfDiagnostics.event(
                "agent.composer.submit.rejected",
                tabID: currentTabID,
                fields: [
                    "reason": reason,
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                    "propsTabID": AgentModePerfDiagnostics.shortID(props.currentTabID),
                    "targetTabID": AgentModePerfDiagnostics.shortID(target?.tabID),
                    "attemptID": AgentModePerfDiagnostics.shortID(submissionLatch.activeAttemptID(for: currentTabID)),
                    "inputRevision": String(submissionLatch.inputRevision),
                    "expectedSubmissionToken": AgentModePerfDiagnostics.shortID(target?.expectedSubmissionToken),
                    "expectedSourceAgentSessionID": AgentModePerfDiagnostics.shortID(target?.expectedSourceAgentSessionID),
                    "expectedPersistentBindingGeneration": AgentModePerfDiagnostics.shortID(target?.expectedPersistentBindingIdentity?.generation),
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

    private func pickImages() {
        guard canAttachImages, let tabID = currentTabID else { return }
        Task { @MainActor in
            let targetWindow = WindowStatesManager.shared.allWindows.first { $0.windowID == windowID }?.nsWindow
            let urls = await OpenPanelService.shared.pickImageFiles(
                title: "Choose Images",
                message: "Attach one or more images for the next turn.",
                attachedTo: targetWindow
            )
            actions.attachImages(tabID, urls)
        }
    }

    private func handleFileTagCommitted(_ suggestion: MentionSuggestion) {
        guard let tabID = currentTabID else { return }
        let attachmentDisplayName = AgentFileMentionText.attachmentDisplayName(for: suggestion)
        actions.commitTaggedFile(tabID, suggestion, attachmentDisplayName)
    }

    private func removeImageAttachment(_ attachmentID: UUID) {
        guard let tabID = currentTabID else { return }
        actions.removeImage(tabID, attachmentID)
    }

    private func removeTaggedFileAttachment(_ attachmentID: UUID) {
        guard let tabID = currentTabID else { return }
        let attachment = props.attachments.taggedFileAttachments
            .first(where: { $0.id == attachmentID })
        actions.removeTaggedFile(tabID, attachmentID)
        if let attachment {
            setLocalInputText(
                AgentFileMentionText.removingTaggedMention(
                    displayName: attachment.displayName,
                    relativePath: attachment.relativePath,
                    from: localInputText
                )
            )
        }
    }

    private func handleImageDrop(providers: [NSItemProvider]) -> Bool {
        guard let tabID = currentTabID else {
            return false
        }
        return imageInputAdapter.loadPreparedImages(from: providers) { prepared in
            guard !prepared.isEmpty else { return }
            Task { @MainActor in
                attachPreparedImages(prepared, tabID: tabID)
            }
        }
    }

    private func handleImagePaste(pasteboard: NSPasteboard) -> Bool {
        guard let tabID = currentTabID else {
            return false
        }
        guard imageInputAdapter.shouldConsumePasteAsImageAttachment(from: pasteboard) else {
            return false
        }
        let prepared = imageInputAdapter.preparedImages(from: pasteboard)
        guard !prepared.isEmpty else {
            return false
        }
        attachPreparedImages(prepared, tabID: tabID)
        return true
    }

    private func attachPreparedImages(_ prepared: [AgentImageInputAdapter.PreparedImage], tabID: UUID) {
        let urls = prepared.map(\.url)
        actions.attachImages(tabID, urls)
        imageInputAdapter.cleanupTemporaryFiles(prepared)
    }

    private func normalizedServerToggleKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func setLocalInputText(_ newValue: String, forceRevision: Bool = false) {
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
        setLocalInputText(actions.retrieveDraft(tabID), forceRevision: true)
        DispatchQueue.main.async {
            isSyncingDraftFromSession = false
        }
    }
}

struct AgentImageInputAdapter {
    struct PreparedImage: Equatable {
        let url: URL
        let isTemporary: Bool
    }

    private let fileManager: FileManager
    private let temporaryRoot: URL
    private let preferredImageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .bmp, .tiff]

    private static let maxPlainTextCandidateCharacters = 50000
    private static let maxPlainTextLineCount = 500
    private static let markdownLinkTargetRegex = try! NSRegularExpression(pattern: #"\(([^)\r\n]+)\)"#)
    private static let quotedPathRegex = try! NSRegularExpression(pattern: #"\"([^\"]+)\"|'([^']+)'|`([^`]+)`"#)
    private static let fileURLTokenRegex = try! NSRegularExpression(pattern: #"file://[^\s<>()\[\]{}\"'`]+"#)
    private static let absolutePathTokenRegex = try! NSRegularExpression(pattern: #"(?:^|[\s:=,])((?:~|/)[^\s<>()\[\]{}\"'`]+)"#)
    private static let pathHintTokens = ["file://", "/", "~", ".png", ".jpg", ".jpeg", ".jfif", ".webp", ".avif", ".gif", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".svg"]
    private static let fallbackImageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jfif", "jpe", "gif", "bmp", "webp", "avif", "heic", "heif", "tif", "tiff", "svg", "ico"
    ]

    init(fileManager: FileManager = .default, temporaryRoot: URL? = nil) {
        self.fileManager = fileManager
        self.temporaryRoot = temporaryRoot
            ?? MCPFilesystemConstants.identity.temporaryRootURL(fileManager: fileManager)
            .appendingPathComponent("AgentImageInput", isDirectory: true)
            .standardizedFileURL
    }

    func preparedImages(from pasteboard: NSPasteboard) -> [PreparedImage] {
        let fileURLPrepared = preparedFileURLImages(from: pasteboard, includePlainTextReferences: true)
        if !fileURLPrepared.isEmpty {
            return fileURLPrepared
        }

        var prepared = preparedImageDataRepresentations(from: pasteboard)
        if prepared.isEmpty {
            prepared = preparedNSImageObjects(from: pasteboard)
        }

        return deduplicated(prepared)
    }

    func shouldConsumePasteAsImageAttachment(from pasteboard: NSPasteboard) -> Bool {
        if hasExplicitImagePasteboardType(in: pasteboard) {
            return true
        }
        if shouldConsumeNSImageReadablePasteboard(pasteboard) {
            return true
        }
        if !preparedFileURLImages(from: pasteboard, includePlainTextReferences: false).isEmpty {
            return true
        }
        guard let plainString = pasteboard.string(forType: .string) else {
            return false
        }
        guard !fileURLs(fromPlainText: plainString).isEmpty else {
            return false
        }
        return shouldConsumePlainTextPaste(plainString)
    }

    func loadPreparedImages(
        from providers: [NSItemProvider],
        completion: @escaping ([PreparedImage]) -> Void
    ) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || bestImageTypeIdentifier(from: $0.registeredTypeIdentifiers) != nil
        }
        guard !candidates.isEmpty else {
            return false
        }

        let lockQueue = DispatchQueue(label: "AgentImageInputAdapter.lock")
        let group = DispatchGroup()
        var prepared: [PreparedImage] = []

        for provider in candidates {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let fileURL = droppedFileURL(from: item), isImageFileURL(fileURL) {
                        lockQueue.sync {
                            prepared.append(PreparedImage(url: fileURL.standardizedFileURL, isTemporary: false))
                        }
                        group.leave()
                        return
                    }

                    guard let imageTypeIdentifier = bestImageTypeIdentifier(from: provider.registeredTypeIdentifiers) else {
                        group.leave()
                        return
                    }
                    provider.loadDataRepresentation(forTypeIdentifier: imageTypeIdentifier) { data, _ in
                        defer { group.leave() }
                        guard let data, !data.isEmpty else { return }
                        do {
                            let fileURL = try writeTemporaryImageData(data, typeIdentifier: imageTypeIdentifier)
                            lockQueue.sync {
                                prepared.append(PreparedImage(url: fileURL, isTemporary: true))
                            }
                        } catch {
                            return
                        }
                    }
                }
                continue
            }

            guard let imageTypeIdentifier = bestImageTypeIdentifier(from: provider.registeredTypeIdentifiers) else {
                continue
            }
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: imageTypeIdentifier) { data, _ in
                defer { group.leave() }
                guard let data, !data.isEmpty else { return }
                do {
                    let fileURL = try writeTemporaryImageData(data, typeIdentifier: imageTypeIdentifier)
                    lockQueue.sync {
                        prepared.append(PreparedImage(url: fileURL, isTemporary: true))
                    }
                } catch {
                    return
                }
            }
        }

        group.notify(queue: .main) {
            lockQueue.sync {
                let deduplicatedPrepared = deduplicated(prepared)
                DispatchQueue.main.async {
                    completion(deduplicatedPrepared)
                }
            }
        }
        return true
    }

    func cleanupTemporaryFiles(_ prepared: [PreparedImage]) {
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

    private func preparedImageDataRepresentations(from pasteboard: NSPasteboard) -> [PreparedImage] {
        var prepared: [PreparedImage] = []

        for item in pasteboard.pasteboardItems ?? [] {
            guard let representation = firstImageDataRepresentation(in: item) else { continue }
            do {
                let fileURL = try writeTemporaryImageData(
                    representation.data,
                    typeIdentifier: representation.typeIdentifier
                )
                prepared.append(PreparedImage(url: fileURL, isTemporary: true))
            } catch {
                continue
            }
        }

        if prepared.isEmpty, let representation = firstImageDataRepresentation(in: pasteboard) {
            do {
                let fileURL = try writeTemporaryImageData(
                    representation.data,
                    typeIdentifier: representation.typeIdentifier
                )
                prepared.append(PreparedImage(url: fileURL, isTemporary: true))
            } catch {
                // Ignore fallback conversion errors.
            }
        }

        return prepared
    }

    private func preparedNSImageObjects(from pasteboard: NSPasteboard) -> [PreparedImage] {
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] else {
            return []
        }

        var prepared: [PreparedImage] = []
        for image in images {
            guard let representation = imageDataRepresentation(from: image) else { continue }
            do {
                let fileURL = try writeTemporaryImageData(
                    representation.data,
                    typeIdentifier: representation.typeIdentifier
                )
                prepared.append(PreparedImage(url: fileURL, isTemporary: true))
            } catch {
                continue
            }
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

    private func preparedFileURLImages(
        from pasteboard: NSPasteboard,
        includePlainTextReferences: Bool
    ) -> [PreparedImage] {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []

        for item in pasteboard.pasteboardItems ?? [] {
            if let fileURLString = item.string(forType: .fileURL),
               let fileURL = URL(string: fileURLString),
               fileURL.isFileURL
            {
                urls.append(fileURL)
            } else if let fileURLData = item.data(forType: .fileURL),
                      let fileURL = URL(dataRepresentation: fileURLData, relativeTo: nil),
                      fileURL.isFileURL
            {
                urls.append(fileURL)
            }

            if includePlainTextReferences, let plainString = item.string(forType: .string) {
                urls.append(contentsOf: fileURLs(fromPlainText: plainString))
            }
        }

        if includePlainTextReferences, let plainString = pasteboard.string(forType: .string) {
            urls.append(contentsOf: fileURLs(fromPlainText: plainString))
        }

        let prepared = urls
            .map(\.standardizedFileURL)
            .filter { $0.isFileURL && fileManager.fileExists(atPath: $0.path) && isImageFileURL($0) }
            .map { PreparedImage(url: $0, isTemporary: false) }
        return deduplicated(prepared)
    }

    private func fileURLs(fromPlainText text: String) -> [URL] {
        let cappedText = text.count > Self.maxPlainTextCandidateCharacters
            ? String(text.prefix(Self.maxPlainTextCandidateCharacters))
            : text
        var results: [URL] = []
        var seenPaths: Set<String> = []
        var processedLineCount = 0
        cappedText.enumerateLines { line, stop in
            if processedLineCount >= Self.maxPlainTextLineCount {
                stop = true
                return
            }
            processedLineCount += 1
            guard lineLikelyContainsPathReference(line) else { return }
            for candidate in fileReferenceCandidates(in: line) {
                guard let fileURL = fileURLFromPlainText(candidate) else { continue }
                let standardizedURL = fileURL.standardizedFileURL
                let key = standardizedURL.path
                guard !key.isEmpty else { continue }
                guard !seenPaths.contains(key) else { continue }
                seenPaths.insert(key)
                results.append(standardizedURL)
            }
        }
        return results
    }

    private func shouldConsumeNSImageReadablePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) else {
            return false
        }
        guard let plainString = pasteboard.string(forType: .string) else {
            return true
        }
        let trimmed = plainString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }
        guard !fileURLs(fromPlainText: plainString).isEmpty else {
            return false
        }
        return shouldConsumePlainTextPaste(plainString)
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

    private func shouldConsumePlainTextPaste(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let cappedText = trimmed.count > Self.maxPlainTextCandidateCharacters
            ? String(trimmed.prefix(Self.maxPlainTextCandidateCharacters))
            : trimmed
        let lines = cappedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        guard lines.count <= Self.maxPlainTextLineCount else { return false }
        return lines.allSatisfy { lineLooksLikeStandaloneImageReference($0) }
    }

    private func lineLooksLikeStandaloneImageReference(_ line: String) -> Bool {
        if fileURLFromPlainText(line) != nil {
            return true
        }
        if let markdownTarget = firstMarkdownImageTarget(in: line),
           fileURLFromPlainText(markdownTarget) != nil
        {
            return true
        }
        return false
    }

    private func firstMarkdownImageTarget(in line: String) -> String? {
        markdownImageTargets(in: line, requireStandaloneLine: true).first
    }

    private func markdownImageTargets(in line: String, requireStandaloneLine: Bool = false) -> [String] {
        let characters = Array(line)
        guard !characters.isEmpty else { return [] }

        var targets: [String] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "!", index + 1 < characters.count, characters[index + 1] == "[" else {
                index += 1
                continue
            }

            let imageStart = index
            guard let altEnd = findClosingBracket(in: characters, startingAt: index + 1) else {
                index += 2
                continue
            }
            guard altEnd + 1 < characters.count, characters[altEnd + 1] == "(" else {
                index = altEnd + 1
                continue
            }

            guard let parsed = parseMarkdownLinkTarget(in: characters, openingParenIndex: altEnd + 1) else {
                index = altEnd + 2
                continue
            }

            if requireStandaloneLine {
                let prefix = String(characters[..<imageStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = String(characters[(parsed.closingParenIndex + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty || !suffix.isEmpty {
                    index = parsed.closingParenIndex + 1
                    continue
                }
            }

            targets.append(parsed.target)
            index = parsed.closingParenIndex + 1
        }

        return targets
    }

    private func findClosingBracket(in characters: [Character], startingAt openingBracketIndex: Int) -> Int? {
        guard openingBracketIndex < characters.count, characters[openingBracketIndex] == "[" else {
            return nil
        }
        var index = openingBracketIndex + 1
        var isEscaping = false
        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                isEscaping = false
                index += 1
                continue
            }
            if character == "\\" {
                isEscaping = true
                index += 1
                continue
            }
            if character == "]" {
                return index
            }
            index += 1
        }
        return nil
    }

    private func parseMarkdownLinkTarget(
        in characters: [Character],
        openingParenIndex: Int
    ) -> (target: String, closingParenIndex: Int)? {
        guard openingParenIndex < characters.count, characters[openingParenIndex] == "(" else {
            return nil
        }
        var depth = 1
        var index = openingParenIndex + 1
        var target = ""
        var isEscaping = false
        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                target.append(character)
                isEscaping = false
                index += 1
                continue
            }
            if character == "\\" {
                isEscaping = true
                index += 1
                continue
            }
            if character == "(" {
                depth += 1
                target.append(character)
                index += 1
                continue
            }
            if character == ")" {
                depth -= 1
                if depth == 0 {
                    return (
                        target.trimmingCharacters(in: .whitespacesAndNewlines),
                        index
                    )
                }
                target.append(character)
                index += 1
                continue
            }
            target.append(character)
            index += 1
        }
        return nil
    }

    private func lineLikelyContainsPathReference(_ line: String) -> Bool {
        let lower = line.lowercased()
        for token in Self.pathHintTokens where lower.contains(token) {
            return true
        }
        return false
    }

    private func fileReferenceCandidates(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates = [trimmed]
        candidates.append(contentsOf: markdownImageTargets(in: line))
        appendMatches(regex: Self.markdownLinkTargetRegex, in: line, captureGroup: 1, into: &candidates)
        appendMatches(regex: Self.quotedPathRegex, in: line, captureGroup: 1, into: &candidates)
        appendMatches(regex: Self.quotedPathRegex, in: line, captureGroup: 2, into: &candidates)
        appendMatches(regex: Self.quotedPathRegex, in: line, captureGroup: 3, into: &candidates)
        appendMatches(regex: Self.fileURLTokenRegex, in: line, into: &candidates)
        appendMatches(regex: Self.absolutePathTokenRegex, in: line, captureGroup: 1, into: &candidates)
        return candidates
    }

    private func appendMatches(
        regex: NSRegularExpression,
        in text: String,
        captureGroup: Int? = nil,
        into candidates: inout [String]
    ) {
        let nsText = text as NSString
        let searchRange = NSRange(location: 0, length: nsText.length)
        regex.enumerateMatches(in: text, options: [], range: searchRange) { match, _, _ in
            guard let match else { return }
            let range: NSRange
            if let captureGroup {
                guard match.numberOfRanges > captureGroup else { return }
                range = match.range(at: captureGroup)
            } else {
                range = match.range
            }
            guard range.location != NSNotFound, range.length > 0 else { return }
            candidates.append(nsText.substring(with: range))
        }
    }

    private func fileURLFromPlainText(_ rawText: String) -> URL? {
        let normalized = normalizedPlainTextCandidate(rawText)
        guard !normalized.isEmpty else { return nil }
        let unescaped = unescapePathEscapes(in: normalized)

        if let fileURL = URL(string: unescaped), fileURL.isFileURL {
            return fileURL
        }

        if unescaped.hasPrefix("file://") {
            var pathPart = String(unescaped.dropFirst("file://".count))
            if pathPart.hasPrefix("localhost/") {
                pathPart = String(pathPart.dropFirst("localhost/".count))
            }
            if !pathPart.hasPrefix("/") {
                pathPart = "/" + pathPart
            }
            let decodedPath = pathPart.removingPercentEncoding ?? pathPart
            return URL(fileURLWithPath: decodedPath)
        }

        if unescaped.hasPrefix("file:/") {
            let normalized = "file://" + String(unescaped.dropFirst("file:/".count))
            if let fileURL = URL(string: normalized), fileURL.isFileURL {
                return fileURL
            }
        }

        guard unescaped.hasPrefix("/") || unescaped.hasPrefix("~") else { return nil }
        let expandedPath = (unescaped as NSString).expandingTildeInPath
        let decodedPath = expandedPath.removingPercentEncoding ?? expandedPath
        return URL(fileURLWithPath: decodedPath)
    }

    private func normalizedPlainTextCandidate(_ rawText: String) -> String {
        var value = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        while let first = value.first, "<[({".contains(first) {
            value.removeFirst()
        }
        while let last = value.last, ">)]},.;:!?".contains(last) {
            value.removeLast()
        }

        if value.count > 1,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
           || (value.hasPrefix("'") && value.hasSuffix("'"))
           || (value.hasPrefix("`") && value.hasSuffix("`"))
        {
            value.removeFirst()
            value.removeLast()
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unescapePathEscapes(in value: String) -> String {
        guard value.contains("\\") else { return value }
        let escapable: Set<Character> = [" ", "(", ")", "[", "]", "{", "}", "!", "?", ",", ";", "\"", "'", "`"]
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "\\" {
                let nextIndex = value.index(after: index)
                if nextIndex < value.endIndex {
                    let next = value[nextIndex]
                    if escapable.contains(next) {
                        output.append(next)
                    } else {
                        output.append("\\")
                        output.append(next)
                    }
                    index = value.index(after: nextIndex)
                    continue
                }
            }
            output.append(character)
            index = value.index(after: index)
        }
        return output
    }

    private func isImageFileURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .image) {
                return true
            }
        }

        let rawExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawExtension.isEmpty else { return false }
        let normalizedExtension = rawExtension.lowercased()
        if let type = UTType(filenameExtension: normalizedExtension) {
            if type.conforms(to: .image) {
                return true
            }
        }
        return Self.fallbackImageFileExtensions.contains(normalizedExtension)
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

    private func deduplicated(_ prepared: [PreparedImage]) -> [PreparedImage] {
        var seenPaths: Set<String> = []
        var result: [PreparedImage] = []
        for entry in prepared {
            let path = entry.url.standardizedFileURL.path
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            result.append(entry)
        }
        return result
    }
}
