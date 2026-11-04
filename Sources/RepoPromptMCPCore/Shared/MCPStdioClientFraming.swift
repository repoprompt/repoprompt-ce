import Foundation

/// Classifies client stdio frames that the newline-delimited MCP transport cannot carry.
///
/// The helper's raw stdio/proxy mode forwards one JSON-RPC object per line. An LSP-style
/// `Content-Length` header is not valid MCP stdio framing; left unclassified it is forwarded as
/// an unparseable frame and the eventual failure surfaces as an internal-looking
/// `unknown JSON-RPC response id` error. Detecting it at ingress lets the helper fail fast
/// with an explicit, non-retryable explanation instead (#294).
enum MCPStdioClientFraming {
    static let unsupportedContentLengthDetail =
        "received an LSP-style `Content-Length` header; RepoPrompt MCP stdio uses newline-delimited JSON-RPC " +
        "(send exactly one JSON object per line, with no Content-Length framing)"

    /// Returns a human-readable reason when `frame` (one newline-delimited segment, without its
    /// trailing `\n`) uses unsupported framing; `nil` for ordinary frames, including blank lines.
    static func unsupportedFramingDetail(for frame: Data) -> String? {
        var index = frame.startIndex
        while index < frame.endIndex, Self.isLeadingWhitespace(frame[index]) {
            index = frame.index(after: index)
        }
        let header = Array("content-length:".utf8)
        guard frame.distance(from: index, to: frame.endIndex) >= header.count else { return nil }
        for (offset, expected) in header.enumerated() {
            let byte = frame[frame.index(index, offsetBy: offset)]
            guard Self.asciiLowercased(byte) == expected else { return nil }
        }
        return unsupportedContentLengthDetail
    }

    private static func isLeadingWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }
}
