import Foundation
import MCP

public enum DomainMutationJournalStatus: String, Codable, Sendable {
    case admitted
    case committing
    case applied
    case cancelledBeforeCommit = "cancelled_before_commit"
    case failedBeforeCommit = "failed_before_commit"
    case indeterminateAfterCommit = "indeterminate_after_commit"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "failed_before_write" {
            // Schema-v1 builds emitted this spelling. Delete this alias when v1 documents are no longer accepted;
            // encoding below rewrites the record with the canonical current spelling.
            self = .failedBeforeCommit
            return
        }
        guard let status = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot initialize DomainMutationJournalStatus from invalid String value \(rawValue)"
            )
        }
        self = status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DomainMutationJournalRecord: Codable, Sendable {
    public let key: String
    public let operationID: String
    public let toolName: String
    public let action: String
    public let fingerprint: String
    public let ownerInvocationID: UUID
    public let workspaceID: UUID?
    public let workspaceRevision: UInt64?
    public let pathFence: DomainMutationPathFenceSnapshot?
    public let status: DomainMutationJournalStatus
    public let attempt: UInt64
    public let resultData: Data?
    public let admittedAt: Date
    public let leaseExpiresAt: Date
    public let updatedAt: Date

    func updating(
        status: DomainMutationJournalStatus,
        ownerInvocationID: UUID? = nil,
        attempt: UInt64? = nil,
        resultData: Data? = nil,
        now: Date
    ) -> Self {
        Self(
            key: key,
            operationID: operationID,
            toolName: toolName,
            action: action,
            fingerprint: fingerprint,
            ownerInvocationID: ownerInvocationID ?? self.ownerInvocationID,
            workspaceID: workspaceID,
            workspaceRevision: workspaceRevision,
            pathFence: pathFence,
            status: status,
            attempt: attempt ?? self.attempt,
            resultData: resultData,
            admittedAt: admittedAt,
            leaseExpiresAt: leaseExpiresAt,
            updatedAt: now
        )
    }

    func attaching(pathFence: DomainMutationPathFenceSnapshot, now: Date) -> Self {
        Self(
            key: key,
            operationID: operationID,
            toolName: toolName,
            action: action,
            fingerprint: fingerprint,
            ownerInvocationID: ownerInvocationID,
            workspaceID: workspaceID,
            workspaceRevision: workspaceRevision,
            pathFence: pathFence,
            status: status,
            attempt: attempt,
            resultData: resultData,
            admittedAt: admittedAt,
            leaseExpiresAt: leaseExpiresAt,
            updatedAt: now
        )
    }
}

public struct DomainMutationJournalDocument: Codable, Sendable {
    public static let schemaVersion = 1

    var version: Int
    var profileIdentifier: String
    var revision: UInt64
    var records: [String: DomainMutationJournalRecord]
    var updatedAt: Date

    public var recordSnapshots: [DomainMutationJournalRecord] {
        Array(records.values)
    }
}

public struct DomainMutationJournalTicket: Hashable, Sendable {
    public let key: String
    public let fingerprint: String
    public let ownerInvocationID: UUID
}

public enum DomainMutationJournalBegin: Sendable {
    case execute(DomainMutationJournalTicket)
    case replay(Value)
}

public enum DomainMutationJournalError: Error, Equatable, LocalizedError, Sendable {
    case corruptOrFutureJournal
    case operationIDCollision(String)
    case operationInProgress(String)
    case interruptedCommit(String)
    case ownershipLost(String)
    case writerConflict

    public var errorDescription: String? {
        switch self {
        case .corruptOrFutureJournal:
            "Protected mutation journal is unavailable; mutations default to deny."
        case let .operationIDCollision(id):
            "Protected mutation operation ID was reused with different arguments: \(id)"
        case let .operationInProgress(id):
            "Protected mutation operation is already in progress: \(id)"
        case let .interruptedCommit(id):
            "Protected mutation commit was interrupted or its result is indeterminate; inspect state before retrying: \(id)"
        case let .ownershipLost(id):
            "Protected mutation journal ownership changed before commit: \(id)"
        case .writerConflict:
            "Protected mutation journal remained contended after bounded compare-and-swap retries."
        }
    }
}

public actor DomainMutationJournal {
    private let persistence: DomainPersistenceCoordinator
    private let profileIdentifier: String
    private var document: DomainMutationJournalDocument
    private var documentDigest: String?
    private var didBootstrap = false
    private var isHealthy = true

    public init(
        persistence: DomainPersistenceCoordinator,
        profileIdentifier: String,
        createdAt: Date
    ) {
        self.persistence = persistence
        self.profileIdentifier = profileIdentifier
        document = DomainMutationJournalDocument(
            version: DomainMutationJournalDocument.schemaVersion,
            profileIdentifier: profileIdentifier,
            revision: 0,
            records: [:],
            updatedAt: createdAt
        )
    }

    public func begin(
        key: String,
        operationID: String,
        toolName: String,
        action: String,
        fingerprint: String,
        ownerInvocationID: UUID,
        workspaceID: UUID?,
        workspaceRevision: UInt64?,
        pathFence: DomainMutationPathFenceSnapshot?,
        now: Date = Date(),
        leaseDuration: TimeInterval = 300
    ) async throws -> DomainMutationJournalBegin {
        try await ensureBootstrapped()
        try await reload()
        for _ in 0 ..< 16 {
            if let existing = document.records[key] {
                guard existing.fingerprint == fingerprint else {
                    throw DomainMutationJournalError.operationIDCollision(operationID)
                }
                switch existing.status {
                case .applied:
                    guard let data = existing.resultData,
                          let value = try? JSONDecoder().decode(Value.self, from: data)
                    else {
                        throw DomainMutationJournalError.corruptOrFutureJournal
                    }
                    return .replay(value)
                case .committing, .indeterminateAfterCommit:
                    throw DomainMutationJournalError.interruptedCommit(operationID)
                case .admitted where existing.ownerInvocationID != ownerInvocationID && existing.leaseExpiresAt > now:
                    throw DomainMutationJournalError.operationInProgress(operationID)
                case .admitted, .cancelledBeforeCommit, .failedBeforeCommit:
                    break
                }
            }

            var next = document
            let priorAttempt = next.records[key]?.attempt ?? 0
            next.records[key] = DomainMutationJournalRecord(
                key: key,
                operationID: operationID,
                toolName: toolName,
                action: action,
                fingerprint: fingerprint,
                ownerInvocationID: ownerInvocationID,
                workspaceID: workspaceID,
                workspaceRevision: workspaceRevision,
                pathFence: pathFence,
                status: .admitted,
                attempt: priorAttempt &+ 1,
                resultData: nil,
                admittedAt: now,
                leaseExpiresAt: now.addingTimeInterval(leaseDuration),
                updatedAt: now
            )
            prune(&next)
            do {
                try await persist(next, expectedDigest: documentDigest)
                return .execute(DomainMutationJournalTicket(
                    key: key,
                    fingerprint: fingerprint,
                    ownerInvocationID: ownerInvocationID
                ))
            } catch DomainPersistenceError.externalDocumentConflict {
                try await reload()
            }
        }
        throw DomainMutationJournalError.writerConflict
    }

    public func attachPathFence(
        _ pathFence: DomainMutationPathFenceSnapshot,
        to ticket: DomainMutationJournalTicket,
        now: Date = Date()
    ) async throws {
        try await transition(ticket, now: now) { record in
            guard record.status == .admitted else {
                throw DomainMutationJournalError.ownershipLost(record.operationID)
            }
            return record.attaching(pathFence: pathFence, now: now)
        }
    }

    public func markCommitting(
        _ ticket: DomainMutationJournalTicket,
        now: Date = Date()
    ) async throws {
        try await transition(ticket, now: now) { record in
            guard record.status == .admitted else {
                throw DomainMutationJournalError.ownershipLost(record.operationID)
            }
            return record.updating(status: .committing, now: now)
        }
    }

    public func finishApplied(
        _ ticket: DomainMutationJournalTicket,
        result: Value,
        now: Date = Date()
    ) async throws {
        let resultData = try JSONEncoder().encode(result)
        try await transition(ticket, now: now) { record in
            guard record.status == .committing else {
                throw DomainMutationJournalError.ownershipLost(record.operationID)
            }
            return record.updating(status: .applied, resultData: resultData, now: now)
        }
    }

    public func finishBeforeCommit(
        _ ticket: DomainMutationJournalTicket,
        cancelled: Bool,
        now: Date = Date()
    ) async throws {
        try await transition(ticket, now: now) { record in
            guard record.status == .admitted else {
                throw DomainMutationJournalError.ownershipLost(record.operationID)
            }
            return record.updating(
                status: cancelled ? .cancelledBeforeCommit : .failedBeforeCommit,
                now: now
            )
        }
    }

    public func finishIndeterminateAfterCommit(
        _ ticket: DomainMutationJournalTicket,
        now: Date = Date()
    ) async throws {
        try await transition(ticket, now: now) { record in
            guard record.status == .committing else {
                throw DomainMutationJournalError.ownershipLost(record.operationID)
            }
            return record.updating(status: .indeterminateAfterCommit, now: now)
        }
    }

    public func snapshot() async throws -> DomainMutationJournalDocument {
        try await ensureBootstrapped()
        return document
    }

    private func transition(
        _ ticket: DomainMutationJournalTicket,
        now: Date,
        transform: (DomainMutationJournalRecord) throws -> DomainMutationJournalRecord
    ) async throws {
        try await ensureBootstrapped()
        for _ in 0 ..< 16 {
            guard let record = document.records[ticket.key],
                  record.fingerprint == ticket.fingerprint,
                  record.ownerInvocationID == ticket.ownerInvocationID
            else {
                throw DomainMutationJournalError.ownershipLost(ticket.key)
            }
            var next = document
            next.records[ticket.key] = try transform(record)
            do {
                try await persist(next, expectedDigest: documentDigest)
                return
            } catch DomainPersistenceError.externalDocumentConflict {
                try await reload()
            }
        }
        throw DomainMutationJournalError.writerConflict
    }

    private func ensureBootstrapped() async throws {
        guard !didBootstrap else {
            guard isHealthy else { throw DomainMutationJournalError.corruptOrFutureJournal }
            return
        }
        didBootstrap = true
        do {
            try await reload()
        } catch {
            isHealthy = false
            throw DomainMutationJournalError.corruptOrFutureJournal
        }
    }

    private func reload() async throws {
        guard let data = try await persistence.loadProtectedMutationJournalData() else {
            document = DomainMutationJournalDocument(
                version: DomainMutationJournalDocument.schemaVersion,
                profileIdentifier: profileIdentifier,
                revision: 0,
                records: [:],
                updatedAt: Date()
            )
            documentDigest = nil
            isHealthy = true
            return
        }
        let decoded = try JSONDecoder().decode(DomainMutationJournalDocument.self, from: data)
        guard decoded.version == DomainMutationJournalDocument.schemaVersion,
              decoded.profileIdentifier == profileIdentifier
        else {
            throw DomainMutationJournalError.corruptOrFutureJournal
        }
        document = decoded
        documentDigest = DomainContentDigest.sha256(data)
        isHealthy = true
    }

    private func persist(
        _ candidate: DomainMutationJournalDocument,
        expectedDigest: String?
    ) async throws {
        var next = candidate
        next.revision = document.revision &+ 1
        next.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        try await persistence.compareAndSwapProtectedMutationJournalData(
            expectedDigest: expectedDigest,
            data: data
        )
        document = next
        documentDigest = DomainContentDigest.sha256(data)
    }

    private func prune(_ document: inout DomainMutationJournalDocument) {
        guard document.records.count > 512 else { return }
        let removable = document.records.values
            .filter { [.applied, .cancelledBeforeCommit, .failedBeforeCommit].contains($0.status) }
            .sorted { $0.updatedAt < $1.updatedAt }
        for record in removable.prefix(document.records.count - 512) {
            document.records.removeValue(forKey: record.key)
        }
    }
}

public actor DomainMutationCommitState {
    private var didBeginCommit = false

    public func beginIfNeeded(_ operation: @Sendable () async throws -> Void) async throws {
        guard !didBeginCommit else { return }
        try await operation()
        didBeginCommit = true
    }

    public func hasBegunCommit() -> Bool {
        didBeginCommit
    }
}

public struct DomainMutationPhysicalRootMapping: Hashable, Sendable {
    public let canonicalRoot: String
    public let physicalRoot: String

    public init(canonicalRoot: String, physicalRoot: String) {
        self.canonicalRoot = canonicalRoot
        self.physicalRoot = physicalRoot
    }
}

public struct DomainMutationCommitController: Sendable {
    private let admitOperation: @Sendable ([String], [DomainMutationPhysicalRootMapping]) async throws -> Void
    private let physicalGuardOperation: @Sendable () async throws -> DomainMutationPhysicalCommitGuard?
    private let commitOperation: @Sendable () async throws -> Void

    public init(
        admitPhysicalTargets: @Sendable @escaping ([String], [DomainMutationPhysicalRootMapping]) async throws -> Void = { _, _ in },
        physicalMutationGuard: @Sendable @escaping () async throws -> DomainMutationPhysicalCommitGuard? = { nil },
        willCommit: @Sendable @escaping () async throws -> Void
    ) {
        admitOperation = admitPhysicalTargets
        physicalGuardOperation = physicalMutationGuard
        commitOperation = willCommit
    }

    public init(operation: @Sendable @escaping () async throws -> Void) {
        admitOperation = { _, _ in }
        physicalGuardOperation = { nil }
        commitOperation = operation
    }

    public func admitPhysicalTargets(
        _ paths: [String],
        rootMappings: [DomainMutationPhysicalRootMapping]
    ) async throws {
        try await admitOperation(paths, rootMappings)
    }

    public func physicalMutationGuard() async throws -> DomainMutationPhysicalCommitGuard? {
        try await physicalGuardOperation()
    }

    public func willCommit() async throws {
        try await commitOperation()
    }
}

public enum MCPDomainMutationCommitContext {
    @TaskLocal public static var controller: DomainMutationCommitController?

    public static func admitPhysicalTargets(
        _ paths: [String],
        rootMappings: [DomainMutationPhysicalRootMapping]
    ) async throws {
        try await controller?.admitPhysicalTargets(paths, rootMappings: rootMappings)
    }

    public static func physicalMutationGuard() async throws -> DomainMutationPhysicalCommitGuard? {
        try await controller?.physicalMutationGuard()
    }

    public static func willCommit() async throws {
        try await controller?.willCommit()
    }
}
