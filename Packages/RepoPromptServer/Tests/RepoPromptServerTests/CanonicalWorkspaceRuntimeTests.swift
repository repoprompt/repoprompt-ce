import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServiceProtocol
@testable import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class CanonicalWorkspaceRuntimeTests: XCTestCase {
    func testContextBuilderUsesFrozenLogicalInventoryAndStructuredSelection() async throws {
        let rootID = UUID()
        let dispatcher = RecordingWorkspaceProvider(results: [
            .init(output: #"{"tool":"get_file_tree","args":{"rootID":"\#(rootID.uuidString)","path":"Sources","max_depth":2}}"#, providerSessionID: "builder-native"),
            .init(output: #"{"tool":"manage_selection","args":{"op":"set","entries":[{"rootID":"\#(rootID.uuidString)","path":"Sources/App.swift","mode":"slices","ranges":[{"start":10,"end":40}]}]}}"#, providerSessionID: "builder-native"),
            .init(output: #"{"tool":"prompt","args":{"op":"set","text":"Implement against App.swift."}}"#, providerSessionID: "builder-native"),
            .init(output: #"{"tool":"workspace_context","args":{}}"#, providerSessionID: "builder-native"),
            .init(
                output: """
                {"tool":"finish","args":{"response":"Grounded plan"}}
                """,
                providerSessionID: "builder-native"
            )
        ])
        let service = ProviderContextBuilderRuntimeService(providers: dispatcher)
        let sessionID = UUID()
        let proposal = try await service.propose(.init(
            workspace: .init(
                sessionID: sessionID,
                projectID: UUID(),
                workingDirectory: "/worktree",
                prompt: "Existing task",
                selection: .init(sessionID: sessionID, entries: [], revision: 7),
                candidates: [.init(rootID: rootID, logicalPath: "Sources/App.swift", byteCount: 1200)],
                tools: .init { call in
                    guard case .tree = call else {
                        throw ServiceAPIError(code: .invalidRequest, message: "unexpected test tool")
                    }
                    return .tree([.init(rootID: rootID, logicalPath: "Sources/App.swift", isDirectory: false, size: 1200)])
                }
            ),
            instructions: "Plan the change",
            tokenBudget: 4096,
            responseType: "plan",
            allowClarifyingQuestions: true,
            provider: .codex,
            model: "test-model",
            runID: UUID()
        ))

        XCTAssertEqual(proposal.selection, [.init(rootID: rootID, logicalPath: "Sources/App.swift", mode: .slices, ranges: [10 ... 40])])
        XCTAssertEqual(proposal.response, "Grounded plan")
        XCTAssertEqual(proposal.handoffPrompt, "Implement against App.swift.")
        XCTAssertEqual(proposal.providerSessionID, "builder-native")
        let requests = await dispatcher.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.prompt.contains("<current_selection revision=\"7\">"))
        XCTAssertTrue(request.prompt.contains("<authorized_roots>\n\(rootID.uuidString)"))
        XCTAssertTrue(request.prompt.contains("Response mode is plan"))
        XCTAssertEqual(request.workingDirectory, "/worktree")
        XCTAssertEqual(request.policy?.mode, .readOnly)
        XCTAssertEqual(requests.count, 5)
        XCTAssertNil(requests[0].resumeProviderSessionID)
        XCTAssertEqual(requests.dropFirst().map(\.resumeProviderSessionID), Array(repeating: "builder-native", count: 4))
        XCTAssertTrue(requests[1].prompt.contains("<tool_result>"))
    }

    func testContextBuilderRejectsProviderSelectionOutsideFrozenRoots() async throws {
        let dispatcher = RecordingWorkspaceProvider(results: [
            .init(output: #"{"tool":"manage_selection","args":{"op":"set","entries":[{"rootID":"\#(UUID().uuidString)","path":"secret.txt"}]}}"#, providerSessionID: nil)
        ])
        let service = ProviderContextBuilderRuntimeService(providers: dispatcher)
        let sessionID = UUID()
        do {
            _ = try await service.propose(.init(
                workspace: .init(
                    sessionID: sessionID,
                    projectID: UUID(),
                    workingDirectory: "/worktree",
                    prompt: "",
                    selection: .init(sessionID: sessionID, entries: [], revision: 1),
                    candidates: [],
                    tools: .init { _ in throw ServiceAPIError(code: .invalidRequest, message: "unused") }
                ),
                instructions: "select",
                tokenBudget: 100,
                responseType: nil,
                allowClarifyingQuestions: false,
                provider: .codex,
                model: nil,
                runID: UUID()
            ))
            XCTFail("expected frozen-root rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
    }

    func testOraclePassesNativeContinuationAndFrozenContext() async throws {
        let dispatcher = RecordingWorkspaceProvider(results: [.init(output: "continued answer", providerSessionID: "native-chat")])
        let service = ProviderOracleRuntimeService(providers: dispatcher)
        let request = OracleRuntimeRequest(
            sessionID: UUID(),
            prompt: "What changed?",
            mode: "review",
            selectedContext: "<file path=\"A.swift\">selected</file>",
            priorTurns: [.init(prompt: "First", response: "Earlier", timestamp: Date(timeIntervalSince1970: 1))],
            providerSessionID: "native-chat",
            provider: .claudeCompatible,
            model: "model",
            workingDirectory: "/bound-worktree",
            runID: UUID()
        )
        let result = try await service.ask(request)

        XCTAssertEqual(result.response, "continued answer")
        XCTAssertEqual(result.providerSessionID, "native-chat")
        XCTAssertEqual(result.transcriptEntries.map(\.role), [OracleRuntimeTranscriptEntry.Role.user, .assistant])
        let requests = await dispatcher.requests()
        let execution = try XCTUnwrap(requests.first)
        XCTAssertEqual(execution.resumeProviderSessionID, "native-chat")
        XCTAssertEqual(execution.workingDirectory, "/bound-worktree")
        XCTAssertFalse(execution.prompt.contains("<turn><user>First</user><assistant>Earlier</assistant></turn>"))
        XCTAssertTrue(execution.prompt.contains("selected</file>"))
    }

    func testOracleReconstructsDurableHistoryWithoutNativeContinuation() async throws {
        let dispatcher = RecordingWorkspaceProvider(results: [.init(output: "reconstructed", providerSessionID: "new-native-chat")])
        let service = ProviderOracleRuntimeService(providers: dispatcher)
        _ = try await service.ask(.init(
            sessionID: UUID(),
            prompt: "Continue",
            mode: "chat",
            selectedContext: "selected",
            priorTurns: [.init(prompt: "First", response: "Earlier", timestamp: Date(timeIntervalSince1970: 1))],
            providerSessionID: nil,
            provider: .codex,
            model: nil,
            workingDirectory: "/worktree",
            runID: UUID()
        ))
        let requests = await dispatcher.requests()
        let execution = try XCTUnwrap(requests.first)
        XCTAssertTrue(execution.prompt.contains("<turn><user>First</user><assistant>Earlier</assistant></turn>"))
    }

    func testBuiltinCatalogIsExactVersionedEightWorkflowSnapshot() throws {
        let workflows = try BuiltinWorkflowCatalog().workflows()
        XCTAssertEqual(workflows.map(\.workflowID), ["rp-investigate", "rp-build", "rp-oracle-export", "rp-review", "rp-refactor", "rp-orchestrate", "rp-optimize", "rp-deep-plan"])
        XCTAssertEqual(workflows.map(\.name), ["Investigate", "Plan & Build", "ChatGPT Export", "Review", "Refactor", "Orchestrate", "Optimize", "Deep Plan"])
        XCTAssertFalse(workflows.map(\.name).contains { $0.hasPrefix("rp-") })
        XCTAssertFalse(workflows.contains { $0.workflowID == "rp-reminder" })
        XCTAssertEqual(Set(workflows.map(\.contentDigest)).count, 8)
        for workflow in workflows {
            XCTAssertEqual(workflow.source, "builtin")
            XCTAssertTrue(workflow.definition.contains("name: \"\(workflow.workflowID)\""), workflow.workflowID)
            XCTAssertTrue(workflow.definition.contains("repoprompt_skills_version: 62"), workflow.workflowID)
            XCTAssertTrue(workflow.definition.contains("repoprompt_variant: mcp"), workflow.workflowID)
            XCTAssertEqual(workflow.contentDigest, CanonicalSigning.bodyDigest(Data(workflow.definition.utf8)))
        }
    }
}

private actor RecordingWorkspaceProvider: AgentProviderDispatcher {
    struct Request {
        let kind: ProviderKind
        let model: String?
        let prompt: String
        let workingDirectory: String
        let runID: UUID?
        let resumeProviderSessionID: String?
        let policy: ProviderExecutionPolicy?
    }

    private var pendingResults: [ProviderExecutionResult]
    private var recorded: [Request] = []

    init(results: [ProviderExecutionResult]) {
        pendingResults = results
    }

    func capabilities() -> [ProviderCapability] {
        []
    }

    func preflight() -> [ProviderCapability] {
        []
    }

    func recoverProcessFamilies() throws {}
    func cancel(runID _: UUID) throws {}

    func execute(
        kind: ProviderKind,
        model: String?,
        prompt: String,
        workingDirectory: String,
        maximumBytes _: Int,
        runID: UUID?,
        resumeProviderSessionID: String?,
        onProviderSessionIdentity: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderExecutionResult {
        recorded.append(.init(kind: kind, model: model, prompt: prompt, workingDirectory: workingDirectory, runID: runID, resumeProviderSessionID: resumeProviderSessionID, policy: nil))
        guard !pendingResults.isEmpty else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "No provider fixture result")
        }
        let result = pendingResults.removeFirst()
        if let identity = result.providerSessionID { await onProviderSessionIdentity(identity) }
        return result
    }

    func executeStreaming(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        try await request.acknowledgeLaunch()
        recorded.append(.init(kind: request.kind, model: request.model, prompt: request.prompt, workingDirectory: request.workingDirectory, runID: request.runID, resumeProviderSessionID: request.resumeProviderSessionID, policy: request.policy))
        guard !pendingResults.isEmpty else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "No provider fixture result")
        }
        let result = pendingResults.removeFirst()
        if let identity = result.providerSessionID { await onEvent(.providerIdentity(identity)) }
        await onEvent(.assistantFinal(result.output))
        await onEvent(.completed(providerSessionID: result.providerSessionID))
        return result
    }

    func requests() -> [Request] {
        recorded
    }
}
