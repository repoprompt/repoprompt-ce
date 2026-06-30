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

                let scopeResolutionStarted = DispatchTime.now().uptimeNanoseconds
                let resolved = try await debugResolveWorktreeStartupBenchmarkScope(
                    connectionID: connectionID,
                    arguments: arguments,
                    requireRootID: true
                )
                let scopeResolutionFinished = DispatchTime.now().uptimeNanoseconds
                let scopeResolutionDuration = scopeResolutionFinished >= scopeResolutionStarted
                    ? scopeResolutionFinished - scopeResolutionStarted
                    : 0
                let scope = resolved.scope
                let diagnostics = WorktreeStartupBenchmarkDiagnostics.shared
                switch action {
                case "set_flags":
                    let preparationID = try debugRequiredUUID(arguments, key: "preparation_id")
                    let expiry = try debugWorktreeStartupBenchmarkExpiry(arguments)
                    let observe = debugBool(arguments, "observe") ?? false
                    let serve = debugBool(arguments, "serve") ?? false
                    let forceFullCrawl = debugBool(arguments, "force_full") ?? false
                    let prepared = try await diagnostics.setFlagsPreparingBaseSnapshot(
                        scope: scope,
                        observe: observe,
                        serve: serve,
                        forceFullCrawl: forceFullCrawl,
                        expiresSeconds: expiry,
                        store: resolved.store,
                        expectedStandardizedRootPath: resolved.rootPath,
                        preparationID: preparationID,
                        prefixControlEvidenceCacheMode: debugBool(arguments, "bypass_prefix_control_cache") == true
                            ? .bypassReadAndAdmission
                            : .automatic,
                        scopeResolutionDurationNanoseconds: scopeResolutionDuration
                    )
                    let result = prepared.control
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "preparation_id": preparationID.uuidString,
                        "preparation": debugPreparationPayload(prepared.preparation),
                        "control_id": result.controlID.uuidString,
                        "previous_control_id": result.previousControlID.map { $0.uuidString as Any } ?? NSNull(),
                        "route": result.route.name,
                        "expires_in_seconds": expiry,
                        "base_snapshot_prepared": prepared.baseSnapshotPrepared,
                        "base_snapshot_identity_sha256": prepared.baseSnapshotIdentity?.sha256 ?? NSNull(),
                        "base_snapshot_search_abi_matcher_schema_version": prepared.baseSnapshotIdentity?.searchABI.matcherSchemaVersion ?? NSNull(),
                        "base_snapshot_search_abi_projected_key_schema_version": prepared.baseSnapshotIdentity?.searchABI.projectedKeySchemaVersion ?? NSNull(),
                        "base_snapshot_search_abi_comparator_schema_version": prepared.baseSnapshotIdentity?.searchABI.comparatorSchemaVersion ?? NSNull(),
                        "base_snapshot_search_abi_path_normalization_schema_version": prepared.baseSnapshotIdentity?.searchABI.pathNormalizationSchemaVersion ?? NSNull()
                    ])
                case "preparation_snapshot":
                    let preparationID = try debugRequiredUUID(arguments, key: "preparation_id")
                    let snapshot = try diagnostics.preparationSnapshot(
                        scope: scope,
                        preparationID: preparationID
                    )
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "preparation_id": preparationID.uuidString,
                        "preparation": debugPreparationPayload(snapshot)
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
                case "start_recovery_snapshot":
                    let correlationID = try debugRequiredUUID(arguments, key: "correlation_id")
                    let controlID = try debugRequiredUUID(arguments, key: "control_id")
                    let snapshot = try diagnostics.recoverableStartSnapshot(
                        scope: scope,
                        correlationID: correlationID,
                        controlID: controlID
                    )
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "recovery": debugRecoverableStartPayload(snapshot)
                    ])
                case "start_recovery_abort":
                    let correlationID = try debugRequiredUUID(arguments, key: "correlation_id")
                    let controlID = try debugRequiredUUID(arguments, key: "control_id")
                    let decision = try diagnostics.requestRecoverableStartAbort(
                        scope: scope,
                        correlationID: correlationID,
                        controlID: controlID
                    )
                    var discardAttempted = false
                    var discardCompleted = decision.snapshot.phase == .discardCompleted
                    if !decision.requiresAgentCancel, let target = decision.target {
                        switch target.origin {
                        case .createdNewTab, .createdForSessionResume:
                            discardAttempted = true
                            try diagnostics.recordRecoverableStartPhase(
                                correlationID: correlationID,
                                phase: .discardRequested,
                                providerRunActive: false,
                                errorCategory: "abort_requested"
                            )
                            await resolved.agentModeVM.mcpDiscardSessionTarget(target)
                            try diagnostics.recordRecoverableStartPhase(
                                correlationID: correlationID,
                                phase: .discardCompleted,
                                providerRunActive: false
                            )
                            discardCompleted = true
                        case .existingSession, .existingTab:
                            throw DebugWorktreeStartupBenchmarkError.invalidRecovery
                        }
                    }
                    let snapshot = try diagnostics.recoverableStartSnapshot(
                        scope: scope,
                        correlationID: correlationID,
                        controlID: controlID
                    )
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "requires_agent_cancel": decision.requiresAgentCancel,
                        "discard_attempted": discardAttempted,
                        "discard_completed": discardCompleted,
                        "recovery": debugRecoverableStartPayload(snapshot)
                    ])
                case "session_worktree_drain_snapshot":
                    let requestedAt = DispatchTime.now().uptimeNanoseconds
                    let correlationID = try debugRequiredUUID(arguments, key: "correlation_id")
                    let controlID = try debugRequiredUUID(arguments, key: "control_id")
                    let recovery = try diagnostics.recoverableStartSnapshot(
                        scope: scope,
                        correlationID: correlationID,
                        controlID: controlID
                    )
                    guard let ownerID = recovery.agentSessionID,
                          !recovery.ownedPhysicalPathDigests.isEmpty
                    else { throw DebugWorktreeStartupBenchmarkError.invalidRecovery }
                    let drain = try await resolved.store.sessionWorktreeOwnershipDrainSnapshotForTesting(
                        ownerID: ownerID,
                        expectedPhysicalPathDigests: Set(recovery.ownedPhysicalPathDigests),
                        requestedAtNanoseconds: requestedAt
                    )
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "correlation_id": correlationID.uuidString,
                        "drain": debugSessionWorktreeDrainPayload(drain)
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
                case "codemap_projection_snapshot":
                    guard let snapshot = await resolved.store.debugCodemapProjectionAdmissionSnapshot(
                        rootID: scope.rootID
                    ) else {
                        return debugDiagnosticsError(
                            op: op,
                            code: "codemap_unavailable",
                            message: "The scoped Git codemap engine is not ready."
                        )
                    }
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "codemap_projection": debugCodemapProjectionPayload(snapshot)
                    ])
                case "codemap_root_snapshot":
                    let targetRootID = try debugRequiredUUID(arguments, key: "target_root_id")
                    let roots = await resolved.store.readSearchRootDiagnosticsSnapshot(
                        recentPublicationLimit: 0
                    )
                    guard roots.contains(where: { $0.rootID == targetRootID }) else {
                        return debugDiagnosticsError(
                            op: op,
                            code: "invalid_scope",
                            message: "The target root is not loaded in the scoped workspace."
                        )
                    }
                    let enginePresent = await resolved.store.debugCodemapEnginePresent(
                        rootID: targetRootID
                    )
                    let snapshot = await resolved.store.debugCodemapProjectionAdmissionSnapshot(
                        rootID: targetRootID
                    )
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "target_root_id": targetRootID.uuidString,
                        "engine_present": enginePresent,
                        "codemap_projection": snapshot.map { debugCodemapProjectionPayload($0) } ?? [
                            "hold_count": 0,
                            "queued_projection_batch_count": 0,
                            "active_projection_batch_count": 0,
                            "builds": 0,
                            "projection_batches_started": 0,
                            "projection_catalog_candidates": 0,
                            "projection_budget_rejections": 0,
                            "retained_path_bytes": 0,
                            "retained_source_bytes": 0,
                            "retained_projection_bytes": 0,
                            "staged_graph_bytes": 0,
                            "resident_graph_bytes": 0,
                            "queued_manifest_mutation_bytes": 0,
                            "queue_wait_ms": []
                        ]
                    ])
                case "codemap_projection_hold_acquire":
                    let targetRootID: UUID
                    if debugString(arguments, "target_root_id") != nil {
                        targetRootID = try debugRequiredUUID(arguments, key: "target_root_id")
                        let roots = await resolved.store.readSearchRootDiagnosticsSnapshot(
                            recentPublicationLimit: 0
                        )
                        guard roots.contains(where: { $0.rootID == targetRootID }) else {
                            return debugDiagnosticsError(
                                op: op,
                                code: "invalid_scope",
                                message: "The target root is not loaded in the scoped workspace."
                            )
                        }
                    } else {
                        targetRootID = scope.rootID
                    }
                    let expiresMilliseconds = try debugRequiredBoundedInt(
                        arguments,
                        key: "expires_ms",
                        range: 10501 ... 60000
                    )
                    guard let acquired = await resolved.store.debugAcquireCodemapProjectionAdmissionHold(
                        rootID: targetRootID,
                        expiresAfterMilliseconds: UInt64(expiresMilliseconds)
                    ) else {
                        return debugDiagnosticsError(
                            op: op,
                            code: "codemap_unavailable",
                            message: "The scoped Git codemap engine is not ready."
                        )
                    }
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "target_root_id": targetRootID.uuidString,
                        "hold_id": acquired.holdID.uuidString,
                        "expires_ms": expiresMilliseconds,
                        "codemap_projection": debugCodemapProjectionPayload((
                            metrics: acquired.metrics,
                            queueWaitMilliseconds: acquired.queueWaitMilliseconds
                        ))
                    ])
                case "codemap_projection_hold_release":
                    let targetRootID: UUID = if debugString(arguments, "target_root_id") != nil {
                        try debugRequiredUUID(arguments, key: "target_root_id")
                    } else {
                        scope.rootID
                    }
                    let holdID = try debugRequiredUUID(arguments, key: "hold_id")
                    guard let released = await resolved.store.debugReleaseCodemapProjectionAdmissionHold(
                        rootID: targetRootID,
                        holdID: holdID
                    ) else {
                        return debugDiagnosticsError(
                            op: op,
                            code: "codemap_unavailable",
                            message: "The scoped Git codemap engine is not ready."
                        )
                    }
                    return debugDiagnosticsResult([
                        "ok": true,
                        "op": op,
                        "action": action,
                        "target_root_id": targetRootID.uuidString,
                        "hold_id": holdID.uuidString,
                        "released": released.released,
                        "codemap_projection": debugCodemapProjectionPayload((
                            metrics: released.metrics,
                            queueWaitMilliseconds: released.queueWaitMilliseconds
                        ))
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
                return debugWorktreeStartupBenchmarkError(op: op, error: error)
            } catch let error as DebugWorktreeStartupBenchmarkRequestError {
                return debugDiagnosticsError(op: op, code: error.code, message: "Invalid worktree startup benchmark request.")
            } catch {
                return debugDiagnosticsError(op: op, code: "unavailable", message: "Worktree startup benchmark diagnostics unavailable.")
            }
        }

        private nonisolated func debugWorktreeStartupBenchmarkError(
            op: String,
            error: DebugWorktreeStartupBenchmarkError
        ) -> CallTool.Result {
            guard case let .baseSnapshotUnavailable(failure) = error else {
                return debugDiagnosticsError(
                    op: op,
                    code: error.code,
                    message: "Worktree startup benchmark request rejected."
                )
            }
            return debugDiagnosticsResult([
                "ok": false,
                "op": op,
                "code": error.code,
                "error": "Worktree startup benchmark request rejected.",
                "base_snapshot_reason": failure.reason.rawValue,
                "base_snapshot_stage": failure.stage?.rawValue ?? NSNull(),
                "base_snapshot_cause": failure.cause ?? NSNull()
            ], isError: true)
        }

        @MainActor
        private func debugResolveWorktreeStartupBenchmarkScope(
            connectionID: UUID,
            arguments: [String: Value],
            requireRootID: Bool
        ) async throws -> (
            scope: DebugWorktreeStartupBenchmarkScope,
            rootPath: String,
            store: WorkspaceFileContextStore,
            agentModeVM: AgentModeViewModel
        ) {
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
                  WorktreeStartupBenchmarkDiagnostics.requiredWorkspaceNamePrefixes.contains { workspace.name.hasPrefix($0) },
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
                (selectedRoot.rootPath as NSString).standardizingPath,
                window.workspaceFileContextStore,
                window.agentModeViewModel
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
            case "first_codemap_started": .firstBenchmarkCodemapStarted
            case "first_codemap_completed": .firstBenchmarkCodemapCompleted
            case "warm_codemap_started": .warmBenchmarkCodemapStarted
            case "warm_codemap_completed": .warmBenchmarkCodemapCompleted
            case "passive_tree_started": .passiveBenchmarkTreeStarted
            case "passive_tree_completed": .passiveBenchmarkTreeCompleted
            case "selection_started": .benchmarkSelectionStarted
            case "selection_completed": .benchmarkSelectionCompleted
            default: throw DebugWorktreeStartupBenchmarkRequestError.invalidParameter
            }
        }

        private nonisolated func debugRecoverableStartPayload(
            _ snapshot: WorktreeStartupBenchmarkDiagnostics.RecoverableStartSnapshot
        ) -> [String: Any] {
            [
                "bounded": true,
                "contains_paths": false,
                "correlation_id": snapshot.correlationID.uuidString,
                "control_id": snapshot.controlID.uuidString,
                "invocation": snapshot.invocation,
                "ordinal": snapshot.ordinal,
                "warmup": snapshot.warmup,
                "phase": snapshot.phase.rawValue,
                "abort_requested": snapshot.abortRequested,
                "agent_session_id": snapshot.agentSessionID?.uuidString ?? NSNull(),
                "target_tab_id": snapshot.targetTabID?.uuidString ?? NSNull(),
                "target_origin": snapshot.targetOrigin ?? NSNull(),
                "worktree_id": snapshot.worktreeID ?? NSNull(),
                "repository_id": snapshot.repositoryID ?? NSNull(),
                "repository_key": snapshot.repositoryKey ?? NSNull(),
                "branch": snapshot.branch ?? NSNull(),
                "head": snapshot.head ?? NSNull(),
                "worktree_path_sha256": snapshot.worktreePathDigest ?? NSNull(),
                "owned_physical_path_sha256": snapshot.ownedPhysicalPathDigests,
                "binding_id": snapshot.bindingID ?? NSNull(),
                "provider_dispatch_started": snapshot.providerDispatchStarted,
                "provider_run_active": snapshot.providerRunActive,
                "error_category": snapshot.errorCategory ?? NSNull(),
                "expires_at_monotonic_ns": snapshot.expiresAtNanoseconds
            ]
        }

        private nonisolated func debugSessionWorktreeDrainPayload(
            _ snapshot: WorkspaceFileContextStore.SessionWorktreeOwnershipDrainDebugSnapshot
        ) -> [String: Any] {
            [
                "bounded": true,
                "contains_paths": false,
                "owner_id": snapshot.ownerID.uuidString,
                "owner_generation": snapshot.ownerGeneration,
                "expected_physical_path_sha256": snapshot.expectedPhysicalPathDigests,
                "actor_entry_delay_us": snapshot.actorEntryDelayNanoseconds / 1000,
                "installed_token_count": snapshot.installedTokenCount,
                "provisional_token_count": snapshot.provisionalTokenCount,
                "root_claim_count": snapshot.rootClaimCount,
                "path_reservation_count": snapshot.pathReservationCount,
                "matching_live_root_count": snapshot.matchingLiveRootCount,
                "matching_watcher_attachment_count": snapshot.matchingWatcherAttachmentCount,
                "pending_seeded_root_count": snapshot.pendingSeededRootCount,
                "pending_visibility_waiter_count": snapshot.pendingVisibilityWaiterCount,
                "queued_publication_count": snapshot.queuedPublicationCount,
                "applying_publication_count": snapshot.applyingPublicationCount,
                "outstanding_publication_count": snapshot.outstandingPublicationCount,
                "publisher_waiter_count": snapshot.publisherWaiterCount,
                "unloading_root_count": snapshot.unloadingRootCount,
                "reserved_load_flight_count": snapshot.reservedLoadFlightCount,
                "is_drained": snapshot.isDrained
            ]
        }

        private nonisolated func debugCodemapProjectionPayload(
            _ snapshot: (metrics: [String: UInt64], queueWaitMilliseconds: [UInt64])
        ) -> [String: Any] {
            var payload = snapshot.metrics.reduce(into: [String: Any]()) { result, item in
                result[item.key] = item.value
            }
            payload["queue_wait_ms"] = snapshot.queueWaitMilliseconds
            return payload
        }

        private nonisolated func debugPreparationPayload(
            _ snapshot: WorktreeStartupPreparationInstrumentation.Snapshot
        ) -> [String: Any] {
            let phases = Dictionary(uniqueKeysWithValues: WorktreeStartupPreparationInstrumentation.Phase.allCases.map {
                let metric = snapshot.phases[$0]!
                return ($0.rawValue, [
                    "count": metric.count,
                    "completed_count": metric.completedCount,
                    "completed_duration_us": metric.completedDurationNanoseconds / 1000,
                    "active_count": metric.activeCount,
                    "active_elapsed_us": metric.activeElapsedNanoseconds / 1000
                ] as [String: Any])
            })
            let counters = Dictionary(uniqueKeysWithValues: WorktreeStartupPreparationInstrumentation.Counter.allCases.map {
                ($0.rawValue, snapshot.counters[$0] ?? 0)
            })
            let saturation = Dictionary(uniqueKeysWithValues: WorktreeStartupPreparationInstrumentation.Counter.allCases.map {
                ($0.rawValue, snapshot.saturatedCounters.contains($0))
            })
            let reasons = Dictionary(uniqueKeysWithValues: WorktreeStartupPreparationInstrumentation.Reason.allCases.map {
                ($0.rawValue, snapshot.reasons[$0] ?? 0)
            })
            let routeControlOwnership: Any = snapshot.routeControlOwnership.map { ownership in
                [
                    "control_id": ownership.controlID.uuidString,
                    "window_id": ownership.windowID,
                    "workspace_id": ownership.workspaceID.uuidString,
                    "context_id": ownership.contextID.uuidString,
                    "root_id": ownership.rootID.uuidString,
                    "revoked": ownership.revoked
                ] as [String: Any]
            } ?? NSNull()
            return [
                "schema_version": 1,
                "path_free": true,
                "preparation_id": snapshot.preparationID.uuidString,
                "terminal_state": snapshot.terminalState?.rawValue ?? "active",
                "current_active_phase": snapshot.currentActivePhase?.rawValue ?? NSNull(),
                "route_control_ownership": routeControlOwnership,
                "started_monotonic_ns": snapshot.startedAtNanoseconds,
                "elapsed_us": snapshot.elapsedNanoseconds / 1000,
                "phases": phases,
                "counters": counters,
                "counter_saturated": saturation,
                "reasons": reasons
            ]
        }
    }

    private enum DebugWorktreeStartupBenchmarkRequestError: Error {
        case invalidParameter

        var code: String {
            "invalid_params"
        }
    }
#endif
