import Darwin
import Foundation

struct OracleImageRequest: Equatable {
    let index: Int
    let path: String
    let title: String?
}

struct OracleImageRootIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
    let mode: mode_t
}

struct OracleImageRootProjection: Equatable {
    let logicalRootPath: String
    let physicalRootPath: String
    let resolvedPhysicalRootPath: String
    let rootIdentity: OracleImageRootIdentity

    static func capture(
        logicalRootPath: String,
        physicalRootPath: String,
        index: Int
    ) throws -> OracleImageRootProjection {
        let logicalRootPath = StandardizedPath.absolute(logicalRootPath)
        let physicalRootPath = StandardizedPath.absolute(physicalRootPath)
        let resolvedPhysicalRootPath = StandardizedPath.absolute(
            URL(fileURLWithPath: physicalRootPath).resolvingSymlinksInPath().path
        )
        let descriptor = resolvedPhysicalRootPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw OracleImageLoadError.missingOrUnreadable(index: index)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw OracleImageLoadError.missingOrUnreadable(index: index)
        }
        return OracleImageRootProjection(
            logicalRootPath: logicalRootPath,
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
}

struct OracleImageWorkspaceAuthority: Equatable {
    let roots: [OracleImageRootProjection]
}

struct OracleImageAttachmentLimits: Equatable {
    let maxCount: Int
    let maxBytesPerImage: Int
    let maxTotalBytes: Int

    static let production = OracleImageAttachmentLimits(
        maxCount: 10,
        maxBytesPerImage: 20 * 1024 * 1024,
        maxTotalBytes: 50 * 1024 * 1024
    )
}

enum OracleImageLoadError: Error, LocalizedError, Equatable {
    case tooMany(maximumCount: Int)
    case invalidPath(index: Int)
    case outsideAuthority(index: Int)
    case unsafePath(index: Int)
    case missingOrUnreadable(index: Int)
    case notRegularFile(index: Int)
    case tooLarge(index: Int, maximumBytes: Int)
    case totalTooLarge(maximumBytes: Int)
    case changedWhileReading(index: Int)
    case unsupportedFormat(index: Int)
    case extensionMismatch(index: Int, mediaType: AIImageMediaType)

    var errorDescription: String? {
        switch self {
        case let .tooMany(maximumCount):
            "images supports at most \(maximumCount) items."
        case let .invalidPath(index):
            "images[\(index)].path must be a canonical absolute local workspace path."
        case let .outsideAuthority(index):
            "images[\(index)].path is outside the current workspace roots."
        case let .unsafePath(index):
            "images[\(index)].path changed or contains a symbolic link."
        case let .missingOrUnreadable(index):
            "images[\(index)] is missing or unreadable."
        case let .notRegularFile(index):
            "images[\(index)] must point to a regular file."
        case let .tooLarge(index, maximumBytes):
            "images[\(index)] exceeds the \(maximumBytes) byte per-image limit."
        case let .totalTooLarge(maximumBytes):
            "images total size exceeds the \(maximumBytes) byte limit."
        case let .changedWhileReading(index):
            "images[\(index)] changed while it was being read."
        case let .unsupportedFormat(index):
            "images[\(index)] is not a supported PNG, JPEG, WebP, or GIF file."
        case let .extensionMismatch(index, mediaType):
            "images[\(index)] file extension does not match detected MIME type \(mediaType.rawValue)."
        }
    }
}

struct OracleImageAttachmentLoader {
    typealias AfterFirstRead = @Sendable (_ requestIndex: Int) throws -> Void

    let limits: OracleImageAttachmentLimits
    let afterFirstRead: AfterFirstRead?

    init(
        limits: OracleImageAttachmentLimits = .production,
        afterFirstRead: AfterFirstRead? = nil
    ) {
        self.limits = limits
        self.afterFirstRead = afterFirstRead
    }

    static func loadDetached(
        requests: [OracleImageRequest],
        authority: OracleImageWorkspaceAuthority,
        loader: OracleImageAttachmentLoader = .init()
    ) async throws -> [AITransientImage] {
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

    func load(
        requests: [OracleImageRequest],
        authority: OracleImageWorkspaceAuthority
    ) throws -> [AITransientImage] {
        guard requests.count <= limits.maxCount else {
            throw OracleImageLoadError.tooMany(maximumCount: limits.maxCount)
        }
        guard !requests.isEmpty else { return [] }
        guard !authority.roots.isEmpty else {
            throw OracleImageLoadError.outsideAuthority(index: requests[0].index)
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
                    throw OracleImageLoadError.unsafePath(index: request.index)
                }
                let fileDescriptor = try openFileWithoutSymlinks(
                    from: rootDescriptor,
                    relativePath: resolution.relativePath,
                    index: request.index
                )
                do {
                    let identity = try fileIdentity(fileDescriptor, index: request.index)
                    guard identity.isRegular else {
                        throw OracleImageLoadError.notRegularFile(index: request.index)
                    }
                    guard identity.size >= 0,
                          let byteCount = Int(exactly: identity.size)
                    else {
                        throw OracleImageLoadError.tooLarge(
                            index: request.index,
                            maximumBytes: limits.maxBytesPerImage
                        )
                    }
                    guard byteCount <= limits.maxBytesPerImage else {
                        throw OracleImageLoadError.tooLarge(
                            index: request.index,
                            maximumBytes: limits.maxBytesPerImage
                        )
                    }
                    totalBytes += byteCount
                    guard totalBytes <= limits.maxTotalBytes else {
                        throw OracleImageLoadError.totalTooLarge(maximumBytes: limits.maxTotalBytes)
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

        var images: [AITransientImage] = []
        images.reserveCapacity(opened.count)
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
                throw OracleImageLoadError.changedWhileReading(index: item.request.index)
            }
            let reopened = try openFileWithoutSymlinks(
                from: item.rootDescriptor,
                relativePath: item.resolution.relativePath,
                index: item.request.index
            )
            defer { Darwin.close(reopened) }
            let reopenedIdentity = try fileIdentity(reopened, index: item.request.index)
            guard reopenedIdentity == item.identity else {
                throw OracleImageLoadError.changedWhileReading(index: item.request.index)
            }

            let mediaType = try detectMediaType(data, index: item.request.index)
            try validateExtension(
                item.resolution.physicalFilePath,
                mediaType: mediaType,
                index: item.request.index
            )
            images.append(AITransientImage(
                bytes: data,
                mediaType: mediaType,
                title: item.request.title
            ))
        }
        return images
    }

    private struct Resolution {
        let physicalRootPath: String
        let physicalFilePath: String
        let relativePath: String
        let expectedRootIdentity: OracleImageRootIdentity
    }

    private struct OpenedImage {
        let request: OracleImageRequest
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
        request: OracleImageRequest,
        authority: OracleImageWorkspaceAuthority
    ) throws -> Resolution {
        let rawPath = request.path
        guard rawPath.hasPrefix("/"),
              !rawPath.contains("\0"),
              rawPath == rawPath.trimmingCharacters(in: .whitespacesAndNewlines),
              rawPath == StandardizedPath.absolute(rawPath),
              !rawPath.hasSuffix("/")
        else {
            throw OracleImageLoadError.invalidPath(index: request.index)
        }
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw OracleImageLoadError.invalidPath(index: request.index)
        }

        var matches: [(specificity: Int, resolution: Resolution)] = []
        for root in authority.roots {
            let logicalRoot = StandardizedPath.absolute(root.logicalRootPath)
            let physicalRoot = StandardizedPath.absolute(root.physicalRootPath)
            let resolvedPhysicalRoot = StandardizedPath.absolute(root.resolvedPhysicalRootPath)
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
        guard let maximumSpecificity = matches.map(\.specificity).max() else {
            throw OracleImageLoadError.outsideAuthority(index: request.index)
        }
        let mostSpecific = matches.filter { $0.specificity == maximumSpecificity }
        let physicalPaths = Set(mostSpecific.map(\.resolution.physicalFilePath))
        guard physicalPaths.count == 1, let resolution = mostSpecific.first?.resolution,
              !resolution.relativePath.isEmpty
        else {
            throw OracleImageLoadError.outsideAuthority(index: request.index)
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
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw OracleImageLoadError.missingOrUnreadable(index: index)
        }
        return descriptor
    }

    private func openFileWithoutSymlinks(
        from rootDescriptor: Int32,
        relativePath: String,
        index: Int
    ) throws -> Int32 {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else {
            throw OracleImageLoadError.notRegularFile(index: index)
        }
        var directoryDescriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard directoryDescriptor >= 0 else {
            throw OracleImageLoadError.missingOrUnreadable(index: index)
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
                        throw OracleImageLoadError.unsafePath(index: index)
                    }
                    throw OracleImageLoadError.missingOrUnreadable(index: index)
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
                    throw OracleImageLoadError.unsafePath(index: index)
                }
                throw OracleImageLoadError.missingOrUnreadable(index: index)
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
            throw OracleImageLoadError.changedWhileReading(index: index)
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
            throw OracleImageLoadError.changedWhileReading(index: index)
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
            throw OracleImageLoadError.changedWhileReading(index: index)
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
                throw OracleImageLoadError.changedWhileReading(index: index)
            } else if errno != EINTR {
                throw OracleImageLoadError.missingOrUnreadable(index: index)
            }
        }
        return data
    }

    private func detectMediaType(_ data: Data, index: Int) throws -> AIImageMediaType {
        if data.count >= 33,
           data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
           String(data: data[12 ..< 16], encoding: .ascii) == "IHDR"
        {
            return .png
        }
        if data.count >= 4,
           data.starts(with: [0xFF, 0xD8, 0xFF]),
           Array(data.suffix(2)) == [0xFF, 0xD9]
        {
            return .jpeg
        }
        if data.count >= 10,
           data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8))
        {
            let width = Int(data[6]) | (Int(data[7]) << 8)
            let height = Int(data[8]) | (Int(data[9]) << 8)
            if width > 0, height > 0 { return .gif }
        }
        if data.count >= 16,
           String(data: data[0 ..< 4], encoding: .ascii) == "RIFF",
           String(data: data[8 ..< 12], encoding: .ascii) == "WEBP",
           let chunk = String(data: data[12 ..< 16], encoding: .ascii),
           ["VP8 ", "VP8L", "VP8X"].contains(chunk)
        {
            return .webp
        }
        throw OracleImageLoadError.unsupportedFormat(index: index)
    }

    private func validateExtension(
        _ path: String,
        mediaType: AIImageMediaType,
        index: Int
    ) throws {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        let expected: Set<String> = switch mediaType {
        case .png: ["png"]
        case .jpeg: ["jpg", "jpeg"]
        case .gif: ["gif"]
        case .webp: ["webp"]
        }
        guard expected.contains(fileExtension) else {
            throw OracleImageLoadError.extensionMismatch(index: index, mediaType: mediaType)
        }
    }
}

enum OracleImageRouteAdmission {
    static func supports(_ model: AIModel) -> Bool {
        switch model {
        case .claude45Haiku,
             .claude4Sonnet,
             .claude4SonnetThinking,
             .claude4SonnetThinkingMax,
             .claude4Opus,
             .claude4OpusThinking:
            true
        default:
            false
        }
    }
}
