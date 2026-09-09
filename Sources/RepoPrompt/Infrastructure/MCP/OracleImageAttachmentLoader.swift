import Foundation
import RepoPromptWorkspaceCore

/// One image attachment requested through the Oracle MCP surface.
struct OracleImageRequest: Equatable {
    let index: Int
    /// Physical absolute path, already translated out of any logical root projection.
    let path: String
    let title: String?
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
    case outsideWorkspaceRoots(index: Int)
    case missingOrUnreadable(index: Int)
    case notRegularFile(index: Int)
    case tooLarge(index: Int, maximumBytes: Int)
    case totalTooLarge(maximumBytes: Int)
    case unsupportedFormat(index: Int)

    var errorDescription: String? {
        switch self {
        case let .tooMany(maximumCount):
            "images supports at most \(maximumCount) items."
        case let .invalidPath(index):
            "images[\(index)].path must be a canonical absolute local workspace path."
        case let .outsideWorkspaceRoots(index):
            "images[\(index)].path is outside the current workspace roots."
        case let .missingOrUnreadable(index):
            "images[\(index)] is missing or unreadable."
        case let .notRegularFile(index):
            "images[\(index)] must point to a regular file."
        case let .tooLarge(index, maximumBytes):
            "images[\(index)] exceeds the \(maximumBytes) byte per-image limit."
        case let .totalTooLarge(maximumBytes):
            "images total size exceeds the \(maximumBytes) byte limit."
        case let .unsupportedFormat(index):
            "images[\(index)] is not a supported PNG, JPEG, GIF, or WebP file."
        }
    }
}

/// Reads request-scoped Oracle image attachments off disk.
///
/// Authority is a containment check: a request's symlink-resolved path must live
/// inside one of the symlink-resolved workspace roots the request already resolved
/// against. Nothing else on the machine is readable through this surface.
struct OracleImageAttachmentLoader {
    let limits: OracleImageAttachmentLimits
    private let resolvedRootPaths: [String]

    init(
        workspaceRootPaths: [String],
        limits: OracleImageAttachmentLimits = .production
    ) {
        self.limits = limits
        resolvedRootPaths = Set(workspaceRootPaths.map(Self.resolved)).sorted()
    }

    /// Runs the blocking file reads off the caller's actor while staying cancellable.
    static func loadDetached(
        requests: [OracleImageRequest],
        loader: OracleImageAttachmentLoader
    ) async throws -> [AITransientImage] {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try loader.load(requests)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func load(_ requests: [OracleImageRequest]) throws -> [AITransientImage] {
        guard requests.count <= limits.maxCount else {
            throw OracleImageLoadError.tooMany(maximumCount: limits.maxCount)
        }
        guard !requests.isEmpty else { return [] }

        var images: [AITransientImage] = []
        var totalBytes = 0
        for request in requests {
            try Task.checkCancellation()
            let url = try admittedFileURL(for: request)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes else {
                throw OracleImageLoadError.missingOrUnreadable(index: request.index)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw OracleImageLoadError.notRegularFile(index: request.index)
            }
            guard let declaredSize = (attributes[.size] as? NSNumber)?.intValue,
                  declaredSize <= limits.maxBytesPerImage
            else {
                throw OracleImageLoadError.tooLarge(
                    index: request.index,
                    maximumBytes: limits.maxBytesPerImage
                )
            }
            guard let bytes = try? Data(contentsOf: url, options: .uncached) else {
                throw OracleImageLoadError.missingOrUnreadable(index: request.index)
            }
            guard bytes.count <= limits.maxBytesPerImage else {
                throw OracleImageLoadError.tooLarge(
                    index: request.index,
                    maximumBytes: limits.maxBytesPerImage
                )
            }
            totalBytes += bytes.count
            guard totalBytes <= limits.maxTotalBytes else {
                throw OracleImageLoadError.totalTooLarge(maximumBytes: limits.maxTotalBytes)
            }
            try images.append(AITransientImage(
                bytes: bytes,
                mediaType: Self.mediaType(of: bytes, index: request.index),
                title: request.title
            ))
        }
        return images
    }

    private func admittedFileURL(for request: OracleImageRequest) throws -> URL {
        let raw = request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("/"), !raw.contains("\0"), !raw.hasSuffix("/") else {
            throw OracleImageLoadError.invalidPath(index: request.index)
        }
        let resolvedPath = Self.resolved(raw)
        guard resolvedRootPaths.contains(where: { resolvedPath.hasPrefix($0 + "/") }) else {
            throw OracleImageLoadError.outsideWorkspaceRoots(index: request.index)
        }
        return URL(fileURLWithPath: resolvedPath)
    }

    /// Standardizes and symlink-resolves a path so containment cannot be escaped
    /// through `..`, a tilde, or a symlink anywhere along the way.
    private static func resolved(_ path: String) -> String {
        let standardized = StandardizedPath.absolute(path)
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return StandardizedPath.absolute(resolved)
    }

    /// Content sniffing is authoritative; the file extension is never trusted.
    private static func mediaType(of data: Data, index: Int) throws -> AIImageMediaType {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            return .gif
        }
        if data.count >= 12,
           data.starts(with: Array("RIFF".utf8)),
           Array(data[8 ..< 12]) == Array("WEBP".utf8)
        {
            return .webp
        }
        throw OracleImageLoadError.unsupportedFormat(index: index)
    }
}

enum OracleImageRouteAdmission {
    /// Transports whose Oracle request serialization emits a native image block.
    /// CLI/ACP-backed Oracle models drop image content, so they are rejected up front
    /// instead of silently sending a text-only prompt.
    static func supports(_ model: AIModel) -> Bool {
        switch model.providerType {
        case .anthropic,
             .openAI,
             .azure,
             .openRouter,
             .gemini,
             .deepseek,
             .customProvider,
             .fireworks,
             .grok,
             .groq,
             .zAI,
             .ollama:
            true
        default:
            false
        }
    }
}
