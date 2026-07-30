import SwiftUI

// MARK: - Oracle Pill

enum AgentOraclePillPresentation: Equatable {
    case legacySingle
    case pairedLane(OracleLane)

    var id: String {
        switch self {
        case .legacySingle: "legacy"
        case let .pairedLane(lane): lane.rawValue
        }
    }

    var lane: OracleLane {
        switch self {
        case .legacySingle: .primary
        case let .pairedLane(lane): lane
        }
    }

    var label: String {
        switch self {
        case .legacySingle: "Oracle"
        case let .pairedLane(lane): AgentOraclePillLogic.displayLabel(for: lane)
        }
    }

    var isPersistent: Bool {
        if case .pairedLane = self { return true }
        return false
    }

    var acceptsLatestRoute: Bool {
        switch self {
        case .legacySingle, .pairedLane(.primary): true
        case .pairedLane(.secondary): false
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .legacySingle: "agent-oracle-pill"
        case let .pairedLane(lane): "agent-oracle-pill-\(lane.rawValue)"
        }
    }
}

enum AgentOraclePillLogic {
    enum Status: Equatable {
        case idle
        case streaming
        case completed
        case failed(String)
    }

    static let persistentLaneOrder: [OracleLane] = [.primary, .secondary]

    static func presentations(secondaryConfigured: Bool) -> [AgentOraclePillPresentation] {
        secondaryConfigured ? persistentLaneOrder.map(AgentOraclePillPresentation.pairedLane) : [.legacySingle]
    }

    static func acceptsLatestRoute(_ presentation: AgentOraclePillPresentation) -> Bool {
        presentation.acceptsLatestRoute
    }

    static func status(isStreaming: Bool, outcome: OracleLaneOutcome?) -> Status {
        if isStreaming { return .streaming }
        switch outcome {
        case .completed: return .completed
        case let .failed(message): return .failed(message)
        case nil: return .idle
        }
    }

    static func displayLabel(for lane: OracleLane) -> String {
        lane == .primary ? "Primary Oracle" : "Secondary Oracle"
    }

    static func resolvedLane(for session: ChatSession) -> OracleLane? {
        OracleLaneResolution.resolve(lane: session.oracleLane, pairID: session.oraclePairID)?.lane
    }

    struct ExplicitOpenRequest: Equatable {
        let generation: UInt64
        let workspaceID: UUID
        let tabID: UUID
        let chatID: String
        let lane: OracleLane
    }

    static func explicitOpenRequest(
        chatID rawChatID: String,
        workspaceID: UUID,
        tabID: UUID,
        generation: UInt64,
        lane: OracleLane = .primary
    ) -> ExplicitOpenRequest? {
        let chatID = rawChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatID.isEmpty else { return nil }
        return ExplicitOpenRequest(
            generation: generation,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: chatID,
            lane: lane
        )
    }

    static func shouldPresent(
        session: ChatSession,
        for request: ExplicitOpenRequest,
        currentGeneration: UInt64,
        currentWorkspaceID: UUID?,
        currentTabID: UUID?,
        lane: OracleLane = .primary
    ) -> Bool {
        guard request.generation == currentGeneration,
              request.workspaceID == currentWorkspaceID,
              request.tabID == currentTabID,
              session.workspaceID == request.workspaceID,
              session.composeTabID == request.tabID,
              request.lane == lane,
              resolvedLane(for: session) == lane else { return false }
        return Self.session(matchingChatID: request.chatID, in: [session], lane: lane) != nil
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
        activeRunID: UUID? = nil,
        lane: OracleLane = .primary
    ) -> [ChatSession] {
        let renderable = sessions.filter { session in
            resolvedLane(for: session) == lane &&
                (
                    hasRenderableMessages(session: session, liveMessageCount: liveMessageCount(session.id))
                        || streamingSessionIDs.contains(session.id)
                )
        }
        return ownerScopedSessions(
            renderable,
            scopeEvidence: sessions,
            activeAgentSessionID: activeAgentSessionID,
            activeRunID: activeRunID
        )
    }

    static func transcriptCandidates(
        sessions: [ChatSession],
        activeAgentSessionID: UUID? = nil,
        activeRunID: UUID? = nil,
        lane: OracleLane
    ) -> [ChatSession] {
        ownerScopedSessions(
            sessions.filter { resolvedLane(for: $0) == lane },
            scopeEvidence: sessions,
            activeAgentSessionID: activeAgentSessionID,
            activeRunID: activeRunID
        )
    }

    private static func ownerScopedSessions(
        _ candidates: [ChatSession],
        scopeEvidence: [ChatSession],
        activeAgentSessionID: UUID?,
        activeRunID: UUID?
    ) -> [ChatSession] {
        guard activeAgentSessionID != nil || activeRunID != nil else { return candidates }

        func isUnownedLegacy(_ session: ChatSession) -> Bool {
            session.agentModeSessionID == nil && session.agentModeRunID == nil
        }
        func matchesAgent(_ session: ChatSession) -> Bool {
            guard let activeAgentSessionID else { return true }
            return session.agentModeSessionID == activeAgentSessionID
        }

        if let activeRunID {
            let exactRunMatches = candidates.filter { matchesAgent($0) && $0.agentModeRunID == activeRunID }
            if !exactRunMatches.isEmpty { return exactRunMatches }
            if scopeEvidence.contains(where: { matchesAgent($0) && $0.agentModeRunID == activeRunID }) {
                return []
            }

            let sameAgentLegacyRunMatches = candidates.filter {
                matchesAgent($0) && $0.agentModeSessionID != nil && $0.agentModeRunID == nil
            }
            if !sameAgentLegacyRunMatches.isEmpty { return sameAgentLegacyRunMatches }

            if let activeAgentSessionID,
               scopeEvidence.contains(where: { $0.agentModeSessionID == activeAgentSessionID })
            {
                return []
            }
            return candidates.filter(isUnownedLegacy)
        }

        if let activeAgentSessionID {
            let sameAgentMatches = candidates.filter { $0.agentModeSessionID == activeAgentSessionID }
            if !sameAgentMatches.isEmpty { return sameAgentMatches }
            if scopeEvidence.contains(where: { $0.agentModeSessionID == activeAgentSessionID }) {
                return []
            }
        }

        return candidates.filter(isUnownedLegacy)
    }

    static func latestSession(
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>,
        lane: OracleLane = .primary
    ) -> ChatSession? {
        latestStreamingSession(in: sessions, streamingSessionIDs: streamingSessionIDs, lane: lane)
            ?? sessions
            .filter { resolvedLane(for: $0) == lane }
            .max(by: { $0.savedAt < $1.savedAt })
    }

    static func latestStreamingSession(
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>,
        lane: OracleLane = .primary
    ) -> ChatSession? {
        sessions
            .filter { resolvedLane(for: $0) == lane && streamingSessionIDs.contains($0.id) }
            .max(by: { $0.savedAt < $1.savedAt })
    }

    static func selectedSessionID(
        currentSelectionID: UUID?,
        in sessions: [ChatSession],
        streamingSessionIDs: Set<UUID>,
        lane: OracleLane = .primary
    ) -> UUID? {
        let laneSessions = sessions.filter { resolvedLane(for: $0) == lane }
        if let currentSelectionID,
           laneSessions.contains(where: { $0.id == currentSelectionID })
        {
            return currentSelectionID
        }
        return latestSession(in: laneSessions, streamingSessionIDs: streamingSessionIDs, lane: lane)?.id
    }

    static func reconciledPresentedSessionID(
        currentSessionID: UUID?,
        isExplicit: Bool,
        currentWorkspaceID: UUID?,
        sameTabSessions: [ChatSession],
        eligibleSessions: [ChatSession],
        streamingSessionIDs: Set<UUID>,
        lane: OracleLane = .primary
    ) -> UUID? {
        let sameWorkspaceSessions = sameTabSessions.filter {
            $0.workspaceID == currentWorkspaceID && resolvedLane(for: $0) == lane
        }
        let sameWorkspaceEligibleSessions = eligibleSessions.filter {
            $0.workspaceID == currentWorkspaceID && resolvedLane(for: $0) == lane
        }
        if isExplicit {
            guard let currentSessionID,
                  sameWorkspaceSessions.contains(where: { $0.id == currentSessionID })
            else { return nil }
            return currentSessionID
        }

        if let currentSessionID,
           sameWorkspaceEligibleSessions.contains(where: { $0.id == currentSessionID })
        {
            return currentSessionID
        }
        return latestSession(
            in: sameWorkspaceEligibleSessions,
            streamingSessionIDs: streamingSessionIDs,
            lane: lane
        )?.id
    }

    static func session(
        matchingChatID raw: String,
        in sessions: [ChatSession],
        lane: OracleLane = .primary
    ) -> ChatSession? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let targetUUID = UUID(uuidString: trimmed)
        let matches = sessions.filter { session in
            guard resolvedLane(for: session) == lane else { return false }
            if let targetUUID {
                return session.id == targetUUID
            }
            return session.shortID == trimmed
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

/// Oracle status pill for either legacy single mode or one persistent paired lane.
struct AgentOraclePill: View {
    @ObservedObject var oracleViewModel: OracleViewModel
    let windowID: Int
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let activeRunID: UUID?
    let presentation: AgentOraclePillPresentation

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

    private var lane: OracleLane {
        presentation.lane
    }

    private var currentWorkspaceID: UUID? {
        oracleViewModel.workspaceManager.activeWorkspaceID
    }

    private var transcriptCandidateSessions: [ChatSession] {
        guard let tabID = currentTabID else { return [] }
        let sessions = oracleViewModel.sessions(forTabID: tabID)
        let candidates: [ChatSession] = switch presentation {
        case .legacySingle:
            AgentOraclePillLogic.eligibleSessions(
                sessions: sessions,
                streamingSessionIDs: oracleViewModel.streamingSessions,
                liveMessageCount: { oracleViewModel.liveMessageCount(for: $0) },
                activeAgentSessionID: activeAgentSessionID,
                activeRunID: activeRunID,
                lane: lane
            )
        case .pairedLane:
            AgentOraclePillLogic.transcriptCandidates(
                sessions: sessions,
                activeAgentSessionID: activeAgentSessionID,
                activeRunID: activeRunID,
                lane: lane
            )
        }
        return candidates.filter { $0.workspaceID == currentWorkspaceID }
    }

    private var latestTabSession: ChatSession? {
        AgentOraclePillLogic.latestSession(
            in: transcriptCandidateSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions,
            lane: lane
        )
    }

    private var isStreaming: Bool {
        latestTabSession.map { oracleViewModel.streamingSessions.contains($0.id) } ?? false
    }

    private var status: AgentOraclePillLogic.Status {
        AgentOraclePillLogic.status(
            isStreaming: isStreaming,
            outcome: latestTabSession.flatMap { oracleViewModel.oracleLaneOutcomesBySessionID[$0.id] }
        )
    }

    private var resolvedPresentedSessionID: UUID? {
        if presentedSessionSource == .explicit {
            return presentedSessionID
        }
        if let presentedSessionID,
           transcriptCandidateSessions.contains(where: { $0.id == presentedSessionID })
        {
            return presentedSessionID
        }
        return latestTabSession?.id
    }

    private var presentedSession: ChatSession? {
        guard let resolvedPresentedSessionID else { return nil }
        if presentedSessionSource == .explicit, let currentTabID {
            return oracleViewModel.sessions(forTabID: currentTabID).first {
                $0.id == resolvedPresentedSessionID && AgentOraclePillLogic.resolvedLane(for: $0) == lane
            }
        }
        return transcriptCandidateSessions.first { $0.id == resolvedPresentedSessionID }
    }

    private var isPresentedSessionStreaming: Bool {
        resolvedPresentedSessionID.map { oracleViewModel.streamingSessions.contains($0) } ?? false
    }

    private var popoverSubtitle: String {
        guard let presentedSession else {
            return presentation == .legacySingle ? "Latest tab chat" : "Latest \(lane.rawValue) chat"
        }
        if presentedSession.id == latestTabSession?.id {
            return presentation == .legacySingle ? "Latest tab chat" : "Latest \(lane.rawValue) chat"
        }
        return presentedSession.name
    }

    private var statusColor: Color {
        switch status {
        case .idle: .secondary
        case .streaming: .purple
        case .completed: .green
        case .failed: .red
        }
    }

    private var statusIconName: String {
        switch status {
        case .idle, .streaming: "brain"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusTooltip: String {
        switch status {
        case .streaming:
            "\(presentation.label) is thinking — click to view the live chat"
        case .completed:
            "\(presentation.label) completed — click to view the response"
        case let .failed(message):
            "\(presentation.label) failed: \(message)"
        case .idle:
            latestTabSession == nil
                ? "No \(presentation.label) session yet in this tab"
                : "Open the latest \(presentation.label) chat for this tab"
        }
    }

    private var presentedSessionHasRenderableMessages: Bool {
        guard let presentedSession else { return false }
        return AgentOraclePillLogic.hasRenderableMessages(
            session: presentedSession,
            liveMessageCount: oracleViewModel.liveMessageCount(for: presentedSession.id)
        )
    }

    private var shouldShowPill: Bool {
        presentation.isPersistent || latestTabSession != nil
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.oracle")
        #endif
        Group {
            if shouldShowPill {
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
                            Image(systemName: statusIconName)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                                .foregroundStyle(statusColor)
                        }
                        Text(presentation.label)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: isStreaming ? .semibold : .medium))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, AgentPillMetrics.horizontalPadding())
                    .frame(height: AgentPillMetrics.height())
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(statusColor.opacity(isStreaming ? 0.4 : 0.25), lineWidth: isStreaming ? 1 : 0.5)
                    )
                    .shadow(color: isStreaming ? Color.purple.opacity(0.15) : .clear, radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .accessibilityLabel(presentation.label)
                .accessibilityValue(statusTooltip)
                .accessibilityIdentifier(presentation.accessibilityIdentifier)
                .hoverTooltip(statusTooltip, .top)
                .animation(.easeInOut(duration: 0.2), value: isStreaming)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentOraclePopover)) { note in
            if let route = AgentOraclePopoverRoute(notificationUserInfo: note.userInfo) {
                guard route.windowID == windowID,
                      route.tabID == currentTabID,
                      route.workspaceID == currentWorkspaceID
                else { return }
                openPopover(chatID: route.chatID, workspaceID: route.workspaceID)
                return
            }
            guard AgentOraclePillLogic.acceptsLatestRoute(presentation),
                  let route = AgentOracleLatestPopoverRoute(notificationUserInfo: note.userInfo),
                  route.windowID == windowID,
                  route.tabID == currentTabID,
                  route.workspaceID == currentWorkspaceID
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
        .onChange(of: oracleViewModel.sessions.map(\.id)) { _, _ in
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
        let popoverWidth = fontPreset.scaledClamped(800, max: 1040)
        let transcriptMinHeight = fontPreset.scaledClamped(350, max: 460)
        let transcriptIdealHeight = fontPreset.scaledClamped(500, max: 660)
        let transcriptMaxHeight = fontPreset.scaledClamped(600, max: 780)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(presentation.label)
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

            Group {
                if let resolvedPresentedSessionID {
                    ZStack {
                        ChatMessagesView(
                            viewModel: oracleViewModel,
                            autoScrollEnabled: $autoScrollEnabled,
                            bottomOcclusion: 0,
                            showsScrollControls: true,
                            autoScrollOnAppear: true,
                            sessionIDOverride: resolvedPresentedSessionID
                        )

                        if !presentedSessionHasRenderableMessages {
                            emptyState(
                                isPresentedSessionStreaming
                                    ? "\(presentation.label) is starting…"
                                    : "\(presentation.label) has no messages yet",
                                showsProgress: isPresentedSessionStreaming
                            )
                        }
                    }
                } else {
                    emptyState(
                        currentTabID == nil ? "No active Agent Mode tab" : "No \(presentation.label) session yet",
                        showsProgress: false
                    )
                }
            }
            .frame(minHeight: transcriptMinHeight, idealHeight: transcriptIdealHeight, maxHeight: transcriptMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .frame(width: popoverWidth)
    }

    private func emptyState(_ message: String, showsProgress: Bool) -> some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "brain")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 24))
                    .foregroundStyle(.secondary)
            }
            Text(message)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("agent-oracle-empty-\(lane.rawValue)")
    }

    private func reconcilePresentedSession() {
        guard showPopover else { return }
        let sameTabSessions = currentTabID.map { oracleViewModel.sessions(forTabID: $0) } ?? []
        let resolvedID = AgentOraclePillLogic.reconciledPresentedSessionID(
            currentSessionID: presentedSessionID,
            isExplicit: presentedSessionSource == .explicit,
            currentWorkspaceID: currentWorkspaceID,
            sameTabSessions: sameTabSessions,
            eligibleSessions: transcriptCandidateSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions,
            lane: lane
        )
        guard let resolvedID else {
            presentedSessionID = nil
            if presentedSessionSource == .explicit || !presentation.isPersistent {
                showPopover = false
            }
            return
        }
        presentedSessionID = resolvedID
    }

    private func openLatestStreamingPopover() {
        guard let target = AgentOraclePillLogic.latestStreamingSession(
            in: transcriptCandidateSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions,
            lane: lane
        ) else { return }
        openRequestGeneration &+= 1
        presentedSessionID = target.id
        presentedSessionSource = .latest
        showPopover = true
    }

    private func openPopover(chatID: String?, workspaceID: UUID? = nil) {
        openRequestGeneration &+= 1
        let generation = openRequestGeneration

        guard let chatID else {
            guard presentation.isPersistent || latestTabSession != nil else { return }
            presentedSessionID = latestTabSession?.id
            presentedSessionSource = .latest
            showPopover = true
            return
        }

        guard let tabID = currentTabID else { return }
        presentedSessionID = nil
        presentedSessionSource = .explicit
        showPopover = false
        guard let workspaceID,
              let request = AgentOraclePillLogic.explicitOpenRequest(
                  chatID: chatID,
                  workspaceID: workspaceID,
                  tabID: tabID,
                  generation: generation,
                  lane: lane
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
                    currentWorkspaceID: currentWorkspaceID,
                    currentTabID: currentTabID,
                    lane: lane
                )
            else { return }

            presentedSessionID = target.id
            presentedSessionSource = .explicit
            showPopover = true
        }
    }
}
