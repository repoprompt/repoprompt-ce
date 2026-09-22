import SwiftUI

struct ChatPresetsSettingsView: View {
    @ObservedObject var promptViewModel: PromptViewModel
    @ObservedObject private var presetManager = ChatPresetManager.shared
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    /// When hosted inside the unified Workflow Presets surface, the inner
    /// per-type header is suppressed so the outer view can supply a single
    /// "Workflow Presets" title. See `WorkflowPresetsSettingsView`.
    var embedded: Bool = false

    @State private var searchText = ""
    @State private var filter: PresetFilter = .all
    @State private var showingAddPreset = false
    @State private var editingPreset: ChatPreset?
    @State private var presetToDelete: ChatPreset?
    @State private var duplicatingPreset: ChatPreset?

    enum PresetFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case shown = "Shown"
        case hidden = "Hidden"
        var id: String {
            rawValue
        }
    }

    private var filteredPresets: [ChatPreset] {
        let searchKey = searchText.lowercased()
        return presetManager.allPresets
            .filter { p in
                // Exclude Manual preset from settings - it's not configurable
                guard p.name != "Manual" else { return false }

                guard !searchKey.isEmpty else { return true }
                return p.name.lowercased().contains(searchKey)
            }
            .filter { p in
                switch filter {
                case .all: true
                case .shown: presetManager.isPresetVisible(p)
                case .hidden: !presetManager.isPresetVisible(p)
                }
            }
            .sorted { first, second in
                // Built-in presets first, then custom
                if first.isBuiltIn != second.isBuiltIn {
                    return first.isBuiltIn
                }
                // Within each group, sort alphabetically
                return first.name < second.name
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                headerSection
            }

            if presetManager.allPresets.isEmpty {
                emptyStateView
            } else {
                presetsContent
            }
        }
        .padding(embedded ? EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12) : EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        // Add sheet for Create (nil preset)
        .sheet(isPresented: $showingAddPreset) {
            ChatPresetEditView(
                promptViewModel: promptViewModel,
                preset: nil,
                editMode: .createCustom,
                onSave: { newPreset in
                    presetManager.addPreset(newPreset)
                }
            )
        }
        // Edit / Inspect sheet (allows override editing for built-ins)
        .sheet(item: $editingPreset) { preset in
            ChatPresetEditView(
                promptViewModel: promptViewModel,
                preset: preset,
                editMode: preset.isBuiltIn ? .builtInOverrides : .editCustom,
                onSave: { updated in
                    if !preset.isBuiltIn {
                        presetManager.updatePreset(updated)
                    }
                    // Built-in overrides are handled inside ChatPresetEditView
                }
            )
        }
        // Duplicate sheet - opens editor with cloned preset
        .sheet(item: $duplicatingPreset) { preset in
            ChatPresetEditView(
                promptViewModel: promptViewModel,
                preset: makeDuplicatePreset(from: preset),
                editMode: .createCustom, // Duplicates are new custom presets
                onSave: { newPreset in
                    presetManager.addPreset(newPreset)
                }
            )
        }
        .alert("Delete Preset", isPresented: Binding(
            get: { presetToDelete != nil },
            set: { _ in }
        )) {
            Button("Cancel", role: .cancel) {
                presetToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let preset = presetToDelete {
                    presetManager.deletePreset(preset)
                    presetToDelete = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(presetToDelete?.name ?? "")'? This action cannot be undone.")
        }
        .background {
            PresetPersistenceErrorAlertHost(
                message: presetManager.persistenceErrorMessage ?? "The preset change couldn't be saved.",
                isPresented: persistenceErrorBinding
            )
        }
    }

    private var persistenceErrorBinding: Binding<Bool> {
        Binding(
            get: { presetManager.persistenceErrorMessage != nil },
            set: { isPresented in
                if !isPresented { presetManager.clearPersistenceError() }
            }
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chat Presets")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Reusable presets for RepoPrompt's built-in chat UI. Each preset bundles a chat mode, optional model selection, project-structure / code-map / git-diff options, and stored-prompt selections. These don't affect Agent Mode.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48 * fontPreset.scaleFactor))
                .foregroundColor(.secondary)

            Text("No Chat Presets")
                .font(.headline)

            Text("Create presets to quickly start chats with different modes and contexts.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button(action: { showingAddPreset = true }) {
                Label("New Chat Preset", systemImage: "plus.circle")
            }
            .buttonStyle(CustomButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main content

    private var presetsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header / Description
            Text("Define chat modes and contexts for different workflows.")
                .font(.body)
                .foregroundColor(.secondary)

            // Compact toolbar row
            HStack(spacing: 8) {
                // Search (expands)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search presets", text: $searchText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.body)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)
                )
                .frame(maxWidth: .infinity)

                // Small filter segment
                Picker("", selection: $filter) {
                    ForEach(PresetFilter.allCases) { f in
                        Text(f.rawValue)
                            .font(.caption)
                            .tag(f)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .controlSize(.small)
                .frame(maxWidth: 200)

                // Add button
                Button(action: { showingAddPreset = true }) {
                    Label("Add Preset", systemImage: "plus")
                        .font(.body)
                }
                .buttonStyle(CustomButtonStyle())
            }
            .padding(.vertical, 2) // more compact vertical size

            // List
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(filteredPresets.enumerated()), id: \.element.id) { index, preset in
                        // Add divider between built-in and custom presets
                        if index > 0,
                           filteredPresets[index - 1].isBuiltIn,
                           !preset.isBuiltIn
                        {
                            Divider()
                                .padding(.vertical, 4)
                        }

                        ChatPresetRow(
                            preset: preset,
                            isShown: presetManager.isPresetVisible(preset),
                            fontPreset: fontPreset,
                            onToggleShown: {
                                presetManager.togglePresetVisibility(preset)
                            },
                            onEdit: {
                                editingPreset = preset
                            },
                            onDuplicate: {
                                duplicatingPreset = preset
                            },
                            onDelete: {
                                if !preset.isBuiltIn {
                                    presetToDelete = preset
                                }
                            }
                        )
                        .contextMenu {
                            Button(presetManager.isPresetVisible(preset) ? "Hide from menu" : "Show in menu") {
                                presetManager.togglePresetVisibility(preset)
                            }
                            Button("Duplicate") { duplicatingPreset = preset }
                            if preset.isBuiltIn, presetManager.hasOverrides(preset.id) {
                                Divider()
                                Button("Reset Overrides") {
                                    presetManager.clearOverrides(for: preset.id)
                                }
                            }
                            if !preset.isBuiltIn {
                                Divider()
                                Button("Delete", role: .destructive) { presetToDelete = preset }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func makeDuplicatePreset(from preset: ChatPreset) -> ChatPreset {
        // Generate a unique name for the duplicate
        let baseName = "\(preset.name) Copy"
        let newName = presetManager.generateUniqueName(baseName: baseName)
        return ChatPreset(
            id: UUID(), // New ID for the duplicate
            name: newName,
            mode: preset.mode,
            modelPresetName: preset.modelPresetName,
            description: preset.description,
            icon: preset.icon,
            isBuiltIn: false, // clones are user presets
            fileTreeMode: preset.fileTreeMode,
            codeMapUsage: preset.codeMapUsage,
            gitInclusion: preset.gitInclusion,
            storedPromptIds: preset.storedPromptIds
        )
    }
}

// MARK: - Row

private struct ChatPresetRow: View {
    let preset: ChatPreset
    let isShown: Bool
    let fontPreset: FontScalePreset
    let onToggleShown: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10 * fontPreset.scaleFactor) {
            // 1) Smaller switch toggle on the left
            Toggle("", isOn: Binding<Bool>(
                get: { isShown },
                set: { _ in onToggleShown() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .hoverTooltip(isShown ? "Shown in quick menu" : "Hidden from quick menu")
            .accessibilityLabel("Show \(preset.name) in quick menu")

            // 2) Title area: icon inline with name, then Built-in/Custom badge, then compact readable chips
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let icon = preset.icon {
                        Text(icon)
                            .font(.system(size: 14)) // Smaller emoji
                    }
                    Text(preset.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if preset.isBuiltIn {
                        if ChatPresetManager.shared.hasOverrides(preset.id) {
                            Label("Built-in (modified)", systemImage: "pencil.circle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            Label("Built-in", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Label("Custom", systemImage: "person.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Readable, compact chips only for non-default settings
                ChatPresetSummaryChips(preset: preset, fontPreset: fontPreset)
            }

            Spacer(minLength: 0)

            // 3) Right-aligned buttons (no ellipsis menu)
            Button("Clone") {
                onDuplicate()
            }
            .font(.body)
            .buttonStyle(CustomButtonStyle())
            .controlSize(.small)

            Button("Edit") {
                onEdit()
            }
            .font(.body)
            .buttonStyle(CustomButtonStyle())
            .controlSize(.small)

            // Delete button for custom presets
            if !preset.isBuiltIn {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.body)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
            }
        }
        .frame(height: 36 * fontPreset.scaleFactor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .opacity(isShown ? 1.0 : 0.6) // Dim entire row when hidden
        // Hover tracking for main row area
        .onHover { isHovering = $0 }
    }
}

private struct ChatPresetSummaryChips: View {
    let preset: ChatPreset
    let fontPreset: FontScalePreset

    var body: some View {
        HStack(spacing: 6) {
            // Mode chip
            ReadableChip(text: readableMode(preset.mode), tint: .blue, fontPreset: fontPreset)

            // Model chip (shown when custom model is specified)
            if let model = preset.modelPresetName {
                ReadableChip(text: readableModel(model), tint: .pink, fontPreset: fontPreset)
            }

            // Project structure map (shown when not .auto and not .none)
            if let mode = preset.fileTreeMode, let text = readableTree(mode) {
                ReadableChip(text: text, tint: .teal, fontPreset: fontPreset)
            }

            // Code map (shown when not .none)
            if let cm = preset.codeMapUsage, let text = readableMap(cm) {
                ReadableChip(text: text, tint: .indigo, fontPreset: fontPreset)
            }

            // Git (shown when not .none)
            if let gi = preset.gitInclusion, gi != .none {
                ReadableChip(text: "Git", tint: .orange, fontPreset: fontPreset)
            }

            // Stored prompts indicator
            if let prompts = preset.storedPromptIds, !prompts.isEmpty {
                ReadableChip(text: "Prompts: \(prompts.count)", tint: .green, fontPreset: fontPreset)
            }
        }
    }

    private func readableMode(_ mode: ChatPresetMode) -> String {
        switch mode {
        case .chat: "Chat"
        case .plan: "Plan"
        case .review: "Review"
        }
    }

    private func readableModel(_ modelRawValue: String) -> String {
        // Convert to AIModel and use its display name
        guard let model = AIModel.fromModelName(modelRawValue) else {
            return modelRawValue
        }

        let displayName = model.displayName
        // Truncate if too long for the chip
        if displayName.count > 20 {
            return String(displayName.prefix(18)) + "…"
        }
        return displayName
    }

    private func readableTree(_ mode: FileTreeOption) -> String? {
        switch mode {
        case .files: "Structure: All"
        case .selected: "Structure: Selected"
        case .auto: nil // default, not shown
        case .none: nil // not shown
        }
    }

    private func readableMap(_ use: CodeMapUsage) -> String? {
        switch use {
        case .auto: nil // default, not shown
        case .complete: "Map Complete"
        case .selected: "Map Selected"
        case .none: nil // not shown
        }
    }

    private struct ReadableChip: View {
        let text: String
        let tint: Color
        let fontPreset: FontScalePreset

        var body: some View {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.12))
                .foregroundColor(tint)
                .cornerRadius(6)
        }
    }
}

// MARK: - Helper Components

private struct StoredPromptChip: View {
    let prompt: PromptViewModel.StoredPrompt
    let onRemove: () -> Void
    let isReadOnly: Bool

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var isHovering = false
    @State private var showPopover = false
    @State private var isPreviewHovering = false
    @State private var isRemoveHovering = false

    private let buttonsWidth: CGFloat = 44 // 2 buttons (20 each) + spacing

    var body: some View {
        ZStack(alignment: .trailing) {
            // Text that truncates when icons appear
            Text(prompt.title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, isHovering && !isReadOnly ? buttonsWidth : 0)

            // Hover controls overlay
            if isHovering, !isReadOnly {
                HStack(spacing: 2) {
                    // Preview button with magnifying glass
                    Button(action: {
                        showPopover = true
                    }) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundColor(.primary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(isPreviewHovering ? Color.secondary.opacity(0.3) : Color.clear)
                    .cornerRadius(3)
                    .onHover { hovering in
                        isPreviewHovering = hovering
                    }

                    // Remove button
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(isRemoveHovering ? Color.secondary.opacity(0.3) : Color.clear)
                    .cornerRadius(3)
                    .onHover { hovering in
                        isRemoveHovering = hovering
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 80, maxWidth: 150)
        .frame(height: 28) // Fixed height to prevent vertical resize
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            if !isHovering {
                showPopover = true
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .leading) {
            StoredPromptPreview(prompt: prompt)
        }
    }
}

/// Simple preview popover for stored prompts
private struct StoredPromptPreview: View {
    let prompt: PromptViewModel.StoredPrompt
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.title)
                .font(.headline)

            ScrollView {
                Text(prompt.content)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Editor Sheet

private struct ChatPresetEditView: View {
    enum EditMode {
        case createCustom
        case editCustom
        case builtInOverrides
    }

    @ObservedObject var promptViewModel: PromptViewModel
    @ObservedObject private var presetManager = ChatPresetManager.shared
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    let preset: ChatPreset?
    let editMode: EditMode
    let onSave: (ChatPreset) -> Void

    init(promptViewModel: PromptViewModel, preset: ChatPreset?, editMode: EditMode, onSave: @escaping (ChatPreset) -> Void) {
        self.promptViewModel = promptViewModel
        self.preset = preset
        self.editMode = editMode
        self.onSave = onSave
    }

    /// Editable state
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var icon: String = "💬"
    @State private var descriptionText: String = ""
    @State private var mode: ChatPresetMode = .chat
    // No copy preset linkage in chat presets

    // New fields for enhanced configuration
    @State private var fileTreeMode: FileTreeOption = .auto
    @State private var codeMapUsage: CodeMapUsage = .auto
    @State private var gitInclusion: GitInclusion = .none
    @State private var selectedStoredPromptIDs: Set<UUID> = []
    @State private var modelPresetName: String?

    @FocusState private var iconFieldFocused: Bool

    private var titleText: String {
        switch editMode {
        case .createCustom:
            "Create Chat Preset"
        case .editCustom:
            "Edit Chat Preset"
        case .builtInOverrides:
            "Customize Built-in Preset"
        }
    }

    private var isReadOnly: Bool {
        false // All modes allow editing now, but some fields are disabled in override mode
    }

    private var isOverviewDisabled: Bool {
        editMode == .builtInOverrides
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(titleText)
                    .font(fontPreset.titleFont)
                Spacer()

                if editMode == .builtInOverrides {
                    Button("Reset All") {
                        resetAllOverrides()
                    }
                    .buttonStyle(CustomButtonStyle())
                    .foregroundColor(.orange)

                    Button("Duplicate") {
                        duplicateBuiltIn()
                    }
                    .buttonStyle(CustomButtonStyle())
                }
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()

            // Info banner for override mode
            if editMode == .builtInOverrides {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("You are customizing a built-in preset. Your changes will be saved as personal overrides.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Overview
                    section(title: "Overview") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("Name")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if isOverviewDisabled || isReadOnly {
                                    ReadOnlyInputBox(
                                        text: name,
                                        placeholder: "Preset Name"
                                    )
                                } else {
                                    TextField("Preset Name", text: $name)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            GridRow {
                                Text("Icon")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack {
                                    // Icon display
                                    Text(icon.isEmpty ? "💬" : icon)
                                        .font(.system(size: 24))
                                        .frame(width: 40, height: 40)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                        )

                                    // Hidden text field for emoji input
                                    TextField("", text: $icon)
                                        .frame(width: 1, height: 1)
                                        .opacity(0)
                                        .focused($iconFieldFocused)
                                        .disabled(isOverviewDisabled || isReadOnly)

                                    if !(isOverviewDisabled || isReadOnly) {
                                        Button("Choose Emoji") {
                                            icon = "" // Clear field
                                            iconFieldFocused = true
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                NSApp.orderFrontCharacterPalette(nil)
                                            }
                                        }
                                        .buttonStyle(CustomButtonStyle())
                                        .controlSize(.small)
                                    }

                                    Spacer()
                                }
                            }
                            GridRow {
                                Text("Description")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if isOverviewDisabled || isReadOnly {
                                    ReadOnlyInputBox(
                                        text: descriptionText,
                                        placeholder: "Optional description",
                                        minHeight: 56,
                                        multiline: true
                                    )
                                } else {
                                    TextField("Optional description", text: $descriptionText, axis: .vertical)
                                        .lineLimit(2 ... 4)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }

                    // Chat Mode
                    section(title: "Chat Mode") {
                        Picker("Mode", selection: $mode) {
                            Text("Chat").tag(ChatPresetMode.chat)
                            Text("Plan").tag(ChatPresetMode.plan)
                            Text("Review").tag(ChatPresetMode.review)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isOverviewDisabled || isReadOnly)

                        Text(mode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Project Structure
                    section(title: "Project Structure") {
                        Picker("Mode", selection: $fileTreeMode) {
                            ForEach(FileTreeOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isReadOnly)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(fileTreeMode.caption)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Adds an ASCII project structure map so chat can understand organization and file locations.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Code Maps
                    section(title: "Code Maps") {
                        Picker("Usage", selection: $codeMapUsage) {
                            ForEach(CodeMapUsage.allCases, id: \.self) { usage in
                                Text(usage.rawValue.capitalized).tag(usage)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isReadOnly)

                        Text(codeMapUsage.caption)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Git
                    section(title: "Git Diff") {
                        Picker("Include", selection: $gitInclusion) {
                            Text("None").tag(GitInclusion.none)
                            Text("Selected").tag(GitInclusion.selected)
                            Text("Complete").tag(GitInclusion.complete)
                        }
                        .pickerStyle(.segmented)
                        .disabled(isReadOnly)

                        Text("Include diffs from your working changes. \"Selected\" includes only checked files, \"Complete\" includes all changes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Stored Prompts
                    section(title: "Stored Prompts") {
                        VStack(alignment: .leading, spacing: 10) {
                            // Description text at the top
                            Text("Meta-instructions to include with this preset (e.g., [Architect], [Review]).")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // Selected prompts as tags or empty state
                            if !selectedStoredPromptIDs.isEmpty {
                                let selectedPrompts = promptViewModel.storedPrompts.filter { selectedStoredPromptIDs.contains($0.id) }
                                let maxVisible = 3
                                HStack(spacing: 6) {
                                    ForEach(selectedPrompts.prefix(maxVisible)) { prompt in
                                        StoredPromptChip(
                                            prompt: prompt,
                                            onRemove: {
                                                guard !isReadOnly else { return }
                                                selectedStoredPromptIDs.remove(prompt.id)
                                            },
                                            isReadOnly: isReadOnly
                                        )
                                    }
                                    if selectedPrompts.count > maxVisible {
                                        Text("+ \(selectedPrompts.count - maxVisible) more")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                Text("No prompts selected")
                                    .font(.caption)
                                    .foregroundColor(Color.secondary.opacity(0.6))
                                    .italic()
                            }

                            // Add button
                            if !isReadOnly {
                                Menu {
                                    ForEach(promptViewModel.storedPrompts.filter { !selectedStoredPromptIDs.contains($0.id) }) { prompt in
                                        Button(action: {
                                            selectedStoredPromptIDs.insert(prompt.id)
                                        }) {
                                            Text(prompt.title)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                        Text("Add Prompt")
                                    }
                                    .font(.caption)
                                }
                                .menuStyle(BorderlessButtonMenuStyle())
                                .menuIndicator(.hidden)
                                .disabled(promptViewModel.storedPrompts.filter { !selectedStoredPromptIDs.contains($0.id) }.isEmpty)
                            }
                        }
                    }

                    // Model Selection
                    section(title: "Model") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Required Model:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if modelPresetName != nil {
                                    // Use AIModelDropdown when a model is selected
                                    AIModelDropdown(
                                        promptViewModel: promptViewModel,
                                        showSettingsPopover: .constant(false),
                                        useBorderlessStyle: false,
                                        destination: .binding(
                                            Binding(
                                                get: { modelPresetName ?? promptViewModel.preferredModel },
                                                set: { modelPresetName = $0 }
                                            ),
                                            id: "chatPresetRequiredModel"
                                        )
                                    )

                                    Button("Clear") {
                                        modelPresetName = nil
                                    }
                                    .buttonStyle(CustomButtonStyle())
                                    .controlSize(.small)
                                } else {
                                    // Show button to select a model
                                    Button("Use current model") {
                                        // This is the default - no model override
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.secondary)

                                    Button("Select Model") {
                                        modelPresetName = promptViewModel.preferredModel
                                    }
                                    .buttonStyle(CustomButtonStyle())
                                    .controlSize(.small)
                                }

                                Spacer()
                            }
                            .disabled(isReadOnly)

                            Text("When set, this model will be used for this preset unless MCP explicitly provides a model.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(CustomButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                if isReadOnly {
                    Button("Close") { dismiss() }
                        .buttonStyle(CustomButtonStyle())
                } else {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .buttonStyle(CustomButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
        .frame(width: 560 * fontPreset.scaleFactor, height: 700 * fontPreset.scaleFactor)
        .onAppear(perform: preload)
    }

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .cornerRadius(8)
        }
    }

    private func preload() {
        // Load existing preset or defaults
        if let p = preset {
            // Always fetch the resolved preset from the manager so we reflect current overrides (or base after reset)
            let effective = presetManager.resolvedPreset(with: p.id) ?? p
            name = effective.name
            icon = effective.icon ?? "💬"
            descriptionText = effective.description ?? ""
            mode = effective.mode
            fileTreeMode = effective.fileTreeMode ?? .auto
            codeMapUsage = effective.codeMapUsage ?? .auto
            gitInclusion = effective.gitInclusion ?? .none
            selectedStoredPromptIDs = Set(effective.storedPromptIds ?? [])
            modelPresetName = effective.modelPresetName
        } else {
            // Defaults for new preset
            name = ""
            icon = "💬"
            descriptionText = ""
            mode = .chat
            fileTreeMode = .auto
            codeMapUsage = .auto
            gitInclusion = .none
            selectedStoredPromptIDs = []
            modelPresetName = nil
        }
    }

    private func save() {
        switch editMode {
        case .builtInOverrides:
            saveBuiltInOverrides()
        case .editCustom, .createCustom:
            let updated = ChatPreset(
                id: preset?.id ?? UUID(),
                name: name,
                mode: mode,
                modelPresetName: modelPresetName,
                description: descriptionText.isEmpty ? nil : descriptionText,
                icon: icon.isEmpty ? nil : icon,
                isBuiltIn: preset?.isBuiltIn ?? false,
                fileTreeMode: fileTreeMode,
                codeMapUsage: codeMapUsage,
                gitInclusion: gitInclusion,
                storedPromptIds: selectedStoredPromptIDs.isEmpty ? nil : Array(selectedStoredPromptIDs)
            )
            onSave(updated)
        }
    }

    private func saveBuiltInOverrides() {
        guard let preset,
              preset.isBuiltIn else { return }

        let overrides = ChatPresetOverrides(
            presetID: preset.id,
            modelPresetName: modelPresetName,
            fileTreeMode: fileTreeMode,
            codeMapUsage: codeMapUsage,
            gitInclusion: gitInclusion,
            storedPromptIds: selectedStoredPromptIDs.isEmpty ? nil : Array(selectedStoredPromptIDs),
            updatedAt: Date()
        )

        presetManager.upsertOverrides(overrides)
        dismiss()
    }

    private func resetAllOverrides() {
        guard let preset else { return }
        presetManager.clearOverrides(for: preset.id)
        preload() // Reload to show base values
    }

    private func duplicateBuiltIn() {
        guard let p = preset else { return }
        let baseName = "\(p.name) Copy"
        let newName = presetManager.generateUniqueName(baseName: baseName)
        let clone = ChatPreset(
            name: newName,
            mode: p.mode,
            modelPresetName: p.modelPresetName,
            description: p.description,
            icon: p.icon,
            isBuiltIn: false,
            fileTreeMode: p.fileTreeMode,
            codeMapUsage: p.codeMapUsage,
            gitInclusion: p.gitInclusion,
            storedPromptIds: p.storedPromptIds
        )
        presetManager.addPreset(clone)
        dismiss()
    }
}
