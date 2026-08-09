import Foundation
import SwiftUI

/// Manager for chat presets - handles both built-in and user-defined chat presets
@MainActor
class ChatPresetManager: ObservableObject {
    // MARK: - Singleton

    static let shared = ChatPresetManager()

    // MARK: - Published Properties

    @Published private(set) var userPresets: [ChatPreset] = [] {
        didSet {
            rebuildAllPresetsCache()
        }
    }

    @Published private var presetVisibility: [UUID: Bool] = [:]
    @Published private(set) var overrides: [UUID: ChatPresetOverrides] = [:] {
        didSet {
            rebuildAllPresetsCache()
        }
    }

    @Published private(set) var persistenceErrorMessage: String?

    // MARK: - Storage

    private let presetFileStore: PresetFileStore

    /// All presets (built-in + user), with overrides applied to built-ins
    @Published private(set) var allPresets: [ChatPreset] = []

    // MARK: - Initialization

    init(presetFileStore: PresetFileStore = .shared) {
        self.presetFileStore = presetFileStore
        load()
        rebuildAllPresetsCache()
    }

    // MARK: - Built-in Presets

    /// All built-in chat presets
    var builtInPresets: [ChatPreset] {
        ChatPreset.BuiltIn.all()
    }

    private func rebuildAllPresetsCache() {
        let overridesSnapshot = overrides
        let resolvedBuiltIns = builtInPresets.map { preset -> ChatPreset in
            guard let override = overridesSnapshot[preset.id] else { return preset }
            return apply(overrides: override, to: preset)
        }
        allPresets = resolvedBuiltIns + userPresets
    }

    // MARK: - Preset Lookup

    /// Find any preset by ID (built-in or user)
    func preset(with id: UUID) -> ChatPreset? {
        allPresets.first { $0.id == id }
    }

    /// Find presets by mode
    func presets(for mode: ChatPresetMode) -> [ChatPreset] {
        allPresets.filter { $0.mode == mode }
    }

    // No linkage to copy presets from chat presets

    // MARK: - User Preset Management

    /// Load user presets, visibility, and built-in overrides from Application Support JSON.
    func load() {
        let document = presetFileStore.loadWorkflowPresets()
        userPresets = document.chatUserPresets
        presetVisibility = document.chatVisibility
        overrides = Dictionary(document.chatOverrides.map { ($0.presetID, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Add a new user preset
    func add(_ preset: ChatPreset) {
        guard !preset.isBuiltIn else {
            print("Cannot add built-in preset as user preset")
            return
        }
        mutateAndPersist {
            userPresets.append(preset)
        }
    }

    /// Update an existing user preset
    func update(_ preset: ChatPreset) {
        guard !preset.isBuiltIn else {
            print("Cannot update built-in preset")
            return
        }

        if let index = userPresets.firstIndex(where: { $0.id == preset.id }) {
            mutateAndPersist {
                userPresets[index] = preset
            }
        }
    }

    /// Remove a user preset
    func remove(_ preset: ChatPreset) {
        guard !preset.isBuiltIn else {
            print("Cannot remove built-in preset")
            return
        }

        mutateAndPersist {
            userPresets.removeAll { $0.id == preset.id }
        }
    }

    /// Remove a user preset by ID
    func remove(id: UUID) {
        mutateAndPersist {
            userPresets.removeAll { $0.id == id }
        }
    }

    /// Add a preset (convenience method matching the settings view)
    func addPreset(_ preset: ChatPreset) {
        add(preset)
    }

    /// Update a preset (convenience method matching the settings view)
    func updatePreset(_ preset: ChatPreset) {
        update(preset)
    }

    /// Delete a preset (convenience method matching the settings view)
    func deletePreset(_ preset: ChatPreset) {
        remove(preset)
    }

    /// Toggle preset visibility
    func togglePresetVisibility(_ preset: ChatPreset) {
        mutateAndPersist {
            let currentVisibility = presetVisibility[preset.id] ?? true
            presetVisibility[preset.id] = !currentVisibility
        }
    }

    /// Check if a preset is visible
    func isPresetVisible(_ preset: ChatPreset) -> Bool {
        presetVisibility[preset.id] ?? true
    }

    /// Load visibility settings from Application Support JSON.
    private func loadVisibility() {
        presetVisibility = presetFileStore.loadWorkflowPresets().chatVisibility
    }

    /// Create a chat preset from current settings
    func createPresetFromSettings(
        name: String,
        mode: ChatPresetMode,
        modelPresetName: String? = nil,
        description: String? = nil,
        icon: String? = nil
    ) -> ChatPreset {
        let preset = ChatPreset(
            name: name,
            mode: mode,
            modelPresetName: modelPresetName,
            description: description,
            icon: icon,
            isBuiltIn: false
        )

        add(preset)
        return preset
    }

    // MARK: - Default Preset Selection

    /// Get the default preset for a given mode
    func defaultPreset(for mode: ChatPresetMode) -> ChatPreset? {
        // First try to find a built-in preset for this mode
        switch mode {
        case .chat:
            builtInPresets.first { $0.name == "Chat" }
        case .plan:
            builtInPresets.first { $0.name == "Plan" }
        case .review:
            builtInPresets.first { $0.name == "Review" }
        }
    }

    /// Get a suggested preset based on context
    func suggestedPreset(hasGitChanges: Bool, fileCount: Int, hasXMLContent: Bool) -> ChatPreset? {
        // If there are git changes, suggest review
        if hasGitChanges {
            return builtInPresets.first { $0.name == "Review" }
        }

        // XML content no longer switches Oracle into edit mode; keep Chat unless another read-only mode fits.
        // If many files, suggest planning
        if fileCount > 10 {
            return builtInPresets.first { $0.name == "Plan" }
        }

        // Default to chat
        return builtInPresets.first { $0.name == "Chat" }
    }

    // MARK: - Validation

    /// Check if a preset name is already in use
    func isNameTaken(_ name: String, excluding: UUID? = nil) -> Bool {
        allPresets.contains { preset in
            preset.name == name && preset.id != excluding
        }
    }

    /// Generate a unique name based on a base name
    func generateUniqueName(baseName: String) -> String {
        var name = baseName
        var counter = 1

        while isNameTaken(name) {
            name = "\(baseName) \(counter)"
            counter += 1
        }

        return name
    }

    // MARK: - Model Preset Integration

    /// Validate that a chat preset's model reference is valid
    /// This will need to be connected to ModelPresetsManager when available
    func validateModelReference(for preset: ChatPreset) -> Bool {
        // TODO: Check against ModelPresetsManager
        // For now, return true if no model specified (use default)
        preset.modelPresetName == nil || !preset.modelPresetName!.isEmpty
    }

    // MARK: - Copy Preset Integration

    // Removed: chat presets no longer reference copy presets

    // MARK: - Override Management

    /// Check if a preset has overrides
    func hasOverrides(_ id: UUID) -> Bool {
        overrides[id] != nil && !overrides[id]!.isEmpty
    }

    /// Get overrides for a preset
    func getOverrides(_ id: UUID) -> ChatPresetOverrides? {
        overrides[id]
    }

    /// Update or insert overrides for a preset
    func upsertOverrides(_ override: ChatPresetOverrides) {
        guard let base = builtInPresets.first(where: { $0.id == override.presetID }) else { return }

        let trimmed = override.trimmed(against: base)
        if trimmed.isEmpty {
            clearOverrides(for: override.presetID)
        } else {
            mutateAndPersist {
                overrides[override.presetID] = trimmed
            }
        }
    }

    /// Update overrides using a mutation closure
    func updateOverrides(for id: UUID, mutate: (inout ChatPresetOverrides) -> Void) {
        var override = overrides[id] ?? ChatPresetOverrides.empty(for: id)
        mutate(&override)
        upsertOverrides(override)
    }

    /// Clear all overrides for a preset
    func clearOverrides(for id: UUID) {
        mutateAndPersist {
            overrides.removeValue(forKey: id)
        }
    }

    /// Get a resolved preset with overrides applied
    func resolvedPreset(with id: UUID) -> ChatPreset? {
        // Check built-in presets first
        if let builtIn = builtInPresets.first(where: { $0.id == id }) {
            if let override = overrides[id] {
                return apply(overrides: override, to: builtIn)
            }
            return builtIn
        }

        // Then check user presets
        return userPresets.first(where: { $0.id == id })
    }

    /// Apply overrides to a base preset
    private func apply(overrides: ChatPresetOverrides, to base: ChatPreset) -> ChatPreset {
        // Create a new preset with overrides applied
        ChatPreset(
            id: base.id,
            name: base.name,
            mode: base.mode,
            modelPresetName: overrides.modelPresetName ?? base.modelPresetName,
            description: base.description,
            icon: base.icon,
            isBuiltIn: base.isBuiltIn,
            fileTreeMode: overrides.fileTreeMode ?? base.fileTreeMode,
            codeMapUsage: overrides.codeMapUsage ?? base.codeMapUsage,
            gitInclusion: overrides.gitInclusion ?? base.gitInclusion,
            storedPromptIds: overrides.storedPromptIds ?? base.storedPromptIds,
            useStoredPromptsAsSystem: overrides.useStoredPromptsAsSystem ?? base.useStoredPromptsAsSystem
        )
    }

    /// Load overrides from Application Support JSON.
    private func loadOverrides() {
        let overridesList = presetFileStore.loadWorkflowPresets().chatOverrides
        overrides = Dictionary(overridesList.map { ($0.presetID, $0) }, uniquingKeysWith: { _, new in new })
    }

    func clearPersistenceError() {
        persistenceErrorMessage = nil
    }

    private func mutateAndPersist(_ mutation: () -> Void) {
        let previousUserPresets = userPresets
        let previousVisibility = presetVisibility
        let previousOverrides = overrides
        mutation()

        do {
            try persistChatState()
            persistenceErrorMessage = nil
        } catch {
            userPresets = previousUserPresets
            presetVisibility = previousVisibility
            overrides = previousOverrides
            reportPersistenceFailure(error)
        }
    }

    private func persistChatState() throws {
        let overridesList = Array(overrides.values)
        try presetFileStore.updateWorkflowPresets { document in
            document.chatUserPresets = userPresets
            document.chatVisibility = presetVisibility
            document.chatOverrides = overridesList
        }
    }

    private func reportPersistenceFailure(_ error: Error) {
        persistenceErrorMessage = "Your chat preset change wasn't saved and has been reverted. \(error.localizedDescription)"
    }
}
