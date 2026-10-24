import Foundation

/// OpenAI Decisions wire translation and acceptance only. Model Router policy is consumer-owned.
struct OpenAIDecisionsDecisionService: DecisionService {
    let id = DecisionServiceID.openAIDecisions
    let displayName = "Decisions by OpenAI"
    let credentialService: OpenAIDecisionsRouterCredentialService
    let capabilities = DecisionServiceCapabilities(
        contextKinds: [.text],
        finiteChoice: .init(
            minimumChoices: 2, maximumChoices: 12, maximumContextBytes: 24 * 1024,
            maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
            maximumAggregateBytes: 128 * 1024
        ),
        evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
    )

    static func settingsRegistration(controller: OpenAIDecisionsRouterCredentialService) -> DecisionServiceConfigurationRegistration {
        .init(presentation: .init(
            title: "Decisions by OpenAI",
            summary: "Uses gpt-6-luna to make supported decisions when selected.",
            notices: [
                .init(
                    id: "decisions-dedicated-project",
                    text: "A dedicated OpenAI project and project key are recommended for attribution and project-level spend controls. A separate key is not a hard budget boundary, and organization limits may span projects. You may manually use another key if you accept shared accounting.",
                    emphasis: .warning
                ),
                .init(
                    id: "decisions-validation-charge",
                    text: "Validation sends a fixed test request, may incur a small input-token charge, and confirms access only at the time of validation.",
                    emphasis: .warning
                )
            ],
            disclosures: [
                .init(
                    id: "decisions-privacy",
                    category: .privacy,
                    title: "Privacy and data controls",
                    paragraphs: [
                        "For task routing, the service receives limited amounts of task and guidance text you enter plus candidate descriptions, but no appended workspace, repository, file, path, transcript, tool, or workflow payload. To select effort for a model already selected, it receives the model ID, available effort choices, a masked excerpt of the current user turn, and, when applicable, the built-in workflow category. Even short text can contain sensitive information; masking is best effort, not anonymization.",
                        "Existing selected prompt-workflow eligibility is preserved; leading-slash invocations, attachments, and tagged-file payloads remain ineligible.",
                        "Pricing and regional data-control capabilities vary by account and project. ZDR, HIPAA, residency, and regional processing require eligibility and configuration."
                    ]
                ),
                .init(
                    id: "decisions-pricing",
                    category: .pricing,
                    title: "Pricing",
                    paragraphs: [
                        "OpenAI sets Decisions API pricing, which may change and can vary with factors such as context length or processing region. Review OpenAI's current pricing before enabling the service."
                    ]
                ),
                .init(
                    id: "decisions-technical",
                    category: .technical,
                    title: "Technical limits",
                    paragraphs: [
                        "Decision requests use the pinned gpt-6-luna model. Each request has a five-second deadline and a 64 KiB response cap; requests are not retried automatically."
                    ]
                )
            ],
            productStatus: nil,
            capabilities: [
                .init(id: "model-router", title: "Model Router"),
                .init(id: "auto-effort", title: "Auto Effort")
            ],
            secretFieldLabel: "API key for Decisions by OpenAI",
            supportedCredentialActions: [
                .validateAndSaveSecret,
                .revalidateStoredSecret,
                .removeStoredSecret
            ],
            links: [
                .init(
                    title: "Decisions documentation",
                    url: URL(string: "https://developers.openai.com/api/docs/guides/decisions")!,
                    disclosureID: "decisions-technical"
                ),
                .init(
                    title: "OpenAI API pricing",
                    url: URL(string: "https://developers.openai.com/api/docs/pricing")!,
                    disclosureID: "decisions-pricing"
                ),
                .init(
                    title: "OpenAI data controls",
                    url: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!,
                    disclosureID: "decisions-privacy"
                )
            ]
        ), controller: controller)
    }

    func readinessSnapshot() async -> DecisionReadiness {
        await credentialService.readinessSnapshot()
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        guard (try? FiniteChoiceDecisionValidator().validateRequest(request, capabilities: capabilities)) != nil else {
            return .invalidRequest
        }
        let question = request.question
        let submitted = question.choices.map(\.opaqueKey)
        let wire = OpenAIDecisionsWireRequest(
            model: OpenAIDecisionsRouterCredentialService.pinnedModel,
            input: request.textContext,
            questions: [.init(
                name: question.name,
                instructions: question.instructions,
                choices: question.choices.map { .init(value: $0.opaqueKey, description: $0.description) }
            )]
        )
        do {
            let response = try await credentialService.judgeForRouting(wire)
            let result = try OpenAIDecisionsRoutingResponseInterpreter().interpret(
                response,
                expectedQuestionName: question.name,
                submittedChoices: submitted
            )
            switch result {
            case .refusal:
                return .abstained(reasonCode: "provider_refusal", evidence: nil)
            case let .choice(key, scores, confidence):
                return .selected(
                    opaqueKey: key,
                    evidence: .init(
                        acceptancePolicyVersion: OpenAIDecisionsRouterCredentialService.routingPolicyVersion,
                        confidence: confidence,
                        scores: nil,
                        scoreSemantics: nil,
                        probabilities: scores.map { .init(opaqueKey: $0.key, value: $0.value) },
                        probabilitySemantics: .probability,
                        usage: .init(inputTokens: response.usage.inputTokens, outputTokens: response.usage.outputTokens)
                    )
                )
            }
        } catch is CancellationError {
            return .cancelled
        } catch is OpenAIDecisionsRoutingResponseInterpreter.ValidationError {
            return .invalidResponse
        } catch let error as OpenAIDecisionsRoutingClientError {
            switch error {
            case .cancelled: return .cancelled
            case .invalidRequest: return .invalidRequest
            case .invalidResponse, .responseTooLarge: return .invalidResponse
            case .authentication, .policyUnavailable: return .unavailable
            case .timeout: return .failed(category: .timeout, retryable: false, evidence: nil)
            case .rateLimited: return .failed(category: .rateLimited, retryable: true, evidence: nil)
            case .overloaded: return .failed(category: .overloaded, retryable: true, evidence: nil)
            case .transport: return .failed(category: .transport, retryable: false, evidence: nil)
            }
        } catch {
            return .failed(category: .transport, retryable: false, evidence: nil)
        }
    }
}
