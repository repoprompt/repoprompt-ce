import Foundation

struct HeadlessWorkspaceDocument: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var rootIDs: [UUID]
    var promptText: String
    var selection: [HeadlessSelectionEntry]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, rootIDs: [UUID], now: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.rootIDs = rootIDs
        promptText = ""
        selection = []
        createdAt = now
        updatedAt = now
    }

    mutating func touch(now: Date = Date()) {
        updatedAt = now
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case name
        case rootIDs = "root_ids"
        case promptText = "prompt_text"
        case selection
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum HeadlessSelectionMode: String, Codable, CaseIterable {
    case full
    case slices
    case codemapOnly = "codemap_only"
}

struct HeadlessLineRange: Codable, Equatable {
    var startLine: Int
    var endLine: Int
    var description: String?

    init(startLine: Int, endLine: Int, description: String? = nil) {
        self.startLine = startLine
        self.endLine = endLine
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case startLine = "start_line"
        case endLine = "end_line"
        case description
    }
}

struct HeadlessSelectionEntry: Codable, Equatable {
    var rootID: UUID
    var relativePath: String
    var mode: HeadlessSelectionMode
    var ranges: [HeadlessLineRange]

    init(rootID: UUID, relativePath: String, mode: HeadlessSelectionMode, ranges: [HeadlessLineRange] = []) {
        self.rootID = rootID
        self.relativePath = relativePath
        self.mode = mode
        self.ranges = ranges
    }

    enum CodingKeys: String, CodingKey {
        case rootID = "root_id"
        case relativePath = "relative_path"
        case mode
        case ranges
    }
}

enum HeadlessSelectionNormalizer {
    static func normalized(_ selection: [HeadlessSelectionEntry]) -> [HeadlessSelectionEntry] {
        var result: [HeadlessSelectionEntry] = []
        for entry in selection {
            var sanitized = entry
            switch sanitized.mode {
            case .slices:
                sanitized.ranges = normalizedRanges(sanitized.ranges)
                guard !sanitized.ranges.isEmpty else { continue }
            case .full, .codemapOnly:
                sanitized.ranges = []
            }

            if let index = result.firstIndex(where: {
                $0.rootID == sanitized.rootID && $0.relativePath == sanitized.relativePath
            }) {
                result[index] = sanitized
            } else {
                result.append(sanitized)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.rootID == rhs.rootID {
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
            return lhs.rootID.uuidString < rhs.rootID.uuidString
        }
    }

    static func subtracting(
        _ removals: [HeadlessLineRange],
        from ranges: [HeadlessLineRange]
    ) -> [HeadlessLineRange] {
        var remaining = normalizedRanges(ranges)
        for removal in normalizedRanges(removals) {
            remaining = remaining.flatMap { range in
                guard removal.endLine >= range.startLine, removal.startLine <= range.endLine else {
                    return [range]
                }

                var residuals: [HeadlessLineRange] = []
                if removal.startLine > range.startLine {
                    residuals.append(HeadlessLineRange(
                        startLine: range.startLine,
                        endLine: removal.startLine - 1,
                        description: range.description
                    ))
                }
                if removal.endLine < range.endLine {
                    residuals.append(HeadlessLineRange(
                        startLine: removal.endLine + 1,
                        endLine: range.endLine,
                        description: range.description
                    ))
                }
                return residuals
            }
        }
        return normalizedRanges(remaining)
    }

    static func normalizedRanges(_ ranges: [HeadlessLineRange]) -> [HeadlessLineRange] {
        ranges
            .filter { $0.startLine > 0 && $0.endLine >= $0.startLine }
            .sorted { lhs, rhs in
                if lhs.startLine != rhs.startLine {
                    return lhs.startLine < rhs.startLine
                }
                return lhs.endLine < rhs.endLine
            }
    }
}

struct HeadlessWorkspaceSnapshot {
    var config: HeadlessConfigurationDocument
    var workspace: HeadlessWorkspaceDocument?
    var roots: [HeadlessAllowedRoot]
}

struct HeadlessResolvedPath {
    var root: HeadlessAllowedRoot
    var url: URL
    var resolvedURL: URL
    var relativePath: String
    var displayPath: String
    var isDirectory: Bool
    var isRegularFile: Bool
}

struct HeadlessCatalogEntry {
    var root: HeadlessAllowedRoot
    var url: URL
    var resolvedURL: URL
    var relativePath: String
    var displayPath: String
    var isDirectory: Bool
    var byteCount: Int64?
}
