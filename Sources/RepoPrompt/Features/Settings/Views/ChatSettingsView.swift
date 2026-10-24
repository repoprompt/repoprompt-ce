import RepoPromptSettingsCore

//
//  ChatSettingsView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-16.
//

import SwiftUI

struct ChatSettingsView: View {
    @ObservedObject var promptViewModel: PromptViewModel
    let windowID: Int
    var closeAction: (() -> Void)?
    @State private var editingPlanningPrompt: String = ""
    @State private var showSettingsPopover: Bool = false
    @State private var isAdvancedExpanded: Bool = false

    // MCP Model Presets — canonical storage lives in GlobalSettingsStore.
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @StateObject private var presetsManager = ModelPresetsManager.shared

    private var showModelPresets: Bool {
        globalSettings.mcpShowModelPresets()
    }

    private var showModelPresetsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpShowModelPresets() },
            set: { globalSettings.setMCPShowModelPresets($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chat Settings")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Configure RepoPrompt's built-in chat UI — the Built-in Chat Model, MCP Oracle presets, and planning prompt. These settings don't affect Agent Mode.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    CheckRecommendationsButton(windowID: windowID, closeAction: closeAction)
                }

                Divider()
                    .padding(.horizontal, -16)

                // AI Model Dropdown
                VStack(alignment: .leading, spacing: 8) {
                    Text("Built-in Chat Model").font(.headline)

                    AIModelDropdown(
                        promptViewModel: promptViewModel,
                        showSettingsPopover: $showSettingsPopover,
                        windowID: windowID,
                        useBorderlessStyle: false
                    )
                }

                Divider()
                    .padding(.horizontal, -16)

                // MCP Model Presets Section
                mcpModelPresetsSection

                Divider()
                    .padding(.horizontal, -16)

                // Planning Prompt
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Chat Planning Prompt")
                            .font(.headline)

                        Spacer()

                        Button("Save") {
                            promptViewModel.customPlanningPrompt = editingPlanningPrompt
                        }
                        .buttonStyle(CustomButtonStyle())

                        Button("Reset to Default") {
                            promptViewModel.resetPlanningPromptToDefault()
                            editingPlanningPrompt = promptViewModel.customPlanningPrompt
                        }
                        .buttonStyle(CustomButtonStyle())
                    }

                    Text("This prompt is used in Plan mode to instruct the AI on how to analyze and plan code changes.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextKitView(text: $editingPlanningPrompt, isSpellCheckEnabled: true, fontSize: 13)
                        .frame(height: 150)
                        .border(Color.gray.opacity(0.3), width: 1)
                }

                Divider()
                    .padding(.horizontal, -16)

                // Advanced Chat Controls (collapsible)
                advancedChatControlsSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            editingPlanningPrompt = promptViewModel.customPlanningPrompt
        }
        .onChange(of: promptViewModel.preferredAIModel) { _, _ in
            if !promptViewModel.preferredAIModel.isModelCapableOfDiff {
                promptViewModel.fileEditFormat = .whole
            }
        }
    }

    // MARK: - MCP Oracle Model Presets Section

    private var mcpModelPresetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Oracle Model Presets")
                    .font(.headline)

                Spacer()

                Button(action: {
                    NotificationCenter.default.post(
                        name: .showModelPresetsTab,
                        object: nil,
                        userInfo: ["windowID": windowID]
                    )
                }) {
                    Label("Manage Presets", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(CustomButtonStyle())
            }

            Text("Named Oracle model choices exposed to MCP clients (like Claude Code) for oracle conversations.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Use Oracle Model Presets for MCP", isOn: showModelPresetsBinding)
                .font(.body)

            if showModelPresets {
                if presetsManager.presets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.orange)
                            Text("No presets defined. MCP will use the model selected below.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        AIModelDropdown(
                            promptViewModel: promptViewModel,
                            showSettingsPopover: $showSettingsPopover,
                            windowID: windowID,
                            useBorderlessStyle: false,
                            isInGeneralSettings: false,
                            destination: .planningModel(promptVM: promptViewModel)
                        )
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(8)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("\(presetsManager.presets.count) preset\(presetsManager.presets.count == 1 ? "" : "s") available for MCP Oracle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("MCP 'list_models' will return these presets for client selection.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("MCP tools will use the current oracle model only.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Advanced Chat Controls Section

    private var advancedChatControlsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clickable header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAdvancedExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    Text("Advanced Chat Controls")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isAdvancedExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    // Edit Mode Prompt
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chat Edit Mode Prompt")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("This prompt will constrain how the model can respond outside of Pro Mode")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $promptViewModel.fileEditFormat) {
                            ForEach(PromptViewModel.FileEditFormat.allCases, id: \.self) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .labelsHidden()
                        .frame(width: 300, alignment: .leading)
                        .disabled(!promptViewModel.preferredAIModel.isModelCapableOfDiff)

                        Text(explanationText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Model Temperature
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Model Temperature")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text(String(format: "%.2f", promptViewModel.modelTemperature))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()
                        }

                        Slider(value: $promptViewModel.modelTemperature, in: 0 ... 1, step: 0.1)

                        Text("Lower values (closer to 0) make outputs more focused and deterministic. Higher values (closer to 1) make outputs more random and creative.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 12)
                .padding(.leading, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var explanationText: String {
        if !promptViewModel.preferredAIModel.isModelCapableOfDiff, promptViewModel.fileEditFormat == .diff {
            "This model does not support diff editing. It will use whole file editing instead."
        } else {
            switch promptViewModel.fileEditFormat {
            case .none:
                "Unconstrained AI chat, but you cannot directly edit files."
            case .diff:
                "In diff mode, the AI will attempt to output only the changes needed."
            case .whole:
                "In whole mode, the AI will rewrite the entire file."
            }
        }
    }
}
