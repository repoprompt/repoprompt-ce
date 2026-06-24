// MARK: - DEBUG Worktree Startup Benchmark Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        @MainActor
        func debugWorktreeStartupBenchmarkPayload(
            op: String,
            connectionID: UUID,
            arguments: [String: Value]
        ) async -> CallTool.Result {
            WorktreeStartupBenchmarkDiagnostics.synchronizeGateFromDefaults()
            let action = debugString(arguments, "action")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "snapshot"

            do {
                if action == "scope" {
                    let resolved = try await debugResolveWorktreeStartupBenchmarkScope(
                        connectionID: connectionID,
                        arguments: arguments,
                        requireRootID: false
                    )
                    let scope = resolved.scope
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "window_id": scope.windowID,
                        "workspace_id": scope.workspaceID.uuidString,
                        "context_id": scope.contextID.uuidString,
                        "root_id": scope.rootID.uuidString,
                        "path_free": true
                    ])
                }

                let resolved = try await debugResolveWorktreeStartupBenchmarkScope(
                    connectionID: connectionID,
                    arguments: arguments,
                    requireRootID: true
                )
                let scope = resolved.scope
                let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
                switch action {
                case "set_flags":
                    let expiry = try debugWorktreeStartupBenchmarkExpiry(arguments)
                    let result = try diagnostics.setFlags(
                        scope: scope,
                        observe: debugBool(arguments, "observe") ?? false,
                        serve: debugBool(arguments, "serve") ?? false,
                        forceFullCrawl: debugBool(arguments, "force_full") ?? false,
                        expiresSeconds: expiry
                    )
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "control_id": result.controlID.uuidString,
                        "previous_control_id": result.previousControlID.map { $0.uuidString as Any } ?? NSNull(),
                        "route": result.route.name,
                        "expires_in_seconds": expiry
                    ])
                case "restore_flags":
                    let controlID = try debugRequiredUUID(arguments, key: "control_id")
                    let restored = try diagnostics.restoreFlags(scope: scope, controlID: controlID)
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "restored_control_id": restored.map { $0.uuidString as Any } ?? NSNull()
                    ])
                case "arm":
                    let controlID = try debugRequiredUUID(arguments, key: "control_id")
                    let scenario = try debugWorktreeStartupBenchmarkScenario(arguments)
                    let invocation = try debugRequiredBoundedInt(
                        arguments,
                        key: "invocation",
                        range: 1 ... 1_000_000
                    )
                    let ordinal = try debugRequiredBoundedInt(
                        arguments,
                        key: "ordinal",
                        range: 1 ... 1_000_000
                    )
                    let expiry = try debugWorktreeStartupBenchmarkExpiry(arguments)
                    guard let layout = GitRepositoryLayoutResolver.resolve(
                        atWorkTreeRoot: URL(fileURLWithPath: resolved.rootPath)
                    ) else { throw DebugWorktreeStartupBenchmarkError.startIdentityMismatch }
                    let repository = GitWorktreeIdentity.repositoryIdentity(
                        commonGitDir: layout.commonDir,
                        mainWorktreeRoot: layout.knownMainWorktreeRoot
                    )
                    let result = try diagnostics.arm(
                        expectedStart: DebugWorktreeStartupBenchmarkExpectedStart(
                            rootIdentity: DebugWorktreeStartupBenchmarkRootIdentity(
                                scope: scope,
                                standardizedLogicalRootPath: resolved.rootPath,
                                repositoryID: repository.repositoryID,
                                repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout)
                            ),
                            requestedBranch: debugString(arguments, "worktree_branch"),
                            requestedBaseRef: debugString(arguments, "worktree_base_ref")
                        ),
                        controlID: controlID,
                        scenario: scenario,
                        invocation: invocation,
                        ordinal: ordinal,
                        warmup: debugBool(arguments, "warmup") ?? false,
                        expiresSeconds: expiry
                    )
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "token": result.token.uuidString,
                        "correlation_id": result.correlationID.uuidString,
                        "route": result.route.name,
                        "expires_in_seconds": expiry
                    ])
                case "mark":
                    let correlationID = try debugRequiredUUID(arguments, key: "correlation_id")
                    let phase = try debugWorktreeStartupBenchmarkMark(arguments)
                    try diagnostics.mark(scope: scope, correlationID: correlationID, phase: phase)
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "correlation_id": correlationID.uuidString,
                        "mark": phase.rawValue
                    ])
                case "snapshot", "export":
                    let correlationID = try debugRequiredUUID(arguments, key: "correlation_id")
                    var payload = try diagnostics.snapshotPayload(
                        scope: scope,
                        correlationID: correlationID,
                        export: action == "export"
                    )
                    payload["op"] = op
                    return debugDiagnosticsResult(payload)
                case "reset":
                    let counts = try diagnostics.reset(scope: scope)
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "reset": counts
                    ])
                default:
                    return debugDiagnosticsError(
                        op: op,
                        code: "invalid_params",
                        message: "Unknown worktree startup benchmark action."
                    )
                }
            } catch let error as DebugWorktreeStartupBenchmarkError {
                return debugDiagnosticsError(op: op, code: error.code, message: "Worktree startup benchmark request rejected.")
            } catch let error as DebugWorktreeStartupBenchmarkRequestError {
                return debugDiagnosticsError(op: op, code: error.code, message: "Invalid worktree startup benchmark request.")
            } catch {
                return debugDiagnosticsError(op: op, code: "unavailable", message: "Worktree startup benchmark diagnostics unavailable.")
            }
        }

        @MainActor
        private func debugResolveWorktreeStartupBenchmarkScope(
            connectionID: UUID,
            arguments: [String: Value],
            requireRootID: Bool
        ) async throws -> (scope: DebugWorktreeStartupBenchmarkScope, rootPath: String) {
            let suppliedWindowID = try debugRequiredBoundedInt(arguments, key: "window_id", range: 1 ... Int.max)
            let hiddenWindowID = try debugRequiredBoundedInt(arguments, key: "_windowID", range: 1 ... Int.max)
            let suppliedWorkspaceID = try debugRequiredUUID(arguments, key: "workspace_id")
            let suppliedContextID = try debugRequiredUUID(arguments, key: "context_id")
            let benchmarkContextID = try debugRequiredUUID(arguments, key: "benchmark_context_id")
            guard let boundWindowID = await selectedWindow(for: connectionID),
                  let window = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == boundWindowID }),
                  let workspace = window.workspaceManager.activeWorkspace,
                  let bindingWindowID = window.mcpServer.connectionBindingSnapshot(forConnection: connectionID).windowID,
                  let boundContextID = window.mcpServer.connectionBindingSnapshot(forConnection: connectionID).tabID,
                  let boundWorkspaceID = window.mcpServer.connectionBindingSnapshot(forConnection: connectionID).workspaceID,
                  bindingWindowID == boundWindowID,
                  boundWorkspaceID == workspace.id,
                  workspace.isSystemWorkspace == false,
                  workspace.name.hasPrefix(WorktreeStartupBenchmarkDiagnostics.requiredWorkspaceNamePrefix),
                  window.workspaceManager.bindingCandidate(forContextID: boundContextID)?.workspaceID == workspace.id
            else { throw DebugWorktreeStartupBenchmarkError.invalidScope }
            try DebugWorktreeStartupBenchmarkRoutingProvenance(
                connectionID: connectionID,
                boundWindowID: boundWindowID,
                boundWorkspaceID: workspace.id,
                boundContextID: boundContextID
            ).authorize(
                connectionID: connectionID,
                windowID: suppliedWindowID,
                hiddenWindowID: hiddenWindowID,
                workspaceID: suppliedWorkspaceID,
                contextID: suppliedContextID,
                benchmarkContextID: benchmarkContextID
            )

            let roots = await window.workspaceFileContextStore.readSearchRootDiagnosticsSnapshot(recentPublicationLimit: 0)
            let selectedRoot: WorkspaceFileContextStore.ReadSearchRootDiagnosticsSnapshot
            if requireRootID {
                let rootID = try debugRequiredUUID(arguments, key: "root_id")
                guard let root = roots.first(where: { $0.rootID == rootID }) else {
                    throw DebugWorktreeStartupBenchmarkError.invalidScope
                }
                selectedRoot = root
            } else {
                guard let expectedPath = debugString(arguments, "expected_root_path")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    expectedPath.hasPrefix("/")
                else { throw DebugWorktreeStartupBenchmarkRequestError.invalidParameter }
                let standardized = (expectedPath as NSString).standardizingPath
                guard let root = roots.first(where: {
                    ($0.rootPath as NSString).standardizingPath == standardized
                }) else { throw DebugWorktreeStartupBenchmarkError.invalidScope }
                selectedRoot = root
            }
            return (
                DebugWorktreeStartupBenchmarkScope(
                    windowID: boundWindowID,
                    workspaceID: workspace.id,
                    contextID: boundContextID,
                    rootID: selectedRoot.rootID
                ),
                (selectedRoot.rootPath as NSString).standardizingPath
            )
        }

        private nonisolated func debugRequiredUUID(
            _ arguments: [String: Value],
            key: String
        ) throws -> UUID {
            guard let raw = debugString(arguments, key), let value = UUID(uuidString: raw) else {
                throw DebugWorktreeStartupBenchmarkRequestError.invalidParameter
            }
            return value
        }

        private nonisolated func debugRequiredBoundedInt(
            _ arguments: [String: Value],
            key: String,
            range: ClosedRange<Int>
        ) throws -> Int {
            switch debugBoundedInt(arguments, key, defaultValue: range.lowerBound - 1, range: range) {
            case let .value(value): value
            case .defaulted, .invalid: throw DebugWorktreeStartupBenchmarkRequestError.invalidParameter
            }
        }

        private nonisolated func debugWorktreeStartupBenchmarkExpiry(_ arguments: [String: Value]) throws -> Int {
            switch debugBoundedInt(arguments, "expires_seconds", defaultValue: 120, range: 5 ... 900) {
            case let .value(value), let .defaulted(value): value
            case .invalid: throw DebugWorktreeStartupBenchmarkRequestError.invalidParameter
            }
        }

        private nonisolated func debugWorktreeStartupBenchmarkScenario(_ arguments: [String: Value]) throws -> String {
            let allowed: Set = [
                "main_checkout", "clean_same_tree", "historical_delta", "parallel", "aged", "correctness", "non_git"
            ]
            guard let scenario = debugString(arguments, "scenario")?.lowercased(), allowed.contains(scenario) else {
                throw DebugWorktreeStartupBenchmarkRequestError.invalidParameter
            }
            return scenario
        }

        private nonisolated func debugWorktreeStartupBenchmarkMark(
            _ arguments: [String: Value]
        ) throws -> WorktreeStartupPhase {
            switch debugString(arguments, "mark")?.lowercased() {
            case "first_search_started": .firstBenchmarkSearchStarted
            case "first_search_completed": .firstBenchmarkSearchCompleted
            case "first_read_started": .firstBenchmarkReadStarted
            case "first_read_completed": .firstBenchmarkReadCompleted
            default: throw DebugWorktreeStartupBenchmarkRequestError.invalidParameter
            }
        }
    }

    private enum DebugWorktreeStartupBenchmarkRequestError: Error {
        case invalidParameter

        var code: String {
            "invalid_params"
        }
    }
#endif
