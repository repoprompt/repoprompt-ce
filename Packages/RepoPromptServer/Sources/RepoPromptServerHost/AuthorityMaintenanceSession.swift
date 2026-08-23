import Foundation
import RepoPromptRuntimeModel
import RepoPromptServicePersistence

public struct AuthorityMaintenanceConfiguration: Sendable {
    public let namespace: AuthorityNamespaceDescriptor

    public init(namespace: AuthorityNamespaceDescriptor) {
        self.namespace = namespace
    }
}

public enum AuthorityMaintenancePhase: String, Sendable, Equatable {
    case idle
    case acquiringLease
    case openingStore
    case ready
    case backingUp
    case migrating
    case restoring
    case mutating
    case closing
    case stopped
    case failed
}

public struct AuthorityMaintenanceObservation: Sendable, Equatable {
    public let phases: [AuthorityMaintenancePhase]
    public let storeWasOpened: Bool
    public let leaseWasReleased: Bool
}

typealias AuthorityMaintenanceStoreOpener = @Sendable (SQLiteServiceStore.Storage) async throws -> SQLiteServiceStore

/// Lease-bound, offline store ownership. This type deliberately exposes no
/// serving capabilities, provider/runtime startup, or schema-migration API.
public actor AuthorityMaintenanceSession {
    public nonisolated let configuration: AuthorityMaintenanceConfiguration

    private var lease: AuthorityNamespaceLease?
    private var store: SQLiteServiceStore?
    private var phaseValue: AuthorityMaintenancePhase
    private var phases: [AuthorityMaintenancePhase]
    private var storeWasOpened: Bool
    private var leaseWasReleased = false

    private init(
        configuration: AuthorityMaintenanceConfiguration,
        lease: AuthorityNamespaceLease,
        store: SQLiteServiceStore
    ) {
        self.configuration = configuration
        self.lease = lease
        self.store = store
        phaseValue = .ready
        phases = [.idle, .acquiringLease, .openingStore, .ready]
        storeWasOpened = true
    }

    private init(
        restoreConfiguration configuration: AuthorityMaintenanceConfiguration,
        lease: AuthorityNamespaceLease
    ) {
        self.configuration = configuration
        self.lease = lease
        store = nil
        phaseValue = .ready
        phases = [.idle, .acquiringLease, .ready]
        storeWasOpened = false
    }

    public static func acquireForRestore(
        configuration: AuthorityMaintenanceConfiguration
    ) throws -> AuthorityMaintenanceSession {
        let acquisition = try AuthorityNamespaceLease.acquire(configuration.namespace)
        return AuthorityMaintenanceSession(
            restoreConfiguration: configuration,
            lease: acquisition.lease
        )
    }

    public static func open(
        configuration: AuthorityMaintenanceConfiguration
    ) async throws -> AuthorityMaintenanceSession {
        try await open(configuration: configuration) { storage in
            try await SQLiteServiceStore.openForMaintenance(
                storage: storage,
                requestedNamespaceKind: configuration.namespace.servingMode.rawValue,
                requestedDatabaseIdentityDigest: configuration.namespace.namespaceID
            )
        }
    }

    static func open(
        configuration: AuthorityMaintenanceConfiguration,
        storeOpener: AuthorityMaintenanceStoreOpener
    ) async throws -> AuthorityMaintenanceSession {
        // Lease acquisition is intentionally the first operation that can touch
        // the authority namespace. Tests inject `storeOpener` to prove contention
        // fails before SQLite open/migration/mutation.
        let acquisition = try AuthorityNamespaceLease.acquire(configuration.namespace)
        do {
            let store = try await storeOpener(.file(configuration.namespace.databasePath))
            return AuthorityMaintenanceSession(
                configuration: configuration,
                lease: acquisition.lease,
                store: store
            )
        } catch {
            acquisition.lease.release()
            throw error
        }
    }

    public func phase() -> AuthorityMaintenancePhase { phaseValue }

    public func observation() -> AuthorityMaintenanceObservation {
        .init(
            phases: phases,
            storeWasOpened: storeWasOpened,
            leaseWasReleased: leaseWasReleased
        )
    }

    public func importLegacyJSON(
        source: URL,
        projectRoot: URL? = nil
    ) async throws -> LegacyImportReport {
        guard phaseValue == .ready, let store else {
            throw ServiceAPIError(
                code: .dependencyUnavailable,
                message: "Authority maintenance session is not open"
            )
        }
        phaseValue = .mutating
        phases.append(.mutating)
        do {
            let report = try await LegacySessionJSONImporter.run(
                source: source,
                store: store,
                projectRoot: projectRoot
            )
            phaseValue = .ready
            return report
        } catch {
            phaseValue = .ready
            throw error
        }
    }

    public func createBackup(
        service: BackupRestoreService,
        request: BackupCreateRequest
    ) async throws -> BackupSidecarV1 {
        guard phaseValue == .ready, let store else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority maintenance session is not open")
        }
        let correlationID = UUID()
        guard request.namespaceKind == configuration.namespace.servingMode.rawValue,
              request.databaseIdentityDigest == configuration.namespace.namespaceID
        else {
            try? await store.appendOperatorSecurityAudit(
                operation: "backupCreate", outcome: "failure",
                actor: "operator-maintenance", channel: "offline",
                clientIdentityDigest: nil, correlationID: correlationID,
                detailCode: "namespaceMismatch"
            )
            throw ServiceAPIError(code: .namespacePurposeMismatch, message: "Backup request does not match the leased namespace")
        }
        phaseValue = .backingUp
        phases.append(.backingUp)
        do {
            let sidecar = try await service.create(request: request, store: store)
            if try await store.metadata().schemaVersion >= 9 {
                try await store.recordMaintenanceReceipt(
                    operation: "backupCreate",
                    outcome: "success",
                    archiveSHA256: sidecar.archiveSHA256,
                    manifestSHA256: sidecar.manifestSHA256,
                    source: sidecar.source,
                    verifierFingerprint: sidecar.verification?.verifierFingerprint,
                    recipientFingerprints: sidecar.recipientFingerprints,
                    sidecarSHA256: BackupRestoreService.sidecarDigest(sidecar),
                    toolVersion: sidecar.toolVersion,
                    toolDigest: sidecar.toolDigest,
                    correlationID: correlationID
                )
            }
            phaseValue = .ready
            phases.append(.ready)
            return sidecar
        } catch {
            try? await store.appendOperatorSecurityAudit(
                operation: "backupCreate", outcome: "failure",
                actor: "operator-maintenance", channel: "offline",
                clientIdentityDigest: nil, correlationID: correlationID,
                detailCode: "backupCreateRejected"
            )
            phaseValue = .ready
            phases.append(.ready)
            throw error
        }
    }

    public func verifyBackup(
        service: BackupRestoreService,
        archiveURL: URL,
        identityFileURL: URL
    ) async throws -> VerifiedBackupArchive {
        guard phaseValue == .ready, let store else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority maintenance session is not open")
        }
        phaseValue = .backingUp
        phases.append(.backingUp)
        let correlationID = UUID()
        do {
            let verified = try await service.verify(
                archiveURL: archiveURL,
                identityFileURL: identityFileURL
            )
            let metadata = try await store.metadata()
            guard verified.manifest.namespaceKind == configuration.namespace.servingMode.rawValue,
                  verified.manifest.databaseIdentityDigest == configuration.namespace.namespaceID,
                  verified.manifest.source.storeID == metadata.storeID
            else {
                throw ServiceAPIError(
                    code: .namespacePurposeMismatch,
                    message: "Verified backup does not belong to the leased source namespace",
                    retryable: false
                )
            }
            if metadata.schemaVersion >= 9 {
                let sidecar = verified.sidecar
                try await store.recordMaintenanceReceipt(
                    operation: "backupVerify",
                    outcome: "success",
                    archiveSHA256: sidecar.archiveSHA256,
                    manifestSHA256: sidecar.manifestSHA256,
                    source: sidecar.source,
                    verifierFingerprint: sidecar.verification?.verifierFingerprint,
                    recipientFingerprints: sidecar.recipientFingerprints,
                    sidecarSHA256: BackupRestoreService.sidecarDigest(sidecar),
                    toolVersion: sidecar.verification?.maintenanceToolVersion ?? sidecar.toolVersion,
                    toolDigest: sidecar.verification?.maintenanceToolDigest ?? sidecar.toolDigest,
                    correlationID: correlationID
                )
            }
            phaseValue = .ready
            phases.append(.ready)
            return verified
        } catch {
            try? await store.appendOperatorSecurityAudit(
                operation: "backupVerify", outcome: "failure",
                actor: "operator-maintenance", channel: "offline",
                clientIdentityDigest: nil, correlationID: correlationID,
                detailCode: "backupVerificationRejected"
            )
            phaseValue = .ready
            phases.append(.ready)
            throw error
        }
    }

    public func resetOperatorPassword(_ password: String) async throws {
        guard phaseValue == .ready, let store else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority maintenance session is not open")
        }
        try await store.resetOperatorPasswordOffline(newPassword: password)
    }

    public func issueOperatorSetupToken() async throws -> String {
        guard phaseValue == .ready, let store else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority maintenance session is not open")
        }
        return try await store.issueOperatorSetupToken(channel: "offline")
    }

    public func revokeAllOperatorSessions() async throws -> Int {
        guard phaseValue == .ready, let store else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority maintenance session is not open")
        }
        return try await store.revokeAllOperatorSessions(
            reason: "offlineRevokeAll",
            auditActor: "operator-recovery",
            auditChannel: "offline",
            correlationID: UUID()
        )
    }

    public func migrate(
        service: BackupRestoreService,
        verifiedBackup archiveURL: URL,
        identityFileURL: URL
    ) async throws -> MigrationSourceEvidence {
        guard phaseValue == .ready, let store else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority maintenance session is not open")
        }
        phaseValue = .migrating
        phases.append(.migrating)
        let correlationID = UUID()
        do {
            // Verification deliberately runs while the source lease remains
            // held and immediately precedes the first migration transaction.
            let verified = try await service.verify(
                archiveURL: archiveURL,
                identityFileURL: identityFileURL
            )
            guard verified.manifest.namespaceKind == configuration.namespace.servingMode.rawValue else {
                throw ServiceAPIError(
                    code: .namespacePurposeMismatch,
                    message: "Verified backup belongs to a different namespace kind"
                )
            }
            let evidence = try await store.migrateToLatest(
                verifiedBackup: verified.migrationEvidence,
                namespaceKind: configuration.namespace.servingMode.rawValue,
                databaseIdentityDigest: configuration.namespace.namespaceID
            )
            try await store.appendOperatorSecurityAudit(
                operation: "schemaMigration", outcome: "success",
                actor: "operator-maintenance", channel: "offline",
                clientIdentityDigest: nil, correlationID: correlationID,
                detailCode: "verifiedBackupApplied"
            )
            phaseValue = .ready
            phases.append(.ready)
            return evidence
        } catch {
            try? await store.appendOperatorSecurityAudit(
                operation: "schemaMigration", outcome: "failure",
                actor: "operator-maintenance", channel: "offline",
                clientIdentityDigest: nil, correlationID: correlationID,
                detailCode: "migrationRejected"
            )
            phaseValue = .ready
            phases.append(.ready)
            throw error
        }
    }

    public func prepareRestore(
        service: BackupRestoreService,
        request: BackupRestoreRequest
    ) async throws -> BackupManifestV1 {
        guard phaseValue == .ready, store == nil else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Restore maintenance session is not ready")
        }
        guard request.targetRootURL.standardizedFileURL.path == configuration.namespace.storageRoot,
              request.targetNamespaceKind == configuration.namespace.servingMode.rawValue,
              request.targetDatabaseIdentityDigest == configuration.namespace.namespaceID
        else {
            throw ServiceAPIError(code: .namespacePurposeMismatch, message: "Restore request does not match the leased target namespace")
        }
        phaseValue = .restoring
        phases.append(.restoring)
        do {
            let manifest = try await service.prepareRestore(request)
            phaseValue = .ready
            phases.append(.ready)
            return manifest
        } catch {
            phaseValue = .ready
            phases.append(.ready)
            throw error
        }
    }

    public func close(clean: Bool = true) async throws {
        guard phaseValue != .stopped else { return }
        phaseValue = .closing
        phases.append(.closing)
        var closeError: Error?
        var storeClosed = store == nil
        if let store {
            do {
                try await store.close(clean: clean)
                storeClosed = true
            } catch {
                closeError = error
                do {
                    try await store.close(clean: false)
                    storeClosed = true
                } catch {
                    closeError = error
                }
            }
        }
        guard storeClosed else {
            phaseValue = .failed
            phases.append(.failed)
            throw closeError ?? ServiceAPIError(
                code: .dependencyUnavailable,
                message: "Authority maintenance store did not close"
            )
        }
        store = nil

        // The lease is always the final owned resource released, and is retained
        // fail-stop if the store cannot be proven closed.
        lease?.release()
        lease = nil
        leaseWasReleased = true
        phaseValue = closeError == nil ? .stopped : .failed
        phases.append(phaseValue)
        if let closeError { throw closeError }
    }
}
