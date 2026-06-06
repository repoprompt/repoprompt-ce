import Foundation

@MainActor
extension AgentModeViewModel {
    func syncRuntimeMetricsUIState(liveSelectedFileCount: Int? = nil) {
        #if DEBUG
            test_syncRuntimeMetricsCallCount += 1
        #endif
        ui.runtimeMetrics.update(
            transcriptSnapshot: activeTranscriptAnalyticsSnapshot,
            codexUsage: contextUsage,
            liveSelectedFileCount: liveSelectedFileCount,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw
        )
    }
}
