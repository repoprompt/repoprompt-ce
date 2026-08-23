import Foundation

public struct MCPDomainClientPolicySnapshot: Equatable, Sendable {
    public let restrictedToolNames: Set<String>
    public let additionalToolNames: Set<String>
    public let role: MCPClientTaskRole
    public let allowsAgentExternalControlTools: Bool

    public init(
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

public struct MCPDomainCatalogAdvertisementRequest: Sendable {
    public let isGloballyEnabled: Bool
    public let disabledToolNames: Set<String>
    public let policy: MCPDomainClientPolicySnapshot

    public init(
        isGloballyEnabled: Bool,
        disabledToolNames: Set<String>,
        policy: MCPDomainClientPolicySnapshot
    ) {
        self.isGloballyEnabled = isGloballyEnabled
        self.disabledToolNames = disabledToolNames
        self.policy = policy
    }
}

public enum MCPDomainCatalogHiddenReason: String, Equatable, Sendable {
    case disabled
    case restricted
    case missingAdditionalToolGrant = "missing_additional_tool_grant"
    case roleAdvertisementPolicy = "role_advertisement_policy"
}

public struct MCPDomainCatalogAdvertisementResult: Sendable {
    public let definitions: [MCPDomainToolDefinition]
    public let hiddenReasonsByToolName: [String: MCPDomainCatalogHiddenReason]

    public init(
        definitions: [MCPDomainToolDefinition],
        hiddenReasonsByToolName: [String: MCPDomainCatalogHiddenReason]
    ) {
        self.definitions = definitions
        self.hiddenReasonsByToolName = hiddenReasonsByToolName
    }
}

public enum MCPDomainCallPolicyDenial: Error, Equatable, Sendable {
    case missingAdditionalGrant(toolName: String)
    case restricted(toolName: String)
    case roleUnavailable(toolName: String)
    case unknownTool(toolName: String)
    case missingAdmissionClassification(toolName: String)
}

public struct MCPDomainPreAdmissionDecision: Equatable, Sendable {
    public let admissionClass: MCPToolAdmissionClass

    public init(admissionClass: MCPToolAdmissionClass) {
        self.admissionClass = admissionClass
    }
}

extension MCPDomainHost {
    public func advertisedCatalog(
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

    public func evaluateEarlyCallPolicy(
        toolName: String,
        policy: MCPDomainClientPolicySnapshot
    ) throws {
        if MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName),
           !policy.additionalToolNames.contains(toolName)
        {
            throw MCPDomainCallPolicyDenial.missingAdditionalGrant(toolName: toolName)
        }
    }

    public func evaluatePreAdmissionCallPolicy(
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
