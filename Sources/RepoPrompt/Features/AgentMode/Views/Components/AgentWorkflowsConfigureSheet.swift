import RepoPromptFileSystem
import SwiftUI

// MARK: - Agent Workflows Configure Sheet

/// Minimal sheet for creating new custom workflows, cloning built-in ones,
/// and managing existing custom workflows. Accessed via the gear button in the workflows popover.
///
/// Related:
/// - Store: `AgentWorkflowStore` in `Services/AgentMode/AgentWorkflowStore.swift`
/// - Pattern reference: `ChatPresetsSettingsView` for clone/create flow
struct AgentWorkflowsConfigureSheet: View {
    @ObservedObject var workflowStore: AgentWorkflowStore
    @Environment(\.dismiss) private var dismiss

    @State private var showNewWorkflowPrompt = false
    @State private var showClonePickerPrompt = false
    @State private var newWorkflowName = ""
    @State private var cloneSource: AgentWorkflow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .alert("New Workflow", isPresented: $showNewWorkflowPrompt) {
            TextField("Workflow name", text: $newWorkflowName)
            Button("Create") { createNewWorkflow() }
            Button("Cancel", role: .cancel) { newWorkflowName = "" }
        } message: {
            Text("Enter a name for your new workflow. You can edit the markdown file afterwards.")
        }
        .alert("Clone Built-in Workflow", isPresented: $showClonePickerPrompt) {
            TextField("New name", text: $newWorkflowName)
            Button("Clone") { cloneWorkflow() }
            Button("Cancel", role: .cancel) { newWorkflowName = ""
                cloneSource = nil
            }
        } message: {
            if let source = cloneSource {
                Text("Clone \"\(source.displayName)\" as a custom workflow you can edit.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Workflow Settings")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                featuredSection
                Divider()

                // Built-in workflows (clone source)
                builtInSection

                if !workflowStore.customWorkflows.isEmpty {
                    Divider()
                    customSection
                }
            }
            .padding(16)
        }
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Featured Workflows")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Text("Up to \(AgentWorkflowStore.maxFeaturedWorkflowCount) workflows appear on the first page. The rest are available by paging forward.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            ForEach(Array(workflowStore.featuredWorkflows.enumerated()), id: \.element.id) { index, workflow in
                HStack(spacing: 8) {
                    Image(systemName: workflow.iconName)
                        .font(.system(size: 12))
                        .foregroundStyle(workflow.accentColor)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(workflow.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let description = workflow.descriptionText, !description.isEmpty {
                            Text(description)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        workflowStore.moveFeaturedWorkflow(withID: workflow.id, direction: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(index == 0 ? .tertiary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .hoverTooltip("Move earlier", .top)

                    Button {
                        workflowStore.moveFeaturedWorkflow(withID: workflow.id, direction: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(index == workflowStore.featuredWorkflows.count - 1 ? .tertiary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == workflowStore.featuredWorkflows.count - 1)
                    .hoverTooltip("Move later", .top)

                    Button {
                        workflowStore.removeFeaturedWorkflow(withID: workflow.id)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip("Remove from first page", .top)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Built-in Workflows")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            ForEach(AgentWorkflow.displayOrder) { workflow in
                let isHidden = workflowStore.isBuiltInHidden(workflow)
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { !workflowStore.isBuiltInHidden(workflow) },
                        set: { workflowStore.setBuiltInVisibility(workflow, isVisible: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()

                    Image(systemName: workflow.iconName)
                        .font(.system(size: 12))
                        .foregroundStyle(isHidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(workflow.accentColor))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workflow.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isHidden ? .tertiary : .primary)
                        Text(workflow.descriptionText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    mainAreaButton(for: workflow.definition)
                    Button {
                        cloneSource = workflow
                        newWorkflowName = "\(workflow.displayName) (Custom)"
                        showClonePickerPrompt = true
                    } label: {
                        Text("Clone")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Custom Workflows")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            ForEach(workflowStore.customWorkflows) { workflow in
                HStack(spacing: 8) {
                    Image(systemName: workflow.iconName)
                        .font(.system(size: 12))
                        .foregroundStyle(workflow.accentColor)
                        .frame(width: 16)
                    Text(workflow.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    mainAreaButton(for: workflow)
                    Button {
                        workflowStore.revealInFinder(workflow)
                    } label: {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip("Show in Finder", .top)

                    Button {
                        try? workflowStore.deleteWorkflow(workflow)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip("Delete workflow", .top)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                newWorkflowName = ""
                showNewWorkflowPrompt = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text("New Workflow")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if !workflowStore.customWorkflows.isEmpty {
                Button {
                    workflowStore.openInFinder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("Open Folder in Finder")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func mainAreaButton(for workflow: AgentWorkflowDefinition) -> some View {
        let isFeatured = workflowStore.isFeatured(workflow)
        let canFeature = workflowStore.canFeature(workflow)

        return Button {
            workflowStore.toggleFeatured(workflow)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isFeatured ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .medium))
                Text(isFeatured ? "Featured" : "Feature")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(
                isFeatured
                    ? AnyShapeStyle(workflow.accentColor)
                    : AnyShapeStyle(canFeature ? .secondary : .tertiary)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canFeature)
        .hoverTooltip(
            isFeatured
                ? "Remove from first page"
                : canFeature
                ? "Add to first page"
                : "First page already has \(AgentWorkflowStore.maxFeaturedWorkflowCount) workflows",
            .top
        )
    }

    // MARK: - Actions

    private func createNewWorkflow() {
        let name = newWorkflowName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let workflow = try workflowStore.createWorkflow(name: name)
            workflowStore.revealInFinder(workflow)
        } catch {
            print("[AgentWorkflowsConfigure] Failed to create workflow: \(error)")
        }
        newWorkflowName = ""
    }

    private func cloneWorkflow() {
        let name = newWorkflowName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let source = cloneSource else { return }
        do {
            let workflow = try workflowStore.cloneBuiltIn(source, name: name)
            workflowStore.revealInFinder(workflow)
        } catch {
            print("[AgentWorkflowsConfigure] Failed to clone workflow: \(error)")
        }
        newWorkflowName = ""
        cloneSource = nil
    }
}
