import Foundation

enum AgentSelectedFilesDiagnostics {
    @TaskLocal static var correlationFields: [String: String] = [:]

    static var isEnabled: Bool {
        #if DEBUG
            AgentModePerfDiagnostics.isEnabled
        #else
            false
        #endif
    }

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
        fields: @autoclosure () -> [String: String] = [:],
        includeStack: Bool = false
    ) {
        #if DEBUG
            guard isEnabled else { return }
            var mergedFields = correlationFields
            mergedFields.merge(fields()) { _, new in new }
            if includeStack {
                mergedFields["stack"] = compactCallStack()
            }
            AgentModePerfDiagnostics.event("selectedFiles.\(name)", fields: mergedFields)
        #endif
    }

    static func durationEvent(
        _ name: String,
        startMS: Double?,
        fields: @autoclosure () -> [String: String] = [:]
    ) {
        #if DEBUG
            guard isEnabled, startMS != nil else { return }
            var mergedFields = correlationFields
            mergedFields.merge(fields()) { _, new in new }
            AgentModePerfDiagnostics.durationEvent("selectedFiles.\(name)", startMS: startMS, fields: mergedFields)
        #endif
    }

    static func shortID(_ id: UUID?) -> String {
        #if DEBUG
            AgentModePerfDiagnostics.shortID(id)
        #else
            "nil"
        #endif
    }

    #if DEBUG
        static func selectionFields(
            _ selection: StoredSelection,
            diagnosticsEnabled: Bool = isEnabled,
            signatureBuilder: (StoredSelection) -> [String: String] = {
                WorkspaceSelectionDebugSignature.unprefixedFields(for: $0)
            }
        ) -> [String: String] {
            guard diagnosticsEnabled else { return [:] }
            return signatureBuilder(selection)
        }
    #else
        static func selectionFields(_: StoredSelection) -> [String: String] {
            [:]
        }
    #endif

    static func sourceFields(_ source: AgentContextExportSource) -> [String: String] {
        #if DEBUG
            guard isEnabled else { return [:] }
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
            guard isEnabled else { return [:] }
            var fields = sourceFields(request.source)
            fields["filePathDisplay"] = String(describing: request.filePathDisplay)
            fields["codeMapUsage"] = String(describing: request.codeMapUsage)
            return fields
        #else
            [:]
        #endif
    }

    static func identityChangeFields(
        from previous: AgentSelectedFilesModelIdentity?,
        to next: AgentSelectedFilesModelIdentity
    ) -> [String: String] {
        #if DEBUG
            guard isEnabled else { return [:] }
            guard let previous else { return ["hasPreviousIdentity": "false"] }
            let previousExport = previous.exportContextIdentity
            let nextExport = next.exportContextIdentity
            return [
                "hasPreviousIdentity": "true",
                "selectionChanged": String(previousExport.selection != nextExport.selection),
                "tabChanged": String(previousExport.tabID != nextExport.tabID),
                "sessionChanged": String(previousExport.activeAgentSessionID != nextExport.activeAgentSessionID),
                "bindingChanged": String(
                    previousExport.worktreeBindingFingerprint != nextExport.worktreeBindingFingerprint
                ),
                "filePathDisplayChanged": String(previous.filePathDisplay != next.filePathDisplay),
                "codeMapUsageChanged": String(previous.codeMapUsage != next.codeMapUsage)
            ]
        #else
            [:]
        #endif
    }

    static func planningMetricsFields(
        _ metrics: WorkspaceCodemapPresentationPlanningMetrics
    ) -> [String: String] {
        #if DEBUG
            guard isEnabled else { return [:] }
            return [
                "rootCount": String(metrics.rootCount),
                "fileEnumerationRequests": String(metrics.fileEnumerationRequestCount),
                "examinedFiles": String(metrics.examinedFileCount),
                "supportedCandidates": String(metrics.supportedCandidateCount),
                "requestedFiles": String(metrics.requestedFileCount),
                "completeRootSet": String(metrics.completeRootSet)
            ]
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
