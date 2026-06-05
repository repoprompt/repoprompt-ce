import Foundation

enum HeadlessFileTools {
    private static let maxReadableBytes = 2 * 1024 * 1024

    static func readFile(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let path = try HeadlessToolArguments.requiredString(arguments, key: "path")
        let snapshot = try await host.snapshot(requireWorkspace: true)
        let resolver = HeadlessPathResolver(roots: snapshot.roots)
        let resolved = try resolver.resolve(path)
        guard !resolved.isDirectory else {
            throw HeadlessCommandError("read_file requires a file, not a directory: \(resolved.displayPath)", exitCode: 2)
        }
        let data = try Data(contentsOf: resolved.url)
        guard data.count <= maxReadableBytes else {
            throw HeadlessCommandError("File is too large to read in headless v1 (\(data.count) bytes > \(maxReadableBytes)): \(resolved.displayPath)", exitCode: 2)
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw HeadlessCommandError("File is binary or not valid UTF-8: \(resolved.displayPath)", exitCode: 2)
        }
        let lines = text.components(separatedBy: .newlines)
        let totalLines = lines.count
        let range = lineRange(totalLines: totalLines, startLine: HeadlessToolArguments.int(arguments, key: "start_line"), limit: HeadlessToolArguments.int(arguments, key: "limit"))
        let selectedLines: [String] = if range.isEmpty {
            []
        } else {
            Array(lines[(range.lowerBound - 1) ..< (range.upperBound - 1)])
        }
        let content = selectedLines.joined(separator: "\n")
        let language = resolved.url.pathExtension.isEmpty ? "text" : resolved.url.pathExtension
        let textOutput = """
        ## File Read ✅
        - **Path**: `\(resolved.displayPath)`
        - **Lines**: \(rangeDescription(range: range, totalLines: totalLines))

        ```\(language)
        \(content)
        ```
        """
        return HeadlessToolResponse.success(text: textOutput, structured: [
            "content": content,
            "total_lines": totalLines,
            "first_line": range.lowerBound,
            "last_line": max(0, range.upperBound - 1),
            "display_path": resolved.displayPath,
            "path": resolved.url.path
        ])
    }

    static func fileSearch(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let snapshot = try await host.snapshot(requireWorkspace: true)
        let resolver = HeadlessPathResolver(roots: snapshot.roots)
        let result = try HeadlessSearchService().search(roots: snapshot.roots, resolver: resolver, arguments: arguments)
        return HeadlessToolResponse.success(text: result.summary, structured: result.structured)
    }

    static func getFileTree(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let snapshot = try await host.snapshot(requireWorkspace: true)
        let type = HeadlessToolArguments.string(arguments, key: "type") ?? "files"
        let mode = HeadlessToolArguments.string(arguments, key: "mode") ?? "auto"
        if type == "roots" {
            var lines = ["## File Tree ✅", "- **Roots**: \(snapshot.roots.count)", ""]
            for root in snapshot.roots {
                lines.append("- \(root.name): `\(root.path)`")
            }
            return try HeadlessToolResponse.success(text: lines.joined(separator: "\n"), structured: [
                "roots_count": snapshot.roots.count,
                "roots": HeadlessJSONValue.value(snapshot.roots)
            ])
        }
        guard type == "files" else {
            throw HeadlessCommandError("Unsupported get_file_tree type '\(type)'. Expected files or roots.", exitCode: 2)
        }
        if mode == "selected" {
            let selected = snapshot.workspace?.selection ?? []
            let tree = selected.isEmpty ? "(no selected files)" : selected.map { "* \(HeadlessSelectionTools.displayPath(for: $0, roots: snapshot.roots))" }.joined(separator: "\n")
            let text = "## File Tree ✅\n- **Roots**: \(snapshot.roots.count)\n- **Mode**: selected\n\n```text\n\(tree)\n```"
            return HeadlessToolResponse.success(text: text, structured: ["roots_count": snapshot.roots.count, "tree": tree, "was_truncated": false])
        }
        guard ["auto", "full", "folders"].contains(mode) else {
            throw HeadlessCommandError("Unsupported get_file_tree mode '\(mode)'. Expected auto, full, folders, or selected.", exitCode: 2)
        }
        let resolver = HeadlessPathResolver(roots: snapshot.roots)
        let basePath = try HeadlessToolArguments.string(arguments, key: "path").map { try resolver.resolve($0) }
        let depth = HeadlessToolArguments.int(arguments, key: "max_depth") ?? (mode == "full" ? 12 : 4)
        let result = try HeadlessFileCatalog().tree(roots: snapshot.roots, basePath: basePath, mode: mode, maxDepth: depth)
        let text = "## File Tree ✅\n- **Roots**: \(result.rootsCount)\n- **Mode**: \(mode)\n- **Truncated**: \(result.wasTruncated)\n\n```text\n\(result.tree)\n```"
        return HeadlessToolResponse.success(text: text, structured: [
            "roots_count": result.rootsCount,
            "tree": result.tree,
            "was_truncated": result.wasTruncated,
            "uses_legend": false
        ])
    }

    static func getCodeStructure(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let snapshot = try await host.snapshot(requireWorkspace: true)
        let resolver = HeadlessPathResolver(roots: snapshot.roots)
        let scope = HeadlessToolArguments.string(arguments, key: "scope") ?? "paths"
        let maxResults = HeadlessToolArguments.int(arguments, key: "max_results") ?? 10
        let paths: [HeadlessResolvedPath]
        switch scope {
        case "paths":
            let inputs = HeadlessToolArguments.stringArray(arguments, key: "paths") ?? []
            guard !inputs.isEmpty else {
                throw HeadlessCommandError("get_code_structure with scope=paths requires paths.", exitCode: 2)
            }
            paths = try expandResolvedFiles(inputs: inputs, resolver: resolver)
        case "selected":
            let selected = snapshot.workspace?.selection ?? []
            guard !selected.isEmpty else {
                throw HeadlessCommandError("get_code_structure scope=selected requires a non-empty selection.", exitCode: 2)
            }
            paths = try selected.compactMap { entry in
                guard let root = snapshot.roots.first(where: { $0.id == entry.rootID }) else { return nil }
                return try resolver.resolve(entry.relativePath.isEmpty ? root.name : "\(root.name)/\(entry.relativePath)")
            }
        default:
            throw HeadlessCommandError("Unsupported get_code_structure scope '\(scope)'. Expected paths or selected.", exitCode: 2)
        }
        let result = try HeadlessCodeStructureService().structure(paths: paths, maxResults: maxResults)
        return HeadlessToolResponse.success(text: result.text, structured: result.structured)
    }

    static func expandResolvedFiles(inputs: [String], resolver: HeadlessPathResolver) throws -> [HeadlessResolvedPath] {
        let catalog = HeadlessFileCatalog()
        var files: [HeadlessResolvedPath] = []
        for input in inputs {
            let resolved = try resolver.resolve(input)
            try files.append(contentsOf: catalog.filesUnder(resolved))
        }
        return files
    }

    static func readSelectedContent(selection: [HeadlessSelectionEntry], roots: [HeadlessAllowedRoot], resolver: HeadlessPathResolver) throws -> [(path: String, content: String)] {
        var output: [(String, String)] = []
        for entry in selection where entry.mode != .codemapOnly {
            guard let root = roots.first(where: { $0.id == entry.rootID }) else { continue }
            let displayPath = entry.relativePath.isEmpty ? root.name : "\(root.name)/\(entry.relativePath)"
            let resolved = try resolver.resolve(displayPath)
            guard !resolved.isDirectory else { continue }
            let data = try Data(contentsOf: resolved.url)
            guard data.count <= maxReadableBytes, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                continue
            }
            if entry.mode == .slices, !entry.ranges.isEmpty {
                let lines = text.components(separatedBy: .newlines)
                let chunks = entry.ranges.map { range in
                    let start = max(1, min(range.startLine, lines.count))
                    let end = max(start, min(range.endLine, lines.count))
                    return Array(lines[(start - 1) ..< end]).joined(separator: "\n")
                }
                output.append((displayPath, chunks.joined(separator: "\n…\n")))
            } else {
                output.append((displayPath, text))
            }
        }
        return output
    }

    private static func lineRange(totalLines: Int, startLine: Int?, limit: Int?) -> Range<Int> {
        guard totalLines > 0 else { return 1 ..< 1 }
        let start: Int = if let startLine, startLine < 0 {
            max(1, totalLines + startLine + 1)
        } else {
            max(1, startLine ?? 1)
        }
        let boundedStart = min(start, totalLines)
        let endInclusive: Int = if let limit, limit > 0 {
            min(totalLines, boundedStart + limit - 1)
        } else {
            totalLines
        }
        return boundedStart ..< (endInclusive + 1)
    }

    private static func rangeDescription(range: Range<Int>, totalLines: Int) -> String {
        guard !range.isEmpty else { return "0 of \(totalLines)" }
        return "\(range.lowerBound)–\(range.upperBound - 1) of \(totalLines)"
    }
}
