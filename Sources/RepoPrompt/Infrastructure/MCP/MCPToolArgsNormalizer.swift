import Foundation
import MCP

// Generic MCP tool-call argument normalization.
// Handles JSON-string payloads, tool-name wrappers, hidden routing fields, and
// best-effort repairs for malformed edit replacement arguments.

// MARK: - Argument Normalization

/// Result of normalizing MCP tool call arguments
struct NormalizedArgs {
    /// Cleaned argument payload with hidden routing fields removed.
    var payload: [String: Value]
    /// Extracted tab ID if present (for tab binding)
    var tabID: UUID?
    /// Extracted window ID if present (for window routing)
    var windowID: Int?
    /// Extracted logical context ID if present (canonical public binding handle)
    var contextID: UUID?
    /// Extracted working directories if present (bind_context-only selector)
    var workingDirs: [String]
    /// Whether caller requested raw JSON output (skip markdown formatting)
    var rawJSON: Bool = false
    /// Warnings generated during normalization (e.g., unwrapped tool-name wrapper)
    var warnings: [String]
}

/// Pure, stateless helpers for argument sanitization
enum MCPToolArgsNormalizer {
    /// Normalize MCP tool call arguments by:
    /// 1. Parsing JSON strings
    /// 2. Unwrapping Codex-style "args" wrappers
    /// 3. Unwrapping tool-name wrappers (e.g., {"apply_edits": {...}})
    /// 4. Stripping hidden routing fields
    /// 5. Repairing malformed replacement keys
    static func normalize(
        params: [String: Value]?,
        originalToolName: String,
        canonicalToolName: String
    ) -> NormalizedArgs {
        guard var raw = params else {
            return NormalizedArgs(payload: [:], tabID: nil, windowID: nil, contextID: nil, workingDirs: [], rawJSON: false, warnings: [])
        }

        var warnings: [String] = []

        // Case 1: Entire arguments payload is a single JSON string → treat it as the object
        if raw.count == 1, let (_, onlyVal) = raw.first, case let .string(s) = onlyVal,
           let obj = Value.objectFromJSONString(s)
        {
            raw = obj
        }

        // Case 2: Codex-style "args" is a JSON string → decode it
        if let v = raw["args"], case let .string(s) = v {
            if let obj = Value.objectFromJSONString(s) {
                raw["args"] = .object(obj)
            } else if let parsed = Value.fromJSONString(s) {
                // If it wasn't an object but still valid JSON (e.g. array), preserve it
                raw["args"] = parsed
            }
        }

        // Case 3: Best-effort—parse any other JSON-string subfields
        for (k, v) in raw {
            if case let .string(s) = v {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if (t.first == "{" && t.last == "}") || (t.first == "[" && t.last == "]") {
                    if let parsed = Value.fromJSONString(t) {
                        raw[k] = parsed
                    }
                }
            }
        }

        // Case 4: Unwrap tool-name nesting at top level
        let wrapperKeys = wrapperCandidateToolNames(
            originalToolName: originalToolName,
            canonicalToolName: canonicalToolName
        )
        let (unwrappedTop, didUnwrapTop) = unwrapToolNameNesting(
            in: raw,
            candidates: wrapperKeys,
            primaryTool: canonicalToolName
        )
        raw = unwrappedTop
        if didUnwrapTop {
            warnings.append("Unwrapped tool-name wrapper at top level")
        }

        // Case 5: Unwrap tool-name nesting inside "args" if present
        if let argsValue = raw["args"] {
            var nestedArgs: [String: Value]?
            if let o = argsValue.objectValue {
                nestedArgs = o
            } else if let s = argsValue.stringValue, let parsed = Value.objectFromJSONString(s) {
                nestedArgs = parsed
            }

            if let nested = nestedArgs {
                let (flatNested, didUnwrap) = unwrapToolNameNesting(
                    in: nested,
                    candidates: wrapperKeys,
                    primaryTool: canonicalToolName
                )
                if didUnwrap {
                    warnings.append("Unwrapped tool-name wrapper inside args")
                    // Merge top-level siblings into the flattened nested object
                    var merged = flatNested
                    for (k, v) in raw where k != "args" && merged[k] == nil {
                        merged[k] = v
                    }
                    raw = merged
                } else {
                    // No unwrap happened, just update the args value with decoded version
                    raw["args"] = .object(flatNested)
                }
            }
        }

        // Case 6: Strip supported hidden routing fields and extract supported ones
        let shouldExtractWorkingDirs = canonicalToolName == "bind_context"
        var extractedTabID: UUID?
        var extractedWindowID: Int?
        var extractedContextID: UUID?
        var extractedWorkingDirs: [String] = []
        var extractedRawJSON = false

        // Check if params are wrapped in an "args" key (Codex format)
        if let nestedArgsValue = raw["args"] {
            var nestedArgs: [String: Value]? = nestedArgsValue.objectValue
            if nestedArgs == nil, let s = nestedArgsValue.stringValue,
               let parsed = Value.objectFromJSONString(s)
            {
                nestedArgs = parsed
            }

            if var nestedArgs {
                // Extract _tabID if present in nested payload
                if let tabIDValue = nestedArgs["_tabID"],
                   let tabIDString = tabIDValue.stringValue,
                   let tabID = UUID(uuidString: tabIDString)
                {
                    extractedTabID = tabID
                    nestedArgs.removeValue(forKey: "_tabID")
                }

                // Extract _windowID if present in nested payload
                if let windowIDValue = nestedArgs["_windowID"] {
                    if let windowIDInt = windowIDValue.intValue {
                        extractedWindowID = windowIDInt
                    } else if let windowIDString = windowIDValue.stringValue,
                              let windowID = Int(windowIDString)
                    {
                        extractedWindowID = windowID
                    }
                    nestedArgs.removeValue(forKey: "_windowID")
                }

                // Extract _rawJSON if present in nested payload
                if let rawValue = nestedArgs["_rawJSON"] {
                    if let b = parseBool(rawValue) { extractedRawJSON = b }
                    nestedArgs.removeValue(forKey: "_rawJSON")
                }

                if let contextIDValue = nestedArgs["context_id"],
                   let contextIDString = contextIDValue.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let contextID = UUID(uuidString: contextIDString)
                {
                    extractedContextID = contextID
                    nestedArgs.removeValue(forKey: "context_id")
                }

                if shouldExtractWorkingDirs, let workingDirsValue = nestedArgs["working_dirs"] {
                    extractedWorkingDirs = parseWorkingDirs(from: workingDirsValue)
                    nestedArgs.removeValue(forKey: "working_dirs")
                }

                raw = nestedArgs
            }
        } else {
            // Check top level (direct format)

            if let tabIDValue = raw["_tabID"],
               let tabIDString = tabIDValue.stringValue,
               let tabID = UUID(uuidString: tabIDString)
            {
                extractedTabID = tabID
                raw.removeValue(forKey: "_tabID")
            }

            if let windowIDValue = raw["_windowID"] {
                if let windowIDInt = windowIDValue.intValue {
                    extractedWindowID = windowIDInt
                } else if let windowIDString = windowIDValue.stringValue,
                          let windowID = Int(windowIDString)
                {
                    extractedWindowID = windowID
                }
                raw.removeValue(forKey: "_windowID")
            }

            if let rawValue = raw["_rawJSON"] {
                if let b = parseBool(rawValue) { extractedRawJSON = b }
                raw.removeValue(forKey: "_rawJSON")
            }

            if let contextIDValue = raw["context_id"],
               let contextIDString = contextIDValue.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               let contextID = UUID(uuidString: contextIDString)
            {
                extractedContextID = contextID
                raw.removeValue(forKey: "context_id")
            }

            if shouldExtractWorkingDirs, let workingDirsValue = raw["working_dirs"] {
                extractedWorkingDirs = parseWorkingDirs(from: workingDirsValue)
                raw.removeValue(forKey: "working_dirs")
            }
        }

        return NormalizedArgs(
            payload: raw,
            tabID: extractedTabID,
            windowID: extractedWindowID,
            contextID: extractedContextID,
            workingDirs: extractedWorkingDirs,
            rawJSON: extractedRawJSON,
            warnings: warnings
        )
    }

    /// Repair malformed edit arguments where replacement text became a property name
    /// Example: {"search": "...", "\tprivate func...": "..."} → {"search": "...", "replace": "..."}
    static func repairMalformedReplacement(in args: [String: Value]) -> (repaired: [String: Value], didRepair: Bool) {
        // Try standard replacement keys first
        let replacementKeys: Set = ["replace", "with", "content"]
        for key in replacementKeys {
            if args[key]?.stringValue != nil {
                return (args, false) // Already has valid replacement key
            }
        }

        // Look for orphan entries that might be malformed replacement keys
        let ignoredKeys: Set<String> = Set(["search", "all", "path", "verbose"]).union(replacementKeys)
        let orphanEntries = args.filter { !ignoredKeys.contains($0.key) }

        if orphanEntries.count == 1,
           let lone = orphanEntries.first,
           let orphanValue = lone.value.stringValue,
           lone.key.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "\\" || $0.isNewline || $0 == "\t" || $0 == "\"" || $0 == "/" })
        {
            // Found a malformed key - repair it
            var repaired = args
            repaired.removeValue(forKey: lone.key)
            repaired["replace"] = .string(orphanValue)
            return (repaired, true)
        }

        return (args, false)
    }

    // MARK: - Private Helpers

    private static func wrapperCandidateToolNames(
        originalToolName: String,
        canonicalToolName: String
    ) -> [String] {
        let candidates = [originalToolName, canonicalToolName]
        return candidates.reduce(into: [String]()) { partial, candidate in
            guard !partial.contains(candidate) else { return }
            partial.append(candidate)
        }
    }

    private static func parseBool(_ value: Value) -> Bool? {
        switch value {
        case let .bool(b):
            return b
        case let .int(i):
            return i != 0
        case let .double(d):
            return d != 0
        case let .string(s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch t {
            case "1", "true", "yes", "y", "on":
                return true
            case "0", "false", "no", "n", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func parseWorkingDirs(from value: Value) -> [String] {
        switch value {
        case let .array(arr):
            arr.compactMap {
                $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        case let .string(raw):
            raw
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            []
        }
    }

    private static func allowedSiblingKeys(for tool: String) -> Set<String> {
        let common: Set = ["_tabID", "_windowID", "_rawJSON", "context_id", "path", "verbose", "args", "operation_id"]
        switch tool {
        case "bind_context":
            return common.union(["op", "window_id", "working_dirs", "create_if_missing", "tab_name"])
        case "apply_edits":
            return common.union(["rewrite", "search", "replace", "all", "replace_all", "edits", "with", "content", "on_missing"])
        case "read_file":
            return common.union(["start_line", "offset", "limit"])
        case "file_search":
            return common.union(["pattern", "regex", "mode", "context_lines", "count_only", "max_results"])
        default:
            return common // conservative fallback
        }
    }

    private static func unwrapToolNameNesting(
        in obj: [String: Value],
        candidates: [String],
        primaryTool: String
    ) -> (flattened: [String: Value], didUnwrap: Bool) {
        var result = obj
        var changed = false

        outer: while true {
            var didOne = false
            for key in candidates {
                guard let v = result[key] else { continue }

                var inner: [String: Value]?
                if let o = v.objectValue {
                    inner = o
                } else if let s = v.stringValue, let parsed = Value.objectFromJSONString(s) {
                    inner = parsed
                }
                guard let innerObj = inner else { continue }

                let siblings = Set(result.keys).subtracting([key])
                let allowed = allowedSiblingKeys(for: primaryTool).union(innerObj.keys)
                guard siblings.isSubset(of: allowed) else { continue }

                // Merge with precedence: inner overrides siblings
                var merged = innerObj
                for sk in siblings where merged[sk] == nil {
                    merged[sk] = result[sk]
                }

                result = merged
                didOne = true
                changed = true
                break
            }
            if !didOne { break outer }
        }

        return (result, changed)
    }
}
