import Foundation

/// Grok Build session-update normalizer. Native search_replace/write calls are
/// classified as edit before shared transcript merging. Terminal tool updates reuse
/// the shared canonical durable-result adapter; all other updates delegate to the
/// default ACP normalizer. Grok's `_x.ai/*` extension updates ride separate methods
/// and never reach this normalizer.
enum GrokBuildACPEventNormalizer {
    static func normalize(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        guard let sessionUpdate = (payload["sessionUpdate"] as? String)?.lowercased() else {
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .grokBuild)
        }

        switch sessionUpdate {
        case "tool_call", "tool_call_update":
            var normalizedPayload = payload
            if sessionUpdate == "tool_call" {
                let nativeName = ACPRuntimeEventParsing.normalizedToolName(from: payload)
                if nativeName == "search_replace" || nativeName == "write" {
                    normalizedPayload["toolName"] = "edit"
                }
            }
            normalizedPayload = ACPToolUpdateResultAdapter.adaptedTerminalToolUpdatePayload(normalizedPayload, sessionUpdate: sessionUpdate)
            if sessionUpdate == "tool_call_update",
               ACPRuntimeEventParsing.firstString(in: normalizedPayload, keys: ["status"])?.lowercased() == "completed",
               var result = normalizedPayload["rawOutput"] as? [String: Any],
               result["acp_status"] as? String == "completed",
               result["status"] as? String == "success",
               let content = result["content"] as? [Any]
            {
                // Enrich the canonical result, after the adapter's raw-output failure checks.
                result["content"] = content.map { value -> Any in
                    guard var item = value as? [String: Any], let diff = nativeEditUnifiedDiff(item) else { return value }
                    item["unified_diff"] = diff
                    return item
                }
                normalizedPayload["rawOutput"] = result
            }
            return ACPDefaultSessionUpdateNormalizer.normalize(normalizedPayload, providerID: .grokBuild)
        default:
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .grokBuild)
        }
    }

    private static func nativeEditUnifiedDiff(_ item: [String: Any]) -> String? {
        guard item["type"] as? String == "diff", item["unified_diff"] == nil,
              let path = item["path"] as? String, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let metadata = item["_meta"] as? [String: Any],
              let details = metadata["details"] as? [[String: Any]], !details.isEmpty
        else { return nil }

        let byteLimit = ACPToolUpdateResultAdapter.generatedDiffInputBytesLimit
        let lineLimit = ACPToolUpdateResultAdapter.generatedDiffInputLineLimit
        var totalBytes = 0
        var totalLines = 0
        var totalSplitLines = 0
        var precedingDelta = 0
        var chunks: [DiffChunk] = []
        for detail in details {
            guard let oldLine = positiveLineNumber(detail["old_line"]),
                  let newLine = positiveLineNumber(detail["new_line"]), oldLine == newLine,
                  let oldText = detail["old_string"] as? String,
                  let newText = detail["new_string"] as? String
            else { return nil }

            totalBytes += oldText.utf8.count + newText.utf8.count
            guard totalBytes <= byteLimit else { return nil }
            totalLines += oldText.split(separator: "\n", omittingEmptySubsequences: false).count
                + newText.split(separator: "\n", omittingEmptySubsequences: false).count
            guard totalLines <= lineLimit else { return nil }

            let oldLines = String.splitContentPreservingLineEndings(oldText).0
            let newLines = String.splitContentPreservingLineEndings(newText).0
            totalSplitLines += oldLines.count + newLines.count
            guard totalSplitLines <= lineLimit else { return nil }
            // Grok reports both coordinates in post-edit text. Undo earlier edits'
            // line deltas; build() reapplies those deltas to derive the new starts.
            let (oldStart, overflow) = newLine.subtractingReportingOverflow(precedingDelta)
            guard !overflow, oldStart > 0, oldStart <= Int.max - lineLimit, newLine <= Int.max - lineLimit else { return nil }
            chunks += UnifiedDiffGenerator.diffChunks(oldLines: oldLines, newLines: newLines, context: 2).map { chunk in
                var shifted = chunk
                shifted.startLine += oldStart - 1
                return shifted
            }
            precedingDelta += newLines.count - oldLines.count
        }
        let diff = UnifiedDiffGenerator.build(filePath: path, chunks: chunks, context: 2)
        return diff.isEmpty ? nil : diff
    }

    private static func positiveLineNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = number as? Int, integer > 0
        else { return nil }
        return integer
    }
}
