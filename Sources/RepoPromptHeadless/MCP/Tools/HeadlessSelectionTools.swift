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
            let updated = try await host.replaceSelection([])
            return try selectionResponse(selection: updated.selection, roots: snapshot.roots, title: "## Selection Cleared ✅", note: nil)
        case "preview":
            let preview = try applySelectionMutation(arguments: arguments, current: current, roots: snapshot.roots, resolver: resolver, persist: false)
            return try selectionResponse(selection: preview, roots: snapshot.roots, title: "## Selection Preview ✅", note: "Preview only; active workspace selection was not changed.")
        case "add", "set":
            let base = op == "set" ? [] : current
            let next = try applySelectionMutation(arguments: arguments, current: base, roots: snapshot.roots, resolver: resolver, persist: true)
            let updated = try await host.replaceSelection(next)
            return try selectionResponse(selection: updated.selection, roots: snapshot.roots, title: "## Selection Updated ✅", note: nil)
        case "remove":
            let removals = try entries(from: arguments, roots: snapshot.roots, resolver: resolver, defaultMode: .full)
            let removalKeys = Set(removals.map { "\($0.rootID.uuidString):\($0.relativePath)" })
            let next = current.filter { !removalKeys.contains("\($0.rootID.uuidString):\($0.relativePath)") }
            let updated = try await host.replaceSelection(next)
            return try selectionResponse(selection: updated.selection, roots: snapshot.roots, title: "## Selection Updated ✅", note: nil)
        case "promote", "demote":
            throw HeadlessCommandError("manage_selection op '\(op)' is not supported in headless v1; use add/set with mode full or codemap_only.", exitCode: 2)
        default:
            throw HeadlessCommandError("Unsupported manage_selection op '\(op)'. Supported ops: get, preview, add, remove, set, clear.", exitCode: 2)
        }
    }

    private static func applySelectionMutation(arguments: HeadlessJSONObject, current: [HeadlessSelectionEntry], roots: [HeadlessAllowedRoot], resolver: HeadlessPathResolver, persist: Bool) throws -> [HeadlessSelectionEntry] {
        let mode = try parseMode(HeadlessToolArguments.string(arguments, key: "mode") ?? "full")
        let additions = try entries(from: arguments, roots: roots, resolver: resolver, defaultMode: mode)
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
        return normalized(result)
    }

    private static func entries(from arguments: HeadlessJSONObject, roots: [HeadlessAllowedRoot], resolver: HeadlessPathResolver, defaultMode: HeadlessSelectionMode) throws -> [HeadlessSelectionEntry] {
        var entries: [HeadlessSelectionEntry] = []
        let catalog = HeadlessFileCatalog()
        let paths = (HeadlessToolArguments.stringArray(arguments, key: "paths") ?? []) + (HeadlessToolArguments.string(arguments, key: "path").map { [$0] } ?? [])
        for path in paths {
            let resolved = try resolver.resolve(path)
            let files = try catalog.filesUnder(resolved)
            for file in files {
                entries.append(HeadlessSelectionEntry(rootID: file.root.id, relativePath: file.relativePath, mode: defaultMode))
            }
        }

        for slice in HeadlessToolArguments.objectArray(arguments, key: "slices") ?? [] {
            let path = try HeadlessToolArguments.requiredString(slice, key: "path")
            let resolved = try resolver.resolve(path)
            guard !resolved.isDirectory else {
                throw HeadlessCommandError("Slice selection requires a file path, not a directory: \(resolved.displayPath)", exitCode: 2)
            }
            let ranges = try parseRanges(slice)
            entries.append(HeadlessSelectionEntry(rootID: resolved.root.id, relativePath: resolved.relativePath, mode: .slices, ranges: ranges))
        }
        return normalized(entries)
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
            let bounds = piece.split(separator: "-", maxSplits: 1).map(String.init)
            guard let start = Int(bounds[0]), start > 0 else {
                throw HeadlessCommandError("Invalid slice line spec: \(piece)", exitCode: 2)
            }
            let end = bounds.count == 2 ? (Int(bounds[1]) ?? start) : start
            guard end >= start else {
                throw HeadlessCommandError("Invalid slice line range: \(piece)", exitCode: 2)
            }
            return HeadlessLineRange(startLine: start, endLine: end)
        }
    }

    private static func selectionResponse(selection: [HeadlessSelectionEntry], roots: [HeadlessAllowedRoot], title: String, note: String?) throws -> HeadlessJSONObject {
        var lines = [title, "- **Files**: \(selection.count)", "- **Auto-codemap**: disabled in headless v1"]
        if let note { lines.append("- **Note**: \(note)") }
        for entry in normalized(selection) {
            lines.append("- `\(displayPath(for: entry, roots: roots))` (\(entry.mode.rawValue)\(rangeSuffix(entry.ranges)))")
        }
        return try HeadlessToolResponse.success(text: lines.joined(separator: "\n"), structured: [
            "files": HeadlessJSONValue.value(normalized(selection)),
            "codemap_auto_enabled": false,
            "total_tokens": 0,
            "summary": "\(selection.count) selected entr\(selection.count == 1 ? "y" : "ies")"
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

    private static func normalized(_ selection: [HeadlessSelectionEntry]) -> [HeadlessSelectionEntry] {
        var result: [HeadlessSelectionEntry] = []
        for entry in selection {
            if let index = result.firstIndex(where: { $0.rootID == entry.rootID && $0.relativePath == entry.relativePath }) {
                result[index] = entry
            } else {
                result.append(entry)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.rootID == rhs.rootID {
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
            return lhs.rootID.uuidString < rhs.rootID.uuidString
        }
    }
}
