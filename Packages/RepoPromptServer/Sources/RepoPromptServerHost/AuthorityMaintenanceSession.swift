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

    public static func open(
        configuration: AuthorityMaintenanceConfiguration
    ) async throws -> AuthorityMaintenanceSession {
        try await open(configuration: configuration) { storage in
            try await SQLiteServiceStore.openForMaintenance(storage: storage)
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
