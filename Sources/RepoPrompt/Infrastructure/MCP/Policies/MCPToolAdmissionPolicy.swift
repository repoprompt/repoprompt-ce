import Foundation
import MCP
import RepoPromptDomainRuntime

typealias MCPToolAdmissionClass = RepoPromptDomainRuntime.MCPToolAdmissionClass
typealias MCPToolOperationIdentity = RepoPromptDomainRuntime.MCPDomainToolOperationIdentity

extension MCPToolAdmissionClass {
    var connectionLane: MCPConnectionCallLane {
        switch self {
        case .exclusive:
            .ordinary
        case .control:
            .control
        case .smallRead:
            .smallRead
        case .gitRead:
            .gitRead
        case .fileSearch:
            .fileSearch
        }
    }
}

enum MCPToolAdmissionPolicy {
    /// Preserve the measured app-host lane limits; M1 moves classification authority only.
    static let exclusiveConnectionLimit = MCPDomainToolAdmissionLimits.exclusiveConnection
    static let controlConnectionLimit = MCPDomainToolAdmissionLimits.controlConnection
    static let smallReadConnectionLimit = MCPDomainToolAdmissionLimits.smallReadConnection
    static let smallReadPerWindowLimit = MCPDomainToolAdmissionLimits.smallReadPerWindow
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
