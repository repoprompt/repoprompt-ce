#if DEBUG
    import Foundation

    /// One view of prompt availability shared by native setup and MCP discovery. A failed
    /// resource or suite load stays visible with its reason, rather than looking runnable.
    struct PromptExperimentPromptOption: Identifiable {
        let promptID: BuiltInPromptID
        let resourceSHA256: String?
        let suite: PromptSuite?
        let unavailableReason: String?

        var id: String {
            promptID.rawValue
        }

        var title: String {
            switch promptID {
            case .oraclePlan: "Oracle Plan"
            case .oracleReview: "Oracle Review"
            case .oracleChat: "Oracle Chat"
            case .oracleChatNoRoots: "Oracle Chat without a workspace"
            }
        }
    }

    extension PromptExperimentAuthority {
        /// Includes the separately admitted calibration pool. This is an evaluation count,
        /// not a dollar, token, or model-call limit: judging and reflection also make calls.
        var maximumTotalEvaluations: Int {
            maxEvaluations + calibrationEvaluations
        }

        var approvalBudgetSummary: String {
            "up to \(maximumTotalEvaluations) evaluations (\(maxEvaluations) search + \(calibrationEvaluations) calibration)"
        }
    }
#endif
