import SwiftUI

/// Gives a pending question or approval card keyboard focus when its session is activated.
///
/// The card is focusable only while it holds requested focus, so it adds no Tab stop and no
/// click-to-focus at any other time. Cards with a better target inside them pass `focusTarget`.
struct AgentPendingCardFocusModifier: ViewModifier {
    @ObservedObject var store: AgentRunInteractionUIStore
    let tabID: UUID?
    var focusTarget: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var isArmed = false
    @State private var deliveryTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .focusable(isArmed)
            .focusEffectDisabled()
            .focused($isFocused)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onAppear(perform: deliver)
            .onChange(of: store.pendingCardFocusRequest) { _, _ in deliver() }
            // A card of the same kind in the next session reuses this view.
            .onChange(of: tabID) { _, _ in
                deliveryTask?.cancel()
                deliver()
            }
            .onDisappear { deliveryTask?.cancel() }
            .onChange(of: isFocused) { _, focused in
                if !focused { isArmed = false }
            }
    }

    private func deliver() {
        guard let request = store.takePendingCardFocus(tabID: tabID) else { return }
        let generation = store.pendingCardFocusGeneration
        if focusTarget == nil { isArmed = true }
        deliveryTask?.cancel()
        deliveryTask = Task { @MainActor in
            // Focus can only move once the armed view has committed.
            await Task.yield()
            guard !Task.isCancelled, store.pendingCardFocusGeneration == generation, request.mayDeliver() else {
                isArmed = isFocused
                return
            }
            if let focusTarget {
                focusTarget()
            } else {
                isFocused = true
            }
        }
    }
}

extension AgentRunInteractionUIStore {
    /// For cards shown where no session can request focus, such as Context Builder.
    static let inertFocusSource = AgentRunInteractionUIStore()
}

extension View {
    func agentPendingCardFocus(
        store: AgentRunInteractionUIStore,
        tabID: UUID?,
        focusTarget: (() -> Void)? = nil
    ) -> some View {
        modifier(AgentPendingCardFocusModifier(store: store, tabID: tabID, focusTarget: focusTarget))
    }
}
