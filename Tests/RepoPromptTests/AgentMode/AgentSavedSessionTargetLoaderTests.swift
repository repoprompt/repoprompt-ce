import Foundation
import MCP
import RepoPromptACPProviders
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptMCPServer
import RepoPromptSettingsCore
import XCTest

private actor SavedHostListenerProbe {
    private(set) var startCount = 0
    func start() {
        startCount += 1
    }
}

@MainActor
final class AgentSavedSessionTargetLoaderTests: XCTestCase {
    func testExactDiskLookupNeedsNoWindowAndDoesNotChangeTheVisibleCarrier() async throws {
        let service = AgentSessionDataService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedID = UUID()
        let tab = ComposeTabState(activeAgentSessionID: UUID())
        var workspace = WorkspaceModel(name: "Saved target", repoPaths: [], customStoragePath: directory)
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        let file = try await service.saveAgentSession(AgentSession(
            id: savedID, workspaceID: workspace.id, composeTabID: tab.id,
            name: "Historical target", itemCount: 0
        ), for: workspace)
        let before = try Data(contentsOf: file)
        var reads = 0
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: savedID, workspaces: [workspace],
            readRecord: { id, candidate in
                reads += 1
                return try await service.metadataRecordForSessionID(id, for: candidate)
            },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        let target = try result.get()
        XCTAssertEqual(target.entry.id, savedID)
        XCTAssertEqual(target.entry.tabID, tab.id)
        XCTAssertEqual(target.tab.activeAgentSessionID, tab.activeAgentSessionID)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try Data(contentsOf: file), before, "Metadata lookup must not rewrite the payload.")
    }

    func testReadResamplesLiveEvidenceAndAuthoritativeRuntimeDoesNotNeedDisk() async throws {
        let id = UUID(), tab = ComposeTabState()
        var workspace = WorkspaceModel(name: "Live", repoPaths: [])
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        var live = AgentSavedSessionTargetLoader.LiveMetadata(entry: entry(id, tab.id, name: "Before"), isAuthoritative: false)
        var reads = 0
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in
                reads += 1
                live = .init(entry: self.entry(id, tab.id, name: "After"), isAuthoritative: true)
                return nil
            },
            currentMetadata: { _ in live }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { $0.entry.name == "After" }
        )
        XCTAssertEqual(try result.get().entry.name, "After")
        let second = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in reads += 1
                throw CocoaError(.fileReadNoPermission)
            },
            currentMetadata: { _ in live }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        XCTAssertEqual(try second.get().entry.name, "After")
        XCTAssertEqual(reads, 1, "Known live state remains usable when persistence is unavailable.")
    }

    func testDeletionAndEarlierMatchInvalidationDuringReadsFailClosed() async {
        let id = UUID(), tab = ComposeTabState()
        var first = WorkspaceModel(name: "First", repoPaths: [])
        first.composeTabs = [tab]
        first.stashedTabs = []
        let later = WorkspaceModel(name: "Later", repoPaths: [])
        var available = true
        let deleted = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [first],
            readRecord: { _, _ in available = false
                return nil
            },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in first }, isAvailable: { available }, isCurrent: { _ in true }
        )
        assertFailure(deleted, .changed)

        var firstIsCurrent = true
        let moved = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [first, later],
            readRecord: { _, _ in firstIsCurrent = false
                return nil
            },
            currentMetadata: { workspaceID in
                workspaceID == first.id ? .init(entry: self.entry(id, tab.id), isAuthoritative: true) : nil
            },
            currentWorkspace: { $0 == first.id ? first : later },
            isAvailable: { true }, isCurrent: { _ in firstIsCurrent }
        )
        assertFailure(moved, .changed)
    }

    func testDistinctMissingAmbiguousAndUnreadableOutcomes() async {
        let id = UUID(), tab = ComposeTabState()
        var workspace = WorkspaceModel(name: "Outcomes", repoPaths: [])
        workspace.composeTabs = [tab]
        workspace.stashedTabs = []
        let missing = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in nil },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(missing, .missing)
        let unreadable = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(unreadable, .unreadable)
        workspace.composeTabs.append(tab)
        let ambiguous = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace], readRecord: { _, _ in XCTFail("Live target does not need IO")
                return nil
            },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: true) },
            currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(ambiguous, .ambiguous)
    }

    func testFreshStashedPlacementIsUsedAfterRead() async throws {
        let id = UUID(), tab = ComposeTabState()
        let stash = StashedTab(tab: tab)
        var workspace = WorkspaceModel(name: "Moving", repoPaths: [], composeTabs: [tab])
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace],
            readRecord: { _, _ in
                workspace.composeTabs = []
                workspace.stashedTabs = [stash]
                return nil
            },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: false) },
            currentWorkspace: { _ in workspace }, isAvailable: { true }, isCurrent: { _ in true }
        )
        XCTAssertEqual(try result.get().stashedTabID, stash.id)
        XCTAssertEqual(try result.get().workspace.stashedTabs, [stash])
    }

    func testDiskIdentityMismatchAndTwoWorkspaceMatchesAreAmbiguous() async throws {
        let service = AgentSessionDataService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), tab = ComposeTabState()
        let workspace = WorkspaceModel(name: "Original", repoPaths: [], customStoragePath: directory, composeTabs: [tab])
        _ = try await service.saveAgentSession(AgentSession(
            id: id, workspaceID: workspace.id, composeTabID: tab.id, name: "Disk", itemCount: 0
        ), for: workspace)
        let loadedRecord = try await service.metadataRecordForSessionID(id, for: workspace)
        let record = try XCTUnwrap(loadedRecord)
        let other = WorkspaceModel(name: "Other", repoPaths: [], composeTabs: [tab])
        for (requestedID, candidate) in [(UUID(), workspace), (id, other)] {
            let result = await AgentSavedSessionTargetLoader.load(
                sessionID: requestedID, workspaces: [candidate], readRecord: { _, _ in record },
                currentMetadata: { _ in nil }, currentWorkspace: { _ in candidate },
                isAvailable: { true }, isCurrent: { _ in true }
            )
            assertFailure(result, .ambiguous)
        }
        let duplicated = await AgentSavedSessionTargetLoader.load(
            sessionID: id, workspaces: [workspace, other], readRecord: { _, _ in nil },
            currentMetadata: { _ in .init(entry: self.entry(id, tab.id), isAuthoritative: true) },
            currentWorkspace: { $0 == workspace.id ? workspace : other }, isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(duplicated, .ambiguous)
    }

    func testCancellationDuringReadIsChangedNotUnreadable() async {
        let workspace = WorkspaceModel(name: "Cancelled", repoPaths: [])
        let result = await AgentSavedSessionTargetLoader.load(
            sessionID: UUID(), workspaces: [workspace], readRecord: { _, _ in throw CancellationError() },
            currentMetadata: { _ in nil }, currentWorkspace: { _ in workspace },
            isAvailable: { true }, isCurrent: { _ in true }
        )
        assertFailure(result, .changed)
    }

    private func entry(_ id: UUID, _ tabID: UUID, name: String = "Target") -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id, tabID: tabID, name: name, savedAt: .distantPast,
            itemCount: 0, autoEditEnabled: false, hasUnknownConversationContent: false,
            isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
        )
    }

    private func assertFailure(
        _ result: Result<AgentSavedSessionTargetLoader.Target, AgentSavedSessionTargetLoader.Failure>,
        _ expected: AgentSavedSessionTargetLoader.Failure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .failure(actual) = result else { return XCTFail("Expected \(expected)", file: file, line: line) }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

@MainActor
final class AgentSavedSessionRuntimeLoadingTests: XCTestCase {
    func testProductionSavedTargetRunsProviderAndRegisteredToolsAndPersistsWithoutWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedHost-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let git = try ReviewGitRepositoryFixture(name: "SavedHost", parentDirectory: directory)
        let root = try git.makeRepository(named: "repo", files: ["Witness.swift": "func savedHostNeedle() -> Int { 42 }\n"])
        let file = root.appendingPathComponent("Witness.swift")
        let script = try AgentSessionLinkACPServerScript.write(to: directory)
        let assistantText = "The saved host completed this controlled turn."
        let preferences = GlobalSettingsStore.shared
        let previousAutoStart = preferences.mcpAutoStart()
        preferences.setMCPAutoStart(false, commit: false)
        defer { preferences.setMCPAutoStart(previousAutoStart, commit: false) }
        let listener = SavedHostListenerProbe()
        let transport = MCPService(
            controller: ServerController(), hostBootstrapOperation: {},
            controllerStartOperation: { await listener.start() }, controllerFullShutdownOperation: {}
        )
        addTeardownBlock { await transport.fullShutdown() }
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: .openCode, commandPath: script.path, environment: ["ACP_ASSISTANT_TEXT_ON_PROMPT": assistantText]
        )
        provider.usesDefaultNormalizer = true
        let keys = KeyManager()
        let settings = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false)
        settings.isOpenCodeConnected = true
        let providerEnvironment = AppSavedAgentSessionExecution.ProviderEnvironment(resources: .init(
            headless: { _, _ in preconditionFailure("The saved target must use its restored ACP provider") },
            acp: { _, _ in provider }, controller: {
                try ACPAgentSessionController(provider: $0, runRequest: $1, allowsProviderProcessLaunchForTesting: true)
            }
        ), settings: settings, mcpTransport: transport)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: "saved-host-\(UUID())", storageDirectory: directory,
            workspaceStorageDirectory: directory.appendingPathComponent("workspaces"),
            eventDirectory: directory.appendingPathComponent("events"), temporaryDirectory: directory.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        do {
            try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) {
                let fixture = Fixture()
                defer { fixture.cleanUp() }
                let visible = ComposeTabState(activeAgentSessionID: UUID())
                let stash = StashedTab(tab: fixture.tab)
                fixture.placement.workspace.composeTabs = [visible]
                fixture.placement.workspace.stashedTabs = [stash]
                fixture.placement.workspace.repoPaths = [root.path]
                let workspace = fixture.placement.workspace
                let authority = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: 101)
                let created = try await authority.create(workspace, fileURL: fixture.root.appendingPathComponent("saved.json"))
                XCTAssertEqual(created.disposition, .applied)
                try await fixture.save(agentKind: "openCode", agentModel: "model-a")

                let windows = WindowStatesManager.shared
                let count = WindowState.windowCounter
                let promptCount = PromptViewModel.constructionCountForTesting
                let workspaceCount = WorkspaceManagerViewModel.constructionCountForTesting
                windows.beginPreparedOversightPreparation(fixture.sessionID)
                var holdingPreparation = true
                defer { if holdingPreparation { windows.endPreparedOversightPreparation(fixture.sessionID) } }
                let loaded = await windows.prepareSavedOversightTarget(fixture.sessionID, providerEnvironment: providerEnvironment, isStillAuthorized: { true })
                let writer = try loaded.get()
                let host = try XCTUnwrap(writer.scope.executableHost)
                do {
                    XCTAssertEqual(writer.session.tabID, stash.tab.id)
                    XCTAssertEqual(writer.session.items.map(\.text), ["Saved request", "Saved response"])
                    XCTAssertEqual(host.route.identity.kind, .independent)
                    XCTAssertNotNil(host.scope.execution)
                    XCTAssertNotNil(host.scope.linkExecution)
                    let registered = await host.route.hasActiveCatalog()
                    XCTAssertTrue(registered)
                    let reused = try await windows.prepareSavedOversightTarget(fixture.sessionID, isStillAuthorized: { true }).get()
                    XCTAssertEqual(reused.identity, writer.identity)
                    XCTAssertTrue(reused.scope.executableHost === host)
                    XCTAssertEqual(writer.session.selectedAgent, .openCode)
                    let startsBeforeRun = await listener.startCount
                    XCTAssertEqual(startsBeforeRun, 0, "Catalog registration and saved hydration do not start the listener")
                    let message = "Continue the original saved chat"
                    let start = AgentRunStartOutcomeRecorder()
                    let command = try writer.admitCommand().get()
                    _ = await host.startCanonicalRequest(command: command, message: message, options: .init(skipsSlashExpansion: true), outcome: start)
                    XCTAssertTrue(start.outcome.didStart)
                    XCTAssertFalse(writer.scope.isRetiring)
                    let receipt = try await originatingPolicyReceipt(for: writer.session)
                    let startsOnRun = await listener.startCount
                    XCTAssertEqual(startsOnRun, 1, "First provider bootstrap brings up its exact registered transport")
                    let stillReady = await host.route.ensureHostProviderTransport()
                    XCTAssertTrue(stillReady)
                    let startsOnReuse = await listener.startCount
                    XCTAssertEqual(startsOnReuse, 1, "Another request joins the same listener")
                    XCTAssertFalse(preferences.mcpAutoStart(), "Demand-driven bootstrap must not modify Auto Start")
                    let connectionID = UUID()
                    let installation = await host.route.installPendingPolicy(receipt, connectionID: connectionID, clientName: nil, tabID: stash.tab.id)
                    let token = try XCTUnwrap(installation?.token)
                    let bindingIsCurrent = await host.route.canCommitPendingPolicy(receipt, token: token)
                    XCTAssertTrue(bindingIsCurrent, "Handshake must accept the exact saved binding before dispatch")
                    let metadata = MCPRequestMetadata(connectionID: connectionID, clientName: nil, windowID: host.routeID)
                    let registration = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
                    func invoke(_ name: String, _ arguments: [String: Value], grantingAccess: Bool = true) async throws -> Value {
                        let resolution = try await runtime.domainHost.resolve(toolName: name, scope: .window(id: host.routeID))
                        let invocationID = UUID()
                        let security = DomainToolInvocationSecurityContext(
                            principal: .init(
                                principalID: UUID(), stableKey: "saved-route-witness", displayName: "Scripted provider",
                                kind: .runScoped, assurance: grantingAccess ? .hostLaunchToken : .displayNameOnly, processID: nil, runID: receipt.runID,
                                provider: "openCode", verifiedIdentityFingerprint: nil
                            ),
                            connectionID: connectionID, connectionGeneration: registration.generation, invocationID: invocationID,
                            runtimeID: runtime.identity.runtimeID, runtimeGeneration: runtime.identity.lifecycleGeneration,
                            workspaceID: workspace.id, authorizedCanonicalRoots: [root.path],
                            ephemeralGrantedToolNames: grantingAccess ? [name] : []
                        )
                        let request = ToolInvocationContext.trustedLocal(toolName: name, metadata: metadata)
                        return try await MCPInvocationContextBridge.withInvocation(request) {
                            try await runtime.domainHost.invoke(.init(
                                invocationID: invocationID, connectionID: connectionID, resolution: resolution,
                                arguments: arguments, securityContext: security
                            ))
                        }
                    }
                    await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                        connectionID: connectionID, runID: receipt.runID, purpose: .agentModeRun,
                        windowID: host.routeID, registration: receipt
                    )
                    let read = try await invoke("read_file", ["path": .string(file.path)])
                    XCTAssertTrue(read.objectValue?["content"]?.stringValue?.contains("savedHostNeedle") == true, "\(read)")
                    let autoSelected = try await invoke("get_file_tree", ["mode": .string("selected")])
                    XCTAssertTrue(autoSelected.objectValue?["tree"]?.stringValue?.contains("Witness.swift") == true, "\(autoSelected)")
                    let structure = try await invoke("get_code_structure", ["paths": .array([.string(file.path)])])
                    XCTAssertTrue(String(describing: structure).contains("Witness.swift"), "\(structure)")
                    let worktrees = try await invoke("manage_worktree", ["op": .string("list")])
                    XCTAssertEqual(worktrees.objectValue?["total_count"]?.intValue, 1, "\(worktrees)")
                    let history = try await invoke("history", [
                        "op": .string("list_sessions"), "workspace": .string(workspace.id.uuidString)
                    ])
                    XCTAssertTrue(String(describing: history).contains(fixture.sessionID.uuidString), "\(history)")
                    let searched = try await invoke("file_search", ["pattern": .string("savedHostNeedle"), "mode": .string("content")])
                    XCTAssertTrue(String(describing: searched).contains("Witness.swift"), "\(searched)")
                    _ = try await invoke("manage_selection", ["op": .string("clear")])
                    let select: [String: Value] = ["op": .string("SET"), "paths": .array([.string(file.path)])]
                    do {
                        _ = try await invoke("manage_selection", select, grantingAccess: false)
                        XCTFail("A route receipt is not permission to mutate selection")
                    } catch DomainMutationPolicyError.principalUnverified {
                        // The existing protected-mutation adapter must remain ahead of dispatch.
                    }
                    let selected = try await invoke("manage_selection", select)
                    XCTAssertEqual(selected.objectValue?["status"]?.stringValue, "ok")
                    let selectedTree = try await invoke("get_file_tree", ["mode": .string("selected")])
                    XCTAssertTrue(selectedTree.objectValue?["tree"]?.stringValue?.contains("Witness.swift") == true, "\(selectedTree)")
                    let linkRuntime = try XCTUnwrap(host.scope.linkExecution)
                    let endpoint = try XCTUnwrap(linkRuntime.agentSessionLinkObserverEndpoint(tabID: writer.session.tabID))
                    let candidate = try XCTUnwrap(windows.agentSessionLinkCandidate(for: endpoint, includeLocation: false))
                    let question = Task { @MainActor in
                        try await invoke("ask_user", ["question": .string("Continue the saved session?"), "timeout_seconds": .int(10)])
                    }
                    defer { question.cancel() }
                    try await AsyncTestWait.waitUntil("the registered question is pending on the exact saved writer") {
                        windows.agentSessionLinkPendingInteraction(for: candidate).interaction != nil
                    }
                    let interaction = try XCTUnwrap(windows.agentSessionLinkPendingInteraction(for: candidate).interaction)
                    let payload = try AgentRunMCPToolService.parseResponsePayload(args: ["answers": .object(["response": .string("Continue")])])
                    let wrong = await windows.agentSessionLinkRespondToPendingInteraction(
                        for: candidate, request: .init(interactionID: UUID(), payload: payload), authorize: { true }
                    )
                    XCTAssertEqual(wrong, .interactionMismatch(currentInteractionID: interaction.id))
                    let request = AgentSessionLinkInteractionResponseRequest(interactionID: interaction.id, payload: payload)
                    let denied = await windows.agentSessionLinkRespondToPendingInteraction(for: candidate, request: request, authorize: { false })
                    XCTAssertEqual(denied, .unavailable)
                    XCTAssertEqual(windows.agentSessionLinkPendingInteraction(for: candidate).interaction?.id, interaction.id)
                    let answered = await windows.agentSessionLinkRespondToPendingInteraction(for: candidate, request: request, authorize: { true })
                    XCTAssertEqual(answered, .submitted(kind: .question, decision: "answered"))
                    let response = try await question.value
                    XCTAssertTrue(String(describing: response).contains("Continue"), "\(response)")
                    XCTAssertNil(windows.agentSessionLinkPendingInteraction(for: candidate).interaction)
                    let editArgs: [String: Value] = [
                        "path": .string(file.path), "search": .string("{ 42 }"), "replace": .string("{ 43 }"),
                        "operation_id": .string("saved-host-edit-witness")
                    ]
                    do {
                        _ = try await invoke("apply_edits", editArgs, grantingAccess: false)
                        XCTFail("An unverified provider must not reach file mutation")
                    } catch DomainMutationPolicyError.principalUnverified {}
                    let interactions = try XCTUnwrap(host.scope.installedInteractions)
                    let scope = ApplyEditsApprovalScope(windowID: host.routeID, tabID: stash.tab.id)
                    await interactions.approvalStore.setAutoEditEnabled(false, for: scope, updateGlobalDefault: false)
                    let editing = Task { @MainActor in try await invoke("apply_edits", editArgs) }
                    defer { editing.cancel() }
                    try await AsyncTestWait.waitUntil("apply_edits awaits the originating writer's approval") {
                        writer.session.pendingApplyEditsReview != nil
                    }
                    XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("{ 42 }"))
                    let review = try XCTUnwrap(writer.session.pendingApplyEditsReview)
                    let applied = await interactions.submitApplyEditsReviewDecision(command: command, reviewID: review.id, decision: .accept)
                    XCTAssertTrue(applied)
                    let edited = try await editing.value
                    XCTAssertEqual(edited.objectValue?["edits_applied"]?.intValue, 1, "\(edited)")
                    XCTAssertEqual(edited.objectValue?["operation_id"]?.stringValue, "saved-host-edit-witness")
                    XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("{ 43 }"))
                    let status = try await invoke("git", ["op": .string("status")])
                    XCTAssertEqual(status.objectValue?["status"]?.objectValue?["branch"]?.stringValue, "main", "\(status)")
                    let diff = try await invoke("git", ["op": .string("diff"), "detail": .string("patches")])
                    XCTAssertTrue(String(describing: diff).contains("{ 43 }"), "\(diff)")
                    let published = try await invoke("git", ["op": .string("diff"), "artifacts": .bool(true), "scope": .string("selected")])
                    let primary = try XCTUnwrap(published.objectValue?["primary_artifacts"]?.objectValue, "\(published)")
                    let alias = try XCTUnwrap(primary["map"]?.stringValue)
                    XCTAssertTrue(primary["auto_selected"]?.arrayValue?.contains(.string(alias)) == true, "\(published)")
                    let removed = try await invoke("manage_selection", ["op": .string("remove"), "paths": .array([.string(alias)]), "strict": .bool(true)])
                    XCTAssertFalse(String(describing: removed).contains(alias), "\(removed)")
                    let repicked = try await invoke("manage_selection", ["op": .string("add"), "paths": .array([.string(alias)]), "strict": .bool(true)])
                    XCTAssertTrue(String(describing: repicked).contains(alias), "\(repicked)")
                    let artifact = try await invoke("read_file", ["path": .string(alias)])
                    XCTAssertTrue(artifact.objectValue?["content"]?.stringValue?.contains("Witness.swift") == true, "\(artifact)")
                    let models = try await invoke("agent_manage", ["op": .string("list_agents"), "roles_only": .bool(true)])
                    XCTAssertNotNil(models.objectValue)
                    let generation = try XCTUnwrap(receipt.routingWaitGeneration)
                    await MCPRoutingWaiter.notifyRouted(runID: receipt.runID, generation: generation)
                    await writer.session.agentTask?.value
                    XCTAssertEqual(provider.promptedMessages.count, 1)
                    XCTAssertTrue(provider.promptedMessages.first?.userMessage.contains(message) == true)
                    let parent = UUID()
                    let placement = try XCTUnwrap(SessionAdminWindowsStructureHost().commitOrganizationalPlacement(
                        sessionID: fixture.sessionID, parentID: parent, delegationScopeID: nil
                    ))
                    try await placement.persisted()
                    let persisted = try await fixture.service.loadAgentSession(id: fixture.sessionID, for: workspace)
                    XCTAssertEqual(persisted?.organizationalParentID, parent)
                    let transcript = try XCTUnwrap(persisted).workingSourceItems()
                    XCTAssertTrue(
                        transcript.contains(where: { $0.kind == .assistant && $0.text.contains(assistantText) }),
                        "The new provider output must be present in the durable canonical transcript"
                    )
                    let current = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspace.id)
                    let document = try XCTUnwrap(current?.document.documentBytes)
                    let unchanged = try JSONDecoder().decode(WorkspaceModel.self, from: document)
                    XCTAssertEqual(unchanged.composeTabs, [visible])
                    XCTAssertEqual(unchanged.stashedTabs, [stash])
                    XCTAssertEqual(WindowState.windowCounter, count)
                    XCTAssertEqual(PromptViewModel.constructionCountForTesting, promptCount)
                    XCTAssertEqual(WorkspaceManagerViewModel.constructionCountForTesting, workspaceCount)
                } catch {
                    let drain = host.beginFinalShutdown()
                    drain.startIfNeeded()
                    _ = await drain.wait(until: .now.advanced(by: .seconds(5)))
                    throw error
                }
                holdingPreparation = false
                windows.endPreparedOversightPreparation(fixture.sessionID)
                try await AsyncTestWait.waitUntil("ordinary saved-host completion retires its owner") {
                    writer.scope.hasReleasedWriterClaims && host.route.isClosing && writer.scope.retainedDrain == nil
                }
            }
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
        _ = await runtime.shutdown()
    }

    func testDurableDeletionReleasesFailedSavedHostDrainWithoutResumingVisit() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await CanonicalSavedWorkspaceFixture.run(fixture.placement.workspace) { workspace in
            let service = AgentSessionDataService.shared
            let file = try await service.saveAgentSession(.init(
                id: fixture.sessionID, workspaceID: workspace.id, composeTabID: fixture.tab.id, name: "Saved target"
            ), for: workspace)
            let original = try Data(contentsOf: file)
            let manager = WindowStatesManager.shared
            manager.attachAgentSessionLinkBridge()
            manager.beginPreparedOversightPreparation(fixture.sessionID)
            var holding = true
            @MainActor func releasePreparation() {
                guard holding else { return }
                holding = false
                manager.endPreparedOversightPreparation(fixture.sessionID)
            }
            defer { releasePreparation() }
            let writer = try await manager.prepareSavedOversightTarget(fixture.sessionID, isStillAuthorized: { true }).get()
            let host = try XCTUnwrap(writer.scope.executableHost)
            do {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                writer.session.organizationalParentID = UUID()
                writer.session.isDirty = true
                releasePreparation()
                try await AsyncTestWait.waitUntil("original saved host retains failed final save") {
                    if case .retained? = writer.scope.retainedDrain?.outcome { return true }
                    return false
                }
                let drain = try XCTUnwrap(writer.scope.retainedDrain)
                XCTAssertFalse(host.route.isClosing)
                manager.queuePreparedRuntimeVisit(fixture.sessionID) { XCTFail("A deleted transcript must not resume its visit") }
                try FileManager.default.removeItem(at: file)
                try original.write(to: file, options: .atomic)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                try await service.deleteAgentSession(id: fixture.sessionID, for: workspace)
                manager.schedulePreparedOversightCleanup()
                try await AsyncTestWait.waitUntil("physical deletion settles the original saved host") {
                    drain.outcome == .released && writer.scope.retainedDrain == nil && host.route.isClosing
                }
                XCTAssertTrue(writer.scope.hasReleasedWriterClaims)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Retirement must never recreate a deleted payload")
                XCTAssertTrue(AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: fixture.sessionID))
            } catch {
                releasePreparation()
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try? FileManager.default.removeItem(at: file)
                }
                let drain = host.beginFinalShutdown()
                drain.attemptRecovery()
                _ = await drain.wait(until: .now.advanced(by: .seconds(5)))
                throw error
            }
        }
    }

    private func originatingPolicyReceipt(for session: AgentTabSession) async throws -> MCPRunRoutingCleanupReceipt {
        var result: MCPRunRoutingCleanupReceipt?
        try await AsyncTestWait.waitUntil("saved host provider registered its originating route") {
            guard let runID = session.runID, let controller = session.acpController,
                  let host = await controller.hostForRoutingHandoff(expectedRunID: runID) as? ACPAgentSessionAppHost else { return false }
            result = host.test_originatingRoutingCleanupReceipt()
            return result != nil
        }
        return try XCTUnwrap(result)
    }

    func testExactColdWriterHydratesInPlaceAndCannotRebindDuringPayloadRead() async throws {
        for replace in [false, true] {
            let f = Fixture()
            defer { f.cleanUp() }
            try await f.save()
            let original = f.scope.makeSession(tabID: f.tab.id)
            let binding = AgentPersistentSessionBindingIdentity(tabID: f.tab.id, sessionID: f.sessionID, workspaceID: f.placement.workspace.id)
            original.installPersistentSessionBinding(binding)
            f.scope.replaceSessions([f.tab.id: original])
            guard case let .unique(writer) = f.scope.resolveWriter(sessionID: f.sessionID) else {
                return XCTFail("Must start with one exact cold writer")
            }
            XCTAssertTrue(AgentSavedSessionTargetLoader.canHydrateOriginalColdWriter(writer))
            let successor = f.scope.makeSession(tabID: f.tab.id)
            if replace {
                f.beforePayload = { _ in
                    successor.installPersistentSessionBinding(binding)
                    f.scope.replaceSessions([f.tab.id: successor])
                }
            }
            let result = await f.load(originalColdWriter: writer)
            if replace {
                assertFailure(result, reason: .lookup(.changed), effects: .loadingClaimDisplaced)
                XCTAssertTrue(f.scope.sessions[f.tab.id] === successor)
                XCTAssertFalse(successor.hasLoadedPersistedState)
                XCTAssertTrue(successor.items.isEmpty)
            } else {
                let restored = try result.get()
                XCTAssertEqual(restored.source, .existingWriter)
                XCTAssertEqual(restored.writer.identity, writer.identity)
                XCTAssertTrue(restored.writer.session === original)
                XCTAssertEqual(original.items.map(\.text), ["Saved request", "Saved response"])
            }
        }
    }

    func testSavedHistoricalPayloadLoadsIntoCanonicalWriterWithoutWindowComposition() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        let carrier = f.placement.workspace.composeTabs
        let result = try await f.load().get()
        XCTAssertEqual(result.source, .savedPayload)
        XCTAssertTrue(result.writer.scope === f.scope)
        XCTAssertTrue(result.writer.session.permitsBoundOperationAndSave)
        XCTAssertEqual(result.writer.session.items.map(\.text), ["Saved request", "Saved response"])
        XCTAssertEqual(f.placement.workspace.composeTabs, carrier, "Historical lookup must not select or rebind the visible carrier")
        XCTAssertNil(f.scope.execution, "Loading does not install a fake execution service")
        XCTAssertNil(f.scope.linkExecution)
        XCTAssertNil(f.scope.persistence.presentation)
        XCTAssertNil(f.scope.attachments.invalidatePreviews)
        XCTAssertNil(result.writer.session.activeRunOwnership)
        let second = try await f.load().get()
        XCTAssertEqual(second.source, .existingWriter)
        XCTAssertTrue(second.writer.session === result.writer.session)
        XCTAssertEqual(f.payloadReads, 1)
    }

    func testStashedHistoricalCarrierLoadsWithoutChangingPresentation() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let visible = ComposeTabState(activeAgentSessionID: UUID())
        let stash = StashedTab(tab: f.tab)
        f.placement.workspace.composeTabs = [visible]
        f.placement.workspace.stashedTabs = [stash]
        try await f.save()

        let result = try await f.load().get()
        XCTAssertEqual(result.writer.session.tabID, stash.tab.id)
        XCTAssertEqual(result.writer.identity.sessionID, f.sessionID)
        XCTAssertEqual(f.placement.workspace.composeTabs, [visible])
        XCTAssertEqual(f.placement.workspace.stashedTabs, [stash])
    }

    func testCanonicalCarrierRevalidationRechecksAuthorizationAfterAwait() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.validateCanonicalTarget = { target in
            await Task.yield()
            if f.payloadReads == 1 { f.authorized = false }
            return target.carrier(in: f.placement.workspace) != nil
        }
        await assertFailure(f.load(), reason: .lookup(.changed), effects: .loadingClaimReleased)
        XCTAssertEqual(f.payloadReads, 1)
        XCTAssertTrue(f.scope.sessions.isEmpty)
    }

    func testExistingForeignScopeIsReturnedWithoutComposingOrPopulatingColdScope() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        let original = try await f.load().get()
        let cold = f.store.makeScope()
        let reused = try await f.load(into: cold).get()
        XCTAssertEqual(reused.source, .existingWriter)
        XCTAssertTrue(reused.writer.scope === original.writer.scope)
        XCTAssertTrue(cold.sessions.isEmpty)
        XCTAssertNil(cold.persistence.composition)
        XCTAssertEqual(f.payloadReads, 1)
    }

    func testConflictingAndUnreadyWritersDoNotFallBackToSavedPayload() async {
        let f = Fixture()
        defer { f.cleanUp() }
        let first = f.scope.makeSession(tabID: f.tab.id)
        first.installPersistentSessionBinding(.init(tabID: first.tabID, sessionID: f.sessionID, workspaceID: f.placement.workspace.id))
        f.scope.replaceSessions([first.tabID: first])
        await assertFailure(f.load(), reason: .commandRejected(.restorationUnavailable), effects: .none)
        let otherScope = f.store.makeScope()
        let other = otherScope.makeSession(tabID: UUID())
        XCTAssertEqual(otherScope.bindingRejection(f.sessionID, on: other), .conflictingWriter)
        // Deliberate legacy corruption after proving normal binding admission refuses it.
        other.installPersistentSessionBinding(.init(tabID: other.tabID, sessionID: f.sessionID, workspaceID: f.placement.workspace.id))
        otherScope.replaceSessions([other.tabID: other])
        await assertFailure(f.load(), reason: .lookup(.ambiguous), effects: .none)
        XCTAssertEqual(f.payloadReads, 0)
        XCTAssertTrue(f.scope.sessions[first.tabID] === first)
        otherScope.replaceSessions([:])
    }

    func testPayloadFailureReleasesOnlyItsLoadingClaimAndExplicitRetryCanRestore() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.beforePayload = { _ in throw CocoaError(.fileReadCorruptFile) }
        await assertFailure(f.load(), reason: .lookup(.unreadable), effects: .loadingClaimReleased)
        XCTAssertTrue(f.scope.sessions.isEmpty)
        guard case .unavailable(.absent) = f.store.resolveWriter(sessionID: f.sessionID) else { return XCTFail("Failed clean load must not strand a writer") }
        f.beforePayload = nil
        let retried = try await f.load().get()
        XCTAssertTrue(retried.writer.session.permitsBoundOperationAndSave)
    }

    func testReacquiredLoadingClaimCannotBeHydratedOrReleasedByItsOldRead() async throws {
        for failsRead in [false, true] {
            let f = Fixture()
            defer { f.cleanUp() }
            try await f.save()
            var retained: AgentTabSession?
            f.beforePayload = { _ in
                let session = try XCTUnwrap(f.scope.sessions[f.tab.id])
                let transition = session.persistentBindingTransitionToken()
                f.scope.replaceSessions([:])
                f.scope.replaceSessions([session.tabID: session])
                XCTAssertTrue(transition.matches(session))
                retained = session
                if failsRead { throw CocoaError(.fileReadCorruptFile) }
            }
            await assertFailure(
                f.load(), reason: .lookup(failsRead ? .unreadable : .changed), effects: .loadingClaimRetained
            )
            let session = try XCTUnwrap(retained)
            XCTAssertTrue(f.scope.sessions[f.tab.id] === session)
            XCTAssertTrue(session.items.isEmpty)
            XCTAssertFalse(session.hasLoadedPersistedState)
            XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
        }
    }

    func testRevocationAndStorageMoveAfterReadCannotPublishReadiness() async throws {
        for moveStorage in [false, true] {
            let f = Fixture()
            defer { f.cleanUp() }
            try await f.save()
            f.afterPayload = {
                if moveStorage { f.placement.workspace.customStoragePath = f.root.appendingPathComponent("moved") }
                else { f.authorized = false }
            }
            await assertFailure(f.load(), reason: .lookup(.changed), effects: .loadingClaimReleased)
            XCTAssertTrue(f.scope.sessions.isEmpty)
        }
    }

    func testLocalMutationDuringPayloadReadIsRetainedWithHonestFailureEffect() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.afterPayload = {
            guard let session = f.scope.sessions[f.tab.id] else { return XCTFail("Loading claim missing") }
            session.setItemsSilently([.init(kind: .user, text: "New local input", sequenceIndex: 0)], reason: .persistedSessionHydration)
            session.isDirty = true
        }
        await assertFailure(f.load(), reason: .lookup(.changed), effects: .loadingClaimRetained)
        let retained = try XCTUnwrap(f.scope.sessions[f.tab.id])
        XCTAssertEqual(retained.items.map(\.text), ["New local input"])
        XCTAssertFalse(retained.permitsBoundOperationAndSave)
        XCTAssertTrue(retained.isDirty)
    }

    func testSuppressionAndOccupiedTabHaveNoLoadingSideEffects() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.placement.suppressed = true
        await assertFailure(f.load(), reason: .suppressed, effects: .none)
        f.placement.suppressed = false
        let draft = f.scope.makeSession(tabID: f.tab.id)
        f.scope.replaceSessions([draft.tabID: draft])
        await assertFailure(f.load(), reason: .occupiedTab, effects: .none)
        XCTAssertEqual(f.payloadReads, 0)
        XCTAssertTrue(f.scope.sessions[draft.tabID] === draft)
    }

    func testRetirementAndReplacementDuringReadCannotPublishOrEvictSuccessor() async throws {
        for replace in [false, true] {
            let f = Fixture()
            defer { f.cleanUp() }
            try await f.save()
            let successor = f.scope.makeSession(tabID: f.tab.id)
            f.afterPayload = {
                if replace { f.scope.replaceSessions([successor.tabID: successor]) }
                else { f.scope.beginRetirement() }
            }
            await assertFailure(f.load(), reason: .lookup(.changed), effects: replace ? .loadingClaimDisplaced : .loadingClaimReleased)
            if replace { XCTAssertTrue(f.scope.sessions[f.tab.id] === successor) }
            else { XCTAssertTrue(f.scope.sessions.isEmpty) }
        }
    }

    func testOldMetadataCannotOverwriteNewPayloadPlacement() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        let parent = UUID()
        f.beforePayload = { _ in
            let saved = try await f.service.loadAgentSession(id: f.sessionID, for: f.placement.workspace)
            var payload = try XCTUnwrap(saved)
            payload.organizationalParentID = parent
            _ = try await f.service.saveAgentSession(payload, for: f.placement.workspace)
        }
        let loaded = try await f.load().get()
        XCTAssertEqual(loaded.writer.session.organizationalParentID, parent)
    }

    func testMissingStorageCompositionRefusesBeforePublishingClaim() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        f.scope.persistence.composition = nil
        await assertFailure(f.load(), reason: .compositionUnavailable, effects: .none)
        XCTAssertTrue(f.scope.sessions.isEmpty)
        XCTAssertEqual(f.payloadReads, 0)
    }

    func testAttachmentStorageFollowsBoundCatalogRootWithoutPresentation() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        try await f.save()
        let configuration = try XCTUnwrap(f.scope.attachments.configuration)
        let draft = f.scope.makeSession(tabID: UUID())
        XCTAssertNotNil(configuration.location(draft), "An unbound first turn retains its canonical temporary location")
        let session = try await f.load().get().writer.session
        let captured = try XCTUnwrap(configuration.location(session))
        XCTAssertNotNil(captured.retainedRoot)
        let originalLocationIsCurrent = await configuration.locationIsCurrent(captured, session)
        XCTAssertTrue(originalLocationIsCurrent)
        f.placement.workspace.customStoragePath = f.root.appendingPathComponent("moved")
        let movedLocationIsCurrent = await configuration.locationIsCurrent(captured, session)
        XCTAssertFalse(movedLocationIsCurrent)
        f.placement.suppressed = true
        XCTAssertNil(configuration.location(session)?.retainedRoot)
    }

    private func assertFailure(
        _ result: Result<AgentSavedSessionTargetLoader.RuntimeLoad, AgentSavedSessionTargetLoader.RuntimeLoadFailure>,
        reason: AgentSavedSessionTargetLoader.RuntimeLoadFailure.Reason,
        effects: AgentSavedSessionTargetLoader.RuntimeLoadFailure.Effects,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .failure(failure) = result else { return XCTFail("Expected refusal", file: file, line: line) }
        XCTAssertEqual(failure.reason, reason, file: file, line: line)
        XCTAssertEqual(failure.effects, effects, file: file, line: line)
    }

    @MainActor
    private final class Placement {
        var workspace: WorkspaceModel
        var suppressed = false
        init(_ workspace: WorkspaceModel) {
            self.workspace = workspace
        }
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M93Loading-\(UUID())")
        let sessionID = UUID()
        let tab = ComposeTabState(activeAgentSessionID: UUID())
        let service = AgentSessionDataService()
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let placement: Placement
        let storage: AgentSessionStorageInputs
        var authorized = true
        var validateCanonicalTarget: ((AgentSavedSessionTargetLoader.Target) async -> Bool)?
        var payloadReads = 0
        var beforePayload: ((AgentSessionHydrationRequest) async throws -> Void)?
        var afterPayload: (() -> Void)?

        init() {
            var workspace = WorkspaceModel(name: "Canonical catalog", repoPaths: [], customStoragePath: root)
            workspace.composeTabs = [tab]
            workspace.stashedTabs = []
            placement = Placement(workspace)
            scope = store.makeScope()
            let placement = placement
            storage = .init(
                workspaceID: workspace.id,
                workspaceWithID: { $0 == placement.workspace.id ? placement.workspace : nil },
                displayName: { _ in "Saved target" }, isSuppressed: { placement.suppressed },
                attachmentWorkspaceDirectory: { FileManager.default.temporaryDirectory }
            )
            scope.persistence.composition = storage.persistenceComposition(scope: scope)
            scope.attachments.configuration = storage.attachmentConfiguration()
        }

        func save(agentKind: String? = nil, agentModel: String? = nil) async throws {
            _ = try await service.saveAgentSession(.init(
                id: sessionID, workspaceID: placement.workspace.id, composeTabID: tab.id, name: "Saved target",
                items: [
                    AgentChatItem(kind: .user, text: "Saved request", sequenceIndex: 0),
                    AgentChatItem(kind: .assistant, text: "Saved response", sequenceIndex: 1)
                ].map { AgentChatItemPersist(from: $0) },
                agentKind: agentKind, agentModel: agentModel, lastRunState: "completed"
            ), for: placement.workspace)
        }

        func load(
            into destination: AgentSessionRuntimeStore.Scope? = nil, originalColdWriter: AgentSessionRuntimeStore.Writer? = nil
        ) async -> Result<AgentSavedSessionTargetLoader.RuntimeLoad, AgentSavedSessionTargetLoader.RuntimeLoadFailure> {
            await AgentSavedSessionTargetLoader.loadRuntime(
                sessionID: sessionID, scope: destination ?? scope,
                catalog: .init(
                    workspaces: { [self] in [placement.workspace] }, currentWorkspace: storage.workspaceWithID,
                    currentMetadata: { _, _ in nil }, isCurrent: { [self] target in
                        target.carrier(in: placement.workspace) == target.tab
                    }, validateCanonicalTarget: validateCanonicalTarget
                ), storage: storage,
                selection: { .init(agent: $0.normalizedSelection.agent, modelRaw: $0.normalizedSelection.modelRaw, explicitReasoningEffortRaw: nil) },
                codexPolicy: { _ in .init(options: [], defaultEffort: nil, lastUsed: nil) },
                isStillAuthorized: { [self] in authorized }, originalColdWriter: originalColdWriter,
                readRecord: { [service] in try await service.metadataRecordForSessionID($0, for: $1) },
                readPayload: { [self] request in
                    payloadReads += 1
                    try await beforePayload?(request)
                    let payload = try await service.preparePersistedHydration(request)
                    afterPayload?()
                    return payload
                }
            )
        }

        func cleanUp() {
            beforePayload = nil
            afterPayload = nil
            validateCanonicalTarget = nil
            for session in scope.sessions.values {
                session.saveDebounceTask?.cancel()
                session.derivedTranscriptRefreshTask?.cancel()
            }
            scope.replaceSessions([:])
            try? FileManager.default.removeItem(at: root)
        }
    }
}
