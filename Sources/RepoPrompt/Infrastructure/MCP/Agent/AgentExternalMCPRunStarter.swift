import Foundation
import MCP

@MainActor
enum AgentExternalMCPRunStarter {
    struct StartOutcome: Equatable {
        let snapshot: AgentRunMCPSnapshot
        let delivery: AgentModeViewModel.MCPInstructionDispatch
    }

    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias BindCurrentRequestToTab = (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void

    /// Extracts a reasoning effort suffix from a model string if present.
    /// Supports formats like "gpt-5.4-high", "o3_low", "gpt-5.4-fast-high".
    /// The model string is passed through unchanged (preserving service tier and other modifiers);
    /// only the effort is extracted separately.
    static func extractReasoningEffort(from modelRaw: String?) -> (model: String?, effort: String?) {
        guard let modelRaw, !modelRaw.isEmpty else { return (modelRaw, nil) }
        let specifier = CodexModelSpecifier(raw: modelRaw)
        if let effort = specifier.reasoningEffort {
            return (modelRaw, effort.rawValue)
        }
        return (modelRaw, nil)
    }

    static func start(
        target: AgentModeViewModel.MCPSessionTarget,
        message: String,
        metadata: RequestMetadata,
        bindCurrentRequestToTab: BindCurrentRequestToTab,
        agentModeVM: AgentModeViewModel,
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        workflow: AgentWorkflowDefinition? = nil
    ) async throws -> StartOutcome {
        let resolvedModel: String?
        let resolvedEffort: String?
        if let reasoningEffortRaw {
            resolvedModel = modelRaw
            resolvedEffort = reasoningEffortRaw
        } else {
            let extracted = extractReasoningEffort(from: modelRaw)
            resolvedModel = extracted.model
            resolvedEffort = extracted.effort
        }
        guard let sessionID = target.sessionID else {
            throw MCPError.internalError("Failed to resolve target agent session ID.")
        }
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.externalRunStarterActivate", tabID: target.tabID, fields: [
                "sessionID": sessionID.uuidString,
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "clientName": metadata.clientName ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "taskLabel": taskLabelKind?.rawValue ?? "nil",
                "agent": agentRaw ?? "nil",
                "model": resolvedModel ?? "nil",
                "workflowID": workflow?.id ?? "nil",
                "workflowName": workflow?.displayName ?? "nil"
            ])
        #endif
        try await agentModeVM.mcpActivateControlContext(
            forTabID: target.tabID,
            sessionID: sessionID,
            originatingConnectionID: metadata.connectionID,
            taskLabelKind: taskLabelKind,
            startPending: true
        )

        // All failures after activation must clean up MCP control context and session store.
        do {
            try await agentModeVM.mcpConfigureSession(
                tabID: target.tabID,
                agentRaw: agentRaw,
                modelRaw: resolvedModel,
                reasoningEffortRaw: resolvedEffort
            )
            try await bindCurrentRequestToTab(target.tabID, metadata)
            #if DEBUG
                AgentModePerfDiagnostics.event("mcp.routing.externalRunStarterBoundRequest", tabID: target.tabID, fields: [
                    "sessionID": sessionID.uuidString,
                    "connectionID": metadata.connectionID?.uuidString ?? "nil",
                    "windowID": metadata.windowID.map(String.init) ?? "nil"
                ])
            #endif

            guard agentModeVM.session(for: target.tabID, createIfNeeded: false) != nil else {
                throw MCPError.internalError("Failed to resolve target agent session.")
            }

            let delivery = try await agentModeVM.mcpDispatchInstruction(
                sessionID: sessionID,
                text: message,
                allowStartingRun: true,
                workflow: workflow
            )

            let snapshot = await resolveInitialSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
            #if DEBUG
                AgentModePerfDiagnostics.event("mcp.routing.externalRunStarterDispatched", tabID: target.tabID, fields: [
                    "sessionID": sessionID.uuidString,
                    "connectionID": metadata.connectionID?.uuidString ?? "nil",
                    "snapshotStatus": snapshot.status.rawValue
                ])
            #endif
            return StartOutcome(snapshot: snapshot, delivery: delivery)
        } catch {
            await agentModeVM.mcpDeactivateControlContext(
                sessionID: sessionID,
                cleanupSessionStore: true
            )
            throw error
        }
    }

    private static func resolveInitialSnapshot(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> AgentRunMCPSnapshot {
        guard let registration = agentModeVM.mcpRegistration(sessionID: sessionID) else {
            return .expired(sessionID: sessionID)
        }
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration) {
            return storedSnapshot
        }
        await Task.yield()
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration) {
            return storedSnapshot
        }
        return .expired(sessionID: sessionID)
    }
}
