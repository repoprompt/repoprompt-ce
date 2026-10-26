import Foundation

@MainActor
extension AgentModeViewModel {
    func syncRuntimeMetricsUIState(
        liveSelectedFileCount: Int? = nil,
        liveSelectionSummary: AgentContextSelectionSummary? = nil
    ) {
        #if DEBUG
            test_syncRuntimeMetricsCallCount += 1
        #endif
        ui.runtimeMetrics.update(
            transcriptSnapshot: activeTranscriptAnalyticsSnapshot,
            codexUsage: contextUsage,
            liveSelectedFileCount: liveSelectedFileCount,
            liveSelectionSummary: liveSelectionSummary,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw
        )
    }
}
