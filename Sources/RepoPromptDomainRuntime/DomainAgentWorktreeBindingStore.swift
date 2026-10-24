import Foundation

package enum DomainAgentWorktreeBindingStoreError: Error, LocalizedError, Equatable, Sendable {
    case futureDocument
    case wrongProfile
    case corruptDocument
    case readOnlyDegraded(String)
    case stateConflict

    package var errorDescription: String? {
        switch self {
        case .futureDocument: "Agent worktree binding document uses a future schema version."
        case .wrongProfile: "Agent worktree binding document belongs to another profile."
        case .corruptDocument: "Agent worktree binding document is corrupt."
        case let .readOnlyDegraded(reason): "Agent worktree bindings are read-only degraded: \(reason)."
        case .stateConflict: "Agent worktree bindings changed in another process; retry."
        }
    }
}

private struct DomainAgentWorktreeBindingDocument: Codable, Sendable {
    struct Record: Codable, Sendable {
        let sessionID: UUID
        let bindings: [AgentSessionWorktreeBinding]
    }

    static let version = 1
    let version: Int
    let profileIdentifier: String
    let revision: UInt64
    let records: [Record]
    let updatedAt: Date
}

/// Durable profile-scoped authority for Agent session worktree bindings.
package actor DomainAgentWorktreeBindingStore {
    private let persistence: DomainPersistenceCoordinator
    private let profileIdentifier: String
    private var bindingsBySessionID: [UUID: [AgentSessionWorktreeBinding]] = [:]
    private var revision: UInt64 = 0
    private var digest: String?
    private var healthReason: String?
    private var didBootstrap = false

    package init(persistence: DomainPersistenceCoordinator, profileIdentifier: String) {
        self.persistence = persistence
        self.profileIdentifier = profileIdentifier
    }

    package func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await reload(degradeOnFailure: true)
    }

    package func bindings(sessionID: UUID) -> [AgentSessionWorktreeBinding] {
        bindingsBySessionID[sessionID] ?? []
    }

    package func allBindings() -> [UUID: [AgentSessionWorktreeBinding]] {
        bindingsBySessionID
    }

    package func upsert(
        sessionID: UUID,
        binding: AgentSessionWorktreeBinding
    ) async throws -> UInt64 {
        try await mutate { records in
            var bindings = records[sessionID] ?? []
            bindings.removeAll { $0.repositoryID == binding.repositoryID || $0.logicalRootPath == binding.logicalRootPath }
            bindings.append(binding)
            records[sessionID] = bindings.sorted { $0.logicalRootPath < $1.logicalRootPath }
        }
    }

    package func remove(sessionID: UUID, repositoryID: String? = nil) async throws -> UInt64 {
        try await mutate { records in
            guard let repositoryID else {
                records.removeValue(forKey: sessionID)
                return
            }
            records[sessionID]?.removeAll { $0.repositoryID == repositoryID || $0.repoKey == repositoryID }
            if records[sessionID]?.isEmpty == true { records.removeValue(forKey: sessionID) }
        }
    }

    private func mutate(
        _ body: (inout [UUID: [AgentSessionWorktreeBinding]]) -> Void
    ) async throws -> UInt64 {
        if let healthReason { throw DomainAgentWorktreeBindingStoreError.readOnlyDegraded(healthReason) }
        for attempt in 0 ..< 3 {
            var next = bindingsBySessionID
            body(&next)
            let nextRevision = revision &+ 1
            let document = DomainAgentWorktreeBindingDocument(
                version: DomainAgentWorktreeBindingDocument.version,
                profileIdentifier: profileIdentifier,
                revision: nextRevision,
                records: next.map { .init(sessionID: $0.key, bindings: $0.value) }
                    .sorted { $0.sessionID.uuidString < $1.sessionID.uuidString },
                updatedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            do {
                try await persistence.compareAndSwapAgentWorktreeBindingsData(expectedDigest: digest, data: data)
                bindingsBySessionID = next
                revision = nextRevision
                digest = DomainContentDigest.sha256(data)
                return revision
            } catch DomainPersistenceError.externalDocumentConflict where attempt < 2 {
                await reload(degradeOnFailure: false)
                continue
            } catch DomainPersistenceError.externalDocumentConflict {
                throw DomainAgentWorktreeBindingStoreError.stateConflict
            } catch {
                healthReason = error.localizedDescription
                throw DomainAgentWorktreeBindingStoreError.readOnlyDegraded(error.localizedDescription)
            }
        }
        throw DomainAgentWorktreeBindingStoreError.stateConflict
    }

    private func reload(degradeOnFailure: Bool) async {
        do {
            let snapshot = try await persistence.loadAgentWorktreeBindingsData()
            digest = snapshot.data.map(DomainContentDigest.sha256)
            guard let data = snapshot.data else {
                bindingsBySessionID = [:]
                revision = 0
                return
            }
            let document = try JSONDecoder().decode(DomainAgentWorktreeBindingDocument.self, from: data)
            guard document.version <= DomainAgentWorktreeBindingDocument.version else {
                throw DomainAgentWorktreeBindingStoreError.futureDocument
            }
            guard document.profileIdentifier == profileIdentifier else {
                throw DomainAgentWorktreeBindingStoreError.wrongProfile
            }
            bindingsBySessionID = Dictionary(uniqueKeysWithValues: document.records.map { ($0.sessionID, $0.bindings) })
            revision = document.revision
        } catch let error as DomainAgentWorktreeBindingStoreError {
            if degradeOnFailure { healthReason = error.localizedDescription }
        } catch {
            if degradeOnFailure { healthReason = DomainAgentWorktreeBindingStoreError.corruptDocument.localizedDescription }
        }
    }
}
