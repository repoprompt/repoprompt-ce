import Foundation
import RepoPromptInstrumentation

@MainActor
final class AgentModeUIFacades {
    let composer = AgentComposerUIStore()
    let statusPills = AgentStatusPillsUIStore()
    let runtimeMetrics = AgentRuntimeMetricsUIStore()
    let contextDrawer = AgentContextDrawerUIStore()
    let sessionSidebar = AgentSessionSidebarUIStore()
    let transcript = AgentTranscriptUIStore()
    let runInteraction = AgentRunInteractionUIStore()

    init(perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()) {
        composer.perfRecorder = perfRecorder
        statusPills.perfRecorder = perfRecorder
        runtimeMetrics.perfRecorder = perfRecorder
        sessionSidebar.perfRecorder = perfRecorder
        transcript.perfRecorder = perfRecorder
        runInteraction.perfRecorder = perfRecorder
    }
}
