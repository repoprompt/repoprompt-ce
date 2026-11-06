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
package struct AgentSessionAttachmentStore {
    package struct Limits: Equatable {
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

    package struct RetentionResult: Equatable {
        /// Rewritten attachments keyed by attachment ID; the source points at the kept copy.
        package var retained: [UUID: AgentFileAttachment]
        /// Kept files removed to bring the session folder back under its cap.
        package var evictedPaths: [String]

        package init(retained: [UUID: AgentFileAttachment], evictedPaths: [String]) {
            self.retained = retained
            self.evictedPaths = evictedPaths
        }
    }

    package struct SweepResult: Equatable {
        package var removedSessionFolders: [UUID]
        package var removedTemporaryFiles: [String]
    }

    package enum HandoffMissingImagePolicy {
        case strict
        case omitMissingImagesForHumanHandoff
    }

    package enum HandoffCopyError: LocalizedError {
        case sourceUnavailable(UUID)
        case destinationInUse
        case sessionLimitExceeded

        package var errorDescription: String? {
            switch self {
            case let .sourceUnavailable(id):
                "The source image \(id.uuidString) is missing or is not owned by this conversation."
            case .destinationInUse:
                "The new conversation already has attachment storage."
            case .sessionLimitExceeded:
                "The handoff images exceed the conversation's attachment storage limit."
            }
        }
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

    /// Whether `path` names a regular file directly inside this session's folder. Symlinks are
    /// rejected and both sides are compared after resolving symlinks, so a link planted in (or
    /// pointing out of) the folder never widens what the path authorizes.
    package func isRetainedPath(_ path: String, sessionID: UUID) -> Bool {
        isRegularFile(URL(fileURLWithPath: path).standardizedFileURL, directlyIn: sessionFolderURL(sessionID: sessionID))
    }

    /// The kept copy of `attachmentID` in this session's folder, whatever its extension.
    package func locateRetainedFile(attachmentID: UUID, sessionID: UUID) -> URL? {
        let folder = sessionFolderURL(sessionID: sessionID)
        guard !isSymbolicLink(folder) else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let stem = attachmentID.uuidString
        guard let name = names.sorted().first(where: { ($0 as NSString).deletingPathExtension == stem }) else {
            return nil
        }
        let candidate = folder.appendingPathComponent(name)
        return isRetainedPath(candidate.path, sessionID: sessionID) ? candidate : nil
    }

    /// Rewrites local attachments whose file no longer exists to their kept copy in this session's
    /// folder, when one exists. Attachments that still resolve, or have no kept copy, are omitted.
    package func repairMissingPaths(_ attachments: [AgentFileAttachment], sessionID: UUID) -> [UUID: AgentFileAttachment] {
        var repaired: [UUID: AgentFileAttachment] = [:]
        for attachment in attachments where repaired[attachment.id] == nil {
            guard case let .localFile(path) = attachment.source,
                  !FileManager.default.fileExists(atPath: path),
                  let kept = locateRetainedFile(attachmentID: attachment.id, sessionID: sessionID),
                  kept.path != URL(fileURLWithPath: path).standardizedFileURL.path
            else { continue }
            repaired[attachment.id] = AgentFileAttachment(
                id: attachment.id,
                source: .localFile(path: kept.path),
                title: attachment.title,
                createdAt: attachment.createdAt,
                kind: attachment.kind,
                fileName: attachment.fileName,
                byteCount: attachment.byteCount
            )
        }
        return repaired
    }

    /// A fork owns independent files: retaining or deleting the source can never invalidate them.
    /// Copy the complete set into private staging before publishing the fresh destination folder.
    /// Strict callers fail on any unavailable image. Human handoff may omit genuinely absent
    /// image bytes, preserving transcript metadata; every other failure remains transactional.
    package func copyForHandoff(
        _ attachments: [AgentFileAttachment],
        sourceSessionID: UUID?,
        destinationSessionID: UUID,
        temporaryRoot: URL?,
        missingImagePolicy: HandoffMissingImagePolicy = .strict
    ) throws -> [UUID: AgentFileAttachment] {
        let local = attachments.filter {
            if case .localFile = $0.source { true } else { false }
        }
        guard !local.isEmpty else { return [:] }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let destinationFolder = sessionFolderURL(sessionID: destinationSessionID)
        guard sourceSessionID != destinationSessionID,
              !fileManager.fileExists(atPath: destinationFolder.path),
              !isSymbolicLink(destinationFolder)
        else { throw HandoffCopyError.destinationInUse }

        let staging = rootURL.appendingPathComponent(".handoff-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        var copied: [UUID: AgentFileAttachment] = [:]
        var sourcesByID: [UUID: AgentAttachmentSource] = [:]
        var totalBytes: Int64 = 0
        for attachment in local {
            try Task.checkCancellation()
            if let previous = sourcesByID[attachment.id] {
                guard previous == attachment.source else { throw HandoffCopyError.sourceUnavailable(attachment.id) }
                continue
            }
            sourcesByID[attachment.id] = attachment.source
            var stagedSource: URL?
            // A turn-end move can race attribute lookup/copy. Retry resolution once, and only
            // for ENOENT; storage, permissions, collisions and cancellation remain strict.
            for attempt in 0 ... 1 {
                guard let source = try handoffSource(
                    for: attachment, sessionID: sourceSessionID, temporaryRoot: temporaryRoot,
                    missingImagePolicy: missingImagePolicy
                ) else { break }
                do {
                    let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
                    let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
                    guard sourceSize <= limits.maxSessionFolderBytes - totalBytes else {
                        throw HandoffCopyError.sessionLimitExceeded
                    }
                    let fileExtension = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
                    let stagedFile = staging.appendingPathComponent(attachment.id.uuidString).appendingPathExtension(fileExtension)
                    try fileManager.copyItem(at: source, to: stagedFile)
                    stagedSource = stagedFile
                    break
                } catch {
                    let failure = error as NSError
                    guard attempt == 0, failure.domain == NSCocoaErrorDomain,
                          failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError
                    else { throw error }
                    try Task.checkCancellation()
                }
            }
            guard let stagedFile = stagedSource else { continue }
            // copyItem preserves symlinks. A source replaced during the copy must not publish a
            // link whose bytes still depend on the parent (or another folder).
            guard isRegularFile(stagedFile, directlyIn: staging) else {
                throw HandoffCopyError.sourceUnavailable(attachment.id)
            }
            let attributes = try fileManager.attributesOfItem(atPath: stagedFile.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= limits.maxSessionFolderBytes - totalBytes else {
                throw HandoffCopyError.sessionLimitExceeded
            }
            totalBytes += size
            copied[attachment.id] = AgentFileAttachment(
                id: attachment.id,
                source: .localFile(path: destinationFolder.appendingPathComponent(stagedFile.lastPathComponent).path),
                title: attachment.title,
                createdAt: attachment.createdAt,
                kind: attachment.kind,
                fileName: attachment.fileName,
                byteCount: attachment.byteCount
            )
        }
        try Task.checkCancellation()
        guard !copied.isEmpty else { return [:] }
        // moveItem refuses an existing destination. Never merge with or replace another owner.
        try fileManager.moveItem(at: staging, to: destinationFolder)
        do {
            try Task.checkCancellation()
        } catch {
            try? fileManager.removeItem(at: destinationFolder)
            throw error
        }
        return copied
    }

    private func handoffSource(
        for attachment: AgentFileAttachment, sessionID: UUID?, temporaryRoot: URL?,
        missingImagePolicy: HandoffMissingImagePolicy
    ) throws -> URL? {
        guard case let .localFile(path) = attachment.source else {
            throw HandoffCopyError.sourceUnavailable(attachment.id)
        }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let parent = candidate.deletingLastPathComponent()
        let ownedParent = parent.path == temporaryRoot?.standardizedFileURL.path
            || sessionID.map { parent.path == sessionFolderURL(sessionID: $0).path } == true
        guard ownedParent, !isSymbolicLink(rootURL), !isSymbolicLink(parent) else {
            throw HandoffCopyError.sourceUnavailable(attachment.id)
        }
        // attributesOfItem does not follow the final symlink, including a dangling one.
        if let attributes = try handoffAttributes(candidate) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  isRegularFile(candidate, directlyIn: parent)
            else { throw HandoffCopyError.sourceUnavailable(attachment.id) }
            return candidate
        }
        // Absence alone is insufficient: an unreadable/unsafe retained folder or ambiguous ID
        // must still fail. Do not use locateRetainedFile's lossy nil result for this decision.
        if let sessionID {
            let folder = sessionFolderURL(sessionID: sessionID)
            if let attributes = try handoffAttributes(folder) {
                guard !isSymbolicLink(rootURL), attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw HandoffCopyError.sourceUnavailable(attachment.id)
                }
                let matches = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
                    ($0 as NSString).deletingPathExtension == attachment.id.uuidString
                }
                guard matches.count <= 1 else { throw HandoffCopyError.sourceUnavailable(attachment.id) }
                if let name = matches.first {
                    let retained = folder.appendingPathComponent(name)
                    guard isRetainedPath(retained.path, sessionID: sessionID) else {
                        throw HandoffCopyError.sourceUnavailable(attachment.id)
                    }
                    return retained
                }
            }
        }
        guard attachment.kind == .image, missingImagePolicy == .omitMissingImagesForHumanHandoff else {
            throw HandoffCopyError.sourceUnavailable(attachment.id)
        }
        return nil
    }

    private func handoffAttributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain,
                  error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
            else { throw error }
            return nil
        }
    }

    /// Moves (falling back to copy) each temporary attachment into the session folder.
    ///
    /// Only files directly inside `temporaryRoot` are touched, so a user's original file is never
    /// moved. Attachments whose temporary copy is already gone are skipped and keep their path.
    package func retain(
        _ attachments: [AgentFileAttachment],
        sessionID: UUID,
        temporaryRoot: URL,
        now: Date = Date()
    ) -> RetentionResult {
        let fileManager = FileManager.default
        let temporaryPrefix = temporaryRoot.standardizedFileURL.path + "/"
        let folder = sessionFolderURL(sessionID: sessionID)
        var retained: [UUID: AgentFileAttachment] = [:]
        var folderReady = false
        guard !isSymbolicLink(folder) else {
            return RetentionResult(retained: [:], evictedPaths: [])
        }

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
            guard let destination = placeFile(source, attachmentID: attachment.id, isImage: attachment.kind == .image, in: folder) else { continue }
            // Order eviction by retention time, not by the original file's preserved timestamp.
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: destination.path)
            retained[attachment.id] = AgentFileAttachment(
                id: attachment.id,
                source: .localFile(path: destination.path),
                title: attachment.title,
                createdAt: attachment.createdAt,
                kind: attachment.kind,
                fileName: attachment.fileName,
                byteCount: attachment.byteCount
            )
        }

        let evicted = retained.isEmpty ? [] : enforceSessionCap(sessionID: sessionID)
        return RetentionResult(retained: retained, evictedPaths: evicted)
    }

    /// Removes the oldest kept images until the session folder fits its cap.
    @discardableResult
    package func enforceSessionCap(sessionID: UUID) -> [String] {
        let folder = sessionFolderURL(sessionID: sessionID)
        guard !isSymbolicLink(folder) else { return [] }
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
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                // A concurrent move for this session may already have evicted it; it no longer
                // counts toward the cap, so treat it as removed rather than evicting a newer file.
                guard !FileManager.default.fileExists(atPath: file.url.path) else { continue }
            }
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

    /// A per-session link cannot delegate one session's image authority to another folder.
    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func isRegularFile(_ candidate: URL, directlyIn folder: URL) -> Bool {
        guard let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              !isSymbolicLink(folder)
        else { return false }
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        let resolved = candidate.resolvingSymlinksInPath().path
        return resolved.hasPrefix(prefix) && !resolved.dropFirst(prefix.count).contains("/")
    }

    private func placeFile(_ source: URL, attachmentID: UUID, isImage: Bool, in folder: URL) -> URL? {
        let fileManager = FileManager.default
        let size = ((try? fileManager.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if isImage, size > limits.maxRetainedImageBytes,
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
