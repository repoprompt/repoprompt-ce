import Foundation
import MCP
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptMCPServer

extension AgentSessionMCPRuntime {
    struct ControlActivationResources {
        let approvalStore: ApplyEditsApprovalStore
        let approvalScope: ApplyEditsApprovalScope
        let providerBindings: AgentModeProviderBindingService
        let perfRecorder: any AgentModePerfRecording
    }

    /// Owns installation, permissions and rollback. Host composition supplies resources and
    /// a read-only consent fence; neither presentation attachment nor a VM mutation callback
    /// is required to activate the exact admitted runtime writer.
    func activateControlContext(
        command activationCommand: AgentSessionRuntimeStore.Command,
        activationID: UUID, originatingConnectionID: UUID?,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?, startPending: Bool,
        markSessionAsMCPOriginated: Bool, requireInactiveRunState: Bool,
        resources: ControlActivationResources,
        revalidateAdmission: (ControlActivationOwnership) throws -> Void
    ) async throws -> AgentMCPControlContext {
        let writer = activationCommand.writer
        let session = writer.session
        let tabID = session.tabID
        let sessionID = writer.identity.sessionID
        let activationBindingToken = writer.identity.restoration
        let existingContext = session.mcpControlContext
        var activationOwnership: ControlActivationOwnership = .resident
        func requireActivationOwner() throws {
            guard writer.scope.mcp === self, activationCommand.isCurrent else {
                throw MCPError.invalidParams("The requested agent session writer changed during MCP control activation.")
            }
            if case .resident = activationOwnership, requireInactiveRunState, session.runState.isActive {
                throw MCPError.invalidParams("The requested agent session became active before MCP control activation.")
            }
            try revalidateAdmission(activationOwnership)
        }
        try requireActivationOwner()
        let admission = try await registerControlActivation(
            command: activationCommand, activationID: activationID, revalidateAdmission: requireActivationOwner
        )
        let activationGeneration = admission.generation
        let cancellation = admission.cancellation
        let registration = admission.registration
        // This hook models the actor hop after runtime registration revalidation and before
        // visibility. The host must still recheck its pinned command and consent afterwards.
        #if DEBUG
            await test_afterMCPControlRegistration?(activationID)
        #endif
        do {
            try requireActivationOwner()
        } catch {
            await AgentRunSessionStore.cleanup(registration: registration)
            throw error
        }
        guard registration.generation != 0 else {
            throw MCPError.internalError(
                "The Agent session runtime is shutting down and cannot activate a control session."
            )
        }
        guard cancellation.permitsPublication,
              writer.scope.sessions[tabID] === session,
              session.activeAgentSessionID == sessionID,
              !session.bindingTransitionInProgress,
              session.mcpControlActivationGeneration == activationGeneration
        else {
            await AgentRunSessionStore.cleanup(registration: registration)
            throw MCPError.invalidParams("The requested agent session binding changed before MCP control activation.")
        }
        if requireInactiveRunState, session.runState.isActive {
            await AgentRunSessionStore.cleanup(registration: registration)
            throw MCPError.invalidParams(
                "The requested agent session became active before MCP control activation."
            )
        }
        // Even an already-enabled resource needs an exact owner. Its value may be the
        // predecessor's override awaiting release, not the user's underlying preference.
        let autoEditOverride: ApplyEditsApprovalStore.AutoEditOverride
        if let interactions = writer.scope.installedInteractions,
           interactions.approvalStore === resources.approvalStore,
           interactions.approvalScope(for: session) == resources.approvalScope
        {
            guard let prepared = await interactions.prepareControlAutoEditOverride(command: activationCommand) else {
                await AgentRunSessionStore.cleanup(registration: registration)
                throw MCPError.invalidParams("The requested agent session writer changed during MCP control activation.")
            }
            autoEditOverride = prepared
        } else {
            // Explicit resources without an installed interaction composition retain their
            // existing resource-only preparation path.
            autoEditOverride = await resources.approvalStore.prepareAutoEditOverride(for: resources.approvalScope)
        }
        let priorAutoEditEnabled = autoEditOverride.restoreValue
        do {
            try requireActivationOwner()
            guard cancellation.permitsPublication,
                  session.mcpControlActivationGeneration == activationGeneration,
                  session.mcpControlContext == existingContext
            else {
                throw MCPError.invalidParams("The MCP control activation was superseded before permission setup.")
            }
        } catch {
            await resources.approvalStore.releaseAutoEditOverride(autoEditOverride)
            await AgentRunSessionStore.cleanup(registration: registration)
            throw error
        }
        let activatedContext = AgentMCPControlContext(
            sessionID: sessionID,
            activationID: activationID,
            writerIdentity: writer.identity,
            registration: registration,
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: originatingConnectionID,
            interactionTransport: .mcp(
                sessionID: sessionID,
                originatingConnectionID: originatingConnectionID
            ),
            suppressUserNotifications: true,
            forceAutoEditEnabled: true,
            autoEditEnabledBeforeOverride: priorAutoEditEnabled,
            taskLabelKind: taskLabelKind,
            autoEditOverride: autoEditOverride
        )
        let priorMCPOriginated = session.isMCPOriginated
        let priorPermissionProfile = session.permissionProfile
        var didOverrideAutoEdit = false
        var didMarkMCPOriginated = false
        var installedPermissionProfile: AgentProviderPermissionProfile?
        // Observers can publish as soon as control is installed. Establish pending status before
        // setup suspends, so an idle session cannot publish a sticky terminal snapshot for this start.
        session.mcpFollowUpRunPending = startPending
        session.mcpControlContext = activatedContext
        // Publication transfers ownership from the app-owned admission to this exact control context.
        activationOwnership = .installed(context: activatedContext, generation: activationGeneration)
        func releaseFailedInstalledActivation() async {
            // The exact provisional write belongs to this object even after removal or
            // claim loss. A copied context in its former tab slot is not a successor.
            if session.mcpControlActivationGeneration == activationGeneration,
               session.mcpControlContext == activatedContext
            {
                session.mcpControlActivationGeneration &+= 1
                session.mcpControlContext = nil
                if session.mcpFollowUpRunPending == startPending { session.mcpFollowUpRunPending = false }
                // Rebinding may have hydrated new payload values. Unwind the old receipt,
                // but never restore the predecessor's settings over that new binding.
                if session.currentRestorationBindingToken == activationBindingToken {
                    if didMarkMCPOriginated, session.isMCPOriginated { session.isMCPOriginated = priorMCPOriginated }
                    if let installedPermissionProfile, session.permissionProfile == installedPermissionProfile {
                        session.permissionProfile = priorPermissionProfile
                    }
                    if didOverrideAutoEdit, session.autoEditEnabled { session.autoEditEnabled = priorAutoEditEnabled }
                }
                if writer.scope.sessions[tabID] === session {
                    writer.scope.presentation.mcpControlChanged(session, controlled: false)
                }
            } else if session.mcpControlActivationGeneration == activationGeneration,
                      session.mcpControlContext?.activationID == activatedContext.activationID
            {
                // This installation progressed (possibly recovering a new registration).
                // Its live context, not the failed setup, still owns the shared override.
                return
            }
            guard !writer.scope.hasOtherControlResourceHolder(activatedContext, excluding: session) else { return }
            await resources.approvalStore.releaseAutoEditOverride(autoEditOverride)
            await AgentRunSessionStore.cleanup(registration: registration)
        }
        #if DEBUG
            await test_afterMCPControlSetupAwait?(session)
        #endif
        guard cancellation.permitsPublication,
              writer.scope.sessions[tabID] === session,
              session.currentRestorationBindingToken == activationBindingToken,
              session.mcpControlActivationGeneration == activationGeneration,
              session.mcpControlContext == activatedContext
        else {
            await releaseFailedInstalledActivation()
            throw MCPError.invalidParams("The MCP control activation was superseded during setup.")
        }
        do { try requireActivationOwner() } catch {
            await releaseFailedInstalledActivation()
            throw error
        }
        if markSessionAsMCPOriginated {
            // Mark session as MCP-originated so cleanup can scope to MCP sessions only.
            didMarkMCPOriginated = true
            session.isMCPOriginated = true
        }
        // MCP-controlled sessions use the sub-agent permission policy, even when
        // they are top-level MCP starts without a parent session.
        session.permissionProfile = resources.providerBindings.permissionProfileForMCPActivation(isSubagent: true, provider: session.selectedAgent.providerBindingID)
        installedPermissionProfile = session.permissionProfile
        #if DEBUG
            resources.perfRecorder.event("mcp.routing.activateControlContext", tabID: tabID, fields: [
                "sessionID": sessionID.uuidString,
                "parentSessionID": session.parentSessionID?.uuidString ?? "nil",
                "originatingConnectionID": originatingConnectionID?.uuidString ?? "nil",
                "taskLabel": taskLabelKind?.rawValue ?? "nil",
                "startPending": String(startPending),
                "markSessionAsMCPOriginated": String(markSessionAsMCPOriginated),
                "requireInactiveRunState": String(requireInactiveRunState),
                "activationID": activationID.uuidString,
                "permissionProfile": String(describing: session.permissionProfile),
                "selectedAgent": session.selectedAgent.rawValue,
                "selectedModel": session.selectedModelRaw
            ])
        #endif
        didOverrideAutoEdit = true
        session.autoEditEnabled = true
        guard await resources.approvalStore.applyAutoEditOverride(autoEditOverride) else {
            await releaseFailedInstalledActivation()
            throw MCPError.invalidParams("The approval configuration changed during MCP control activation.")
        }
        #if DEBUG
            await test_afterMCPControlSetupAwait?(session)
        #endif
        guard cancellation.permitsPublication,
              writer.scope.sessions[tabID] === session,
              session.currentRestorationBindingToken == activationBindingToken,
              session.mcpControlActivationGeneration == activationGeneration,
              session.mcpControlContext == activatedContext
        else {
            await releaseFailedInstalledActivation()
            throw MCPError.invalidParams("The MCP control activation was superseded during setup.")
        }
        do { try requireActivationOwner() } catch {
            await releaseFailedInstalledActivation()
            throw error
        }
        writer.scope.presentation.mcpControlChanged(session, controlled: true)
        handleObservedMCPStateChange(for: session)
        #if DEBUG
            await test_afterMCPControlActivation?(session)
        #endif
        return activatedContext
    }
}
