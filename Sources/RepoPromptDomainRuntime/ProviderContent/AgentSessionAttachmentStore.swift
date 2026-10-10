import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Session-lifetime storage for images sent in Agent Mode turns.
///
/// Composer attachments start as temporary copies under the managed temporary store
/// (`AgentAttachmentStore.managedStorageRootURL`). When a turn finishes, the copies are moved into
/// `<workspace>/AgentSessions/attachments/<sessionID>/<attachmentID>.<ext>` so the transcript keeps
/// rendering them for the life of the session. Deleting the session deletes the folder; a startup
/// sweep removes folders whose session file no longer exists and stale temporary copies.
package struct AgentSessionAttachmentStore: Sendable {
    package struct Limits: Sendable, Equatable {
        /// Images up to this size are kept byte-for-byte; larger ones are kept as a downscaled copy.
        package var maxRetainedImageBytes: Int64
        /// Long-edge pixel size of the downscaled copy kept for oversized images.
        package var downscaledLongEdgePixels: Int
        /// Per-session folder cap; the oldest kept images are evicted first when exceeded.
        package var maxSessionFolderBytes: Int64

        package static let standard = Limits(
            maxRetainedImageBytes: 20 * 1024 * 1024,
            downscaledLongEdgePixels: 4096,
            maxSessionFolderBytes: 200 * 1024 * 1024
        )

        package init(maxRetainedImageBytes: Int64, downscaledLongEdgePixels: Int, maxSessionFolderBytes: Int64) {
            self.maxRetainedImageBytes = maxRetainedImageBytes
            self.downscaledLongEdgePixels = downscaledLongEdgePixels
            self.maxSessionFolderBytes = maxSessionFolderBytes
        }
    }

    package struct RetentionResult: Sendable, Equatable {
        /// Rewritten attachments keyed by attachment ID; the source points at the kept copy.
        package var retained: [UUID: AgentImageAttachment]
        /// Kept files removed to bring the session folder back under its cap.
        package var evictedPaths: [String]
    }

    package struct SweepResult: Sendable, Equatable {
        package var removedSessionFolders: [UUID]
        package var removedTemporaryFiles: [String]
    }

    package static let directoryName = "attachments"
    package static let temporaryFileMaxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Orphaned folders younger than this are left alone so a session whose transcript has not been
    /// written yet cannot lose its images to a concurrent sweep.
    package static let orphanFolderGracePeriod: TimeInterval = 10 * 60

    package let rootURL: URL
    package let limits: Limits

    package init(rootURL: URL, limits: Limits = .standard) {
        self.rootURL = rootURL.standardizedFileURL
        self.limits = limits
    }

    package init(agentSessionsFolder: URL, limits: Limits = .standard) {
        self.init(rootURL: Self.rootURL(forAgentSessionsFolder: agentSessionsFolder), limits: limits)
    }

    package static func rootURL(forAgentSessionsFolder agentSessionsFolder: URL) -> URL {
        agentSessionsFolder
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    package func sessionFolderURL(sessionID: UUID) -> URL {
        rootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Whether `path` names a file directly inside this session's folder.
    package func isRetainedPath(_ path: String, sessionID: UUID) -> Bool {
        let prefix = sessionFolderURL(sessionID: sessionID).path + "/"
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(prefix) && !standardized.dropFirst(prefix.count).contains("/")
    }

    /// Moves (falling back to copy) each temporary attachment into the session folder.
    ///
    /// Only files directly inside `temporaryRoot` are touched, so a user's original file is never
    /// moved. Attachments whose temporary copy is already gone are skipped and keep their path.
    package func retain(
        _ attachments: [AgentImageAttachment],
        sessionID: UUID,
        temporaryRoot: URL,
        now: Date = Date()
    ) -> RetentionResult {
        let fileManager = FileManager.default
        let temporaryPrefix = temporaryRoot.standardizedFileURL.path + "/"
        let folder = sessionFolderURL(sessionID: sessionID)
        var retained: [UUID: AgentImageAttachment] = [:]
        var folderReady = false

        for attachment in attachments where retained[attachment.id] == nil {
            guard case let .localFile(path) = attachment.source else { continue }
            let source = URL(fileURLWithPath: path).standardizedFileURL
            guard source.path.hasPrefix(temporaryPrefix),
                  !source.path.dropFirst(temporaryPrefix.count).contains("/"),
                  fileManager.fileExists(atPath: source.path)
            else { continue }
            if !folderReady {
                do {
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                } catch {
                    break
                }
                folderReady = true
            }
            guard let destination = placeFile(source, attachmentID: attachment.id, in: folder) else { continue }
            // Order eviction by retention time, not by the original file's preserved timestamp.
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: destination.path)
            retained[attachment.id] = AgentImageAttachment(
                id: attachment.id,
                source: .localFile(path: destination.path),
                title: attachment.title,
                createdAt: attachment.createdAt
            )
        }

        let evicted = retained.isEmpty ? [] : enforceSessionCap(sessionID: sessionID)
        return RetentionResult(retained: retained, evictedPaths: evicted)
    }

    /// Removes the oldest kept images until the session folder fits its cap.
    @discardableResult
    package func enforceSessionCap(sessionID: UUID) -> [String] {
        let folder = sessionFolderURL(sessionID: sessionID)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, size: Int64, modified: Date)] = entries.compactMap { entry in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            return (
                folder.appendingPathComponent(entry.lastPathComponent),
                Int64(values?.fileSize ?? 0),
                values?.contentModificationDate ?? .distantPast
            )
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > limits.maxSessionFolderBytes else { return [] }

        files.sort { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified < rhs.modified }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        var evicted: [String] = []
        for file in files where total > limits.maxSessionFolderBytes {
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            evicted.append(file.url.path)
        }
        return evicted
    }

    package func removeSessionFolder(sessionID: UUID) {
        try? FileManager.default.removeItem(at: sessionFolderURL(sessionID: sessionID))
    }

    package static func removeSessionFolder(sessionID: UUID, agentSessionsFolder: URL) {
        AgentSessionAttachmentStore(agentSessionsFolder: agentSessionsFolder).removeSessionFolder(sessionID: sessionID)
    }

    /// Removes session folders whose `AgentSession-<id>.json` no longer exists, and temporary copies
    /// older than `temporaryFileMaxAge` that are not pending in any draft.
    package static func sweep(
        agentSessionsFolder: URL,
        temporaryRoot: URL?,
        protectedSessionIDs: Set<UUID>,
        protectedTemporaryPaths: Set<String>,
        now: Date = Date(),
        temporaryFileMaxAge: TimeInterval = Self.temporaryFileMaxAge,
        orphanFolderGracePeriod: TimeInterval = Self.orphanFolderGracePeriod
    ) -> SweepResult {
        let fileManager = FileManager.default
        let root = rootURL(forAgentSessionsFolder: agentSessionsFolder)
        var removedFolders: [UUID] = []
        let folderKeys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        if let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: folderKeys,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                guard let sessionID = UUID(uuidString: entry.lastPathComponent),
                      !protectedSessionIDs.contains(sessionID)
                else { continue }
                let values = try? entry.resourceValues(forKeys: Set(folderKeys))
                guard values?.isDirectory == true else { continue }
                let sessionFile = agentSessionsFolder.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
                guard !fileManager.fileExists(atPath: sessionFile.path) else { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) >= orphanFolderGracePeriod else { continue }
                if (try? fileManager.removeItem(at: root.appendingPathComponent(entry.lastPathComponent))) != nil {
                    removedFolders.append(sessionID)
                }
            }
        }

        var removedTemporaryFiles: [String] = []
        if let temporaryRoot {
            let temporaryRoot = temporaryRoot.standardizedFileURL
            let protected = Set(protectedTemporaryPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            let fileKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .addedToDirectoryDateKey]
            let entries = (try? fileManager.contentsOfDirectory(
                at: temporaryRoot,
                includingPropertiesForKeys: fileKeys,
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries {
                let path = temporaryRoot.appendingPathComponent(entry.lastPathComponent).path
                guard !protected.contains(path) else { continue }
                let values = try? entry.resourceValues(forKeys: Set(fileKeys))
                guard values?.isRegularFile == true else { continue }
                let stamp = max(
                    values?.contentModificationDate ?? .distantPast,
                    values?.addedToDirectoryDate ?? .distantPast
                )
                guard now.timeIntervalSince(stamp) > temporaryFileMaxAge else { continue }
                if (try? fileManager.removeItem(atPath: path)) != nil {
                    removedTemporaryFiles.append(path)
                }
            }
        }

        return SweepResult(removedSessionFolders: removedFolders, removedTemporaryFiles: removedTemporaryFiles)
    }

    // MARK: - Placement

    private func placeFile(_ source: URL, attachmentID: UUID, in folder: URL) -> URL? {
        let fileManager = FileManager.default
        let size = ((try? fileManager.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if size > limits.maxRetainedImageBytes,
           let downscaled = writeDownscaledCopy(of: source, attachmentID: attachmentID, in: folder)
        {
            try? fileManager.removeItem(at: source)
            return downscaled
        }

        let fileExtension = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let destination = folder
            .appendingPathComponent(attachmentID.uuidString)
            .appendingPathExtension(fileExtension)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            do {
                try fileManager.copyItem(at: source, to: destination)
                try? fileManager.removeItem(at: source)
            } catch {
                return nil
            }
        }
        return destination
    }

    private func writeDownscaledCopy(of source: URL, attachmentID: UUID, in folder: URL) -> URL? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, limits.downscaledLongEdgePixels)
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else { return nil }

        let opaqueAlphaInfos: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        let hasAlpha = !opaqueAlphaInfos.contains(image.alphaInfo)
        let type: UTType = hasAlpha ? .png : .jpeg
        let destination = folder
            .appendingPathComponent(attachmentID.uuidString)
            .appendingPathExtension(hasAlpha ? "png" : "jpg")
        try? FileManager.default.removeItem(at: destination)
        guard let imageDestination = CGImageDestinationCreateWithURL(
            destination as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties: CFDictionary? = hasAlpha
            ? nil
            : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(imageDestination, image, properties)
        guard CGImageDestinationFinalize(imageDestination) else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        return destination
    }
}
