import Foundation

enum AgentSelectedFilesDiagnostics {
    static func timestampMSIfEnabled() -> Double? {
        #if DEBUG
            AgentModePerfDiagnostics.timestampMSIfEnabled()
        #else
            nil
        #endif
    }

    static func elapsedFields(since startMS: Double?) -> [String: String] {
        #if DEBUG
            guard let startMS else { return [:] }
            return ["duration": AgentModePerfDiagnostics.formatElapsedMS(since: startMS)]
        #else
            [:]
        #endif
    }

    static func event(
        _ name: String,
        fields: [String: String] = [:],
        includeStack: Bool = false
    ) {
        #if DEBUG
            guard AgentModePerfDiagnostics.isEnabled else { return }
            var fields = fields
            if includeStack {
                fields["stack"] = compactCallStack()
            }
            AgentModePerfDiagnostics.event("selectedFiles.\(name)", fields: fields)
        #endif
    }

    static func durationEvent(
        _ name: String,
        startMS: Double?,
        fields: [String: String] = [:]
    ) {
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent("selectedFiles.\(name)", startMS: startMS, fields: fields)
        #endif
    }

    static func shortID(_ id: UUID?) -> String {
        #if DEBUG
            AgentModePerfDiagnostics.shortID(id)
        #else
            "nil"
        #endif
    }

    static func selectionFields(_ selection: StoredSelection) -> [String: String] {
        #if DEBUG
            let nonEmptySlices = selection.slices.filter { !$0.value.isEmpty }
            let sliceRanges = nonEmptySlices.values.reduce(0) { $0 + $1.count }
            return [
                "selectedPaths": String(selection.selectedPaths.count),
                "autoCodemapPaths": String(selection.autoCodemapPaths.count),
                "sliceFiles": String(nonEmptySlices.count),
                "sliceRanges": String(sliceRanges),
                "codemapAutoEnabled": String(selection.codemapAutoEnabled)
            ]
        #else
            [:]
        #endif
    }

    static func sourceFields(_ source: AgentContextExportSource) -> [String: String] {
        #if DEBUG
            var fields = selectionFields(source.selection)
            fields["tabID"] = shortID(source.tabID)
            fields["activeAgentSessionID"] = shortID(source.activeAgentSessionID)
            fields["bindingCount"] = String(source.worktreeBindings.count)
            fields["bindingFingerprint"] = String(source.exportContextIdentity.worktreeBindingFingerprint.prefix(16))
            fields["promptChars"] = String(source.promptText.count)
            return fields
        #else
            [:]
        #endif
    }

    static func requestFields(_ request: AgentSelectedFilesModelRequest) -> [String: String] {
        #if DEBUG
            var fields = sourceFields(request.source)
            fields["filePathDisplay"] = String(describing: request.filePathDisplay)
            fields["codeMapUsage"] = String(describing: request.codeMapUsage)
            return fields
        #else
            [:]
        #endif
    }

    private static func compactCallStack() -> String {
        Thread.callStackSymbols
            .dropFirst(3)
            .prefix(10)
            .map { symbol in
                symbol
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: " <- ")
    }
}
