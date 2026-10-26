import CoreGraphics
import Foundation

/// User-facing display mode for file @ mention pickers.
enum FileMentionPickerStyle: String, CaseIterable, Codable, Identifiable {
    case compact
    case expanded

    static let defaultStyle: FileMentionPickerStyle = .compact

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .expanded: "Expanded"
        }
    }

    var configuration: FileMentionPickerConfiguration {
        switch self {
        case .compact: .compact
        case .expanded: .expanded
        }
    }

    static func normalized(rawValue: String?) -> FileMentionPickerStyle {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let style = FileMentionPickerStyle(rawValue: rawValue)
        else {
            return defaultStyle
        }
        return style
    }
}

/// Derived behavior values for file @ mention pickers.
struct FileMentionPickerConfiguration: Equatable {
    let maxResults: Int
    let visibleRows: Int
    let overlayWidth: CGFloat
    let showsFileSubtitles: Bool

    static let compact = FileMentionPickerConfiguration(
        maxResults: 5,
        visibleRows: 5,
        overlayWidth: 240,
        showsFileSubtitles: false
    )

    static let expanded = FileMentionPickerConfiguration(
        maxResults: 99,
        visibleRows: 10,
        overlayWidth: 480,
        showsFileSubtitles: true
    )
}
