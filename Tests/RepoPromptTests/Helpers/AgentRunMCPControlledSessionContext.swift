import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSettingsCore

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
            await window.workspaceManager.awaitInitialized()
            let sessionID = UUID()
            let tabID = UUID()
            var workspace = WorkspaceModel(
                name: "\(workspaceNamePrefix) \(UUID().uuidString.prefix(8))",
                repoPaths: [FileManager.default.currentDirectoryPath]
            )
            workspace.isEphemeral = true
            workspace.composeTabs = [
                ComposeTabState(id: tabID, name: "Controlled approval session", activeAgentSessionID: sessionID)
            ]
            workspace.activeComposeTabID = tabID
            let payload = AgentSession(
                id: sessionID, workspaceID: workspace.id, composeTabID: tabID,
                name: "Controlled approval session", agentKind: AgentProviderKind.claudeCode.rawValue
            )
            // Restore the intended binding from disk; rebinding a loaded fresh tab resets readiness.
            _ = try await AgentSessionDataService.shared.saveAgentSession(payload, for: workspace)
            window.workspaceManager.workspaces.append(workspace)
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: workspaceSwitchReason
            )
            guard let activeWorkspace = window.workspaceManager.activeWorkspace,
                  activeWorkspace.id == workspace.id
            else {
                throw MCPError.internalError("Expected active ephemeral workspace")
            }
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

            let viewModel = window.agentModeViewModel
            let session = await viewModel.ensureSessionReady(tabID: tabID, reconnectActiveProviders: false)
            guard session.activeAgentSessionID == sessionID,
                  session.qualifiedRestorationReadiness.isAuthoritative,
                  viewModel.ownerValidatedSessionIndex[sessionID]?.tabID == tabID
            else {
                throw MCPError.internalError("Expected the persisted approval session to restore with its owner-valid binding")
            }
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
                startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
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
