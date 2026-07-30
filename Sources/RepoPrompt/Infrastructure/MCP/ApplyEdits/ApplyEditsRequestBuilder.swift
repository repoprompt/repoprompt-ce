import Foundation
import Logging
import MCP

struct ApplyEditsRequestBuilder {
    func build(from args: [String: Value]) throws -> ApplyEditsRequest {
        let normalized = MCPToolArgsNormalizer.normalize(
            params: args,
            originalToolName: "apply_edits",
            canonicalToolName: "apply_edits"
        )
        return try buildFromPayload(normalized.payload)
    }

    func buildFromNormalizedPayload(_ payload: [String: Value]) throws -> ApplyEditsRequest {
        try buildFromPayload(payload)
    }

    private func buildFromPayload(_ payload: [String: Value]) throws -> ApplyEditsRequest {
        guard let path = Self.coercePathArg(payload) else {
            throw ApplyEditsError.invalidParams("missing path")
        }

        let verbose = payload["verbose"]?.boolValue ?? false

        let rewriteText: String? = payload["rewrite"]?.stringValue.map { cleanText($0) }
        let onMissing = parseOnMissing(from: payload)

        let single = try parseSingleEdit(from: payload)
        let batch = try parseBatchEdits(from: payload)

        let shapeCount = (rewriteText != nil ? 1 : 0) + (single != nil ? 1 : 0) + (batch != nil ? 1 : 0)
        if shapeCount == 0 {
            throw ApplyEditsError.invalidParams("Provide exactly one of: `rewrite`, `replace`, or `edits`.")
        }
        if shapeCount > 1 {
            throw ApplyEditsError.invalidParams("Multiple edit shapes provided. Use only one of: `rewrite`, `replace`, or `edits`.")
        }

        if let rewriteText {
            try ApplyEditsEchoGuard.validate(replacement: rewriteText, path: path)
            return ApplyEditsRequest(
                path: path,
                mode: .rewrite(newText: rewriteText, onMissing: onMissing),
                verbose: verbose
            )
        }

        if let single {
            try ApplyEditsEchoGuard.validate(replacement: single.replace, path: path)
            return ApplyEditsRequest(
                path: path,
                mode: .single(search: single.search, replace: single.replace, replaceAll: single.replaceAll),
                verbose: verbose
            )
        }

        if let batch {
            for op in batch {
                try ApplyEditsEchoGuard.validate(replacement: op.replace, path: path)
            }
            return ApplyEditsRequest(
                path: path,
                mode: .batch(batch),
                verbose: verbose
            )
        }

        throw ApplyEditsError.internalError("Internal error: no valid edit shape found")
    }

    private func parseSingleEdit(from payload: [String: Value]) throws -> ApplyEditsOperation? {
        let repairedPayload = MCPToolArgsNormalizer.repairMalformedReplacement(in: payload).repaired
        let missingReplacementMessage = "must have 'replace', 'with', or 'content' field."
        let emptySearchMessage = "search cannot be empty for replace operations; omit 'search' to rewrite the entire file"

        if let searchRaw = repairedPayload["search"]?.stringValue {
            return try parseOperation(
                fromRepaired: repairedPayload,
                searchRaw: searchRaw,
                replacementRaw: replacementString(from: repairedPayload),
                missingReplacementMessage: missingReplacementMessage,
                emptySearchMessage: emptySearchMessage
            )
        }

        if let searchRaw = repairedPayload["replace"]?.stringValue,
           let replaceRaw = alternateReplacementString(from: repairedPayload)
        {
            return try makeOperation(
                searchRaw: searchRaw,
                replaceRaw: replaceRaw,
                replaceAll: replaceAll(from: repairedPayload),
                emptySearchMessage: emptySearchMessage
            )
        }

        if let replaceObj = repairedPayload["replace_obj"]?.objectValue ?? repairedPayload["replace"]?.objectValue {
            let repaired = MCPToolArgsNormalizer.repairMalformedReplacement(in: replaceObj).repaired
            if let searchRaw = repaired["search"]?.stringValue {
                return try parseOperation(
                    fromRepaired: repaired,
                    searchRaw: searchRaw,
                    replacementRaw: replacementString(from: repaired),
                    missingReplacementMessage: missingReplacementMessage,
                    emptySearchMessage: emptySearchMessage
                )
            }
        }

        if let replaceString = repairedPayload["replace"]?.stringValue,
           !replaceString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let obj = Value.objectFromJSONString(replaceString)
        {
            let repaired = MCPToolArgsNormalizer.repairMalformedReplacement(in: obj).repaired
            if let searchRaw = repaired["search"]?.stringValue {
                return try parseOperation(
                    fromRepaired: repaired,
                    searchRaw: searchRaw,
                    replacementRaw: replacementString(from: repaired),
                    missingReplacementMessage: missingReplacementMessage,
                    emptySearchMessage: emptySearchMessage
                )
            }
        }

        return nil
    }

    private func parseBatchEdits(from payload: [String: Value]) throws -> [ApplyEditsOperation]? {
        if let editsArray = payload["edits"]?.arrayValue {
            guard !editsArray.isEmpty else {
                throw ApplyEditsError.invalidParams("edits array cannot be empty")
            }
            return try parseEditArray(editsArray)
        }

        if let editsObj = payload["edits"]?.objectValue {
            return try [parseEditObject(editsObj, errorMessage: "edits object must contain 'search' and 'with' (or 'content')")]
        }

        if let editsString = payload["edits"]?.stringValue,
           !editsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard let parsed = Value.fromJSONString(editsString) else {
                throw ApplyEditsError.invalidParams("`edits` was provided as a string that could not be parsed as JSON. Provide an array of objects or a JSON string that decodes to that shape.")
            }
            if let array = parsed.arrayValue {
                guard !array.isEmpty else {
                    throw ApplyEditsError.invalidParams("edits array cannot be empty")
                }
                return try parseEditArray(array)
            }
            if let object = parsed.objectValue {
                return try [parseEditObject(object, errorMessage: "edits JSON string must contain 'search' and 'with' (or 'content')")]
            }
            throw ApplyEditsError.invalidParams("`edits` was provided as a string that could not be parsed as JSON. Provide an array of objects or a JSON string that decodes to that shape.")
        }

        return nil
    }

    private func parseEditArray(_ array: [Value]) throws -> [ApplyEditsOperation] {
        var edits: [ApplyEditsOperation] = []
        edits.reserveCapacity(array.count)
        for editValue in array {
            guard let editObj = editValue.objectValue else {
                throw ApplyEditsError.invalidParams("Each edit must have 'search' and 'with' (or 'content') fields")
            }
            let op = try parseEditObject(editObj, errorMessage: "Each edit must have 'search' and 'with' (or 'content') fields")
            edits.append(op)
        }
        return edits
    }

    private func parseEditObject(
        _ obj: [String: Value],
        errorMessage: String
    ) throws -> ApplyEditsOperation {
        let repaired = MCPToolArgsNormalizer.repairMalformedReplacement(in: obj).repaired
        guard let searchRaw = repaired["search"]?.stringValue else {
            throw ApplyEditsError.invalidParams(errorMessage)
        }
        return try parseOperation(
            fromRepaired: repaired,
            searchRaw: searchRaw,
            replacementRaw: replacementString(from: repaired),
            missingReplacementMessage: errorMessage,
            emptySearchMessage: "search cannot be empty for replace operations; provide a non-empty search or use the single-edit rewrite path by omitting 'edits' and passing only 'content'"
        )
    }

    private func parseOperation(
        fromRepaired obj: [String: Value],
        searchRaw: String,
        replacementRaw: String?,
        missingReplacementMessage: String,
        emptySearchMessage: String
    ) throws -> ApplyEditsOperation {
        guard let replacementRaw else {
            throw ApplyEditsError.invalidParams(missingReplacementMessage)
        }
        return try makeOperation(
            searchRaw: searchRaw,
            replaceRaw: replacementRaw,
            replaceAll: replaceAll(from: obj),
            emptySearchMessage: emptySearchMessage
        )
    }

    private func makeOperation(
        searchRaw: String,
        replaceRaw: String,
        replaceAll: Bool,
        emptySearchMessage: String
    ) throws -> ApplyEditsOperation {
        let search = cleanText(searchRaw)
        let replace = cleanText(replaceRaw)
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplyEditsError.invalidParams(emptySearchMessage)
        }
        return ApplyEditsOperation(search: search, replace: replace, replaceAll: replaceAll)
    }

    private func replacementString(from payload: [String: Value]) -> String? {
        payload["replace"]?.stringValue
            ?? payload["with"]?.stringValue
            ?? payload["content"]?.stringValue
    }

    private func alternateReplacementString(from payload: [String: Value]) -> String? {
        payload["with"]?.stringValue ?? payload["content"]?.stringValue
    }

    private func replaceAll(from payload: [String: Value]) -> Bool {
        payload["all"]?.boolValue ?? payload["replace_all"]?.boolValue ?? false
    }

    private func parseOnMissing(from payload: [String: Value]) -> OnMissing {
        let raw = payload["on_missing"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let raw, !raw.isEmpty else {
            return .error
        }
        switch raw {
        case "error":
            return .error
        case "create":
            return .create
        default:
            return .error
        }
    }

    private func cleanText(_ text: String) -> String {
        Self.sanitizeParamArtifacts(text)
    }

    private static let pathArgKeys = ["path", "file", "filepath", "file_path", "target", "full_path", "abs_path", "absolute_path", "rel_path", "relative_path"]

    private static func coercePathArg(_ args: [String: Value]) -> String? {
        for key in pathArgKeys {
            if let value = args[key]?.stringValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func sanitizeParamArtifacts(_ text: String) -> String {
        guard text.contains("<parameter name=\"") else {
            return text
        }
        var out = text
        while let start = out.range(of: "<parameter name=\"") {
            if let end = out[start.upperBound...].firstIndex(of: ">") {
                out.removeSubrange(start.lowerBound ... end)
            } else {
                break
            }
        }
        return out
    }
}

private enum ApplyEditsEchoGuard {
    private static let logger = Logger(label: "com.repoprompt.mcp.applyedits.guard")

    static func validate(replacement: String, path: String) throws {
        let reasons = hardRejectReasons(replacement)
        guard reasons.isEmpty else {
            let message = "Refusing to apply edit: replacement for '\(path)' contains tool-call artifacts. "
                + "Reasons: " + reasons.joined(separator: "; ")
                + ". Please resend a clean 'apply_edits' with only the intended code."
            logger.warning("\(message)")
            throw ApplyEditsError.invalidParams(message)
        }
    }

    private static func hardRejectReasons(_ text: String) -> [String] {
        var reasons: [String] = []

        @inline(__always)
        func countOccurrences(_ haystack: String, _ needle: String) -> Int {
            var count = 0
            var searchRange: Range<String.Index>? = haystack.startIndex ..< haystack.endIndex
            while let found = haystack.range(of: needle, options: [.caseInsensitive], range: searchRange) {
                count += 1
                searchRange = found.upperBound ..< haystack.endIndex
            }
            return count
        }

        if text.range(of: "to=functions", options: .caseInsensitive) != nil {
            let matches = countOccurrences(text, "to=functions")
            reasons.append("'to=functions' token present \(matches)x")
        }
        if text.range(of: "RepoPrompt__apply_edits", options: .caseInsensitive) != nil {
            reasons.append("'RepoPrompt__apply_edits' token present")
        }

        let applyHits = countOccurrences(text, "apply_edits")
        if applyHits >= 10 {
            reasons.append("'apply_edits' appears \(applyHits)x inside replacement")
        }

        return reasons
    }
}
