import AppKit
import SwiftUI

// MARK: - Oracle Pill

enum AgentOraclePillLogic {
    struct ExplicitOpenRequest: Equatable {
        let generation: UInt64
        let workspaceID: UUID
        let tabID: UUID
        let chatID: String
        let presentation: AgentOraclePopoverPresentation
    }

    static func explicitOpenRequest(
        chatID rawChatID: String,
        workspaceID: UUID,
        tabID: UUID,
        generation: UInt64,
        presentation: AgentOraclePopoverPresentation = .standard
    ) -> ExplicitOpenRequest? {
        let chatID = rawChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatID.isEmpty else { return nil }
        return ExplicitOpenRequest(
            generation: generation,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: chatID,
            presentation: presentation
        )
    }

    static func transcriptActionPolicy(
        for presentation: AgentOraclePopoverPresentation
    ) -> ChatTranscriptActionPolicy {
        switch presentation {
        case .standard:
            .standard
        case .generatedAnswerReadOnly:
            .nonMutating
        }
    }

    static func shouldPresent(
        session: ChatSession,
        for request: ExplicitOpenRequest,
        currentGeneration: UInt64,
        currentWorkspaceID: UUID?,
        currentTabID: UUID?
    ) -> Bool {
        guard request.generation == currentGeneration,
              request.workspaceID == currentWorkspaceID,
              request.tabID == currentTabID,
              session.workspaceID == request.workspaceID,
              session.composeTabID == request.tabID else { return false }
        return Self.session(matchingChatID: request.chatID, in: [session]) != nil
    }

    static func hasRenderableMessages(session: ChatSession, liveMessageCount: Int?) -> Bool {
        if let liveMessageCount {
            return liveMessageCount > 0
        }
        return session.hasMessages
    }

    static func eligibleSessions(
        sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>,
        liveMessageCount: (UUID) -> Int?,
        activeAgentSessionID: UUID? = nil,
        activeRunID: UUID? = nil
    ) -> [ChatSession] {
        let renderable = sessions.filter { session in
            hasRenderableMessages(session: session, liveMessageCount: liveMessageCount(session.id))
                || streamingSessionIDs.contains(session.id)
        }
        guard activeAgentSessionID != nil || activeRunID != nil else { return renderable }

        func isUnownedLegacy(_ session: ChatSession) -> Bool {
            session.agentModeSessionID == nil && session.agentModeRunID == nil
        }
        func matchesAgent(_ session: ChatSession) -> Bool {
            guard let activeAgentSessionID else { return true }
            return session.agentModeSessionID == activeAgentSessionID
        }

        if let activeRunID {
            let exactRunMatches = renderable.filter { matchesAgent($0) && $0.agentModeRunID == activeRunID }
            if !exactRunMatches.isEmpty { return exactRunMatches }

            let sameAgentLegacyRunMatches = renderable.filter { matchesAgent($0) && $0.agentModeSessionID != nil && $0.agentModeRunID == nil }
            if !sameAgentLegacyRunMatches.isEmpty { return sameAgentLegacyRunMatches }

            if let activeAgentSessionID,
               renderable.contains(where: { $0.agentModeSessionID == activeAgentSessionID })
            {
                return []
            }
            return renderable.filter(isUnownedLegacy)
        }

        if let activeAgentSessionID {
            let sameAgentMatches = renderable.filter { $0.agentModeSessionID == activeAgentSessionID }
            if !sameAgentMatches.isEmpty { return sameAgentMatches }
        }

        return renderable.filter(isUnownedLegacy)
    }

    static func latestSession(
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> ChatSession? {
        guard let latest = latestStreamingSession(in: sessions, streamingSessionIDs: streamingSessionIDs)
            ?? sessions.max(by: { $0.savedAt < $1.savedAt })
        else { return nil }
        guard let groupID = latest.oracleGroupID else { return latest }
        return sessions.first(where: {
            $0.oracleGroupID == groupID && $0.oracleLaneIndex == 0
        }) ?? latest
    }

    static func canCopyAll(_ session: ChatSession) -> Bool {
        session.oracleGroupID != nil && (session.oracleGroupSize ?? 1) > 1
    }

    static func aggregateOracleCount(configuredAdditionalCount: Int, sessions: [ChatSession]) -> Int {
        let configured = 1 + configuredAdditionalCount
        guard let latest = sessions.max(by: { $0.savedAt < $1.savedAt }),
              latest.oracleGroupID != nil
        else { return configured }
        let projected = min(max(latest.oracleGroupSize ?? 1, 1), 5)
        return max(configured, projected)
    }

    static func latestStreamingSession(
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> ChatSession? {
        sessions
            .filter { streamingSessionIDs.contains($0.id) }
            .max(by: { $0.savedAt < $1.savedAt })
    }

    static func selectedSessionID(
        currentSelectionID: UUID?,
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> UUID? {
        if let currentSelectionID,
           sessions.contains(where: { $0.id == currentSelectionID })
        {
            return currentSelectionID
        }
        return latestSession(in: sessions, streamingSessionIDs: streamingSessionIDs)?.id
    }

    static func reconciledPresentedSessionID(
        currentSessionID: UUID?,
        isExplicit: Bool,
        currentWorkspaceID: UUID?,
        sameTabSessions: [ChatSession],
        eligibleSessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> UUID? {
        let sameWorkspaceSessions = sameTabSessions.filter { $0.workspaceID == currentWorkspaceID }
        let sameWorkspaceEligibleSessions = eligibleSessions.filter { $0.workspaceID == currentWorkspaceID }
        if isExplicit {
            guard let currentSessionID,
                  sameWorkspaceSessions.contains(where: { $0.id == currentSessionID })
            else {
                return nil
            }
            return currentSessionID
        }

        if let currentSessionID,
           sameWorkspaceEligibleSessions.contains(where: { $0.id == currentSessionID })
        {
            return currentSessionID
        }
        return latestSession(in: sameWorkspaceEligibleSessions, streamingSessionIDs: streamingSessionIDs)?.id
    }

    static func session(matchingChatID raw: String, in sessions: [ChatSession]) -> ChatSession? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let targetUUID = UUID(uuidString: trimmed)
        let matches = sessions.filter { session in
            if let targetUUID {
                return session.id == targetUUID
            }
            return session.shortID == trimmed
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    enum LaneDotState: Equatable {
        case streaming
        case failed
        case completed
    }

    static func lastAssistantContent(
        liveMessages: [AIChatMessage],
        storedMessages: [StoredMessage]
    ) -> String? {
        if let last = liveMessages.last(where: { !$0.isUser }) {
            return last.content
        }
        return storedMessages.last(where: { !$0.isUser })?.rawText
    }

    static func assistantContentIndicatesFailure(_ content: String?) -> Bool {
        guard let content else { return false }
        if content.contains("\n--\nError:\n") { return true }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("Error:")
    }

    static func laneDotState(isStreaming: Bool, lastAssistantContent: String?) -> LaneDotState {
        if isStreaming { return .streaming }
        if assistantContentIndicatesFailure(lastAssistantContent) { return .failed }
        return .completed
    }
}

/// Pill that appears when there are oracle chat sessions for the current tab.
/// More prominent when streaming. Clicking opens a wide popover with chat transcript.
struct AgentOraclePill: View {
    @ObservedObject var oracleViewModel: OracleViewModel
    let windowID: Int
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let activeRunID: UUID?

    private struct PopoverPresentation: Identifiable {
        /// Identifies the open request; bump the generation whenever the session or policy changes
        let id: UInt64
        let sessionID: UUID
        let isExplicit: Bool
        let actionPolicy: ChatTranscriptActionPolicy
    }

    private enum CopyAllFeedback: String {
        case copying = "Copying…"
        case copied = "Copied!"
        case failed = "Copy Failed"
    }

    @State private var presentedPopover: PopoverPresentation?
    @State private var copyAllFeedback: CopyAllFeedback?
    @State private var autoScrollEnabled = false
    @State private var openRequestGeneration: UInt64 = 0
    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var settingsStore = GlobalSettingsStore.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var eligibleTabSessions: [ChatSession] {
        guard let tabID = currentTabID else { return [] }
        return AgentOraclePillLogic.eligibleSessions(
            sessions: oracleViewModel.sessions(forTabID: tabID),
            streamingSessionIDs: oracleViewModel.streamingSessions,
            liveMessageCount: { oracleViewModel.liveMessageCount(for: $0) },
            activeAgentSessionID: activeAgentSessionID,
            activeRunID: activeRunID
        )
    }

    private var latestTabSession: ChatSession? {
        AgentOraclePillLogic.latestSession(
            in: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
    }

    private var currentTabSessions: [ChatSession] {
        currentTabID.map(oracleViewModel.sessions(forTabID:)) ?? []
    }

    private var oracleCount: Int {
        let workspaceID = oracleViewModel.workspaceManager.activeWorkspaceID
        let configuredAdditional = settingsStore
            .effectiveAgentModelsProfile(workspaceID: workspaceID)
            .additionalOracleModelRaws.count
        return AgentOraclePillLogic.aggregateOracleCount(
            configuredAdditionalCount: configuredAdditional,
            sessions: currentTabSessions
        )
    }

    private var isStreaming: Bool {
        guard let latestTabSession else { return false }
        if let groupID = latestTabSession.oracleGroupID {
            return currentTabSessions.contains {
                $0.oracleGroupID == groupID && oracleViewModel.streamingSessions.contains($0.id)
            }
        }
        return oracleViewModel.streamingSessions.contains(latestTabSession.id)
    }

    private func presentedSession(for presentation: PopoverPresentation) -> ChatSession? {
        guard let tabID = currentTabID else { return nil }
        return oracleViewModel.sessions(forTabID: tabID).first { $0.id == presentation.sessionID }
    }

    private func isPresentedSessionStreaming(_ presentation: PopoverPresentation) -> Bool {
        oracleViewModel.streamingSessions.contains(presentation.sessionID)
    }

    private func popoverSubtitle(_ presentation: PopoverPresentation) -> String {
        guard let session = presentedSession(for: presentation) else { return "Latest tab chat" }
        if session.id == latestTabSession?.id {
            return "Latest tab chat"
        }
        return session.name
    }

    private func laneDotColor(for session: ChatSession) -> Color {
        switch AgentOraclePillLogic.laneDotState(
            isStreaming: oracleViewModel.streamingSessions.contains(session.id),
            lastAssistantContent: AgentOraclePillLogic.lastAssistantContent(
                liveMessages: oracleViewModel.messagesSnapshot(for: session.id),
                storedMessages: session.messages
            )
        ) {
        case .streaming: Color.purple
        case .failed: Color.red
        case .completed: Color.green
        }
    }

    private var hasAnySessions: Bool {
        latestTabSession != nil
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.oracle")
        #endif
        Group {
            if hasAnySessions {
                let cornerRadius = AgentPillMetrics.cornerRadius()
                Button {
                    openPopover(chatID: nil)
                } label: {
                    HStack(spacing: 6) {
                        if isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "brain")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                                .foregroundStyle(.secondary)
                        }
                        Text(oracleCount > 1 ? "Oracles · \(oracleCount)" : "Oracle")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: isStreaming ? .semibold : .medium))
                            .foregroundStyle(isStreaming ? .primary : .secondary)
                    }
                    .padding(.horizontal, AgentPillMetrics.horizontalPadding())
                    .frame(height: AgentPillMetrics.height())
                    .background(isStreaming ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.ultraThinMaterial))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(isStreaming ? Color.purple.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: isStreaming ? 1 : 0.5)
                    )
                    .shadow(color: isStreaming ? Color.purple.opacity(0.15) : .clear, radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .hoverTooltip(
                    oracleCount > 1
                        ? (isStreaming ? "Oracles are thinking — click to view progress" : "Open Oracle chats for this tab")
                        : (isStreaming ? "Oracle is thinking — click to view the live chat" : "Open the latest Oracle chat for this tab"),
                    .top
                )
                .animation(.easeInOut(duration: 0.2), value: isStreaming)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentOraclePopover)) { note in
            if let route = AgentOraclePopoverRoute(notificationUserInfo: note.userInfo) {
                guard route.windowID == windowID,
                      route.tabID == currentTabID,
                      route.workspaceID == oracleViewModel.workspaceManager.activeWorkspaceID
                else { return }
                openPopover(
                    chatID: route.chatID,
                    workspaceID: route.workspaceID,
                    presentation: route.presentation
                )
                return
            }
            guard let route = AgentOracleLatestPopoverRoute(notificationUserInfo: note.userInfo),
                  route.windowID == windowID,
                  route.tabID == currentTabID,
                  route.workspaceID == oracleViewModel.workspaceManager.activeWorkspaceID
            else { return }
            openLatestStreamingPopover()
        }
        .popover(item: $presentedPopover, arrowEdge: .bottom) { presentation in
            oraclePopoverContent(presentation)
        }
        .onChange(of: currentTabID) { _, _ in
            openRequestGeneration &+= 1
            reconcilePresentedSession()
        }
        .onReceive(oracleViewModel.workspaceManager.$activeWorkspaceID) { _ in
            openRequestGeneration &+= 1
            if presentedPopover?.isExplicit == true {
                presentedPopover = nil
            } else {
                reconcilePresentedSession()
            }
        }
        .onChange(of: activeAgentSessionID) { _, _ in
            reconcilePresentedSession()
        }
        .onChange(of: activeRunID) { _, _ in
            reconcilePresentedSession()
        }
    }

    private func groupMemberSessions(for session: ChatSession) -> [ChatSession] {
        guard let groupID = session.oracleGroupID else { return [] }
        return currentTabSessions
            .filter { $0.oracleGroupID == groupID }
            .sorted { ($0.oracleLaneIndex ?? .max) < ($1.oracleLaneIndex ?? .max) }
    }

    @ViewBuilder
    private func oraclePopoverContent(_ presentation: PopoverPresentation) -> some View {
        // Popover dimensions scale so chat messages don't feel cramped at
        // Larger/Extra Large. Width gets a tighter cap than height because the
        // popover is anchored to the composer and we don't want it to spill
        // beyond the window edges; the chat transcript area takes the rest.
        let popoverWidth = fontPreset.scaledClamped(800, max: 1040)
        let transcriptMinHeight = fontPreset.scaledClamped(350, max: 460)
        let transcriptIdealHeight = fontPreset.scaledClamped(500, max: 660)
        let transcriptMaxHeight = fontPreset.scaledClamped(600, max: 780)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Oracle")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                if isPresentedSessionStreaming(presentation) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Spacer()
                Text(popoverSubtitle(presentation))
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let session = presentedSession(for: presentation),
                   AgentOraclePillLogic.canCopyAll(session)
                {
                    Button(copyAllFeedback?.rawValue ?? "Copy All") {
                        copyAllLanes(containing: session)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(copyAllFeedback == .copying)
                }
            }

            if let presented = presentedSession(for: presentation) {
                let members = groupMemberSessions(for: presented)
                if members.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(members) { member in
                            let laneIndex = member.oracleLaneIndex ?? 0
                            Button {
                                openRequestGeneration &+= 1
                                present(
                                    sessionID: member.id,
                                    isExplicit: presentation.isExplicit,
                                    actionPolicy: presentation.actionPolicy,
                                    generation: openRequestGeneration
                                )
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(laneDotColor(for: member))
                                        .frame(width: 6, height: 6)
                                    Text(OracleViewModel.oracleLabel(laneIndex: laneIndex))
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .hoverTooltip(member.oracleModelRaw ?? "Oracle model")
                        }
                    }
                }
            }

            ChatMessagesView(
                viewModel: oracleViewModel,
                autoScrollEnabled: $autoScrollEnabled,
                bottomOcclusion: 0,
                showsScrollControls: true,
                autoScrollOnAppear: true,
                sessionIDOverride: presentation.sessionID,
                actionPolicy: presentation.actionPolicy
            )
            .frame(minHeight: transcriptMinHeight, idealHeight: transcriptIdealHeight, maxHeight: transcriptMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .frame(width: popoverWidth)
    }

    private func copyAllLanes(containing session: ChatSession) {
        copyAllFeedback = .copying
        Task { @MainActor in
            let feedback: CopyAllFeedback
            do {
                let payload = try await oracleViewModel.oracleGroupCopyPayload(containing: session)
                let markdown = OracleLaneMarkdownFormatter.format(payload)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                feedback = pasteboard.setString(markdown, forType: .string) ? .copied : .failed
            } catch {
                feedback = .failed
            }
            copyAllFeedback = feedback
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copyAllFeedback == feedback {
                copyAllFeedback = nil
            }
        }
    }

    private func reconcilePresentedSession() {
        guard let presentation = presentedPopover else { return }
        let sameTabSessions = currentTabID.map { oracleViewModel.sessions(forTabID: $0) } ?? []
        let resolvedID = AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: presentation.sessionID,
            isExplicit: presentation.isExplicit,
            currentWorkspaceID: oracleViewModel.workspaceManager.activeWorkspaceID,
            sameTabSessions: sameTabSessions,
            eligibleSessions: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
        guard let resolvedID else {
            presentedPopover = nil
            return
        }
        guard resolvedID != presentation.sessionID else { return }
        openRequestGeneration &+= 1
        present(
            sessionID: resolvedID,
            isExplicit: presentation.isExplicit,
            actionPolicy: presentation.actionPolicy,
            generation: openRequestGeneration
        )
    }

    private func present(
        sessionID: UUID,
        isExplicit: Bool,
        actionPolicy: ChatTranscriptActionPolicy,
        generation: UInt64
    ) {
        presentedPopover = PopoverPresentation(
            id: generation,
            sessionID: sessionID,
            isExplicit: isExplicit,
            actionPolicy: actionPolicy
        )
    }

    private func openLatestStreamingPopover() {
        guard let target = AgentOraclePillLogic.latestStreamingSession(
            in: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        ) else { return }
        openRequestGeneration &+= 1
        present(
            sessionID: target.id,
            isExplicit: false,
            actionPolicy: .standard,
            generation: openRequestGeneration
        )
    }

    private func openPopover(
        chatID: String?,
        workspaceID: UUID? = nil,
        presentation: AgentOraclePopoverPresentation = .standard
    ) {
        guard let tabID = currentTabID else { return }
        openRequestGeneration &+= 1
        let generation = openRequestGeneration

        guard let chatID else {
            guard let target = latestTabSession else { return }
            present(
                sessionID: target.id,
                isExplicit: false,
                actionPolicy: .standard,
                generation: generation
            )
            return
        }

        presentedPopover = nil
        guard let workspaceID,
              let request = AgentOraclePillLogic.explicitOpenRequest(
                  chatID: chatID,
                  workspaceID: workspaceID,
                  tabID: tabID,
                  generation: generation,
                  presentation: presentation
              ) else { return }

        Task { @MainActor in
            guard let target = await oracleViewModel.resolveExactSessionForPopover(
                chatID: request.chatID,
                workspaceID: request.workspaceID,
                tabID: request.tabID
            ),
                AgentOraclePillLogic.shouldPresent(
                    session: target,
                    for: request,
                    currentGeneration: openRequestGeneration,
                    currentWorkspaceID: oracleViewModel.workspaceManager.activeWorkspaceID,
                    currentTabID: currentTabID
                )
            else { return }

            present(
                sessionID: target.id,
                isExplicit: true,
                actionPolicy: AgentOraclePillLogic.transcriptActionPolicy(for: request.presentation),
                generation: request.generation
            )
        }
    }
}
