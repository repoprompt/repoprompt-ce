import Foundation

package struct DomainHeadlessMutationGrant: Codable, Hashable, Identifiable, Sendable {
    package let id: UUID
    package let principalKey: String
    package let allowedOperations: Set<String>
    package let workspaceIDs: Set<UUID>
    package let canonicalRoots: Set<String>
    package let provider: String?
    package let issuedAt: Date
    package let expiresAt: Date
    package let revokedAt: Date?
    package let revision: UInt64

    package init(
        id: UUID = UUID(),
        principalKey: String,
        allowedOperations: Set<String>,
        workspaceIDs: Set<UUID> = [],
        canonicalRoots: Set<String> = [],
        provider: String? = nil,
        issuedAt: Date = Date(),
        expiresAt: Date,
        revokedAt: Date? = nil,
        revision: UInt64 = 1
    ) {
        self.id = id
        self.principalKey = principalKey
        self.allowedOperations = allowedOperations
        self.workspaceIDs = workspaceIDs
        self.canonicalRoots = canonicalRoots
        self.provider = provider
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.revision = revision
    }

    package func revoking(at date: Date) -> Self {
        Self(
            id: id,
            principalKey: principalKey,
            allowedOperations: allowedOperations,
            workspaceIDs: workspaceIDs,
            canonicalRoots: canonicalRoots,
            provider: provider,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            revokedAt: date,
            revision: revision &+ 1
        )
    }
}

package struct DomainMutationPolicyDocument: Codable, Hashable, Sendable {
    package static let schemaVersion = 2
    package static let legacySchemaVersion = 1

    package let version: Int
    package let profileIdentifier: String
    package let revision: UInt64
    package let headlessGrants: [DomainHeadlessMutationGrant]
    package let updatedAt: Date

    package init(
        version: Int = Self.schemaVersion,
        profileIdentifier: String,
        revision: UInt64,
        headlessGrants: [DomainHeadlessMutationGrant],
        updatedAt: Date
    ) {
        self.version = version
        self.profileIdentifier = profileIdentifier
        self.revision = revision
        self.headlessGrants = headlessGrants
        self.updatedAt = updatedAt
    }
}

package enum DomainMutationPolicyHealth: Hashable, Sendable {
    case ready
    case degradedReadOnly(reason: String)
}

package struct DomainMutationAuthorizationSnapshot: Hashable, Sendable {
    package let policyRevision: UInt64
    package let grantID: UUID?
    package let grantRevision: UInt64?
    package let operation: String
    package let canonicalRoots: Set<String>
}

package enum DomainMutationPolicyError: Error, Equatable, LocalizedError, Sendable {
    case principalMissing
    case principalUnverified
    case runtimeIdentityMismatch
    case routingContextUnavailable
    case grantMissing
    case grantExpired
    case grantRevoked
    case policyReadOnly(String)
    case policyRevisionConflict(expected: UInt64, actual: UInt64)
    case invalidGrant(String)
    case administratorTTYRequired

    package var errorDescription: String? {
        switch self {
        case .principalMissing:
            "Protected mutation denied because no client principal was installed."
        case .principalUnverified:
            "Protected mutation denied because the client principal is not verified."
        case .runtimeIdentityMismatch:
            "Protected mutation denied because the runtime generation changed."
        case .routingContextUnavailable:
            "Protected mutation denied because the connection has no authoritative routing registration."
        case .grantMissing:
            "Protected mutation denied because no active grant covers this operation."
        case .grantExpired:
            "Protected mutation denied because the matching grant expired."
        case .grantRevoked:
            "Protected mutation denied because the matching grant was revoked."
        case let .policyReadOnly(reason):
            "Protected mutations are read-only because the policy is unavailable (\(reason))."
        case let .policyRevisionConflict(expected, actual):
            "Protected mutation policy changed (expected revision \(expected), actual \(actual))."
        case let .invalidGrant(reason):
            "Invalid protected mutation grant: \(reason)"
        case .administratorTTYRequired:
            "Protected mutation grants may only be changed by a verified local TTY administrator."
        }
    }
}

package actor DomainMutationPolicyStore {
    private let persistence: DomainPersistenceCoordinator
    private let identity: DomainRuntimeIdentity
    private let profileIdentifier: String
    private var document: DomainMutationPolicyDocument
    private var documentDigest: String?
    private var health: DomainMutationPolicyHealth = .ready
    private var didBootstrap = false

    package init(
        persistence: DomainPersistenceCoordinator,
        identity: DomainRuntimeIdentity,
        profileIdentifier: String
    ) {
        self.persistence = persistence
        self.identity = identity
        self.profileIdentifier = profileIdentifier
        document = DomainMutationPolicyDocument(
            profileIdentifier: profileIdentifier,
            revision: 0,
            headlessGrants: [],
            updatedAt: identity.createdAt
        )
    }

    package func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await refreshFromPersistence()
    }

    package func snapshot() async -> (DomainMutationPolicyDocument, DomainMutationPolicyHealth) {
        if !didBootstrap { await bootstrap() } else { await refreshFromPersistence() }
        return (document, health)
    }

    package func authorize(
        context: DomainToolInvocationSecurityContext?,
        toolName: String,
        action: String,
        workspaceID: UUID? = nil,
        canonicalRoots: Set<String> = [],
        now: Date = Date()
    ) async throws -> DomainMutationAuthorizationSnapshot {
        if !didBootstrap { await bootstrap() } else { await refreshFromPersistence() }
        guard case .ready = health else {
            if case let .degradedReadOnly(reason) = health {
                throw DomainMutationPolicyError.policyReadOnly(reason)
            }
            throw DomainMutationPolicyError.policyReadOnly("unavailable")
        }
        guard let context else { throw DomainMutationPolicyError.principalMissing }
        guard context.runtimeID == identity.runtimeID,
              context.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw DomainMutationPolicyError.runtimeIdentityMismatch
        }
        guard context.principal.assurance != .displayNameOnly else {
            throw DomainMutationPolicyError.principalUnverified
        }

        let operation = "\(toolName).\(action)"
        if identity.mode == .app,
           context.principal.kind == .appProxy,
           context.principal.assurance == .verifiedProcess
        {
            return DomainMutationAuthorizationSnapshot(
                policyRevision: document.revision,
                grantID: nil,
                grantRevision: nil,
                operation: operation,
                canonicalRoots: canonicalRoots
            )
        }
        guard context.hasAuthoritativeRoutingContext else {
            throw DomainMutationPolicyError.routingContextUnavailable
        }
        let hasEphemeralGrant = context.ephemeralGrantedToolNames.contains(toolName)
            || context.ephemeralGrantedOperations.contains(operation)
        if context.principal.kind == .runScoped,
           hasEphemeralGrant,
           Self.roots(canonicalRoots, areCoveredBy: context.authorizedCanonicalRoots),
           context.principal.assurance == .verifiedProcess || context.principal.assurance == .hostLaunchToken
        {
            return DomainMutationAuthorizationSnapshot(
                policyRevision: document.revision,
                grantID: nil,
                grantRevision: nil,
                operation: operation,
                canonicalRoots: canonicalRoots
            )
        }

        guard let principalFingerprint = context.principal.verifiedIdentityFingerprint else {
            throw DomainMutationPolicyError.principalUnverified
        }
        let candidates = document.headlessGrants.filter { grant in
            guard grant.principalKey == principalFingerprint else { return false }
            guard grant.allowedOperations.contains(operation)
                || grant.allowedOperations.contains("\(toolName).*")
            else { return false }
            if let workspaceID, !grant.workspaceIDs.isEmpty, !grant.workspaceIDs.contains(workspaceID) {
                return false
            }
            if let provider = grant.provider, provider != context.principal.provider {
                return false
            }
            return Self.roots(canonicalRoots, areCoveredBy: grant.canonicalRoots)
        }
        guard let grant = candidates.first(where: { $0.revokedAt == nil && $0.expiresAt > now }) else {
            if candidates.contains(where: { $0.revokedAt != nil }) {
                throw DomainMutationPolicyError.grantRevoked
            }
            if candidates.contains(where: { $0.expiresAt <= now }) {
                throw DomainMutationPolicyError.grantExpired
            }
            throw DomainMutationPolicyError.grantMissing
        }
        return DomainMutationAuthorizationSnapshot(
            policyRevision: document.revision,
            grantID: grant.id,
            grantRevision: grant.revision,
            operation: operation,
            canonicalRoots: grant.canonicalRoots
        )
    }

    package func revalidate(
        _ snapshot: DomainMutationAuthorizationSnapshot,
        now: Date = Date()
    ) async throws {
        if !didBootstrap { await bootstrap() } else { await refreshFromPersistence() }
        guard case .ready = health else {
            throw DomainMutationPolicyError.policyReadOnly("policy_changed")
        }
        guard let grantID = snapshot.grantID else { return }
        guard let grant = document.headlessGrants.first(where: { $0.id == grantID }) else {
            throw DomainMutationPolicyError.grantMissing
        }
        guard grant.revokedAt == nil else { throw DomainMutationPolicyError.grantRevoked }
        guard grant.expiresAt > now else { throw DomainMutationPolicyError.grantExpired }
        guard grant.revision == snapshot.grantRevision else {
            throw DomainMutationPolicyError.grantRevoked
        }
    }

    @discardableResult
    package func addGrant(
        _ grant: DomainHeadlessMutationGrant,
        expectedRevision: UInt64?,
        administrator: DomainClientPrincipal
    ) async throws -> DomainMutationPolicyDocument {
        try validateAdministrator(administrator)
        try validateGrant(grant)
        if !didBootstrap { await bootstrap() } else { await refreshFromPersistence() }
        try requireWritable(expectedRevision: expectedRevision)
        guard !document.headlessGrants.contains(where: { $0.id == grant.id }) else {
            throw DomainMutationPolicyError.invalidGrant("duplicate grant id")
        }
        let grantToPersist = try canonicalizedGrant(grant)
        return try await persist(grants: document.headlessGrants + [grantToPersist])
    }

    @discardableResult
    package func revokeGrant(
        id: UUID,
        expectedRevision: UInt64?,
        administrator: DomainClientPrincipal,
        now: Date = Date()
    ) async throws -> DomainMutationPolicyDocument {
        try validateAdministrator(administrator)
        if !didBootstrap { await bootstrap() } else { await refreshFromPersistence() }
        try requireWritable(expectedRevision: expectedRevision)
        guard let index = document.headlessGrants.firstIndex(where: { $0.id == id }) else {
            throw DomainMutationPolicyError.invalidGrant("unknown grant id")
        }
        var grants = document.headlessGrants
        grants[index] = grants[index].revoking(at: now)
        return try await persist(grants: grants)
    }

    private static func roots(_ requested: Set<String>, areCoveredBy authorized: Set<String>) -> Bool {
        requested.allSatisfy { requestedRoot in
            guard let requested = DomainMutationPathFence.canonicalPath(requestedRoot) else {
                return false
            }
            return authorized.contains { authorizedRoot in
                requested == authorizedRoot || requested.hasPrefix(authorizedRoot.hasSuffix("/") ? authorizedRoot : authorizedRoot + "/")
            }
        }
    }

    private func validateAdministrator(_ principal: DomainClientPrincipal) throws {
        guard principal.kind == .ttyAdministrator,
              principal.assurance == .localTTY
        else {
            throw DomainMutationPolicyError.administratorTTYRequired
        }
    }

    private func validateGrant(_ grant: DomainHeadlessMutationGrant) throws {
        guard !grant.principalKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainMutationPolicyError.invalidGrant("verified principal fingerprint is empty")
        }
        guard !grant.allowedOperations.isEmpty else {
            throw DomainMutationPolicyError.invalidGrant("at least one tool.action is required")
        }
        guard grant.expiresAt > grant.issuedAt else {
            throw DomainMutationPolicyError.invalidGrant("expiry must be after issue time")
        }
        guard grant.allowedOperations.allSatisfy({ value in
            !value.contains(where: \.isWhitespace) && value.contains(".")
        }) else {
            throw DomainMutationPolicyError.invalidGrant("operations must use tool.action form")
        }
    }

    private func canonicalizedGrant(_ grant: DomainHeadlessMutationGrant) throws -> DomainHeadlessMutationGrant {
        let roots = try Set(grant.canonicalRoots.map { root in
            guard let canonical = DomainMutationPathFence.canonicalPath(root) else {
                throw DomainMutationPolicyError.invalidGrant("canonical roots must be absolute paths")
            }
            return canonical
        })
        return DomainHeadlessMutationGrant(
            id: grant.id,
            principalKey: grant.principalKey,
            allowedOperations: grant.allowedOperations,
            workspaceIDs: grant.workspaceIDs,
            canonicalRoots: roots,
            provider: grant.provider,
            issuedAt: grant.issuedAt,
            expiresAt: grant.expiresAt,
            revokedAt: grant.revokedAt,
            revision: grant.revision
        )
    }

    private func validateStoredDocument(_ document: DomainMutationPolicyDocument) throws {
        for grant in document.headlessGrants {
            try validateGrant(grant)
            guard grant.canonicalRoots.allSatisfy({ root in
                guard let canonical = DomainMutationPathFence.canonicalPath(root) else {
                    return false
                }
                return canonical == root
            }) else {
                throw DomainMutationPolicyError.invalidGrant("stored canonical roots are invalid")
            }
        }
    }

    private func migratedDocument(
        from legacy: DomainMutationPolicyDocument
    ) throws -> DomainMutationPolicyDocument {
        DomainMutationPolicyDocument(
            version: DomainMutationPolicyDocument.schemaVersion,
            profileIdentifier: legacy.profileIdentifier,
            revision: legacy.revision,
            headlessGrants: try legacy.headlessGrants.map { grant in
                try validateGrant(grant)
                return try canonicalizedGrant(grant)
            },
            updatedAt: legacy.updatedAt
        )
    }

    private func encodedDocument(_ document: DomainMutationPolicyDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    /// Reloads the versioned snapshot for every authorization/revalidation boundary so
    /// TTY policy administration and revocation are visible to already-running brokers.
    private func refreshFromPersistence() async {
        do {
            guard let data = try await persistence.loadProtectedMutationPolicyData() else {
                document = DomainMutationPolicyDocument(
                    profileIdentifier: profileIdentifier,
                    revision: 0,
                    headlessGrants: [],
                    updatedAt: identity.createdAt
                )
                documentDigest = nil
                health = .ready
                return
            }
            let digest = DomainContentDigest.sha256(data)
            guard digest != documentDigest else {
                health = .ready
                return
            }
            let decoded = try JSONDecoder().decode(DomainMutationPolicyDocument.self, from: data)
            guard decoded.profileIdentifier == profileIdentifier else {
                health = .degradedReadOnly(reason: "future_or_wrong_profile")
                return
            }
            if decoded.version == DomainMutationPolicyDocument.schemaVersion {
                try validateStoredDocument(decoded)
                document = decoded
                documentDigest = digest
                health = .ready
            } else if decoded.version == DomainMutationPolicyDocument.legacySchemaVersion {
                let migrated = try migratedDocument(from: decoded)
                let migratedData = try encodedDocument(migrated)
                do {
                    try await persistence.compareAndSwapProtectedMutationPolicyData(
                        expectedDigest: digest,
                        data: migratedData
                    )
                } catch DomainPersistenceError.externalDocumentConflict {
                    documentDigest = nil
                    health = .degradedReadOnly(reason: "policy_changed")
                    return
                }
                document = migrated
                documentDigest = DomainContentDigest.sha256(migratedData)
                health = .ready
            } else {
                health = .degradedReadOnly(reason: "future_or_wrong_profile")
            }
        } catch {
            health = .degradedReadOnly(reason: "corrupt_policy")
        }
    }

    private func requireWritable(expectedRevision: UInt64?) throws {
        if case let .degradedReadOnly(reason) = health {
            throw DomainMutationPolicyError.policyReadOnly(reason)
        }
        if let expectedRevision, expectedRevision != document.revision {
            throw DomainMutationPolicyError.policyRevisionConflict(
                expected: expectedRevision,
                actual: document.revision
            )
        }
    }

    private func persist(grants: [DomainHeadlessMutationGrant]) async throws -> DomainMutationPolicyDocument {
        let next = DomainMutationPolicyDocument(
            profileIdentifier: profileIdentifier,
            revision: document.revision &+ 1,
            headlessGrants: grants,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        do {
            try await persistence.compareAndSwapProtectedMutationPolicyData(
                expectedDigest: documentDigest,
                data: data
            )
        } catch DomainPersistenceError.externalDocumentConflict {
            await refreshFromPersistence()
            throw DomainMutationPolicyError.policyRevisionConflict(
                expected: next.revision &- 1,
                actual: document.revision
            )
        }
        document = next
        documentDigest = DomainContentDigest.sha256(data)
        return next
    }
}
