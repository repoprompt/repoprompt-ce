import Combine
import SwiftUI

// MARK: - Recommendation Toolbar Button View

private struct RecommendationToolbarState: Equatable {
    let hasActiveRecommendations: Bool
}

@MainActor
private final class RecommendationToolbarStateObserver: ObservableObject {
    @Published private(set) var state: RecommendationToolbarState

    private var cancellables = Set<AnyCancellable>()

    init(viewModel: RecommendationWizardViewModel) {
        state = RecommendationToolbarState(hasActiveRecommendations: viewModel.hasActiveRecommendations)

        viewModel.$hasActiveRecommendations
            .removeDuplicates()
            .map(RecommendationToolbarState.init(hasActiveRecommendations:))
            .sink { [weak self] in self?.state = $0 }
            .store(in: &cancellables)
    }
}

/// Toolbar button that opens the recommendation wizard popover.
@MainActor
struct RecommendationToolbarButtonView: View {
    let viewModel: RecommendationWizardViewModel
    @Binding var showPopover: Bool
    @StateObject private var toolbarStateObserver: RecommendationToolbarStateObserver

    init(viewModel: RecommendationWizardViewModel, showPopover: Binding<Bool>) {
        self.viewModel = viewModel
        _showPopover = showPopover
        _toolbarStateObserver = StateObject(wrappedValue: RecommendationToolbarStateObserver(viewModel: viewModel))
    }

    var body: some View {
        Button(action: {
            if !showPopover {
                viewModel.refresh()
            }
            showPopover.toggle()
        }) {
            Label("Setup Wizard", systemImage: "lightbulb")
                .labelStyle(.iconOnly)
                .imageScale(.medium)
                .foregroundColor(toolbarStateObserver.state.hasActiveRecommendations ? .yellow : .secondary)
        }
        .hoverTooltip("Setup Wizard", .bottom)
        .popover(isPresented: $showPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            RecommendationWizardPopoverView(
                viewModel: viewModel,
                onDismiss: {
                    if viewModel.currentStep == .summary || !viewModel.hasActiveRecommendations {
                        viewModel.markCompleted()
                    }
                    showPopover = false
                }
            )
            .frame(width: 480)
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct RecommendationToolbarButtonView_Previews: PreviewProvider {
        static var previews: some View {
            Text("RecommendationToolbarButtonView")
                .padding()
        }
    }
#endif
