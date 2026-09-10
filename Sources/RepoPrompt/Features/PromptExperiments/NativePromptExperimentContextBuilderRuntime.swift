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

        private weak var windowState: WindowState?
        private var running: [UUID: RunningAttempt] = [:]

        init(windowState: WindowState) {
            self.windowState = windowState
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
            guard plan.executionAdapter == PromptExperimentPlan.executionAdapter,
                  plan.verifiesIntegrity(),
                  plan.environment.fixtureFiles.count == 1
            else {
                throw PromptExperimentSubmissionError.rejected("The sealed plan or synthetic environment is invalid.")
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
                        let afterDigest = try? verifyEnvironment(plan.environment)
                        let disposition: PromptExperimentRuntimeDisposition = switch completion.terminalDisposition {
                        case .completed:
                            .completed
                        case .cancelled:
                            .cancelled
                        case let .failed(message):
                            .failed(message)
                        }
                        result = PromptExperimentRuntimeResult(
                            disposition: disposition,
                            runtimeLink: PromptExperimentRuntimeLink(
                                adapter: PromptExperimentPlan.executionAdapter,
                                tabID: completion.tabID,
                                runID: completion.runID,
                                provider: completion.agentKind?.rawValue ?? plan.resolvedTarget.agentRaw,
                                model: completion.modelRaw ?? plan.resolvedTarget.modelRaw
                            ),
                            output: completion.agentOutput,
                            fixtureDigestBefore: beforeDigest,
                            fixtureDigestAfter: afterDigest
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
                            output: nil,
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
                            output: nil,
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

        func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult {
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
                    output: nil,
                    fixtureDigestBefore: "unavailable",
                    fixtureDigestAfter: nil
                )
            }
            let result = await attempt.task.value
            running.removeValue(forKey: handle.id)
            return result
        }

        func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation {
            guard let attempt = running[handle.id] else { return .alreadySettled }
            attempt.task.cancel()
            guard let windowState else {
                return .remoteStateUnknown("The bound Agent window closed before cancellation settled.")
            }
            await windowState.contextBuilderAgentViewModel.cancelMCPContextBuilderRun(forTabID: attempt.tabID)
            return .requested
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
