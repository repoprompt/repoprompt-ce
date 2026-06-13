import Foundation
import SwiftUI

@MainActor
final class AgentRuntimeSidebarViewModel: ObservableObject {
    enum UsageSource: String, Equatable {
        case codexLive
        case toolDerived
        case unavailable

        var label: String {
            switch self {
            case .codexLive:
                "Live"
            case .toolDerived:
                "Estimated (tools)"
            case .unavailable:
                "Unavailable"
            }
        }
    }

    struct ContextSnapshot: Equatable {
        var updatedAt: Date?
        var usedTokens: Int?
        var estimatedTranscriptTokens: Int?
        var contextWindowTokens: Int?
        var usageSource: UsageSource = .unavailable
        var selectionFileCount: Int?
        var selectionTokens: Int?
        var selectionDeltaTokens: Int?
        var observedReadFileCount: Int = 0
        var tokenStatsTotal: Int?
        var selectedAgent: AgentProviderKind?
        var selectedModelRaw: String?

        /// Context window with agent-specific fallback when the provider hasn't reported one yet.
        /// With a known agent, encoded selections (`base:effort`) resolve through
        /// `resolvedModel(forRaw:agentKind:)`; without one, only an exact raw match
        /// can be trusted because the specifier grammar is agent-specific.
        var effectiveContextWindowTokens: Int {
            if let contextWindowTokens { return contextWindowTokens }
            let model: AgentModel? = if let selectedAgent {
                AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent)
            } else {
                selectedModelRaw.flatMap(AgentModel.init(rawValue:))
            }
            if let modelContextWindow = model?.contextWindowTokens {
                return modelContextWindow
            }
            switch selectedAgent {
            case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: return 200_000
            case .openCode, .cursor: return 200_000
            case .codexExec, .none: return 200_000
            }
        }
    }

    @Published private(set) var snapshot: ContextSnapshot = .init()
    @Published private(set) var latestContextBuilderResult: ToolResultDTOs.ContextBuilderDTO?

    private struct SelectionToolMetrics: Equatable {
        let fileCount: Int
        let tokens: Int?
        let timestamp: Date
    }

    private struct TimestampedToolResult<Value: Equatable>: Equatable {
        let value: Value
        let timestamp: Date
    }

    private var latestWorkspaceContext: TimestampedToolResult<ToolResultDTOs.PromptContextDTO>?
    private var latestManageSelection: TimestampedToolResult<ToolResultDTOs.SelectionReply>?
    private var observedReadFiles: Set<String> = []
    private var processedItemIDs: Set<UUID> = []
    private var activeTranscriptFirstItemID: UUID?
    private var lastSeenCodexUsage: AgentContextUsage?
    private var lastUpdatedAt: Date?

    func update(
        snapshot transcriptSnapshot: AgentTranscriptAnalyticsSnapshot,
        codexUsage: AgentContextUsage?,
        liveSelectedFileCount: Int? = nil,
        selectedAgent: AgentProviderKind? = nil,
        selectedModelRaw: String? = nil
    ) {
        activeTranscriptFirstItemID = nil
        processedItemIDs.removeAll()
        // Only bump `lastUpdatedAt` when meaningful runtime inputs actually change.
        // Updating the timestamp unconditionally defeats the downstream snapshot
        // equality guard in `AgentRuntimeMetricsUIStore` and causes revision churn.
        var meaningfulChange = false

        let nextObservedReadFiles = transcriptSnapshot.observedReadFiles
        if nextObservedReadFiles != observedReadFiles {
            observedReadFiles = nextObservedReadFiles
            meaningfulChange = true
        }

        let nextWorkspaceContextItem = transcriptSnapshot.latestWorkspaceContextItem
        let nextWorkspaceContext = nextWorkspaceContextItem.flatMap { item in
            ToolJSON.decodeResult(ToolResultDTOs.PromptContextDTO.self, from: item.toolResultJSON).map {
                TimestampedToolResult(value: $0, timestamp: item.timestamp)
            }
        }
        if nextWorkspaceContext != latestWorkspaceContext {
            latestWorkspaceContext = nextWorkspaceContext
            meaningfulChange = true
        }

        let nextManageSelectionItem = transcriptSnapshot.latestManageSelectionItem
        let nextManageSelection = nextManageSelectionItem.flatMap { item in
            ToolJSON.decodeResult(ToolResultDTOs.SelectionReply.self, from: item.toolResultJSON).map {
                TimestampedToolResult(value: $0, timestamp: item.timestamp)
            }
        }
        if nextManageSelection != latestManageSelection {
            latestManageSelection = nextManageSelection
            meaningfulChange = true
        }

        let nextContextBuilderResult = transcriptSnapshot.latestContextBuilderItem.flatMap {
            ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: $0.toolResultJSON)
        }
        if nextContextBuilderResult != latestContextBuilderResult {
            latestContextBuilderResult = nextContextBuilderResult
            meaningfulChange = true
        }

        if lastSeenCodexUsage != codexUsage {
            lastSeenCodexUsage = codexUsage
            meaningfulChange = true
        }

        if meaningfulChange {
            lastUpdatedAt = Date()
        }

        let previousSnapshot = snapshot
        var next = ContextSnapshot()
        next.updatedAt = lastUpdatedAt
        next.observedReadFileCount = observedReadFiles.count
        next.estimatedTranscriptTokens = transcriptSnapshot.estimatedTranscriptTokens

        let toolTotalTokens = latestWorkspaceContext?.value.tokenStats?.total ?? latestManageSelection?.value.tokenStats?.total
        next.tokenStatsTotal = toolTotalTokens

        if let codexUsage {
            let last = codexUsage.lastTotalTokens ?? 0
            let total = codexUsage.totalTotalTokens ?? 0
            let used = last > 0 ? last : total
            next.usedTokens = used > 0 ? used : nil
            next.contextWindowTokens = codexUsage.modelContextWindow
            next.usageSource = .codexLive
        } else if let toolTotalTokens {
            next.usedTokens = toolTotalTokens
            next.contextWindowTokens = nil
            next.usageSource = .toolDerived
        } else {
            next.usageSource = .unavailable
        }

        let selectionToolMetrics = latestToolSelectionMetrics()
        let selectionFiles = liveSelectedFileCount ?? selectionToolMetrics?.fileCount
        let selectionTokens = selectionToolMetrics?.tokens
        next.selectionTokens = selectionTokens

        if let selectionFiles {
            next.selectionFileCount = selectionFiles
        }

        if let previousTokens = previousSnapshot.selectionTokens,
           let selectionTokens,
           previousTokens != selectionTokens
        {
            next.selectionDeltaTokens = selectionTokens - previousTokens
        }

        next.selectedAgent = selectedAgent ?? transcriptSnapshot.selectedAgent
        next.selectedModelRaw = selectedModelRaw

        if snapshot != next {
            snapshot = next
        }
    }

    func update(
        items: [AgentChatItem],
        codexUsage: AgentContextUsage?,
        liveSelectedFileCount: Int? = nil,
        selectedAgent: AgentProviderKind? = nil,
        selectedModelRaw: String? = nil
    ) {
        resetIfTranscriptChanged(items: items)
        processNewItems(items)

        if lastSeenCodexUsage != codexUsage {
            lastSeenCodexUsage = codexUsage
            lastUpdatedAt = Date()
        }

        let previousSnapshot = snapshot
        var next = ContextSnapshot()
        next.updatedAt = lastUpdatedAt
        next.observedReadFileCount = observedReadFiles.count
        let transcriptChars = items.reduce(0) { $0 + $1.text.count }
        next.estimatedTranscriptTokens = transcriptChars > 0 ? transcriptChars / 4 : nil

        let toolTotalTokens = latestWorkspaceContext?.value.tokenStats?.total ?? latestManageSelection?.value.tokenStats?.total
        next.tokenStatsTotal = toolTotalTokens

        if let codexUsage {
            let last = codexUsage.lastTotalTokens ?? 0
            let total = codexUsage.totalTotalTokens ?? 0
            let used = last > 0 ? last : total
            next.usedTokens = used > 0 ? used : nil
            next.contextWindowTokens = codexUsage.modelContextWindow
            next.usageSource = .codexLive
        } else if let toolTotalTokens {
            next.usedTokens = toolTotalTokens
            next.contextWindowTokens = nil
            next.usageSource = .toolDerived
        } else {
            next.usageSource = .unavailable
        }

        let selectionToolMetrics = latestToolSelectionMetrics()
        let selectionFiles = liveSelectedFileCount ?? selectionToolMetrics?.fileCount
        let selectionTokens = selectionToolMetrics?.tokens
        next.selectionTokens = selectionTokens

        if let selectionFiles {
            next.selectionFileCount = selectionFiles
        }

        if let previousTokens = previousSnapshot.selectionTokens,
           let selectionTokens,
           previousTokens != selectionTokens
        {
            next.selectionDeltaTokens = selectionTokens - previousTokens
        }

        next.selectedAgent = selectedAgent
        next.selectedModelRaw = selectedModelRaw

        if snapshot != next {
            snapshot = next
        }
    }

    private func latestToolSelectionMetrics() -> SelectionToolMetrics? {
        let workspaceMetrics = latestWorkspaceContext.flatMap { result -> SelectionToolMetrics? in
            guard let selection = result.value.selection else { return nil }
            return SelectionToolMetrics(
                fileCount: selection.files.count,
                tokens: selection.totalTokens,
                timestamp: result.timestamp
            )
        }
        let manageSelectionMetrics = latestManageSelection.flatMap { result -> SelectionToolMetrics? in
            guard let files = result.value.files else { return nil }
            return SelectionToolMetrics(
                fileCount: files.count,
                tokens: result.value.totalTokens,
                timestamp: result.timestamp
            )
        }

        switch (workspaceMetrics, manageSelectionMetrics) {
        case let (workspaceMetrics?, manageSelectionMetrics?):
            return manageSelectionMetrics.timestamp >= workspaceMetrics.timestamp
                ? manageSelectionMetrics
                : workspaceMetrics
        case let (workspaceMetrics?, nil):
            return workspaceMetrics
        case let (nil, manageSelectionMetrics?):
            return manageSelectionMetrics
        case (nil, nil):
            return nil
        }
    }

    private func resetIfTranscriptChanged(items: [AgentChatItem]) {
        let firstID = items.first?.id
        if firstID != activeTranscriptFirstItemID {
            activeTranscriptFirstItemID = firstID
            processedItemIDs.removeAll()
            latestWorkspaceContext = nil
            latestManageSelection = nil
            latestContextBuilderResult = nil
            observedReadFiles.removeAll()
            lastUpdatedAt = nil
        }
    }

    private func processNewItems(_ items: [AgentChatItem]) {
        for item in items where !processedItemIDs.contains(item.id) {
            processedItemIDs.insert(item.id)
            process(item)
        }
    }

    private func process(_ item: AgentChatItem) {
        guard let toolName = normalizedToolCardName(item.toolName) else { return }
        let normalized = toolName.lowercased()

        if item.kind == .toolCall, normalized == "read_file",
           let args = ToolJSON.decodeArgs(ToolArgsDTOs.ReadFileArgs.self, from: item.toolArgsJSON),
           let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty
        {
            observedReadFiles.insert(path)
            lastUpdatedAt = item.timestamp
        }

        guard item.kind == .toolResult else { return }
        switch normalized {
        case "workspace_context":
            if let dto = ToolJSON.decodeResult(ToolResultDTOs.PromptContextDTO.self, from: item.toolResultJSON) {
                latestWorkspaceContext = TimestampedToolResult(value: dto, timestamp: item.timestamp)
                lastUpdatedAt = item.timestamp
            }
        case "manage_selection":
            if let dto = ToolJSON.decodeResult(ToolResultDTOs.SelectionReply.self, from: item.toolResultJSON) {
                latestManageSelection = TimestampedToolResult(value: dto, timestamp: item.timestamp)
                lastUpdatedAt = item.timestamp
            }
        case "context_builder":
            if let dto = ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: item.toolResultJSON) {
                latestContextBuilderResult = dto
                lastUpdatedAt = item.timestamp
            }
        case "read_file":
            if let dto = ToolJSON.decodeResult(ToolResultDTOs.ReadFileReply.self, from: item.toolResultJSON),
               let path = dto.displayPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty
            {
                observedReadFiles.insert(path)
                lastUpdatedAt = item.timestamp
            }
        default:
            break
        }
    }
}
