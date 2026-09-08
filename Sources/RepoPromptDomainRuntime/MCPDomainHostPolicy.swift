import Foundation

package struct MCPDomainClientPolicySnapshot: Equatable, Sendable {
    package let restrictedToolNames: Set<String>
    package let additionalToolNames: Set<String>
    package let role: MCPClientTaskRole
    package let allowsAgentExternalControlTools: Bool
    /// Whether server-owned routing resolved this connection to an exact endpoint that currently has
    /// an Agent-session link in either direction. This is intentionally narrower than an additional
    /// tool grant: only this live authority fact may override profile/role hiding for
    /// `agent_session_link`, so a policy-supplied grant cannot manufacture the override.
    package let hasExactAgentSessionLinkGrant: Bool

    package init(
        restrictedToolNames: Set<String>,
        additionalToolNames: Set<String>,
        role: MCPClientTaskRole,
        allowsAgentExternalControlTools: Bool,
        hasExactAgentSessionLinkGrant: Bool = false
    ) {
        self.restrictedToolNames = restrictedToolNames
        self.additionalToolNames = additionalToolNames
        self.role = role
        self.allowsAgentExternalControlTools = allowsAgentExternalControlTools
        self.hasExactAgentSessionLinkGrant = hasExactAgentSessionLinkGrant
    }
}

package struct MCPDomainCatalogAdvertisementRequest: Sendable {
    package let isGloballyEnabled: Bool
    package let disabledToolNames: Set<String>
    package let policy: MCPDomainClientPolicySnapshot

    package init(
        isGloballyEnabled: Bool,
        disabledToolNames: Set<String>,
        policy: MCPDomainClientPolicySnapshot
    ) {
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

extension MCPDomainHost {
    /// The one profile-policy exception backed by live, exact domain authority.
    ///
    /// Being the target of an oversight link grants no outbound observer authority, but it does make
    /// `agent_session_link` reachable for self-scoped and inverse operations. The operation service
    /// still authorizes those directions independently. No other tool, static additional grant, or
    /// profile restriction inherits this exception.
    private static func exactLinkGrantOverridesProfilePolicy(
        toolName: String,
        policy: MCPDomainClientPolicySnapshot
    ) -> Bool {
        toolName == MCPWindowToolName.agentSessionLink
            && policy.hasExactAgentSessionLinkGrant
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
            if request.disabledToolNames.contains(toolName) {
                hidden[toolName] = .disabled
                continue
            }
            let exactLinkOverride = Self.exactLinkGrantOverridesProfilePolicy(
                toolName: toolName,
                policy: request.policy
            )
            if request.policy.restrictedToolNames.contains(toolName), !exactLinkOverride {
                hidden[toolName] = .restricted
                continue
            }
            if MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName),
               !request.policy.additionalToolNames.contains(toolName),
               !exactLinkOverride
            {
                hidden[toolName] = .missingAdditionalToolGrant
                continue
            }
            if !exactLinkOverride,
               !MCPClientToolPolicyCatalog.shouldAdvertise(
                   toolName: toolName,
                   role: request.policy.role,
                   allowsAgentExternalControlTools: request.policy.allowsAgentExternalControlTools
               )
            {
                hidden[toolName] = .roleAdvertisementPolicy
                continue
            }
            visible.append(definition)
        }

        return MCPDomainCatalogAdvertisementResult(
            definitions: visible,
            hiddenReasonsByToolName: hidden
        )
    }

    package func evaluateEarlyCallPolicy(
        toolName: String,
        policy: MCPDomainClientPolicySnapshot
    ) throws {
        if MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName),
           !policy.additionalToolNames.contains(toolName),
           !Self.exactLinkGrantOverridesProfilePolicy(toolName: toolName, policy: policy)
        {
            throw MCPDomainCallPolicyDenial.missingAdditionalGrant(toolName: toolName)
        }
    }

    package func evaluatePreAdmissionCallPolicy(
        toolName: String,
        policy: MCPDomainClientPolicySnapshot
    ) throws -> MCPDomainPreAdmissionDecision {
        guard MCPDomainToolCatalog.entry(named: toolName) != nil else {
            throw MCPDomainCallPolicyDenial.unknownTool(toolName: toolName)
        }
        let exactLinkOverride = Self.exactLinkGrantOverridesProfilePolicy(
            toolName: toolName,
            policy: policy
        )
        if policy.restrictedToolNames.contains(toolName), !exactLinkOverride {
            throw MCPDomainCallPolicyDenial.restricted(toolName: toolName)
        }
        // Advertisement is never authority: a hidden tool stays callable by name unless execution
        // mirrors the role filter. Both agent-control capability families are gated here so a
        // non-orchestrator agent cannot reach `agent_run` / `agent_manage` simply by naming them.
        // The exact-link exception above affects only agent_session_link reachability; its service
        // continues to enforce outbound versus inverse operation authority on every call.
        let capabilities = MCPDomainToolCatalog.capabilities(for: toolName)
        if !exactLinkOverride,
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
