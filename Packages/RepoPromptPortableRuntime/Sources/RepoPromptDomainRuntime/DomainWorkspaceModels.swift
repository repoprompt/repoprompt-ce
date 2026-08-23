#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

public enum DomainWorkspaceStoragePath {
    public static func directoryName(name: String, id: UUID) -> String {
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Workspace-\(safeName)-\(id.uuidString)"
    }
}

public struct DomainContextIdentity: Codable, Hashable, Sendable {
    public let workspaceID: UUID
    public let contextID: UUID

    public init(workspaceID: UUID, contextID: UUID) {
        self.workspaceID = workspaceID
        self.contextID = contextID
    }
}

public struct DomainRevisionState: Codable, Equatable, Sendable {
    public let workingRevision: UInt64
    public let savedRevision: UInt64
    public let dirtyRevision: UInt64?

    public init(workingRevision: UInt64, savedRevision: UInt64, dirtyRevision: UInt64?) {
        self.workingRevision = workingRevision
        self.savedRevision = savedRevision
        self.dirtyRevision = dirtyRevision
    }

    public static let initial = DomainRevisionState(
        workingRevision: 0,
        savedRevision: 0,
        dirtyRevision: nil
    )
}

public enum DomainAuthorityHealth: Codable, Equatable, Sendable {
    case writable
    case externalConflict(reason: String)
    case degradedReadOnly(reason: String)
    case removed

    public var acceptsMutations: Bool {
        if case .writable = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .writable:
            nil
        case let .externalConflict(reason), let .degradedReadOnly(reason):
            reason
        case .removed:
            "workspace_removed"
        }
    }
}

public enum DomainWorkspaceTabLocation: String, Codable, Equatable, Hashable, Sendable {
    case composed
    case stashed
}

public struct DomainProtectedAgentIdentity: Codable, Equatable, Hashable, Sendable {
    public let tabID: UUID
    public let location: DomainWorkspaceTabLocation
    public let activeAgentSessionID: UUID?
    public let isPinned: Bool

    public init(
        tabID: UUID,
        location: DomainWorkspaceTabLocation,
        activeAgentSessionID: UUID?,
        isPinned: Bool
    ) {
        self.tabID = tabID
        self.location = location
        self.activeAgentSessionID = activeAgentSessionID
        self.isPinned = isPinned
    }

    public var requiresProtection: Bool {
        activeAgentSessionID != nil || isPinned
    }
}

public struct DomainContextMetadata: Codable, Equatable, Sendable {
    public let identity: DomainContextIdentity
    public let name: String
    public let activeAgentSessionID: UUID?
    public let activeChatSessionID: UUID?
    public let documentBytes: Data
    public let contentDigest: String

    public init(
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

public struct DomainWorkspaceMetadata: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let schemaVersion: Int
    public let name: String
    public let repoPaths: [String]
    public let customStoragePath: URL?
    public let isSystemWorkspace: Bool
    public let isHiddenInMenus: Bool
    public let isEphemeral: Bool
    public let activeContextID: UUID?
    public let contexts: [DomainContextMetadata]
    public let agentIdentityClaims: [DomainProtectedAgentIdentity]

    public init(
        workspaceID: UUID,
        schemaVersion: Int,
        name: String,
        repoPaths: [String],
        customStoragePath: URL?,
        isSystemWorkspace: Bool,
        isHiddenInMenus: Bool,
        isEphemeral: Bool,
        activeContextID: UUID?,
        contexts: [DomainContextMetadata],
        agentIdentityClaims: [DomainProtectedAgentIdentity] = []
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
        self.agentIdentityClaims = agentIdentityClaims
    }
}

public struct DomainWorkspaceDocument: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let fileURL: URL
    public let documentBytes: Data
    public let contentDigest: String
    public let metadata: DomainWorkspaceMetadata

    public init(workspaceID: UUID, fileURL: URL, documentBytes: Data, metadata: DomainWorkspaceMetadata) {
        self.workspaceID = workspaceID
        self.fileURL = fileURL
        self.documentBytes = documentBytes
        contentDigest = DomainContentDigest.sha256(documentBytes)
        self.metadata = metadata
    }

    public static func decode(documentBytes: Data, fileURL: URL) throws -> DomainWorkspaceDocument {
        let metadata = try DomainWorkspaceDocumentDecoder.decodeMetadata(from: documentBytes)
        return DomainWorkspaceDocument(
            workspaceID: metadata.workspaceID,
            fileURL: fileURL,
            documentBytes: documentBytes,
            metadata: metadata
        )
    }
}

public struct DomainContextSnapshot: Codable, Equatable, Sendable {
    public let metadata: DomainContextMetadata
    public let revisions: DomainRevisionState
    public let health: DomainAuthorityHealth
}

public struct DomainWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let document: DomainWorkspaceDocument
    public let revisions: DomainRevisionState
    public let health: DomainAuthorityHealth
    public let contexts: [DomainContextSnapshot]
}

public struct DomainWorkspaceCatalogSnapshot: Equatable, Sendable {
    public let runtimeIdentity: DomainRuntimeIdentity
    public let isBootstrapped: Bool
    public let publicationSequence: UInt64
    public let catalogRevision: UInt64
    public let health: DomainAuthorityHealth
    public let workspaces: [DomainWorkspaceSnapshot]

    public init(
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

public enum DomainWorkspaceEventKind: String, Codable, Sendable {
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

public struct DomainWorkspaceEvent: Codable, Equatable, Sendable {
    public let runtimeID: UUID
    public let sequence: UInt64
    public let catalogRevision: UInt64
    public let kind: DomainWorkspaceEventKind
    public let workspaceID: UUID?
    public let contextID: UUID?
    public let operationID: UUID?
    public let origin: DomainCommandOrigin?
    public let revisions: DomainRevisionState?
    public let timestamp: Date
    public let diagnostic: String?
}

public struct DomainWorkspaceSnapshotSubscription: Sendable {
    public let snapshot: DomainWorkspaceCatalogSnapshot
    public let events: AsyncStream<DomainWorkspaceEvent>
}

public enum DomainWorkspaceDocumentError: Error, Equatable {
    case invalidTopLevel
    case missingWorkspaceID
    case futureSchema(Int)
    case invalidContext(UUID?)
}

public enum DomainContentDigest {
    public static func sha256(_ data: Data) -> String {
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
        var agentIdentityClaims: [DomainProtectedAgentIdentity] = []
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
            agentIdentityClaims.append(DomainProtectedAgentIdentity(
                tabID: contextID,
                location: .composed,
                activeAgentSessionID: (context["activeAgentSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                isPinned: context["isPinned"] as? Bool ?? false
            ))
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
        // WorkspaceModel treats stashed tabs as recoverable compatibility data: malformed arrays
        // decode as empty and composed/stashed ID collisions are removed during normalization.
        // Mirror that behavior for identity claims instead of making the whole workspace unreadable.
        for raw in (object["stashedTabs"] as? [Any]) ?? [] {
            guard let stashed = raw as? [String: Any],
                  let tab = stashed["tab"] as? [String: Any],
                  let tabIDString = tab["id"] as? String,
                  let tabID = UUID(uuidString: tabIDString),
                  contextIDs.insert(tabID).inserted
            else { continue }
            agentIdentityClaims.append(DomainProtectedAgentIdentity(
                tabID: tabID,
                location: .stashed,
                activeAgentSessionID: (tab["activeAgentSessionID"] as? String).flatMap(UUID.init(uuidString:)),
                isPinned: tab["isPinned"] as? Bool ?? false
            ))
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
            contexts: contexts,
            agentIdentityClaims: agentIdentityClaims
        )
    }
}
