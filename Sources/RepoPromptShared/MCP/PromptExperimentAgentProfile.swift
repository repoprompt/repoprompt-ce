import Foundation

/// Closed tool surface for a user-approved coding evaluation in a disposable workspace.
/// Both the agent launcher and direct MCP server consume this contract. It grants no
/// authority over an app window, persisted workspaces, shell commands, or other agents.
package enum PromptExperimentAgentProfile {
    package static let environmentKey = "REPOPROMPT_MCP_EXPERIMENT_PROFILE"
    package static let identifier = "engineer-v1"
    package static let toolNames: Set<String> = [
        "get_file_tree", "file_search", "read_file", "get_code_structure", "apply_edits", "file_actions"
    ]
    package static let mutationOperations: Set<String> = [
        "apply_edits.replace", "apply_edits.rewrite", "apply_edits.batch",
        "file_actions.create", "file_actions.move", "file_actions.rename", "file_actions.delete"
    ]
}
