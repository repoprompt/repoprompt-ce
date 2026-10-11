import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pane-wide image drop state for one Agent Mode pane.
///
/// The pane's SwiftUI drop delegate and the composer's `ImageAwareTextView` both report into this
/// controller, so the overlay stays lit while an image drag moves between the transcript, the
/// text field, and the composer controls. Text and non-image drags are never highlighted.
@MainActor
final class AgentImageDropController: ObservableObject {
    @Published private(set) var isPaneHighlighted = false
    @Published private(set) var isTextViewImageDragActive = false
    private(set) var tracker = AgentImageDropTracker()

    var isOverlayVisible: Bool {
        isPaneHighlighted || isTextViewImageDragActive
    }

    /// Whether the pane accepts the current drag; undetermined file drags are accepted and
    /// filtered when the drop loads, so a slow URL read never rejects an image.
    var acceptsPaneDrop: Bool {
        tracker.classification == .images || tracker.classification == .undetermined
    }

    /// Starts a pane drag, capturing the tab that is current now. File URLs that cannot be classified
    /// from their registered types are read asynchronously and resolve the highlight later.
    func paneDragEntered(typeIdentifiers: [String], fileURLProviders: [NSItemProvider], currentTabID: UUID?) {
        let classification = AgentImageDropClassifier.classify(typeIdentifiers: typeIdentifiers, fileURLs: nil)
        let generation = tracker.begin(tabID: currentTabID, classification: classification)
        // AppKit exits the text view before the pane is entered; clear a hover a torn-down or
        // missed text-view exit left behind.
        setTextViewImageDragActive(false)
        publishHighlight()
        guard classification == .undetermined, !fileURLProviders.isEmpty else { return }
        probeFileURLs(fileURLProviders, generation: generation)
    }

    func resolvePaneClassification(_ classification: AgentImageDropClassifier.Classification, generation: UInt64) {
        guard tracker.resolve(classification, generation: generation) else { return }
        publishHighlight()
    }

    /// Leaves the text-view hover alone: SwiftUI may deliver this exit after AppKit has already
    /// entered the text view, and clearing it here would unlight a live hover. Stuck hovers are
    /// cleared on the next pane entry, on drop, and when the text view is dismantled.
    func paneDragExited() {
        tracker.exit()
        publishHighlight()
    }

    func setTextViewImageDragActive(_ isActive: Bool) {
        guard isTextViewImageDragActive != isActive else { return }
        isTextViewImageDragActive = isActive
    }

    /// Ends the drag and loads its images, attaching them to the tab captured when the drag began
    /// even if the user switches tabs while the load is in flight.
    @discardableResult
    func performPaneDrop(
        currentTabID: UUID?,
        load: (_ completion: @escaping ([AgentImageInputAdapter.PreparedImage]) -> Void) -> Bool,
        attach: @escaping (_ tabID: UUID, _ prepared: [AgentImageInputAdapter.PreparedImage]) -> Void
    ) -> Bool {
        let accepts = tracker.classification.map { $0 != .notImages } ?? true
        let target = tracker.takeDropTarget(fallbackTabID: currentTabID)
        publishHighlight()
        isTextViewImageDragActive = false
        guard accepts, let target else { return false }
        return load { prepared in
            guard !prepared.isEmpty else { return }
            attach(target, prepared)
        }
    }

    private func publishHighlight() {
        let highlighted = tracker.isHighlighted
        if isPaneHighlighted != highlighted {
            isPaneHighlighted = highlighted
        }
    }

    private func probeFileURLs(_ providers: [NSItemProvider], generation: UInt64) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            lock.lock()
            let loaded = urls
            lock.unlock()
            // Unreadable during the drag: stay undetermined and let the drop decide.
            guard !loaded.isEmpty else { return }
            let classification = AgentImageDropClassifier.classify(typeIdentifiers: [], fileURLs: loaded)
            Task { @MainActor [weak self] in
                self?.resolvePaneClassification(classification, generation: generation)
            }
        }
    }
}

/// The pane-wide drop target installed on the Agent Mode ZStack.
struct AgentImagePaneDropDelegate: DropDelegate {
    let controller: AgentImageDropController
    let currentTabID: () -> UUID?
    let attachImages: (_ tabID: UUID, _ urls: [URL]) -> Void
    var imageInputAdapter = AgentImageInputAdapter()

    static let acceptedTypes: [UTType] = [.image, .fileURL]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        let providers = info.itemProviders(for: Self.acceptedTypes)
        controller.paneDragEntered(
            typeIdentifiers: providers.flatMap(\.registeredTypeIdentifiers),
            fileURLProviders: providers,
            currentTabID: currentTabID()
        )
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: controller.acceptsPaneDrop ? .copy : .cancel)
    }

    func dropExited(info _: DropInfo) {
        controller.paneDragExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: Self.acceptedTypes)
        let adapter = imageInputAdapter
        let attachImages = attachImages
        return controller.performPaneDrop(
            currentTabID: currentTabID(),
            load: { completion in
                adapter.loadPreparedImages(from: providers, completion: completion)
            },
            attach: { tabID, prepared in
                attachImages(tabID, prepared.map(\.url))
                adapter.cleanupTemporaryFiles(prepared)
            }
        )
    }
}

/// Dimmed, accent-dashed overlay shown while an image drag is over the pane.
struct AgentImageDropOverlay: View {
    @ObservedObject var controller: AgentImageDropController

    var body: some View {
        ZStack {
            if controller.isOverlayVisible {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    Label("Drop images to attach", systemImage: "photo.badge.plus")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(8)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: controller.isOverlayVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(!controller.isOverlayVisible)
    }
}

extension EnvironmentValues {
    /// The enclosing Agent Mode pane's image drop controller, for the composer text view hand-off.
    @Entry var agentImageDropController: AgentImageDropController? = nil
}
