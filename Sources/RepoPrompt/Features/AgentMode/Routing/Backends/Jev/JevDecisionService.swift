import Foundation

/// Jev wire translation and acceptance only. Model Router policy is consumer-owned.
struct JevDecisionService: DecisionService {
    /// Jev's documented question-map key remains stable even though the generic question is named.
    static let routeQuestionID = "route"

    let id = DecisionServiceID.jev
    let displayName = "Jev by TypeSafe"
    let credentialService: JevRouterCredentialService
    let capabilities = DecisionServiceCapabilities(
        contextKinds: [.text],
        finiteChoice: .init(
            minimumChoices: 2, maximumChoices: 12, maximumContextBytes: 24 * 1024,
            maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
            maximumAggregateBytes: 128 * 1024
        ),
        evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
    )

    static func settingsRegistration(controller: JevRouterCredentialService) -> DecisionServiceConfigurationRegistration {
        .init(
            presentation: .init(
                title: "Jev by TypeSafe",
                summary: "Verify a TypeSafe API key to use Jev for supported decisions.",
                notices: [],
                disclosures: [
                    .init(
                        id: "jev-privacy",
                        category: .privacy,
                        title: "Privacy and data sharing",
                        paragraphs: [
                            "Key verification checks your account without sending a task. For task routing, Jev helps choose a model and then its effort. For effort selection, it chooses only effort for an eligible user turn without changing the model already selected."
                        ]
                    ),
                    .init(
                        id: "jev-technical",
                        category: .technical,
                        title: "Technical limits",
                        paragraphs: ["Each Jev decision request has a five-second deadline. Requests are not retried automatically."]
                    )
                ],
                productStatus: nil,
                capabilities: [
                    .init(id: "model-router", title: "Model Router"),
                    .init(id: "auto-effort", title: "Auto Effort")
                ],
                secretFieldLabel: "TypeSafe API key",
                supportedCredentialActions: [
                    .validateAndSaveSecret,
                    .revalidateStoredSecret,
                    .removeStoredSecret
                ],
                links: [
                    .init(
                        title: "TypeSafe API documentation",
                        url: URL(string: "https://docs.typesafe.ai/api")!,
                        disclosureID: "jev-technical"
                    ),
                    .init(
                        title: "TypeSafe privacy policy",
                        url: URL(string: "https://typesafe.ai/legal/privacy-policy")!,
                        disclosureID: "jev-privacy"
                    )
                ]
            ),
            controller: controller
        )
    }

    func readinessSnapshot() async -> DecisionReadiness {
        await credentialService.readinessSnapshot()
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        guard (try? FiniteChoiceDecisionValidator().validateRequest(request, capabilities: capabilities)) != nil,
              let batch = try? JevJudgmentBatch(questions: [
                  JevJudgmentQuestion(
                      id: Self.routeQuestionID,
                      instructions: request.question.instructions,
                      criteria: request.question.choices.map {
                          JevJudgmentCriterion(opaqueKey: $0.opaqueKey, description: $0.description)
                      }
                  )
              ])
        else { return .invalidRequest }
        let wireRequest = JevRoutingWireRequest(
            model: JevRouterCredentialService.pinnedModel,
            state: request.textContext,
            questions: batch.wireQuestions()
        )
        do {
            let response = try await credentialService.judgeForRouting(wireRequest)
            let validated = try JevRoutingResponseInterpreter().validate(response, batch: batch)
            guard let answer = validated.answer(forQuestionID: Self.routeQuestionID) else { return .invalidResponse }
            return .selected(
                opaqueKey: answer.selectedOpaqueKey,
                evidence: .init(
                    acceptancePolicyVersion: JevRouterCredentialService.routingPolicyVersion,
                    confidence: answer.confidence,
                    scores: nil,
                    scoreSemantics: nil,
                    probabilities: answer.probabilities.map { .init(opaqueKey: $0.key, value: $0.value) },
                    probabilitySemantics: .probability,
                    usage: .init(inputTokens: validated.inputTokens, outputTokens: validated.outputTokens)
                )
            )
        } catch is CancellationError {
            return .cancelled
        } catch is JevRoutingResponseInterpreter.ValidationError {
            return .invalidResponse
        } catch let error as JevRoutingClientError {
            return switch error {
            case .authentication: .failed(category: .authentication, retryable: false, evidence: nil)
            case .invalidRequest: .invalidRequest
            case .rateLimited: .failed(category: .rateLimited, retryable: true, evidence: nil)
            case .overloaded: .failed(category: .overloaded, retryable: true, evidence: nil)
            case .timeout: .failed(category: .timeout, retryable: true, evidence: nil)
            case .invalidResponse, .decoding: .invalidResponse
            case .service: .failed(category: .transport, retryable: true, evidence: nil)
            }
        } catch {
            return .failed(category: .transport, retryable: true, evidence: nil)
        }
    }
}
