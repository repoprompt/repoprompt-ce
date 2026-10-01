import Foundation

/// Decides what a later result update for an already-tracked tool call stores.
///
/// ACP agents stream several updates per call. Devin, for example, sends
/// `running` progress, then `running` with the actual output, then a terminal
/// update with no output. RepoPrompt's own MCP tools also get an authoritative
/// structured result from the tool tracker, which provider echoes must not erase
/// (that is what hid Oracle lane coverage on tool cards).
enum AgentToolResultPayloadRetention {
    /// The payload to store, or nil to keep `existing` unchanged.
    ///
    /// With `requireObjectReplacement`, used for RepoPrompt's own MCP tools whose
    /// results are JSON objects, an earlier JSON object result is also kept when
    /// the incoming payload is not a JSON object (for example a bare text echo).
    static func resolvedPayload(
        existing: String?,
        incoming: String,
        incomingIsError: Bool?,
        requireObjectReplacement: Bool = false
    ) -> String? {
        if incomingIsError != true,
           let terminalStatus = terminalMarkerStatus(incoming),
           var object = jsonObject(existing),
           isLifecycleStatus(object["status"])
        {
            object["status"] = terminalStatus
            // A presentation summary may already carry the lifecycle word; the card
            // trusts `render_summary.status`, so finish it there too.
            if var renderSummary = object["render_summary"] as? [String: Any] {
                if isLifecycleStatus(renderSummary["status"]) {
                    renderSummary["status"] = terminalStatus == "failed" ? "failure" : "success"
                }
                if isLifecycleStatus(renderSummary["detail_text"]) {
                    renderSummary.removeValue(forKey: "detail_text")
                }
                object["render_summary"] = renderSummary
            }
            if isLifecycleStatus(object["summary_text"]) {
                object.removeValue(forKey: "summary_text")
            }
            return serialize(object) ?? incoming
        }
        return shouldKeepExisting(
            existing: existing,
            incoming: incoming,
            incomingIsError: incomingIsError,
            requireObjectReplacement: requireObjectReplacement
        ) ? nil : incoming
    }

    /// True when `incoming` carries no output and should not replace `existing`.
    static func shouldKeepExisting(
        existing: String?,
        incoming: String?,
        incomingIsError: Bool?,
        requireObjectReplacement: Bool = false
    ) -> Bool {
        guard incomingIsError != true, !isThin(existing), !isProgress(existing) else { return false }
        if isThin(incoming) || isProgress(incoming) || terminalMarkerStatus(incoming) != nil { return true }
        guard requireObjectReplacement else { return false }
        return isJSONObject(existing) && !isJSONObject(incoming)
    }

    static func isThin(_ payload: String?) -> Bool {
        guard let trimmed = payload?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return true }
        switch trimmed {
        case "{}", "[]", "null", "\"\"":
            return true
        default:
            return false
        }
    }

    /// A provider progress update such as `{"status":"running","title":"…"}`.
    static func isProgress(_ payload: String?) -> Bool {
        guard let object = jsonObject(payload), isLifecycleStatus(object["status"]) else { return false }
        return Set(object.keys).isSubset(of: ["status", "title", "kind", "summary_only"])
    }

    /// `completed` / `failed` for a bare `{"status":…}` terminal marker.
    static func terminalMarkerStatus(_ payload: String?) -> String? {
        guard let object = jsonObject(payload), object.count == 1,
              let status = (object["status"] as? String)?.lowercased(),
              status == "completed" || status == "failed"
        else { return nil }
        return status
    }

    static func isJSONObject(_ payload: String?) -> Bool {
        jsonObject(payload) != nil
    }

    private static func isLifecycleStatus(_ value: Any?) -> Bool {
        guard let status = (value as? String)?.lowercased() else { return false }
        return ["running", "pending", "in_progress"].contains(status)
    }

    private static func jsonObject(_ payload: String?) -> [String: Any]? {
        guard let data = payload?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              data.first == UInt8(ascii: "{")
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func serialize(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
