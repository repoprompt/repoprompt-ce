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
            case .engineer: "Engineer agent"
            }
        }
    }

    enum PromptLabSourceChoice: String, CaseIterable, Identifiable {
        case builtIn = "RepoPrompt"
        case file = "Project file"
        case pasted = "Paste a prompt"

        var id: String {
            rawValue
        }
    }

    /// Editable native fields retain frozen context and template variables when an example
    /// comes from a built-in suite or a program adapter.
    struct PromptLabExampleDraft: Identifiable {
        var id: String
        var split: PromptSuiteSplit
        var input: String
        var reference: String
        var context: PromptSuiteCaseContext?
        var variables: [String: String]
        var payload: [String: PromptExperimentExampleValue]?

        init(example: PromptSuiteCase) {
            id = example.id
            split = example.split
            input = example.input
            reference = example.expectedOutput ?? ""
            context = example.context
            variables = example.variables
            payload = example.payload
        }

        init(index: Int) {
            id = "example-\(UUID().uuidString.lowercased())"
            split = index == 1 ? .validation : index == 2 ? .hiddenTest : .training
            input = ""
            reference = ""
            context = nil
            variables = [:]
            payload = nil
        }

        var example: PromptSuiteCase {
            var resolvedInput = input
            if case let .string(text)? = payload?["input"] ?? payload?["question"] { resolvedInput = text }
            return PromptSuiteCase(
                id: id,
                split: split,
                input: resolvedInput,
                expectedOutput: reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reference,
                context: context,
                variables: variables,
                payload: payload
            )
        }
    }

    extension PromptSuiteSplit {
        var labDisplayName: String {
            switch self {
            case .training: "Improve with this example"
            case .validation: "Compare candidates"
            case .hiddenTest: "Final check only"
            }
        }
    }

    extension PromptLabRunnerKind {
        var labDisplayName: String {
            switch self {
            case .plainPrompt: "Send the prompt to a model"
            case .oracle: "RepoPrompt Oracle request"
            case .engineer: "Engineer repository task"
            case .program: "Run a Python evaluation program"
            case .dspy: "Run a DSPy program"
            }
        }

        var usesProgram: Bool {
            self == .program || self == .dspy
        }

        var usesModelJudge: Bool {
            self == .plainPrompt || self == .oracle
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
