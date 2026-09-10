#if DEBUG
    import Foundation

    /// Executes approved Prompt Experiment trials through the existing Context Builder runtime.
    ///
    /// Isolation is structural, not prompt-based: native provider file/shell tools are disabled by
    /// discovery configuration, the provider cwd is the experiment’s synthetic root, and every
    /// RepoPrompt file tool inherits a frozen lookup context containing only that root.
    @MainActor
    final class NativePromptExperimentContextBuilderRuntime: PromptExperimentRuntime {
        private struct RunningAttempt {
            let task: Task<PromptExperimentRuntimeResult, Never>
            let workspaceID: UUID
            let tabID: UUID
            let rootID: UUID
            let controlToken: UUID
        }

        private struct RunningOptimization {
            let task: Task<PromptExperimentRuntimeResult, Never>
            let worker: PromptExperimentGEPAWorker
        }

        private weak var windowState: WindowState?
        private var running: [UUID: RunningAttempt] = [:]
        private var runningOptimizations: [UUID: RunningOptimization] = [:]
        private var optimizationChildren: [UUID: [PromptExperimentRuntimeHandle]] = [:]
        private var cancelledOptimizationIDs: Set<UUID> = []

        init(windowState: WindowState) {
            self.windowState = windowState
        }

        func preflightOptimization(_ plan: PromptExperimentPlan) async throws {
            guard let optimization = plan.optimization else { return }
            guard plan.executionAdapter == PromptExperimentPlan.gepaExecutionAdapter,
                  plan.verifiesIntegrity(),
                  plan.optimizationTargets != nil
            else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The sealed upstream GEPA plan is invalid.")
            }
            guard optimization.gepa.engine == "gepa" else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("Only the pinned upstream GEPA engine is admitted.")
            }
            guard FileManager.default.fileExists(atPath: "/usr/bin/sandbox-exec")
                || optimization.evaluator.kind != .sandboxedCommand
            else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The sealed command evaluator requires macOS sandbox-exec, which is unavailable.")
            }
            try await PromptExperimentGEPAWorker.preflight(
                pythonExecutable: optimization.gepa.pythonExecutablePath
            )
        }

        func submit(
            _ request: PromptExperimentRunRequest,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async throws -> PromptExperimentRuntimeHandle {
            guard let windowState else {
                throw PromptExperimentSubmissionError.rejected("The bound Agent window is no longer available.")
            }
            guard running[request.attempt.id] == nil else {
                throw PromptExperimentSubmissionError.rejected("This attempt already has a runtime submission.")
            }
            let plan = request.plan
            guard plan.verifiesIntegrity(), plan.environment.fixtureFiles.count == 1 else {
                throw PromptExperimentSubmissionError.rejected("The sealed plan or synthetic environment is invalid.")
            }
            if plan.optimization != nil {
                return try await submitOptimization(request, progress: progress)
            }
            guard plan.executionAdapter == PromptExperimentPlan.executionAdapter else {
                throw PromptExperimentSubmissionError.rejected("The legacy Context Builder plan adapter is invalid.")
            }
            let rootURL = URL(fileURLWithPath: plan.environment.isolatedRootPath).standardizedFileURL
            let liveEnvironmentsURL = PromptExperimentStore.liveRootURL()
                .appendingPathComponent("environments", isDirectory: true)
                .standardizedFileURL
            guard rootURL.path.hasPrefix(liveEnvironmentsURL.path + "/") else {
                throw PromptExperimentSubmissionError.rejected("Loaded-workspace roots are unsupported; only app-owned synthetic environments may run.")
            }
            let beforeDigest: String
            do {
                beforeDigest = try verifyEnvironment(plan.environment)
            } catch {
                throw PromptExperimentSubmissionError.rejected(error.localizedDescription)
            }

            let workspaceID = PromptExperimentDigest.deterministicUUID(
                namespace: "runtime-workspace",
                value: request.attempt.id.uuidString
            )
            let tabID = PromptExperimentDigest.deterministicUUID(
                namespace: "runtime-tab",
                value: request.attempt.id.uuidString
            )
            let selection = plan.environment.selection
            let tab = ComposeTabState(
                id: tabID,
                name: "Experiment \(request.attempt.ordinal)",
                lastModified: Date(),
                selection: selection,
                promptText: plan.taskInput,
                contextBuilder: ContextBuilderTabConfig(instructions: plan.instructions(for: request.attempt.condition))
            )
            let workspace = WorkspaceModel(
                id: workspaceID,
                name: "Prompt Experiment \(request.experimentID.uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                lastUsed: Date(),
                ephemeralFlag: true,
                isHiddenInMenus: true,
                isSavedWorkspace: false,
                composeTabs: [tab],
                activeComposeTabID: tabID
            )

            var rootID: UUID?
            do {
                let loadedRoot = try await windowState.workspaceFileContextStore.loadRoot(
                    path: rootURL.path,
                    kind: .primaryWorkspace,
                    respectRepoIgnore: false,
                    respectCursorignore: false,
                    skipSymlinks: true,
                    enableHierarchicalIgnores: false,
                    cancelUnderlyingLoadOnCallerCancellation: true
                )
                rootID = loadedRoot.id
                guard windowState.workspaceManager.workspaces.allSatisfy({ $0.id != workspaceID }) else {
                    throw PromptExperimentSubmissionError.rejected("The isolated runtime workspace identity is already in use.")
                }
                windowState.workspaceManager.workspaces.append(workspace)

                let lookupContext = WorkspaceLookupContext(
                    rootScope: .sessionBoundWorkspace(
                        canonicalRootPaths: [rootURL.path],
                        physicalRootPaths: []
                    ),
                    bindingProjection: nil
                )
                let snapshot = MCPServerViewModel.TabContextSnapshot(
                    tabID: tabID,
                    windowID: windowState.windowID,
                    workspaceID: workspaceID,
                    promptText: plan.taskInput,
                    selection: selection,
                    selectedMetaPromptIDs: [],
                    tabName: tab.name,
                    runID: nil,
                    activeAgentSessionID: nil,
                    worktreeBindings: [],
                    frozenLookupContext: lookupContext,
                    contextBuilderReviewTargetResolution: .unavailable(.missingFrozenTarget),
                    explicitlyBound: true
                )
                let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
                let baseAuthority = try await windowState.contextBuilderAgentViewModel.resolveMCPRunAuthority(
                    identity: identity,
                    nestedTabContext: snapshot,
                    workspaceContext: nil,
                    responseType: nil
                )
                guard let agent = AgentProviderKind(rawValue: plan.resolvedTarget.agentRaw) else {
                    throw PromptExperimentSubmissionError.rejected("The sealed provider is no longer recognized.")
                }
                switch agent {
                case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec:
                    break
                case .openCode, .cursor, .grokBuild, .antigravity:
                    throw PromptExperimentSubmissionError.rejected(
                        "This provider does not have a proven exact-model, synthetic-cwd, file/shell-free discovery profile for the isolated pilot."
                    )
                }
                let baseConfiguration = baseAuthority.configuration
                let configuration = ContextBuilderMCPRunConfiguration(
                    identity: baseConfiguration.identity,
                    nestedTabContext: baseConfiguration.nestedTabContext,
                    providerWorkspacePath: rootURL.path,
                    runBehavior: baseConfiguration.runBehavior,
                    responseType: baseConfiguration.responseType,
                    planningModelRaw: baseConfiguration.planningModelRaw,
                    agentModelsProfile: baseConfiguration.agentModelsProfile,
                    isSystemWorkspace: baseConfiguration.isSystemWorkspace,
                    codexRunConstraints: agent == .codexExec
                        ? .promptExperiment(workingDirectory: rootURL.path)
                        : nil
                )
                let authority = ContextBuilderResolvedRunAuthority(
                    configuration: configuration,
                    agentKind: agent,
                    modelRaw: plan.resolvedTarget.modelRaw
                )
                let controlToken = try windowState.contextBuilderAgentViewModel.beginMCPControlledRun(
                    forTabID: tabID,
                    workspaceID: workspaceID,
                    responseType: nil,
                    planModelName: nil
                )
                let task = Task { @MainActor [self] in
                    let result: PromptExperimentRuntimeResult
                    do {
                        let completion = try await windowState.contextBuilderAgentViewModel.runContextBuilderForMCP(
                            authority: authority,
                            instructionsOverride: plan.instructions(for: request.attempt.condition),
                            workspaceContext: nil,
                            mcpControlToken: controlToken,
                            progressReporter: { phase in
                                await progress("Context Builder: \(phase.displayName)")
                            },
                            activityReporter: { phase, message in
                                await progress("Context Builder \(phase.stage): \(message)")
                            }
                        )
                        result = Self.runtimeResult(
                            completion: completion,
                            fallbackProvider: plan.resolvedTarget.agentRaw,
                            fallbackModel: plan.resolvedTarget.modelRaw,
                            fixtureDigestBefore: beforeDigest,
                            fixtureDigestAfter: try? verifyEnvironment(plan.environment)
                        )
                    } catch is CancellationError {
                        result = PromptExperimentRuntimeResult(
                            disposition: .cancelled,
                            runtimeLink: PromptExperimentRuntimeLink(
                                adapter: PromptExperimentPlan.executionAdapter,
                                tabID: tabID,
                                runID: nil,
                                provider: plan.resolvedTarget.agentRaw,
                                model: plan.resolvedTarget.modelRaw
                            ),
                            committedHandoff: nil,
                            assistantOutput: nil,
                            handoffUnavailableReason: "Context Builder was cancelled before an immutable handoff was committed.",
                            fixtureDigestBefore: beforeDigest,
                            fixtureDigestAfter: try? verifyEnvironment(plan.environment)
                        )
                    } catch {
                        result = PromptExperimentRuntimeResult(
                            disposition: .failed(error.localizedDescription),
                            runtimeLink: PromptExperimentRuntimeLink(
                                adapter: PromptExperimentPlan.executionAdapter,
                                tabID: tabID,
                                runID: nil,
                                provider: plan.resolvedTarget.agentRaw,
                                model: plan.resolvedTarget.modelRaw
                            ),
                            committedHandoff: nil,
                            assistantOutput: nil,
                            handoffUnavailableReason: "Context Builder failed before an immutable handoff was committed.",
                            fixtureDigestBefore: beforeDigest,
                            fixtureDigestAfter: try? verifyEnvironment(plan.environment)
                        )
                    }
                    await cleanup(workspaceID: workspaceID, tabID: tabID, rootID: loadedRoot.id, controlToken: controlToken)
                    return result
                }
                running[request.attempt.id] = RunningAttempt(
                    task: task,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    rootID: loadedRoot.id,
                    controlToken: controlToken
                )
                return PromptExperimentRuntimeHandle(id: request.attempt.id, tabID: tabID, runID: nil)
            } catch let error as PromptExperimentSubmissionError {
                if let rootID { await cleanupBeforeControl(workspaceID: workspaceID, rootID: rootID) }
                throw error
            } catch {
                if let rootID { await cleanupBeforeControl(workspaceID: workspaceID, rootID: rootID) }
                throw PromptExperimentSubmissionError.rejected(error.localizedDescription)
            }
        }

        private enum OptimizationTimeoutError: LocalizedError {
            case exceeded(Int)

            var errorDescription: String? {
                switch self {
                case let .exceeded(seconds): "GEPA exceeded the sealed wall-clock limit of \(seconds) seconds."
                }
            }
        }

        private func submitOptimization(
            _ request: PromptExperimentRunRequest,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async throws -> PromptExperimentRuntimeHandle {
            guard request.plan.executionAdapter == PromptExperimentPlan.gepaExecutionAdapter,
                  let optimization = request.plan.optimization,
                  request.plan.optimizationTargets != nil
            else {
                throw PromptExperimentSubmissionError.rejected("The sealed GEPA optimization envelope is incomplete.")
            }
            guard runningOptimizations[request.attempt.id] == nil else {
                throw PromptExperimentSubmissionError.rejected("This GEPA run already has a runtime submission.")
            }
            let beforeDigest: String
            do {
                beforeDigest = try verifyEnvironment(request.plan.environment)
                try await preflightOptimization(request.plan)
            } catch {
                throw PromptExperimentSubmissionError.rejected(error.localizedDescription)
            }
            let worker = PromptExperimentGEPAWorker()
            cancelledOptimizationIDs.remove(request.attempt.id)
            let task = Task { @MainActor [self] in
                do {
                    let result = try await withThrowingTaskGroup(of: PromptExperimentOptimizationRuntimeResult.self) { group in
                        group.addTask {
                            try await worker.run(
                                plan: request.plan,
                                attemptID: request.attempt.id,
                                host: { operation, payload in
                                    await self.handleGEPAHostRequest(
                                        parentRequest: request,
                                        operation: operation,
                                        payload: payload,
                                        progress: progress
                                    )
                                },
                                progress: progress
                            )
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(optimization.gepa.maxWallClockSeconds))
                            throw OptimizationTimeoutError.exceeded(optimization.gepa.maxWallClockSeconds)
                        }
                        guard let first = try await group.next() else {
                            throw PromptExperimentAuthorityError.runtimeUnavailable("GEPA produced no terminal result.")
                        }
                        group.cancelAll()
                        worker.cancel()
                        return first
                    }
                    return PromptExperimentRuntimeResult(
                        disposition: .completed,
                        runtimeLink: PromptExperimentRuntimeLink(
                            adapter: PromptExperimentPlan.gepaExecutionAdapter,
                            tabID: nil,
                            runID: request.attempt.id,
                            provider: request.plan.optimizationTargets?.reflection.agentRaw,
                            model: request.plan.optimizationTargets?.reflection.modelRaw
                        ),
                        committedHandoff: nil,
                        assistantOutput: nil,
                        handoffUnavailableReason: nil,
                        fixtureDigestBefore: beforeDigest,
                        fixtureDigestAfter: try? verifyEnvironment(request.plan.environment),
                        optimizationResult: result
                    )
                } catch is CancellationError {
                    cancelledOptimizationIDs.insert(request.attempt.id)
                    await cancelAndDrainOptimizationChildren(parentID: request.attempt.id)
                    return PromptExperimentRuntimeResult(
                        disposition: .cancelled,
                        runtimeLink: PromptExperimentRuntimeLink(
                            adapter: PromptExperimentPlan.gepaExecutionAdapter,
                            tabID: nil,
                            runID: request.attempt.id,
                            provider: request.plan.optimizationTargets?.reflection.agentRaw,
                            model: request.plan.optimizationTargets?.reflection.modelRaw
                        ),
                        committedHandoff: nil,
                        assistantOutput: nil,
                        handoffUnavailableReason: "GEPA was cancelled after active app-owned provider work settled.",
                        fixtureDigestBefore: beforeDigest,
                        fixtureDigestAfter: try? verifyEnvironment(request.plan.environment)
                    )
                } catch {
                    cancelledOptimizationIDs.insert(request.attempt.id)
                    await cancelAndDrainOptimizationChildren(parentID: request.attempt.id)
                    worker.cancel()
                    return PromptExperimentRuntimeResult(
                        disposition: .failed(error.localizedDescription),
                        runtimeLink: PromptExperimentRuntimeLink(
                            adapter: PromptExperimentPlan.gepaExecutionAdapter,
                            tabID: nil,
                            runID: request.attempt.id,
                            provider: request.plan.optimizationTargets?.reflection.agentRaw,
                            model: request.plan.optimizationTargets?.reflection.modelRaw
                        ),
                        committedHandoff: nil,
                        assistantOutput: nil,
                        handoffUnavailableReason: "Upstream GEPA infrastructure failed before producing an immutable result.",
                        fixtureDigestBefore: beforeDigest,
                        fixtureDigestAfter: try? verifyEnvironment(request.plan.environment)
                    )
                }
            }
            runningOptimizations[request.attempt.id] = RunningOptimization(task: task, worker: worker)
            optimizationChildren[request.attempt.id] = []
            await progress("Pinned GEPA \(PromptExperimentGEPAConfiguration.packageVersion) worker admitted; model credentials remain in RepoPrompt.")
            return PromptExperimentRuntimeHandle(id: request.attempt.id, tabID: nil, runID: request.attempt.id)
        }

        private func handleGEPAHostRequest(
            parentRequest: PromptExperimentRunRequest,
            operation: String,
            payload: [String: Any],
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async -> PromptExperimentGEPAHostReply {
            guard !cancelledOptimizationIDs.contains(parentRequest.attempt.id) else {
                return infrastructureReply("The GEPA run was cancelled before this host request could start.")
            }
            guard let specification = parentRequest.plan.optimization,
                  let targets = parentRequest.plan.optimizationTargets
            else {
                return infrastructureReply("The sealed GEPA host configuration is unavailable.")
            }
            do {
                switch operation {
                case "reflect":
                    let promptValue = payload["prompt"]
                    let prompt: String
                    if let value = promptValue as? String {
                        prompt = value
                    } else if JSONSerialization.isValidJSONObject(promptValue as Any) {
                        prompt = try String(decoding: JSONSerialization.data(withJSONObject: promptValue as Any, options: [.sortedKeys]), as: UTF8.self)
                    } else {
                        throw PromptExperimentAuthorityError.runtimeUnavailable("GEPA supplied an invalid reflection prompt.")
                    }
                    await progress("GEPA is requesting a reflection proposal from \(targets.reflection.displayName).")
                    let output = try await invokeContextBuilder(
                        parentRequest: parentRequest,
                        target: targets.reflection,
                        taskInput: prompt,
                        instructions: "Act as GEPA's reflection language model. Return only the proposed replacement candidate; do not access or modify any source outside the sealed synthetic environment.",
                        progress: progress
                    )
                    let wrapped = output.contains("```") ? output : "```\n\(output)\n```"
                    return PromptExperimentGEPAHostReply(
                        ok: true,
                        output: wrapped,
                        score: nil,
                        feedback: nil,
                        failureKind: nil,
                        error: nil,
                        elapsedSeconds: nil
                    )
                case "evaluate":
                    guard let candidate = payload["candidate"] as? String,
                          let example = payload["example"] as? [String: Any]
                    else { throw PromptExperimentAuthorityError.runtimeUnavailable("GEPA supplied an invalid evaluation request.") }
                    return try await evaluate(
                        candidate: candidate,
                        example: example,
                        parentRequest: parentRequest,
                        specification: specification,
                        targets: targets,
                        progress: progress
                    )
                default:
                    throw PromptExperimentAuthorityError.runtimeUnavailable("Unsupported GEPA host operation: \(operation)")
                }
            } catch {
                return infrastructureReply(error.localizedDescription)
            }
        }

        private func evaluate(
            candidate: String,
            example: [String: Any],
            parentRequest: PromptExperimentRunRequest,
            specification: PromptExperimentOptimizationSpecification,
            targets: PromptExperimentOptimizationTargets,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async throws -> PromptExperimentGEPAHostReply {
            let started = Date()
            if specification.evaluator.kind == .sandboxedCommand {
                return try await evaluateSandboxedCommand(
                    candidate: candidate,
                    example: example,
                    request: parentRequest,
                    specification: specification,
                    started: started
                )
            }
            guard let executionTarget = targets.execution else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The sealed execution target is unavailable.")
            }
            let input = example["input"] as? String ?? ""
            await progress("Evaluating a GEPA candidate through Context Builder on reviewed example \(example["id"] as? String ?? "unknown").")
            let output = try await invokeContextBuilder(
                parentRequest: parentRequest,
                target: executionTarget,
                taskInput: input,
                instructions: """
                \(specification.execution.instructions)

                Candidate instructions (immutable for this evaluation):
                \(candidate)
                """,
                progress: progress
            )
            let elapsed = Date().timeIntervalSince(started)
            switch specification.evaluator.kind {
            case .exactMatch:
                let expected = example["expected_output"] as? String ?? ""
                let matched = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    == expected.trimmingCharacters(in: .whitespacesAndNewlines)
                let score = matched ? specification.evaluator.maximumScore : specification.evaluator.minimumScore
                let feedback = matched
                    ? "Output matched the reviewed expected output. Preserve this behavior."
                    : "Expected:\n\(expected)\nActual:\n\(output)\nRevise the candidate to close this concrete gap without memorizing the example."
                return PromptExperimentGEPAHostReply(
                    ok: true,
                    output: output,
                    score: score,
                    feedback: feedback,
                    failureKind: nil,
                    error: nil,
                    elapsedSeconds: elapsed
                )
            case .connectedModelJudge:
                guard let judge = targets.judge else {
                    throw PromptExperimentAuthorityError.runtimeUnavailable("The sealed judge target is unavailable.")
                }
                let expected = example["expected_output"] as? String ?? "unavailable"
                let judgePrompt = """
                Evaluate the candidate run using the immutable rubric below. Return only JSON with numeric `score` and string `feedback`.
                Score range: \(specification.evaluator.minimumScore)...\(specification.evaluator.maximumScore)
                Rubric:\n\(specification.evaluator.rubric)
                Input:\n\(input)
                Reviewed expected output (may be unavailable):\n\(expected)
                Actual output:\n\(output)
                """
                let rawJudgment = try await invokeContextBuilder(
                    parentRequest: parentRequest,
                    target: judge,
                    taskInput: judgePrompt,
                    instructions: "Return only the requested evaluator JSON. Do not propose or reveal hidden examples.",
                    progress: progress
                )
                let object = try parseJSONObject(rawJudgment)
                guard let score = (object["score"] as? NSNumber)?.doubleValue,
                      score >= specification.evaluator.minimumScore,
                      score <= specification.evaluator.maximumScore,
                      let feedback = object["feedback"] as? String
                else {
                    throw PromptExperimentAuthorityError.runtimeUnavailable("The connected-model evaluator returned invalid score JSON.")
                }
                return PromptExperimentGEPAHostReply(
                    ok: true,
                    output: output,
                    score: score,
                    feedback: feedback,
                    failureKind: nil,
                    error: nil,
                    elapsedSeconds: elapsed
                )
            case .sandboxedCommand:
                fatalError("handled above")
            }
        }

        private func invokeContextBuilder(
            parentRequest: PromptExperimentRunRequest,
            target: PromptExperimentResolvedTarget,
            taskInput: String,
            instructions: String,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async throws -> String {
            let date = Date()
            let childDraft = PromptExperimentDraft(
                revision: parentRequest.plan.revision,
                title: "GEPA host callback",
                taskInput: taskInput,
                syntheticFixture: "Sealed evaluation dataset; see fixture inventory.",
                originalInstructions: "GEPA host callback baseline (not executed).",
                candidateInstructions: instructions,
                targetRole: target.selector,
                repetitions: 1,
                createdAt: date,
                updatedAt: date
            )
            let childPlan = try PromptExperimentPlan.seal(
                draft: childDraft,
                target: target,
                environment: parentRequest.plan.environment,
                at: date
            )
            guard let trial = childPlan.trials.first(where: { $0.condition == .candidate }) else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("Could not construct the Context Builder callback trial.")
            }
            let childAttempt = PromptExperimentAttempt(trial: trial, plan: childPlan)
            let childRequest = PromptExperimentRunRequest(
                experimentID: parentRequest.experimentID,
                controllerSessionID: parentRequest.controllerSessionID,
                plan: childPlan,
                attempt: childAttempt
            )
            let handle = try await submit(childRequest, progress: progress)
            optimizationChildren[parentRequest.attempt.id, default: []].append(handle)
            if cancelledOptimizationIDs.contains(parentRequest.attempt.id) {
                _ = await cancel(handle)
                _ = await wait(for: handle)
                throw CancellationError()
            }
            let result = await wait(for: handle)
            optimizationChildren[parentRequest.attempt.id]?.removeAll { $0.id == handle.id }
            switch result.disposition {
            case .completed:
                guard let prompt = result.committedHandoff?.prompt else {
                    throw PromptExperimentAuthorityError.runtimeUnavailable(result.handoffUnavailableReason ?? "Context Builder callback committed no output.")
                }
                return prompt
            case let .failed(message):
                throw PromptExperimentAuthorityError.runtimeUnavailable("Context Builder callback failed: \(message)")
            case .cancelled:
                throw CancellationError()
            }
        }

        private func evaluateSandboxedCommand(
            candidate: String,
            example: [String: Any],
            request: PromptExperimentRunRequest,
            specification: PromptExperimentOptimizationSpecification,
            started: Date
        ) async throws -> PromptExperimentGEPAHostReply {
            guard let command = specification.evaluator.command,
                  let fileName = specification.evaluator.candidateFileName,
                  fileName == URL(fileURLWithPath: fileName).lastPathComponent,
                  !fileName.contains("..")
            else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The sealed candidate file name is unsafe.")
            }
            let workspace = PromptExperimentStore.liveRootURL()
                .appendingPathComponent("command-runs", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data(candidate.utf8).write(to: workspace.appendingPathComponent(fileName), options: [.atomic])
            let exampleData = try JSONSerialization.data(withJSONObject: example, options: [.prettyPrinted, .sortedKeys])
            try exampleData.write(to: workspace.appendingPathComponent("example.json"), options: [.atomic])
            let escaped = workspace.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let profile = """
            (version 1)
            (deny default)
            (allow process*)
            (allow sysctl-read)
            (allow mach-lookup)
            (allow file-read* (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/Library") (subpath "\(escaped)"))
            (allow file-write* (subpath "\(escaped)"))
            """
            let runner = CLIProcessRunner(config: CLIProcessConfiguration(
                command: "/usr/bin/sandbox-exec",
                workingDirectory: workspace.path,
                environment: ["HOME": workspace.path, "TMPDIR": workspace.path],
                captureStdoutTailBytes: 1024 * 1024,
                captureStderrTailBytes: 1024 * 1024
            ))
            let result = try await runner.run(
                args: ["-p", profile, "/bin/zsh", "-lc", command],
                stdin: nil,
                outputMode: .none,
                timeout: min(300, TimeInterval(specification.gepa.maxWallClockSeconds)),
                cancelChildOnTaskCancellation: true
            )
            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            if result.timedOut || result.status != 0 {
                let message = result.timedOut
                    ? "Candidate command exceeded its sealed per-evaluation timeout."
                    : "Candidate command exited \(result.status).\n\(stderr)"
                return PromptExperimentGEPAHostReply(
                    ok: false,
                    output: stdout,
                    score: specification.evaluator.minimumScore,
                    feedback: message,
                    failureKind: .candidate,
                    error: message,
                    elapsedSeconds: Date().timeIntervalSince(started)
                )
            }
            let object = try parseJSONObject(stdout)
            guard let score = (object["score"] as? NSNumber)?.doubleValue,
                  score >= specification.evaluator.minimumScore,
                  score <= specification.evaluator.maximumScore,
                  let feedback = object["feedback"] as? String
            else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The sealed command evaluator did not return valid score/feedback JSON.")
            }
            return PromptExperimentGEPAHostReply(
                ok: true,
                output: stdout,
                score: score,
                feedback: feedback,
                failureKind: nil,
                error: nil,
                elapsedSeconds: Date().timeIntervalSince(started)
            )
        }

        private func parseJSONObject(_ raw: String) throws -> [String: Any] {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("```"), let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
                if let fence = text.range(of: "```", options: .backwards) {
                    text.removeSubrange(fence.lowerBound...)
                }
            }
            guard let data = text.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("Evaluator output is not a JSON object.")
            }
            return object
        }

        private func infrastructureReply(_ message: String) -> PromptExperimentGEPAHostReply {
            PromptExperimentGEPAHostReply(
                ok: false,
                output: nil,
                score: nil,
                feedback: nil,
                failureKind: .infrastructure,
                error: message,
                elapsedSeconds: nil
            )
        }

        func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult {
            if let optimization = runningOptimizations[handle.id] {
                let result = await optimization.task.value
                runningOptimizations.removeValue(forKey: handle.id)
                optimizationChildren.removeValue(forKey: handle.id)
                cancelledOptimizationIDs.remove(handle.id)
                return result
            }
            guard let attempt = running[handle.id] else {
                return PromptExperimentRuntimeResult(
                    disposition: .failed("The accepted runtime attempt is no longer registered."),
                    runtimeLink: PromptExperimentRuntimeLink(
                        adapter: PromptExperimentPlan.executionAdapter,
                        tabID: handle.tabID,
                        runID: handle.runID,
                        provider: nil,
                        model: nil
                    ),
                    committedHandoff: nil,
                    assistantOutput: nil,
                    handoffUnavailableReason: "The accepted runtime attempt was no longer registered; committed handoff is unavailable.",
                    fixtureDigestBefore: "unavailable",
                    fixtureDigestAfter: nil
                )
            }
            let result = await attempt.task.value
            running.removeValue(forKey: handle.id)
            return result
        }

        func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation {
            if let optimization = runningOptimizations[handle.id] {
                cancelledOptimizationIDs.insert(handle.id)
                await cancelAndDrainOptimizationChildren(parentID: handle.id)
                optimization.worker.cancel()
                optimization.task.cancel()
                return .requested
            }
            guard let attempt = running[handle.id] else { return .alreadySettled }
            attempt.task.cancel()
            guard let windowState else {
                return .remoteStateUnknown("The bound Agent window closed before cancellation settled.")
            }
            await windowState.contextBuilderAgentViewModel.cancelMCPContextBuilderRun(forTabID: attempt.tabID)
            return .requested
        }

        private func cancelAndDrainOptimizationChildren(parentID: UUID) async {
            let children = optimizationChildren[parentID, default: []]
            for child in children {
                _ = await cancel(child)
                _ = await wait(for: child)
            }
            optimizationChildren[parentID] = []
        }

        static func runtimeResult(
            completion: ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion,
            fallbackProvider: String,
            fallbackModel: String,
            fixtureDigestBefore: String,
            fixtureDigestAfter: String?
        ) -> PromptExperimentRuntimeResult {
            let committedHandoff: PromptExperimentRuntimeHandoff?
            let unavailableReason: String?
            if let committed = completion.committedTab {
                let overrides = committed.tab.contextOverrides
                let prompt = overrides.useOverridePrompt
                    ? overrides.overridePromptText
                    : committed.tab.promptText
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    committedHandoff = nil
                    unavailableReason = "Context Builder committed a tab without a non-empty effective prompt handoff."
                } else {
                    committedHandoff = PromptExperimentRuntimeHandoff(
                        prompt: prompt,
                        selection: committed.tab.selection,
                        selectionRevision: committed.selectionRevision,
                        usedAgentOutputAsPrompt: committed.usedAgentOutputAsPrompt
                    )
                    unavailableReason = nil
                }
            } else {
                committedHandoff = nil
                unavailableReason = "Context Builder did not return its terminal committed-tab handoff snapshot."
            }

            var disposition: PromptExperimentRuntimeDisposition = switch completion.terminalDisposition {
            case .completed:
                .completed
            case .cancelled:
                .cancelled
            case let .failed(message):
                .failed(message)
            }
            if case .completed = disposition, committedHandoff == nil {
                disposition = .failed(unavailableReason ?? "Committed handoff is unavailable.")
            }

            return PromptExperimentRuntimeResult(
                disposition: disposition,
                runtimeLink: PromptExperimentRuntimeLink(
                    adapter: PromptExperimentPlan.executionAdapter,
                    tabID: completion.tabID,
                    runID: completion.runID,
                    provider: completion.agentKind?.rawValue ?? fallbackProvider,
                    model: completion.modelRaw ?? fallbackModel
                ),
                committedHandoff: committedHandoff,
                assistantOutput: completion.agentOutput,
                handoffUnavailableReason: unavailableReason,
                fixtureDigestBefore: fixtureDigestBefore,
                fixtureDigestAfter: fixtureDigestAfter
            )
        }

        private func verifyEnvironment(_ environment: PromptExperimentEnvironment) throws -> String {
            let root = URL(fileURLWithPath: environment.isolatedRootPath).standardizedFileURL
            let resolvedRoot = root.resolvingSymlinksInPath()
            let liveEnvironmentsRoot = PromptExperimentStore.liveRootURL()
                .appendingPathComponent("environments", isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolvedRoot.path.hasPrefix(liveEnvironmentsRoot.path + "/"),
                  try (root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
            else {
                throw PromptExperimentAuthorityError.environmentUnavailable("The synthetic root is outside app-owned experiment storage or is a symbolic link.")
            }
            let expectedPaths = Set(environment.fixtureFiles.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else {
                throw PromptExperimentAuthorityError.environmentUnavailable("The synthetic fixture root is unavailable.")
            }
            var observedPaths = Set<String>()
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true,
                      values.isRegularFile == true,
                      values.isDirectory != true,
                      url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot.path + "/")
                else {
                    throw PromptExperimentAuthorityError.environmentUnavailable("Synthetic fixture roots cannot contain directories, symbolic links, or non-file entries.")
                }
                observedPaths.insert(url.standardizedFileURL.path)
            }
            guard observedPaths == expectedPaths else {
                throw PromptExperimentAuthorityError.environmentUnavailable("Synthetic fixture contents differ from the sealed file inventory.")
            }
            for fixture in environment.fixtureFiles {
                let data = try Data(contentsOf: URL(fileURLWithPath: fixture.path), options: [.mappedIfSafe])
                guard data.count == fixture.byteCount,
                      PromptExperimentDigest.sha256(data) == fixture.sha256
                else {
                    throw PromptExperimentAuthorityError.environmentUnavailable("Synthetic fixture digest verification failed.")
                }
            }
            let inventoryDigest = environment.fixtureFiles.first?.sha256 ?? ""
            guard inventoryDigest == environment.fixtureDigest else {
                throw PromptExperimentAuthorityError.environmentUnavailable("Synthetic environment digest does not match the sealed plan.")
            }
            return inventoryDigest
        }

        private func cleanup(
            workspaceID: UUID,
            tabID: UUID,
            rootID: UUID,
            controlToken: UUID
        ) async {
            guard let windowState else { return }
            windowState.contextBuilderAgentViewModel.clearMCPControlledRun(
                forTabID: tabID,
                controlToken: controlToken
            )
            windowState.workspaceManager.workspaces.removeAll { $0.id == workspaceID && $0.ephemeralFlag == true }
            await windowState.workspaceFileContextStore.unloadRoot(id: rootID)
        }

        private func cleanupBeforeControl(workspaceID: UUID, rootID: UUID) async {
            guard let windowState else { return }
            windowState.workspaceManager.workspaces.removeAll { $0.id == workspaceID && $0.ephemeralFlag == true }
            await windowState.workspaceFileContextStore.unloadRoot(id: rootID)
        }
    }
#endif
