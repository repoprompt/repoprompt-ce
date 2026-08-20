import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptRuntimeModel
import RepoPromptWorkspaceRuntimeCore

public struct ContextBuilderFileCandidate: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let byteCount: Int64

    public init(rootID: UUID, logicalPath: String, byteCount: Int64) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.byteCount = byteCount
    }
}

public enum ContextBuilderWorkspaceToolCall: Sendable {
    case tree(rootID: UUID, logicalPath: String, maximumDepth: Int, maximumEntries: Int)
    case search(rootID: UUID, logicalPath: String, query: String, useRegex: Bool, maximumResults: Int)
    case read(rootID: UUID, logicalPath: String, startLine: Int?, lineCount: Int?)
    case codeMap(rootID: UUID, logicalPath: String)
    case diff(rootID: UUID, comparison: String, logicalPaths: [String])
    case askUser(prompt: String, choices: [String])
}

public enum ContextBuilderWorkspaceToolResult: Sendable {
    case tree([ProjectTreeEntry])
    case search([ProjectSearchHit])
    case file(ProjectFileSnapshot)
    case codeMap(ProjectCodeMapSnapshot)
    case diff(ProjectDiffSnapshot)
    case answer(String?)
}

/// Exact, root-authorized project tools captured for one Context Builder run.
/// The authority supplies this bridge from its existing `ProjectToolAuthority`;
/// the provider never receives physical paths or direct filesystem authority.
public struct ContextBuilderWorkspaceTools: Sendable {
    private let invokeClosure: @Sendable (ContextBuilderWorkspaceToolCall) async throws -> ContextBuilderWorkspaceToolResult

    public init(invoke: @escaping @Sendable (ContextBuilderWorkspaceToolCall) async throws -> ContextBuilderWorkspaceToolResult) {
        invokeClosure = invoke
    }

    public func invoke(_ call: ContextBuilderWorkspaceToolCall) async throws -> ContextBuilderWorkspaceToolResult {
        try await invokeClosure(call)
    }
}

public struct FrozenContextBuilderWorkspace: Sendable {
    public let sessionID: UUID
    public let projectID: UUID
    public let workingDirectory: String
    public let prompt: String
    public let selection: SelectionSnapshot
    public let candidates: [ContextBuilderFileCandidate]
    public let tools: ContextBuilderWorkspaceTools

    public init(sessionID: UUID, projectID: UUID, workingDirectory: String, prompt: String, selection: SelectionSnapshot, candidates: [ContextBuilderFileCandidate], tools: ContextBuilderWorkspaceTools) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.selection = selection
        self.candidates = candidates
        self.tools = tools
    }
}

public struct ContextBuilderRuntimeRequest: Sendable {
    public let workspace: FrozenContextBuilderWorkspace
    public let instructions: String
    public let tokenBudget: Int
    public let responseType: String?
    public let allowClarifyingQuestions: Bool
    public let provider: ProviderKind
    public let providerSettingsID: ProviderSettingsID?
    public let providerSettings: [String: String]
    public let model: String?
    public let reasoningEffort: String?
    public let runID: UUID

    public init(workspace: FrozenContextBuilderWorkspace, instructions: String, tokenBudget: Int, responseType: String?, allowClarifyingQuestions: Bool, provider: ProviderKind, providerSettingsID: ProviderSettingsID? = nil, providerSettings: [String: String] = [:], model: String?, reasoningEffort: String? = nil, runID: UUID) {
        self.workspace = workspace
        self.instructions = instructions
        self.tokenBudget = tokenBudget
        self.responseType = responseType
        self.allowClarifyingQuestions = allowClarifyingQuestions
        self.provider = provider
        self.providerSettingsID = providerSettingsID
        self.providerSettings = providerSettings
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.runID = runID
    }
}

public struct ContextBuilderRuntimeProposal: Codable, Hashable, Sendable {
    public let selection: [LogicalSelectionEntry]
    public let response: String?
    public let providerSessionID: String?
    public let rawProviderOutput: String
    public let handoffPrompt: String?

    public init(selection: [LogicalSelectionEntry], response: String?, providerSessionID: String?, rawProviderOutput: String, handoffPrompt: String? = nil) {
        self.selection = selection
        self.response = response
        self.providerSessionID = providerSessionID
        self.rawProviderOutput = rawProviderOutput
        self.handoffPrompt = handoffPrompt
    }
}

public protocol ContextBuilderRuntimeService: Sendable {
    func propose(_ request: ContextBuilderRuntimeRequest) async throws -> ContextBuilderRuntimeProposal
}

/// Portable Context Builder execution adapter. The caller freezes workspace and
/// selection authority before entry and remains the sole owner of the commit.
public struct ProviderContextBuilderRuntimeService: ContextBuilderRuntimeService, Sendable {
    private let providers: any AgentProviderDispatcher

    public init(providers: any AgentProviderDispatcher) {
        self.providers = providers
    }

    public func propose(_ request: ContextBuilderRuntimeRequest) async throws -> ContextBuilderRuntimeProposal {
        var selection = request.workspace.selection.entries
        var handoffPrompt: String?
        var providerSessionID: String?
        var nextPrompt = Self.initialPrompt(for: request)
        var rawTurns: [String] = []

        // Canonical discovery is an agent/tool loop, not a one-shot selection
        // guess. Every tool call executes against the frozen authority bridge;
        // the final selection remains staged until the caller's revision CAS.
        for turn in 0 ..< 64 {
            let result = try await providers.executeStreaming(.init(
                kind: request.provider,
                model: request.model,
                prompt: nextPrompt,
                workingDirectory: request.workspace.workingDirectory,
                maximumBytes: 8_388_608,
                runID: request.runID,
                resumeProviderSessionID: providerSessionID,
                policy: .init(
                    mode: .readOnly,
                    providerSettings: Self.providerIdentitySettings(
                        base: request.providerSettings,
                        providerSettingsID: request.providerSettingsID,
                        reasoningEffort: request.reasoningEffort
                    )
                )
            )) { _ in }
            providerSessionID = result.providerSessionID ?? providerSessionID
            rawTurns.append(result.output)
            let action = try Self.decodeAction(result.output)
            switch action.tool {
            case "manage_selection":
                selection = try Self.applySelectionAction(
                    action.arguments,
                    current: selection,
                    candidates: request.workspace.candidates
                )
                nextPrompt = Self.toolResult(
                    tool: action.tool,
                    value: [
                        "status": "ok",
                        "revision": request.workspace.selection.revision,
                        "selection": Self.selectionJSON(selection)
                    ],
                    turn: turn
                )
            case "prompt":
                let operation = action.arguments["op"] as? String ?? "get"
                switch operation {
                case "get": break
                case "set": handoffPrompt = action.arguments["text"] as? String ?? ""
                case "append": handoffPrompt = (handoffPrompt ?? "") + (action.arguments["text"] as? String ?? "")
                default: throw ServiceAPIError(code: .invalidRequest, message: "Context Builder requested an unsupported prompt operation")
                }
                nextPrompt = Self.toolResult(tool: action.tool, value: ["status": "ok", "prompt": handoffPrompt ?? ""], turn: turn)
            case "workspace_context":
                nextPrompt = Self.toolResult(
                    tool: action.tool,
                    value: [
                        "selection": Self.selectionJSON(selection),
                        "selection_count": selection.count,
                        "prompt": handoffPrompt ?? "",
                        "token_budget": request.tokenBudget
                    ],
                    turn: turn
                )
            case "get_file_tree", "file_search", "read_file", "get_code_structure", "git":
                let value = try await Self.invokeWorkspaceTool(action, workspace: request.workspace)
                nextPrompt = Self.toolResult(tool: action.tool, value: value, turn: turn)
            case "ask_user":
                guard request.allowClarifyingQuestions else {
                    throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Context Builder clarifying questions are disabled")
                }
                let prompt = action.arguments["question"] as? String ?? ""
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Context Builder question is empty")
                }
                let result = try await request.workspace.tools.invoke(.askUser(prompt: prompt, choices: action.arguments["choices"] as? [String] ?? []))
                nextPrompt = try Self.toolResult(tool: action.tool, value: Self.toolResultJSON(result), turn: turn)
            case "finish":
                let response = action.arguments["response"] as? String
                if let finalPrompt = action.arguments["prompt"] as? String { handoffPrompt = finalPrompt }
                return try ContextBuilderRuntimeProposal(
                    selection: Self.validated(selection, candidates: request.workspace.candidates),
                    response: response,
                    providerSessionID: providerSessionID,
                    rawProviderOutput: rawTurns.joined(separator: "\n\n--- provider turn ---\n\n"),
                    handoffPrompt: handoffPrompt
                )
            default:
                throw ServiceAPIError(code: .invalidRequest, message: "Context Builder requested an unsupported canonical tool")
            }
        }
        throw ServiceAPIError(code: .dependencyUnavailable, message: "Context Builder exceeded the 64-turn discovery bound")
    }

    private static func initialPrompt(for request: ContextBuilderRuntimeRequest) -> String {
        let selection = request.workspace.selection.entries.map {
            "\($0.rootID.uuidString)\t\($0.logicalPath)\t\($0.mode.rawValue)"
        }.joined(separator: "\n")
        let roots = Array(Set(request.workspace.candidates.map(\.rootID))).sorted { $0.uuidString < $1.uuidString }
            .map(\.uuidString).joined(separator: "\n")
        let responseType = request.responseType ?? "clarify"
        return """
        You are RepoPrompt's canonical Context Builder discovery runtime. Explore the repository with the provided authority tools, curate the smallest complete logical file selection, and create the handoff prompt. Do not implement changes.

        Authority rules:
        - Use get_file_tree, file_search, read_file, and get_code_structure to discover context before finishing. Use git in review mode.
        - Use manage_selection to stage exact rootID/logical-path entries. Paths are logical and relative; never invent a physical checkout path.
        - Use prompt with op set/append to preserve or improve the handoff instructions. The authority commits selection and prompt only after your final tool call.
        - Use workspace_context to verify the staged selection and prompt before finishing.
        - Prefer complete files. Use slices only when required by the token budget, and codemap_only only for supporting APIs.
        - The hard final selection budget is \(max(1, request.tokenBudget)) tokens.
        - Clarifying questions are \(request.allowClarifyingQuestions ? "permitted" : "not permitted").
        - Response mode is \(responseType). For plan/question/review, include a grounded response after curating selection; for clarify, response may be null.

        Return exactly one JSON tool action per turn, without Markdown:
        {"tool":"get_file_tree|file_search|read_file|get_code_structure|git|manage_selection|prompt|workspace_context|ask_user|finish","args":{...}}

        Common argument shapes:
        - get_file_tree: {"rootID":"UUID","path":"","max_depth":4,"max_entries":2000}
        - file_search: {"rootID":"UUID","path":"","query":"term","regex":false,"max_results":50}
        - read_file: {"rootID":"UUID","path":"relative/path","start_line":1,"line_count":200}
        - get_code_structure: {"rootID":"UUID","path":"relative/path"}
        - git: {"rootID":"UUID","comparison":"HEAD","paths":[]}
        - manage_selection: {"op":"set|add|remove|clear","entries":[{"rootID":"UUID","path":"relative/path","mode":"full|slices|codemap_only","ranges":[{"start":1,"end":20}]}]}
        - prompt: {"op":"get|set|append","text":"..."}
        - workspace_context: {}
        - ask_user: {"question":"...","choices":["..."]} (only when clarifying questions are permitted)
        - finish: {"response":"optional response or null","prompt":"optional final handoff prompt"}

        <current_selection revision="\(request.workspace.selection.revision)">
        \(selection.isEmpty ? "(empty)" : selection)
        </current_selection>
        <current_prompt_content>
        \(request.workspace.prompt)
        </current_prompt_content>
        <discover_instructions>
        \(request.instructions)
        </discover_instructions>
        <authorized_roots>
        \(roots)
        </authorized_roots>
        """
    }

    private struct DecodedAction {
        let tool: String
        let arguments: [String: Any]
    }

    private static func decodeAction(_ output: String) throws -> DecodedAction {
        let object = try JSONObjectExtractor.object(from: output)
        guard let dictionary = object as? [String: Any], let tool = dictionary["tool"] as? String else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Context Builder provider returned an invalid tool action")
        }
        return DecodedAction(tool: tool, arguments: dictionary["args"] as? [String: Any] ?? [:])
    }

    private static func applySelectionAction(_ arguments: [String: Any], current: [LogicalSelectionEntry], candidates: [ContextBuilderFileCandidate]) throws -> [LogicalSelectionEntry] {
        let operation = arguments["op"] as? String ?? "set"
        let proposed = try decodeSelection(arguments["entries"] as? [Any] ?? [], candidates: candidates)
        let next: [LogicalSelectionEntry] = switch operation {
        case "set": proposed
        case "add": current + proposed
        case "remove": current.filter { !Set(proposed).contains($0) }
        case "clear": []
        default: throw ServiceAPIError(code: .invalidRequest, message: "Context Builder requested an unsupported selection operation")
        }
        return try validated(next, candidates: candidates)
    }

    private static func decodeSelection(_ selectionValues: [Any], candidates: [ContextBuilderFileCandidate]) throws -> [LogicalSelectionEntry] {
        let allowed = Set(candidates.map { CandidateIdentity(rootID: $0.rootID, path: normalizedPath($0.logicalPath) ?? $0.logicalPath) })
        var entries: [LogicalSelectionEntry] = []
        var seen = Set<LogicalSelectionEntry>()
        for value in selectionValues {
            guard let item = value as? [String: Any],
                  let rootString = item["rootID"] as? String,
                  let rootID = UUID(uuidString: rootString),
                  let rawPath = (item["path"] ?? item["logicalPath"]) as? String,
                  let path = normalizedPath(rawPath),
                  allowed.contains(CandidateIdentity(rootID: rootID, path: path))
            else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Context Builder proposed a file outside the frozen project inventory")
            }
            let modeRaw = (item["mode"] as? String) ?? "full"
            let mode: LogicalSelectionEntry.Mode = switch modeRaw {
            case "full": .full
            case "slices": .slices
            case "codemap_only", "codeMap": .codeMap
            default: throw ServiceAPIError(code: .dependencyUnavailable, message: "Context Builder proposed an unsupported selection mode")
            }
            let ranges: [ClosedRange<Int>] = try (item["ranges"] as? [[String: Any]] ?? []).map { range in
                guard let start = range["start"] as? Int, let end = range["end"] as? Int, start > 0, end >= start else {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "Context Builder proposed an invalid slice")
                }
                return start ... end
            }
            guard mode == .slices || ranges.isEmpty else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Context Builder ranges require slices mode")
            }
            let entry = LogicalSelectionEntry(rootID: rootID, logicalPath: path, mode: mode, ranges: ranges)
            if seen.insert(entry).inserted { entries.append(entry) }
        }
        guard entries.count <= 20000 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Context Builder proposal exceeds the selection limit")
        }
        return entries
    }

    private static func validated(_ values: [LogicalSelectionEntry], candidates: [ContextBuilderFileCandidate]) throws -> [LogicalSelectionEntry] {
        try decodeSelection(selectionJSON(values), candidates: candidates)
    }

    private static func selectionJSON(_ selection: [LogicalSelectionEntry]) -> [[String: Any]] {
        selection.map { entry in
            [
                "rootID": entry.rootID.uuidString,
                "path": entry.logicalPath,
                "mode": entry.mode == .codeMap ? "codemap_only" : entry.mode.rawValue,
                "ranges": entry.ranges.map { ["start": $0.lowerBound, "end": $0.upperBound] }
            ]
        }
    }

    private static func invokeWorkspaceTool(_ action: DecodedAction, workspace: FrozenContextBuilderWorkspace) async throws -> Any {
        guard let rootString = action.arguments["rootID"] as? String, let rootID = UUID(uuidString: rootString) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder tool call omitted an authorized rootID")
        }
        let path = action.arguments["path"] as? String ?? ""
        let result: ContextBuilderWorkspaceToolResult = switch action.tool {
        case "get_file_tree": try await workspace.tools.invoke(.tree(
                rootID: rootID,
                logicalPath: path,
                maximumDepth: action.arguments["max_depth"] as? Int ?? 4,
                maximumEntries: action.arguments["max_entries"] as? Int ?? 2000
            ))
        case "file_search": try await workspace.tools.invoke(.search(
                rootID: rootID,
                logicalPath: path,
                query: action.arguments["query"] as? String ?? "",
                useRegex: action.arguments["regex"] as? Bool ?? false,
                maximumResults: action.arguments["max_results"] as? Int ?? 50
            ))
        case "read_file": try await workspace.tools.invoke(.read(
                rootID: rootID,
                logicalPath: path,
                startLine: action.arguments["start_line"] as? Int,
                lineCount: action.arguments["line_count"] as? Int
            ))
        case "get_code_structure": try await workspace.tools.invoke(.codeMap(rootID: rootID, logicalPath: path))
        case "git": try await workspace.tools.invoke(.diff(
                rootID: rootID,
                comparison: action.arguments["comparison"] as? String ?? "HEAD",
                logicalPaths: action.arguments["paths"] as? [String] ?? []
            ))
        default: throw ServiceAPIError(code: .invalidRequest, message: "Unsupported Context Builder workspace tool")
        }
        return try toolResultJSON(result)
    }

    private static func toolResultJSON(_ result: ContextBuilderWorkspaceToolResult) throws -> Any {
        let encoder = JSONEncoder()
        let data: Data = switch result {
        case let .tree(value): try encoder.encode(value)
        case let .search(value): try encoder.encode(value)
        case let .file(value): try encoder.encode(value)
        case let .codeMap(value): try encoder.encode(value)
        case let .diff(value): try encoder.encode(value)
        case let .answer(value): try encoder.encode(["answer": value])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func toolResult(tool: String, value: Any, turn: Int) -> String {
        let object: [String: Any] = ["tool": tool, "turn": turn + 1, "result": value]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return """
        <tool_result>
        \(String(decoding: data, as: UTF8.self))
        </tool_result>
        Continue discovery. Return exactly one next JSON tool action.
        """
    }

    private struct CandidateIdentity: Hashable {
        let rootID: UUID
        let path: String
    }

    private static func providerIdentitySettings(
        base: [String: String],
        providerSettingsID: ProviderSettingsID?,
        reasoningEffort: String?
    ) -> [String: String] {
        var settings = base
        if let providerSettingsID { settings["provider.settingsID"] = providerSettingsID.rawValue }
        if let reasoningEffort { settings["provider.reasoningEffort"] = reasoningEffort }
        return settings
    }

    private static func normalizedPath(_ raw: String) -> String? {
        let path = raw.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.filter { $0 != "." }.joined(separator: "/")
    }
}

public struct OracleRuntimeTranscriptEntry: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct OracleRuntimeRequest: Sendable {
    public let sessionID: UUID
    public let prompt: String
    public let mode: String
    public let selectedContext: String
    public let priorTurns: [OracleChatTurn]
    public let providerSessionID: String?
    public let provider: ProviderKind
    public let providerSettingsID: ProviderSettingsID?
    public let providerSettings: [String: String]
    public let model: String?
    public let reasoningEffort: String?
    public let tokenBudget: Int?
    public let workingDirectory: String
    public let runID: UUID
    public let planningSystemPrompt: String?

    public init(sessionID: UUID, prompt: String, mode: String, selectedContext: String, priorTurns: [OracleChatTurn], providerSessionID: String?, provider: ProviderKind, providerSettingsID: ProviderSettingsID? = nil, providerSettings: [String: String] = [:], model: String?, reasoningEffort: String? = nil, tokenBudget: Int? = nil, workingDirectory: String, runID: UUID, planningSystemPrompt: String? = nil) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.mode = mode
        self.selectedContext = selectedContext
        self.priorTurns = priorTurns
        self.providerSessionID = providerSessionID
        self.provider = provider
        self.providerSettingsID = providerSettingsID
        self.providerSettings = providerSettings
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.tokenBudget = tokenBudget
        self.workingDirectory = workingDirectory
        self.runID = runID
        self.planningSystemPrompt = planningSystemPrompt
    }
}

public struct OracleRuntimeResult: Codable, Hashable, Sendable {
    public let response: String
    public let providerSessionID: String?
    public let transcriptEntries: [OracleRuntimeTranscriptEntry]

    public init(response: String, providerSessionID: String?, transcriptEntries: [OracleRuntimeTranscriptEntry]) {
        self.response = response
        self.providerSessionID = providerSessionID
        self.transcriptEntries = transcriptEntries
    }
}

public protocol OracleRuntimeService: Sendable {
    func ask(_ request: OracleRuntimeRequest) async throws -> OracleRuntimeResult
}

/// Provider-backed Oracle adapter. Native provider session identity is passed
/// through unchanged so the authority can durably resume the exact chat.
public struct ProviderOracleRuntimeService: OracleRuntimeService, Sendable {
    private let providers: any AgentProviderDispatcher

    public init(providers: any AgentProviderDispatcher) {
        self.providers = providers
    }

    public func ask(_ request: OracleRuntimeRequest) async throws -> OracleRuntimeResult {
        let mode = request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["chat", "question", "plan", "review", "selected"].contains(mode) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported Oracle mode")
        }
        // Native continuation already owns its transcript. Durable replay is
        // used only when reconstructing a provider session from scratch.
        let history = request.providerSessionID == nil
            ? request.priorTurns.suffix(50).map { "<turn><user>\($0.prompt)</user><assistant>\($0.response)</assistant></turn>" }.joined(separator: "\n")
            : ""
        let systemPrompt: String
        if mode == "plan" {
            let planning = request.planningSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            systemPrompt = planning.isEmpty ? AdvancedServerSettings.architectFallback : planning
        } else {
            systemPrompt = "You are RepoPrompt Oracle, a repository reasoning service. Answer only from the frozen, root-authorized context below. State uncertainty and missing context explicitly. Do not claim access to unselected files."
        }
        let prompt = """
        \(systemPrompt)
        <mode>\(mode == "selected" ? "chat" : mode)</mode>
        <prior_conversation>
        \(history.isEmpty ? "(new chat)" : history)
        </prior_conversation>
        <selected_context>
        \(request.selectedContext)
        </selected_context>
        <token_budget>\(request.tokenBudget.map { String($0) } ?? "provider-default")</token_budget>
        <request>
        \(request.prompt)
        </request>
        """
        let execution = try await providers.executeStreaming(.init(
            kind: request.provider,
            model: request.model,
            prompt: prompt,
            workingDirectory: request.workingDirectory,
            maximumBytes: 8_388_608,
            runID: request.runID,
            resumeProviderSessionID: request.providerSessionID,
            policy: .init(
                mode: .readOnly,
                providerSettings: Self.providerIdentitySettings(
                    base: request.providerSettings,
                    providerSettingsID: request.providerSettingsID,
                    reasoningEffort: request.reasoningEffort
                )
            )
        )) { _ in }
        return OracleRuntimeResult(
            response: execution.output,
            providerSessionID: execution.providerSessionID ?? request.providerSessionID,
            transcriptEntries: [
                .init(role: .user, content: request.prompt),
                .init(role: .assistant, content: execution.output)
            ]
        )
    }

    private static func providerIdentitySettings(
        base: [String: String],
        providerSettingsID: ProviderSettingsID?,
        reasoningEffort: String?
    ) -> [String: String] {
        var settings = base
        if let providerSettingsID { settings["provider.settingsID"] = providerSettingsID.rawValue }
        if let reasoningEffort { settings["provider.reasoningEffort"] = reasoningEffort }
        return settings
    }
}

private enum JSONObjectExtractor {
    static func object(from output: String) throws -> Any {
        let data = Data(output.utf8)
        if let value = try? JSONSerialization.jsonObject(with: data) { return value }
        for (open, close) in [(Character("{"), Character("}")), (Character("["), Character("]"))] {
            guard let start = output.firstIndex(of: open), let end = output.lastIndex(of: close), start <= end else { continue }
            if let value = try? JSONSerialization.jsonObject(with: Data(output[start ... end].utf8)) { return value }
        }
        throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider response did not contain a JSON result")
    }
}
