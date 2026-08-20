import Foundation
import MCP

/// Pure helpers (no AppKit/SwiftUI) that were previously duplicated.
public enum DiffEncodingUtils {
    /// Helper to encode arbitrary raw text into `[String]` using the same rules
    /// as `encodedOriginal(of:)`.
    public static func encode(_ raw: String, usesSpaces: Bool) -> [String] {
        ApplyEditsDiffParserUtils.splitContentToLines(raw, usesSpaces)
    }
}
