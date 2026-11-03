import Darwin
import Foundation

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
                replacement: replacement.replacementBytes
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

    /// True when the discarded bytes cannot be reasoned about as raw JSON, or when any of their
    /// compose-tab identities is absent from the replacement (composed or stashed).
    package static func replacementDropsComposeTabs(discarded: Data, replacement: Data) -> Bool {
        guard let discardedIDs = composeTabIDs(in: discarded) else { return true }
        guard !discardedIDs.isEmpty else { return false }
        guard let object = jsonObject(replacement) else { return true }
        var surviving = composeTabIDs(in: object) ?? []
        for raw in object["stashedTabs"] as? [Any] ?? [] {
            if let tab = (raw as? [String: Any])?["tab"] as? [String: Any], let id = tab["id"] as? String {
                surviving.insert(id)
            }
        }
        return !discardedIDs.isSubset(of: surviving)
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

    private static func composeTabIDs(in data: Data) -> Set<String>? {
        jsonObject(data).flatMap(composeTabIDs(in:))
    }

    /// Nil when `composeTabs` is present but not an array of objects that all carry a string ID.
    private static func composeTabIDs(in object: [String: Any]) -> Set<String>? {
        guard let raw = object["composeTabs"] else { return [] }
        guard let tabs = raw as? [Any] else { return nil }
        var ids = Set<String>()
        for tab in tabs {
            guard let id = (tab as? [String: Any])?["id"] as? String else { return nil }
            ids.insert(id)
        }
        return ids
    }

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
            let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryDescriptor >= 0 else {
                throw DomainRecoveryBackupError.writeFailed("directory_open_failed_\(errno)")
            }
            defer { close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else {
                throw DomainRecoveryBackupError.writeFailed("directory_fsync_failed_\(errno)")
            }
        } catch {
            if descriptorIsOpen {
                close(descriptor)
            }
            unlink(temporary.path)
            throw error
        }
    }
}
