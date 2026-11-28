import AppKit
import SwiftUI

/// The 8 pt workspace-colour dot shown before a workspace name (workspace picker rows, Manage
/// Workspaces recovery-copy rows). The hairline keeps pale colours legible on light backgrounds.
struct WorkspaceColorDot: View {
    let color: WorkspaceColor

    var body: some View {
        Circle()
            .fill(color.color)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .frame(width: 8, height: 8)
            .accessibilityElement()
            .accessibilityLabel(color.accessibilityLabel)
    }
}

/// The `Workspace Color` context-menu section on Manage Workspaces rows: None plus the fixed
/// palette, with a native checkmark on the current choice.
struct WorkspaceColorMenuSection: View {
    let selection: WorkspaceColor?
    let onSelect: (WorkspaceColor?) -> Void

    var body: some View {
        Section("Workspace Color") {
            Picker(
                "Workspace Color",
                selection: Binding(get: { selection }, set: { onSelect($0) })
            ) {
                Text("None").tag(WorkspaceColor?.none)
                ForEach(WorkspaceColor.allCases) { color in
                    Label {
                        Text(color.displayName)
                    } icon: {
                        Image(nsImage: color.menuSwatchImage)
                    }
                    .labelStyle(.titleAndIcon)
                    .tag(WorkspaceColor?.some(color))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

extension View {
    /// Attaches the `Workspace Color` context menu only when `onSelect` is provided, so surfaces
    /// that cannot be coloured (System, recovery copies) keep their default right-click.
    @ViewBuilder
    func workspaceColorContextMenu(
        selection: WorkspaceColor?,
        onSelect: ((WorkspaceColor?) -> Void)?
    ) -> some View {
        if let onSelect {
            contextMenu {
                WorkspaceColorMenuSection(selection: selection, onSelect: onSelect)
            }
        } else {
            self
        }
    }
}
