import Foundation

package struct FileChange: Identifiable, Equatable, Codable {
    package let id: UUID
    package let description: String
    package var startLine: Int
    package var diffChunk: DiffChunk
    package static let dummy = FileChange(id: UUID(), startLine: 0, description: "No change", diffChunk: DiffChunk(lines: [], startLine: 0))

    enum CodingKeys: String, CodingKey {
        case startLine = "start_line"
        case description
        case chunk
    }

    package init(id: UUID = UUID(), startLine: Int, description: String, diffChunk: DiffChunk) {
        self.id = id
        self.startLine = startLine
        self.description = description
        self.diffChunk = diffChunk
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        startLine = try container.decode(Int.self, forKey: .startLine)
        description = try container.decode(String.self, forKey: .description)
        let chunkLines = try container.decode([String].self, forKey: .chunk)
        diffChunk = DiffChunk(lines: chunkLines.map { DiffLine(content: $0) }, startLine: startLine)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startLine, forKey: .startLine)
        try container.encode(description, forKey: .description)
        try container.encode(diffChunk.lines.map(\.rawContent), forKey: .chunk)
    }

    /// New function to print all lines in the file change
    package func printAllLines() {
        print("File Change ID: \(id)")
        print("Description: \(description)")
        print("Start Line: \(startLine)")
        print("Diff Chunk:")
        for (index, line) in diffChunk.lines.enumerated() {
            print("  Line \(index + 1): \(line.rawContent)")
        }
        print("") // Empty line for better readability
    }

    /// A stable, human-readable identity built from the change's content.
    ///
    /// *Important*: use the immutable `diffChunk.startLine` rather than the
    /// mutable `startLine`.
    /// When changes are applied (or reverted) `startLine` is adjusted,
    /// causing any key computed from it *afterwards* to drift.
    /// Persisting that drifting key made most changes fail to match during a
    /// restore – we’d only hit whichever change happened not to shift.
    package var contentKey: String {
        [
            description.trimmingCharacters(in: .whitespacesAndNewlines),
            String(diffChunk.startLine), // ← fixed
            diffChunk.lines.map(\.rawContent).joined(separator: "\n")
        ]
        .joined(separator: "|")
    }
}
