import Foundation

extension RepoPromptWorkflowPrompts {
    // MARK: - CLI Variants (convenience accessors)

    /// CLI variant of rp-investigate - uses rpce-cli commands instead of MCP tools.
    static var rpInvestigateCLI: String {
        rpInvestigate(variant: .cli)
    }

    /// CLI variant of rp-deep-plan - uses rpce-cli commands instead of MCP tools.
    static var rpDeepPlanCLI: String {
        rpDeepPlan(variant: .cli)
    }

    /// CLI variant of rp-build - uses rpce-cli commands instead of MCP tools.
    static var rpBuildCLI: String {
        rpBuild(variant: .cli)
    }

    /// CLI variant of rp-orchestrate - uses rpce-cli commands instead of MCP tools.
    static var rpOrchestrateCLI: String {
        rpOrchestrate(variant: .cli)
    }

    /// CLI variant of rp-optimize - uses rpce-cli commands instead of MCP tools.
    static var rpOptimizeCLI: String {
        rpOptimize(variant: .cli)
    }

    // MARK: - Agent Variants (convenience accessors)

    /// Agent variant of rp-build - no Phase 0, uses ask_oracle instead of oracle_send.
    static var rpBuildAgent: String {
        rpBuild(variant: .agent)
    }

    /// Agent variant of rp-review - no Step 0, uses ask_oracle and ask_user.
    static var rpReviewAgent: String {
        rpReview(variant: .agent)
    }

    /// Agent variant of rp-refactor - no Step 0, uses ask_oracle.
    static var rpRefactorAgent: String {
        rpRefactorAgent(includeSessionCleanupGuidance: true)
    }

    static func rpRefactorAgent(includeSessionCleanupGuidance: Bool) -> String {
        rpRefactor(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
    }

    /// Agent variant of rp-investigate - no Phase 0, uses ask_oracle.
    static var rpInvestigateAgent: String {
        rpInvestigateAgent(includeSessionCleanupGuidance: true)
    }

    static func rpInvestigateAgent(includeSessionCleanupGuidance: Bool) -> String {
        rpInvestigate(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
    }

    /// Agent variant of rp-deep-plan - no Phase 0, uses ask_user / ask_oracle / agent_run.
    static var rpDeepPlanAgent: String {
        rpDeepPlanAgent(includeSessionCleanupGuidance: true)
    }

    static func rpDeepPlanAgent(includeSessionCleanupGuidance: Bool) -> String {
        rpDeepPlan(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
    }

    /// Agent variant of rp-oracle-export - no Phase 0.
    static var rpOracleExportAgent: String {
        rpOracleExport(variant: .agent)
    }

    /// Agent variant of rp-orchestrate - no Phase 0, uses agent_run for dispatch.
    static var rpOrchestrateAgent: String {
        rpOrchestrateAgent(includeSessionCleanupGuidance: true)
    }

    static func rpOrchestrateAgent(includeSessionCleanupGuidance: Bool) -> String {
        rpOrchestrate(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
    }

    /// Agent variant of rp-optimize - no Phase 0, uses ask_oracle and agent_run for dispatch.
    static var rpOptimizeAgent: String {
        rpOptimizeAgent(includeSessionCleanupGuidance: true)
    }

    static func rpOptimizeAgent(includeSessionCleanupGuidance: Bool) -> String {
        rpOptimize(variant: .agent, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
    }
}
