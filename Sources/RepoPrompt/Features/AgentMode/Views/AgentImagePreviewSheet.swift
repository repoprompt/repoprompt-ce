import AppKit
import SwiftUI

/// Full-size viewer for an Agent Mode image attachment, opened from composer and transcript cards.
///
/// The image is decoded off the main thread at a bounded preview size and fitted to the sheet.
/// Esc, ⌘W, and the Close button dismiss it; the decode is cancelled when the sheet closes.
struct AgentImagePreviewSheet: View {
    let attachment: AgentImageAttachment
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var loadToken: AgentAttachmentImageLoadToken?
    /// Captured once from the presenting window; re-reading it after presentation would measure
    /// the sheet itself and shrink it on every re-render.
    @State private var idealSize = Self.initialIdealSize()

    private enum Phase {
        case loading
        case loaded(NSImage, pixelSize: CGSize)
        case missing
        case failed
    }

    private var path: String? {
        AgentImageAttachmentAvailabilityResolver.path(for: attachment)
    }

    private static func initialIdealSize() -> CGSize {
        let windowSize = (NSApp.mainWindow ?? NSApp.keyWindow)?.frame.size ?? CGSize(width: 1000, height: 760)
        return CGSize(width: max(520, windowSize.width * 0.85), height: max(400, windowSize.height * 0.85))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        }
        .frame(
            minWidth: 520,
            idealWidth: idealSize.width,
            maxWidth: .infinity,
            minHeight: 400,
            idealHeight: idealSize.height,
            maxHeight: .infinity
        )
        .background(closeShortcut)
        .onExitCommand { dismiss() }
        .onAppear(perform: loadPreview)
        .onDisappear {
            loadToken?.cancel()
            loadToken = nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(dimensionsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            Button("Reveal in Finder", action: revealInFinder)
                .disabled(!canReveal)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case let .loaded(image, _):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .accessibilityLabel(Text(title))
        case .missing:
            unavailableView(message: "Image no longer available")
        case .failed:
            unavailableView(message: "This image couldn't be displayed")
        }
    }

    private func unavailableView(message: String) -> some View {
        VStack(spacing: 10) {
            AgentImageMissingPlaceholder()
                .frame(width: 96, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    /// ⌘W closes the sheet like a window; kept invisible but in the hierarchy so the shortcut works.
    private var closeShortcut: some View {
        Button("Close Preview") { dismiss() }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var dimensionsText: String {
        switch phase {
        case let .loaded(_, pixelSize):
            "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px"
        case .missing:
            "Unavailable"
        case .loading, .failed:
            " "
        }
    }

    private var canReveal: Bool {
        if case .loaded = phase { return true }
        return false
    }

    private func revealInFinder() {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func loadPreview() {
        loadToken?.cancel()
        guard let path else {
            phase = .failed
            return
        }
        let key = AgentAttachmentImageKey.preview(path: path, backingScale: NSScreen.main?.backingScaleFactor ?? 2)
        let cache = AgentAttachmentThumbnailCache.shared
        if let cached = cache.cachedImage(for: key) {
            phase = .loaded(cached.image, pixelSize: cached.pixelSize)
            return
        }
        phase = .loading
        loadToken = cache.loadImage(for: key) { result in
            switch result {
            case let .image(decoded):
                phase = .loaded(decoded.image, pixelSize: decoded.pixelSize)
            case .missing:
                phase = .missing
            case .undecodable:
                phase = .failed
            }
        }
    }
}
