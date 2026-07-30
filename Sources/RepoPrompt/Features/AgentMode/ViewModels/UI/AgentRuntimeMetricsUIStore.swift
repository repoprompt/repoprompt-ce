import Foundation

@MainActor
final class AgentRuntimeMetricsUIStore: ObservableObject {
    let runtimeVM = AgentRuntimeSidebarViewModel()
    @Published private(set) var revision: Int = 0

    func update(
        transcriptSnapshot: AgentTranscriptAnalyticsSnapshot,
        codexUsage: AgentContextUsage?,
        liveSelectedFileCount: Int?,
        liveSelectionSummary: AgentContextSelectionSummary? = nil,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String
    ) {
        let previousSnapshot = runtimeVM.snapshot
        runtimeVM.update(
            snapshot: transcriptSnapshot,
            codexUsage: codexUsage,
            liveSelectedFileCount: liveSelectedFileCount,
            liveSelectionSummary: liveSelectionSummary,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw
        )
        let didPublish = runtimeVM.snapshot != previousSnapshot
        if didPublish {
            revision &+= 1
        }
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                "runtimeMetrics",
                published: didPublish,
                details: [
                    "revision": String(revision),
                    "usedTokens": runtimeVM.snapshot.usedTokens.map(String.init) ?? "nil",
                    "estimatedTranscriptTokens": runtimeVM.snapshot.estimatedTranscriptTokens.map(String.init) ?? "nil",
                    "selectionFileCount": runtimeVM.snapshot.selectionFileCount.map(String.init) ?? "nil",
                    "selectionSliceRanges": runtimeVM.snapshot.selectionSummary.map { String($0.sliceRangeCount) } ?? "nil",
                    "updatedAtChanged": String(runtimeVM.snapshot.updatedAt != previousSnapshot.updatedAt)
                ]
            )
        #endif
    }
}
