import Darwin
import Foundation
import RepoPromptWorkspaceCore

package struct OracleAttachmentRequest: Equatable {
    package let index: Int
    package let path: String
    package let title: String?
    /// Set for the deprecated `images` alias: the file must be a PNG, JPEG, GIF or WebP image, exactly
    /// as v1.6.0's `images` contract required, so the alias never widens what an old caller can send.
    package let imageOnly: Bool

    package init(index: Int, path: String, title: String?, imageOnly: Bool = false) {
        self.index = index
        self.path = path
        self.title = title
        self.imageOnly = imageOnly
    }
}

package struct OracleImageRootIdentity: Equatable {
    package let device: dev_t
    package let inode: ino_t
    package let generation: UInt32
    package let mode: mode_t
}

package struct OracleImagePhysicalRootCapture: Equatable {
    package let physicalRootPath: String
    package let resolvedPhysicalRootPath: String
    package let rootIdentity: OracleImageRootIdentity

    package static func capture(
        physicalRootPath: String,
        index: Int,
        beforeAcquiringResolvedRoot: (() throws -> Void)? = nil
    ) throws -> OracleImagePhysicalRootCapture {
        let physicalRootPath = StandardizedPath.absolute(physicalRootPath)
        guard let resolvedPath = physicalRootPath.withCString({ Darwin.realpath($0, nil) }) else {
            throw OracleAttachmentLoadError.missingOrUnreadable(index: index)
        }
        defer { free(resolvedPath) }
        // Foundation path standardization can strip /private on Darwin; keep realpath's
        // symlink-free spelling for descriptor acquisition, separate from request aliases.
        let resolvedPhysicalRootPath = String(cString: resolvedPath)
        try beforeAcquiringResolvedRoot?()
        let descriptor = try openResolvedDirectoryWithoutSymlinks(resolvedPhysicalRootPath, index: index)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw OracleAttachmentLoadError.missingOrUnreadable(index: index)
        }
        return OracleImagePhysicalRootCapture(
            physicalRootPath: physicalRootPath,
            resolvedPhysicalRootPath: resolvedPhysicalRootPath,
            rootIdentity: OracleImageRootIdentity(
                device: info.st_dev,
                inode: info.st_ino,
                generation: info.st_gen,
                mode: info.st_mode
            )
        )
    }

    /// Acquire every resolved component without following a substitution made after resolution.
    package static func openResolvedDirectoryWithoutSymlinks(_ path: String, index: Int) throws -> Int32 {
        var descriptor = Darwin.open("/", O_SEARCH | O_CLOEXEC)
        guard descriptor >= 0 else { throw OracleAttachmentLoadError.missingOrUnreadable(index: index) }
        do {
            let components = path.split(separator: "/")
            for (offset, component) in components.enumerated() {
                let access = offset == components.count - 1 ? O_RDONLY | O_DIRECTORY : O_SEARCH
                let next = String(component).withCString {
                    Darwin.openat(descriptor, $0, access | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    if errno == ELOOP || errno == ENOTDIR {
                        throw OracleAttachmentLoadError.unsafePath(index: index)
                    }
                    throw OracleAttachmentLoadError.missingOrUnreadable(index: index)
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    package func projection(logicalRootPath: String) -> OracleImageRootProjection {
        OracleImageRootProjection(
            logicalRootPath: StandardizedPath.absolute(logicalRootPath),
            physicalRootPath: physicalRootPath,
            resolvedPhysicalRootPath: resolvedPhysicalRootPath,
            rootIdentity: rootIdentity
        )
    }
}

package struct OracleImageRootProjection: Equatable {
    package let logicalRootPath: String
    package let physicalRootPath: String
    package let resolvedPhysicalRootPath: String
    package let rootIdentity: OracleImageRootIdentity
}

/// One physical workspace root to capture, together with every logical alias whose paths
/// should resolve into it. Built from workspace namespace bindings before authority capture.
package struct OracleImageRootSpec: Equatable {
    package let physicalRootPath: String
    package let logicalRootPaths: [String]

    package init(physicalRootPath: String, logicalRootPaths: [String]) {
        self.physicalRootPath = physicalRootPath
        self.logicalRootPaths = logicalRootPaths
    }
}

/// A represented workspace root whose descriptor capture failed. Kept so a request path that
/// resolves under it is attributed `missingOrUnreadable` instead of a misleading
/// `outsideAuthority`, and so unrelated roots do not block images elsewhere in the workspace.
package struct OracleImageUnavailableRoot: Equatable {
    /// Logical and unresolved-physical prefixes this root would have matched.
    package let candidatePrefixes: [String]
}

/// One exact image file the current Agent Mode session itself attached (pasted or dropped into
/// its composer and copied into the app-managed attachment store). Authority covers only this
/// file, never its directory, so sibling files from other sessions stay unreachable.
package struct OracleImageSessionAttachment: Equatable {
    /// Request paths that name this file (as stored, and its symlink-resolved form).
    package let requestPaths: [String]
    package let directory: OracleImagePhysicalRootCapture
    package let fileName: String
}

package struct OracleImageWorkspaceAuthority: Equatable {
    package let roots: [OracleImageRootProjection]
    package var unavailableRoots: [OracleImageUnavailableRoot] = []
    package var sessionAttachments: [OracleImageSessionAttachment] = []

    package init(
        roots: [OracleImageRootProjection],
        unavailableRoots: [OracleImageUnavailableRoot] = [],
        sessionAttachments: [OracleImageSessionAttachment] = []
    ) {
        self.roots = roots
        self.unavailableRoots = unavailableRoots
        self.sessionAttachments = sessionAttachments
    }
}

package enum OracleAttachmentLoadError: Error, LocalizedError, Equatable {
    case tooMany(maximumCount: Int)
    case invalidPath(index: Int)
    case outsideAuthority(index: Int)
    case unsafePath(index: Int)
    case missingOrUnreadable(index: Int)
    case notRegularFile(index: Int)
    case tooLarge(index: Int, maximumBytes: Int)
    case totalTooLarge(maximumBytes: Int)
    case changedWhileReading(index: Int)
    case extensionMismatch(index: Int, fileName: String, detected: String)
    case imageNormalizationFailed(index: Int, AttachmentClassificationError)
    case legacyImagesRequiresImage(index: Int)

    package var errorDescription: String? {
        switch self {
        case let .tooMany(maximumCount):
            "At most \(maximumCount) attachments are supported."
        case let .invalidPath(index):
            "attachments[\(index)].path must be a canonical absolute local workspace path."
        case let .outsideAuthority(index):
            "attachments[\(index)].path is outside the current workspace roots and this session's attached files."
        case let .unsafePath(index):
            "attachments[\(index)].path changed or contains a symbolic link."
        case let .missingOrUnreadable(index):
            "attachments[\(index)] is missing or unreadable."
        case let .notRegularFile(index):
            "attachments[\(index)] must point to a regular file."
        case let .tooLarge(index, maximumBytes):
            "attachments[\(index)] exceeds the \(maximumBytes) byte per-file limit."
        case let .totalTooLarge(maximumBytes):
            "Attachments exceed the \(maximumBytes) byte total size limit."
        case let .changedWhileReading(index):
            "attachments[\(index)] changed while it was being read."
        case let .extensionMismatch(index, fileName, detected):
            "attachments[\(index)] \(fileName): the file extension does not match its content, which is \(detected)."
        case let .imageNormalizationFailed(index, error):
            "attachments[\(index)] \(error.errorDescription ?? "image conversion failed")"
        case let .legacyImagesRequiresImage(index):
            "\(OracleAttachmentContract.legacyImagesArgumentName)[\(index)] is not a supported PNG, JPEG, WebP, or GIF file. "
                + "The deprecated `\(OracleAttachmentContract.legacyImagesArgumentName)` argument takes only those images; "
                + "pass other files in `\(OracleAttachmentContract.argumentName)`."
        }
    }
}

package struct OracleAttachmentLoader {
    package typealias AfterFirstRead = @Sendable (_ requestIndex: Int) throws -> Void

    package let limits: OracleAttachmentLimits
    package let afterFirstRead: AfterFirstRead?

    package init(
        limits: OracleAttachmentLimits = .production,
        afterFirstRead: AfterFirstRead? = nil
    ) {
        self.limits = limits
        self.afterFirstRead = afterFirstRead
    }

    package static func loadDetached(
        requests: [OracleAttachmentRequest],
        authority: OracleImageWorkspaceAuthority,
        loader: OracleAttachmentLoader = .init()
    ) async throws -> [OracleAttachment] {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try loader.load(requests: requests, authority: authority)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Captures physical root identity for every represented workspace root off the caller's
    /// executor. A root that cannot be captured is recorded in `unavailableRoots` so only image
    /// requests under it fail, rather than one broken root rejecting the whole request.
    package static func deriveAuthorityDetached(
        rootSpecs: [OracleImageRootSpec],
        sessionAttachmentPaths: [String] = []
    ) async throws -> OracleImageWorkspaceAuthority {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try deriveAuthority(rootSpecs: rootSpecs, sessionAttachmentPaths: sessionAttachmentPaths)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    package static func deriveAuthority(
        rootSpecs: [OracleImageRootSpec],
        sessionAttachmentPaths: [String] = []
    ) throws -> OracleImageWorkspaceAuthority {
        var roots: [OracleImageRootProjection] = []
        var unavailableRoots: [OracleImageUnavailableRoot] = []
        var seenProjections: Set<String> = []
        for spec in rootSpecs {
            try Task.checkCancellation()
            do {
                let capture = try OracleImagePhysicalRootCapture.capture(
                    physicalRootPath: spec.physicalRootPath,
                    index: 0
                )
                for logicalRootPath in spec.logicalRootPaths {
                    let key = "\(logicalRootPath)\u{0}\(spec.physicalRootPath)"
                    guard seenProjections.insert(key).inserted else { continue }
                    roots.append(capture.projection(logicalRootPath: logicalRootPath))
                }
            } catch {
                unavailableRoots.append(OracleImageUnavailableRoot(
                    candidatePrefixes: spec.logicalRootPaths + [spec.physicalRootPath]
                ))
            }
        }
        var sessionAttachments: [OracleImageSessionAttachment] = []
        var seenAttachmentPaths: Set<String> = []
        for rawPath in sessionAttachmentPaths {
            try Task.checkCancellation()
            let path = StandardizedPath.absolute(rawPath)
            let fileURL = URL(fileURLWithPath: path)
            let fileName = fileURL.lastPathComponent
            guard path.hasPrefix("/"), !path.contains("\0"), !fileName.isEmpty, fileName != "/",
                  seenAttachmentPaths.insert(path).inserted
            else { continue }
            let directoryPath = fileURL.deletingLastPathComponent().path
            do {
                let directory = try OracleImagePhysicalRootCapture.capture(
                    physicalRootPath: directoryPath,
                    index: 0
                )
                let resolvedPath = directory.resolvedPhysicalRootPath + "/" + fileName
                sessionAttachments.append(OracleImageSessionAttachment(
                    requestPaths: Array(Set([path, resolvedPath])).sorted(),
                    directory: directory,
                    fileName: fileName
                ))
            } catch {
                // Only this exact file is attributed unreadable; its directory is not authorized.
                unavailableRoots.append(OracleImageUnavailableRoot(candidatePrefixes: [path]))
            }
        }
        return OracleImageWorkspaceAuthority(
            roots: roots,
            unavailableRoots: unavailableRoots,
            sessionAttachments: sessionAttachments
        )
    }

    package func load(
        requests: [OracleAttachmentRequest],
        authority: OracleImageWorkspaceAuthority
    ) throws -> [OracleAttachment] {
        guard requests.count <= limits.maxCount else {
            throw OracleAttachmentLoadError.tooMany(maximumCount: limits.maxCount)
        }
        guard !requests.isEmpty else { return [] }
        guard !authority.roots.isEmpty || !authority.unavailableRoots.isEmpty
            || !authority.sessionAttachments.isEmpty
        else {
            throw OracleAttachmentLoadError.outsideAuthority(index: requests[0].index)
        }

        var opened: [OpenedImage] = []
        defer {
            for item in opened {
                Darwin.close(item.fileDescriptor)
                Darwin.close(item.rootDescriptor)
            }
        }

        var totalBytes = 0
        for request in requests {
            try Task.checkCancellation()
            let resolution = try resolve(request: request, authority: authority)
            let rootDescriptor = try openTrustedRootDirectory(
                resolution.physicalRootPath,
                index: request.index
            )
            do {
                let rootIdentity = try descriptorIdentity(rootDescriptor, index: request.index)
                guard rootIdentity == resolution.expectedRootIdentity else {
                    throw OracleAttachmentLoadError.unsafePath(index: request.index)
                }
                let fileDescriptor = try openFileWithoutSymlinks(
                    from: rootDescriptor,
                    relativePath: resolution.relativePath,
                    index: request.index
                )
                do {
                    let identity = try fileIdentity(fileDescriptor, index: request.index)
                    guard identity.isRegular else {
                        throw OracleAttachmentLoadError.notRegularFile(index: request.index)
                    }
                    guard identity.size >= 0,
                          let byteCount = Int(exactly: identity.size)
                    else {
                        throw OracleAttachmentLoadError.tooLarge(
                            index: request.index,
                            maximumBytes: limits.maxBytesPerFile
                        )
                    }
                    guard byteCount <= limits.maxBytesPerFile else {
                        throw OracleAttachmentLoadError.tooLarge(
                            index: request.index,
                            maximumBytes: limits.maxBytesPerFile
                        )
                    }
                    totalBytes += byteCount
                    guard totalBytes <= limits.maxTotalBytes else {
                        throw OracleAttachmentLoadError.totalTooLarge(maximumBytes: limits.maxTotalBytes)
                    }
                    opened.append(OpenedImage(
                        request: request,
                        rootDescriptor: rootDescriptor,
                        fileDescriptor: fileDescriptor,
                        resolution: resolution,
                        identity: identity,
                        byteCount: byteCount
                    ))
                } catch {
                    Darwin.close(fileDescriptor)
                    throw error
                }
            } catch {
                Darwin.close(rootDescriptor)
                throw error
            }
        }

        var attachments: [OracleAttachment] = []
        attachments.reserveCapacity(opened.count)
        var acceptedBytes = 0
        for item in opened {
            try Task.checkCancellation()
            let data = try readExactly(
                descriptor: item.fileDescriptor,
                byteCount: item.byteCount,
                index: item.request.index
            )
            try afterFirstRead?(item.request.index)
            let postReadIdentity = try fileIdentity(item.fileDescriptor, index: item.request.index)
            guard postReadIdentity == item.identity else {
                throw OracleAttachmentLoadError.changedWhileReading(index: item.request.index)
            }
            let reopened = try openFileWithoutSymlinks(
                from: item.rootDescriptor,
                relativePath: item.resolution.relativePath,
                index: item.request.index
            )
            defer { Darwin.close(reopened) }
            let reopenedIdentity = try fileIdentity(reopened, index: item.request.index)
            guard reopenedIdentity == item.identity else {
                throw OracleAttachmentLoadError.changedWhileReading(index: item.request.index)
            }

            let fileName = (item.resolution.physicalFilePath as NSString).lastPathComponent
            let sniffedImage = AttachmentClassifier.sniffImage(of: data)
            if item.request.imageOnly {
                guard case .native = sniffedImage else {
                    throw OracleAttachmentLoadError.legacyImagesRequiresImage(index: item.request.index)
                }
            }
            if let sniffedImage {
                try validateExtension(
                    fileName: fileName,
                    sniffedImage: sniffedImage,
                    index: item.request.index
                )
            }
            let payload: AttachmentPayload
            do {
                payload = try AttachmentClassifier.classify(bytes: data, fileName: fileName)
            } catch {
                throw OracleAttachmentLoadError.imageNormalizationFailed(index: item.request.index, error)
            }
            if sniffedImage == nil {
                try rejectImageExtension(fileName: fileName, payload: payload, index: item.request.index)
            }

            // Size accounting uses the classified payload, so a converted image counts as the bytes
            // that will be sent. The pre-read fstat caps above only bound how much is read.
            guard payload.byteCount <= limits.maxBytesPerFile else {
                throw OracleAttachmentLoadError.tooLarge(
                    index: item.request.index,
                    maximumBytes: limits.maxBytesPerFile
                )
            }
            acceptedBytes += payload.byteCount
            guard acceptedBytes <= limits.maxTotalBytes else {
                throw OracleAttachmentLoadError.totalTooLarge(maximumBytes: limits.maxTotalBytes)
            }
            attachments.append(OracleAttachment(payload: payload, fileName: fileName, title: item.request.title))
        }
        return attachments
    }

    private struct Resolution {
        let physicalRootPath: String
        let physicalFilePath: String
        let relativePath: String
        let expectedRootIdentity: OracleImageRootIdentity
    }

    private struct OpenedImage {
        let request: OracleAttachmentRequest
        let rootDescriptor: Int32
        let fileDescriptor: Int32
        let resolution: Resolution
        let identity: FileIdentity
        let byteCount: Int
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        var isRegular: Bool {
            (mode & S_IFMT) == S_IFREG
        }
    }

    private func resolve(
        request: OracleAttachmentRequest,
        authority: OracleImageWorkspaceAuthority
    ) throws -> Resolution {
        let rawPath = request.path
        guard rawPath.hasPrefix("/"),
              !rawPath.contains("\0"),
              rawPath == rawPath.trimmingCharacters(in: .whitespacesAndNewlines),
              rawPath == StandardizedPath.absolute(rawPath),
              !rawPath.hasSuffix("/")
        else {
            throw OracleAttachmentLoadError.invalidPath(index: request.index)
        }
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw OracleAttachmentLoadError.invalidPath(index: request.index)
        }

        // An exact session-attached file wins outright; nothing else in its directory matches.
        if let attachment = authority.sessionAttachments.first(where: { $0.requestPaths.contains(rawPath) }) {
            let directory = attachment.directory.resolvedPhysicalRootPath
            return Resolution(
                physicalRootPath: directory,
                physicalFilePath: join(root: directory, relativePath: attachment.fileName),
                relativePath: attachment.fileName,
                expectedRootIdentity: attachment.directory.rootIdentity
            )
        }

        var matches: [(specificity: Int, resolution: Resolution)] = []
        for root in authority.roots {
            let logicalRoot = StandardizedPath.absolute(root.logicalRootPath)
            let physicalRoot = StandardizedPath.absolute(root.physicalRootPath)
            let resolvedPhysicalRoot = root.resolvedPhysicalRootPath
            if let relative = relativePath(rawPath, under: logicalRoot) {
                matches.append((logicalRoot.count, Resolution(
                    physicalRootPath: resolvedPhysicalRoot,
                    physicalFilePath: join(root: resolvedPhysicalRoot, relativePath: relative),
                    relativePath: relative,
                    expectedRootIdentity: root.rootIdentity
                )))
            }
            if logicalRoot != physicalRoot,
               let relative = relativePath(rawPath, under: physicalRoot)
            {
                matches.append((physicalRoot.count, Resolution(
                    physicalRootPath: resolvedPhysicalRoot,
                    physicalFilePath: join(root: resolvedPhysicalRoot, relativePath: relative),
                    relativePath: relative,
                    expectedRootIdentity: root.rootIdentity
                )))
            }
            if resolvedPhysicalRoot != logicalRoot,
               resolvedPhysicalRoot != physicalRoot,
               let relative = relativePath(rawPath, under: resolvedPhysicalRoot)
            {
                matches.append((resolvedPhysicalRoot.count, Resolution(
                    physicalRootPath: resolvedPhysicalRoot,
                    physicalFilePath: join(root: resolvedPhysicalRoot, relativePath: relative),
                    relativePath: relative,
                    expectedRootIdentity: root.rootIdentity
                )))
            }
        }
        // Longest unavailable-binding prefix covering this path. A failed capture still owns
        // its logical/physical prefixes, so it competes in specificity with available roots.
        let unavailableSpecificity = authority.unavailableRoots
            .flatMap(\.candidatePrefixes)
            .filter { rawPath == $0 || rawPath.hasPrefix($0 + "/") }
            .map(\.count)
            .max()

        guard let maximumSpecificity = matches.map(\.specificity).max() else {
            if unavailableSpecificity != nil {
                throw OracleAttachmentLoadError.missingOrUnreadable(index: request.index)
            }
            throw OracleAttachmentLoadError.outsideAuthority(index: request.index)
        }
        // A binding at least as specific as the best available match wins the request and
        // fails it — a broader root must not substitute a different copy of the file.
        if let unavailableSpecificity, unavailableSpecificity >= maximumSpecificity {
            throw OracleAttachmentLoadError.missingOrUnreadable(index: request.index)
        }
        let mostSpecific = matches.filter { $0.specificity == maximumSpecificity }
        let physicalPaths = Set(mostSpecific.map(\.resolution.physicalFilePath))
        guard physicalPaths.count == 1, let resolution = mostSpecific.first?.resolution,
              !resolution.relativePath.isEmpty
        else {
            throw OracleAttachmentLoadError.outsideAuthority(index: request.index)
        }
        return resolution
    }

    private func relativePath(_ path: String, under root: String) -> String? {
        guard path != root, path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    private func join(root: String, relativePath: String) -> String {
        root + "/" + relativePath
    }

    private func openTrustedRootDirectory(_ path: String, index: Int) throws -> Int32 {
        try OracleImagePhysicalRootCapture.openResolvedDirectoryWithoutSymlinks(path, index: index)
    }

    private func openFileWithoutSymlinks(
        from rootDescriptor: Int32,
        relativePath: String,
        index: Int
    ) throws -> Int32 {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else {
            throw OracleAttachmentLoadError.notRegularFile(index: index)
        }
        var directoryDescriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard directoryDescriptor >= 0 else {
            throw OracleAttachmentLoadError.missingOrUnreadable(index: index)
        }
        do {
            for component in components.dropLast() {
                let next = component.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    if errno == ELOOP {
                        throw OracleAttachmentLoadError.unsafePath(index: index)
                    }
                    throw OracleAttachmentLoadError.missingOrUnreadable(index: index)
                }
                Darwin.close(directoryDescriptor)
                directoryDescriptor = next
            }
            let descriptor = filename.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                if errno == ELOOP {
                    throw OracleAttachmentLoadError.unsafePath(index: index)
                }
                throw OracleAttachmentLoadError.missingOrUnreadable(index: index)
            }
            Darwin.close(directoryDescriptor)
            return descriptor
        } catch {
            Darwin.close(directoryDescriptor)
            throw error
        }
    }

    private func descriptorIdentity(_ descriptor: Int32, index: Int) throws -> OracleImageRootIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw OracleAttachmentLoadError.changedWhileReading(index: index)
        }
        return OracleImageRootIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            mode: info.st_mode
        )
    }

    private func fileIdentity(_ descriptor: Int32, index: Int) throws -> FileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw OracleAttachmentLoadError.changedWhileReading(index: index)
        }
        return FileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            mode: info.st_mode,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec,
            changedNanoseconds: info.st_ctimespec.tv_nsec
        )
    }

    private func readExactly(descriptor: Int32, byteCount: Int, index: Int) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw OracleAttachmentLoadError.changedWhileReading(index: index)
        }
        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            try Task.checkCancellation()
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    min(64 * 1024, byteCount - offset)
                )
            }
            if count > 0 {
                offset += count
            } else if count == 0 {
                throw OracleAttachmentLoadError.changedWhileReading(index: index)
            } else if errno != EINTR {
                throw OracleAttachmentLoadError.missingOrUnreadable(index: index)
            }
        }
        return data
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif"
    ]

    private func validateExtension(
        fileName: String,
        sniffedImage: AttachmentClassifier.SniffedImage,
        index: Int
    ) throws {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let expected: Set<String>
        let detected: String
        switch sniffedImage {
        case let .native(mediaType):
            detected = mediaType.rawValue
            expected = switch mediaType {
            case .png: ["png"]
            case .jpeg: ["jpg", "jpeg"]
            case .gif: ["gif"]
            case .webp: ["webp"]
            }
        case let .convertible(format):
            detected = "\(format.rawValue) image"
            expected = switch format {
            case .heic: ["heic", "heif"]
            case .tiff: ["tif", "tiff"]
            case .bmp: ["bmp"]
            case .avif: ["avif"]
            }
        }
        guard expected.contains(fileExtension) else {
            throw OracleAttachmentLoadError.extensionMismatch(index: index, fileName: fileName, detected: detected)
        }
    }

    /// A file named like an image whose content is not one stays an error. It never becomes a
    /// text, PDF, or binary attachment under a misleading name.
    private func rejectImageExtension(fileName: String, payload: AttachmentPayload, index: Int) throws {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        guard Self.imageExtensions.contains(fileExtension) else { return }
        let detected = switch payload.kind {
        case .image: "an image"
        case .pdf: "a PDF"
        case .text: "text"
        case .binary: "binary data"
        }
        throw OracleAttachmentLoadError.extensionMismatch(index: index, fileName: fileName, detected: detected)
    }
}
