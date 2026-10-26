import Foundation
import RepoPromptInstrumentation

typealias AgentSelectedFilesDiagnostics = WorkspaceSelectedFilesDiagnostics

extension WorkspaceSelectedFilesDiagnostics {
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
}
