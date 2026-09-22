import Foundation

@MainActor
final class AgentModeUIFacades {
    let composer = AgentComposerUIStore()
    let statusPills = AgentStatusPillsUIStore()
    let runtimeMetrics = AgentRuntimeMetricsUIStore()
    let contextDrawer = AgentContextDrawerUIStore()
    let sessionSidebar = AgentSessionSidebarUIStore()
    let transcript = AgentTranscriptUIStore()
    let runInteraction = AgentRunInteractionUIStore()
}
