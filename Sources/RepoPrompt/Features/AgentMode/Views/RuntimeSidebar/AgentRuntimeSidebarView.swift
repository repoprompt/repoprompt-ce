import SwiftUI

struct AgentRuntimeSidebarView: View {
    @ObservedObject var contextBuilderAgentVM: ContextBuilderAgentViewModel
    @ObservedObject var oracleViewModel: OracleViewModel
    @ObservedObject var promptManager: PromptViewModel
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let activeRunID: UUID?
    let worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?
    let onCollapse: () -> Void

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @State private var oracleAutoScrollEnabled: Bool = false
    @State private var selectedOracleSessionID: UUID?

    private var isContextBuilderRunning: Bool {
        guard let tabID = currentTabID else { return false }
        return contextBuilderAgentVM.tabsWithActiveContextBuilderRun.contains(tabID)
    }

    private var isOracleStreaming: Bool {
        let tabSessionIDs = Set(tabChatSessions.map(\.id))
        guard !tabSessionIDs.isEmpty else { return false }
        return !oracleViewModel.streamingSessions.isDisjoint(with: tabSessionIDs)
    }

    private var hasContextBuilderLog: Bool {
        !contextBuilderAgentVM.agentLog.isEmpty
    }

    private var tabChatSessions: [ChatSession] {
        guard let tabID = currentTabID else { return [] }
        return AgentOraclePillLogic.eligibleSessions(
            sessions: oracleViewModel.sessions(forTabID: tabID),
            streamingSessionIDs: oracleViewModel.streamingSessions,
            liveMessageCount: { oracleViewModel.liveMessageCount(for: $0) },
            activeAgentSessionID: activeAgentSessionID,
            activeRunID: activeRunID
        )
    }

    private var selectedOracleSession: ChatSession? {
        guard let selectedID = AgentOraclePillLogic.selectedSessionID(
            currentSelectionID: selectedOracleSessionID,
            in: tabChatSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        ) else { return nil }
        return tabChatSessions.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Context builder - shown when running or has recent log
                    if isContextBuilderRunning || hasContextBuilderLog {
                        contextBuilderSection
                    }

                    // Oracle chat - shown when there are any sessions for this tab
                    if !tabChatSessions.isEmpty {
                        oracleChatSection
                    }

                    // File context summary
                    fileContextSection

                    // Context usage
                    contextUsageSection

                    // Export context
                    exportContextSection
                }
                .padding(10)
            }
        }
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 360, maxHeight: .infinity)
        .environment(\.showDatesInMessageTimestamps, globalSettings.showDatesInMessageTimestamps())
        .onChange(of: currentTabID) { _, _ in
            selectedOracleSessionID = nil
            selectLatestOracleSessionIfNeeded()
        }
    }

    // MARK: - Header (matches pill visual style, collapse on left)

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            AgentRuntimeSidebarCollapseButton(onCollapse: onCollapse)

            AgentRuntimeSidebarHeaderStatusView(state: headerState)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(headerState.borderColor, lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var headerState: RuntimeSidebarHeaderState {
        if isContextBuilderRunning { return .init(mode: .contextBuilder) }
        if isOracleStreaming { return .init(mode: .oracle) }
        return .init(
            mode: .idle(
                fileCount: runtimeVM.snapshot.selectionFileCount ?? 0,
                selectionTokens: runtimeVM.snapshot.selectionTokens
            )
        )
    }

    // MARK: - Context Builder

    private var contextBuilderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isContextBuilderRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                Text("Context Builder")
                    .font(.system(size: 11, weight: .semibold))

                Spacer()

                if contextBuilderAgentVM.toolCallCount > 0 {
                    Text("\(contextBuilderAgentVM.toolCallCount) tools")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(contextBuilderAgentVM.agentLog.suffix(6))) { entry in
                    AgentLogEntryRowView(entry: entry, style: .compact)
                }
            }
        }
        .sidebarCard(highlight: isContextBuilderRunning ? .blue : nil)
    }

    // MARK: - Oracle Chat

    private var oracleChatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isOracleStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Text("Oracle")
                    .font(.system(size: 11, weight: .semibold))

                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)

                Text("\(tabChatSessions.count) session\(tabChatSessions.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            // Always show the chat transcript when there are sessions
            ChatMessagesView(
                viewModel: oracleViewModel,
                autoScrollEnabled: $oracleAutoScrollEnabled,
                bottomOcclusion: 0,
                showsScrollControls: false,
                autoScrollOnAppear: isOracleStreaming,
                sessionIDOverride: selectedOracleSession?.id
            )
            .frame(minHeight: 160, idealHeight: 260, maxHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Session list for switching
            if tabChatSessions.count > 1 {
                VStack(spacing: 2) {
                    ForEach(tabChatSessions.suffix(5)) { session in
                        oracleSessionRow(session)
                    }
                }
            }
        }
        .sidebarCard(highlight: isOracleStreaming ? .purple : nil)
        .onAppear { selectLatestOracleSessionIfNeeded() }
    }

    /// Select the latest oracle session for rendering only when the local
    /// sidebar selection is missing or no longer belongs to this tab.
    private func selectLatestOracleSessionIfNeeded() {
        let resolvedID = AgentOraclePillLogic.selectedSessionID(
            currentSelectionID: selectedOracleSessionID,
            in: tabChatSessions,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
        if resolvedID == selectedOracleSessionID { return }
        guard let resolvedID else { return }
        selectedOracleSessionID = resolvedID
    }

    private func oracleSessionRow(_ session: ChatSession) -> some View {
        Button {
            selectedOracleSessionID = session.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(session.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if oracleViewModel.streamingSessions.contains(session.id) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Text(session.messageCountLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        selectedOracleSession?.id == session.id
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - File Context

    private var fileContextSection: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected files")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("\(runtimeVM.snapshot.selectionFileCount ?? 0)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Selection tokens")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let tokens = runtimeVM.snapshot.selectionTokens {
                    Text("~\(AgentContextIndicator.formatTokens(tokens))")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                } else {
                    Text("—")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .sidebarCard()
    }

    // MARK: - Context Usage

    /// Estimates used tokens from the agent transcript character count when codex usage isn't available.
    private var estimatedUsedTokens: Int? {
        runtimeVM.snapshot.usedTokens ?? runtimeVM.snapshot.estimatedTranscriptTokens
    }

    private var contextWindowTokens: Int {
        runtimeVM.snapshot.effectiveContextWindowTokens
    }

    private var contextUsageSection: some View {
        Group {
            if let usedTokens = estimatedUsedTokens {
                AgentContextIndicator(
                    contextWindowTokens: contextWindowTokens,
                    usedTokens: usedTokens,
                    sourceLabel: runtimeVM.snapshot.usedTokens != nil
                        ? runtimeVM.snapshot.usageSource.label
                        : "Estimated",
                    style: .labeled
                )
                .sidebarCard()
            }
        }
    }

    // MARK: - Export Context

    private var exportContextSection: some View {
        AgentExportCard(
            promptManager: promptManager,
            tokenCounter: promptManager.tokenCountingViewModel,
            selectionCoordinator: selectionCoordinator,
            fileCount: runtimeVM.snapshot.selectionFileCount,
            selectionTokens: runtimeVM.snapshot.selectionTokens,
            currentTabID: currentTabID,
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingsProvider: worktreeBindingsProvider
        )
        .sidebarCard()
    }
}

private struct RuntimeSidebarHeaderState: Equatable {
    enum Mode: Equatable {
        case contextBuilder
        case oracle
        case idle(fileCount: Int, selectionTokens: Int?)
    }

    let mode: Mode

    var borderColor: Color {
        switch mode {
        case .contextBuilder:
            Color.blue.opacity(0.3)
        case .oracle:
            Color.purple.opacity(0.3)
        case .idle:
            Color.secondary.opacity(0.15)
        }
    }
}

private struct AgentRuntimeSidebarCollapseButton: View {
    let onCollapse: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onCollapse) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Collapse runtime sidebar")
    }
}

private struct AgentRuntimeSidebarHeaderStatusView: View {
    let state: RuntimeSidebarHeaderState

    var body: some View {
        HStack(spacing: 6) {
            switch state.mode {
            case .contextBuilder:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text("Context Builder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            case .oracle:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text("Oracle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            case let .idle(fileCount, selectionTokens):
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let selectionTokens {
                    Text("\(fileCount) files · \(AgentContextIndicator.formatTokens(selectionTokens))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if fileCount > 0 {
                    Text("\(fileCount) files")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Runtime")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Card Modifier

private extension View {
    func sidebarCard(highlight: Color? = nil) -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(highlight?.opacity(0.25) ?? Color.clear, lineWidth: 1)
            )
    }
}

private extension ChatSession {
    var messageCountLabel: String {
        let count = effectiveMessageCount
        return "\(count) msg\(count == 1 ? "" : "s")"
    }
}
