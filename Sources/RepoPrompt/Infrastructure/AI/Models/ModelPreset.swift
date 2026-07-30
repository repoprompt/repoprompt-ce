import Foundation

// MARK: - ModelPreset

/// Represents a user-defined model preset with optional mode restrictions.
/// Legacy mode override options preserved for decoding old preset files.
enum ProEditingOverride: String, Codable {
    case useDefault = "default"
    case forceOn = "on"
    case forceOff = "off"
}

struct ModelPreset: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let modelString: String // Store as string for Codable
    let description: String?
    let supportedModes: SupportedModes?
    let proEditingOverride: ProEditingOverride // Legacy decode-only field
    let chatPresetMappings: ChatPresetMappings? // Maps modes to chat preset IDs

    /// Returns the resolved AIModel, or `.claude4Sonnet` as a fallback if the stored rawValue can't be parsed.
    /// For cases where you need to handle missing models differently, use `optionalModel` instead.
    var model: AIModel {
        AIModel.fromModelName(modelString) ?? .claude4Sonnet
    }

    /// Returns the resolved AIModel, or `nil` if the stored rawValue can't be parsed.
    /// Use this when you want to handle missing/renamed models explicitly rather than falling back silently.
    var optionalModel: AIModel? {
        AIModel.fromModelName(modelString)
    }

    /// Returns `true` if the stored modelString can be resolved to a valid AIModel.
    /// Use this to check if the preset's model is still valid after model definitions may have changed.
    var isModelResolvable: Bool {
        AIModel.fromModelName(modelString) != nil
    }

    init(id: UUID = UUID(), name: String, model: AIModel, description: String? = nil, supportedModes: SupportedModes? = nil, proEditingOverride: ProEditingOverride = .useDefault, chatPresetMappings: ChatPresetMappings? = nil) {
        self.id = id
        self.name = Self.sanitizeName(name)
        modelString = model.rawValue
        self.description = description
        self.supportedModes = supportedModes
        self.proEditingOverride = proEditingOverride
        self.chatPresetMappings = chatPresetMappings
    }

    /// Custom decoding to handle missing fields in existing presets
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        modelString = try container.decode(String.self, forKey: .modelString)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        supportedModes = try container.decodeIfPresent(SupportedModes.self, forKey: .supportedModes)
        // Default to .useDefault if not present (for backward compatibility)
        proEditingOverride = try container.decodeIfPresent(ProEditingOverride.self, forKey: .proEditingOverride) ?? .useDefault
        // Default to nil if not present (for backward compatibility)
        chatPresetMappings = try container.decodeIfPresent(ChatPresetMappings.self, forKey: .chatPresetMappings)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(modelString, forKey: .modelString)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(supportedModes, forKey: .supportedModes)
        try container.encodeIfPresent(chatPresetMappings, forKey: .chatPresetMappings)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, modelString, description, supportedModes, proEditingOverride, chatPresetMappings
    }

    /// Sanitizes a preset name to ensure it's valid for command-line use
    static func sanitizeName(_ name: String) -> String {
        // Remove leading/trailing whitespace
        var sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Replace spaces and special characters with underscores
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        sanitized = sanitized.unicodeScalars
            .map { allowedCharacters.contains($0) ? String($0) : "_" }
            .joined()

        // Remove consecutive underscores
        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }

        // Ensure it starts with alphanumeric
        if let first = sanitized.first, !first.isLetter, !first.isNumber {
            sanitized = "preset_" + sanitized
        }

        // Limit length
        let maxLength = 30
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength))
        }

        // Ensure non-empty
        if sanitized.isEmpty {
            sanitized = "preset_\(UUID().uuidString.prefix(8))"
        }

        return sanitized
    }

    /// Validates if a name is acceptable for a preset
    static func validateName(_ name: String) -> (isValid: Bool, error: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return (false, "Name cannot be empty")
        }

        if trimmed.count > 30 {
            return (false, "Name must be 30 characters or less")
        }

        // Check for whitespace
        if trimmed.contains(" ") || trimmed.contains("\t") || trimmed.contains("\n") {
            return (false, "Name cannot contain spaces or tabs")
        }

        // Check for allowed characters
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let nameCharacters = CharacterSet(charactersIn: trimmed)
        if !allowedCharacters.isSuperset(of: nameCharacters) {
            return (false, "Name can only contain letters, numbers, underscores, and hyphens")
        }

        // Check first character
        if let first = trimmed.first, !first.isLetter, !first.isNumber {
            return (false, "Name must start with a letter or number")
        }

        return (true, nil)
    }

    /// Convenience initializer from current chat model
    static func fromCurrentChatModel(modelRawString: String) -> ModelPreset {
        let model = AIModel.fromModelName(modelRawString) ?? .claude4Sonnet
        return ModelPreset(
            name: "Default",
            model: model,
            description: "Current chat model",
            supportedModes: nil, // No restrictions by default
            proEditingOverride: .useDefault,
            chatPresetMappings: nil
        )
    }

    /// Finds the best matching preset name from available options using fuzzy matching
    static func findBestMatch(_ requested: String, among availableNames: [String]) -> String? {
        let trimmedReq = requested.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Exact match
        if availableNames.contains(trimmedReq) {
            return trimmedReq
        }

        // 2) Case-insensitive exact match
        let reqLower = trimmedReq.lowercased()
        if let match = availableNames.first(where: { $0.lowercased() == reqLower }) {
            return match
        }

        // 3) Prefix match (case-insensitive)
        if let match = availableNames.first(where: { $0.lowercased().hasPrefix(reqLower) }) {
            return match
        }

        // 4) Contains match (case-insensitive)
        if let match = availableNames.first(where: { $0.lowercased().contains(reqLower) }) {
            return match
        }

        // 5) Fuzzy similarity using Dice coefficient
        var bestCandidate: String?
        var bestScore = 0.0
        let threshold = 0.6 // Lower threshold for model names

        for candidate in availableNames {
            // Use dice coefficient for fuzzy matching
            let score = trimmedReq.lowercased().diceCoefficient(against: candidate.lowercased())
            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }

        if let match = bestCandidate, bestScore >= threshold {
            return match
        }

        // 6) Levenshtein distance for very close matches
        if trimmedReq.count >= 3 { // Only for non-trivial strings
            for candidate in availableNames {
                let distance = trimmedReq.lowercased().levenshteinDistance(to: candidate.lowercased())
                let maxLen = max(trimmedReq.count, candidate.count)
                let similarity = 1.0 - Double(distance) / Double(maxLen)

                if similarity >= 0.8 { // 80% similarity threshold
                    return candidate
                }
            }
        }

        return nil
    }
}

// MARK: - SupportedModes

/// Defines which modes a model preset supports
struct SupportedModes: Codable, Equatable {
    let chat: Bool
    let plan: Bool
    let edit: Bool
    let review: Bool

    init(chat: Bool = true, plan: Bool = true, edit: Bool = false, review: Bool = true) {
        self.chat = chat
        self.plan = plan
        self.edit = edit
        self.review = review
    }

    private enum CodingKeys: String, CodingKey {
        case chat, plan, edit, review
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chat, forKey: .chat)
        try container.encode(plan, forKey: .plan)
        try container.encode(review, forKey: .review)
    }

    /// Custom decoder for backward compatibility when new modes are added
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Default missing keys to true for backward compatibility
        chat = try container.decodeIfPresent(Bool.self, forKey: .chat) ?? true
        plan = try container.decodeIfPresent(Bool.self, forKey: .plan) ?? true
        // Legacy Oracle edit support is decode-only; old presets with edit=true load safely but are not surfaced as active modes.
        edit = try container.decodeIfPresent(Bool.self, forKey: .edit) ?? false
        review = try container.decodeIfPresent(Bool.self, forKey: .review) ?? true
    }

    /// Returns true if at least one mode is enabled
    var hasEnabledModes: Bool {
        chat || plan || review
    }

    /// Returns a user-friendly string describing the enabled modes
    var displayString: String {
        var modes: [String] = []
        if chat {
            modes.append("Chat")
        }
        if plan {
            modes.append("Plan")
        }
        if review {
            modes.append("Review")
        }

        if modes.isEmpty {
            return "No modes enabled"
        } else if modes.count == 3 {
            return "All modes"
        } else {
            return modes.joined(separator: ", ")
        }
    }
}

// MARK: - ChatPresetMappings

/// Maps each mode to a specific chat preset ID
struct ChatPresetMappings: Codable, Equatable {
    var chatPresetID: UUID?
    var planPresetID: UUID?
    var editPresetID: UUID?
    var reviewPresetID: UUID?

    init(chatPresetID: UUID? = nil, planPresetID: UUID? = nil, editPresetID: UUID? = nil, reviewPresetID: UUID? = nil) {
        self.chatPresetID = chatPresetID
        self.planPresetID = planPresetID
        self.editPresetID = editPresetID
        self.reviewPresetID = reviewPresetID
    }

    private enum CodingKeys: String, CodingKey {
        case chatPresetID, planPresetID, editPresetID, reviewPresetID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(chatPresetID, forKey: .chatPresetID)
        try container.encodeIfPresent(planPresetID, forKey: .planPresetID)
        try container.encodeIfPresent(reviewPresetID, forKey: .reviewPresetID)
    }

    /// Custom decoder for backward compatibility when new mappings are added
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatPresetID = try container.decodeIfPresent(UUID.self, forKey: .chatPresetID)
        planPresetID = try container.decodeIfPresent(UUID.self, forKey: .planPresetID)
        editPresetID = try container.decodeIfPresent(UUID.self, forKey: .editPresetID)
        reviewPresetID = try container.decodeIfPresent(UUID.self, forKey: .reviewPresetID)
    }

    /// Get the chat preset ID for a specific mode
    func presetID(for mode: String) -> UUID? {
        switch mode.lowercased() {
        case "chat": chatPresetID
        case "plan": planPresetID
        case "review": reviewPresetID
        default: nil
        }
    }

    /// Set the chat preset ID for a specific mode
    mutating func setPresetID(_ id: UUID?, for mode: String) {
        switch mode.lowercased() {
        case "chat": chatPresetID = id
        case "plan": planPresetID = id
        case "review": reviewPresetID = id
        default: break
        }
    }
}

// MARK: - ModelPresetsManager

/// Manages storage and retrieval of model presets
@MainActor
class ModelPresetsManager: ObservableObject {
    static let shared = ModelPresetsManager()

    private let presetFileStore = PresetFileStore.shared

    @Published var presets: [ModelPreset] = []

    private init() {
        loadPresets()
    }

    /// Loads presets from Application Support JSON.
    private func loadPresets() {
        presets = presetFileStore.loadModelPresets().modelPresets
    }

    /// Saves presets to Application Support JSON.
    private func savePresets() {
        presetFileStore.saveModelPresets(
            PresetFileStore.ModelPresetDocument(modelPresets: presets)
        )
    }

    /// Adds a new preset
    func addPreset(_ preset: ModelPreset) {
        presets.append(preset)
        savePresets()
    }

    /// Updates an existing preset
    func updatePreset(_ preset: ModelPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
            savePresets()
        }
    }

    /// Removes a preset
    func removePreset(_ preset: ModelPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    /// Removes presets at the specified offsets
    func removePresets(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        savePresets()
    }

    /// Moves presets for reordering
    func movePresets(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        savePresets()
    }

    /// Returns available presets for a specific mode
    func availablePresets(for mode: String) -> [ModelPreset] {
        presets.filteredForMode(mode)
    }

    /// Returns a preset by name (case-insensitive)
    func preset(named name: String) -> ModelPreset? {
        presets.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Returns a preset by ID
    func preset(withID id: UUID) -> ModelPreset? {
        presets.first { $0.id == id }
    }

    /// Returns a thread-safe copy of all presets
    /// Since ModelPreset is Sendable, this array can be safely passed across actor boundaries
    func allPresets() -> [ModelPreset] {
        // Returns a copy of the array, safe to use across actors
        presets
    }

    /// Returns a thread-safe copy of presets available for a specific mode
    func getAvailablePresets(for mode: String) -> [ModelPreset] {
        availablePresets(for: mode)
    }
}
