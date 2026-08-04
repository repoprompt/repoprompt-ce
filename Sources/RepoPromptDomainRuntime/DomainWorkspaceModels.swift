import CryptoKit
import Foundation

package enum DomainWorkspaceStoragePath {
    package static func directoryName(name: String, id: UUID) -> String {
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Workspace-\(safeName)-\(id.uuidString)"
    }
}

package struct DomainContextIdentity: Codable, Hashable {
    package let workspaceID: UUID
    package let contextID: UUID

    package init(workspaceID: UUID, contextID: UUID) {
        self.workspaceID = workspaceID
        self.contextID = contextID
    }
}

package struct DomainRevisionState: Codable, Equatable {
    package let workingRevision: UInt64
    package let savedRevision: UInt64
    package let dirtyRevision: UInt64?

    package init(workingRevision: UInt64, savedRevision: UInt64, dirtyRevision: UInt64?) {
        self.workingRevision = workingRevision
        self.savedRevision = savedRevision
        self.dirtyRevision = dirtyRevision
    }

    package static let initial = DomainRevisionState(
        workingRevision: 0,
        savedRevision: 0,
        dirtyRevision: nil
    )
}

package enum DomainAuthorityHealth: Codable, Equatable {
    case writable
    case externalConflict(reason: String)
    case degradedReadOnly(reason: String)
    case removed

    package var acceptsMutations: Bool {
        if case .writable = self { return true }
        return false
    }
}

package struct DomainContextMetadata: Codable, Equatable {
    package let identity: DomainContextIdentity
    package let name: String
    package let activeAgentSessionID: UUID?
    package let activeChatSessionID: UUID?
    package let documentBytes: Data
    package let contentDigest: String

    package init(
        identity: DomainContextIdentity,
        name: String,
        activeAgentSessionID: UUID?,
        activeChatSessionID: UUID?,
        documentBytes: Data,
        contentDigest: String
    ) {
        self.identity = identity
        self.name = name
        self.activeAgentSessionID = activeAgentSessionID
        self.activeChatSessionID = activeChatSessionID
        self.documentBytes = documentBytes
        self.contentDigest = contentDigest
    }
}

package struct DomainWorkspaceMetadata: Codable, Equatable {
    package let workspaceID: UUID
    package let schemaVersion: Int
    package let name: String
    package let repoPaths: [String]
    package let customStoragePath: URL?
    package let isSystemWorkspace: Bool
    package let isHiddenInMenus: Bool
    package let isEphemeral: Bool
    package let activeContextID: UUID?
    package let contexts: [DomainContextMetadata]

    package init(
        workspaceID: UUID,
        schemaVersion: Int,
        name: String,
        repoPaths: [String],
        customStoragePath: URL?,
        isSystemWorkspace: Bool,
        isHiddenInMenus: Bool,
        isEphemeral: Bool,
        activeContextID: UUID?,
        contexts: [DomainContextMetadata]
    ) {
        self.workspaceID = workspaceID
        self.schemaVersion = schemaVersion
        self.name = name
        self.repoPaths = repoPaths
        self.customStoragePath = customStoragePath
        self.isSystemWorkspace = isSystemWorkspace
        self.isHiddenInMenus = isHiddenInMenus
        self.isEphemeral = isEphemeral
        self.activeContextID = activeContextID
        self.contexts = contexts
    }
}

package struct DomainWorkspaceDocument: Codable, Equatable {
    package let workspaceID: UUID
    package let fileURL: URL
    package let documentBytes: Data
    package let contentDigest: String
    package let metadata: DomainWorkspaceMetadata

    package init(workspaceID: UUID, fileURL: URL, documentBytes: Data, metadata: DomainWorkspaceMetadata) {
        self.workspaceID = workspaceID
        self.fileURL = fileURL
        self.documentBytes = documentBytes
        contentDigest = DomainContentDigest.sha256(documentBytes)
        self.metadata = metadata
    }

    package static func decode(documentBytes: Data, fileURL: URL) throws -> DomainWorkspaceDocument {
        let metadata = try DomainWorkspaceDocumentDecoder.decodeMetadata(from: documentBytes)
        return DomainWorkspaceDocument(
            workspaceID: metadata.workspaceID,
            fileURL: fileURL,
            documentBytes: documentBytes,
            metadata: metadata
        )
    }
}

package struct DomainContextSnapshot: Codable, Equatable {
    package let metadata: DomainContextMetadata
    package let revisions: DomainRevisionState
    package let health: DomainAuthorityHealth
}

package struct DomainWorkspaceSnapshot: Codable, Equatable {
    package let document: DomainWorkspaceDocument
    package let revisions: DomainRevisionState
    package let health: DomainAuthorityHealth
    package let contexts: [DomainContextSnapshot]
}

package struct DomainWorkspaceCatalogSnapshot: Equatable {
    package let runtimeIdentity: DomainRuntimeIdentity
    package let isBootstrapped: Bool
    package let publicationSequence: UInt64
    package let catalogRevision: UInt64
    package let health: DomainAuthorityHealth
    package let workspaces: [DomainWorkspaceSnapshot]

    package init(
        runtimeIdentity: DomainRuntimeIdentity,
        isBootstrapped: Bool,
        publicationSequence: UInt64,
        catalogRevision: UInt64,
        health: DomainAuthorityHealth,
        workspaces: [DomainWorkspaceSnapshot]
    ) {
        self.runtimeIdentity = runtimeIdentity
        self.isBootstrapped = isBootstrapped
        self.publicationSequence = publicationSequence
        self.catalogRevision = catalogRevision
        self.health = health
        self.workspaces = workspaces
    }
}

package enum DomainWorkspaceEventKind: String, Codable {
    case bootstrapped
    case workspaceCreated
    case workspaceDeleted
    case workingStateCommitted
    case savedDocumentCommitted
    case externalReloaded
    case externalConflict
    case degraded
    case routingChanged
    case operationDeduplicated
}

package struct DomainWorkspaceEvent: Codable, Equatable {
    package let runtimeID: UUID
    package let sequence: UInt64
    package let catalogRevision: UInt64
    package let kind: DomainWorkspaceEventKind
    package let workspaceID: UUID?
    package let contextID: UUID?
    package let operationID: UUID?
    package let origin: DomainCommandOrigin?
    package let revisions: DomainRevisionState?
    package let timestamp: Date
    package let diagnostic: String?
}

package struct DomainWorkspaceSnapshotSubscription {
    package let snapshot: DomainWorkspaceCatalogSnapshot
    package let events: AsyncStream<DomainWorkspaceEvent>
}

package enum DomainWorkspaceDocumentError: Error, Equatable {
    case invalidTopLevel
    case missingWorkspaceID
    case futureSchema(Int)
    case invalidContext(UUID?)
}

package enum DomainContentDigest {
    package static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum DomainWorkspaceDocumentDecoder {
    static let maximumSupportedSchemaVersion = 1

    static func decodeMetadata(from data: Data) throws -> DomainWorkspaceMetadata {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DomainWorkspaceDocumentError.invalidTopLevel
        }
        guard let idString = object["id"] as? String, let workspaceID = UUID(uuidString: idString) else {
            throw DomainWorkspaceDocumentError.missingWorkspaceID
        }
        let schemaVersion = (object["schemaVersion"] as? NSNumber)?.intValue ?? 1
        guard schemaVersion <= maximumSupportedSchemaVersion else {
            throw DomainWorkspaceDocumentError.futureSchema(schemaVersion)
        }
        var contextIDs = Set<UUID>()
        let contexts = try ((object["composeTabs"] as? [Any]) ?? []).map { raw -> DomainContextMetadata in
            guard let context = raw as? [String: Any],
                  let contextIDString = context["id"] as? String,
                  let contextID = UUID(uuidString: contextIDString)
            else {
                throw DomainWorkspaceDocumentError.invalidContext(nil)
            }
            guard contextIDs.insert(contextID).inserted else {
                throw DomainWorkspaceDocumentError.invalidContext(contextID)
            }
            let bytes = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
            return DomainContextMetadata(
                identity: DomainContextIdentity(workspaceID: workspaceID, contextID: contextID),
                name: context["name"] as? String ?? "Untitled",
                activeAgentSessionID: (context["activeAgentSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                activeChatSessionID: (context["activeChatSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                documentBytes: bytes,
                contentDigest: DomainContentDigest.sha256(bytes)
            )
        }
        let customStoragePath: URL? = if let raw = object["customStoragePath"] as? String {
            URL(string: raw) ?? URL(fileURLWithPath: raw)
        } else {
            nil
        }
        return DomainWorkspaceMetadata(
            workspaceID: workspaceID,
            schemaVersion: schemaVersion,
            name: object["name"] as? String ?? "Untitled Workspace",
            repoPaths: object["repoPaths"] as? [String] ?? [],
            customStoragePath: customStoragePath,
            isSystemWorkspace: object["isSystemWorkspace"] as? Bool ?? false,
            isHiddenInMenus: object["isHiddenInMenus"] as? Bool ?? false,
            isEphemeral: object["ephemeralFlag"] as? Bool ?? false,
            activeContextID: (object["activeComposeTabID"] as? String).flatMap(UUID.init(uuidString:)),
            contexts: contexts
        )
    }
}
