import AppKit
import SwiftUI

/// Settings view for Context Builder configuration.
///
/// Agent/model choice is owned by the Agent Models page and is intentionally
/// absent here to avoid the "which picker wins?" duplication. This page keeps
/// Context Builder-specific knobs: shared token budgets, prompt enhancement,
/// question timeout, UI-run-only toggles (clarifying questions, follow-up
/// analysis, custom prompts), and the MCP-run-only clarifying-questions
/// toggle.
///
/// SEARCH-HELPER: Context Builder, token budget, enhancement mode, question
/// timeout, clarifying questions, follow-up analysis, custom prompts
///
/// Related:
/// - Agent Models (owns CB agent/model): /RepoPrompt/Views/Settings/AgentModelsSettingsView.swift
/// - Agent Mode Overview summary:        /RepoPrompt/Views/Settings/AgentModeGeneralSettingsView.swift
/// - Context Builder VM:                        /RepoPrompt/Features/ContextBuilder/ViewModels/ContextBuilderAgentViewModel.swift
/// - Plan:                               /docs/plans/settings-ui-agent-mode-progressive-disclosure-plan-2026-04-17.md
struct ContextBuilderSettingsView: View {
    @ObservedObject var contextBuilderVM: ContextBuilderAgentViewModel
    @ObservedObject var promptVM: PromptViewModel
    @ObservedObject var apiSettingsVM: APISettingsViewModel
    let windowID: Int
    var onNavigate: ((SettingsTab) -> Void)?

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var showPromptsOverlay = false
    @State private var selectedPromptIDsForSettings: Set<UUID> = [] // Dummy binding for settings view
    @ObservedObject private var promptStorage = ContextBuilderPromptStorage.shared

    var body: some View {
        List {
            overviewSection
            sharedSettingsSection
            uiRunsSection
            mcpRunsSection
        }
    }

    // MARK: - Overview / Agent Models handoff

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Context Builder explores your codebase and generates an optimized prompt. It can be invoked from the UI or via the MCP tool.")
                    .font(fontPreset.font)
                    .foregroundColor(.secondary)

                agentModelsLinkRow
            }
        } header: {
            Text("About")
                .font(fontPreset.headlineFont)
        }
    }

    private var agentModelsLinkRow: some View {
        Button {
            onNavigate?(.agentModels)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "brain")
                    .font(.callout)
                    .frame(width: 18, alignment: .center)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context Builder Agent")
                        .font(fontPreset.font).bold()
                        .foregroundColor(.primary)
                    Text("Currently: \(promptVM.contextBuilderAgent.displayName) · \(promptVM.contextBuilderAgentModelDisplayName). Configure which CLI agent and model Context Builder uses in Agent Models.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onNavigate == nil)
    }

    // MARK: - Shared Settings (Token Budgets & Enhancement Mode)

    private var sharedSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Context Budget")
                            .font(fontPreset.font)
                        Spacer()
                        Text("\(contextBuilderVM.contextTokenBudget / 1000)k")
                            .font(fontPreset.font)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(contextBuilderVM.contextTokenBudget) },
                            set: { contextBuilderVM.contextTokenBudget = Int($0) }
                        ),
                        in: 10000 ... 200_000,
                        step: 5000
                    )
                    Text("Sets the target size of the context package. Use ~160k for ChatGPT/web exports by default, or lower for a more token-efficient prompt.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Analysis Budget")
                            .font(fontPreset.font)
                        Spacer()
                        Text("\(contextBuilderVM.analysisTokenBudget / 1000)k")
                            .font(fontPreset.font)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(contextBuilderVM.analysisTokenBudget) },
                            set: { contextBuilderVM.analysisTokenBudget = Int($0) }
                        ),
                        in: 40000 ... 200_000,
                        step: 5000
                    )
                    Text("Sets the target size of the context package when Context Builder will immediately produce a plan, review, or answer.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Enhancement Mode
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt Enhancement")
                        .font(fontPreset.font)
                    Picker(
                        "",
                        selection: Binding(
                            get: { contextBuilderVM.enhancementMode },
                            set: { contextBuilderVM.enhancementMode = $0 }
                        )
                    ) {
                        Text("Rewrite").tag(PromptEnhancementMode.fullRewrite)
                        Text("Augment").tag(PromptEnhancementMode.augment)
                        Text("Preserve").tag(PromptEnhancementMode.preserve)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(enhancementDescription)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Question Timeout (canonical home — applies to UI + MCP clarifying questions and ask_user).
                VStack(alignment: .leading, spacing: 6) {
                    Text("Question Timeout")
                        .font(fontPreset.font)
                    Picker(
                        "",
                        selection: Binding(
                            get: { contextBuilderVM.questionTimeoutSeconds },
                            set: { contextBuilderVM.questionTimeoutSeconds = $0 }
                        )
                    ) {
                        Text("30 sec").tag(TimeInterval(30))
                        Text("1 min").tag(TimeInterval(60))
                        Text("2 min").tag(TimeInterval(120))
                        Text("5 min").tag(TimeInterval(300))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text("How long to wait for your response before the agent continues on its own. Applies to both clarifying questions and Agent Mode ask_user.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Shared Settings")
                .font(fontPreset.headlineFont)
        }
    }

    private var enhancementDescription: String {
        switch contextBuilderVM.enhancementMode {
        case .fullRewrite:
            "Agent rewrites the prompt while building context."
        case .augment:
            "Keeps your instructions and appends relevant context."
        case .preserve:
            "Only updates file selection, leaves instructions unchanged."
        }
    }

    // MARK: - UI Runs Section

    private var uiRunsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text("When you click \"Run\" in the Context Builder panel.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)

                Toggle(
                    isOn: Binding(
                        get: { contextBuilderVM.allowUIClarifyingQuestions },
                        set: { contextBuilderVM.allowUIClarifyingQuestions = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow Clarifying Questions")
                            .font(fontPreset.font)
                        Text("Agent can ask questions (\(formattedQuestionTimeout) timeout)")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(
                    isOn: Binding(
                        get: { contextBuilderVM.followUpAnalysisEnabled },
                        set: { contextBuilderVM.followUpAnalysisEnabled = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Follow-up Analysis")
                            .font(fontPreset.font)
                        Text("Automatically run this tab’s selected plan, review, or question after Context Builder completes")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                // Custom Prompts for Context Builder
                customPromptsSection
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .font(.caption)
                Text("UI Runs")
                    .font(fontPreset.headlineFont)
            }
        }
        .sheet(isPresented: $showPromptsOverlay) {
            ContextBuilderPromptsOverlay(
                isVisible: $showPromptsOverlay,
                selectedPromptIDs: $selectedPromptIDsForSettings,
                storage: promptStorage
            )
        }
    }

    // MARK: - Custom Prompts Section

    private var customPromptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Instructions")
                        .font(fontPreset.font)
                    Text("Manage prompts that can be selected per-tab in Context Builder.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { showPromptsOverlay = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "text.badge.plus")
                        Text(promptStorage.prompts.isEmpty ? "Add" : "\(promptStorage.prompts.count)")
                    }
                    .font(fontPreset.captionFont)
                }
                .buttonStyle(.bordered)
            }

            if !promptStorage.prompts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(promptStorage.prompts.prefix(3)) { prompt in
                        HStack(spacing: 6) {
                            Image(systemName: "text.quote")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(prompt.title)
                                .font(fontPreset.captionFont)
                                .lineLimit(1)
                        }
                    }
                    if promptStorage.prompts.count > 3 {
                        Text("+ \(promptStorage.prompts.count - 3) more...")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.05))
                .cornerRadius(6)
            }

            Text("Select which prompts to use from the Context Builder panel.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - MCP Runs Section

    private var mcpRunsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text("When called via the Context Builder MCP tool from Claude Code, Cursor, etc.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)

                Toggle(
                    isOn: Binding(
                        get: { contextBuilderVM.allowMCPClarifyingQuestions },
                        set: { contextBuilderVM.allowMCPClarifyingQuestions = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow Clarifying Questions")
                            .font(fontPreset.font)
                        Text("Agent can ask questions during MCP runs")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if contextBuilderVM.allowMCPClarifyingQuestions {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("You must be watching RepoPrompt to respond. Questions timeout after \(formattedQuestionTimeout) and are always disabled for inactive target workspaces.")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.orange)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption)
                Text("MCP Runs")
                    .font(fontPreset.headlineFont)
            }
        }
    }

    // MARK: - Helpers

    private var formattedQuestionTimeout: String {
        let seconds = contextBuilderVM.questionTimeoutSeconds
        if seconds < 60 {
            return "\(Int(seconds)) sec"
        } else {
            let minutes = Int(seconds) / 60
            return "\(minutes) min"
        }
    }
}
