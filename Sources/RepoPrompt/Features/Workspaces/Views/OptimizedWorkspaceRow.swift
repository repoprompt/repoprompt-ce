import SwiftUI

/// Optimized workspace row that minimizes re-renders
struct OptimizedWorkspaceRow: View {
    let workspace: WorkspaceModel
    let onSwitch: (() -> Void)?
    let onRename: () -> Void
    let onToggleHidden: () -> Void
    let onDelete: () -> Void

    @State private var showingDeleteConfirmation = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workspace.name)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 16, weight: .medium))

                Spacer()

                if let onSwitch {
                    // Switch to workspace
                    Button(action: onSwitch) {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(CustomButtonStyle())
                    .hoverTooltip("Switch to workspace")
                }

                // Rename
                Button(action: onRename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Rename workspace")

                // Hide toggle
                Button(action: onToggleHidden) {
                    Image(systemName: workspace.isHiddenInMenus ? "eye.slash" : "eye")
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip(workspace.isHiddenInMenus ? "Show in workspace menu" : "Hide from workspace menu")

                // Delete
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Delete workspace")
                .popover(isPresented: $showingDeleteConfirmation, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Delete workspace?")
                            .font(fontPreset.headlineFont)
                        Text("This will delete \"\(workspace.name)\" from your workspace list.")
                            .font(fontPreset.subheadlineFont)
                            .foregroundColor(.secondary)
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                showingDeleteConfirmation = false
                            }
                            Button("Delete") {
                                showingDeleteConfirmation = false
                                onDelete()
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding()
                    .frame(width: fontPreset.scaledClamped(280, max: 380))
                }
            }

            // Show folder paths in smaller text
            if !workspace.repoPaths.isEmpty {
                Text("Folders: \(workspace.repoPaths.joined(separator: ", "))")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else {
                Text("No folders yet.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.85))
        )
    }
}
