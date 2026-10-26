import RepoPromptInstrumentation
import SwiftUI

// MARK: - Workflow Pill

/// Pill for selecting a workflow template that wraps user input before sending.
/// Collapsed: shows current selection or generic "Workflow" label.
/// Clicking opens a popover with workflow options (two-pane when custom workflows exist).
struct AgentWorkflowPill: View {
    @Environment(\.agentModePerfRecorder) private var perfRecorder
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    @ObservedObject var workflowStore: AgentWorkflowStore = .shared
    let windowID: Int
    let selectWorkflow: (AgentWorkflowDefinition?) -> Void
    @State private var showPopover = false
    @State private var showConfigureSheet = false

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var selection: AgentWorkflowDefinition? {
        statusPillsUI.snapshot.selectedWorkflow
    }

    var body: some View {
        #if DEBUG
            let _ = perfRecorder.increment("ui.body.statusPills.workflow")
        #endif
        let cornerRadius = AgentPillMetrics.cornerRadius()
        let height = AgentPillMetrics.height()
        let horizontalPadding = AgentPillMetrics.horizontalPadding()
        // Trailing padding shrinks when the close (×) button is shown so the
        // pill keeps its overall length proportional at every font scale.
        let trailingPaddingForCloseButton = ButtonScale.metric(4)
        let closeButtonSize = ButtonScale.metric(16)
        let closeButtonTrailing = ButtonScale.metric(6)
        HStack(spacing: 0) {
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    if let selected = selection {
                        Image(systemName: selected.iconName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        Text(selected.displayName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        Text("Workflow")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    }
                    Image(systemName: "chevron.down")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                }
                .foregroundStyle(selection != nil ? AnyShapeStyle(selection!.accentColor) : AnyShapeStyle(.secondary))
                .padding(.leading, horizontalPadding)
                .padding(.trailing, selection != nil ? trailingPaddingForCloseButton : horizontalPadding)
                .frame(height: height)
            }
            .buttonStyle(.plain)

            if selection != nil {
                Button {
                    selectWorkflow(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: closeButtonSize, height: closeButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, closeButtonTrailing)
                .hoverTooltip("Clear workflow", .top)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    selection != nil
                        ? selection!.accentColor.opacity(0.4)
                        : Color.secondary.opacity(0.15),
                    lineWidth: selection != nil ? 1 : 0.5
                )
        )
        .hoverTooltip("Wrap your message with a workflow template", .top)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            AgentWorkflowsPopoverView(
                statusPillsUI: statusPillsUI,
                workflowStore: workflowStore,
                isPresented: $showPopover,
                showConfigureSheet: $showConfigureSheet,
                selectWorkflow: selectWorkflow
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentWorkflowPopover)) { note in
            guard let targetWindowID = note.userInfo?["windowID"] as? Int,
                  targetWindowID == windowID else { return }
            showPopover = true
        }
        .sheet(isPresented: $showConfigureSheet) {
            AgentWorkflowsConfigureSheet(workflowStore: workflowStore)
        }
    }
}
