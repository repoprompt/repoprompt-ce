import SwiftUI

/// Settings-native management surface for Agent Mode workflow prompts.
///
/// This page is intentionally standalone for now: Settings routing is owned by
/// a follow-up integration change. It manages Agent Mode workflows only and
/// does not reuse or alter Copy/Chat Workflow Presets.
///
/// Related:
/// - Store: `AgentWorkflowStore` in `Services/AgentMode/AgentWorkflowStore.swift`
/// - Model: `AgentWorkflow` / `AgentWorkflowDefinition` in `Models/Agent/AgentWorkflow.swift`
/// - In-flow editor: `AgentWorkflowsConfigureSheet`
///
/// SEARCH-HELPER: Agent Workflows settings, Agent Mode workflows, built-in workflows,
/// featured workflows, custom workflow markdown, workflow prompts, cleanup guidance
struct AgentModeWorkflowsSettingsView: View {
    @ObservedObject var workflowStore: AgentWorkflowStore
    var onNavigate: ((SettingsTab) -> Void)?

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    @State private var showNewWorkflowPrompt = false
    @State private var showCloneWorkflowPrompt = false
    @State private var workflowNameDraft = ""
    @State private var cloneSource: AgentWorkflow?
    @State private var workflowPendingDeletion: AgentWorkflowDefinition?
    @State private var errorMessage: String?

    init(workflowStore: AgentWorkflowStore? = nil, onNavigate: ((SettingsTab) -> Void)? = nil) {
        self.workflowStore = workflowStore ?? AgentWorkflowStore.shared
        self.onNavigate = onNavigate
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection
                promptBehaviorSection
                featuredSection
                builtInSection
                customSection
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .alert("New Custom Workflow", isPresented: $showNewWorkflowPrompt) {
            TextField("Workflow name", text: $workflowNameDraft)
            Button("Create") { createNewWorkflow() }
            Button("Cancel", role: .cancel) { workflowNameDraft = "" }
        } message: {
            Text("Create a markdown workflow in RepoPrompt's Workflows folder. You can edit the file afterwards.")
        }
        .alert("Clone Built-in Workflow", isPresented: $showCloneWorkflowPrompt) {
            TextField("New name", text: $workflowNameDraft)
            Button("Clone") { cloneWorkflow() }
            Button("Cancel", role: .cancel) {
                workflowNameDraft = ""
                cloneSource = nil
            }
        } message: {
            if let cloneSource {
                Text("Clone \"\(cloneSource.displayName)\" as a custom markdown workflow you can edit.")
            }
        }
        .alert("Delete Custom Workflow?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) { deletePendingWorkflow() }
            Button("Cancel", role: .cancel) { workflowPendingDeletion = nil }
        } message: {
            if let workflowPendingDeletion {
                Text("This deletes \"\(workflowPendingDeletion.displayName)\" from the Workflows folder. This can't be undone from RepoPrompt.")
            }
        }
        .alert("Workflow Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Something went wrong while updating workflows.")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent Workflows")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Manage Agent Mode prompt templates, the workflows shown first in Agent Mode, and custom workflow markdown files. These are separate from Copy/Chat Workflow Presets.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptBehaviorSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    icon: "text.append",
                    title: "Prompt Behavior",
                    detail: "Controls text RepoPrompt appends to built-in Agent Mode workflows. Custom workflows and external slash skills aren't affected."
                )

                Toggle(isOn: showBuiltInWorkflowCleanupGuidanceBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include Session Cleanup Guidance")
                            .font(.system(size: 13, weight: .semibold))
                        Text("When on, built-in workflows end with housekeeping instructions that remind the agent to dismiss completed agent sessions. Turn off if that guidance is noisy or conflicts with how you manage sessions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var featuredSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    sectionHeader(
                        icon: "star.fill",
                        title: "Featured Workflows",
                        detail: "Up to \(AgentWorkflowStore.maxFeaturedWorkflowCount) workflows appear first in Agent Mode. The full workflow catalog remains available from the picker."
                    )
                    Spacer(minLength: 12)
                    addFeaturedMenu
                }

                if workflowStore.featuredWorkflows.isEmpty {
                    emptyState("No featured workflows selected. Use Add Featured Workflow to choose workflows for the Agent Mode empty state.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(workflowStore.featuredWorkflows.enumerated()), id: \.element.id) { index, workflow in
                            featuredRow(workflow, index: index)
                            if index < workflowStore.featuredWorkflows.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var builtInSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    icon: "rectangle.stack.fill",
                    title: "Built-in Workflows",
                    detail: "Show, hide, feature, or clone RepoPrompt's built-in Agent Mode workflows. Hiding a built-in workflow also removes it from the featured list."
                )

                VStack(spacing: 0) {
                    ForEach(AgentWorkflow.displayOrder) { workflow in
                        builtInRow(workflow)
                        if workflow.id != AgentWorkflow.displayOrder.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var customSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    sectionHeader(
                        icon: "doc.text.fill",
                        title: "Custom Workflows",
                        detail: "Create markdown workflow prompts here, or add .md files directly to the Workflows folder."
                    )
                    Spacer(minLength: 12)
                    customToolbar
                }

                if workflowStore.customWorkflows.isEmpty {
                    emptyState("No custom workflows yet. Create one here or add markdown files to the Workflows folder.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(workflowStore.customWorkflows.enumerated()), id: \.element.id) { index, workflow in
                            customRow(workflow)
                            if index < workflowStore.customWorkflows.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func featuredRow(_ workflow: AgentWorkflowDefinition, index: Int) -> some View {
        workflowRowLayout(workflow: workflow) {
            Button {
                workflowStore.moveFeaturedWorkflow(withID: workflow.id, direction: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .hoverTooltip("Move earlier")
            .accessibilityLabel("Move earlier")

            Button {
                workflowStore.moveFeaturedWorkflow(withID: workflow.id, direction: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index == workflowStore.featuredWorkflows.count - 1)
            .hoverTooltip("Move later")
            .accessibilityLabel("Move later")

            Button {
                workflowStore.removeFeaturedWorkflow(withID: workflow.id)
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .hoverTooltip("Remove from featured workflows")
        }
    }

    private func builtInRow(_ workflow: AgentWorkflow) -> some View {
        let definition = workflow.definition
        let isHidden = workflowStore.isBuiltInHidden(workflow)

        return workflowRowLayout(workflow: definition, isDimmed: isHidden) {
            Toggle("Visible", isOn: Binding(
                get: { !workflowStore.isBuiltInHidden(workflow) },
                set: { workflowStore.setBuiltInVisibility(workflow, isVisible: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .hoverTooltip(isHidden ? "Show this built-in workflow" : "Hide this built-in workflow")

            featureButton(for: definition, isEnabled: !isHidden)

            Button {
                cloneSource = workflow
                workflowNameDraft = "\(workflow.displayName) (Custom)"
                showCloneWorkflowPrompt = true
            } label: {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            .hoverTooltip("Clone as a custom markdown workflow")
        }
    }

    private func customRow(_ workflow: AgentWorkflowDefinition) -> some View {
        workflowRowLayout(workflow: workflow) {
            featureButton(for: workflow, isEnabled: true)

            Button {
                workflowStore.revealInFinder(workflow)
            } label: {
                Label("Reveal", systemImage: "doc.text.magnifyingglass")
            }
            .hoverTooltip("Reveal in Finder")

            Button(role: .destructive) {
                workflowPendingDeletion = workflow
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .hoverTooltip("Delete custom workflow")
        }
    }

    private func workflowRowLayout(
        workflow: AgentWorkflowDefinition,
        isDimmed: Bool = false,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: workflow.iconName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(workflow.accentColor))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDimmed ? .tertiary : .primary)
                if let description = workflow.descriptionText, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                actions()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 9)
    }

    // MARK: - Controls

    private var addFeaturedMenu: some View {
        Menu {
            ForEach(addableFeaturedWorkflows) { workflow in
                Button {
                    workflowStore.toggleFeatured(workflow)
                } label: {
                    Label(workflow.displayName, systemImage: workflow.iconName)
                }
            }
        } label: {
            Label("Add Featured Workflow", systemImage: "plus")
        }
        .disabled(workflowStore.featuredWorkflowIDs.count >= AgentWorkflowStore.maxFeaturedWorkflowCount || addableFeaturedWorkflows.isEmpty)
        .hoverTooltip(addFeaturedHelpText)
        .accessibilityHint(addFeaturedHelpText)
    }

    private var customToolbar: some View {
        HStack(spacing: 8) {
            Button {
                workflowNameDraft = ""
                showNewWorkflowPrompt = true
            } label: {
                Label("New", systemImage: "plus")
            }

            Button {
                workflowStore.refresh()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }

            Button {
                workflowStore.openInFinder()
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func featureButton(for workflow: AgentWorkflowDefinition, isEnabled: Bool) -> some View {
        let isFeatured = workflowStore.isFeatured(workflow)
        let canFeature = workflowStore.canFeature(workflow)
        let isActionEnabled = isEnabled && (isFeatured || canFeature)

        return Button {
            workflowStore.toggleFeatured(workflow)
        } label: {
            Label(isFeatured ? "Featured" : "Feature", systemImage: isFeatured ? "star.fill" : "star")
        }
        .disabled(!isActionEnabled)
        .hoverTooltip(featureHelpText(isFeatured: isFeatured, canFeature: canFeature, isEnabled: isEnabled))
        .accessibilityHint(featureHelpText(isFeatured: isFeatured, canFeature: canFeature, isEnabled: isEnabled))
    }

    // MARK: - Helpers

    private func settingsCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private func sectionHeader(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private var showBuiltInWorkflowCleanupGuidanceBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.showBuiltInWorkflowCleanupGuidance() },
            set: { globalSettings.setShowBuiltInWorkflowCleanupGuidance($0) }
        )
    }

    private var addableFeaturedWorkflows: [AgentWorkflowDefinition] {
        workflowStore.allWorkflows.filter { !workflowStore.isFeatured($0) }
    }

    private var addFeaturedHelpText: String {
        if workflowStore.featuredWorkflowIDs.count >= AgentWorkflowStore.maxFeaturedWorkflowCount {
            return "Featured workflows are limited to \(AgentWorkflowStore.maxFeaturedWorkflowCount). Remove one before adding another."
        }
        if addableFeaturedWorkflows.isEmpty {
            return "All visible workflows are already featured."
        }
        return "Add a visible built-in or custom workflow to the Agent Mode empty state."
    }

    private func featureHelpText(isFeatured: Bool, canFeature: Bool, isEnabled: Bool) -> String {
        if !isEnabled {
            return "Show this built-in workflow before featuring it."
        }
        if isFeatured {
            return "Remove from featured workflows."
        }
        if canFeature {
            return "Add to featured workflows."
        }
        return "Featured workflows are limited to \(AgentWorkflowStore.maxFeaturedWorkflowCount)."
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { workflowPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    workflowPendingDeletion = nil
                }
            }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    // MARK: - Actions

    private func createNewWorkflow() {
        let name = workflowNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        do {
            _ = try workflowStore.createWorkflow(name: name)
        } catch {
            errorMessage = "Failed to create workflow: \(error.localizedDescription)"
        }
        workflowNameDraft = ""
    }

    private func cloneWorkflow() {
        let name = workflowNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let cloneSource else { return }

        do {
            _ = try workflowStore.cloneBuiltIn(cloneSource, name: name)
        } catch {
            errorMessage = "Failed to clone workflow: \(error.localizedDescription)"
        }
        workflowNameDraft = ""
        self.cloneSource = nil
    }

    private func deletePendingWorkflow() {
        guard let workflow = workflowPendingDeletion else { return }
        do {
            try workflowStore.deleteWorkflow(workflow)
        } catch {
            errorMessage = "Failed to delete workflow: \(error.localizedDescription)"
        }
        workflowPendingDeletion = nil
    }
}
