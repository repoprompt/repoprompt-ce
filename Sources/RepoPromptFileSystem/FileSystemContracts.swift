import Foundation

/// Read-only ignore policy consumed without depending on the compiler's representation.
package protocol IgnoreMatcher {
    func isIgnored(relativePath: String, isDirectory: Bool) -> Bool
    func requiresTraversal(for relativePath: String) -> Bool
}

extension IgnoreRulesSnapshot: IgnoreMatcher {}
extension CompiledIgnoreRules: IgnoreMatcher {
    package func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        outcome(for: relativePath, isDirectory: isDirectory) == .ignore
    }
}

/// Validated repository-relative prefixes are supplied by the repository owner.
/// FileSystem never resolves VCS configuration or acquires repository authority.
package protocol IgnoreRepositoryRootPrefix: Sendable {
    var value: String { get }
}

package struct IgnoreRootPrefix: IgnoreRepositoryRootPrefix, Equatable {
    package let value: String

    /// The caller already owns prefix validation (e.g. GitRepositoryRelativeRootPrefix).
    package init(value: String) {
        self.value = value
    }
}

/// A streaming projection of an authenticated app-owned seed plan. Its lease
/// must stay alive through readers and point lookups, without materializing paths.
package protocol FileSystemSeedPlanManifest: AnyObject, Sendable {
    var ordinaryFileCount: UInt64 { get }
    var ordinaryDirectoryCount: UInt64 { get }
    var digest: Data { get }
    func makeFileSystemReader() throws -> any FileSystemSeedPlanReading
    func makeFileSystemLookupReader(startingAtValidatedRecordOffset offset: Int64) throws -> any FileSystemSeedPlanLookupReading
}

package protocol FileSystemSeedPlanLookupReading: AnyObject {
    func next() throws -> FileSystemSeedPlanRecord?
}

package protocol FileSystemSeedPlanReading: FileSystemSeedPlanLookupReading {
    var isVerified: Bool { get }
    func nextRecordFileOffset() throws -> Int64
}

package struct FileSystemSeedPlanRecord {
    package enum Disposition {
        case ordinaryFile
        case ordinaryDirectory
        case policyIgnoredTrackedFile
        case baseTombstone
    }

    package let relativePathBytes: Data
    package let disposition: Disposition

    package init(relativePathBytes: Data, disposition: Disposition) {
        self.relativePathBytes = relativePathBytes
        self.disposition = disposition
    }
}
