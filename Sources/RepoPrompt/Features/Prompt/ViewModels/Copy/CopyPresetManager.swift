import Foundation
import SwiftUI

/// Manager for copy presets - handles both built-in and user-defined presets
@MainActor
class CopyPresetManager: ObservableObject {
    // MARK: - Singleton

    static let shared = CopyPresetManager()

    // MARK: - Published Properties

    @Published private(set) var userPresets: [CopyPreset] = [] {
        didSet {
            rebuildAllPresetsCache()
        }
    }

    @Published private var presetVisibility: [UUID: Bool] = [:]
    @Published private(set) var overrides: [UUID: CopyPresetOverrides] = [:] {
        didSet {
            rebuildAllPresetsCache()
        }
    }

    @Published private(set) var persistenceErrorMessage: String?

    // MARK: - Storage

    private let presetFileStore: PresetFileStore

    /// All presets (built-in + user), with overrides applied to built-ins
    @Published private(set) var allPresets: [CopyPreset] = []

    // MARK: - Initialization

    init(presetFileStore: PresetFileStore = .shared) {
        self.presetFileStore = presetFileStore
        load()
        rebuildAllPresetsCache()
    }

    // MARK: - Built-in Presets

    /// All built-in presets
    var builtInPresets: [CopyPreset] {
        BuiltInCopyPresets.all
    }

    private func rebuildAllPresetsCache() {
        let overridesSnapshot = overrides
        let resolvedBuiltIns = builtInPresets.map { preset -> CopyPreset in
            guard let override = overridesSnapshot[preset.id] else { return preset }
            return apply(overrides: override, to: preset)
        }
        allPresets = resolvedBuiltIns + userPresets
    }

    // MARK: - Preset Lookup

    /// Find any preset by ID (built-in or user)
    func preset(with id: UUID) -> CopyPreset? {
        allPresets.first { $0.id == id }
    }

    /// Find a built-in preset by kind
    func builtInPreset(for kind: CopyPresetKind) -> CopyPreset? {
        BuiltInCopyPresets.preset(for: kind)
    }

    // MARK: - User Preset Management

    /// Load user presets, visibility, and built-in overrides from Application Support JSON.
    func load() {
        let document = presetFileStore.loadWorkflowPresets()
        userPresets = document.copyUserPresets
        presetVisibility = document.copyVisibility
        let currentBuiltInIDs = Set(BuiltInCopyPresets.all.map(\.id))
        overrides = Dictionary(
            document.copyOverrides.filter { currentBuiltInIDs.contains($0.presetID) }.map { ($0.presetID, $0) },
            uniquingKeysWith: { _, new in new }
        )
    }

    /// Add a new user preset
    func add(_ preset: CopyPreset) {
        guard !preset.isBuiltIn else {
            print("Cannot add built-in preset as user preset")
            return
        }
        mutateAndPersist {
            userPresets.append(preset)
        }
    }

    /// Update an existing user preset
    func update(_ preset: CopyPreset) {
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
    func remove(_ preset: CopyPreset) {
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
    func addPreset(_ preset: CopyPreset) {
        add(preset)
    }

    /// Update a preset (convenience method matching the settings view)
    func updatePreset(_ preset: CopyPreset) {
        update(preset)
    }

    /// Delete a preset (convenience method matching the settings view)
    func deletePreset(_ preset: CopyPreset) {
        remove(preset)
    }

    /// Toggle preset visibility
    func togglePresetVisibility(_ preset: CopyPreset) {
        mutateAndPersist {
            let currentVisibility = presetVisibility[preset.id] ?? true
            presetVisibility[preset.id] = !currentVisibility
        }
    }

    /// Check if a preset is visible
    func isPresetVisible(_ preset: CopyPreset) -> Bool {
        presetVisibility[preset.id] ?? true
    }

    /// Load visibility settings from Application Support JSON.
    private func loadVisibility() {
        presetVisibility = presetFileStore.loadWorkflowPresets().copyVisibility
    }

    /// Create a preset from current settings
    func createPresetFromSettings(
        name: String,
        description: String? = nil,
        icon: String? = nil,
        includeFiles: Bool,
        includeUserPrompt: Bool,
        includeMetaPrompts: Bool,
        includeFileTree: Bool,
        fileTreeMode: FileTreeOption,
        codeMapUsage: CodeMapUsage,
        gitInclusion: GitInclusion
    ) -> CopyPreset {
        let preset = CopyPreset(
            name: name,
            description: description,
            icon: icon,
            isBuiltIn: false,
            includeFiles: includeFiles,
            includeUserPrompt: includeUserPrompt,
            includeMetaPrompts: includeMetaPrompts,
            includeFileTree: includeFileTree,
            fileTreeMode: fileTreeMode,
            codeMapUsage: codeMapUsage,
            gitInclusion: gitInclusion
        )

        add(preset)
        return preset
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

    // MARK: - Override Management

    /// Check if a preset has overrides
    func hasOverrides(_ id: UUID) -> Bool {
        overrides[id] != nil && !overrides[id]!.isEmpty
    }

    /// Get overrides for a preset
    func getOverrides(_ id: UUID) -> CopyPresetOverrides? {
        overrides[id]
    }

    /// Update or insert overrides for a preset
    func upsertOverrides(_ override: CopyPresetOverrides) {
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
    func updateOverrides(for id: UUID, mutate: (inout CopyPresetOverrides) -> Void) {
        var override = overrides[id] ?? CopyPresetOverrides.empty(for: id)
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
    func resolvedPreset(with id: UUID) -> CopyPreset? {
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
    private func apply(overrides: CopyPresetOverrides, to base: CopyPreset) -> CopyPreset {
        // Create a new preset with overrides applied
        CopyPreset(
            id: base.id,
            name: base.name,
            builtInKind: base.builtInKind,
            description: base.description,
            icon: base.icon,
            isBuiltIn: base.isBuiltIn,
            includeFiles: overrides.includeFiles ?? base.includeFiles,
            includeUserPrompt: overrides.includeUserPrompt ?? base.includeUserPrompt,
            includeMetaPrompts: overrides.includeMetaPrompts ?? base.includeMetaPrompts,
            includeFileTree: overrides.includeFileTree ?? base.includeFileTree,
            fileTreeMode: overrides.fileTreeMode ?? base.fileTreeMode,
            codeMapUsage: overrides.codeMapUsage ?? base.codeMapUsage,
            gitInclusion: overrides.gitInclusion ?? base.gitInclusion,
            storedPromptIds: overrides.storedPromptIds ?? base.storedPromptIds,
            notes: base.notes
        )
    }

    /// Load overrides from Application Support JSON.
    private func loadOverrides() {
        let overridesList = presetFileStore.loadWorkflowPresets().copyOverrides
        let currentBuiltInIDs = Set(BuiltInCopyPresets.all.map(\.id))
        overrides = Dictionary(
            overridesList.filter { currentBuiltInIDs.contains($0.presetID) }.map { ($0.presetID, $0) },
            uniquingKeysWith: { _, new in new }
        )
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
            try persistCopyState()
            persistenceErrorMessage = nil
        } catch {
            userPresets = previousUserPresets
            presetVisibility = previousVisibility
            overrides = previousOverrides
            reportPersistenceFailure(error)
        }
    }

    private func persistCopyState() throws {
        let overridesList = Array(overrides.values)
        try presetFileStore.updateWorkflowPresets { document in
            document.copyUserPresets = userPresets
            document.copyVisibility = presetVisibility
            document.copyOverrides = overridesList
        }
    }

    private func reportPersistenceFailure(_ error: Error) {
        persistenceErrorMessage = "Your copy preset change wasn't saved and has been reverted. \(error.localizedDescription)"
    }
}
