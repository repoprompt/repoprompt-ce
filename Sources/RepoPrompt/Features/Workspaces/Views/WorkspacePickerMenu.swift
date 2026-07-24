import SwiftUI

/// Compact, font‑scale aware workspace picker.
///
/// Visual goal: keep the popover as close to a native AppKit menu as possible
/// while still respecting the user's `ui.font_scale` preset (regular `Menu`
/// items don't honor our app font scale, which is why this is a custom popover
/// rather than `Menu { … }`). Metrics are clamped aggressively so the popover
/// stays compact even at the largest preset.
///
/// SEARCH-HELPER: Workspace Picker, workspace switcher, switch workspace menu
struct WorkspacePickerMenu<Label: View>: View {
    @ObservedObject var workspaceManager: WorkspaceManagerViewModel
    var query: WorkspaceMenuQuery = .init()
    var includeSaveActions: Bool = false
    var includeExitAction: Bool = false
    var onCreateWorkspace: (() -> Void)?
    var onManageWorkspaces: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var isPresented = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    /// Popover metrics. Keep this close to the native workflow popover: enough
    /// breathing room for scaled fonts, but still compact for a picker menu.
    private var menuMinWidth: CGFloat {
        fontPreset.scaledClamped(200, max: 280)
    }

    private var menuIdealWidth: CGFloat {
        fontPreset.scaledClamped(220, max: 300)
    }

    private var menuMaxHeight: CGFloat {
        fontPreset.scaledClamped(300, max: 440)
    }

    private var rowMinHeight: CGFloat {
        fontPreset.scaledClamped(26, min: 26, max: 36)
    }

    private var rowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var rowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 7)
    }

    private var itemSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 4)
    }

    private var menuPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var dividerPadding: CGFloat {
        fontPreset.scaledClamped(5, max: 8)
    }

    private var cornerRadius: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    private var checkmarkColumnWidth: CGFloat {
        fontPreset.scaledClamped(16, max: 22)
    }

    private var rowSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            label()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            menuContent
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceList

            divider

            if let onCreateWorkspace {
                menuRow(title: "Create Workspace…", isSelected: false, isDisabled: false) {
                    isPresented = false
                    onCreateWorkspace()
                }
            }

            menuRow(title: "Manage Workspaces…", isSelected: false, isDisabled: false) {
                isPresented = false
                onManageWorkspaces()
            }

            if includeSaveActions,
               let current = workspaceManager.activeWorkspace,
               !current.isSystemWorkspace
            {
                divider
                menuRow(title: "Save Workspace (⌘S)", isSelected: false, isDisabled: false) {
                    isPresented = false
                    workspaceManager.pollAndSaveState()
                }
                menuRow(title: "Save & Exit Workspace (⇧⌘S)", isSelected: false, isDisabled: false) {
                    isPresented = false
                    Task { await workspaceManager.saveAndExitToFallback() }
                }
            } else if includeExitAction,
                      let current = workspaceManager.activeWorkspace,
                      !current.isSystemWorkspace
            {
                divider
                menuRow(title: "Exit Workspace", isSelected: false, isDisabled: false) {
                    isPresented = false
                    Task { await workspaceManager.saveAndExitToFallback() }
                }
            }
        }
        .padding(menuPadding)
        .frame(minWidth: menuMinWidth, idealWidth: menuIdealWidth, maxWidth: menuIdealWidth)
    }

    private var divider: some View {
        Divider().padding(.vertical, dividerPadding)
    }

    @ViewBuilder
    private var workspaceList: some View {
        let items = workspaceManager.workspacesForMenu(query)

        if items.isEmpty {
            menuRow(title: "(No Workspaces)", isSelected: false, isDisabled: true) {}
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: itemSpacing) {
                    ForEach(items) { ws in
                        let isSelected = ws.id == workspaceManager.activeWorkspaceID
                        menuRow(
                            title: ws.name,
                            isSelected: isSelected,
                            isDisabled: isSelected
                        ) {
                            isPresented = false
                            Task {
                                _ = await workspaceManager.requestWorkspaceSwitch(to: ws)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: menuMaxHeight)
            .scrollIndicators(.automatic)
        }
    }

    private func menuRow(
        title: String,
        isSelected: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: rowSpacing) {
                ZStack(alignment: .center) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(width: checkmarkColumnWidth)

                Text(title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isDisabled && !isSelected ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, rowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
