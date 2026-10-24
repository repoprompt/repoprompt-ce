import MCP

/// Keeps scope-selected inventory counts visible when a provider previews only the first rows.
/// The complete structured result remains unchanged beneath this bounded summary.
enum SessionAdminToolOutputFormatter {
    static func format(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        guard args["op"]?.stringValue == "inventory",
              let object = value.objectValue,
              object["result"]?.stringValue == "ok",
              let total = object["total"]?.intValue,
              let totalComplete = object["total_complete"]?.boolValue,
              let historyComplete = object["history_complete"]?.boolValue,
              let endpointsComplete = object["endpoints_complete"]?.boolValue,
              let truncated = object["truncated"]?.boolValue,
              let sessions = object["sessions"]?.arrayValue
        else {
            return ToolOutputFormatter.formatGeneric(value: value)
        }

        let countStatus = totalComplete ? "complete" : "lower bound; completeness unproven"
        var lines = [
            "Session inventory: \(total) matching session identities (\(countStatus)); \(sessions.count) rows returned.",
            "Coverage: total_complete=\(totalComplete), history_complete=\(historyComplete), endpoints_complete=\(endpointsComplete).",
            "Row-limit truncated=\(truncated). Counts cover only the approved scope and requested filter."
        ]
        if !totalComplete {
            lines.append("An incomplete count, including zero, does not prove an empty workspace or matching set.")
        }
        if !endpointsComplete {
            lines.append("Endpoint/link/orphan coverage is incomplete; this is separate from the selected count's completeness.")
        }
        if truncated {
            lines.append("The row limit omitted matches; these rows are not the complete matching set.")
        }
        lines.append("A provider preview may omit rows. Use the total above, not the number of visible rows.")
        return [.text(lines.joined(separator: "\n") + "\n\n```json\n" + ToolOutputFormatter.prettyJSON(value) + "\n```")]
    }
}
