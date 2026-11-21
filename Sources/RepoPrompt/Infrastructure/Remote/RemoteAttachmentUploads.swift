import Foundation
import RepoPromptDomainRuntime
import RepoPromptRemoteProtocol

/// Stages only the currently paired phone's uncommitted submission. The gateway
/// clears the buffer when it revokes pairing or stops. Contents never enter logs.
@MainActor
struct RemoteAttachmentUploads {
    struct File {
        let name: String
        let size: Int
        var bytes = Data()
    }

    private var batches: [UUID: [UUID: File]] = [:]
    private var expiresAt: Date = .distantPast

    mutating func append(_ chunk: RemoteAttachmentChunk, now: Date = Date()) throws {
        expire(now)
        guard Self.isValidFileName(chunk.fileName),
              (0 ... RemoteAttachmentLimits.maxFileBytes).contains(chunk.fileSize),
              (0 ... chunk.fileSize).contains(chunk.offset),
              chunk.bytes.count <= min(RemoteAttachmentLimits.maxChunkBytes, chunk.fileSize - chunk.offset),
              !chunk.bytes.isEmpty || chunk.fileSize == 0
        else { throw invalidUpload }

        if let file = batches[chunk.submissionID]?[chunk.attachmentID] {
            guard file.name == chunk.fileName, file.size == chunk.fileSize else { throw invalidUpload }
            if chunk.offset < file.bytes.count {
                let end = chunk.offset + chunk.bytes.count
                guard end <= file.bytes.count,
                      file.bytes[chunk.offset ..< end].elementsEqual(chunk.bytes)
                else { throw invalidUpload }
                return
            }
            guard file.bytes.count == chunk.offset else { throw invalidUpload }
        } else {
            guard chunk.offset == 0 else { throw invalidUpload }
            let files = batches.values.flatMap(\.values)
            if files.count >= RemoteAttachmentLimits.maxCount
                || files.reduce(chunk.fileSize, { $0 + $1.size }) > RemoteAttachmentLimits.maxTotalBytes
            {
                // An interrupted draft can be retried immediately under a new
                // submission ID instead of keeping the old quota reserved.
                batches = batches.filter { $0.key == chunk.submissionID }
            }
            let retainedFiles = batches.values.flatMap(\.values)
            guard retainedFiles.count < RemoteAttachmentLimits.maxCount,
                  retainedFiles.reduce(chunk.fileSize, { $0 + $1.size }) <= RemoteAttachmentLimits.maxTotalBytes
            else { throw invalidUpload }
            batches[chunk.submissionID, default: [:]][chunk.attachmentID] = File(name: chunk.fileName, size: chunk.fileSize)
        }

        batches[chunk.submissionID]?[chunk.attachmentID]?.bytes.append(chunk.bytes)
        expiresAt = now.addingTimeInterval(120)
    }

    mutating func take(submissionID: UUID, ids: [UUID], now: Date = Date()) throws -> [File] {
        expire(now)
        guard !ids.isEmpty, Set(ids).count == ids.count,
              let files = batches[submissionID], files.count == ids.count
        else { throw invalidUpload }
        let ordered = ids.compactMap { files[$0] }
        guard ordered.count == ids.count, ordered.allSatisfy({ $0.bytes.count == $0.size }) else {
            throw invalidUpload
        }
        batches.removeValue(forKey: submissionID)
        return ordered
    }

    mutating func expire(_ now: Date = Date()) {
        if now >= expiresAt { batches.removeAll() }
    }

    static func importFiles(_ files: [File], workspaceDirectory: URL) throws -> [AgentFileAttachment] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentAttachmentStore()
        var imported: [AgentFileAttachment] = []
        do {
            for file in files {
                let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
                let source = directory.appendingPathComponent(file.name, isDirectory: false)
                try file.bytes.write(to: source, options: .atomic)
                try imported.append(store.importFile(sourceURL: source, workspaceDirectory: workspaceDirectory).attachment)
            }
            return imported
        } catch {
            store.clearConsumedLocalFiles(imported, workspaceDirectory: workspaceDirectory)
            throw RemoteAgentControlServiceError.commandRejected("The Mac could not import the selected attachments.")
        }
    }

    private static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private var invalidUpload: RemoteAgentControlServiceError {
        .commandRejected("The attachment upload was incomplete or invalid. Send the message again to retry.")
    }
}
