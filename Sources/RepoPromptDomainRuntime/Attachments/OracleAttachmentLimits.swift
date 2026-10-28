import Foundation

/// Byte caps are measured on raw file content, before any base64 expansion.
package struct OracleAttachmentLimits: Equatable {
    package let maxCount: Int
    package let maxBytesPerFile: Int
    package let maxTotalBytes: Int
    package let maxTitleLength: Int
    /// Largest text file delivered inline. Larger files are refused, never truncated.
    package let maxInlineTextBytes: Int

    package init(
        maxCount: Int,
        maxBytesPerFile: Int,
        maxTotalBytes: Int,
        maxTitleLength: Int,
        maxInlineTextBytes: Int
    ) {
        self.maxCount = maxCount
        self.maxBytesPerFile = maxBytesPerFile
        self.maxTotalBytes = maxTotalBytes
        self.maxTitleLength = maxTitleLength
        self.maxInlineTextBytes = maxInlineTextBytes
    }

    package static let production = OracleAttachmentLimits(
        maxCount: 10,
        maxBytesPerFile: 20 * 1024 * 1024,
        maxTotalBytes: 50 * 1024 * 1024,
        maxTitleLength: 200,
        maxInlineTextBytes: 512 * 1024
    )
}
