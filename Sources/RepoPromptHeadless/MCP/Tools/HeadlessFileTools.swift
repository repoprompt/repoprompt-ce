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
        let data = try HeadlessSecureFileAccess()
            .readRegularFile(root: resolved.root, relativePath: resolved.relativePath, maximumBytes: maxReadableBytes)
            .data
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw HeadlessCommandError("File is binary or not valid UTF-8: \(resolved.displayPath)", exitCode: 2)
        }
        let slice = try HeadlessReadFileSlicer.slice(
            text: text,
            startLine: HeadlessToolArguments.int(arguments, key: "start_line"),
            limit: HeadlessToolArguments.int(arguments, key: "limit")
        )
        let language = resolved.url.pathExtension.isEmpty ? "text" : resolved.url.pathExtension
        let textOutput = """
        ## File Read ✅
        - **Path**: `\(resolved.displayPath)`
        - **Lines**: \(rangeDescription(firstLine: slice.firstLine, lastLine: slice.lastLine, totalLines: slice.totalLines))
        \(slice.message.map { "- **Message**: \($0)" } ?? "")

        ```\(language)
        \(slice.content)
        ```
        """
        var structured: HeadlessJSONObject = [
            "content": slice.content,
            "total_lines": slice.totalLines,
            "first_line": slice.firstLine,
            "last_line": slice.lastLine,
            "display_path": resolved.displayPath,
            "path": resolved.resolvedURL.path
        ]
        if let message = slice.message {
            structured["message"] = message
        } else {
            structured["message"] = NSNull()
        }
        return HeadlessToolResponse.success(text: textOutput, structured: structured)
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
            guard let snapshot = try? HeadlessSecureFileAccess().readRegularFile(
                root: resolved.root,
                relativePath: resolved.relativePath,
                maximumBytes: maxReadableBytes
            ) else {
                continue
            }
            let data = snapshot.data
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                continue
            }
            if entry.mode == .slices {
                guard !entry.ranges.isEmpty else { continue }
                let chunks = try entry.ranges.map { range in
                    try HeadlessReadFileSlicer.slice(
                        text: text,
                        startLine: range.startLine,
                        limit: range.endLine - range.startLine + 1
                    ).content
                }
                output.append((displayPath, chunks.joined(separator: "\n…\n")))
            } else {
                output.append((displayPath, text))
            }
        }
        return output
    }

    private static func rangeDescription(firstLine: Int, lastLine: Int, totalLines: Int) -> String {
        guard firstLine > 0, lastLine >= firstLine else { return "0 of \(totalLines)" }
        return "\(firstLine)–\(lastLine) of \(totalLines)"
    }
}
