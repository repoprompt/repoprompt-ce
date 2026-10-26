import RepoPromptFileSystem

//
//  WorkspaceSetupView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-01-19.
//

import SwiftUI

struct WorkspaceSetupView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManagerViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    let onClose: () -> Void
    let onWorkspaceCreated: (WorkspaceModel) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Configure Workspace")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 20, weight: .semibold))
                .padding(.top, 8)

            // Bind directly to the manager’s creationDraft name
            TextField("Workspace Name", text: $workspaceManager.creationDraft.name)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)

            // Show the selected repo paths from the manager’s creationDraft
            List {
                ForEach(workspaceManager.creationDraft.selectedRepoPaths, id: \.self) { path in
                    Text(path)
                }
                .onDelete { indexSet in
                    workspaceManager.creationDraft.selectedRepoPaths.remove(atOffsets: indexSet)
                }
            }
            .frame(height: fontPreset.scaledMetric(120))

            Button("Add Folder(s)") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true

                if panel.runModal() == .OK {
                    for url in panel.urls {
                        let stdURL = url.standardizedFileURL
                        workspaceManager.creationDraft.selectedRepoPaths.append(stdURL.path)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    // If you want, reset the draft so there's no leftover state
                    workspaceManager.creationDraft = WorkspaceManagerViewModel.WorkspaceCreationDraft()
                    onClose()
                }
                Button("Create") {
                    if let newWS = workspaceManager.createWorkspaceFromDraft() {
                        onWorkspaceCreated(newWS)
                    } else {
                        print("Invalid workspace name or other error.")
                    }
                }
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: fontPreset.scaledMetric(400), height: fontPreset.scaledMetric(400))
    }
}
