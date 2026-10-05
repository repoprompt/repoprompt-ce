import RepoPromptFileSystem

//
//  AIQueryBasicSettingsView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-04.
//

import SwiftUI

struct AIQueryBasicSettingsView: View {
    @ObservedObject var promptViewModel: PromptViewModel
    @State private var isTemperatureExpanded: Bool = false

    // Access the font preset size

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Query Settings").font(.headline)

            Text("File Edit Format")
                .font(.body)
            Picker("", selection: $promptViewModel.fileEditFormat) {
                ForEach(PromptViewModel.FileEditFormat.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()
            .disabled(!promptViewModel.preferredAIModel.isModelCapableOfDiff)

            Text(explanationText)
                .font(.caption)
                .foregroundColor(.secondary)

            DisclosureGroup(
                isExpanded: $isTemperatureExpanded,
                content: {
                    HStack {
                        Text("Temperature: ").font(.subheadline)
                        Text(String(format: "%.2f", promptViewModel.modelTemperature)).font(.caption)
                        Spacer()
                    }
                    .padding(.top, 4)

                    Slider(value: $promptViewModel.modelTemperature, in: 0 ... 1, step: 0.1)
                    Text("Lower values (closer to 0) make outputs more focused and deterministic. Higher values (closer to 1) make outputs more random and creative.").font(.caption)
                },
                label: {
                    Text("Model Config").font(.headline)
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    isTemperatureExpanded.toggle()
                }
            }
        }
        .onChange(of: promptViewModel.preferredAIModel) { _, _ in
            if !promptViewModel.preferredAIModel.isModelCapableOfDiff {
                promptViewModel.fileEditFormat = .whole
            }
        }
    }

    private var explanationText: String {
        if !promptViewModel.preferredAIModel.isModelCapableOfDiff, promptViewModel.fileEditFormat == .diff {
            return "This model does not support diff editing. It will use whole file editing instead."
        }

        switch promptViewModel.fileEditFormat {
        case .none:
            return "Unconstrained AI chat, but you cannot directly edit files."
        case .diff:
            return "In diff mode, the AI will attempt to output only the changes needed."
        case .whole:
            return "In whole mode, the AI will rewrite the entire file."
        }
    }
}
