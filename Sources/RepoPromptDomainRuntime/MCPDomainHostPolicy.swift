import Foundation

package struct MCPDomainClientPolicySnapshot: Equatable, Sendable {
    package let restrictedToolNames: Set<String>
    package let additionalToolNames: Set<String>
    package let role: MCPClientTaskRole
    package let allowsAgentExternalControlTools: Bool

    package init(
        restrictedToolNames: Set<String>,
        additionalToolNames: Set<String>,
        role: MCPClientTaskRole,
        allowsAgentExternalControlTools: Bool
    ) {
        self.restrictedToolNames = restrictedToolNames
        self.additionalToolNames = additionalToolNames
        self.role = role
        self.allowsAgentExternalControlTools = allowsAgentExternalControlTools
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
            if request.policy.restrictedToolNames.contains(toolName) {
                hidden[toolName] = .restricted
                continue
            }
            if MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName),
               !request.policy.additionalToolNames.contains(toolName)
            {
                hidden[toolName] = .missingAdditionalToolGrant
                continue
            }
            if !MCPClientToolPolicyCatalog.shouldAdvertise(
                toolName: toolName,
                role: request.policy.role,
                allowsAgentExternalControlTools: request.policy.allowsAgentExternalControlTools
            ) {
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
           !policy.additionalToolNames.contains(toolName)
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
        if policy.restrictedToolNames.contains(toolName) {
            throw MCPDomainCallPolicyDenial.restricted(toolName: toolName)
        }
        if MCPDomainToolCatalog.capabilities(for: toolName).contains(.agentExploreControl),
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
