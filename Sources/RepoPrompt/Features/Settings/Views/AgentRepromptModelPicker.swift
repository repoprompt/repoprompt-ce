import RepoPromptSettingsCore
import SwiftUI

/// The stored default remains nil, but its presentation is always the concrete resolved model.
struct AgentRepromptModelPicker: View {
    @Binding var selection: String
    let availableModels: [AIModel]
    let resolvedModel: AIModel?

    var concreteSelection: Binding<String> {
        Binding(
            get: {
                resolvedModel?.rawValue ?? "Choose a model"
            },
            set: { selection = $0 }
        )
    }

    var body: some View {
        OptimizedModelPicker(selection: concreteSelection, availableModels: availableModels, font: .body, widthStyle: .flexible())
            .accessibilityLabel("Re-prompt model")
    }
}
