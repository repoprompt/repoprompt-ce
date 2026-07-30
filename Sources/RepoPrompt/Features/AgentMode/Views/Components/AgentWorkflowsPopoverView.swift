import SwiftUI

// MARK: - Agent Workflows Popover

/// Single-pane popover for selecting agent workflows.
/// Shows built-in workflows, plus a "Custom" section when custom workflows exist.
/// Includes a configure button for creating/cloning workflows and a Finder shortcut.
///
/// Related:
/// - Model: `AgentWorkflowDefinition` in `Models/Agent/AgentWorkflow.swift`
/// - Store: `AgentWorkflowStore` in `Services/AgentMode/AgentWorkflowStore.swift`
struct AgentWorkflowsPopoverView: View {
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    @ObservedObject var workflowStore: AgentWorkflowStore
    @Binding var isPresented: Bool

    @Binding var showConfigureSheet: Bool
    let selectWorkflow: (AgentWorkflowDefinition?) -> Void
    @State private var showHiddenBuiltIns = false

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private enum Layout {
        // Baseline (Normal preset) sizes; scaled by `fontPreset` so the popover
        // grows with the rest of the composer chrome instead of clipping the
        // workflow descriptions when the user picks Larger / Extra Large.
        static let baseWidth: CGFloat = 340
        static let baseHeight: CGFloat = 415
    }

    private var popoverWidth: CGFloat {
        // Width caps a touch above the natural Extra Large value so the popover
        // stays compact relative to the composer pill that anchors it.
        fontPreset.scaledClamped(Layout.baseWidth, max: 460)
    }

    private var popoverHeight: CGFloat {
        fontPreset.scaledClamped(Layout.baseHeight, max: 560)
    }

    /// Inner spacing/padding metrics scale with the preset so rows do not hug
    /// the popover edges at Larger/Extra Large.
    private var sectionContentPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var rowVerticalSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var rowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var rowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    private var rowGroupSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var rowCornerRadius: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var titleDescriptionSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var rowIconTopPadding: CGFloat {
        fontPreset.scaledClamped(1, max: 2)
    }

    private var hiddenChevronSpacing: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    private var hiddenChevronVerticalPadding: CGFloat {
        fontPreset.scaledClamped(3, max: 5)
    }

    private var customSectionTopPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    private var sectionHeaderVerticalPadding: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var clearButtonSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    private var footerSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    private var footerInnerSpacing: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    private var footerControlHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var footerControlVerticalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    private var selection: AgentWorkflowDefinition? {
        statusPillsUI.snapshot.selectedWorkflow
    }

    private var builtInSections: AgentWorkflow.BuiltInSections {
        AgentWorkflow.builtInSections(hiddenBuiltInIDs: workflowStore.hiddenBuiltInIDs)
    }

    private var visibleBuiltIns: [AgentWorkflowDefinition] {
        builtInSections.visibleBuiltIns
    }

    private var hiddenBuiltIns: [AgentWorkflowDefinition] {
        builtInSections.hiddenBuiltIns
    }

    private var hasCustom: Bool {
        !workflowStore.customWorkflows.isEmpty
    }

    private var hasHidden: Bool {
        !hiddenBuiltIns.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: rowVerticalSpacing) {
                    workflowSections
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(sectionContentPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            VStack(alignment: .leading, spacing: rowVerticalSpacing) {
                if selection != nil {
                    clearButton
                    Divider().padding(.vertical, 2)
                }

                footerRow
            }
            .padding(sectionContentPadding)
        }
        .frame(width: popoverWidth, height: popoverHeight)
        .onChange(of: hasHidden) { _, hasHidden in
            if !hasHidden {
                showHiddenBuiltIns = false
            }
        }
    }

    @ViewBuilder
    private var workflowSections: some View {
        // Built-in section
        if hasCustom || hasHidden {
            sectionHeader("Built-in")
        }

        ForEach(visibleBuiltIns) { workflow in
            workflowRow(workflow)
        }

        // Hidden built-ins (collapsed by default)
        if hasHidden {
            Button {
                showHiddenBuiltIns.toggle()
            } label: {
                HStack(spacing: hiddenChevronSpacing) {
                    Image(systemName: showHiddenBuiltIns ? "chevron.down" : "chevron.right")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .medium))
                    Text("\(hiddenBuiltIns.count) hidden")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, rowHorizontalPadding)
                .padding(.vertical, hiddenChevronVerticalPadding)
            }
            .buttonStyle(.plain)

            if showHiddenBuiltIns {
                ForEach(hiddenBuiltIns) { workflow in
                    workflowRow(workflow, dimmed: true)
                }
            }
        }

        // Custom section
        if hasCustom {
            sectionHeader("Custom")
                .padding(.top, customSectionTopPadding)

            ForEach(workflowStore.customWorkflows) { workflow in
                workflowRow(workflow)
            }
        }
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, sectionHeaderVerticalPadding)
    }

    // MARK: - Workflow row

    private func workflowRow(_ workflow: AgentWorkflowDefinition, dimmed: Bool = false) -> some View {
        let isSelected = selection?.id == workflow.id
        let iconColumnWidth = fontPreset.scaledClamped(16, max: 22)
        return Button {
            if dimmed {
                return
            } // hidden rows can't be selected; unhide first
            if isSelected {
                selectWorkflow(nil)
            } else {
                selectWorkflow(workflow)
            }
            isPresented = false
        } label: {
            HStack(alignment: .top, spacing: rowGroupSpacing) {
                Image(systemName: workflow.iconName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(workflow.accentColor))
                    .frame(width: iconColumnWidth)
                    .padding(.top, rowIconTopPadding)
                VStack(alignment: .leading, spacing: titleDescriptionSpacing) {
                    Text(workflow.displayName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                        .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(workflow.accentColor))
                    if let desc = workflow.descriptionText {
                        Text(desc)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundStyle(dimmed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .foregroundStyle(workflow.accentColor)
                        .padding(.top, rowIconTopPadding)
                }
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, rowVerticalPadding)
            .background(isSelected ? workflow.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let builtIn = workflow.builtInWorkflow {
                Button {
                    workflowStore.toggleBuiltInVisibility(builtIn)
                } label: {
                    Label(
                        dimmed ? "Show Workflow" : "Hide from All Pages",
                        systemImage: dimmed ? "eye" : "eye.slash"
                    )
                }
            }
        }
    }

    // MARK: - Clear button

    private var clearButton: some View {
        Button {
            selectWorkflow(nil)
            isPresented = false
        } label: {
            HStack(spacing: clearButtonSpacing) {
                Image(systemName: "xmark")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Clear")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer (configure + Finder)

    private var footerRow: some View {
        HStack(spacing: footerSpacing) {
            Button {
                showConfigureSheet = true
            } label: {
                HStack(spacing: footerInnerSpacing) {
                    Image(systemName: "gearshape")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    Text("Configure…")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, footerControlHorizontalPadding)
                .padding(.vertical, footerControlVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                workflowStore.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, footerControlHorizontalPadding)
                    .padding(.vertical, footerControlVerticalPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTooltip("Reload workflows from disk", .top)

            if hasCustom {
                Button {
                    workflowStore.openInFinder()
                } label: {
                    Image(systemName: "folder")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, footerControlHorizontalPadding)
                        .padding(.vertical, footerControlVerticalPadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTooltip("Open Workflows folder in Finder", .top)
            }
        }
    }
}
