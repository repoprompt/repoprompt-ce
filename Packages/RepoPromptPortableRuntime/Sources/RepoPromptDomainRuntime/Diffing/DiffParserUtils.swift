import Foundation

public enum ApplyEditsDiffParserUtils {
    public static func splitContentToLines(_ content: String, _ usesSpaces: Bool) -> [String] {
        let (lines, _) = String.splitContentPreservingLineEndings(content)
        let decodedLines = lines.map { $0.decodingHTMLEntities() }
        return decodedLines.map { line in
            usesSpaces ? String.encodeIndentationAsSpaces(line) : String.encodeIndentationAsTabs(line)
        }
    }
}
