import AppKit
import ImageIO
import SwiftUI

struct AgentAttachmentStripSnapshot: Equatable {
    let scopeTabID: UUID?
    let imageAttachments: [AgentImageAttachment]
    let taggedFileAttachments: [AgentTaggedFileAttachment]

    init(
        scopeTabID: UUID? = nil,
        imageAttachments: [AgentImageAttachment],
        taggedFileAttachments: [AgentTaggedFileAttachment]
    ) {
        self.scopeTabID = scopeTabID
        self.imageAttachments = imageAttachments
        self.taggedFileAttachments = taggedFileAttachments
    }

    var hasImages: Bool {
        !imageAttachments.isEmpty
    }

    var hasTaggedFiles: Bool {
        !taggedFileAttachments.isEmpty
    }

    var hasAny: Bool {
        hasImages || hasTaggedFiles
    }

    static func == (lhs: AgentAttachmentStripSnapshot, rhs: AgentAttachmentStripSnapshot) -> Bool {
        // Compare sources, not just IDs: a finished turn rewrites an image's path to its kept copy.
        lhs.scopeTabID == rhs.scopeTabID
            && lhs.imageAttachments.map(ImageRenderKey.init) == rhs.imageAttachments.map(ImageRenderKey.init)
            && lhs.taggedFileAttachments.map { TaggedFileRenderKey($0) } == rhs.taggedFileAttachments.map { TaggedFileRenderKey($0) }
    }

    private struct ImageRenderKey: Equatable {
        let id: UUID
        let source: AgentImageSource

        init(_ attachment: AgentImageAttachment) {
            id = attachment.id
            source = attachment.source
        }
    }

    private struct TaggedFileRenderKey: Equatable {
        let id: UUID
        let displayName: String
        let relativePath: String

        init(_ attachment: AgentTaggedFileAttachment) {
            id = attachment.id
            displayName = attachment.displayName
            relativePath = attachment.relativePath
        }
    }
}

enum AgentAttachmentStripLayout {
    static var imageStripHeight: CGFloat {
        FontScalePreset.current.scaledMetric(88)
    }

    static var fileOnlyStripHeight: CGFloat {
        FontScalePreset.current.scaledMetric(24)
    }

    static let composerVerticalSpacingWhenPresent: CGFloat = 8

    /// Fixed thumbnail frame so loading, missing, and loaded cards never change row height.
    static let thumbnailSize = CGSize(width: 76, height: 52)

    static func reservedHeight(hasImages: Bool, hasTaggedFiles: Bool) -> CGFloat {
        if hasImages {
            return imageStripHeight + composerVerticalSpacingWhenPresent
        }
        if hasTaggedFiles {
            return fileOnlyStripHeight + composerVerticalSpacingWhenPresent
        }
        return 0
    }
}

struct AgentAttachmentsStrip: View, Equatable {
    let snapshot: AgentAttachmentStripSnapshot
    var disabled: Bool = false
    var allowsRemoval: Bool = true
    var onRemoveImage: ((UUID) -> Void)?
    var onRemoveTaggedFile: ((UUID) -> Void)?
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var previewAttachment: AgentImageAttachment?
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    init(
        snapshot: AgentAttachmentStripSnapshot,
        disabled: Bool = false,
        allowsRemoval: Bool = true,
        onRemoveImage: ((UUID) -> Void)? = nil,
        onRemoveTaggedFile: ((UUID) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.disabled = disabled
        self.allowsRemoval = allowsRemoval
        self.onRemoveImage = onRemoveImage
        self.onRemoveTaggedFile = onRemoveTaggedFile
    }

    init(
        scopeTabID: UUID? = nil,
        imageAttachments: [AgentImageAttachment],
        taggedFileAttachments: [AgentTaggedFileAttachment],
        disabled: Bool = false,
        allowsRemoval: Bool = true,
        onRemoveImage: ((UUID) -> Void)? = nil,
        onRemoveTaggedFile: ((UUID) -> Void)? = nil
    ) {
        self.init(
            snapshot: AgentAttachmentStripSnapshot(
                scopeTabID: scopeTabID,
                imageAttachments: imageAttachments,
                taggedFileAttachments: taggedFileAttachments
            ),
            disabled: disabled,
            allowsRemoval: allowsRemoval,
            onRemoveImage: onRemoveImage,
            onRemoveTaggedFile: onRemoveTaggedFile
        )
    }

    static func == (lhs: AgentAttachmentsStrip, rhs: AgentAttachmentsStrip) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.disabled == rhs.disabled
            && lhs.allowsRemoval == rhs.allowsRemoval
    }

    private enum AttachmentItem: Identifiable {
        case image(AgentImageAttachment)
        case file(AgentTaggedFileAttachment)

        var id: String {
            switch self {
            case let .image(attachment):
                "image-\(attachment.id.uuidString)"
            case let .file(attachment):
                "file-\(attachment.id.uuidString)"
            }
        }

        var createdAt: Date {
            switch self {
            case let .image(attachment):
                attachment.createdAt
            case let .file(attachment):
                attachment.createdAt
            }
        }
    }

    private var items: [AttachmentItem] {
        (snapshot.imageAttachments.map(AttachmentItem.image) + snapshot.taggedFileAttachments.map(AttachmentItem.file))
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        switch item {
                        case let .image(attachment):
                            imageAttachmentCard(attachment)
                        case let .file(attachment):
                            fileAttachmentCard(attachment)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .sheet(item: $previewAttachment) { attachment in
                AgentImagePreviewSheet(attachment: attachment, title: Self.title(for: attachment))
            }
        }
    }

    private func imageAttachmentCard(_ attachment: AgentImageAttachment) -> some View {
        var onRemove: (() -> Void)?
        if allowsRemoval, let onRemoveImage {
            onRemove = { onRemoveImage(attachment.id) }
        }
        return AgentImageAttachmentCard(
            attachment: attachment,
            title: Self.title(for: attachment),
            disabled: disabled,
            fontPreset: fontPreset,
            onRemove: onRemove,
            onOpen: { previewAttachment = attachment }
        )
        .id(attachment.id)
    }

    private func fileAttachmentCard(_ attachment: AgentTaggedFileAttachment) -> some View {
        let path = attachment.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = path.isEmpty ? attachment.displayName : path
        return HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text(title)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: fontPreset.scaledMetric(170), alignment: .leading)
                .accessibilityLabel(attachment.relativePath)

            if allowsRemoval, let onRemoveTaggedFile {
                Button {
                    onRemoveTaggedFile(attachment.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(disabled ? .gray : .secondary)
                        .background(Color(NSColor.windowBackgroundColor).clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
        .hoverTooltip(attachment.relativePath)
    }

    static func title(for attachment: AgentImageAttachment) -> String {
        if let title = attachment.title, !title.isEmpty {
            return title
        }
        switch attachment.source {
        case let .localFile(path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .url:
            return "Image"
        }
    }
}

// MARK: - Image card

/// A fixed-size, clickable image card. Missing files render a placeholder that cannot be opened.
private struct AgentImageAttachmentCard: View {
    let attachment: AgentImageAttachment
    let title: String
    let disabled: Bool
    let fontPreset: FontScalePreset
    let onRemove: (() -> Void)?
    let onOpen: () -> Void

    @State private var phase: AgentAttachmentThumbnailPhase = .loading
    @State private var activeKey: AgentAttachmentImageKey?
    @State private var loadToken: AgentAttachmentImageLoadToken?

    private static let missingCaption = "Image no longer available"

    private var isMissing: Bool {
        phase == .missing
    }

    private var canOpen: Bool {
        if case .loaded = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button(action: onOpen) {
                    thumbnailContent
                        .frame(
                            width: AgentAttachmentStripLayout.thumbnailSize.width,
                            height: AgentAttachmentStripLayout.thumbnailSize.height
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canOpen)
                .accessibilityLabel(isMissing ? "\(title), \(Self.missingCaption.lowercased())" : "Open \(title)")

                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(disabled ? .gray : .secondary)
                            .background(Color(NSColor.windowBackgroundColor).clipShape(Circle()))
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .offset(x: 4, y: -4)
                    .accessibilityLabel("Remove \(title)")
                }
            }

            Text(isMissing ? Self.missingCaption : title)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(isMissing ? 0.7 : 1)
                .frame(width: fontPreset.scaledMetric(AgentAttachmentStripLayout.thumbnailSize.width), alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
        .hoverTooltip(isMissing ? "\(title) is no longer available" : title)
        .onAppear(perform: loadThumbnail)
        .onChange(of: attachment.source) { _, _ in
            loadThumbnail()
        }
        .onDisappear {
            loadToken?.cancel()
            loadToken = nil
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        switch phase {
        case let .loaded(image):
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        case .missing:
            AgentImageMissingPlaceholder()
        case .loading, .unavailable:
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func loadThumbnail() {
        loadToken?.cancel()
        loadToken = nil

        guard let path = AgentImageAttachmentAvailabilityResolver.path(for: attachment) else {
            activeKey = nil
            phase = .unavailable
            return
        }
        let key = AgentAttachmentImageKey.thumbnail(
            path: path,
            pointSize: AgentAttachmentStripLayout.thumbnailSize,
            backingScale: NSScreen.main?.backingScaleFactor ?? 2
        )
        if activeKey != key {
            activeKey = key
            phase = .loading
        }

        let cache = AgentAttachmentThumbnailCache.shared
        if cache.availability.cachedAvailability(forPath: path) == .missing {
            phase = .missing
            return
        }
        if let cached = cache.cachedImage(for: key) {
            phase = .loaded(cached.image)
            return
        }
        loadToken = cache.loadImage(for: key) { result in
            guard activeKey == key else { return }
            phase = AgentAttachmentThumbnailPhase(result)
        }
    }
}

/// Fixed-size "no longer available" artwork: a slashed photo glyph.
struct AgentImageMissingPlaceholder: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.10))
            Image(systemName: "photo")
                .font(.system(size: 16))
                .foregroundColor(.secondary.opacity(0.7))
            Image(systemName: "line.diagonal")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .accessibilityHidden(true)
    }
}

enum AgentAttachmentThumbnailPhase: Equatable {
    case loading
    case loaded(NSImage)
    case missing
    case unavailable

    init(_ result: AgentAttachmentImageLoadResult) {
        switch result {
        case let .image(decoded):
            self = .loaded(decoded.image)
        case .missing:
            self = .missing
        case .undecodable:
            self = .unavailable
        }
    }
}

// MARK: - Image cache

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
    static let shared = AgentAttachmentThumbnailCache()

    /// Cached existence lookups shared by every card.
    let availability = AgentImageAttachmentAvailabilityResolver()

    private let thumbnails = NSCache<NSString, AgentAttachmentDecodedImage>()
    private let previews = NSCache<NSString, AgentAttachmentDecodedImage>()
    /// Cache keys stored per path, so a moved or evicted file can drop every rendition.
    private let keysLock = NSLock()
    private var keysByPath: [String: Set<NSString>] = [:]
    private let loadQueue = DispatchQueue(label: "com.repoprompt.agent-attachment-thumbnails", qos: .userInitiated)

    private init() {
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
        for path in paths {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            availability.record(.missing, forPath: standardized)
            keysLock.lock()
            let keys = keysByPath.removeValue(forKey: standardized) ?? []
            keysLock.unlock()
            for key in keys {
                thumbnails.removeObject(forKey: key)
                previews.removeObject(forKey: key)
            }
        }
    }

    private func noteCachedKey(_ key: AgentAttachmentImageKey) {
        keysLock.lock()
        keysByPath[key.path, default: []].insert(key.cacheKey)
        keysLock.unlock()
    }

    func loadImage(
        for key: AgentAttachmentImageKey,
        completion: @escaping (AgentAttachmentImageLoadResult) -> Void
    ) -> AgentAttachmentImageLoadToken {
        let token = AgentAttachmentImageLoadToken()
        if let cached = cachedImage(for: key) {
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                completion(.image(cached))
            }
            return token
        }

        let availability = availability
        let cache = store(for: key)
        loadQueue.async { [weak self, weak token] in
            guard let token, !token.isCancelled else { return }
            let result = Self.decode(key)
            switch result {
            case let .image(decoded):
                availability.record(.available, forPath: key.path)
                cache.setObject(decoded, forKey: key.cacheKey)
                self?.noteCachedKey(key)
            case .missing:
                availability.record(.missing, forPath: key.path)
            case .undecodable:
                availability.record(.available, forPath: key.path)
            }
            DispatchQueue.main.async { [weak token] in
                guard let token, !token.isCancelled else { return }
                completion(result)
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
