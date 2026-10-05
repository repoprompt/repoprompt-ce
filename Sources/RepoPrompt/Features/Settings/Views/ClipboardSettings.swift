import RepoPromptFileSystem

// File: RepoPrompt/Views/Settings/ClipboardSettings.swift

import SwiftUI

struct ClipboardSettingsView: View {
    @ObservedObject var promptViewModel: PromptViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Clipboard Settings").font(.headline)
                Text("Hotkey ⌘ + ⇧ + c to copy").font(.caption)
            }

            Toggle("Include Saved Prompts", isOn: $promptViewModel.includeSavedPromptsInClipboard)
            Toggle("Include Files", isOn: $promptViewModel.includeFilesInClipboard)
            Toggle("Include User Instructions", isOn: $promptViewModel.includeUserPromptInClipboard)
        }
        .padding()
        .frame(width: 224)
    }
}
