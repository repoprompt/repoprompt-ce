import Foundation
import RepoPromptFileSystem

/// Retains the workspace-owned authenticated lease; no VCS/planner authority is
/// copied into the filesystem module.
private final class AppFileSystemSeedPlanManifest: FileSystemSeedPlanManifest, @unchecked Sendable {
    private let lease: WorkspaceRootTargetSeedPlanManifestLease

    init(_ lease: WorkspaceRootTargetSeedPlanManifestLease) {
        self.lease = lease
    }

    var ordinaryFileCount: UInt64 {
        lease.footer.ordinaryFileCount
    }

    var ordinaryDirectoryCount: UInt64 {
        lease.footer.ordinaryDirectoryCount
    }

    var digest: Data {
        lease.footer.digest
    }

    func makeFileSystemReader() throws -> any FileSystemSeedPlanReading {
        try AppFileSystemSeedPlanReader(lease.makeReader())
    }

    func makeFileSystemLookupReader(startingAtValidatedRecordOffset offset: Int64) throws -> any FileSystemSeedPlanLookupReading {
        try AppFileSystemSeedPlanLookupReader(lease.makeLookupReader(startingAtValidatedRecordOffset: offset))
    }
}

private final class AppFileSystemSeedPlanReader: FileSystemSeedPlanReading {
    private let reader: WorkspaceRootTargetSeedPlanManifestReader

    init(_ reader: WorkspaceRootTargetSeedPlanManifestReader) {
        self.reader = reader
    }

    var isVerified: Bool {
        reader.validationState == .verified
    }

    func nextRecordFileOffset() throws -> Int64 {
        try reader.nextRecordFileOffset()
    }

    func next() throws -> FileSystemSeedPlanRecord? {
        guard let record = try reader.next() else { return nil }
        return Self.project(record)
    }

    static func project(_ record: WorkspaceRootTargetSeedPlanRecord) -> FileSystemSeedPlanRecord {
        let disposition: FileSystemSeedPlanRecord.Disposition = switch record.disposition {
        case .ordinaryFile: .ordinaryFile
        case .ordinaryDirectory: .ordinaryDirectory
        case .policyIgnoredTrackedFile: .policyIgnoredTrackedFile
        case .baseTombstone: .baseTombstone
        }
        return FileSystemSeedPlanRecord(relativePathBytes: record.relativePathBytes, disposition: disposition)
    }
}

private final class AppFileSystemSeedPlanLookupReader: FileSystemSeedPlanLookupReading {
    private let reader: WorkspaceRootTargetSeedPlanManifestLookupReader

    init(_ reader: WorkspaceRootTargetSeedPlanManifestLookupReader) {
        self.reader = reader
    }

    func next() throws -> FileSystemSeedPlanRecord? {
        try reader.next().map(AppFileSystemSeedPlanReader.project)
    }
}

extension FileSystemService {
    func prepareSeededInventory(
        planHandle: WorkspaceRootTargetSeedPlanHandle,
        initializationID: FileSystemSeedInitializationID
    ) async throws -> FileSystemSeededInventoryPreparation {
        try await prepareSeededInventory(
            planManifest: AppFileSystemSeedPlanManifest(planHandle.planManifest),
            initializationID: initializationID
        )
    }
}
