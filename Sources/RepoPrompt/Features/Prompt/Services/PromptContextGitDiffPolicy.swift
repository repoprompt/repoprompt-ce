import Foundation

enum PromptContextGitDiffPolicy {
    static let deferredCompleteWorktreeGitDiffMessage = "Complete git diff export is not available for worktree-bound context yet; this export intentionally omits the base-checkout complete diff. Use selected-file diff for worktree-aware diff details."
    static let unavailableCompleteGitDiffMessage = "Complete git diff export is not available because no git repository root is selected for this context."
}
