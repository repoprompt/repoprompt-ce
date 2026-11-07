import Foundation
import RepoPromptAgentProviderContracts

extension NativeAgentRuntimeRuntimeInitStatus {
    var repoPromptServerStatus: String? {
        mcpServerStatuses.first {
            $0.key.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        }?.value
    }

    var isRepoPromptServerFailed: Bool {
        guard let status = repoPromptServerStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return status == "failed"
    }
}
