import Foundation

package enum AttachmentInlineText {
    private static let minimumFenceLength = 3
    private static let backtick = UInt8(ascii: "`")

    /// The fence is one backtick longer than the longest backtick run in `text`, so no line of the
    /// file can close the block early. The file name and title sit in a header line above the fence
    /// because an info string may not contain backticks.
    package static func render(text: String, fileName: String, title: String?) -> String {
        let fence = String(repeating: "`", count: fenceLength(for: text))
        var header = "Attached file: \(singleLine(fileName))"
        if let title {
            let line = singleLine(title)
            if !line.isEmpty { header += " (title: \(line))" }
        }
        let separator = text.hasSuffix("\n") || text.isEmpty ? "" : "\n"
        return "\(header)\n\(fence)\n\(text)\(separator)\(fence)"
    }

    package static func fenceLength(for text: String) -> Int {
        var longest = 0
        var current = 0
        for byte in text.utf8 {
            if byte == backtick {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return max(minimumFenceLength, longest + 1)
    }

    /// One line naming a binary file the agent is expected to open itself: no fence and no bytes, so
    /// nothing in the file can reach the model. `path` must already be a validated absolute path.
    package static func renderPathMention(
        fileName: String,
        title: String?,
        byteCount: Int,
        absolutePath path: String
    ) -> String {
        var header = "Attached file: \(singleLine(fileName))"
        if let title {
            let line = singleLine(title)
            if !line.isEmpty { header += " (title: \(line))" }
        }
        return "\(header), binary, \(AttachmentFacts.humanSize(byteCount)). "
            + "Its contents are not inlined; you may open it yourself at its absolute path: \(path)"
    }

    private static func singleLine(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: " "
            default: Character(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}
