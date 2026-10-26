import AppKit
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
        lhs.scopeTabID == rhs.scopeTabID
            && lhs.attachments.map(\.id) == rhs.attachments.map(\.id)
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
        FontScalePreset.current.scaledMetric(108)
    }

    static var fileOnlyStripHeight: CGFloat {
        FontScalePreset.current.scaledMetric(24)
    }

    static let composerVerticalSpacingWhenPresent: CGFloat = 8

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
        }
    }

    private func attachmentCard(_ attachment: AgentFileAttachment) -> some View {
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
