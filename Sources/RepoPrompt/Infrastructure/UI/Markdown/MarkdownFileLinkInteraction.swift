import Foundation
import SwiftUI

struct MarkdownFileLinkTarget {
    let rawDestination: String
    let normalizedPath: String
    let lineNumber: Int?

    static func parse(rawDestination: String) -> MarkdownFileLinkTarget? {
        let trimmed = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let colonLineMatch = parseColonLineSuffix(in: trimmed)
        let candidate = colonLineMatch?.path ?? trimmed

        if let url = URL(string: candidate), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "mailto":
                return nil
            case "file":
                let normalizedPath = (url.path as NSString).standardizingPath
                guard !normalizedPath.isEmpty else { return nil }
                return MarkdownFileLinkTarget(
                    rawDestination: rawDestination,
                    normalizedPath: normalizedPath,
                    lineNumber: parseLineNumber(fragment: url.fragment)
                )
            default:
                return nil
            }
        }

        let parts = candidate.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }

        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let normalizedPath = (decodedPath as NSString).standardizingPath
        guard !normalizedPath.isEmpty, normalizedPath != "." else { return nil }

        let fragment = parts.count > 1 ? String(parts[1]) : nil
        return MarkdownFileLinkTarget(
            rawDestination: rawDestination,
            normalizedPath: normalizedPath,
            lineNumber: parseLineNumber(fragment: fragment) ?? colonLineMatch?.lineNumber
        )
    }

    private static func parseLineNumber(fragment: String?) -> Int? {
        guard let fragment = fragment?.trimmingCharacters(in: .whitespacesAndNewlines), !fragment.isEmpty else {
            return nil
        }

        let lowercase = fragment.lowercased()
        if lowercase.hasPrefix("l") {
            let digits = lowercase.dropFirst().prefix { $0.isNumber }
            return Int(digits)
        }
        if lowercase.hasPrefix("line=") {
            return Int(lowercase.dropFirst("line=".count))
        }
        return nil
    }

    private static func parseColonLineSuffix(in value: String) -> (path: String, lineNumber: Int)? {
        let lowercase = value.lowercased()
        guard !lowercase.hasPrefix("http://"), !lowercase.hasPrefix("https://"), !lowercase.hasPrefix("mailto:") else {
            return nil
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        guard let lineNumber = Int(parts[parts.count - 2]) ?? Int(parts[parts.count - 1]) else {
            return nil
        }

        let pathPartsCount = Int(parts[parts.count - 2]) != nil && parts.count >= 3 ? parts.count - 2 : parts.count - 1
        let path = parts.prefix(pathPartsCount).joined(separator: ":")
        guard !path.isEmpty else { return nil }
        return (path: path, lineNumber: lineNumber)
    }
}

@MainActor
final class MarkdownFileLinkOpener {
    private let handler: @MainActor (MarkdownFileLinkTarget) async -> Bool

    init(open: @escaping @MainActor (MarkdownFileLinkTarget) async -> Bool) {
        handler = open
    }

    func open(_ target: MarkdownFileLinkTarget) async -> Bool {
        await handler(target)
    }
}

// swiftformat:disable environmentEntry
private struct MarkdownFileLinkOpenerKey: EnvironmentKey {
    static let defaultValue: MarkdownFileLinkOpener? = nil
}

extension EnvironmentValues {
    var markdownFileLinkOpener: MarkdownFileLinkOpener? {
        get { self[MarkdownFileLinkOpenerKey.self] }
        set { self[MarkdownFileLinkOpenerKey.self] = newValue }
    }
}

// swiftformat:enable environmentEntry

extension NSAttributedString.Key {
    static let markdownRawLink = NSAttributedString.Key("markdownRawLink")
}
