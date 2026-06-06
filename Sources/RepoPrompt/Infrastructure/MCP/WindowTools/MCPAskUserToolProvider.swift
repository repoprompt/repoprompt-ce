import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
final class MCPAskUserToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .askUser

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [askUserTool()]
    }

    /// Unified ask_user tool for both discovery and agent mode runs.
    /// Routes to the appropriate UI based on the connection's run purpose.
    /// Only visible to connections that have been granted it via additionalTools.
    private func askUserTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.askUser,
            freshnessPolicy: .none,
            description: """
            Ask the user a clarifying question and wait for their response.

            Use this tool to gather additional context or clarification from the user.
            The tool will block until the user responds.

            **When to use:**
            - Task requirements are ambiguous
            - Multiple valid approaches exist and you need user preference
            - Critical context is missing
            - Confirming before making significant changes

            **Best practices:**
            - Ask early, not at the end
            - Be specific - explain what you're trying to determine
            - Provide options when the choices are clear
            - Limit questions to avoid disrupting the user

            **Input:**
            - `questions`: Required array of structured questions. Each question requires stable `id` and `question` fields. Use `allows_multiple` and `allows_custom` for selection/custom-answer behavior.
            - `title`: Optional title for the wizard card.
            - `context`: Optional overall context shown above the questions.
            - `timeout_seconds`: Optional timeout in seconds for the whole interaction.

            **Response:**
            - `answers`: Object keyed by question ID. Each value contains `answers`, `selected_options`, `custom_response`, and `skipped`.
            - `timed_out`: True if the interaction timed out.
            - `skipped`: True if user explicitly skipped the interaction.
            - `elapsed_seconds`: How long the user took to respond.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "title": .string(description: "Optional title shown above the question wizard."),
                    "context": .string(description: "Optional overall context shown above the wizard."),
                    "timeout_seconds": .integer(description: "Timeout in seconds for the whole interaction."),
                    "questions": .array(
                        description: "One or more structured questions to ask as a single wizard.",
                        items: .object(
                            properties: [
                                "id": .string(description: "Stable unique question ID used as the response key."),
                                "header": .string(description: "Optional short heading for this question."),
                                "question": .string(description: "Question text to show the user."),
                                "context": .string(description: "Optional per-question context."),
                                "options": .array(
                                    description: "Optional suggested answers. Each entry may be a string label or an object with label/description.",
                                    items: .anyOf([
                                        .string(description: "Option label returned when selected."),
                                        .object(
                                            properties: [
                                                "label": .string(description: "Option label returned when selected."),
                                                "description": .string(description: "Optional option description shown to the user.")
                                            ],
                                            required: ["label"]
                                        )
                                    ])
                                ),
                                "allows_multiple": .boolean(description: "When true, the user can select multiple options. Default is false."),
                                "allows_custom": .boolean(description: "When true, the user can type one custom response. Default is true.")
                            ],
                            required: ["id", "question"]
                        )
                    )
                ],
                required: ["questions"]
            )
        ) { [dependencies] _, args in
            try await Self.executeAskUser(args: args, dependencies: dependencies)
        }
    }

    /// Execute the ask_user tool - routes to appropriate UI based on run purpose.
    private static func executeAskUser(
        args: [String: Value],
        dependencies: MCPWindowToolDependencies
    ) async throws -> Value {
        // Get connection ID and determine run purpose for routing.
        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("ask_user requires an active MCP connection")
        }
        let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)

        // Get target window.
        let targetWindow = try dependencies.requireTargetWindow()

        // Resolve timeout: use explicit value from caller, or workspace setting.
        let workspaceTimeout = await MainActor.run { targetWindow.contextBuilderAgentViewModel.questionTimeoutSeconds }
        let parsed = try parseAskUserInteraction(args: args, defaultTimeout: workspaceTimeout)

        // Route based on run purpose.
        let response: AgentAskUserResponse
        switch purpose {
        case .discoverRun:
            // Route to Context Builder UI.
            let tabContext = try await dependencies.requireCurrentTabContext(MCPWindowToolName.askUser)
            guard let runID = tabContext.runID else {
                throw MCPError.invalidParams("ask_user requires an active Context Builder run with tab context")
            }
            response = try await targetWindow.contextBuilderAgentViewModel.askUserInteraction(
                tabID: tabContext.tabID,
                interaction: parsed.interaction,
                runID: runID
            )

        case .agentModeRun:
            // Route to agent mode UI.
            let tabID = try await dependencies.resolveAgentModeTabID(args, connectionID)
            // For non-MCP-controlled sessions, surface the tab so the user can
            // see and answer the question. MCP-controlled runs handle interactions
            // programmatically via `respond`, so pulling focus would be disruptive.
            if !targetWindow.agentModeViewModel.isMCPControlled(tabID: tabID) {
                _ = await targetWindow.revealPendingInteraction(
                    tabID: tabID,
                    surface: .agentQuestion
                )
            }
            response = try await targetWindow.agentModeViewModel.askUserInteraction(
                tabID: tabID,
                interaction: parsed.interaction
            )

        case .unknown:
            throw MCPError.invalidParams("ask_user is only available during Context Builder or agent mode runs")
        }

        return askUserResponseValue(response, includeLegacyResponse: parsed.includeLegacyResponse)
    }

    private struct ParsedAskUserInteraction {
        let interaction: AgentAskUserInteraction
        let includeLegacyResponse: Bool
    }

    private static func parseAskUserInteraction(args: [String: Value], defaultTimeout: TimeInterval) throws -> ParsedAskUserInteraction {
        let hasStructuredQuestions = args["questions"] != nil
        let legacyKeys = ["question", "options", "multi_select"]
        let misplacedTopLevelQuestionKeys = ["allow_custom", "allows_custom", "allows_multiple"]
        let hasLegacyInput = legacyKeys.contains { args[$0] != nil }
        if hasStructuredQuestions, hasLegacyInput {
            throw MCPError.invalidParams("ask_user accepts either structured questions or legacy question/options/multi_select, not both.")
        }
        if hasStructuredQuestions, let misplacedKey = misplacedTopLevelQuestionKeys.first(where: { args[$0] != nil }) {
            throw MCPError.invalidParams("ask_user structured questions must put '\(misplacedKey)' on each question, not at the top level.")
        }

        let timeoutSeconds: TimeInterval
        if let timeoutValue = args["timeout_seconds"] {
            guard let timeoutInt = timeoutValue.intValue, timeoutInt > 0 else {
                throw MCPError.invalidParams("timeout_seconds must be a positive integer.")
            }
            timeoutSeconds = TimeInterval(timeoutInt)
        } else {
            timeoutSeconds = defaultTimeout
        }

        let questions: [AgentAskUserQuestion]
        let includeLegacyResponse: Bool
        if hasStructuredQuestions {
            guard let questionValues = args["questions"]?.arrayValue else {
                throw MCPError.invalidParams("questions must be an array.")
            }
            guard !questionValues.isEmpty else {
                throw MCPError.invalidParams("ask_user requires at least one question.")
            }
            let maxQuestionCount = 10
            guard questionValues.count <= maxQuestionCount else {
                throw MCPError.invalidParams("ask_user supports at most \(maxQuestionCount) questions per request.")
            }
            questions = try questionValues.enumerated().map { index, value in
                try parseAskUserQuestion(value, index: index)
            }
            includeLegacyResponse = false
        } else {
            guard let questionText = normalizedAskUserString(args["question"]) else {
                throw MCPError.invalidParams("ask_user requires a questions array.")
            }
            let options = try parseAskUserOptions(args["options"], questionPath: "options")
            let multiSelect = try optionalAskUserBool(args["multi_select"], name: "multi_select") ?? false
            questions = [
                AgentAskUserQuestion(
                    id: "response",
                    question: questionText,
                    options: options,
                    allowsMultiple: multiSelect,
                    allowsCustom: true
                )
            ]
            includeLegacyResponse = true
        }

        let interaction = AgentAskUserInteraction(
            title: normalizedAskUserString(args["title"]) ?? (includeLegacyResponse ? "Question" : nil),
            context: normalizedAskUserString(args["context"]),
            timeoutSeconds: timeoutSeconds,
            questions: questions
        )
        do {
            try interaction.validate()
        } catch {
            throw MCPError.invalidParams(error.localizedDescription)
        }
        return ParsedAskUserInteraction(interaction: interaction, includeLegacyResponse: includeLegacyResponse)
    }

    private static func parseAskUserQuestion(_ value: Value, index: Int) throws -> AgentAskUserQuestion {
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("questions[\(index)] must be an object.")
        }
        guard let id = normalizedAskUserString(object["id"]) else {
            throw MCPError.invalidParams("questions[\(index)].id is required.")
        }
        guard let questionText = normalizedAskUserString(object["question"]) else {
            throw MCPError.invalidParams("questions[\(index)].question is required.")
        }
        if object["multi_select"] != nil {
            throw MCPError.invalidParams("questions[\(index)].multi_select has been renamed to questions[\(index)].allows_multiple.")
        }
        if object["allow_custom"] != nil {
            throw MCPError.invalidParams("questions[\(index)].allow_custom has been renamed to questions[\(index)].allows_custom.")
        }
        let options = try parseAskUserOptions(object["options"], questionPath: "questions['\(id)'].options")
        let allowsMultiple = try optionalAskUserBool(object["allows_multiple"], name: "questions[\(index)].allows_multiple") ?? false
        let allowsCustom = try optionalAskUserBool(object["allows_custom"], name: "questions[\(index)].allows_custom") ?? true
        return AgentAskUserQuestion(
            id: id,
            header: normalizedAskUserString(object["header"]),
            question: questionText,
            context: normalizedAskUserString(object["context"]),
            options: options,
            allowsMultiple: allowsMultiple,
            allowsCustom: allowsCustom
        )
    }

    private static func parseAskUserOptions(_ value: Value?, questionPath: String) throws -> [AgentAskUserOption] {
        guard let value else { return [] }
        guard let optionValues = value.arrayValue else {
            throw MCPError.invalidParams("\(questionPath) must be an array.")
        }
        return try optionValues.enumerated().map { index, value in
            if let label = normalizedAskUserString(value) {
                return AgentAskUserOption(label: label)
            }
            guard let object = value.objectValue else {
                throw MCPError.invalidParams("\(questionPath)[\(index)] must be a string or object.")
            }
            guard let label = normalizedAskUserString(object["label"]) else {
                throw MCPError.invalidParams("\(questionPath)[\(index)].label is required.")
            }
            return AgentAskUserOption(
                label: label,
                description: normalizedAskUserString(object["description"])
            )
        }
    }

    private static func normalizedAskUserString(_ value: Value?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalAskUserBool(_ value: Value?, name: String) throws -> Bool? {
        guard let value else { return nil }
        guard let bool = value.boolValue else {
            throw MCPError.invalidParams("\(name) must be a boolean.")
        }
        return bool
    }

    private static func askUserResponseValue(_ response: AgentAskUserResponse, includeLegacyResponse: Bool) -> Value {
        var object: [String: Value] = [
            "answers": .object(response.answersByQuestionID.reduce(into: [String: Value]()) { partialResult, entry in
                partialResult[entry.key] = askUserAnswerValue(entry.value)
            }),
            "timed_out": .bool(response.timedOut),
            "skipped": .bool(response.skipped),
            "elapsed_seconds": .int(response.elapsedSeconds)
        ]
        if includeLegacyResponse {
            if response.timedOut || response.skipped {
                object["response"] = .null
            } else {
                let answer = response.answersByQuestionID["response"]
                object["response"] = answer?.skipped == true
                    ? .null
                    : .string(answer?.answers.joined(separator: "\n") ?? "")
            }
        }
        return .object(object)
    }

    private static func askUserAnswerValue(_ answer: AgentAskUserAnswer) -> Value {
        .object([
            "answers": .array(answer.answers.map { .string($0) }),
            "selected_options": .array(answer.selectedOptions.map { .string($0) }),
            "custom_response": answer.customResponse.map { .string($0) } ?? .null,
            "skipped": .bool(answer.skipped)
        ])
    }
}
