import SwiftUI

struct ModelPresetsSheet: View {
    @ObservedObject var promptViewModel: PromptViewModel
    @ObservedObject var presetsManager = ModelPresetsManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingAddPreset = false
    @State private var editingPreset: ModelPreset?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            if presetsManager.presets.isEmpty {
                emptyStateView
            } else {
                presetsList
            }
        }
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

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model Presets")
                    .font(FontScalePreset.current.headlineFont)
                Text("Define custom model configurations for different use cases")
                    .font(FontScalePreset.current.captionFont)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(CustomButtonStyle())
        }
        .padding()
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
        .padding()
    }

    private var presetsList: some View {
        VStack(spacing: 0) {
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
            .padding()

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
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }
}

// MARK: - ModelPresetRow

struct ModelPresetRow: View {
    let preset: ModelPreset
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isHoveringEdit = false
    @State private var isHoveringDelete = false

    var body: some View {
        HStack(spacing: 12) {
            // Model icon
            Image(systemName: "cpu")
                .font(.system(size: 20 * FontScalePreset.current.scaleFactor))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(preset.name)
                        .font(FontScalePreset.current.subHeadlineBoldFont)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text(preset.model.displayName)
                        .font(FontScalePreset.current.font)
                        .foregroundColor(.secondary)
                }

                if let description = preset.description, !description.isEmpty {
                    Text(description)
                        .font(FontScalePreset.current.captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let modes = preset.supportedModes {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape.2")
                                .font(FontScalePreset.current.captionFont)
                            Text(modes.displayString)
                                .font(FontScalePreset.current.captionFont)
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Actions
            if isHovering {
                HStack(spacing: 12) {
                    Button(action: onEdit) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isHoveringEdit ? Color.accentColor : Color.gray.opacity(0.2))
                        .foregroundColor(isHoveringEdit ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isHoveringEdit = hovering
                        }
                    }

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .padding(8)
                            .background(isHoveringDelete ? Color.red.opacity(0.9) : Color.gray.opacity(0.2))
                            .foregroundColor(isHoveringDelete ? .white : .red)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isHoveringDelete = hovering
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(isHovering ? 0.1 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - ModelPresetEditView

struct ModelPresetEditView: View {
    @ObservedObject var promptViewModel: PromptViewModel
    let preset: ModelPreset?
    let onSave: (ModelPreset) -> Void

    @State private var name: String = ""
    @State private var selectedModel: AIModel = .claude4Sonnet
    @State private var description: String = ""
    @State private var chatEnabled = true
    @State private var planEnabled = true
    @State private var editEnabled = false
    @State private var reviewEnabled = true
    @State private var hasRestrictions = false
    @State private var nameValidationError: String? = nil

    // Chat preset mappings
    @State private var chatPresetID: UUID? = nil
    @State private var planPresetID: UUID? = nil
    @State private var editPresetID: UUID? = nil
    @State private var reviewPresetID: UUID? = nil
    @StateObject private var chatPresetManager = ChatPresetManager.shared

    @Environment(\.dismiss) private var dismiss

    private var availableModels: [AIModel] {
        // Get all available models from the prompt view model
        promptViewModel.availableModels
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: { selectedModel.rawValue },
            set: { newValue in
                if let model = AIModel.fromModelName(newValue) {
                    selectedModel = model
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(preset == nil ? "Add Model Preset" : "Edit Model Preset")
                    .font(FontScalePreset.current.headlineFont)
                Spacer()
            }
            .padding()

            Divider()

            // Form
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Preset Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: name) { _, newValue in
                                let validation = ModelPreset.validateName(newValue)
                                nameValidationError = validation.error
                            }

                        if let error = nameValidationError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(FontScalePreset.current.captionFont)
                                Text(error)
                                    .font(FontScalePreset.current.captionFont)
                                    .foregroundColor(.orange)
                            }
                        } else if !name.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                    .font(FontScalePreset.current.captionFont)
                                Text("Will be saved as: \(ModelPreset.sanitizeName(name))")
                                    .font(FontScalePreset.current.captionFont)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        OptimizedModelPicker(
                            selection: modelSelectionBinding,
                            availableModels: availableModels,
                            font: FontScalePreset.current.font
                        )
                        .frame(width: 250)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description (optional)")
                            .font(FontScalePreset.current.captionFont)
                            .foregroundColor(.secondary)
                        TextEditor(text: $description)
                            .font(FontScalePreset.current.font)
                            .frame(height: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }
                }

                // Mode section (Chat, Plan, Review) with mapping selectors – toggles enabled, default ON for new presets
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        // Chat mode
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Available for Chat", isOn: $chatEnabled)
                                .font(FontScalePreset.current.font)

                            HStack {
                                Text("Chat Preset:")
                                    .font(FontScalePreset.current.captionFont)
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .trailing)

                                ChatPresetSelectorButton(
                                    selection: $chatPresetID,
                                    mode: .chat,
                                    chatPresetManager: chatPresetManager,
                                    promptViewModel: promptViewModel
                                )

                                Spacer()
                            }
                            .padding(.leading, 20)
                        }

                        // Plan mode
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Available for Plan", isOn: $planEnabled)
                                .font(FontScalePreset.current.font)

                            HStack {
                                Text("Chat Preset:")
                                    .font(FontScalePreset.current.captionFont)
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .trailing)

                                ChatPresetSelectorButton(
                                    selection: $planPresetID,
                                    mode: .plan,
                                    chatPresetManager: chatPresetManager,
                                    promptViewModel: promptViewModel
                                )

                                Spacer()
                            }
                            .padding(.leading, 20)
                        }

                        // Review mode
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Available for Review", isOn: $reviewEnabled)
                                .font(FontScalePreset.current.font)

                            HStack {
                                Text("Chat Preset:")
                                    .font(FontScalePreset.current.captionFont)
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .trailing)

                                ChatPresetSelectorButton(
                                    selection: $reviewPresetID,
                                    mode: .review,
                                    chatPresetManager: chatPresetManager,
                                    promptViewModel: promptViewModel
                                )

                                Spacer()
                            }
                            .padding(.leading, 20)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .formStyle(.grouped)
            .padding(.top, -20) // Reduce top padding

            Divider()

            // Footer
            HStack(spacing: 16) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(CustomButtonStyle())

                Button("Save") {
                    savePreset()
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(name.isEmpty || nameValidationError != nil)

                Spacer()
            }
            .padding()
        }
        .frame(width: 500, height: 700)
        .onAppear {
            if let preset {
                name = preset.name
                selectedModel = preset.model
                description = preset.description ?? ""

                // Initialize modes from preset.supportedModes if present; default to true
                if let modes = preset.supportedModes {
                    chatEnabled = modes.chat
                    planEnabled = modes.plan
                    editEnabled = false
                    reviewEnabled = modes.review
                } else {
                    chatEnabled = true
                    planEnabled = true
                    editEnabled = false
                    reviewEnabled = true
                }

                // Load chat preset mappings (migration preserved)
                if let mappings = preset.chatPresetMappings {
                    chatPresetID = mappings.chatPresetID
                    planPresetID = mappings.planPresetID
                    editPresetID = nil
                    reviewPresetID = mappings.reviewPresetID
                } else {
                    chatPresetID = ChatPreset.BuiltIn.chat.id
                    planPresetID = ChatPreset.BuiltIn.plan.id
                    editPresetID = nil
                    reviewPresetID = ChatPreset.BuiltIn.review.id
                }
            } else {
                // Default to current chat model for new presets
                selectedModel = promptViewModel.preferredAIModel

                // Set default chat preset mappings to built-in presets
                chatPresetID = ChatPreset.BuiltIn.chat.id
                planPresetID = ChatPreset.BuiltIn.plan.id
                editPresetID = nil
                reviewPresetID = ChatPreset.BuiltIn.review.id

                // Modes default ON for new presets
                chatEnabled = true
                planEnabled = true
                editEnabled = false
                reviewEnabled = true
            }
        }
    }

    private func savePreset() {
        // New logic: persist no supportedModes and always include mappings for all modes
        let supportedModesFinal = SupportedModes(
            chat: chatEnabled,
            plan: planEnabled,
            edit: false,
            review: reviewEnabled
        )
        let chatPresetMappingsFinal = ChatPresetMappings(
            chatPresetID: chatPresetID,
            planPresetID: planPresetID,
            editPresetID: nil,
            reviewPresetID: reviewPresetID
        )

        let newPreset = ModelPreset(
            id: preset?.id ?? UUID(),
            name: name,
            model: selectedModel,
            description: description.isEmpty ? nil : description,
            supportedModes: supportedModesFinal,
            chatPresetMappings: chatPresetMappingsFinal
        )

        onSave(newPreset)
        dismiss()
    }
}

// MARK: - ChatPresetSelectorButton

struct ChatPresetSelectorButton: View {
    @Binding var selection: UUID?
    let mode: ChatPresetMode
    @ObservedObject var chatPresetManager: ChatPresetManager
    @ObservedObject var promptViewModel: PromptViewModel
    @State private var showPresetPicker = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var currentPreset: ChatPreset? {
        if let id = selection {
            return chatPresetManager.preset(with: id)
        }
        // Return the default built-in preset for the mode
        switch mode {
        case .chat:
            return ChatPreset.BuiltIn.chat
        case .plan:
            return ChatPreset.BuiltIn.plan
        case .review:
            return ChatPreset.BuiltIn.review
        }
    }

    private var currentPresetName: String {
        currentPreset?.name ?? "None"
    }

    private var currentPresetIcon: String? {
        currentPreset?.icon
    }

    var body: some View {
        Button(action: { showPresetPicker = true }) {
            HStack(spacing: 4) {
                if let icon = currentPresetIcon {
                    Text(icon)
                        .font(.system(size: 12))
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                }
                Text(currentPresetName)
                    .font(FontScalePreset.current.captionFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 45)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
        }
        .buttonStyle(CustomButtonStyle())
        .hoverTooltip("Select \(mode.displayName) preset")
        .popover(isPresented: $showPresetPicker) {
            chatPresetPickerPopover()
        }
    }

    @ViewBuilder
    private func chatPresetPickerPopover() -> some View {
        // Get all presets for the specific mode, excluding Manual.
        let allPresets = chatPresetManager.allPresets.filter { preset in
            // Exclude Manual preset
            if preset.name == "Manual" {
                return false
            }

            return preset.mode == mode && chatPresetManager.isPresetVisible(preset)
        }

        // Find the default built-in preset for this mode if no selection
        let defaultPresetId: UUID = switch mode {
        case .chat:
            ChatPreset.BuiltIn.chat.id
        case .plan:
            ChatPreset.BuiltIn.plan.id
        case .review:
            ChatPreset.BuiltIn.review.id
        }

        // Use the selection if set, otherwise use the default
        let selectedId = selection ?? defaultPresetId

        SettingsChatPresetPickerPopover(
            allPresets: allPresets,
            selectedId: selectedId,
            fontPreset: fontPreset,
            windowID: promptViewModel.windowID,
            previewBuilder: { preset -> AnyView in
                AnyView(SettingsChatPresetPreviewView(preset: preset, fontPreset: fontPreset))
            },
            onSelect: { preset in
                selection = preset.id
                showPresetPicker = false
            }
        )
        .frame(width: 640 * fontPreset.scaleFactor, height: 436 * fontPreset.scaleFactor)
        .padding(10)
    }
}
