import AppKit
import RepoPromptDomainRuntime
import SwiftUI

enum AttachmentTileGeometry {
    case strip
    case chip

    var faceSize: CGSize {
        switch self {
        case .strip: CGSize(width: 76, height: 52)
        case .chip: CGSize(width: 48, height: 48)
        }
    }

    var showsLabels: Bool {
        self == .strip
    }

    var faceCornerRadius: CGFloat {
        8
    }
}

enum AttachmentTilePreview: Equatable {
    case none
    case rendered(Data)
    case file(URL)
}

struct AttachmentTile: View {
    let facts: AttachmentFacts
    let preview: AttachmentTilePreview
    let geometry: AttachmentTileGeometry
    let labelScale: CGFloat
    var isDisabled = false
    var onDismiss: (() -> Void)?

    @State private var loaded: LoadedPreview

    private enum LoadedPreview {
        case pending
        case image(NSImage)
        case missing

        var availability: AttachmentPreviewAvailability {
            switch self {
            case .pending: .pending
            case .image: .available
            case .missing: .unavailable
            }
        }
    }

    init(
        facts: AttachmentFacts,
        preview: AttachmentTilePreview,
        geometry: AttachmentTileGeometry,
        labelScale: CGFloat = 1,
        isDisabled: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        self.facts = facts
        self.preview = preview
        self.geometry = geometry
        self.labelScale = labelScale
        self.isDisabled = isDisabled
        self.onDismiss = onDismiss
        _loaded = State(initialValue: Self.immediatePreview(facts: facts, preview: preview))
    }

    private var presentation: AttachmentPresentation {
        AttachmentPresentation.make(facts: facts, preview: loaded.availability)
    }

    var body: some View {
        let presentation = presentation
        content(presentation)
            .task(id: preview) { await loadPreview() }
    }

    @ViewBuilder
    private func content(_ presentation: AttachmentPresentation) -> some View {
        switch geometry {
        case .strip:
            stripCard(presentation)
        case .chip:
            faceWithDismiss(presentation)
                .hoverTooltip(tooltip(for: presentation))
        }
    }

    private func stripCard(_ presentation: AttachmentPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            faceWithDismiss(presentation)

            Text(presentation.title)
                .font(.system(size: 10 * labelScale, weight: .regular, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: geometry.faceSize.width * labelScale, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
        .hoverTooltip(tooltip(for: presentation))
    }

    private func faceWithDismiss(_ presentation: AttachmentPresentation) -> some View {
        ZStack(alignment: .topTrailing) {
            face(presentation)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityLabel)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(isDisabled ? .gray : .secondary)
                        .background(Color(NSColor.windowBackgroundColor).clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel("Remove \(presentation.title)")
                .offset(x: 4, y: -4)
            }
        }
    }

    private func face(_ presentation: AttachmentPresentation) -> some View {
        let shape = RoundedRectangle(cornerRadius: geometry.faceCornerRadius)
        return faceFill(presentation.face)
            .frame(width: geometry.faceSize.width, height: geometry.faceSize.height)
            .overlay(alignment: .bottomLeading) {
                if let badge = presentation.badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.regularMaterial, in: Capsule())
                        .padding(3)
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func faceFill(_ face: AttachmentFace) -> some View {
        switch face {
        case .preview:
            if case let .image(image) = loaded {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        case let .glyph(glyph):
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: glyph.systemSymbolName)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func tooltip(for presentation: AttachmentPresentation) -> String {
        [presentation.title, presentation.caption].compactMap(\.self).joined(separator: "\n")
    }

    private static func immediatePreview(facts: AttachmentFacts, preview: AttachmentTilePreview) -> LoadedPreview {
        guard facts.canHavePreview else { return .missing }
        switch preview {
        case .none:
            return .missing
        case let .rendered(data):
            return NSImage(data: data).map(LoadedPreview.image) ?? .missing
        case let .file(url):
            return AttachmentTilePreviewCache.shared.image(for: url, kind: facts.kind).map(LoadedPreview.image) ?? .pending
        }
    }

    private func loadPreview() async {
        let immediate = Self.immediatePreview(facts: facts, preview: preview)
        loaded = immediate
        guard case .pending = immediate, case let .file(url) = preview else { return }
        let image = await AttachmentTilePreviewCache.shared.render(url: url, kind: facts.kind)
        guard !Task.isCancelled else { return }
        loaded = image.map(LoadedPreview.image) ?? .missing
    }
}

private final class AttachmentTilePreviewCache: @unchecked Sendable {
    static let shared = AttachmentTilePreviewCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for url: URL, kind: AttachmentKind) -> NSImage? {
        cache.object(forKey: Self.key(url, kind))
    }

    func render(url: URL, kind: AttachmentKind) async -> NSImage? {
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try AttachmentPreviewRenderer.jpegData(fromFileAt: url, kind: kind) }
        }
        let jpeg = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard let jpeg, let image = NSImage(data: jpeg) else { return nil }
        cache.setObject(image, forKey: Self.key(url, kind))
        return image
    }

    private static func key(_ url: URL, _ kind: AttachmentKind) -> NSString {
        "\(kind.rawValue)|\(url.standardizedFileURL.path)" as NSString
    }
}
