#if DEBUG
    import Foundation

    extension PromptExperimentService {
        /// One explicit, bounded model call drafts data. It never starts optimization or applies a prompt.
        func prepareDefinition(
            source: PromptLabSource,
            goal: String,
            exampleInputs: String,
            criteria: String,
            targetSelector: String?,
            expectedTarget: PromptExperimentResolvedTarget? = nil,
            completer: PromptExperimentModelCompleting? = nil
        ) async throws -> PromptLabDefinition {
            _ = try source.validated()
            guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PromptExperimentAuthorityError.invalidRequest("Describe what you want to improve first.")
            }
            let target = try preparationTarget(targetSelector)
            if let expectedTarget,
               target.agentRaw != expectedTarget.agentRaw || target.modelRaw != expectedTarget.modelRaw
            {
                throw PromptExperimentAuthorityError.invalidRequest("The preparation model changed while awaiting review. Request a new preparation for the current model.")
            }
            let request: [String: Any] = [
                "prompt": source.prompt, "goal": goal, "supplied_examples": exampleInputs,
                "criteria": criteria, "template_variables": PromptLabTemplate.variables(in: source.prompt)
            ]
            let input = try String(decoding: JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
            let invoker = PromptExperimentModelInvoker(
                completer: completer ?? PromptExperimentConnectedModelRunner(),
                policy: .init(maxRetries: 0, overallTimeoutSeconds: 60), checkpoint: { _ in },
                callbackRootBase: FileManager.default.temporaryDirectory.appendingPathComponent("rpce-lab-prepare-\(UUID().uuidString)")
            )
            let completion = try await invoker.invoke(
                target: target, role: "preparation",
                systemPrompt: """
                Design a small prompt experiment from the user's task. Return one JSON object, no prose:
                {"criteria":["concrete check",...],"examples":[{"id":"case_1","split":"training","input":"realistic request","expectedOutput":null,"variables":{}},...]}
                Produce 4 training, 2 validation and 2 hidden_test cases. Preserve and diversify supplied examples.
                Include ordinary, difficult and negative cases. Criteria must measure useful task behavior and required format,
                not similarity to one preferred wording. Never reward short or empty answers that fail the task.
                Populate every template variable in each example. Use expectedOutput only when a reliable reference can be
                derived from provided facts; otherwise null. Do not invent factual reference answers. Avoid leaking references
                into model inputs. The user will inspect and edit these provisional examples before approving an experiment.
                """,
                userPrompt: input
            )
            guard completion.output.utf8.count <= 200_000,
                  let object = PromptExperimentGrading.decodeObject(completion.output),
                  let checks = object["criteria"] as? [String], !checks.isEmpty,
                  let examplesJSON = object["examples"] as? [[String: Any]], (3 ... 30).contains(examplesJSON.count)
            else { throw PromptExperimentAuthorityError.invalidRequest("The model did not return a usable experiment. Edit examples manually or prepare again.") }
            let examples = try JSONDecoder().decode([PromptSuiteCase].self, from: JSONSerialization.data(withJSONObject: examplesJSON))
            var definition = PromptLabDefinition(
                source: source, goal: goal,
                runner: source.kind == .builtIn ? (source.builtInPromptID == .engineer ? .engineer : .oracle) : .plainPrompt,
                examples: examples, criteria: checks.joined(separator: "\n")
            )
            if goal.localizedCaseInsensitiveContains("token") || goal.localizedCaseInsensitiveContains("cost") {
                definition.objective.mode = .efficiency
            }
            // Engineer tasks use real fixture/acceptance data supplied by the built-in suite;
            // generated writing examples cannot replace that execution contract.
            if source.builtInPromptID == .engineer,
               let option = promptOptions().first(where: { $0.promptID == .engineer }), let suite = option.suite
            {
                definition.examples = suite.cases
            }
            return try definition.validated()
        }
    }
#endif
