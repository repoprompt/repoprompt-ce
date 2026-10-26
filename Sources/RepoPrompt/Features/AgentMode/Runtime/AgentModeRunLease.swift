import Foundation

extension MCPBootstrapLeaseSpec {
    @MainActor
    static func agentMode(
        tabID: UUID,
        runID: UUID,
        gateID: UUID,
        windowID: Int,
        agent: AgentProviderKind,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false
    ) -> MCPBootstrapLeaseSpec {
        MCPBootstrapLeaseSpec(
            runID: runID,
            gateID: gateID,
            windowID: windowID,
            tabID: tabID,
            clientName: agent.mcpClientNameHint,
            restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
            additionalTools: AgentModeMCPPolicyInstaller.additionalTools(for: agent),
            oneShot: true,
            reason: AgentModeMCPPolicyInstaller.policyReason,
            ttl: AgentModeMCPPolicyInstaller.policyTTL,
            purpose: .agentModeRun,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            requiresExpectedAgentPID: agent.requiresExpectedPIDOwnedAgentModeMCPRouting
        )
    }
}

extension MCPBootstrapLease {
    static func agentModePolicyInstaller(
        _ connectionPolicyInstaller: @escaping AgentModeViewModel.ConnectionPolicyInstaller
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        { leaseSpec in
            guard let clientName = leaseSpec.clientName else { return }
            await connectionPolicyInstaller(
                clientName,
                leaseSpec.windowID,
                leaseSpec.restrictedTools,
                leaseSpec.oneShot,
                leaseSpec.reason,
                leaseSpec.ttl,
                leaseSpec.tabID,
                leaseSpec.runID,
                leaseSpec.additionalTools,
                leaseSpec.purpose,
                leaseSpec.taskLabelKind,
                leaseSpec.allowsAgentExternalControlTools,
                leaseSpec.requiresExpectedAgentPID
            )
        }
    }

    static func agentModePolicyClearer(
        pendingPolicyClearer: (@Sendable () async -> Void)? = nil
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        if let pendingPolicyClearer {
            return { _ in await pendingPolicyClearer() }
        }

        return { leaseSpec in
            guard let clientName = leaseSpec.clientName else { return }
            await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                for: clientName,
                windowID: leaseSpec.windowID,
                runID: leaseSpec.runID
            )
        }
    }
}
