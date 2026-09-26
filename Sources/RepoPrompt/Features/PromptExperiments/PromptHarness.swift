#if DEBUG
    import Foundation

    /// Result of executing and grading one candidate on one sealed example.
    struct PromptHarnessOutcome: Equatable {
        let score: Double
        /// Bounded, proposer-safe feedback (held-out feedback is always withheld).
        let proposerFeedback: String
        /// Full target output, retained host-side as evidence.
        let output: String
        let failureKind: PromptExperimentOptimizationFailureKind?
        let elapsedSeconds: Double
        /// Candidate/output size and the target call's token usage when reported.
        var usage: PromptExperimentEvaluationUsage?
    }

    /// Executes a candidate against one sealed example and grades the result.
    ///
    /// The caller has already admitted this evaluation in the budget ledger; a harness never
    /// admits spend itself. Candidate-level failures are returned as scored outcomes;
    /// infrastructure failures and cancellation throw.
    ///
    /// Extension point — `ContextBuilderHarness` (not implemented): a Context Builder harness
    /// must run each evaluation against its own immutable workspace snapshot through the
    /// headless `repoprompt-mcp` server, with run-scoped file-tool authority. It must not
    /// borrow the window's active-workspace authority (the removed in-window adapter failed
    /// every file read with `workspace_authority_superseded`).
    @MainActor
    protocol PromptHarness: AnyObject {
        func evaluate(
            candidate: String,
            example: PromptSuiteCase,
            evaluationID: UUID
        ) async throws -> PromptHarnessOutcome
    }
#endif
