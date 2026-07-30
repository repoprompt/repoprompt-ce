import SwiftUI

// MARK: - Oracle Pill

enum AgentOraclePillLogic {
    struct ExplicitOpenRequest: Equatable {
        let generation: UInt64
        let workspaceID: UUID
        let tabID: UUID
        let chatID: String
    }

    static func explicitOpenRequest(
        chatID rawChatID: String,
        workspaceID: UUID,
        tabID: UUID,
        generation: UInt64
    ) -> ExplicitOpenRequest? {
        let chatID = rawChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatID.isEmpty else { return nil }
        return ExplicitOpenRequest(
            generation: generation,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: chatID
        )
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
            if !exactRunMatches.isEmpty {
                return exactRunMatches
            }

            let sameAgentLegacyRunMatches = renderable.filter { matchesAgent($0) && $0.agentModeSessionID != nil && $0.agentModeRunID == nil }
            if !sameAgentLegacyRunMatches.isEmpty {
                return sameAgentLegacyRunMatches
            }

            if let activeAgentSessionID,
               renderable.contains(where: { $0.agentModeSessionID == activeAgentSessionID })
            {
                return []
            }
            return renderable.filter(isUnownedLegacy)
        }

        if let activeAgentSessionID {
            let sameAgentMatches = renderable.filter { $0.agentModeSessionID == activeAgentSessionID }
            if !sameAgentMatches.isEmpty {
                return sameAgentMatches
            }
        }

        return renderable.filter(isUnownedLegacy)
    }

    static func latestSession(
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>
    ) -> ChatSession? {
        latestStreamingSession(in: sessions, streamingSessionIDs: streamingSessionIDs)
            ?? sessions.max(by: { $0.savedAt < $1.savedAt })
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
}

/// Pill that appears when there are oracle chat sessions for the current tab.
/// More prominent when streaming. Clicking opens a wide popover with chat transcript.
struct AgentOraclePill: View {
    @ObservedObject var oracleViewModel: OracleViewModel
    let windowID: Int
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let activeRunID: UUID?

    private enum PresentedSessionSource {
        case latest
        case explicit
    }

    @State private var showPopover = false
    @State private var autoScrollEnabled = false
    @State private var presentedSessionID: UUID?
    @State private var presentedSessionSource: PresentedSessionSource = .latest
    @State private var openRequestGeneration: UInt64 = 0
    @ObservedObject private var fontScale = FontScaleManager.shared
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

    private var isStreaming: Bool {
        guard let latestTabSession else { return false }
        return oracleViewModel.streamingSessions.contains(latestTabSession.id)
    }

    private var presentedSession: ChatSession? {
        guard let presentedSessionID,
              let tabID = currentTabID else { return nil }
        return oracleViewModel.sessions(forTabID: tabID).first { $0.id == presentedSessionID }
    }

    private var isPresentedSessionStreaming: Bool {
        guard let presentedSessionID else { return isStreaming }
        return oracleViewModel.streamingSessions.contains(presentedSessionID)
    }

    private var popoverSubtitle: String {
        guard let presentedSession else { return "Latest tab chat" }
        if presentedSession.id == latestTabSession?.id {
            return "Latest tab chat"
        }
        return presentedSession.name
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
                        Text("Oracle")
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
                .hoverTooltip(isStreaming ? "Oracle is thinking — click to view the live chat" : "Open the latest Oracle chat for this tab", .top)
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
                openPopover(chatID: route.chatID, workspaceID: route.workspaceID)
                return
            }
            guard let route = AgentOracleLatestPopoverRoute(notificationUserInfo: note.userInfo),
                  route.windowID == windowID,
                  route.tabID == currentTabID,
                  route.workspaceID == oracleViewModel.workspaceManager.activeWorkspaceID
            else { return }
            openLatestStreamingPopover()
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            oraclePopoverContent
        }
        .onChange(of: currentTabID) { _, _ in
            openRequestGeneration &+= 1
            reconcilePresentedSession()
        }
        .onReceive(oracleViewModel.workspaceManager.$activeWorkspaceID) { _ in
            openRequestGeneration &+= 1
            if presentedSessionSource == .explicit {
                presentedSessionID = nil
                showPopover = false
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

    @ViewBuilder
    private var oraclePopoverContent: some View {
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
                if isPresentedSessionStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Spacer()
                Text(popoverSubtitle)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ChatMessagesView(
                viewModel: oracleViewModel,
                autoScrollEnabled: $autoScrollEnabled,
                bottomOcclusion: 0,
                showsScrollControls: true,
                autoScrollOnAppear: true,
                sessionIDOverride: presentedSessionID
            )
            .frame(minHeight: transcriptMinHeight, idealHeight: transcriptIdealHeight, maxHeight: transcriptMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .frame(width: popoverWidth)
    }

    private func reconcilePresentedSession() {
        guard showPopover else { return }
        let sameTabSessions = currentTabID.map { oracleViewModel.sessions(forTabID: $0) } ?? []
        let resolvedID = AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: presentedSessionID,
            isExplicit: presentedSessionSource == .explicit,
            currentWorkspaceID: oracleViewModel.workspaceManager.activeWorkspaceID,
            sameTabSessions: sameTabSessions,
            eligibleSessions: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
        guard let resolvedID else {
            presentedSessionID = nil
            showPopover = false
            return
        }
        presentedSessionID = resolvedID
    }

    private func openLatestStreamingPopover() {
        guard let target = AgentOraclePillLogic.latestStreamingSession(
            in: eligibleTabSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        ) else { return }
        openRequestGeneration &+= 1
        presentedSessionID = target.id
        presentedSessionSource = .latest
        showPopover = true
    }

    private func openPopover(chatID: String?, workspaceID: UUID? = nil) {
        guard let tabID = currentTabID else { return }
        openRequestGeneration &+= 1
        let generation = openRequestGeneration

        guard let chatID else {
            guard let target = latestTabSession else { return }
            presentedSessionID = target.id
            presentedSessionSource = .latest
            showPopover = true
            return
        }

        presentedSessionID = nil
        presentedSessionSource = .explicit
        showPopover = false
        guard let workspaceID,
              let request = AgentOraclePillLogic.explicitOpenRequest(
                  chatID: chatID,
                  workspaceID: workspaceID,
                  tabID: tabID,
                  generation: generation
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

            presentedSessionID = target.id
            presentedSessionSource = .explicit
            showPopover = true
        }
    }
}
