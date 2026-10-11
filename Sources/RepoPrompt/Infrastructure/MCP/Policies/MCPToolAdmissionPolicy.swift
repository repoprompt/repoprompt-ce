import Foundation
import MCP
import RepoPromptDomainRuntime

typealias MCPToolAdmissionClass = RepoPromptDomainRuntime.MCPToolAdmissionClass
typealias MCPToolOperationIdentity = RepoPromptDomainRuntime.MCPDomainToolOperationIdentity
// These are the domain owners' values, not a second admission or terminal-settlement model.
typealias MCPToolAdmissionDecision = RepoPromptDomainRuntime.MCPDomainPreAdmissionDecision
typealias MCPToolSettlementResult = RepoPromptDomainRuntime.MCPToolExecutionSettlement

extension MCPToolAdmissionClass {
    var connectionLane: MCPConnectionCallLane {
        switch self {
        case .exclusive:
            .ordinary
        case .control:
            .control
        case .smallRead:
            .smallRead
        case .fileRead:
            .fileRead
        case .gitRead:
            .gitRead
        case .fileSearch:
            .fileSearch
        }
    }
}

enum MCPToolAdmissionPolicy {
    static func clientPolicySnapshot(
        restricted: Set<String>,
        additional: Set<String>,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        allowsAgentExternalControlTools: Bool,
        hasExactAgentSessionLinkGrant: Bool = false,
        canBecomeOverseer: Bool = false,
        hasActivatedOverseer: Bool = false
    ) -> MCPDomainClientPolicySnapshot {
        let role: MCPClientTaskRole = switch taskLabelKind {
        case .explore:
            .explore
        case .engineer, .pair, .design:
            .engineer
        case nil:
            .direct
        }
        return MCPDomainClientPolicySnapshot(
            restrictedToolNames: restricted,
            additionalToolNames: additional,
            role: role,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            hasExactAgentSessionLinkGrant: hasExactAgentSessionLinkGrant,
            canBecomeOverseer: canBecomeOverseer,
            hasActivatedOverseer: hasActivatedOverseer
        )
    }

    /// Keep app-host admission aligned with the package-level domain limits.
    static let exclusiveConnectionLimit = MCPDomainToolAdmissionLimits.exclusiveConnection
    static let controlConnectionLimit = MCPDomainToolAdmissionLimits.controlConnection
    static let smallReadConnectionLimit = MCPDomainToolAdmissionLimits.smallReadConnection
    static let smallReadPerWindowLimit = MCPDomainToolAdmissionLimits.smallReadPerWindow
    static let fileReadConnectionLimit = MCPDomainToolAdmissionLimits.fileReadConnection
    static let fileReadPerWindowLimit = MCPDomainToolAdmissionLimits.fileReadPerWindow
    static let gitReadConnectionLimit = MCPDomainToolAdmissionLimits.gitReadConnection
    static let fileSearchConnectionLimit = MCPDomainToolAdmissionLimits.fileSearchConnection
    static let gitReadPerRepositoryLimit = MCPDomainToolAdmissionLimits.gitReadPerRepository

    static let classifications = MCPDomainToolCatalog.classifications

    static func classification(forCanonicalToolName toolName: String) -> MCPToolAdmissionClass? {
        MCPDomainToolCatalog.admissionClass(for: toolName)
    }

    static func operationIdentity(
        forCanonicalToolName toolName: String,
        arguments: [String: Value]
    ) -> MCPToolOperationIdentity {
        let input: MCPDomainToolOperationInput = if let argumentKey = MCPDomainToolCatalog.operationArgumentKey(for: toolName),
                                                    let value = arguments[argumentKey]
        {
            value.stringValue.map(MCPDomainToolOperationInput.value) ?? .malformed
        } else {
            .missing
        }
        return MCPDomainToolCatalog.operationIdentity(for: toolName, input: input)
    }
}
