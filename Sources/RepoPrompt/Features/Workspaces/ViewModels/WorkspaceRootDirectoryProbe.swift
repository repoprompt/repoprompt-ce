import Foundation

extension WorkspaceRootReadinessFailure.Availability: @unchecked Sendable {}

struct WorkspaceRootDirectoryProbeTestEvent {
    enum Phase { case beforeFileSystem, afterFileSystem, workerFinished }
    let attemptID: UUID
    let workerID: UUID
    let phase: Phase
}

/// Owns immutable filesystem reads independently from root-mutation lifecycle work.
/// Two slots let a new activation proceed while one retired read is stalled, while
/// repeated retirement cannot accumulate unbounded detached workers.
final class WorkspaceRootDirectoryProbe: @unchecked Sendable {
    struct CapacityExceeded: Error {}

    typealias Checkpoint = @Sendable (WorkspaceRootDirectoryProbeTestEvent) async -> Void

    private let lock = NSLock()
    private let maximumOutstanding = 2
    private var outstandingWorkerIDs: Set<UUID> = []

    var outstandingCount: Int {
        lock.withLock { outstandingWorkerIDs.count }
    }

    func run(
        paths: [String],
        attemptID: UUID,
        checkpoint: Checkpoint?
    ) async throws -> WorkspaceRootReadinessFailure.Availability? {
        try Task.checkCancellation()
        let workerID = UUID()
        guard reserve(workerID) else { throw CapacityExceeded() }
        return try await CancellableProbe.run { complete in
            Task.detached(priority: .utility) { [self] in
                let result: Result<WorkspaceRootReadinessFailure.Availability?, Error>
                do {
                    try Task.checkCancellation()
                    await checkpoint?(.init(attemptID: attemptID, workerID: workerID, phase: .beforeFileSystem))
                    try Task.checkCancellation()
                    let value = try Self.readDirectories(paths)
                    await checkpoint?(.init(attemptID: attemptID, workerID: workerID, phase: .afterFileSystem))
                    try Task.checkCancellation()
                    result = .success(value)
                } catch {
                    result = .failure(error)
                }
                release(workerID)
                complete(result)
                await checkpoint?(.init(attemptID: attemptID, workerID: workerID, phase: .workerFinished))
            }
        }
    }

    private func reserve(_ workerID: UUID) -> Bool {
        lock.withLock {
            guard outstandingWorkerIDs.count < maximumOutstanding else { return false }
            outstandingWorkerIDs.insert(workerID)
            return true
        }
    }

    private func release(_ workerID: UUID) {
        lock.withLock { _ = outstandingWorkerIDs.remove(workerID) }
    }

    private static func readDirectories(_ paths: [String]) throws -> WorkspaceRootReadinessFailure.Availability? {
        for path in paths {
            try Task.checkCancellation()
            do {
                let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
                if values.isDirectory != true { return .notDirectory }
                if values.isReadable != true { return .accessDenied }
            } catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain,
                   error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
                {
                    return .missingDirectory
                }
                if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
                    return .accessDenied
                }
                return .loadFailed
            }
        }
        return nil
    }
}
