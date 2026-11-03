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
        // Cheap structural prefilter: a replacement that keeps every compose-tab identity cannot
        // lose an unreadable tab. Only otherwise is the exact (model) decode consulted, so closing
        // a tab never produces a backup.
        guard discarded != replacement,
              DomainRecoveryBackup.replacementDropsComposeTabs(discarded: discarded, replacement: replacement),
              documentRequiresPreservation(discarded)
        else { return }
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
        do {
            let url = try DomainRecoveryBackup.preserve(
                documentBytes: documentBytes,
                documentURL: documentURL,
                validatePath: AppProfileLocations.current.validateMetadataFile
            )
            logger.notice(
                "Preserved unreadable workspace document (\(droppedComposeTabCount, privacy: .public) compose tab(s) dropped) at \(url.path, privacy: .private)"
            )
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
        let verdict = WorkspaceManagerViewModel.workspaceDocumentDecodesLossily(documentBytes: bytes)
        verdicts.withLock { $0.store(verdict, for: digest) }
        return verdict
    }

    /// Replacement for the app's non-domain writers (`WorkspaceDiskWriter` backends and direct
    /// saves), which only run when no domain authority owns the document. Check, preserve, and the
    /// atomic replacement happen under one per-document lock, so in-process writers cannot race
    /// between the check and the write. The lock never covers more than one document.
    static func replaceDocument(_ data: Data, at url: URL) throws {
        let documentLock = lock(for: url)
        documentLock.lock()
        defer { documentLock.unlock() }
        try AppProfileLocations.current.validateMetadataFile(url)
        if let current = try? Data(contentsOf: url) {
            try protectReplacement(discarding: current, replacement: data, documentURL: url)
        }
        try data.write(to: url, options: .atomic)
    }

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
        "RepoPrompt couldn't save a recovery copy of workspace tabs it couldn't read (\(reason))."
    }
}
