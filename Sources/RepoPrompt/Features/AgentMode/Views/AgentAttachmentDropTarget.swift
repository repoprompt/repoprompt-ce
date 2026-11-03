import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The single attachment drop owner for an Agent Mode pane, including its native text editor.
@MainActor
final class AgentAttachmentDropController: ObservableObject {
    @Published private(set) var isPaneHighlighted = false
    @Published private(set) var isTextViewAttachmentDragActive = false
    private(set) var tracker = AgentAttachmentDropTracker()

    var isOverlayVisible: Bool {
        isPaneHighlighted || isTextViewAttachmentDragActive
    }

    var acceptsPaneDrop: Bool {
        tracker.acceptsAttachments == true
    }

    func paneDragEntered(typeIdentifiers: [String], currentTabID: UUID?, dragID: String? = nil) {
        tracker.begin(
            tabID: currentTabID,
            acceptsAttachments: AgentAttachmentDropClassifier.accepts(typeIdentifiers: typeIdentifiers),
            dragID: dragID ?? Self.dragID(for: NSPasteboard(name: .drag))
        )
        setTextViewAttachmentDragActive(false)
        publishHighlight()
    }

    func textViewDragEntered(pasteboard: NSPasteboard, currentTabID: UUID?) {
        tracker.begin(
            tabID: currentTabID,
            acceptsAttachments: AgentAttachmentDropClassifier.accepts(typeIdentifiers: (pasteboard.types ?? []).map(\.rawValue)),
            dragID: Self.dragID(for: pasteboard)
        )
        // AppKit owns this hover. It must be able to clear the overlay on exit even if SwiftUI
        // never received a pane entry/exit for this direct editor drag.
        isPaneHighlighted = false
        setTextViewAttachmentDragActive(true)
    }

    /// AppKit may already own the text-view hover when SwiftUI reports the pane exit.
    func paneDragExited() {
        tracker.exit()
        publishHighlight()
    }

    func setTextViewAttachmentDragActive(_ isActive: Bool) {
        guard isTextViewAttachmentDragActive != isActive else { return }
        isTextViewAttachmentDragActive = isActive
    }

    /// Capture the destination before loading providers; completion cannot drift to a new tab.
    @discardableResult
    func performPaneDrop(
        currentTabID: UUID?,
        load: (_ completion: @escaping ([AgentAttachmentIntake.Prepared], [AgentAttachmentFailure]) -> Void) -> Bool,
        prepareAttach: (_ tabID: UUID) -> ([AgentAttachmentIntake.Prepared], [AgentAttachmentFailure]) -> Void
    ) -> Bool {
        let accepts = tracker.acceptsAttachments ?? true
        let target = tracker.takeDropTarget(fallbackTabID: currentTabID)
        publishHighlight()
        isTextViewAttachmentDragActive = false
        guard accepts, let target else { return false }
        let attach = prepareAttach(target)
        return load { prepared, failures in
            guard !prepared.isEmpty || !failures.isEmpty else { return }
            attach(prepared, failures)
        }
    }

    static func dragID(for pasteboard: NSPasteboard) -> String {
        "\(pasteboard.name.rawValue):\(pasteboard.changeCount)"
    }

    private func publishHighlight() {
        let highlighted = tracker.isHighlighted
        if isPaneHighlighted != highlighted {
            isPaneHighlighted = highlighted
        }
    }
}

/// Installed once on the pane. The native editor forwards drops here instead of attaching itself.
struct AgentAttachmentPaneDropDelegate: DropDelegate {
    let controller: AgentAttachmentDropController
    let currentTabID: () -> UUID?
    let prepareAttach: (_ tabID: UUID) -> ([URL], [AgentAttachmentFailure]) async -> Void
    var attachmentIntake = AgentAttachmentIntake()

    static let acceptedTypes: [UTType] = [.image, .fileURL]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        controller.paneDragEntered(
            typeIdentifiers: info.itemProviders(for: Self.acceptedTypes).flatMap(\.registeredTypeIdentifiers),
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
        controller.paneDragEntered(typeIdentifiers: providers.flatMap(\.registeredTypeIdentifiers), currentTabID: currentTabID())
        return performDrop(providers: providers)
    }

    func performDrop(providers: [NSItemProvider]) -> Bool {
        performDrop { completion in
            attachmentIntake.loadPreparedAttachments(from: providers, completion: completion)
        }
    }

    func performDrop(pasteboard: NSPasteboard) -> Bool {
        guard AgentAttachmentDropClassifier.accepts(typeIdentifiers: (pasteboard.types ?? []).map(\.rawValue)) else { return false }
        controller.textViewDragEntered(pasteboard: pasteboard, currentTabID: currentTabID())
        return performDrop(providers: attachmentIntake.dropProviders(from: pasteboard))
    }

    private func performDrop(
        load: (_ completion: @escaping ([AgentAttachmentIntake.Prepared], [AgentAttachmentFailure]) -> Void) -> Bool
    ) -> Bool {
        let adapter = attachmentIntake
        let prepareAttach = prepareAttach
        return controller.performPaneDrop(
            currentTabID: currentTabID(),
            load: load,
            prepareAttach: { tabID in
                let attach = prepareAttach(tabID)
                return { prepared, failures in
                    Task { @MainActor in
                        defer { adapter.cleanupTemporaryFiles(prepared) }
                        await attach(prepared.map(\.url), failures)
                    }
                }
            }
        )
    }
}

/// The pane's only drop affordance; it never intercepts mouse or drag hit testing.
struct AgentAttachmentDropOverlay: View {
    @ObservedObject var controller: AgentAttachmentDropController

    var body: some View {
        ZStack {
            if controller.isOverlayVisible {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    Label("Drop files to attach", systemImage: "doc.badge.plus")
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
    @Entry var agentAttachmentDropController: AgentAttachmentDropController? = nil
    @Entry var agentAttachmentDropHandler: ((NSPasteboard) -> Bool)? = nil
}
