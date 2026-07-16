import Foundation

/// Test-only compatibility codec frozen from RepoPrompt CE annotated tag v1.0.28
/// (`65d473858d7a140dc82364f4b359482d6dc5ce80`), peeled commit
/// `1b185f74e72af3000550796b3d1d7476d244e546`.
///
/// The production implementation at that tag used exactly these seven root fields and always
/// stamped schema v2 plus the CE lineage on save. JSONValue deliberately keeps this boundary
/// independent of today's production settings models.
struct FrozenV1028GlobalSettingsDocument: Codable, Equatable {
    static let schemaVersion = 2
    static let schemaLineage = "repoprompt-ce.global-settings"

    var schemaVersion: Int
    var schemaLineage: String?
    var updatedAt: Date
    var copySettingsByWorkspaceID: [String: FrozenV1028JSONValue]
    var chatSettingsByWorkspaceID: [String: FrozenV1028JSONValue]
    var globalDefaults: FrozenV1028JSONValue
    var scalarPreferences: FrozenV1028JSONValue?

    static func load(from url: URL) throws -> Self {
        let document = try decoder.decode(Self.self, from: Data(contentsOf: url))
        if document.schemaLineage == Self.schemaLineage,
           document.schemaVersion > Self.schemaVersion
        {
            throw CompatibilityError.unsupportedFutureSchema(document.schemaVersion)
        }
        return document
    }

    mutating func setAppearanceMode(_ mode: String) {
        var scalar = scalarPreferences?.objectValue ?? [:]
        var ui = scalar["ui"]?.objectValue ?? [:]
        ui["appearanceMode"] = .string(mode)
        scalar["ui"] = .object(ui)
        scalarPreferences = .object(scalar)
    }

    mutating func save(to url: URL, now: Date) throws {
        schemaVersion = Self.schemaVersion
        schemaLineage = Self.schemaLineage
        updatedAt = now
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    enum CompatibilityError: Error, Equatable {
        case unsupportedFutureSchema(Int)
    }
}

enum FrozenV1028JSONValue: Codable, Equatable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var objectValue: [String: Self]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = try .string(container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
