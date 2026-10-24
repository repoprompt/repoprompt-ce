import Darwin
import Foundation
import os

package enum OracleGroupClaimError: Error, LocalizedError, Equatable {
    case ownerMismatch
    case conflict
    case unavailable(Int32)

    package var errorDescription: String? {
        switch self {
        case .ownerMismatch:
            "Oracle group claim route owner does not match the persisted group."
        case .conflict:
            "Oracle group is already claimed by another invocation."
        case let .unavailable(errorNumber):
            "Oracle group claim is unavailable (errno \(errorNumber))."
        }
    }
}

package final class OracleGroupClaim: @unchecked Sendable {
    private struct State {
        var descriptor: Int32?
    }

    package let id: UUID
    package let groupID: OracleGroupID
    package let owner: OracleConversationOwner
    package let invocationID: UUID
    package let runID: UUID
    package let runtimeID: UUID
    private let state: OSAllocatedUnfairLock<State>

    fileprivate init(
        id: UUID,
        groupID: OracleGroupID,
        owner: OracleConversationOwner,
        invocationID: UUID,
        runID: UUID,
        runtimeID: UUID,
        descriptor: Int32
    ) {
        self.id = id
        self.groupID = groupID
        self.owner = owner
        self.invocationID = invocationID
        self.runID = runID
        self.runtimeID = runtimeID
        state = OSAllocatedUnfairLock(initialState: State(descriptor: descriptor))
    }

    package var isReleased: Bool {
        state.withLock { $0.descriptor == nil }
    }

    package func release() {
        let descriptor = state.withLock { state -> Int32? in
            defer { state.descriptor = nil }
            return state.descriptor
        }
        guard let descriptor else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        release()
    }
}

package struct OracleGroupClaimManager {
    private struct ClaimRecord: Codable {
        let claimID: UUID
        let groupID: OracleGroupID
        let owner: OracleConversationOwner
        let invocationID: UUID
        let runID: UUID
        let runtimeID: UUID
        let runtimeGeneration: UInt64
        let processID: Int32
        let acquiredAt: Date
    }

    private let claimsDirectory: URL
    private let identity: DomainRuntimeIdentity

    package init(
        persistence: DomainPersistenceCoordinator,
        identity: DomainRuntimeIdentity
    ) {
        claimsDirectory = persistence.oracleStorageRoot.appendingPathComponent("claims", isDirectory: true)
        self.identity = identity
    }

    package func acquire(
        group: OracleGroupDocument,
        owner: OracleConversationOwner,
        invocationID: UUID,
        runID: UUID,
        claimID: UUID = UUID()
    ) async throws -> OracleGroupClaim {
        guard group.owner == owner else { throw OracleGroupClaimError.ownerMismatch }
        let record = ClaimRecord(
            claimID: claimID,
            groupID: group.group.id,
            owner: owner,
            invocationID: invocationID,
            runID: runID,
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            processID: identity.processID,
            acquiredAt: Date()
        )
        let directory = claimsDirectory
        let runtimeID = identity.runtimeID
        return try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(group.group.id.rawValue.uuidString).lock")
            let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw OracleGroupClaimError.unavailable(errno) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let errorNumber = errno
                close(descriptor)
                if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                    throw OracleGroupClaimError.conflict
                }
                throw OracleGroupClaimError.unavailable(errorNumber)
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(record)
                guard ftruncate(descriptor, 0) == 0,
                      lseek(descriptor, 0, SEEK_SET) >= 0
                else {
                    throw OracleGroupClaimError.unavailable(errno)
                }
                try data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    var written = 0
                    while written < buffer.count {
                        let count = Darwin.write(
                            descriptor,
                            base.advanced(by: written),
                            buffer.count - written
                        )
                        guard count > 0 else { throw OracleGroupClaimError.unavailable(errno) }
                        written += count
                    }
                }
                guard fsync(descriptor) == 0 else {
                    throw OracleGroupClaimError.unavailable(errno)
                }
                return OracleGroupClaim(
                    id: claimID,
                    groupID: group.group.id,
                    owner: owner,
                    invocationID: invocationID,
                    runID: runID,
                    runtimeID: runtimeID,
                    descriptor: descriptor
                )
            } catch {
                flock(descriptor, LOCK_UN)
                close(descriptor)
                throw error
            }
        }
    }
}
