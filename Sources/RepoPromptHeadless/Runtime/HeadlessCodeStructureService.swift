import Foundation

struct HeadlessCodeStructureResult {
    var text: String
    var structured: [String: Any]
}

final class HeadlessCodeStructureService {
    private let maxReadableBytes = 2 * 1024 * 1024
    private let supportedExtensions: Set<String> = [
        "swift", "py", "js", "jsx", "ts", "tsx", "go", "rs", "rb", "java", "c", "h", "cc", "cpp", "hpp", "cs", "php", "m", "mm"
    ]

    func structure(paths: [HeadlessResolvedPath], maxResults: Int) throws -> HeadlessCodeStructureResult {
        var fileBlocks: [[String: Any]] = []
        var textBlocks: [String] = []
        var skipped: [String] = []
        let limit = max(1, min(maxResults, 200))

        for path in paths.prefix(limit) {
            guard !path.isDirectory else {
                skipped.append("\(path.displayPath) (directory)")
                continue
            }
            let ext = path.url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else {
                skipped.append("\(path.displayPath) (unsupported type)")
                continue
            }
            let values = try path.url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= maxReadableBytes else {
                skipped.append("\(path.displayPath) (oversized)")
                continue
            }
            let data = try Data(contentsOf: path.url)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                skipped.append("\(path.displayPath) (binary or non-UTF-8)")
                continue
            }
            let symbols = extractSymbols(from: text, extension: ext)
            guard !symbols.isEmpty else {
                skipped.append("\(path.displayPath) (no lightweight symbols found)")
                continue
            }
            let symbolObjects = symbols.map { symbol in
                ["line": symbol.line, "kind": symbol.kind, "signature": symbol.signature] as [String: Any]
            }
            fileBlocks.append([
                "path": path.displayPath,
                "relative_path": path.relativePath,
                "parser": "headless-lightweight",
                "symbols": symbolObjects
            ])
            var block = "File: \(path.displayPath)\nParser: headless-lightweight"
            for symbol in symbols {
                block += "\nL\(symbol.line): \(symbol.signature)"
            }
            textBlocks.append(block)
        }

        let header = "## Code Structure ✅\n- **Files with codemap**: \(fileBlocks.count)\n- **Parser**: `headless-lightweight`"
        let skippedText = skipped.isEmpty ? "" : "\n\nSkipped:\n" + skipped.map { "- \($0)" }.joined(separator: "\n")
        let body = textBlocks.isEmpty ? "" : "\n\n```text\n\(textBlocks.joined(separator: "\n\n"))\n```"
        return HeadlessCodeStructureResult(
            text: header + skippedText + body,
            structured: [
                "parser": "headless-lightweight",
                "files": fileBlocks,
                "skipped": skipped,
                "files_with_codemap": fileBlocks.count
            ]
        )
    }

    private func extractSymbols(from text: String, extension ext: String) -> [Symbol] {
        let patterns = patterns(for: ext)
        let lines = text.components(separatedBy: .newlines)
        var symbols: [Symbol] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#") else {
                continue
            }
            for pattern in patterns {
                if let match = trimmed.range(of: pattern.regex, options: .regularExpression) {
                    let signature = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
                    symbols.append(Symbol(line: index + 1, kind: pattern.kind, signature: signature))
                    break
                }
            }
        }
        return symbols
    }

    private func patterns(for ext: String) -> [Pattern] {
        switch ext {
        case "swift":
            [
                Pattern(kind: "type", regex: #"^(?:public|private|fileprivate|internal|open)?\s*(?:final\s+)?(?:class|struct|enum|protocol|actor|extension)\s+[^:{]+"#),
                Pattern(kind: "function", regex: #"^(?:public|private|fileprivate|internal|open)?\s*(?:static\s+)?func\s+[^\{]+"#),
                Pattern(kind: "initializer", regex: #"^(?:public|private|fileprivate|internal|open)?\s*init\s*\([^\{]*"#)
            ]
        case "py":
            [Pattern(kind: "type", regex: #"^class\s+[^:]+"#), Pattern(kind: "function", regex: #"^(?:async\s+)?def\s+[^:]+"#)]
        case "js", "jsx", "ts", "tsx":
            [
                Pattern(kind: "type", regex: #"^(?:export\s+)?(?:default\s+)?class\s+[^\{]+"#),
                Pattern(kind: "function", regex: #"^(?:export\s+)?(?:async\s+)?function\s+[^\{]+"#),
                Pattern(kind: "function", regex: #"^(?:export\s+)?(?:const|let|var)\s+\w+\s*=\s*(?:async\s*)?\([^=]*\)\s*=>"#)
            ]
        case "go":
            [Pattern(kind: "type", regex: #"^type\s+\w+\s+(?:struct|interface)"#), Pattern(kind: "function", regex: #"^func\s+[^\{]+"#)]
        case "rs":
            [Pattern(kind: "type", regex: #"^(?:pub\s+)?(?:struct|enum|trait|impl)\s+[^\{]+"#), Pattern(kind: "function", regex: #"^(?:pub\s+)?(?:async\s+)?fn\s+[^\{]+"#)]
        case "rb":
            [Pattern(kind: "type", regex: #"^class\s+.+"#), Pattern(kind: "type", regex: #"^module\s+.+"#), Pattern(kind: "function", regex: #"^def\s+.+"#)]
        case "java", "cs":
            [Pattern(kind: "type", regex: #"^(?:public|private|protected|internal|static|sealed|abstract|final|partial|\s)+\s*(?:class|interface|enum|record|struct)\s+[^\{]+"#), Pattern(kind: "function", regex: #"^(?:public|private|protected|internal|static|async|final|virtual|override|\s)+[\w<>\[\],?]+\s+\w+\s*\([^\)]*\)"#)]
        case "php":
            [Pattern(kind: "type", regex: #"^(?:final\s+|abstract\s+)?(?:class|interface|trait|enum)\s+[^\{]+"#), Pattern(kind: "function", regex: #"^(?:public|private|protected|static|\s)*function\s+[^\{]+"#)]
        default:
            [Pattern(kind: "type", regex: #"^(?:class|struct|enum|interface)\s+[^\{]+"#), Pattern(kind: "function", regex: #"^[\w\s\*:&<>]+\s+\w+\s*\([^\)]*\)"#)]
        }
    }

    private struct Symbol {
        let line: Int
        let kind: String
        let signature: String
    }

    private struct Pattern {
        let kind: String
        let regex: String
    }
}
