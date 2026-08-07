import SwiftUI

struct ModelPresetsSettingsView: View {
    @ObservedObject var promptViewModel: PromptViewModel
    @ObservedObject var presetsManager = ModelPresetsManager.shared

    @State private var showingAddPreset = false
    @State private var editingPreset: ModelPreset?

    /// "Presets hidden" flag is owned by GlobalSettingsStore.
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    private var presetsTemporarilyDisabled: Bool {
        globalSettings.mcpTemporarilyDisablePresets()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Warning banner when presets are temporarily hidden
            if presetsTemporarilyDisabled {
                presetsHiddenBanner
            }

            // Content
            if presetsManager.presets.isEmpty {
                emptyStateView
            } else {
                presetsContent
            }
        }
        .padding()
        .sheet(isPresented: $showingAddPreset) {
            ModelPresetEditView(
                promptViewModel: promptViewModel,
                preset: nil,
                onSave: { preset in
                    presetsManager.addPreset(preset)
                }
            )
        }
        .sheet(item: $editingPreset) { preset in
            ModelPresetEditView(
                promptViewModel: promptViewModel,
                preset: preset,
                onSave: { updatedPreset in
                    presetsManager.updatePreset(updatedPreset)
                }
            )
        }
        .background {
            PresetPersistenceErrorAlertHost(
                message: presetsManager.persistenceErrorMessage ?? "The preset change couldn't be saved.",
                isPresented: persistenceErrorBinding
            )
        }
    }

    private var persistenceErrorBinding: Binding<Bool> {
        Binding(
            get: { presetsManager.persistenceErrorMessage != nil },
            set: { isPresented in
                if !isPresented { presetsManager.clearPersistenceError() }
            }
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 48 * FontScalePreset.current.scaleFactor))
                .foregroundColor(.secondary)

            Text("No Model Presets")
                .font(FontScalePreset.current.headlineFont)

            Text("Create presets to quickly switch between different models for specific tasks")
                .font(FontScalePreset.current.font)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button(action: {
                // Create default preset from current chat model
                let defaultPreset = ModelPreset.fromCurrentChatModel(modelRawString: promptViewModel.preferredModel)
                if presetsManager.addPreset(defaultPreset) {
                    editingPreset = defaultPreset
                }
            }) {
                Label("Create Default Preset", systemImage: "plus.circle")
            }
            .buttonStyle(CustomButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var presetsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with description
            VStack(alignment: .leading, spacing: 4) {
                Text("Define custom model configurations for different use cases")
                    .font(FontScalePreset.current.font)
                    .foregroundColor(.secondary)
            }

            // Toolbar
            HStack {
                Text("\(presetsManager.presets.count) preset\(presetsManager.presets.count == 1 ? "" : "s")")
                    .font(FontScalePreset.current.captionFont)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { showingAddPreset = true }) {
                    Label("Add Preset", systemImage: "plus")
                }
                .buttonStyle(CustomButtonStyle())
            }

            // List
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(presetsManager.presets) { preset in
                        ModelPresetRow(
                            preset: preset,
                            onEdit: { editingPreset = preset },
                            onDelete: { presetsManager.removePreset(preset) }
                        )
                    }
                }
            }

            Spacer()
        }
    }

    private var presetsHiddenBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 16 * FontScalePreset.current.scaleFactor))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Presets Hidden")
                    .font(FontScalePreset.current.subHeadlineBoldFont)
                Text("Model presets are temporarily hidden by the recommendation engine. Click to show them in the MCP toolbar.")
                    .font(FontScalePreset.current.captionFont)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Show Presets") {
                globalSettings.setMCPTemporarilyDisablePresets(false)
            }
            .buttonStyle(CustomButtonStyle())
        }
        .padding(12)
        .background(Color.yellow.opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 12)
    }
}
