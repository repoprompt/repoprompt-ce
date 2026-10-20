import Foundation
import MCP
import RepoPromptSettingsCore

/// One preparation's consult ownership. Oracle and discovery begin immediately; the caller
/// may present clarification while these tasks run. No attachment inputs exist in this API.
@MainActor
final class AgentRepromptContextConsultant {
    struct Output {
        let result: AgentRepromptConsultResult
        var committedSelection: StoredSelection?
    }

    @MainActor
    private final class SelectionObserver {
        weak var owner: AgentRepromptContextConsultant?
    }

    typealias Consult = @MainActor (String) async throws -> Output
    private let oracle: Consult
    private let contextBuilder: Consult
    private let readSelection: () -> StoredSelection?
    private let restoreSelection: (StoredSelection) -> Void
    private let originalSelection: StoredSelection?
    private(set) var committedSelection: StoredSelection?
    private var tasks: [AgentRepromptContextRequest.Kind: Task<AgentRepromptConsultResult, Never>] = [:]
    private var isCancelled = false
    private var settled: [AgentRepromptContextRequest.Kind: AgentRepromptConsultResult] = [:]
    private var waiters: [CheckedContinuation<[AgentRepromptConsultResult], Never>] = []

    init(
        oracle: @escaping Consult,
        contextBuilder: @escaping Consult,
        readSelection: @escaping () -> StoredSelection?,
        restoreSelection: @escaping (StoredSelection) -> Void
    ) {
        self.oracle = oracle
        self.contextBuilder = contextBuilder
        self.readSelection = readSelection
        self.restoreSelection = restoreSelection
        originalSelection = readSelection()
    }

    func start(_ requests: [AgentRepromptContextRequest]) {
        for request in requests where tasks[request.kind] == nil && !isCancelled {
            tasks[request.kind] = Task { [self] in
                let result = await perform(request)
                settled[request.kind] = result
                resolveWaitersIfReady()
                return result
            }
        }
    }

    private func perform(_ request: AgentRepromptContextRequest) async -> AgentRepromptConsultResult {
        do {
            let output = try await (request.kind == .oracle ? oracle : contextBuilder)(request.text)
            if let selection = output.committedSelection, request.kind == .contextBuilder {
                noteCommittedSelection(selection)
            }
            guard !isCancelled, !Task.isCancelled else {
                restoreIfUnchanged()
                return .init(kind: request.kind, status: "skipped", text: "Context gathering skipped")
            }
            var result = output.result
            result = .init(
                kind: result.kind, status: result.status, text: Self.boundedResult(result.text),
                chatID: result.chatID, selectedFileCount: result.selectedFileCount
            )
            return result
        } catch {
            return .init(kind: request.kind, status: Task.isCancelled ? "skipped" : "failed", text: "Context gathering unavailable")
        }
    }

    private var currentResults: [AgentRepromptConsultResult] {
        [AgentRepromptContextRequest.Kind.oracle, .contextBuilder].compactMap { kind in
            guard tasks[kind] != nil else { return nil }
            return settled[kind] ?? (isCancelled ? .init(kind: kind, status: "skipped", text: "Context gathering skipped") : nil)
        }
    }

    private func resolveWaitersIfReady() {
        guard isCancelled || settled.count == tasks.count else { return }
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: currentResults)
        }
    }

    var resultsSnapshot: [AgentRepromptConsultResult] {
        currentResults
    }

    func results() async -> [AgentRepromptConsultResult] {
        if isCancelled || settled.count == tasks.count {
            return currentResults
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func cancel(keepSelection: Bool = false) {
        isCancelled = true
        tasks.values.forEach { $0.cancel() }
        resolveWaitersIfReady()
        if !keepSelection {
            restoreIfUnchanged()
        }
    }

    func noteCommittedSelection(_ selection: StoredSelection) {
        committedSelection = selection
        if isCancelled {
            restoreIfUnchanged()
        }
    }

    func restoreIfUnchanged() {
        guard let originalSelection, let committedSelection,
              readSelection() == committedSelection else { return }
        restoreSelection(originalSelection)
        self.committedSelection = nil
    }

    static func live(
        identity: WorkspaceSelectionIdentity,
        nested: MCPTabContextSnapshot,
        oracleContext: OracleViewModel.OracleSendTabContext,
        profile: AgentModelsSettingsProfile,
        prompt: PromptViewModel,
        workspace: WorkspaceManagerViewModel,
        oracle: OracleViewModel,
        builder: ContextBuilderAgentViewModel
    ) -> AgentRepromptContextConsultant {
        let observer = SelectionObserver()
        let consultant = Self(
            oracle: { question in
                let race = AgentRepromptCallRace<AgentRepromptConsultResult>()
                let result = try await withTaskCancellationHandler {
                    try await race.run(seconds: 180) { @MainActor in
                        let reply = try await oracle.tool_chatSendWithConfiguredRoster(
                            args: [
                                "message": .string(question),
                                "mode": .string("chat"),
                                "chat_name": .string("Re-prompt consult"),
                                "new_chat": .bool(true)
                            ],
                            promptVM: prompt, tabContext: oracleContext, capturedProfile: profile
                        )
                        return AgentRepromptConsultResult(
                            kind: .oracle, status: "success", text: reply["response"]?.stringValue ?? "",
                            chatID: reply["chat_id"]?.stringValue
                        )
                    }
                } onCancel: { Task { await race.finish(.failure(CancellationError())) } }
                return Output(result: result)
            },
            contextBuilder: { instructions in
                let completion = try await builder.runContextBuilderForReprompt(
                    identity: identity, nestedTabContext: nested, instructions: instructions,
                    onSelectionCommitted: { observer.owner?.noteCommittedSelection($0) }
                )
                let selection = completion.committedTab?.tab.selection
                return Output(result: .init(
                    kind: .contextBuilder, status: selection == nil ? "failed" : "success",
                    text: (selection?.selectedPaths ?? []).joined(separator: "\n") + "\n" + (completion.agentOutput ?? ""),
                    selectedFileCount: selection?.selectedPaths.count
                ), committedSelection: nil)
            },
            readSelection: { workspace.composeTab(for: identity)?.selection },
            restoreSelection: { selection in
                guard var tab = workspace.composeTab(for: identity) else { return }
                tab.selection = selection
                workspace.updateComposeTab(tab, workspaceID: identity.workspaceID, markDirty: true)
                Task { @MainActor in
                    guard workspace.composeTab(for: identity)?.selection == selection else { return }
                    _ = await workspace.applyStoredSelectionMirrorForReadFileAutoSelection(for: identity)
                }
            }
        )
        observer.owner = consultant
        return consultant
    }

    static func boundedResult(_ text: String) -> String {
        let limit = 16 * 1024
        guard text.utf8.count > limit else { return text }
        let marker = "\n[truncated]"
        var prefix = String(decoding: text.utf8.prefix(limit - marker.utf8.count), as: UTF8.self)
        while prefix.utf8.count > limit - marker.utf8.count {
            prefix.removeLast()
        }
        return prefix + marker
    }

    static func manifest(rootNames: [String], selectedPaths: [String]) -> String {
        let limit = 4 * 1024
        var lines: [String] = []
        // Root names are bounded too: an arbitrary number of roots must not leak unbounded input.
        for root in rootNames {
            let line = "Root: \(root)"
            guard (lines + [line]).joined(separator: "\n").utf8.count <= limit - 64 else { break }
            lines.append(line)
        }
        var included = 0
        for path in selectedPaths.prefix(50) {
            guard (lines + [path]).joined(separator: "\n").utf8.count <= limit - 64 else { break }
            lines.append(path)
            included += 1
        }
        if included < selectedPaths.count {
            lines.append("+\(selectedPaths.count - included) more")
        }
        return lines.joined(separator: "\n")
    }
}
