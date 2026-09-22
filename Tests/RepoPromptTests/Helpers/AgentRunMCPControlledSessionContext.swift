import Foundation
import MCP
@testable import RepoPromptApp

@MainActor
final class AgentRunMCPControlledSessionContext {
    let window: WindowState
    let sessionID: UUID
    let session: AgentModeViewModel.TabSession
    let service: AgentRunMCPToolService

    private init(
        window: WindowState,
        sessionID: UUID,
        session: AgentModeViewModel.TabSession,
        service: AgentRunMCPToolService
    ) {
        self.window = window
        self.sessionID = sessionID
        self.session = session
        self.service = service
    }

    static func make(
        workspaceNamePrefix: String,
        workspaceSwitchReason: String,
        clientName: String,
        unusedStartRunMessage: String
    ) async throws -> AgentRunMCPControlledSessionContext {
        let settings = GlobalSettingsStore.shared
        let previousAutoStart = settings.mcpAutoStart()
        settings.setMCPAutoStart(false, commit: false)
        defer { settings.setMCPAutoStart(previousAutoStart, commit: false) }

        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "\(workspaceNamePrefix) \(UUID().uuidString.prefix(8))",
                repoPaths: [FileManager.default.currentDirectoryPath],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: workspaceSwitchReason
            )
            guard let activeWorkspace = window.workspaceManager.activeWorkspace else {
                throw MCPError.internalError("Expected active ephemeral workspace")
            }
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let sessionID = UUID()
            let session = await window.agentModeViewModel.ensureSessionReady(tabID: UUID())
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
            try await window.agentModeViewModel.mcpActivateControlContext(
                forTabID: session.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                startPending: true
            )

            let windowID = window.windowID
            let service = AgentRunMCPToolService(
                toolName: MCPWindowToolName.agentRun,
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: UUID(),
                        clientName: clientName,
                        windowID: windowID
                    )
                },
                requireTargetWindow: { window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                    throw MCPError.internalError(unusedStartRunMessage)
                }
            )
            return AgentRunMCPControlledSessionContext(
                window: window,
                sessionID: sessionID,
                session: session,
                service: service
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }
    }

    func cleanup() async {
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
    }
}
