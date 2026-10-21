import CryptoKit
import Foundation

package struct AgentAttachmentStore: Sendable {
    private static let attachmentsDirectoryName = "agent_attachments"

    package struct ImportResult {
        package let attachment: AgentFileAttachment
        package let fileURL: URL
    }

    /// What makes two attached files the same file: the name the user attached it under, its size, and
    /// its content. Name is part of it so `config.dev.json` and `config.prod.json` with identical bytes
    /// stay distinct, as do two empty `__init__.py` files.
    package struct Identity: Hashable, Sendable {
        package let fileName: String
        package let byteCount: Int
        package let digestHex: String
    }

    package enum Error: LocalizedError, Equatable {
        case invalidSourceURL
        case sourceIsNotFile
        case tooLarge(byteCount: Int, limit: Int)
        case failedToCopy

        package var errorDescription: String? {
            switch self {
            case .invalidSourceURL:
                "Attachment source must be a local file URL."
            case .sourceIsNotFile:
                "Only files can be attached, not folders."
            case let .tooLarge(byteCount, limit):
                "the file is \(Self.mebibytes(byteCount)), over the \(Self.mebibytes(limit)) attachment limit. Attach a smaller file."
            case .failedToCopy:
                "Failed to import the selected file."
            }
        }

        private static func mebibytes(_ bytes: Int) -> String {
            // Rounded up so a file one byte over the limit never reads as equal to it.
            String(format: "%.1f MiB", (Double(bytes) / (1024 * 1024) * 10).rounded(.up) / 10)
        }
    }

    private var fileManager: FileManager {
        .default
    }

    private let limits: OracleAttachmentLimits

    package init(limits: OracleAttachmentLimits = .production) {
        self.limits = limits
    }

    package static func managedStorageRootURL(for workspaceDirectory: URL) -> URL {
        workspaceDirectory
            .appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    /// Decides whether `sourceURL` may be attached, from its directory entry alone: it must be a
    /// regular file no larger than the per-file limit the loader enforces. Reads no file content, so a
    /// refused file costs nothing to refuse. Returns the standardized URL and the file's size.
    package func admit(sourceURL: URL) throws -> (url: URL, byteCount: Int) {
        let sourceURL = sourceURL.standardizedFileURL
        guard sourceURL.isFileURL else {
            throw Error.invalidSourceURL
        }
        guard let byteCount = regularFileByteCount(at: sourceURL) else {
            throw Error.sourceIsNotFile
        }
        guard byteCount <= limits.maxBytesPerFile else {
            throw Error.tooLarge(byteCount: byteCount, limit: limits.maxBytesPerFile)
        }
        return (sourceURL, byteCount)
    }

    package func identity(of fileURL: URL, fileName: String) -> Identity? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                return nil
            }
            // `read(upToCount:)` returns nil, not empty data, at end of file.
            guard let chunk, !chunk.isEmpty else { break }
            byteCount += chunk.count
            hasher.update(data: chunk)
        }
        let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Identity(fileName: fileName, byteCount: byteCount, digestHex: digestHex)
    }

    package func importFile(sourceURL: URL, workspaceDirectory: URL) throws -> ImportResult {
        let (sourceURL, byteCount) = try admit(sourceURL: sourceURL)

        let storageRoot = Self.managedStorageRootURL(for: workspaceDirectory)
        try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let kind = classifiedKind(of: sourceURL)
        let destinationURL = storageRoot
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension(for: sourceURL, kind: kind))

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw Error.failedToCopy
        }

        let attachment = AgentFileAttachment(
            source: .localFile(path: destinationURL.path),
            title: sourceURL.lastPathComponent,
            kind: kind,
            fileName: sourceURL.lastPathComponent,
            byteCount: byteCount
        )
        return ImportResult(attachment: attachment, fileURL: destinationURL)
    }

    package func clearConsumedLocalFiles(_ attachments: [AgentFileAttachment], workspaceDirectory: URL) {
        guard !attachments.isEmpty else { return }
        let storageRoot = Self.managedStorageRootURL(for: workspaceDirectory)
        let storagePrefix = storageRoot.path + "/"
        var localFilesToRemove: Set<URL> = []

        for attachment in attachments {
            guard case let .localFile(path) = attachment.source else { continue }
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            guard candidate.path.hasPrefix(storagePrefix) else { continue }
            localFilesToRemove.insert(candidate)
        }

        for fileURL in localFilesToRemove {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func regularFileByteCount(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true
        else { return nil }
        return values.fileSize ?? 0
    }

    private func classifiedKind(of url: URL) -> AttachmentKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .binary }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limits.maxBytesPerFile)) ?? Data()
        return AttachmentClassifier.kind(of: data)
    }

    private func fileExtension(for sourceURL: URL, kind: AttachmentKind) -> String {
        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !ext.isEmpty {
            return ext
        }
        switch kind {
        case .image: return "png"
        case .pdf: return "pdf"
        case .text: return "txt"
        case .binary: return "bin"
        }
    }
}
