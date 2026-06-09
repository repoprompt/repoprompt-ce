import Foundation

enum HeadlessSelectionTools {
    static func manageSelection(host: HeadlessHost, arguments: HeadlessJSONObject) async throws -> HeadlessJSONObject {
        let op = HeadlessToolArguments.string(arguments, key: "op") ?? "get"
        let snapshot = try await host.snapshot(requireWorkspace: true)
        guard let workspace = snapshot.workspace else {
            throw HeadlessCommandError("No active workspace is available.", exitCode: 2)
        }
        let resolver = HeadlessPathResolver(roots: snapshot.roots)
        let current = workspace.selection

        switch op {
        case "get":
            return try selectionResponse(selection: current, roots: snapshot.roots, title: "## Selection ✅", note: nil)
        case "clear":
            let updated = try await host.updateSelection(workspaceID: workspace.id) { selection in
                selection = []
            }
            return try selectionResponse(selection: updated.selection, roots: snapshot.roots, title: "## Selection Cleared ✅", note: nil)
        case "preview":
            let preview = try applySelectionMutation(arguments: arguments, current: current, resolver: resolver)
            return try selectionResponse(selection: preview, roots: snapshot.roots, title: "## Selection Preview ✅", note: "Preview only; active workspace selection was not changed.")
        case "add", "set":
            let updated = try await host.updateSelection(workspaceID: workspace.id) { selection in
                let base = op == "set" ? [] : selection
                selection = try applySelectionMutation(arguments: arguments, current: base, resolver: resolver)
            }
            return try selectionResponse(selection: updated.selection, roots: snapshot.roots, title: "## Selection Updated ✅", note: nil)
        case "remove":
            let updated = try await host.updateSelection(workspaceID: workspace.id) { selection in
                selection = try applyingRemovals(arguments: arguments, current: selection, resolver: resolver)
            }
            return try selectionResponse(selection: updated.selection, roots: snapshot.roots, title: "## Selection Updated ✅", note: nil)
        case "promote", "demote":
            throw HeadlessCommandError("manage_selection op '\(op)' is not supported in headless v1; use add/set with mode full or codemap_only.", exitCode: 2)
        default:
            throw HeadlessCommandError("Unsupported manage_selection op '\(op)'. Supported ops: get, preview, add, remove, set, clear.", exitCode: 2)
        }
    }

    private static func applySelectionMutation(arguments: HeadlessJSONObject, current: [HeadlessSelectionEntry], resolver: HeadlessPathResolver) throws -> [HeadlessSelectionEntry] {
        let mode = try parseMode(HeadlessToolArguments.string(arguments, key: "mode") ?? "full")
        let additions = try entries(from: arguments, resolver: resolver, defaultMode: mode)
        guard !additions.isEmpty || !(HeadlessToolArguments.stringArray(arguments, key: "paths") ?? []).isEmpty || HeadlessToolArguments.string(arguments, key: "path") != nil || HeadlessToolArguments.objectArray(arguments, key: "slices") != nil else {
            return current
        }
        var result = current
        for addition in additions {
            if let index = result.firstIndex(where: { $0.rootID == addition.rootID && $0.relativePath == addition.relativePath }) {
                result[index] = addition
            } else {
                result.append(addition)
            }
        }
        return HeadlessSelectionNormalizer.normalized(result)
    }

    private static func entries(from arguments: HeadlessJSONObject, resolver: HeadlessPathResolver, defaultMode: HeadlessSelectionMode) throws -> [HeadlessSelectionEntry] {
        var entries: [HeadlessSelectionEntry] = []
        let catalog = HeadlessFileCatalog()
        let paths = (HeadlessToolArguments.stringArray(arguments, key: "paths") ?? []) + (HeadlessToolArguments.string(arguments, key: "path").map { [$0] } ?? [])
        if defaultMode == .slices, !paths.isEmpty {
            throw HeadlessCommandError("Selection mode slices requires slice objects with non-empty ranges; path/paths cannot create an empty slice selection.", exitCode: 2)
        }
        for path in paths {
            let resolved = try resolver.resolve(path)
            let files = try catalog.filesUnder(resolved)
            for file in files {
                entries.append(HeadlessSelectionEntry(rootID: file.root.id, relativePath: file.relativePath, mode: defaultMode))
            }
        }

        for slice in try sliceObjects(from: arguments) {
            let path = try HeadlessToolArguments.requiredString(slice, key: "path")
            let resolved = try resolver.resolve(path)
            guard !resolved.isDirectory else {
                throw HeadlessCommandError("Slice selection requires a file path, not a directory: \(resolved.displayPath)", exitCode: 2)
            }
            let ranges = try parseRanges(slice)
            entries.append(HeadlessSelectionEntry(rootID: resolved.root.id, relativePath: resolved.relativePath, mode: .slices, ranges: ranges))
        }
        return HeadlessSelectionNormalizer.normalized(entries)
    }

    private static func applyingRemovals(
        arguments: HeadlessJSONObject,
        current: [HeadlessSelectionEntry],
        resolver: HeadlessPathResolver
    ) throws -> [HeadlessSelectionEntry] {
        let catalog = HeadlessFileCatalog()
        let paths = (HeadlessToolArguments.stringArray(arguments, key: "paths") ?? [])
            + (HeadlessToolArguments.string(arguments, key: "path").map { [$0] } ?? [])
        if HeadlessToolArguments.string(arguments, key: "mode") == HeadlessSelectionMode.slices.rawValue,
           !paths.isEmpty
        {
            throw HeadlessCommandError("Selection mode slices requires slice objects with non-empty ranges; path/paths cannot create an empty slice selection.", exitCode: 2)
        }
        var wholeFileKeys: Set<String> = []
        for path in paths {
            let resolved = try resolver.resolve(path)
            for file in try catalog.filesUnder(resolved) {
                wholeFileKeys.insert(selectionKey(rootID: file.root.id, relativePath: file.relativePath))
            }
        }

        var sliceRemovals: [String: [HeadlessLineRange]] = [:]
        for slice in try sliceObjects(from: arguments) {
            let path = try HeadlessToolArguments.requiredString(slice, key: "path")
            let resolved = try resolver.resolve(path)
            guard !resolved.isDirectory else {
                throw HeadlessCommandError("Slice removal requires a file path, not a directory: \(resolved.displayPath)", exitCode: 2)
            }
            let key = selectionKey(rootID: resolved.root.id, relativePath: resolved.relativePath)
            try sliceRemovals[key, default: []].append(contentsOf: parseRanges(slice))
        }

        var result = HeadlessSelectionNormalizer.normalized(current)
            .filter { !wholeFileKeys.contains(selectionKey(for: $0)) }
        for (key, removals) in sliceRemovals where !wholeFileKeys.contains(key) {
            guard let index = result.firstIndex(where: { selectionKey(for: $0) == key }),
                  result[index].mode == .slices
            else {
                continue
            }
            result[index].ranges = HeadlessSelectionNormalizer.subtracting(removals, from: result[index].ranges)
            if result[index].ranges.isEmpty {
                result.remove(at: index)
            }
        }
        return HeadlessSelectionNormalizer.normalized(result)
    }

    private static func sliceObjects(from arguments: HeadlessJSONObject) throws -> [HeadlessJSONObject] {
        guard let rawValue = arguments["slices"], !(rawValue is NSNull) else {
            return []
        }
        guard let slices = HeadlessToolArguments.objectArray(arguments, key: "slices") else {
            throw HeadlessCommandError("Selection slices must be an array of slice objects.", exitCode: 2)
        }
        guard !slices.isEmpty else {
            throw HeadlessCommandError("Selection slices must not be empty.", exitCode: 2)
        }
        return slices
    }

    private static func parseMode(_ value: String) throws -> HeadlessSelectionMode {
        guard let mode = HeadlessSelectionMode(rawValue: value) else {
            throw HeadlessCommandError("Unsupported selection mode '\(value)'. Expected full, slices, or codemap_only.", exitCode: 2)
        }
        return mode
    }

    private static func parseRanges(_ slice: HeadlessJSONObject) throws -> [HeadlessLineRange] {
        if let rangeObjects = HeadlessToolArguments.objectArray(slice, key: "ranges") {
            let ranges = try rangeObjects.map { object in
                guard let start = HeadlessToolArguments.int(object, key: "start_line") else {
                    throw HeadlessCommandError("Slice range is missing start_line.", exitCode: 2)
                }
                let end = HeadlessToolArguments.int(object, key: "end_line") ?? start
                guard start > 0, end >= start else {
                    throw HeadlessCommandError("Invalid slice range \(start)-\(end).", exitCode: 2)
                }
                return HeadlessLineRange(startLine: start, endLine: end, description: HeadlessToolArguments.string(object, key: "description"))
            }
            guard !ranges.isEmpty else {
                throw HeadlessCommandError("Slice selection requires at least one range.", exitCode: 2)
            }
            return ranges
        }
        if let lines = HeadlessToolArguments.string(slice, key: "lines") {
            return try parseLineSpec(lines)
        }
        throw HeadlessCommandError("Slice selection requires ranges or lines.", exitCode: 2)
    }

    private static func parseLineSpec(_ spec: String) throws -> [HeadlessLineRange] {
        let pieces = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !pieces.isEmpty else {
            throw HeadlessCommandError("Slice lines spec is empty.", exitCode: 2)
        }
        return try pieces.map { piece in
            let bounds = piece.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let start = Int(bounds[0]), start > 0 else {
                throw HeadlessCommandError("Invalid slice line spec: \(piece)", exitCode: 2)
            }
            let end: Int
            if bounds.count == 2 {
                guard let parsedEnd = Int(bounds[1]) else {
                    throw HeadlessCommandError("Invalid slice line range: \(piece)", exitCode: 2)
                }
                end = parsedEnd
            } else {
                end = start
            }
            guard end >= start else {
                throw HeadlessCommandError("Invalid slice line range: \(piece)", exitCode: 2)
            }
            return HeadlessLineRange(startLine: start, endLine: end)
        }
    }

    private static func selectionResponse(selection: [HeadlessSelectionEntry], roots: [HeadlessAllowedRoot], title: String, note: String?) throws -> HeadlessJSONObject {
        let normalizedSelection = HeadlessSelectionNormalizer.normalized(selection)
        var lines = [title, "- **Files**: \(normalizedSelection.count)", "- **Auto-codemap**: disabled in headless v1"]
        if let note { lines.append("- **Note**: \(note)") }
        for entry in normalizedSelection {
            lines.append("- `\(displayPath(for: entry, roots: roots))` (\(entry.mode.rawValue)\(rangeSuffix(entry.ranges)))")
        }
        return try HeadlessToolResponse.success(text: lines.joined(separator: "\n"), structured: [
            "files": HeadlessJSONValue.value(normalizedSelection),
            "codemap_auto_enabled": false,
            "total_tokens": 0,
            "summary": "\(normalizedSelection.count) selected entr\(normalizedSelection.count == 1 ? "y" : "ies")"
        ])
    }

    static func displayPath(for entry: HeadlessSelectionEntry, roots: [HeadlessAllowedRoot]) -> String {
        let rootName = roots.first(where: { $0.id == entry.rootID })?.name ?? entry.rootID.uuidString
        return entry.relativePath.isEmpty ? rootName : "\(rootName)/\(entry.relativePath)"
    }

    private static func rangeSuffix(_ ranges: [HeadlessLineRange]) -> String {
        guard !ranges.isEmpty else { return "" }
        let spec = ranges.map { range in
            range.startLine == range.endLine ? "\(range.startLine)" : "\(range.startLine)-\(range.endLine)"
        }.joined(separator: ",")
        return ", lines \(spec)"
    }

    private static func selectionKey(for entry: HeadlessSelectionEntry) -> String {
        selectionKey(rootID: entry.rootID, relativePath: entry.relativePath)
    }

    private static func selectionKey(rootID: UUID, relativePath: String) -> String {
        "\(rootID.uuidString):\(relativePath)"
    }
}
