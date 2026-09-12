#if DEBUG
    import Foundation

    /// Deterministic observations, not a semantic quality judge or permission to spend.
    /// Derived from current-revision evidence only; never writes historical records or feeds
    /// hidden-test outcomes into development recommendations.
    struct PromptExperimentGuidance {
        let action: String
        let explanation: String
        let evidenceIDs: [String]

        static func evaluate(_ record: PromptExperimentRecord) -> Self? {
            if let spec = record.draft?.optimization {
                if spec.startingPoint == .choose {
                    return .init(action: "choose_starting_point", explanation: "Ask: use your existing prompt, or start without a seed and let GEPA create it? Record the choice; do not invent an existing baseline.", evidenceIDs: [])
                }
                if spec.startingPoint == nil {
                    return .init(action: "review_proposal", explanation: "Historical draft: starting-point choice was not recorded. Review its existing seed and proposal with the user; do not infer a new choice or mutate historical evidence.", evidenceIDs: [])
                }
                return .init(action: "review_proposal", explanation: "Review the next focused question, examples, evaluator and spend with the user. Supplied prompts can use preparation probes; seedless GEPA uses search with seed_candidate omitted. Do not run merely because a draft exists.", evidenceIDs: [])
            }
            guard let plan = record.currentPlan, let spec = plan.optimization else { return nil }
            if [.awaitingApproval, .approved].contains(record.phase) {
                return .init(action: "review_authority", explanation: "Review the exact sealed scope and request user approval. This recommendation grants no execution authority.", evidenceIDs: [])
            }
            // New runs have one attempt per revision; choose the latest if a historical
            // record contains multiple attempts rather than letting old failures dominate.
            let attempts = Array(record.attempts(for: plan).suffix(1))
            if record.phase == .running,
               let grade = attempts.last?.gradingEvidence?.last(where: { $0.awaitingRetry == true })
            {
                return .init(action: "retry_grading_or_cancel", explanation: "GEPA is paused on a failed judge call, not abandoned. Inspect grading_evidence and model_calls. Fix any provider problem, then call retry_grading with this grading ID and exact plan digest to consume one sealed judge retry on the SAME saved output, or cancel. No target call is repeated, no model/rubric substitution is allowed, and no model calls run while awaiting the decision. Worker/app exit cannot resume this live callback.", evidenceIDs: [grade.id.uuidString])
            }
            let attemptFailed = attempts.contains {
                [.failed, .submissionUncertain, .localPersistenceFailed, .cancelledRemoteUnknown].contains($0.status)
            }
            let runtimeFailed = attemptFailed || attempts.contains { attempt in
                attempt.optimizationResult == nil && attempt.status != .completed
                    && attempt.modelCalls?.contains(where: { $0.state == .failed }) == true
            }
            let partials = attempts.flatMap { $0.partialEvaluations ?? [] }.map(\.evaluation).filter { $0.split != .hiddenTest }
            let final = attempts.flatMap { $0.optimizationResult?.evaluations ?? [] }.filter { $0.split != .hiddenTest }
            let evidence = attempts.last?.optimizationResult != nil ? final : partials
            if ![.running, .cancelling].contains(record.phase),
               let grade = attempts.last?.gradingEvidence?.last(where: { $0.state != .completed })
            {
                return .init(action: "review_grading_interruption", explanation: "Execution evidence was preserved before grading. Latest grading state: \(grade.state.rawValue), judge attempts: \(grade.ordinal). Inspect grading_evidence and safe failure codes; do not rerun the target or label this a bad candidate. The bounded format-repair allowance does not authorize model switching, rubric changes or indefinite retries. Exact post-exit GEPA resume is not yet available; preserve this run and its evidence rather than claiming a fresh search is a resume.", evidenceIDs: [grade.id.uuidString])
            }
            let failures = evidence.compactMap(\.failureKind)
            let ids = evidence.map(\.id.uuidString)
            if [.running, .cancelling].contains(record.phase), !attemptFailed, !failures.contains(.infrastructure) {
                return .init(action: "monitor", explanation: "Execution is active. Inspect incremental model_calls and partial_evaluations; wait or cancel through the existing authority. Silence alone is not failure.", evidenceIDs: ids)
            }
            if runtimeFailed || failures.contains(.infrastructure) {
                return .init(action: "repair_runtime", explanation: "Inspect provider status and diagnostics before buying more evaluations. Infrastructure failures are not prompt scores. Do not automatically retry or switch models.", evidenceIDs: ids)
            }
            if record.phase == .cancelled {
                return .init(action: "review_interruption", explanation: "The run was cancelled. Inspect preserved evidence and discuss whether another run is useful; do not auto-resume spending.", evidenceIDs: ids)
            }
            if failures.contains(.candidate) {
                return .init(action: "diagnose_and_probe", explanation: "Inspect failing outputs and execution traces. Distinguish malformed tool protocol, adapter limitations, task errors and evaluator defects. Revise the responsible layer, then propose a focused preparation probe; do not repeat the entire batch or enlarge search blindly. MCP two-pass execution permits only one tool call.", evidenceIDs: ids)
            }
            let scores = evidence.compactMap(\.score)
            guard !scores.isEmpty else {
                return .init(action: "establish_evaluable_execution", explanation: "No scored development/validation evidence is available. Inspect missing outputs and evaluator behavior before proposing search. Hidden tests are not development feedback.", evidenceIDs: ids)
            }
            if scores.allSatisfy({ $0 == spec.evaluator.maximumScore }) {
                return .init(action: "review_measurement", explanation: "Observed scores are saturated. Check representative difficult cases, controls and fixed instructions for masking. Do not infer no improvement is needed or weaken correctness to reward brevity.", evidenceIDs: ids)
            }
            return .init(action: "review_evidence", explanation: "Inspect representative successes and failures, evaluator agreement, and candidate differences. Decide whether to revise and probe again or start/continue GEPA. Scores alone do not establish readiness or improvement; reserve untouched examples for final verification.", evidenceIDs: ids)
        }
    }
#endif
