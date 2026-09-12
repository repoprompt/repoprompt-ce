#if DEBUG
    import Foundation
    import MCP

    /// Human approval over the existing MCP transport. No caller-supplied approval boolean,
    /// controller UUID, or digest token can substitute for this server-originated interaction.
    enum PromptExperimentMCPElicitation {
        static func approve(
            _ plan: PromptExperimentPlan,
            connection: BootstrapSocketConnectionManager
        ) async throws -> Bool {
            let result = try await connection.requestExperimentForm(
                message: "Review this complete sealed experiment plan. Approving starts exactly this revision; it does not apply a candidate or authorize future revisions.\n\n" + (PromptExperimentSealedPlanPresentation.prettyPrintedJSON(plan)),
                requestedSchema: .init(
                    title: "Run experiment: " + plan.title,
                    description: "Exact plan digest: " + plan.digest,
                    properties: ["approve": .object([
                        "type": .string("boolean"),
                        "title": .string("Approve and run this exact plan")
                    ])],
                    required: ["approve"]
                )
            )
            switch result.action {
            case .accept: return result.content?["approve"]?.boolValue == true
            case .decline: return false
            case .cancel: throw CancellationError()
            }
        }
    }
#endif
