import Foundation
import UniformTypeIdentifiers

package struct AttachmentFacts: Equatable {
    package let kind: AttachmentKind
    package let fileName: String
    package let byteCount: Int

    package init(kind: AttachmentKind, fileName: String, byteCount: Int) {
        self.kind = kind
        self.fileName = Self.lastPathComponent(fileName)
        self.byteCount = max(0, byteCount)
    }

    /// Reduces any path to its last component, so a directory can never reach a transcript or a tile.
    package static func lastPathComponent(_ name: String) -> String {
        let component = (name as NSString).lastPathComponent
        return component == "/" ? "" : component
    }

    /// The one human form of a byte count in this subsystem: tiles and the path mention both use it.
    package static func humanSize(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, byteCount)), countStyle: .file)
    }

    package var canHavePreview: Bool {
        switch kind {
        case .image, .pdf: true
        case .text, .binary: false
        }
    }
}

package enum AttachmentPreviewAvailability: Equatable {
    case available
    case pending
    case unavailable
}

package enum AttachmentGlyph: Equatable {
    case photo
    case document
    case file

    package var systemSymbolName: String {
        switch self {
        case .photo: "photo"
        case .document: "doc.text"
        case .file: "doc"
        }
    }
}

package enum AttachmentFace: Equatable {
    case preview
    case glyph(AttachmentGlyph)
}

package enum AttachmentStatus: Equatable {
    case ready
    case previewUnavailable
    case refused(reason: String)
}

package struct AttachmentPresentation: Equatable {
    package let face: AttachmentFace
    package let title: String
    package let caption: String?
    package let badge: String?
    package let status: AttachmentStatus
    package let accessibilityLabel: String

    package var refusalReason: String? {
        if case let .refused(reason) = status { reason } else { nil }
    }

    package static let previewUnavailableCaption = "Preview unavailable"
    private static let maxBadgeLength = 6

    /// - Parameters:
    ///   - preview: Whether a rendered preview exists. `.pending` shows the preview face while one loads.
    ///   - route: The route the attachment is about to travel, or nil when nothing is about to send.
    package static func make(
        facts: AttachmentFacts,
        preview: AttachmentPreviewAvailability,
        route: AttachmentRoute? = nil,
        limits: OracleAttachmentLimits = .production
    ) -> AttachmentPresentation {
        let title = facts.fileName.isEmpty ? fallbackTitle(for: facts.kind) : facts.fileName
        let typeDescription = typeDescription(for: facts)
        let detail = [typeDescription, sizeDescription(facts.byteCount)].compactMap(\.self).joined(separator: " · ")

        let face: AttachmentFace
        var caption: String? = detail
        var badge = badge(for: facts)
        var status = AttachmentStatus.ready

        if facts.canHavePreview {
            switch preview {
            case .available, .pending:
                face = .preview
                if facts.kind == .image {
                    badge = nil
                }
            case .unavailable:
                face = .glyph(glyph(for: facts.kind))
                caption = previewUnavailableCaption
                status = .previewUnavailable
            }
        } else {
            face = .glyph(glyph(for: facts.kind))
        }

        if let route, let reason = refusal(for: facts, title: title, route: route, limits: limits) {
            caption = reason
            status = .refused(reason: reason)
        }

        return AttachmentPresentation(
            face: face,
            title: title,
            caption: caption,
            badge: badge,
            status: status,
            accessibilityLabel: accessibilityLabel(
                title: title,
                typeDescription: typeDescription,
                byteCount: facts.byteCount,
                status: status
            )
        )
    }

    private static func refusal(
        for facts: AttachmentFacts,
        title: String,
        route: AttachmentRoute,
        limits: OracleAttachmentLimits
    ) -> String? {
        let capability = AttachmentRouteCapability.capability(for: route)
        guard let reason = AttachmentPlanner.refusalReason(
            kind: facts.kind,
            byteCount: facts.byteCount,
            capability: capability,
            limits: limits
        ) else { return nil }
        return AttachmentRefusal(
            index: 0,
            fileName: title,
            kind: facts.kind,
            routeDisplayName: capability.displayName,
            reason: reason
        ).reasonText
    }

    private static func glyph(for kind: AttachmentKind) -> AttachmentGlyph {
        switch kind {
        case .image: .photo
        case .pdf, .text: .document
        case .binary: .file
        }
    }

    private static func fallbackTitle(for kind: AttachmentKind) -> String {
        switch kind {
        case .image: "Image"
        case .pdf: "PDF document"
        case .text: "Text file"
        case .binary: "File"
        }
    }

    /// The type named by the file extension, trusted only where the content kind leaves it open.
    private static func extensionType(for facts: AttachmentFacts) -> UTType? {
        let fileExtension = (facts.fileName as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return nil }
        switch facts.kind {
        case .image: return type.conforms(to: .image) ? type : nil
        case .pdf: return nil
        case .text, .binary: return type
        }
    }

    private static func badge(for facts: AttachmentFacts) -> String? {
        let type: UTType? = switch facts.kind {
        case .pdf: .pdf
        case .image, .text, .binary: extensionType(for: facts)
        }
        let fileExtension = (facts.fileName as NSString).pathExtension
        let raw = type?.preferredFilenameExtension
            ?? (fileExtension.isEmpty ? nil : fileExtension)
            ?? (facts.kind == .text ? UTType.plainText.preferredFilenameExtension : nil)
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.uppercased().prefix(maxBadgeLength))
    }

    private static func typeDescription(for facts: AttachmentFacts) -> String {
        let type: UTType? = switch facts.kind {
        case .pdf: .pdf
        case .image, .text, .binary: extensionType(for: facts)
        }
        if let description = type?.localizedDescription, !description.isEmpty {
            return description
        }
        return fallbackTitle(for: facts.kind)
    }

    private static func sizeDescription(_ byteCount: Int) -> String? {
        byteCount > 0 ? AttachmentFacts.humanSize(byteCount) : nil
    }

    private static func accessibilityLabel(
        title: String,
        typeDescription: String,
        byteCount: Int,
        status: AttachmentStatus
    ) -> String {
        var parts = [title, typeDescription]
        if let size = sizeDescription(byteCount) { parts.append(size) }
        switch status {
        case .ready: break
        case .previewUnavailable: parts.append(previewUnavailableCaption.lowercased())
        case let .refused(reason): parts.append("cannot be sent: \(reason)")
        }
        return parts.joined(separator: ", ")
    }
}
