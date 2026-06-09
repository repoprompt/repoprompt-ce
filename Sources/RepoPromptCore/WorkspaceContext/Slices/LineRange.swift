import Foundation

/// Represents a 1-based inclusive line range within a file.
package struct LineRange: Codable, Equatable, Hashable {
    package let start: Int
    package let end: Int
    /// Optional description explaining what this slice contains and why it's relevant.
    package let description: String?

    package init(start: Int, end: Int, description: String? = nil) {
        let clampedStart = max(1, start)
        let clampedEnd = max(clampedStart, end)
        self.start = clampedStart
        self.end = clampedEnd
        self.description = description
    }
}
