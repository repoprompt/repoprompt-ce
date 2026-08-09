import Foundation
import SwiftUI

/// Decouples "what model was picked" from "where/how that choice is applied".
/// Each destination encapsulates:
/// - How to get the current model raw value
/// - How to apply a new model selection (including any side effects like notifications)
@MainActor
struct ModelDestination: Identifiable {
    let id: String
    let allowsEmptySelection: Bool
    private let getter: @MainActor () -> String
    private let applier: @MainActor (String) -> Void

    init(
        id: String,
        allowsEmptySelection: Bool = false,
        getter: @escaping @MainActor () -> String,
        applier: @escaping @MainActor (String) -> Void
    ) {
        self.id = id
        self.allowsEmptySelection = allowsEmptySelection
        self.getter = getter
        self.applier = applier
    }

    /// The current model raw value for this destination
    var currentRawValue: String {
        getter()
    }

    /// Apply a new model selection to this destination
    func apply(_ rawValue: String) {
        applier(rawValue)
    }
}

// MARK: - Binding-backed Destination

extension ModelDestination {
    /// Creates a destination backed by a simple binding (no side effects)
    static func binding(_ binding: Binding<String>, id: String) -> ModelDestination {
        ModelDestination(
            id: id,
            getter: { binding.wrappedValue },
            applier: { binding.wrappedValue = $0 }
        )
    }
}

// MARK: - PromptViewModel-backed Destinations

extension ModelDestination {
    /// Destination for the main chat model (preferredModel).
    /// PromptViewModel enforces Oracle/Built-in Chat sync when the global toggle is enabled.
    static func chatModel(promptVM: PromptViewModel) -> ModelDestination {
        ModelDestination(
            id: "chatModel",
            getter: { promptVM.preferredModel },
            applier: { promptVM.preferredModel = $0 }
        )
    }

    /// Destination for the context builder model
    static func contextBuilderModel(promptVM: PromptViewModel) -> ModelDestination {
        ModelDestination(
            id: "contextBuilderModel",
            getter: { promptVM.contextBuilderModelName },
            applier: { promptVM.contextBuilderModelName = $0 }
        )
    }

    /// Destination for the MCP default model (planningModel).
    /// PromptViewModel enforces Oracle/Built-in Chat sync when the global toggle is enabled.
    /// This model is used for all MCP chat connections: ask_oracle/oracle_send and context_builder plan/review/question.
    /// - Parameter postNotification: Whether to post `.recommendationsShouldRefresh` after applying (default: true)
    ///   Note: We use `.recommendationsShouldRefresh` (not `.recommendationsDidApply`) because a user manually
    ///   picking a model is semantically different from the recommendation engine applying changes.
    ///   This triggers the wizard to recompute without side effects like discarding window overlays.
    static func planningModel(promptVM: PromptViewModel, postNotification: Bool = true) -> ModelDestination {
        ModelDestination(
            id: "planningModel",
            getter: { promptVM.planningModelName },
            applier: { rawValue in
                promptVM.planningModelName = rawValue

                if postNotification {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .recommendationsShouldRefresh,
                            object: nil
                        )
                    }
                }
            }
        )
    }
}
