import Foundation

/// Represents a 1-based inclusive line range within a file.
public struct LineRange: Codable, Equatable, Hashable, Sendable {
    public let start: Int
    public let end: Int
    /// Optional description explaining what this slice contains and why it's relevant
    public let description: String?

    public init(start: Int, end: Int, description: String? = nil) {
        let clampedStart = max(1, start)
        let clampedEnd = max(clampedStart, end)
        self.start = clampedStart
        self.end = clampedEnd
        self.description = description
    }
}
