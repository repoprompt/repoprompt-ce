import Foundation

struct HeadlessSearchResult {
    var summary: String
    var structured: [String: Any]
}

final class HeadlessSearchService {
    private let catalog: HeadlessFileCatalog
    private let fileManager: FileManager
    private let maxReadableBytes = 2 * 1024 * 1024

    init(catalog: HeadlessFileCatalog = HeadlessFileCatalog(), fileManager: FileManager = .default) {
        self.catalog = catalog
        self.fileManager = fileManager
    }

    func search(roots: [HeadlessAllowedRoot], resolver: HeadlessPathResolver, arguments: [String: Any]) throws -> HeadlessSearchResult {
        let pattern = try HeadlessToolArguments.requiredString(arguments, key: "pattern")
        let mode = HeadlessToolArguments.string(arguments, key: "mode") ?? "auto"
        let countOnly = HeadlessToolArguments.bool(arguments, key: "count_only") ?? false
        let maxResults = max(1, min(HeadlessToolArguments.int(arguments, key: "max_results") ?? 50, 1000))
        let contextLines = max(0, min(HeadlessToolArguments.int(arguments, key: "context_lines") ?? 0, 5))
        let wholeWord = HeadlessToolArguments.bool(arguments, key: "whole_word") ?? false
        let regexFlag = HeadlessToolArguments.bool(arguments, key: "regex")
        let useRegex = regexFlag ?? Self.looksLikeRegex(pattern)
        let filter = arguments["filter"] as? [String: Any] ?? [:]
        let extensions = Set((HeadlessToolArguments.stringArray(filter, key: "extensions") ?? []).map { ext in
            ext.hasPrefix(".") ? ext.lowercased() : ".\(ext.lowercased())"
        })
        let exclude = HeadlessToolArguments.stringArray(filter, key: "exclude") ?? []
        let filterPaths = (HeadlessToolArguments.stringArray(filter, key: "paths") ?? []) + (HeadlessToolArguments.string(arguments, key: "path").map { [$0] } ?? [])

        let searchRoots: [HeadlessCatalogEntry]
        if filterPaths.isEmpty {
            searchRoots = try catalog.scan(roots: roots)
        } else {
            var entries: [HeadlessCatalogEntry] = []
            for filterPath in filterPaths {
                let resolved = try resolver.resolve(filterPath)
                try entries.append(contentsOf: catalog.scan(roots: [resolved.root], under: resolved))
            }
            searchRoots = entries
        }

        let matcher = try Matcher(pattern: pattern, regex: useRegex, wholeWord: wholeWord)
        let effectiveMode = mode == "auto" ? "both" : mode
        guard ["path", "content", "both"].contains(effectiveMode) else {
            throw HeadlessCommandError("Unsupported file_search mode '\(mode)'. Expected auto, path, content, or both.", exitCode: 2)
        }

        var pathMatches: [[String: Any]] = []
        var contentMatches: [[String: Any]] = []
        var totalContentMatches = 0
        for entry in searchRoots where !entry.relativePath.isEmpty {
            if shouldSkip(entry: entry, extensions: extensions, exclude: exclude) {
                continue
            }
            if effectiveMode == "path" || effectiveMode == "both" {
                if matcher.matches(entry.displayPath) || matcher.matches(entry.relativePath) {
                    if pathMatches.count < maxResults {
                        pathMatches.append(["path": entry.displayPath, "relative_path": entry.relativePath, "root": entry.root.name])
                    }
                }
            }
            guard !entry.isDirectory, effectiveMode == "content" || effectiveMode == "both" else {
                continue
            }
            guard let byteCount = entry.byteCount, byteCount <= maxReadableBytes else {
                continue
            }
            guard let text = try? readTextFile(entry.url) else {
                continue
            }
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where matcher.matches(line) {
                totalContentMatches += 1
                if contentMatches.count < maxResults {
                    let start = max(0, index - contextLines)
                    let end = min(lines.count - 1, index + contextLines)
                    let context = (start ... end).map { lineIndex in
                        ["line": lineIndex + 1, "text": lines[lineIndex]] as [String: Any]
                    }
                    contentMatches.append([
                        "path": entry.displayPath,
                        "relative_path": entry.relativePath,
                        "root": entry.root.name,
                        "line": index + 1,
                        "text": line,
                        "context": context
                    ])
                }
            }
        }

        let totalMatches = pathMatches.count + totalContentMatches
        var lines: [String] = ["## Search Results ✅", "- **Pattern**: `\(pattern)`", "- **Mode**: `\(mode)`", "- **Total matches**: \(totalMatches)"]
        if countOnly {
            lines.append("- **Count only**: true")
        } else {
            if !pathMatches.isEmpty {
                lines.append("\n### Path Matches")
                for match in pathMatches.prefix(maxResults) {
                    lines.append("- `\(match["path"] as? String ?? "")`")
                }
            }
            if !contentMatches.isEmpty {
                lines.append("\n### Content Matches")
                for match in contentMatches.prefix(maxResults) {
                    let path = match["path"] as? String ?? ""
                    let line = match["line"] as? Int ?? 0
                    let text = match["text"] as? String ?? ""
                    lines.append("- `\(path):\(line)` \(text)")
                }
            }
            if totalMatches > maxResults {
                lines.append("\n_Omitted matches after max_results=\(maxResults)._")
            }
        }

        return HeadlessSearchResult(summary: lines.joined(separator: "\n"), structured: [
            "pattern": pattern,
            "mode": mode,
            "regex": useRegex,
            "whole_word": wholeWord,
            "total_matches": totalMatches,
            "path_matches": pathMatches,
            "content_matches": contentMatches,
            "omitted": max(0, totalMatches - maxResults)
        ])
    }

    private func shouldSkip(entry: HeadlessCatalogEntry, extensions: Set<String>, exclude: [String]) -> Bool {
        if !extensions.isEmpty, !entry.isDirectory {
            let ext = ".\(entry.url.pathExtension.lowercased())"
            if !extensions.contains(ext) {
                return true
            }
        }
        return exclude.contains { token in
            entry.relativePath.localizedCaseInsensitiveContains(token) || entry.displayPath.localizedCaseInsensitiveContains(token)
        }
    }

    private func readTextFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard !data.contains(0) else {
            throw HeadlessCommandError("Binary file skipped: \(url.path)", exitCode: 2)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HeadlessCommandError("File is not valid UTF-8: \(url.path)", exitCode: 2)
        }
        return text
    }

    private static func looksLikeRegex(_ pattern: String) -> Bool {
        pattern.range(of: #"[.\[\]()*+?{}|^$]"#, options: .regularExpression) != nil
    }

    private struct Matcher {
        let pattern: String
        let regex: NSRegularExpression?

        init(pattern: String, regex: Bool, wholeWord: Bool) throws {
            self.pattern = pattern
            if regex || wholeWord {
                let source = regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
                let wrapped = wholeWord ? "\\b(?:\(source))\\b" : source
                self.regex = try NSRegularExpression(pattern: wrapped)
            } else {
                self.regex = nil
            }
        }

        func matches(_ text: String) -> Bool {
            if let regex {
                let range = NSRange(text.startIndex ..< text.endIndex, in: text)
                return regex.firstMatch(in: text, range: range) != nil
            }
            return text.localizedCaseInsensitiveContains(pattern)
        }
    }
}
