import SwiftUI

/// Gives a pending question card keyboard focus when its session is activated. Approval cards do
/// not use this: their action is bound to Return, so taking focus could approve by accident.
struct AgentPendingCardFocusModifier: ViewModifier {
    @ObservedObject var store: AgentRunInteractionUIStore
    let tabID: UUID?
    let focusTarget: () -> Void

    @State private var deliveryTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: deliver)
            .onChange(of: store.pendingCardFocusRequest) { _, _ in deliver() }
            // A card of the same kind in the next session reuses this view. The request can change
            // in the same update, so this must not cancel a delivery that was just scheduled.
            .onChange(of: tabID) { _, _ in deliver() }
            .onDisappear { deliveryTask?.cancel() }
    }

    private func deliver() {
        guard let request = store.takePendingCardFocus(tabID: tabID) else { return }
        let generation = store.pendingCardFocusGeneration
        deliveryTask?.cancel()
        deliveryTask = Task { @MainActor in
            // Focus can only move once the view has committed.
            await Task.yield()
            guard !Task.isCancelled, store.pendingCardFocusGeneration == generation, request.mayDeliver() else { return }
            focusTarget()
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
        focusTarget: @escaping () -> Void
    ) -> some View {
        modifier(AgentPendingCardFocusModifier(store: store, tabID: tabID, focusTarget: focusTarget))
    }
}
