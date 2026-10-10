import Foundation

package struct MCPDomainClientPolicySnapshot: Equatable, Sendable {
    package let restrictedToolNames: Set<String>
    package let additionalToolNames: Set<String>
    package let role: MCPClientTaskRole
    package let allowsAgentExternalControlTools: Bool
    /// Whether server-owned routing resolved this connection to an exact endpoint that currently has
    /// an Agent-session link in either direction. This is intentionally narrower than an additional
    /// tool grant: a policy-supplied grant cannot manufacture the exact-link override.
    /// The separate session-incarnation opt-in below is also server-owned, never a link.
    package let hasExactAgentSessionLinkGrant: Bool
    /// Server-proved session-local reachability only; neither fact manufactures a link grant.
    package let canBecomeOverseer: Bool
    package let hasActivatedOverseer: Bool

    package init(
        restrictedToolNames: Set<String>,
        additionalToolNames: Set<String>,
        role: MCPClientTaskRole,
        allowsAgentExternalControlTools: Bool,
        hasExactAgentSessionLinkGrant: Bool = false,
        canBecomeOverseer: Bool = false,
        hasActivatedOverseer: Bool = false
    ) {
        self.restrictedToolNames = restrictedToolNames
        self.additionalToolNames = additionalToolNames
        self.role = role
        self.allowsAgentExternalControlTools = allowsAgentExternalControlTools
        self.hasExactAgentSessionLinkGrant = hasExactAgentSessionLinkGrant
        self.canBecomeOverseer = canBecomeOverseer
        self.hasActivatedOverseer = hasActivatedOverseer
    }
}

package struct MCPDomainCatalogAdvertisementRequest: Sendable {
    package let isGloballyEnabled: Bool
    package let disabledToolNames: Set<String>
    package let policy: MCPDomainClientPolicySnapshot
    package let agentSessionLinkSurface: AgentSessionLinkToolSurface

    package init(
        isGloballyEnabled: Bool,
        disabledToolNames: Set<String>,
        policy: MCPDomainClientPolicySnapshot,
        agentSessionLinkSurface: AgentSessionLinkToolSurface = .full
    ) {
        self.agentSessionLinkSurface = agentSessionLinkSurface
        self.isGloballyEnabled = isGloballyEnabled
        self.disabledToolNames = disabledToolNames
        self.policy = policy
    }
}

package enum MCPDomainCatalogHiddenReason: String, Equatable, Sendable {
    case disabled
    case restricted
    case missingAdditionalToolGrant = "missing_additional_tool_grant"
    case roleAdvertisementPolicy = "role_advertisement_policy"
}

package struct MCPDomainCatalogAdvertisementResult: Sendable {
    package let definitions: [MCPDomainToolDefinition]
    package let hiddenReasonsByToolName: [String: MCPDomainCatalogHiddenReason]

    package init(
        definitions: [MCPDomainToolDefinition],
        hiddenReasonsByToolName: [String: MCPDomainCatalogHiddenReason]
    ) {
        self.definitions = definitions
        self.hiddenReasonsByToolName = hiddenReasonsByToolName
    }
}

package enum MCPDomainCallPolicyDenial: Error, Equatable, Sendable {
    case missingAdditionalGrant(toolName: String)
    case restricted(toolName: String)
    case roleUnavailable(toolName: String)
    case unknownTool(toolName: String)
    case missingAdmissionClassification(toolName: String)
}

package struct MCPDomainPreAdmissionDecision: Equatable, Sendable {
    package let admissionClass: MCPToolAdmissionClass

    package init(admissionClass: MCPToolAdmissionClass) {
        self.admissionClass = admissionClass
    }
}

package extension MCPDomainHost {
    /// Profile-policy exceptions backed by exact live link authority or eligible incarnation opt-in.
    ///
    /// Being the target of an oversight link grants no outbound observer authority, but it does make
    /// `agent_session_link` reachable for self-scoped and inverse operations. The operation service
    /// still authorizes those directions independently. No other tool, static additional grant, or
    /// profile restriction inherits this exception.
    private static func oversightReachabilityOverridesProfilePolicy(
        toolName: String,
        policy: MCPDomainClientPolicySnapshot
    ) -> Bool {
        (
            toolName == MCPWindowToolName.agentSessionLink
                && (policy.hasExactAgentSessionLinkGrant || policy.hasActivatedOverseer)
        )
            || (toolName == MCPWindowToolName.becomeOverseer && policy.canBecomeOverseer)
    }

    /// Capabilities whose role advertisement policy is also enforced at `tools/call` admission.
    package static let executionRoleGatedCapabilities: Set<MCPToolCapability> = [
        .agentExploreControl,
        .agentExternalControl,
        .agentSessionLinkControl,
    ]

    package func advertisedCatalog(
        _ request: MCPDomainCatalogAdvertisementRequest
    ) async -> MCPDomainCatalogAdvertisementResult {
        guard request.isGloballyEnabled else {
            return MCPDomainCatalogAdvertisementResult(
                definitions: [],
                hiddenReasonsByToolName: [:]
            )
        }

        let catalog = await registry.snapshot()
        var visible: [MCPDomainToolDefinition] = []
        var hidden: [String: MCPDomainCatalogHiddenReason] = [:]
        visible.reserveCapacity(catalog.definitions.count)

        for definition in catalog.definitions {
            let toolName = definition.name
            if toolName == MCPWindowToolName.becomeOverseer, !request.policy.canBecomeOverseer {
                hidden[toolName] = .missingAdditionalToolGrant
                continue
            }
            if request.disabledToolNames.contains(toolName)
                || (toolName == MCPWindowToolName.becomeOverseer && request.disabledToolNames.contains(MCPWindowToolName.agentSessionLink))
            {
                hidden[toolName] = .disabled
                continue
            }
            let reachabilityOverride = Self.oversightReachabilityOverridesProfilePolicy(
                toolName: toolName,
                policy: request.policy
            )
            if request.policy.restrictedToolNames.contains(toolName), !reachabilityOverride {
                hidden[toolName] = .restricted
                continue
            }
            if MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName),
               !request.policy.additionalToolNames.contains(toolName),
               !reachabilityOverride
            {
                hidden[toolName] = .missingAdditionalToolGrant
                continue
            }
            if !reachabilityOverride,
               !MCPClientToolPolicyCatalog.shouldAdvertise(
                   toolName: toolName,
                   role: request.policy.role,
                   allowsAgentExternalControlTools: request.policy.allowsAgentExternalControlTools
               )
            {
                hidden[toolName] = .roleAdvertisementPolicy
                continue
            }
            let surface: AgentSessionLinkToolSurface = request.policy.hasActivatedOverseer ? .full : request.agentSessionLinkSurface
            visible.append(surface.project(definition))
        }

        return MCPDomainCatalogAdvertisementResult(
            definitions: visible,
            hiddenReasonsByToolName: hidden
        )
    }

    private static func requireBootstrapAdmission(toolName: String, policy: MCPDomainClientPolicySnapshot) throws {
        if toolName == MCPWindowToolName.becomeOverseer, !policy.canBecomeOverseer {
            throw MCPDomainCallPolicyDenial.missingAdditionalGrant(toolName: toolName)
        }
    }

    func evaluateEarlyCallPolicy(
        toolName: String,
        policy: MCPDomainClientPolicySnapshot
    ) throws {
        try Self.requireBootstrapAdmission(toolName: toolName, policy: policy)
        if MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName),
           !policy.additionalToolNames.contains(toolName),
           !Self.oversightReachabilityOverridesProfilePolicy(toolName: toolName, policy: policy)
        {
            throw MCPDomainCallPolicyDenial.missingAdditionalGrant(toolName: toolName)
        }
    }

    package func evaluatePreAdmissionCallPolicy(
        toolName: String,
        policy: MCPDomainClientPolicySnapshot
    ) throws -> MCPDomainPreAdmissionDecision {
        try Self.requireBootstrapAdmission(toolName: toolName, policy: policy)
        guard MCPDomainToolCatalog.entry(named: toolName) != nil else {
            throw MCPDomainCallPolicyDenial.unknownTool(toolName: toolName)
        }
        let reachabilityOverride = Self.oversightReachabilityOverridesProfilePolicy(
            toolName: toolName,
            policy: policy
        )
        if policy.restrictedToolNames.contains(toolName), !reachabilityOverride {
            throw MCPDomainCallPolicyDenial.restricted(toolName: toolName)
        }
        // Advertisement is never authority: a hidden tool stays callable by name unless execution
        // mirrors the role filter. Both agent-control capability families are gated here so a
        // non-orchestrator agent cannot reach `agent_run` / `agent_manage` simply by naming them.
        // Exact-link and incarnation opt-in exceptions affect only the oversight family; its service
        // continues to enforce outbound versus inverse operation authority on every call.
        let capabilities = MCPDomainToolCatalog.capabilities(for: toolName)
        if !reachabilityOverride,
           !capabilities.isDisjoint(with: Self.executionRoleGatedCapabilities),
           !MCPClientToolPolicyCatalog.shouldAdvertise(
               toolName: toolName,
               role: policy.role,
               allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools
           )
        {
            throw MCPDomainCallPolicyDenial.roleUnavailable(toolName: toolName)
        }
        guard let admissionClass = MCPDomainToolCatalog.admissionClass(for: toolName) else {
            throw MCPDomainCallPolicyDenial.missingAdmissionClassification(toolName: toolName)
        }
        return MCPDomainPreAdmissionDecision(admissionClass: admissionClass)
    }
}
