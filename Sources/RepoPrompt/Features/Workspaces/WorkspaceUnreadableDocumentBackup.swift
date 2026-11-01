import CryptoKit
import Foundation
import OSLog
import RepoPromptShared

/// Preserves the original bytes of a `workspace.json` whose compose tabs could not all be decoded.
///
/// `WorkspaceModel` decoding is deliberately lossy at the smallest unit (a single unreadable tab is
/// dropped; an unreadable array becomes a fresh `T1`), and nothing downstream distinguishes that
/// lossy value from a clean one once it is saved back. Writing a content-addressed sibling copy at
/// decode time keeps the user's original data recoverable no matter which writer later replaces
/// the file (#335). The copy is idempotent per document content, so repeated loads of the same
/// bytes never pile up backups.
enum WorkspaceUnreadableDocumentBackup {
    static let fileNamePrefix = "workspace.unreadable-"
    private static let logger = Logger(subsystem: "com.repoprompt.workspace", category: "decode")

    /// `workspace.unreadable-<16 hex digest chars>.json` next to `documentURL`.
    static func backupURL(for documentURL: URL, documentBytes: Data) -> URL {
        let digest = Data(SHA256.hash(data: documentBytes)).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return documentURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileNamePrefix)\(digest).json", isDirectory: false)
    }

    /// Writes the backup when `droppedComposeTabCount` is positive and the original document still
    /// exists at `documentURL`. Returns the backup location when one exists afterwards (newly
    /// written or already present); failures are logged and never surface to the loader.
    @discardableResult
    static func preserveIfNeeded(
        documentBytes: Data,
        documentURL: URL,
        droppedComposeTabCount: Int
    ) -> URL? {
        guard droppedComposeTabCount > 0 else { return nil }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: documentURL.path) else { return nil }
        let backupURL = backupURL(for: documentURL, documentBytes: documentBytes)
        if fileManager.fileExists(atPath: backupURL.path) {
            return backupURL
        }
        do {
            try AppProfileLocations.current.validateMetadataFile(backupURL)
            // Content-addressed name: a concurrent writer can only produce identical bytes.
            try documentBytes.write(to: backupURL, options: .atomic)
            logger.notice(
                "Preserved unreadable workspace document (\(droppedComposeTabCount, privacy: .public) compose tab(s) dropped) at \(backupURL.path, privacy: .private)"
            )
            return backupURL
        } catch {
            logger.error(
                "Failed to preserve unreadable workspace document: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}
