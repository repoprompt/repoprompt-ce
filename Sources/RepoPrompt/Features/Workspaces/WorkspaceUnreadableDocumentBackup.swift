import Foundation
import os
import OSLog
import RepoPromptDomainRuntime
import RepoPromptShared

/// The app's recovery-backup policy for workspace documents whose compose tabs it cannot all
/// decode (#335).
///
/// `WorkspaceModel` decoding is deliberately lossy at the smallest unit (an unreadable tab is
/// dropped; an unreadable array becomes a fresh `T1`), so a lossy value saved back would replace
/// tabs this build could not read. The invariant enforced here and in the domain runtime is
/// stateless: durable bytes that decode lossily are never replaced (working journal or
/// `workspace.json`) until a verified, fsynced, content-addressed copy of them exists. The backup
/// file is the only record that the obligation was met, so it survives restarts.
///
/// Nothing here requires the main actor or AppKit: the guard runs inside domain persistence locks.
enum WorkspaceUnreadableDocumentBackup {
    static let fileNamePrefix = DomainRecoveryBackup.fileNamePrefix
    private static let logger = Logger(subsystem: "com.repoprompt.workspace", category: "decode")

    /// Full-digest `workspace.unreadable-<sha256>.json` next to `documentURL`.
    static func backupURL(for documentURL: URL, documentBytes: Data) -> URL {
        DomainRecoveryBackup.backupURL(documentURL: documentURL, documentBytes: documentBytes)
    }

    /// The app-side guard installed in the app's domain runtime configuration.
    static let durableReplacementGuard = DomainDurableReplacementGuard { replacement in
        try WorkspaceUnreadableDocumentBackup.protectReplacement(
            discarding: replacement.discardedBytes,
            replacement: replacement.replacementBytes,
            documentURL: replacement.documentURL
        )
    }

    /// Ensures `discarded` is recoverable before it is replaced by `replacement`. Throws
    /// `WorkspaceRecoveryBackupBlockedError` when a required backup cannot be made durable.
    static func protectReplacement(discarding discarded: Data, replacement: Data, documentURL: URL) throws {
        // The exact (model) decode decides; surviving tab identities are not evidence that an
        // unreadable payload survived. Clean documents never produce a backup, so closing a tab
        // in a readable workspace never does either. The verdict is memoized by digest.
        guard discarded != replacement, documentRequiresPreservation(discarded) else { return }
        do {
            try DomainRecoveryBackup.preserve(
                documentBytes: discarded,
                documentURL: documentURL,
                validatePath: AppProfileLocations.current.validateMetadataFile
            )
        } catch {
            logger.error(
                "Refusing to replace unreadable workspace document without a recovery backup: \(String(describing: error), privacy: .public)"
            )
            throw WorkspaceRecoveryBackupBlockedError(reason: String(describing: error))
        }
    }

    /// Eager, best-effort preservation at decode time. Enforcement happens at replacement time, so
    /// a failure here is only logged. The canonical document need not exist (journal bytes), but
    /// the workspace directory must: synthetic or deleted projections never create directories.
    @discardableResult
    static func preserveIfNeeded(documentBytes: Data, documentURL: URL, droppedComposeTabCount: Int) -> URL? {
        guard droppedComposeTabCount > 0,
              FileManager.default.fileExists(atPath: documentURL.deletingLastPathComponent().path)
        else { return nil }
        // Projection decodes repeat for the same bytes; once this process has a durable receipt
        // for them, the eager path does not re-read and re-hash the backup. Enforcement at
        // replacement time always re-verifies.
        let receiptKey = "\(documentURL.standardizedFileURL.path)|\(DomainContentDigest.sha256(documentBytes))"
        if eagerReceipts.withLock({ $0.contains(receiptKey) }) {
            return backupURL(for: documentURL, documentBytes: documentBytes)
        }
        do {
            let url = try DomainRecoveryBackup.preserve(
                documentBytes: documentBytes,
                documentURL: documentURL,
                validatePath: AppProfileLocations.current.validateMetadataFile
            )
            logger.notice(
                "Preserved unreadable workspace document (\(droppedComposeTabCount, privacy: .public) compose tab(s) dropped) at \(url.path, privacy: .private)"
            )
            eagerReceipts.withLock { _ = $0.insert(receiptKey) }
            return url
        } catch {
            logger.error(
                "Failed to preserve unreadable workspace document; replacements stay blocked until it succeeds: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Whether this build cannot represent every compose tab in `bytes` (or cannot decode them at
    /// all). The verdict is a pure function of the bytes, so it is memoized by digest.
    static func documentRequiresPreservation(_ bytes: Data) -> Bool {
        let digest = DomainContentDigest.sha256(bytes)
        if let cached = verdicts.withLock({ $0.value(for: digest) }) {
            return cached
        }
        #if DEBUG
            lossyDecodeCountForTesting.withLock { $0 += 1 }
        #endif
        let verdict = WorkspaceManagerViewModel.workspaceDocumentDecodesLossily(documentBytes: bytes)
        verdicts.withLock { $0.store(verdict, for: digest) }
        return verdict
    }

    /// Records that `bytes` were produced by the app's own encoder, so they are not lossy.
    static func recordAppEncodedDocument(_ bytes: Data) {
        let digest = DomainContentDigest.sha256(bytes)
        verdicts.withLock { $0.store(false, for: digest) }
    }

    #if DEBUG
        static let lossyDecodeCountForTesting = OSAllocatedUnfairLock(initialState: 0)
    #endif

    /// Replacement for the app's non-domain writers (`WorkspaceDiskWriter` backends and direct
    /// saves), which only run when no domain authority owns the document. Check, preserve, and the
    /// atomic replacement happen under one per-document lock, so in-process writers cannot race
    /// between the check and the write. The lock never covers more than one document.
    static func replaceDocument(_ data: Data, at url: URL) throws {
        try AppProfileLocations.current.validateMetadataFile(url)
        // Only workspace documents carry the obligation; the workspace index and other metadata
        // sharing this writer are written as before.
        guard url.lastPathComponent == documentFileName else {
            try data.write(to: url, options: .atomic)
            return
        }
        let documentLock = lock(for: url)
        documentLock.lock()
        defer { documentLock.unlock() }
        let current: Data?
        do {
            current = try DomainRecoveryBackup.existingBytes(at: url)
        } catch {
            // An original that exists but cannot be read is never renamed over unprotected.
            throw WorkspaceRecoveryBackupBlockedError(reason: "saved_document_unreadable: \(error.localizedDescription)")
        }
        if let current {
            try protectReplacement(discarding: current, replacement: data, documentURL: url)
        }
        try data.write(to: url, options: .atomic)
    }

    static let documentFileName = "workspace.json"

    // MARK: - Private

    private struct VerdictCache {
        private var entries: [String: Bool] = [:]
        private var order: [String] = []
        private let limit = 256

        func value(for digest: String) -> Bool? {
            entries[digest]
        }

        mutating func store(_ verdict: Bool, for digest: String) {
            if entries.updateValue(verdict, forKey: digest) == nil {
                order.append(digest)
            }
            while order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
    }

    private static let verdicts = OSAllocatedUnfairLock(initialState: VerdictCache())
    private static let eagerReceipts = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Held only to look up a document's lock, never across disk I/O.
    private static let documentLocks = OSAllocatedUnfairLock(initialState: [String: NSLock]())

    private static func lock(for url: URL) -> NSLock {
        let key = url.standardizedFileURL.path
        return documentLocks.withLock { locks in
            if let existing = locks[key] {
                return existing
            }
            let created = NSLock()
            locks[key] = created
            return created
        }
    }
}

/// A save was refused because the bytes it would replace need a recovery backup that could not be
/// made durable. Nothing on disk changed; the in-memory draft is retained and a later save retries.
struct WorkspaceRecoveryBackupBlockedError: Error, Equatable, LocalizedError {
    let reason: String

    var errorDescription: String? {
        "RepoPrompt couldn't save a recovery copy of workspace tabs it couldn't read: "
            + WorkspaceRecoveryBackupReason(raw: reason).summary
    }
}

/// A readable account of why a recovery backup could not be made, derived from the raw domain or
/// file-system diagnostic, with guidance that matches the cause.
struct WorkspaceRecoveryBackupReason: Equatable {
    enum Kind: Equatable {
        case diskFull
        case permissionDenied
        case readOnlyVolume
        case conflictingEntry
        case unreadableOriginal
        case conflictingChanges
        case other
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    init(raw: String) {
        if raw.contains("conflicting_changes") {
            kind = .conflictingChanges
        } else if raw.contains("saved_document_unreadable") {
            kind = .unreadableOriginal
        } else if raw.contains("conflictingEntry") {
            kind = .conflictingEntry
        } else if let code = Self.errnoCode(in: raw) {
            switch code {
            case ENOSPC, EDQUOT: kind = .diskFull
            case EACCES, EPERM: kind = .permissionDenied
            case EROFS: kind = .readOnlyVolume
            default: kind = .other
            }
        } else {
            kind = .other
        }
    }

    var summary: String {
        switch kind {
        case .diskFull: "the disk is full"
        case .permissionDenied: "RepoPrompt doesn't have permission to write in the workspace folder"
        case .readOnlyVolume: "the workspace folder is on a read-only volume"
        case .conflictingEntry: "another item is in the way of the recovery copy in the workspace folder"
        case .unreadableOriginal: "the saved workspace file can't be read"
        case .conflictingChanges: "another window changed the same tabs, and RepoPrompt won't overwrite those changes"
        case .other: "the recovery copy couldn't be written"
        }
    }

    var guidance: String {
        switch kind {
        case .diskFull: "Free some disk space, then try again."
        case .permissionDenied, .readOnlyVolume: "Check the workspace folder's permissions, then try again."
        case .conflictingEntry: "Move the item named like workspace.unreadable-….json out of the workspace folder, then try again."
        case .unreadableOriginal: "Check the workspace file's permissions, then try again."
        case .conflictingChanges: "Copy anything you need from this window, then discard your changes to load the other window's version."
        case .other: "Check the workspace folder in Finder, then try again."
        }
    }

    private static func errnoCode(in raw: String) -> Int32? {
        guard let range = raw.range(of: #"_failed_(\d+)"#, options: .regularExpression) else { return nil }
        return Int32(raw[range].split(separator: "_").last ?? "")
    }
}
