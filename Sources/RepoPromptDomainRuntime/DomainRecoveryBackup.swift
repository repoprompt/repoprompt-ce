import Darwin
import Foundation
import os

/// One durable replacement that would discard `discardedBytes` (#335).
///
/// The obligation is stateless: whoever is about to discard durable workspace bytes asks the host
/// guard whether those bytes need a recovery copy, and the guard either confirms a verified backup
/// exists (writing one if needed) or refuses the replacement. The backup file is the only record
/// that the obligation was met, so the check is recomputed from the bytes on every replacement and
/// survives restarts and process boundaries.
package struct DomainDurableReplacement: Sendable {
    package enum Location: String, Sendable {
        /// The canonical `workspace.json` bytes on disk.
        case savedDocument = "saved_document"
        /// The working-journal document bytes (the dirty working copy startup would restore).
        case workingDocument = "working_document"
    }

    package let workspaceID: UUID
    package let documentURL: URL
    package let location: Location
    package let discardedBytes: Data
    /// The bytes that become authoritative in place of `discardedBytes`.
    package let replacementBytes: Data

    package init(
        workspaceID: UUID,
        documentURL: URL,
        location: Location,
        discardedBytes: Data,
        replacementBytes: Data
    ) {
        self.workspaceID = workspaceID
        self.documentURL = documentURL
        self.location = location
        self.discardedBytes = discardedBytes
        self.replacementBytes = replacementBytes
    }
}

/// Host-provided policy that runs inside the domain workspace locks, before any journal or document
/// mutation. Throwing refuses the replacement; nothing durable changes. Implementations must not
/// call back into the domain runtime and must not require the main actor.
package struct DomainDurableReplacementGuard: Sendable {
    package let protect: @Sendable (DomainDurableReplacement) throws -> Void

    package init(protect: @escaping @Sendable (DomainDurableReplacement) throws -> Void) {
        self.protect = protect
    }

    /// Codec-free policy for processes that cannot decode the app's workspace model (the headless
    /// MCP runtime). They edit compose tabs as raw JSON, so they never reduce a document
    /// themselves, but they can save a working copy reduced by another process over an original
    /// whose tabs that process could not read. Discarding bytes whose compose-tab identities do
    /// not all survive into the replacement therefore requires a verified backup first.
    package static func composeTabLoss(
        validatePath: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) -> Self {
        Self { replacement in
            guard DomainRecoveryBackup.replacementDropsComposeTabs(
                discarded: replacement.discardedBytes,
                replacement: replacement.replacementBytes,
                intentionallyClosed: DomainIntentionalTabClosures.shared.closures(for: replacement.workspaceID)
            ) else { return }
            try DomainRecoveryBackup.preserve(
                documentBytes: replacement.discardedBytes,
                documentURL: replacement.documentURL,
                validatePath: validatePath
            )
        }
    }
}

package enum DomainRecoveryBackupError: Error, Equatable, Sendable {
    /// Something other than a regular file occupies the backup locator. It is never removed.
    case conflictingEntry(String)
    case writeFailed(String)
    /// The published backup could not be read back with the expected full digest.
    case verificationFailed
}

/// Content-addressed recovery copies of workspace documents, next to the canonical document.
package enum DomainRecoveryBackup {
    package static let fileNamePrefix = "workspace.unreadable-"

    /// `workspace.unreadable-<full sha256>.json` next to `documentURL`. The full digest makes the
    /// name unique per original, so replacing a corrupt copy never erases a different original.
    package static func backupURL(documentURL: URL, documentBytes: Data) -> URL {
        locator(documentURL: documentURL, digest: DomainContentDigest.sha256(documentBytes))
    }

    /// The 16-hex-character name written by #1593. Accepted only after full-digest verification.
    package static func legacyBackupURL(documentURL: URL, documentBytes: Data) -> URL {
        locator(documentURL: documentURL, digest: String(DomainContentDigest.sha256(documentBytes).prefix(16)))
    }

    /// A regular (non-symlink) file at the full or legacy locator whose full digest matches.
    package static func verifiedBackupURL(documentURL: URL, documentBytes: Data) -> URL? {
        let digest = DomainContentDigest.sha256(documentBytes)
        for candidate in [
            backupURL(documentURL: documentURL, documentBytes: documentBytes),
            legacyBackupURL(documentURL: documentURL, documentBytes: documentBytes)
        ] where isRegularFile(candidate) {
            if let bytes = try? Data(contentsOf: candidate), DomainContentDigest.sha256(bytes) == digest {
                return candidate
            }
        }
        return nil
    }

    /// Ensures a verified backup of `documentBytes` exists and is durable (file and directory entry
    /// fsynced) before returning. The canonical document need not exist: journal bytes are
    /// protected even when `workspace.json` is missing.
    @discardableResult
    package static func preserve(
        documentBytes: Data,
        documentURL: URL,
        validatePath: (URL) throws -> Void = { _ in }
    ) throws -> URL {
        if let existing = verifiedBackupURL(documentURL: documentURL, documentBytes: documentBytes) {
            // An existing copy (possibly written by a crashed process) is only a receipt once its
            // data and directory entry are durable.
            try syncExisting(existing)
            return existing
        }
        let url = backupURL(documentURL: documentURL, documentBytes: documentBytes)
        try validatePath(url)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DomainRecoveryBackupError.writeFailed("directory_create_failed: \(error.localizedDescription)")
        }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            // A directory, symlink, or special file is never removed or followed.
            throw DomainRecoveryBackupError.conflictingEntry(url.lastPathComponent)
        }
        // A regular file at this full-digest name with other content is a damaged copy of these
        // same bytes; atomically replacing it cannot discard any other original.
        try publishDurably(documentBytes, to: url, in: directory)
        guard verifiedBackupURL(documentURL: documentURL, documentBytes: documentBytes) == url else {
            throw DomainRecoveryBackupError.verificationFailed
        }
        return url
    }

    /// Bytes at `url`; nil only when nothing exists there (ENOENT). Any other read failure
    /// (EACCES, EIO, ...) throws, so an unreadable original is never mistaken for a missing one.
    package static func existingBytes(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
    }

    /// Codec-free loss check. True when the discarded bytes cannot be reasoned about as raw JSON,
    /// or when a discarded tab's content does not survive into the replacement:
    /// - a composed tab survives only as a composed tab with the same identity (raw editors keep
    ///   unknown fields in place), or as a stashed tab with an identical payload; a same-ID stashed
    ///   copy with different content is not evidence that the composed payload survived;
    /// - a stashed tab survives as a stashed or composed tab with the same identity;
    /// - `intentionallyClosed` (tab ID to payload digest) exempts tabs a user closed on purpose,
    ///   only while their payload is unchanged.
    package static func replacementDropsComposeTabs(
        discarded: Data,
        replacement: Data,
        intentionallyClosed: [String: String] = [:]
    ) -> Bool {
        guard let discardedObject = jsonObject(discarded),
              let discardedComposed = tabObjects(discardedObject["composeTabs"]),
              let discardedStashed = stashedTabObjects(discardedObject["stashedTabs"])
        else { return true }
        guard !discardedComposed.isEmpty || !discardedStashed.isEmpty else { return false }
        guard let replacementObject = jsonObject(replacement) else { return true }
        let replacementComposedIDs = Set((tabObjects(replacementObject["composeTabs"]) ?? []).compactMap { $0["id"] as? String })
        var replacementStashedPayloads: [String: Set<String>] = [:]
        for tab in stashedTabObjects(replacementObject["stashedTabs"]) ?? [] {
            if let id = tab["id"] as? String, let digest = payloadDigest(tab) {
                replacementStashedPayloads[id, default: []].insert(digest)
            }
        }
        for tab in discardedComposed {
            guard let id = tab["id"] as? String else { return true }
            if replacementComposedIDs.contains(id) { continue }
            guard let digest = payloadDigest(tab) else { return true }
            if replacementStashedPayloads[id]?.contains(digest) == true || intentionallyClosed[id] == digest { continue }
            return true
        }
        for tab in discardedStashed {
            guard let id = tab["id"] as? String else { return true }
            if replacementStashedPayloads[id] != nil || replacementComposedIDs.contains(id) { continue }
            return true
        }
        return false
    }

    /// Digest of a raw tab object, stable across key order.
    package static func payloadDigest(_ tab: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: tab, options: [.sortedKeys]) else { return nil }
        return DomainContentDigest.sha256(data)
    }

    // MARK: - Private

    private static func locator(documentURL: URL, digest: String) -> URL {
        documentURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileNamePrefix)\(digest).json", isDirectory: false)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Nil when the value is present but not an array of objects.
    private static func tabObjects(_ raw: Any?) -> [[String: Any]]? {
        guard let raw, !(raw is NSNull) else { return [] }
        return raw as? [[String: Any]]
    }

    /// The `tab` objects of a stashed-tabs array; nil when the array is malformed.
    private static func stashedTabObjects(_ raw: Any?) -> [[String: Any]]? {
        guard let entries = tabObjects(raw) else { return nil }
        var tabs: [[String: Any]] = []
        for entry in entries {
            guard let tab = entry["tab"] as? [String: Any] else { return nil }
            tabs.append(tab)
        }
        return tabs
    }

    private static func syncExisting(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DomainRecoveryBackupError.writeFailed("existing_open_failed_\(errno)")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DomainRecoveryBackupError.writeFailed("existing_fsync_failed_\(errno)")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func syncDirectory(_ directory: URL) throws {
        #if DEBUG
            if let injected = directorySyncFailureForTesting.withLock({ $0 }) {
                throw DomainRecoveryBackupError.writeFailed("directory_fsync_failed_\(injected)")
            }
        #endif
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw DomainRecoveryBackupError.writeFailed("directory_open_failed_\(errno)")
        }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw DomainRecoveryBackupError.writeFailed("directory_fsync_failed_\(errno)")
        }
    }

    #if DEBUG
        private static let directorySyncFailureForTesting = OSAllocatedUnfairLock<Int32?>(initialState: nil)

        /// Makes every directory sync fail with `errno` (nil restores real syncing).
        package static func setDirectorySyncFailureForTesting(_ errno: Int32?) {
            directorySyncFailureForTesting.withLock { $0 = errno }
        }
    #endif

    private static func publishDurably(_ data: Data, to destination: URL, in directory: URL) throws {
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DomainRecoveryBackupError.writeFailed("temp_open_failed_\(errno)")
        }
        var descriptorIsOpen = true
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                    guard count > 0 else {
                        throw DomainRecoveryBackupError.writeFailed("write_failed_\(errno)")
                    }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw DomainRecoveryBackupError.writeFailed("fsync_failed_\(errno)")
            }
            close(descriptor)
            descriptorIsOpen = false
            // rename(2) replaces a regular file but fails on a directory; nothing is ever removed.
            guard rename(temporary.path, destination.path) == 0 else {
                throw DomainRecoveryBackupError.writeFailed("rename_failed_\(errno)")
            }
            try syncDirectory(directory)
        } catch {
            if descriptorIsOpen {
                close(descriptor)
            }
            unlink(temporary.path)
            throw error
        }
    }
}

/// Tabs a user closed on purpose through a raw-JSON editor (headless `close_tab`), keyed by
/// workspace and tab identity with the closed payload's digest. The headless guard exempts them
/// from the loss check only while the discarded payload is identical. Process-local: after a
/// restart an unchanged close is treated conservatively (a backup is made).
package final class DomainIntentionalTabClosures: Sendable {
    package static let shared = DomainIntentionalTabClosures()

    private let state = OSAllocatedUnfairLock<[UUID: [String: String]]>(initialState: [:])

    package func record(workspaceID: UUID, closedTab tab: [String: Any]) {
        guard let id = tab["id"] as? String, let digest = DomainRecoveryBackup.payloadDigest(tab) else { return }
        state.withLock { $0[workspaceID, default: [:]][id] = digest }
    }

    package func closures(for workspaceID: UUID) -> [String: String] {
        state.withLock { $0[workspaceID] ?? [:] }
    }
}
