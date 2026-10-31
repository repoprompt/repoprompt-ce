import AppKit
import Combine
import ImageIO
import RepoPromptDomainRuntime

/// Identifies one decoded rendition of an attachment file.
struct AgentAttachmentImageKey: Hashable {
    enum Purpose: Hashable {
        case thumbnail
        case preview
    }

    /// Long edge of the full-size viewer's decode; large enough to fill a window, small enough to
    /// keep a single preview's memory bounded.
    static let previewLongEdgePixels = 2048

    let path: String
    let maxPixelSize: Int
    let backingScale: Int
    let purpose: Purpose

    static func thumbnail(path: String, pointSize: CGSize, backingScale: CGFloat) -> Self {
        let scale = max(1, backingScale)
        return Self(
            path: path,
            maxPixelSize: Int((max(pointSize.width, pointSize.height) * scale).rounded(.up)),
            backingScale: Int(scale.rounded(.up)),
            purpose: .thumbnail
        )
    }

    static func preview(path: String, backingScale: CGFloat) -> Self {
        Self(
            path: path,
            maxPixelSize: previewLongEdgePixels,
            backingScale: Int(max(1, backingScale).rounded(.up)),
            purpose: .preview
        )
    }

    var cacheKey: NSString {
        "\(purpose)|\(path)|\(maxPixelSize)@\(backingScale)" as NSString
    }
}

/// A decoded rendition plus the original file's pixel dimensions (orientation-corrected).
final class AgentAttachmentDecodedImage {
    let image: NSImage
    let pixelSize: CGSize

    init(image: NSImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
    }
}

enum AgentAttachmentImageLoadResult {
    case image(AgentAttachmentDecodedImage)
    case missing
    case undecodable
}

final class AgentAttachmentImageLoadToken {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

/// Shared `CGImageSource` decode pipeline for attachment cards and the full-size viewer.
///
/// All decoding and existence checks run on a background queue; results are cached by path and
/// pixel size. Previews live in a separate, small cache so a closed viewer does not pin memory.
final class AgentAttachmentThumbnailCache {
    /// Cached existence lookups shared by every card.
    let availability = RepoPromptDomainRuntime.AgentImageAttachmentAvailabilityResolver()
    /// Mounted cards must refresh their local phase when an image disappears without a row rewrite.
    let invalidatedPaths = PassthroughSubject<Set<String>, Never>()

    private let thumbnails = NSCache<NSString, AgentAttachmentDecodedImage>()
    private let previews = NSCache<NSString, AgentAttachmentDecodedImage>()
    /// Cache keys stored per path, so a moved or evicted file can drop every rendition.
    private let keysLock = NSLock()
    private var keysByPath: [String: Set<NSString>] = [:]
    private var invalidationGenerationByPath: [String: UInt64] = [:]
    private let loadQueue = DispatchQueue(label: "com.repoprompt.agent-attachment-thumbnails", qos: .userInitiated)

    init() {
        thumbnails.countLimit = 200
        previews.countLimit = 2
    }

    private func store(for key: AgentAttachmentImageKey) -> NSCache<NSString, AgentAttachmentDecodedImage> {
        key.purpose == .preview ? previews : thumbnails
    }

    func cachedImage(for key: AgentAttachmentImageKey) -> AgentAttachmentDecodedImage? {
        store(for: key).object(forKey: key.cacheKey)
    }

    /// Marks `paths` missing and drops their cached renditions (a file was moved out of the
    /// temporary store or evicted by the session cap).
    func invalidate(paths: [String]) {
        let standardizedPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        keysLock.lock()
        for path in standardizedPaths {
            invalidationGenerationByPath[path, default: 0] &+= 1
            availability.record(.missing, forPath: path)
            let keys = keysByPath.removeValue(forKey: path) ?? []
            for key in keys {
                thumbnails.removeObject(forKey: key)
                previews.removeObject(forKey: key)
            }
        }
        keysLock.unlock()
        invalidatedPaths.send(standardizedPaths)
    }

    private func generation(for path: String) -> UInt64 {
        keysLock.lock()
        defer { keysLock.unlock() }
        return invalidationGenerationByPath[path, default: 0]
    }

    private func record(_ result: AgentAttachmentImageLoadResult, for key: AgentAttachmentImageKey, generation: UInt64) -> AgentAttachmentImageLoadResult {
        keysLock.lock()
        defer { keysLock.unlock() }
        guard invalidationGenerationByPath[key.path, default: 0] == generation else { return .missing }
        switch result {
        case let .image(decoded):
            availability.record(.available, forPath: key.path)
            store(for: key).setObject(decoded, forKey: key.cacheKey)
            keysByPath[key.path, default: []].insert(key.cacheKey)
        case .missing:
            availability.record(.missing, forPath: key.path)
        case .undecodable:
            availability.record(.available, forPath: key.path)
        }
        return result
    }

    func loadImage(
        for key: AgentAttachmentImageKey,
        completion: @escaping (AgentAttachmentImageLoadResult) -> Void
    ) -> AgentAttachmentImageLoadToken {
        let token = AgentAttachmentImageLoadToken()
        let generation = generation(for: key.path)
        if let cached = cachedImage(for: key) {
            DispatchQueue.main.async { [weak self] in
                guard !token.isCancelled else { return }
                completion(self?.generation(for: key.path) == generation ? .image(cached) : .missing)
            }
            return token
        }

        loadQueue.async { [weak self, weak token] in
            guard let self, let token, !token.isCancelled else { return }
            let result = record(Self.decode(key), for: key, generation: generation)
            DispatchQueue.main.async { [weak self, weak token] in
                guard let token, !token.isCancelled else { return }
                completion(self?.generation(for: key.path) == generation ? result : .missing)
            }
        }
        return token
    }

    private static func decode(_ key: AgentAttachmentImageKey) -> AgentAttachmentImageLoadResult {
        guard FileManager.default.fileExists(atPath: key.path) else { return .missing }
        let url = URL(fileURLWithPath: key.path)
        let scale = CGFloat(max(1, key.backingScale))
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return fallbackDecode(path: key.path)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: key.maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return fallbackDecode(path: key.path)
        }
        let decodedSize = CGSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: decodedSize.width / scale, height: decodedSize.height / scale)
        )
        return .image(AgentAttachmentDecodedImage(image: image, pixelSize: originalPixelSize(of: source) ?? decodedSize))
    }

    private static func fallbackDecode(path: String) -> AgentAttachmentImageLoadResult {
        guard let image = NSImage(contentsOfFile: path) else { return .undecodable }
        let representation = image.representations.first
        let pixelSize = representation.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        return .image(AgentAttachmentDecodedImage(image: image, pixelSize: pixelSize))
    }

    private static func originalPixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        // EXIF orientations 5–8 rotate the image a quarter turn.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
