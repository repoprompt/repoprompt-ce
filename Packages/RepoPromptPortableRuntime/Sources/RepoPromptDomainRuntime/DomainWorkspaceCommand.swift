import Foundation

public enum DomainCommandOrigin: Codable, Equatable, Sendable {
    case appPresentation(windowID: Int)
    case appMCP(connectionID: UUID?)
    case standalone
    case externalReload
}

private extension DomainCommandOrigin {
    var fingerprintComponent: String {
        switch self {
        case let .appPresentation(windowID): "presentation:\(windowID)"
        case let .appMCP(connectionID): "app-mcp:\(connectionID?.uuidString ?? "nil")"
        case .standalone: "standalone"
        case .externalReload: "external-reload"
        }
    }
}

public enum DomainWorkspaceCommand: Codable, Equatable, Sendable {
    case createWorkspace(DomainWorkspaceDocument)
    case replaceWorkingDocument(DomainWorkspaceDocument)
    case saveWorkspaceDocument(workspaceID: UUID)
    case deleteWorkspace(workspaceID: UUID)
    case resolveExternalConflict(
        workspaceID: UUID,
        acceptExternal: Bool,
        protectedAgentIdentities: [DomainProtectedAgentIdentity]
    )
}

public struct DomainWorkspaceCommandEnvelope: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let expectedCatalogRevision: UInt64?
    public let expectedWorkspaceRevision: UInt64?
    public let expectedContextRevision: UInt64?
    public let origin: DomainCommandOrigin
    public let command: DomainWorkspaceCommand

    public init(
        operationID: UUID,
        expectedCatalogRevision: UInt64? = nil,
        expectedWorkspaceRevision: UInt64? = nil,
        expectedContextRevision: UInt64? = nil,
        origin: DomainCommandOrigin,
        command: DomainWorkspaceCommand
    ) {
        self.operationID = operationID
        self.expectedCatalogRevision = expectedCatalogRevision
        self.expectedWorkspaceRevision = expectedWorkspaceRevision
        self.expectedContextRevision = expectedContextRevision
        self.origin = origin
        self.command = command
    }

    public var fingerprint: String {
        var components = [
            operationID.uuidString,
            expectedCatalogRevision.map(String.init) ?? "nil",
            expectedWorkspaceRevision.map(String.init) ?? "nil",
            expectedContextRevision.map(String.init) ?? "nil",
            origin.fingerprintComponent
        ]
        switch command {
        case let .createWorkspace(document):
            components += ["create", document.workspaceID.uuidString, document.fileURL.absoluteString, document.contentDigest]
        case let .replaceWorkingDocument(document):
            components += ["replace", document.workspaceID.uuidString, document.fileURL.absoluteString, document.contentDigest]
        case let .saveWorkspaceDocument(workspaceID):
            components += ["save", workspaceID.uuidString]
        case let .deleteWorkspace(workspaceID):
            components += ["delete", workspaceID.uuidString]
        case let .resolveExternalConflict(workspaceID, acceptExternal, protectedAgentIdentities):
            components += ["resolve", workspaceID.uuidString, acceptExternal ? "external" : "local"]
            components += protectedAgentIdentities
                .sorted {
                    if $0.location.rawValue != $1.location.rawValue {
                        return $0.location.rawValue < $1.location.rawValue
                    }
                    return $0.tabID.uuidString < $1.tabID.uuidString
                }
                .flatMap {
                    [
                        $0.location.rawValue,
                        $0.tabID.uuidString,
                        $0.activeAgentSessionID?.uuidString ?? "nil",
                        $0.isPinned ? "pinned" : "unpinned"
                    ]
                }
        }
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return DomainContentDigest.sha256(Data(canonical.utf8))
    }
}

public enum DomainCommandDisposition: String, Codable, Sendable {
    case applied
    case unchanged
    case conflict
    case readOnly
    case invalid
    case failed
    case deduplicated
}

public enum DomainCommandErrorCode: String, Codable, Sendable {
    case stateConflict = "state_conflict"
    case runtimeReadOnlyDegraded = "runtime_read_only_degraded"
    case workspaceExternalConflict = "workspace_external_conflict"
    case workspaceReadOnlyDegraded = "workspace_read_only_degraded"
    case protectedAgentIdentityConflict = "protected_agent_identity_conflict"
    case operationIDCollision = "operation_id_collision"
    case workspaceUnavailable = "workspace_unavailable"
    case invalidDocument = "invalid_document"
    case persistenceFailure = "persistence_failure"
    case lockTimedOut = "lock_timed_out"
    case cancelled
}

public struct DomainCommandOutcome: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let disposition: DomainCommandDisposition
    public let before: DomainRevisionState?
    public let after: DomainRevisionState?
    public let catalogRevision: UInt64
    public let resultingDigest: String?
    public let errorCode: DomainCommandErrorCode?
    public let diagnostic: String?
    public let workspace: DomainWorkspaceSnapshot?

    public init(
        operationID: UUID,
        disposition: DomainCommandDisposition,
        before: DomainRevisionState?,
        after: DomainRevisionState?,
        catalogRevision: UInt64,
        resultingDigest: String?,
        errorCode: DomainCommandErrorCode? = nil,
        diagnostic: String? = nil,
        workspace: DomainWorkspaceSnapshot? = nil
    ) {
        self.operationID = operationID
        self.disposition = disposition
        self.before = before
        self.after = after
        self.catalogRevision = catalogRevision
        self.resultingDigest = resultingDigest
        self.errorCode = errorCode
        self.diagnostic = diagnostic
        self.workspace = workspace
    }
}

struct DomainRecordedOperation: Codable, Equatable, Sendable {
    let operationID: UUID
    let fingerprint: String
    let recordedAt: Date
    let disposition: DomainCommandDisposition
    let before: DomainRevisionState?
    let after: DomainRevisionState?
    let catalogRevision: UInt64
    let resultingDigest: String?
    let errorCode: DomainCommandErrorCode?
    let diagnostic: String?

    init(fingerprint: String, recordedAt: Date, outcome: DomainCommandOutcome) {
        operationID = outcome.operationID
        self.fingerprint = fingerprint
        self.recordedAt = recordedAt
        disposition = outcome.disposition
        before = outcome.before
        after = outcome.after
        catalogRevision = outcome.catalogRevision
        resultingDigest = outcome.resultingDigest
        errorCode = outcome.errorCode
        diagnostic = outcome.diagnostic
    }

    func outcome(workspace: DomainWorkspaceSnapshot?) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: operationID,
            disposition: .deduplicated,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: resultingDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: workspace
        )
    }
}
