import Foundation
import RepoPromptDomainRuntime

typealias MCPToolAdmissionClass = RepoPromptDomainRuntime.MCPToolAdmissionClass

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
    static let exclusiveConnectionLimit = 1
    static let controlConnectionLimit = 8
    static let smallReadConnectionLimit = 2
    static let smallReadPerWindowLimit = 2
    static let gitReadConnectionLimit = 2
    static let fileSearchConnectionLimit = 4
    static let gitReadPerRepositoryLimit = 1

    static let classifications = MCPDomainToolCatalog.classifications

    static func classification(forCanonicalToolName toolName: String) -> MCPToolAdmissionClass? {
        MCPDomainToolCatalog.admissionClass(for: toolName)
    }
}
