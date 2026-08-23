import Foundation

public struct ProjectSelectionPreset: Codable, Hashable, Sendable {
    public let presetID: UUID
    public let projectID: UUID
    public let name: String
    public let entries: [LogicalSelectionEntry]
    public let order: Int
    public let rowRevision: Int64

    public init(
        presetID: UUID,
        projectID: UUID,
        name: String,
        entries: [LogicalSelectionEntry],
        order: Int,
        rowRevision: Int64
    ) {
        self.presetID = presetID
        self.projectID = projectID
        self.name = name
        self.entries = entries
        self.order = order
        self.rowRevision = rowRevision
    }
}

public struct ProjectSelectionPresetsSnapshot: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let presets: [ProjectSelectionPreset]
    public let revision: Int64
    public let updatedAt: Date

    public init(projectID: UUID, presets: [ProjectSelectionPreset], revision: Int64, updatedAt: Date) {
        self.projectID = projectID
        self.presets = presets
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct ReplaceProjectSelectionPresetsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let presets: [ProjectSelectionPreset]

    public init(expectedRevision: Int64, presets: [ProjectSelectionPreset]) {
        self.expectedRevision = expectedRevision
        self.presets = presets
    }
}

public struct CreateProjectSelectionPresetRequest: Codable, Hashable, Sendable {
    public let expectedCollectionRevision: Int64
    public let name: String
    public let entries: [LogicalSelectionEntry]

    public init(expectedCollectionRevision: Int64, name: String, entries: [LogicalSelectionEntry]) {
        self.expectedCollectionRevision = expectedCollectionRevision
        self.name = name
        self.entries = entries
    }
}

public struct UpdateProjectSelectionPresetRequest: Codable, Hashable, Sendable {
    public let expectedCollectionRevision: Int64
    public let expectedRowRevision: Int64
    public let name: String
    public let entries: [LogicalSelectionEntry]

    public init(expectedCollectionRevision: Int64, expectedRowRevision: Int64, name: String, entries: [LogicalSelectionEntry]) {
        self.expectedCollectionRevision = expectedCollectionRevision
        self.expectedRowRevision = expectedRowRevision
        self.name = name
        self.entries = entries
    }
}

public struct DeleteProjectSelectionPresetRequest: Codable, Hashable, Sendable {
    public let expectedCollectionRevision: Int64
    public let expectedRowRevision: Int64

    public init(expectedCollectionRevision: Int64, expectedRowRevision: Int64) {
        self.expectedCollectionRevision = expectedCollectionRevision
        self.expectedRowRevision = expectedRowRevision
    }
}

public struct ReorderProjectSelectionPresetsRequest: Codable, Hashable, Sendable {
    public let expectedCollectionRevision: Int64
    public let orderedPresetIDs: [UUID]

    public init(expectedCollectionRevision: Int64, orderedPresetIDs: [UUID]) {
        self.expectedCollectionRevision = expectedCollectionRevision
        self.orderedPresetIDs = orderedPresetIDs
    }
}

public struct CaptureProjectSelectionPresetRequest: Codable, Hashable, Sendable {
    public let expectedCollectionRevision: Int64
    public let sessionID: UUID
    public let expectedSelectionRevision: Int64
    public let name: String

    public init(expectedCollectionRevision: Int64, sessionID: UUID, expectedSelectionRevision: Int64, name: String) {
        self.expectedCollectionRevision = expectedCollectionRevision
        self.sessionID = sessionID
        self.expectedSelectionRevision = expectedSelectionRevision
        self.name = name
    }
}

public struct ApplyProjectSelectionPresetRequest: Codable, Hashable, Sendable {
    public let presetID: UUID
    public let expectedCollectionRevision: Int64
    public let sessionID: UUID
    public let expectedSelectionRevision: Int64

    public init(presetID: UUID, expectedCollectionRevision: Int64, sessionID: UUID, expectedSelectionRevision: Int64) {
        self.presetID = presetID
        self.expectedCollectionRevision = expectedCollectionRevision
        self.sessionID = sessionID
        self.expectedSelectionRevision = expectedSelectionRevision
    }
}
