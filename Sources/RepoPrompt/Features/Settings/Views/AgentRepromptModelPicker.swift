import SwiftUI

struct AgentRepromptModelPicker: View {
    @Binding var selection: String
    let availableModels: [AIModel]

    private var label: String {
        if selection.isEmpty { return "Automatic" }
        if selection == AgentRepromptModelPolicy.primaryOracle { return "Use primary Oracle" }
        return AIModel.fromModelName(selection)?.displayName ?? "Unavailable: \(selection)"
    }

    var body: some View {
        Menu {
            Button("Automatic — prefer connected subscriptions") { selection = "" }
            Button("Use primary Oracle") { selection = AgentRepromptModelPolicy.primaryOracle }
            Divider()
            OptimizedModelPicker(selection: $selection, availableModels: availableModels, font: .body, widthStyle: .flexible())
        } label: { Text("Re-prompt model: \(label)") }
            .accessibilityLabel("Re-prompt model")
    }
}
