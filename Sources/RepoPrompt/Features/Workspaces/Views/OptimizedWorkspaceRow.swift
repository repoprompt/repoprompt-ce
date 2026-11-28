import SwiftUI

/// Optimized workspace row that minimizes re-renders
struct OptimizedWorkspaceRow: View {
    let workspace: WorkspaceModel
    let onSwitch: (() -> Void)?
    let onRename: () -> Void
    let onToggleHidden: () -> Void
    let onDelete: () -> Void
    /// Sets the workspace colour from the row's sticker and context menu; nil shows only the dot
    /// and offers no menu.
    let onSetColor: ((WorkspaceColor?) -> Void)?

    @State private var showingDeleteConfirmation = false
    @State private var showingColorPicker = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    if let onSetColor {
                        colorSticker(onSetColor: onSetColor)
                    } else if let color = workspace.workspaceColor {
                        WorkspaceColorDot(color: color)
                    }
                    Text(workspace.name)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 16, weight: .medium))
                }

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
                        Text("This will delete \"\(workspace.name)\" and its saved tabs and session history, including pinned tabs. Running work will be stopped and affected windows will return to the welcome screen. Your project folders are kept.")
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
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .workspaceColorContextMenu(selection: workspace.workspaceColor, onSelect: onSetColor)
    }

    /// The workspace sticker at row size; a click opens the same swatch picker as the titlebar.
    private func colorSticker(onSetColor: @escaping (WorkspaceColor?) -> Void) -> some View {
        Button {
            showingColorPicker.toggle()
        } label: {
            WorkspaceSticker(color: workspace.workspaceColor, size: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip("Workspace Color")
        .accessibilityLabel("Workspace Color")
        .accessibilityValue(workspace.workspaceColor?.accessibilityLabel ?? "None")
        .popover(isPresented: $showingColorPicker, arrowEdge: .bottom) {
            WorkspaceColorSwatchPicker(selection: workspace.workspaceColor, onSelect: onSetColor)
        }
    }
}
