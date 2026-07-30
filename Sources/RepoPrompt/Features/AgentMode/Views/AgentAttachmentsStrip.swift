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
        lhs.scopeTabID == rhs.scopeTabID
            && lhs.imageAttachments.map(\.id) == rhs.imageAttachments.map(\.id)
            && lhs.taggedFileAttachments.map { TaggedFileRenderKey($0) } == rhs.taggedFileAttachments.map { TaggedFileRenderKey($0) }
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
        }
    }

    private func imageAttachmentCard(_ attachment: AgentImageAttachment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AgentImageAttachmentThumbnailView(attachment: attachment)
                    .frame(width: 76, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                if allowsRemoval, let onRemoveImage {
                    Button {
                        onRemoveImage(attachment.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(disabled ? .gray : .secondary)
                            .background(Color(NSColor.windowBackgroundColor).clipShape(Circle()))
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .offset(x: 4, y: -4)
                }
            }

            Text(title(for: attachment))
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: fontPreset.scaledMetric(76), alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
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

    private func title(for attachment: AgentImageAttachment) -> String {
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

private struct AgentImageAttachmentThumbnailView: View, Equatable {
    let attachment: AgentImageAttachment

    @State private var image: NSImage?
    @State private var activeKey: AgentAttachmentThumbnailKey?
    @State private var loadToken: AgentAttachmentThumbnailLoadToken?

    static func == (lhs: AgentImageAttachmentThumbnailView, rhs: AgentImageAttachmentThumbnailView) -> Bool {
        lhs.attachment.id == rhs.attachment.id
    }

    var body: some View {
        thumbnailContent
            .onAppear(perform: loadThumbnailIfNeeded)
            .onChange(of: thumbnailKey) { _, _ in
                loadThumbnailIfNeeded()
            }
            .onDisappear {
                loadToken?.cancel()
                loadToken = nil
            }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            placeholderThumbnail
        }
    }

    private var placeholderThumbnail: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            Image(systemName: "photo")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
        }
    }

    private var thumbnailKey: AgentAttachmentThumbnailKey? {
        guard case let .localFile(path) = attachment.source else { return nil }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !standardizedPath.isEmpty else { return nil }
        let scale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
        return AgentAttachmentThumbnailKey(
            path: standardizedPath,
            pixelWidth: Int((76 * scale).rounded(.up)),
            pixelHeight: Int((52 * scale).rounded(.up))
        )
    }

    private func loadThumbnailIfNeeded() {
        loadToken?.cancel()
        loadToken = nil

        guard let key = thumbnailKey else {
            activeKey = nil
            image = nil
            return
        }

        if activeKey != key {
            activeKey = key
            image = nil
        }

        let cache = AgentAttachmentThumbnailCache.shared
        if let cachedImage = cache.cachedImage(for: key) {
            image = cachedImage
            return
        }

        let token = cache.loadImage(for: key) { loadedImage in
            guard activeKey == key else { return }
            image = loadedImage
        }
        loadToken = token
    }
}

private struct AgentAttachmentThumbnailKey: Hashable {
    let path: String
    let pixelWidth: Int
    let pixelHeight: Int

    var cacheKey: NSString {
        "\(path)|\(pixelWidth)x\(pixelHeight)" as NSString
    }
}

private final class AgentAttachmentThumbnailLoadToken {
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

private final class AgentAttachmentThumbnailCache {
    static let shared = AgentAttachmentThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let loadQueue = DispatchQueue(label: "com.repoprompt.agent-attachment-thumbnails", qos: .userInitiated)

    private init() {
        cache.countLimit = 200
    }

    func cachedImage(for key: AgentAttachmentThumbnailKey) -> NSImage? {
        cache.object(forKey: key.cacheKey)
    }

    func loadImage(
        for key: AgentAttachmentThumbnailKey,
        completion: @escaping (NSImage?) -> Void
    ) -> AgentAttachmentThumbnailLoadToken {
        if let cached = cachedImage(for: key) {
            DispatchQueue.main.async {
                completion(cached)
            }
            return AgentAttachmentThumbnailLoadToken()
        }

        let token = AgentAttachmentThumbnailLoadToken()
        loadQueue.async { [weak self, weak token] in
            guard let self, token?.isCancelled == false else { return }
            let decodedImage = Self.decodeThumbnail(for: key)
            DispatchQueue.main.async { [weak self, weak token] in
                guard let self, token?.isCancelled == false else { return }
                if let decodedImage {
                    cache.setObject(decodedImage, forKey: key.cacheKey)
                }
                completion(decodedImage)
            }
        }
        return token
    }

    private static func decodeThumbnail(for key: AgentAttachmentThumbnailKey) -> NSImage? {
        guard FileManager.default.fileExists(atPath: key.path) else { return nil }
        let url = URL(fileURLWithPath: key.path)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return NSImage(contentsOfFile: key.path)
        }
        let maxPixelSize = max(key.pixelWidth, key.pixelHeight)
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return NSImage(contentsOfFile: key.path)
        }
        let size = NSSize(
            width: CGFloat(key.pixelWidth) / max(1, NSScreen.main?.backingScaleFactor ?? 2),
            height: CGFloat(key.pixelHeight) / max(1, NSScreen.main?.backingScaleFactor ?? 2)
        )
        return NSImage(cgImage: cgImage, size: size)
    }
}
