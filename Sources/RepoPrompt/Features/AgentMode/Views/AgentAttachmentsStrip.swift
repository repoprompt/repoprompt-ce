import AppKit
import Combine
import RepoPromptDomainRuntime
import SwiftUI

struct AgentAttachmentStripSnapshot: Equatable {
    let scopeTabID: UUID?
    let attachments: [AgentFileAttachment]
    let taggedFileAttachments: [AgentTaggedFileAttachment]

    init(
        scopeTabID: UUID? = nil,
        attachments: [AgentFileAttachment],
        taggedFileAttachments: [AgentTaggedFileAttachment]
    ) {
        self.scopeTabID = scopeTabID
        self.attachments = attachments
        self.taggedFileAttachments = taggedFileAttachments
    }

    var hasAttachments: Bool {
        !attachments.isEmpty
    }

    var hasTaggedFiles: Bool {
        !taggedFileAttachments.isEmpty
    }

    var hasAny: Bool {
        hasAttachments || hasTaggedFiles
    }

    static func == (lhs: AgentAttachmentStripSnapshot, rhs: AgentAttachmentStripSnapshot) -> Bool {
        // Compare sources, not just IDs: a finished turn rewrites an image's path to its kept copy.
        lhs.scopeTabID == rhs.scopeTabID
            && lhs.attachments.map(ImageRenderKey.init) == rhs.attachments.map(ImageRenderKey.init)
            && lhs.taggedFileAttachments.map { TaggedFileRenderKey($0) } == rhs.taggedFileAttachments.map { TaggedFileRenderKey($0) }
    }

    private struct ImageRenderKey: Equatable {
        let id: UUID
        let source: AgentAttachmentSource

        init(_ attachment: AgentFileAttachment) {
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
        FontScalePreset.current.scaledMetric(108)
    }

    static var fileOnlyStripHeight: CGFloat {
        FontScalePreset.current.scaledMetric(24)
    }

    static let composerVerticalSpacingWhenPresent: CGFloat = 8

    /// Fixed thumbnail frame so loading, missing, and loaded cards never change row height.
    static let thumbnailSize = CGSize(width: 76, height: 52)

    static func reservedHeight(hasAttachments: Bool, hasTaggedFiles: Bool) -> CGFloat {
        if hasAttachments {
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
    var onRemoveAttachment: ((UUID) -> Void)?
    var onRemoveTaggedFile: ((UUID) -> Void)?
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var previewAttachment: AgentFileAttachment?
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    init(
        snapshot: AgentAttachmentStripSnapshot,
        disabled: Bool = false,
        allowsRemoval: Bool = true,
        onRemoveAttachment: ((UUID) -> Void)? = nil,
        onRemoveTaggedFile: ((UUID) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.disabled = disabled
        self.allowsRemoval = allowsRemoval
        self.onRemoveAttachment = onRemoveAttachment
        self.onRemoveTaggedFile = onRemoveTaggedFile
    }

    init(
        scopeTabID: UUID? = nil,
        attachments: [AgentFileAttachment],
        taggedFileAttachments: [AgentTaggedFileAttachment],
        disabled: Bool = false,
        allowsRemoval: Bool = true,
        onRemoveAttachment: ((UUID) -> Void)? = nil,
        onRemoveTaggedFile: ((UUID) -> Void)? = nil
    ) {
        self.init(
            snapshot: AgentAttachmentStripSnapshot(
                scopeTabID: scopeTabID,
                attachments: attachments,
                taggedFileAttachments: taggedFileAttachments
            ),
            disabled: disabled,
            allowsRemoval: allowsRemoval,
            onRemoveAttachment: onRemoveAttachment,
            onRemoveTaggedFile: onRemoveTaggedFile
        )
    }

    static func == (lhs: AgentAttachmentsStrip, rhs: AgentAttachmentsStrip) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.disabled == rhs.disabled
            && lhs.allowsRemoval == rhs.allowsRemoval
    }

    private enum AttachmentItem: Identifiable {
        case attachment(AgentFileAttachment)
        case file(AgentTaggedFileAttachment)

        var id: String {
            switch self {
            case let .attachment(attachment):
                "image-\(attachment.id.uuidString)"
            case let .file(attachment):
                "file-\(attachment.id.uuidString)"
            }
        }

        var createdAt: Date {
            switch self {
            case let .attachment(attachment):
                attachment.createdAt
            case let .file(attachment):
                attachment.createdAt
            }
        }
    }

    private var items: [AttachmentItem] {
        (snapshot.attachments.map(AttachmentItem.attachment) + snapshot.taggedFileAttachments.map(AttachmentItem.file))
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        switch item {
                        case let .attachment(attachment):
                            attachmentCard(attachment)
                        case let .file(attachment):
                            fileAttachmentCard(attachment)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .sheet(item: $previewAttachment) { attachment in
                AgentImagePreviewSheet(attachment: attachment, title: attachment.title ?? attachment.facts.fileName)
            }
        }
    }

    private func imageAttachmentCard(_ attachment: AgentFileAttachment) -> some View {
        var onRemove: (() -> Void)?
        if allowsRemoval, let onRemoveAttachment {
            onRemove = { onRemoveAttachment(attachment.id) }
        }
        return AgentImageAttachmentCard(
            attachment: attachment,
            title: attachment.title ?? attachment.facts.fileName,
            disabled: disabled,
            fontPreset: fontPreset,
            onRemove: onRemove,
            onOpen: { previewAttachment = attachment }
        )
        .id(attachment.id)
    }

    @ViewBuilder
    private func attachmentCard(_ attachment: AgentFileAttachment) -> some View {
        if attachment.kind == .image {
            imageAttachmentCard(attachment)
        } else {
            genericAttachmentCard(attachment)
        }
    }

    private func genericAttachmentCard(_ attachment: AgentFileAttachment) -> some View {
        AttachmentTile(
            facts: attachment.facts,
            preview: preview(for: attachment),
            geometry: .strip,
            labelScale: fontPreset.scaleFactor,
            isDisabled: disabled,
            onDismiss: allowsRemoval ? onRemoveAttachment.map { remove in { remove(attachment.id) } } : nil
        )
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

    private func preview(for attachment: AgentFileAttachment) -> AttachmentTilePreview {
        switch attachment.source {
        case let .localFile(path): .file(URL(fileURLWithPath: path))
        case .url: .none
        }
    }
}

// MARK: - Image card

/// A fixed-size, clickable image card. Missing files render a placeholder that cannot be opened.
private struct AgentImageAttachmentCard: View {
    let attachment: AgentFileAttachment
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
        .onReceive(AttachmentTilePreviewCache.shared.retainedImages.invalidatedPaths.receive(on: DispatchQueue.main)) { paths in
            guard let path = AgentImageAttachmentAvailabilityResolver.path(for: attachment),
                  paths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
            else { return }
            loadThumbnail()
        }
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

        let cache = AttachmentTilePreviewCache.shared.retainedImages
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
