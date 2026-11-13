import Foundation
import MCP
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCPServer
import RepoPromptSettingsCore
@testable import RepoPromptWorkspaceContext
import XCTest

@MainActor
final class MCPHostRouteResourceTests: XCTestCase {
    func testHostIdentityDoesNotBecomeTheLatestPresentationWindow() {
        let window = MCPRouteIdentityAllocator.allocateWindowID()
        let first = MCPRouteIdentityAllocator.allocateHost()
        let second = MCPRouteIdentityAllocator.allocateHost()
        XCTAssertEqual(WindowState.latestWindowID(), window)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertLessThan(window, first.routeID)
        XCTAssertLessThan(first.routeID, second.routeID)
        XCTAssertGreaterThan(MCPRouteIdentityAllocator.allocateWindowID(), second.routeID)
    }

    func testWithdrawalRefusesNewMappingsButDoesNotCancelTrackedTools() async throws {
        let owner = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: nil)
        let run = UUID(), connection = UUID(), execution = UUID()
        let pending = try XCTUnwrap(owner.runRouteBindings.beginPendingPolicy(connectionID: connection, runID: run, windowID: owner.identity.routeID))
        var cancellations = 0
        owner.toolExecutionRuntime.registerToolExecution(executionID: execution, runID: run, connectionID: connection, toolName: "read_file") { cancellations += 1 }
        owner.closeDomainAdmission()
        XCTAssertTrue(owner.runRouteBindings.isCurrent(pending), "Legacy domain close must not withdraw the run's mapping owner before drain")
        await owner.close()
        XCTAssertFalse(owner.runRouteBindings.hasCurrentMapping(runID: run, connectionID: connection))
        XCTAssertEqual(owner.runRouteBindings.register(connectionID: UUID(), runID: run, windowID: owner.identity.routeID), .refusedOwnerUnavailable)
        XCTAssertNil(owner.runRouteBindings.beginPendingPolicy(connectionID: UUID(), runID: run, windowID: owner.identity.routeID))
        XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(owner.toolExecutionRuntime.containsExecution(execution))
        XCTAssertTrue(owner.runRouteBindings.rollback(pending, removingContext: {}))
        owner.toolExecutionRuntime.unregisterToolExecution(executionID: execution)
        try await owner.toolExecutionRuntime.awaitNoActiveToolExecutions(runID: run)
        XCTAssertEqual(owner.toolExecutionRuntime.activeExecutionCount, 0)
    }

    func testWindowFreeDomainRouteKeepsItsOriginalConnectionGenerationOnClose() async throws {
        let runtime = try await makeRuntime()
        let windowCount = WindowState.windowCounter
        let owner = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
        owner.scheduleRegistration(workspaceID: nil, contextID: nil, revision: 0)
        let descriptor = await owner.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
        XCTAssertEqual(descriptor?.windowID, owner.identity.routeID)
        XCTAssertEqual(WindowState.windowCounter, windowCount)
        let connectionID = UUID()
        let context = MCPTabContextSnapshot(
            tabID: UUID(), windowID: owner.identity.routeID, workspaceID: nil,
            promptText: "", selection: .init(), selectedMetaPromptIDs: [], tabName: "Host",
            runID: nil, explicitlyBound: true
        )
        owner.publishBinding(connectionID: connectionID, context: context)
        await owner.settleRoutingPublications()
        let published = await runtime.routingCoordinator.snapshot()
        let receipt = try XCTUnwrap(published.connections.first { $0.registration.connectionID == connectionID }?.registration)
        XCTAssertEqual(published.windows.first?.activeContextID, context.tabID)
        _ = await runtime.routingCoordinator.unregisterConnection(receipt, operationID: UUID())
        let replacement = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let successor = try XCTUnwrap(replacement.snapshot.connections.first { $0.registration.connectionID == connectionID }?.registration)
        XCTAssertNotEqual(successor, receipt)
        let pendingConnection = UUID()
        owner.publishBinding(connectionID: pendingConnection, context: context)
        await owner.closeDomainRoute()
        await owner.closeDomainRoute()
        let final = await runtime.routingCoordinator.snapshot()
        XCTAssertFalse(final.windows.contains { $0.windowID == owner.identity.routeID })
        XCTAssertFalse(final.connections.contains { $0.registration.connectionID == pendingConnection }, "Close joins queued publications without resurrecting a route")
        XCTAssertTrue(final.connections.contains { $0.registration == successor }, "Old owner must never retract a replacement registration")
        let refused = await owner.ensureRegistered(workspaceID: nil, contextID: nil, revision: 0)
        XCTAssertNil(refused)
    }

    func testDisconnectThroughAnotherOwnerReleasesTheCanonicalConnection() async throws {
        let runtime = try await makeRuntime()
        let first = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
        let second = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
        let connectionID = UUID()
        let registered = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let receipt = try XCTUnwrap(registered.snapshot.connections.first { $0.registration.connectionID == connectionID }?.registration)
        first.retainConnection(receipt)
        await second.releaseDisconnectedConnection(connectionID)
        let disconnected = await runtime.routingCoordinator.snapshot()
        XCTAssertFalse(disconnected.connections.contains { $0.registration.connectionID == connectionID })
        let replacement = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let successor = try XCTUnwrap(replacement.snapshot.connections.first { $0.registration.connectionID == connectionID }?.registration)
        await first.close()
        let final = await runtime.routingCoordinator.snapshot()
        XCTAssertTrue(final.connections.contains { $0.registration == successor }, "The old receipt retained by another owner cannot retract its successor")
        await second.close()
    }

    func testWindowFreeCatalogFailureAndCloseUseExactRegistrationReceipts() async throws {
        let runtime = try await makeRuntime()
        do {
            let before = WindowState.windowCounter
            let owner = MCPHostRouteResources(identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime)
            let routeID = owner.identity.routeID
            let executions = owner.toolExecutionRuntime
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "read_file"))
            let binding = MCPDomainToolBinding(definition: definition) { _ in
                await .bool(executions.activeExecutionCount == 1)
            }
            let binder = MCPAppToolBinder(windowID: routeID) { name, _, arguments, implementation in
                let invocation = MCPAppToolInvocation(toolName: name, windowID: routeID, context: .trustedLocal(
                    toolName: name, metadata: .init(connectionID: nil, clientName: nil, windowID: routeID)
                ))
                return try await executions.execute(
                    invocation, ownerIdentity: ObjectIdentifier(owner), indexedRunID: nil,
                    validateInvocation: { context, routeID, identity in
                        await ServerNetworkManager.shared.validateToolInvocationContext(
                            context, expectedWindowID: routeID, expectedServerViewModelIdentity: identity
                        )
                    }
                ) { try await implementation(invocation, arguments) }
            }
            func catalog(required: Set<String>) -> MCPAppToolCatalogRegistration {
                MCPAppToolCatalogRegistration(
                    windowID: routeID, providers: [], sharedBindings: [binding],
                    runtime: binder, requiredToolNames: required
                )
            }
            do {
                _ = try await owner.registerCatalog(catalog(required: ["file_search"]))
                XCTFail("A partial catalog cannot be reported registered")
            } catch let MCPAppToolCatalogMaterializationError.missingCanonicalTools(names) {
                XCTAssertEqual(names, ["file_search"])
            }
            XCTAssertNil(owner.catalogHandle)
            let complete = catalog(required: ["read_file"])
            let handle = try await owner.registerCatalog(complete)
            let active = await owner.hasActiveCatalog()
            XCTAssertTrue(active)
            XCTAssertEqual(owner.catalogHandle, handle)
            let unrelated = await AppDomainRuntimeComposition.shared.isActive(handle)
            XCTAssertFalse(unrelated, "Explicit host runtime must not register in the process fallback")
            complete.invalidateToolsCache()
            let refreshed = try await owner.registerCatalog(complete)
            XCTAssertEqual(refreshed, handle, "Refreshing the stable legacy catalog keeps its exact handle")
            let resolved = await runtime.toolRegistry.resolve(toolName: "read_file", scope: .window(id: routeID))
            let tool = try XCTUnwrap(resolved)
            let result = try await tool.binding([:])
            XCTAssertEqual(result, .bool(true), "The real catalog/binder dispatch uses the host-owned execution tracker without a window")
            XCTAssertEqual(executions.activeExecutionCount, 0)
            XCTAssertEqual(WindowState.windowCounter, before)
            // Retire admission after registration but before opening the provider gate. The same
            // window-free execution path must withdraw tracking without dispatch or an ended count.
            let rejectedRun = UUID()
            do {
                _ = try await executions.execute(
                    .init(toolName: "read_file", windowID: routeID, context: .trustedLocal(
                        toolName: "read_file", metadata: .init(connectionID: nil, clientName: nil, windowID: routeID)
                    )),
                    ownerIdentity: ObjectIdentifier(owner), indexedRunID: rejectedRun,
                    validateInvocation: { _, _, _ in await !owner.isClosing },
                    presentation: .init(registered: { _, _ in owner.closeDomainAdmission() })
                ) { XCTFail("A retired route cannot dispatch its provider")
                    return false
                }
                XCTFail("Retired invocation must be refused")
            } catch ServerNetworkManager.ToolDispatchAdmissionError.windowTerminal {}
            XCTAssertEqual(executions.activeExecutionCount, 0)
            XCTAssertEqual(executions.toolEndedCount(runID: rejectedRun), 0)
            await owner.close()
            let retired = await owner.hasActiveCatalog()
            XCTAssertFalse(retired)
            XCTAssertNil(owner.catalogHandle)
            do {
                _ = try await owner.registerCatalog(complete)
                XCTFail("Retired route must not reopen its catalog")
            } catch MCPHostRouteResources.RegistrationFailure.closing {} catch { XCTFail("Unexpected refusal: \(error)") }
        }
    }

    func testSettingsLeaseUsesExactOwnerWithoutWindowElectionAndReleasesOnce() throws {
        let count = WindowState.windowCounter
        let keys = KeyManager()
        let settings = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false)
        let first = try XCTUnwrap(APISettingsRuntimeLease.acquire(from: settings))
        let second = try XCTUnwrap(APISettingsRuntimeLease.acquire(from: settings))
        XCTAssertTrue(first.settings === settings)
        XCTAssertTrue(second.settings === settings)
        XCTAssertEqual(WindowState.windowCounter, count)
        settings.prepareForWindowClose()
        XCTAssertTrue(settings.canAcquireManagedRuntimeLease)
        first.release()
        first.release()
        XCTAssertEqual(settings.managedRuntimeLeaseCount, 1)
        second.release()
        XCTAssertEqual(settings.managedRuntimeLeaseCount, 0)
        XCTAssertFalse(settings.canAcquireManagedRuntimeLease)
        XCTAssertNil(APISettingsRuntimeLease.acquire(from: settings))
    }

    func testCanonicalContextLeaseDefersOnlyItsRootsAndRevalidatesTheAuthority() async throws {
        let runtime = try await makeRuntime()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-root-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let files = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let root = try await files.loadRoot(path: directory.path)
        addTeardownBlock { await files.unloadRoot(id: root.id) }
        var workspace = WorkspaceModel(name: "Host context", repoPaths: [directory.path])
        let tab = ComposeTabState()
        workspace.composeTabs = [tab]
        let documentURL = directory.appendingPathComponent("workspace.json")
        let document = try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(workspace), fileURL: documentURL)
        _ = await runtime.workspaceStore.registerReadDocument(document)
        let resources = AgentHostWorkspaceResources(files: files, contexts: runtime.contextStore)
        let before = WindowState.windowCounter
        do {
            _ = try await resources.acquire(context: .init(workspaceID: workspace.id, contextID: tab.id), rootIDs: [])
            XCTFail("An incomplete root set must not claim a workspace lease")
        } catch AgentHostWorkspaceResources.Failure.rootsChanged {} catch { XCTFail("Unexpected refusal: \(error)") }
        let lease = try await resources.acquire(context: .init(workspaceID: workspace.id, contextID: tab.id), rootIDs: [root.id])
        let current = await lease.isCurrent()
        XCTAssertTrue(current)
        XCTAssertEqual(WindowState.windowCounter, before)
        await files.unloadRoot(id: root.id)
        let retained = await files.rootRefs()
        XCTAssertTrue(retained.contains { $0.id == root.id })
        workspace.name = "Changed canonical context"
        let replacement = try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(workspace), fileURL: documentURL)
        _ = await runtime.workspaceStore.registerReadDocument(replacement)
        let stale = await lease.isCurrent()
        XCTAssertFalse(stale)
        await lease.release()
        await lease.release()
        let released = await files.rootRefs()
        XCTAssertFalse(released.contains { $0.id == root.id })
    }

    private func makeRuntime() async throws -> MCPDomainRuntime {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-runtime-\(UUID())")
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: "host-\(UUID())", storageDirectory: directory,
            workspaceStorageDirectory: directory.appendingPathComponent("workspaces"),
            eventDirectory: directory.appendingPathComponent("events"), temporaryDirectory: directory.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        return runtime
    }
}

@MainActor
final class MCPRunRouteBindingsTests: XCTestCase {
    func testStandaloneMappingRejectsReplacementAcrossRunWindowAndTab() {
        let lifetime = MCPRunRouteBindings.OwnerLifetime()
        defer { withExtendedLifetime(lifetime) {} }
        let routes = MCPRunRouteBindings(ownerLifetime: lifetime)
        let runID = UUID(), first = UUID(), replacement = UUID(), tabID = UUID()
        XCTAssertEqual(routes.register(connectionID: first, runID: runID, windowID: 41), .registered(displacedConnectionID: nil))
        routes.tabContextByConnectionID[first] = context(runID: runID, tabID: tabID)
        XCTAssertTrue(routes.hasCurrentMapping(runID: runID, connectionID: first, expectedTabID: tabID))
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: first, expectedTabID: UUID()))
        XCTAssertEqual(routes.register(connectionID: replacement, runID: runID, windowID: 42), .refusedWindow(41))
        let otherRun = UUID()
        XCTAssertEqual(routes.register(connectionID: first, runID: otherRun, windowID: 41), .refusedBoundRun(runID))
        XCTAssertEqual(routes.register(connectionID: replacement, runID: runID, windowID: 41), .registered(displacedConnectionID: first))
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: first, expectedTabID: tabID))
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: replacement, expectedTabID: tabID), "A mapping without its exact context is insufficient")
        routes.tabContextByConnectionID[replacement] = context(runID: runID, tabID: tabID)
        XCTAssertTrue(routes.hasCurrentMapping(runID: runID, connectionID: replacement, expectedTabID: tabID))
        routes.connectionIDToRunID[replacement] = otherRun
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: replacement, expectedTabID: tabID), "Both mapping directions remain required")
    }

    func testPendingReplacementRestoresCommittedPredecessorButNeverPendingPredecessor() throws {
        let lifetime = MCPRunRouteBindings.OwnerLifetime()
        defer { withExtendedLifetime(lifetime) {} }
        let routes = MCPRunRouteBindings(ownerLifetime: lifetime)
        let runID = UUID(), committed = UUID(), replacement = UUID()
        _ = routes.register(connectionID: committed, runID: runID, windowID: 41)
        let token = try XCTUnwrap(routes.beginPendingPolicy(connectionID: replacement, runID: runID, windowID: 41))
        XCTAssertTrue(routes.isCurrent(token))
        XCTAssertNil(routes.connectionIDToRunID[committed])
        XCTAssertTrue(routes.rollback(token, removingContext: {}))
        XCTAssertTrue(routes.hasCurrentMapping(runID: runID, connectionID: committed))
        XCTAssertNil(routes.connectionIDToRunID[replacement])

        let pending = try XCTUnwrap(routes.beginPendingPolicy(connectionID: replacement, runID: runID, windowID: 41))
        let successor = try XCTUnwrap(routes.beginPendingPolicy(connectionID: UUID(), runID: runID, windowID: 41))
        XCTAssertFalse(routes.isCurrent(pending), "A displaced token cannot begin rollback")
        XCTAssertTrue(routes.isCurrent(successor))
        var staleCleanupRan = false
        XCTAssertFalse(routes.rollback(pending) { staleCleanupRan = true })
        XCTAssertFalse(staleCleanupRan)
        XCTAssertTrue(routes.isCurrent(successor))
        XCTAssertTrue(routes.rollback(successor, removingContext: {}))
        XCTAssertFalse(routes.hasCurrentMapping(runID: runID, connectionID: replacement), "Rollback must not resurrect a displaced pending policy")
        XCTAssertNil(routes.connectionIDByRunID[runID])
    }

    func testRuntimeRetainsSameMappingStorageWithoutPresentation() throws {
        let scope = AgentSessionRuntimeStore().makeScope()
        var lifetime: MCPRunRouteBindings.OwnerLifetime? = .init()
        var routes: MCPRunRouteBindings? = try MCPRunRouteBindings(ownerLifetime: XCTUnwrap(lifetime))
        weak let retainedRoutes = routes
        try scope.mcp.installRunRoute(id: 41, bindings: XCTUnwrap(routes))
        let runID = UUID(), connectionID = UUID()
        _ = try XCTUnwrap(routes).register(connectionID: connectionID, runID: runID, windowID: 41)
        routes = nil
        let retained = try XCTUnwrap(retainedRoutes, "A runtime route must not disappear with its presenter")
        XCTAssertTrue(retained.hasCurrentMapping(runID: runID, connectionID: connectionID))
        retained.connectionIDByRunID.removeValue(forKey: runID)
        XCTAssertFalse(retained.hasCurrentMapping(runID: runID, connectionID: connectionID), "Transport cleanup mutates the retained storage, not a copied snapshot")
        _ = retained.register(connectionID: connectionID, runID: runID, windowID: 41)
        XCTAssertTrue(retained.hasCurrentMapping(runID: runID, connectionID: connectionID))
        lifetime = nil
        XCTAssertFalse(retained.hasCurrentMapping(runID: runID, connectionID: connectionID), "Retained maps must refuse dispatch when their routing composition has gone away")
        XCTAssertEqual(retained.connectionIDByRunID[runID], connectionID, "Refusal does not pretend to perform domain cleanup")
    }

    private func context(runID: UUID, tabID: UUID) -> MCPTabContextSnapshot {
        .init(tabID: tabID, windowID: 41, workspaceID: UUID(), promptText: "", selection: .init(), selectedMetaPromptIDs: [], tabName: "Runtime", runID: runID, explicitlyBound: true)
    }
}

@MainActor
final class ContextBuilderSelectionTransactionTests: XCTestCase {
    func testLegacyDomainUnregistrationKeepsRunMappingOwnerUntilServerRelease() async throws {
        let fixture = try await makePromptMutationFixture(name: "legacy-route-lifetime")
        let server = fixture.window.mcpServer
        let runID = UUID(), connectionID = UUID()
        XCTAssertEqual(server.runRouteBindings.register(connectionID: connectionID, runID: runID, windowID: fixture.window.windowID), .registered(displacedConnectionID: nil))
        XCTAssertTrue(server.runRouteBindings.hasCurrentMapping(runID: runID, connectionID: connectionID))
        await server.unregisterDomainRoutingWindow()
        XCTAssertTrue(server.runRouteBindings.hasCurrentMapping(runID: runID, connectionID: connectionID), "Domain close precedes the existing explicit run drain; it must not withdraw that run's resources")
    }

    func testBackgroundPromptAppendUsesCurrentTextWithoutRefreshingTheStaleBinding() async throws {
        let fixture = try await makePromptMutationFixture(name: "shared-background-prompt")
        let server = fixture.window.mcpServer
        let activeTabID = fixture.window.promptManager.activeComposeTabID
        let activePrompt = fixture.window.promptManager.promptText
        XCTAssertNotEqual(activeTabID, fixture.tabID)
        try fixture.updateStoredPrompt("X0")
        try fixture.bindPromptConnection(fixture.connectionID)
        let otherConnectionID = UUID()
        try fixture.bindPromptConnection(otherConnectionID)

        let otherReply = try await fixture.mutatePrompt(connectionID: otherConnectionID) { $0 = "Y1" }
        XCTAssertEqual(otherReply, "Y1")
        XCTAssertEqual(fixture.boundContext?.promptText, "X0", "The first connection must remain stale before append")
        let appendReply = try await fixture.mutatePrompt(connectionID: fixture.connectionID) { $0 += "+X" }

        XCTAssertEqual(appendReply, "Y1+X")
        XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: fixture.identity)?.promptText, "Y1+X")
        let freshConnectionID = UUID()
        try fixture.bindPromptConnection(freshConnectionID)
        XCTAssertEqual(server.tabContextByConnectionID[freshConnectionID]?.promptText, "Y1+X")
        XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, activeTabID)
        XCTAssertEqual(fixture.window.promptManager.promptText, activePrompt)
    }

    func testOrdinaryPromptMutationsPreserveCurrentMetaPromptsAndOtherTabFields() async throws {
        let fixture = try await makePromptMutationFixture(name: "prompt-field-ownership")
        let cachedMetaPromptID = UUID()
        let currentMetaPromptIDs = [UUID(), UUID()]
        let cases: [(name: String, expected: String, mutation: (inout String) -> Void)] = [
            ("set", "Replacement", { $0 = "Replacement" }),
            ("append", "Y1+X", { $0 += "+X" }),
            ("clear", "", { $0 = "" })
        ]
        for testCase in cases {
            try fixture.updateStoredPrompt("X0", metaPromptIDs: [cachedMetaPromptID])
            try fixture.bindPromptConnection(fixture.connectionID)
            var current = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            current.promptText = "Y1"
            current.selectedMetaPromptIDs = currentMetaPromptIDs
            current.selection = StoredSelection(selectedPaths: [fixture.fileB.path])
            current.contextOverrides.useOverridePrompt = true
            current.contextOverrides.overridePromptText = "Keep this override"
            XCTAssertTrue(fixture.window.workspaceManager.updateComposeTabStoredOnly(current, inWorkspaceID: fixture.workspaceID))
            XCTAssertEqual(fixture.boundContext?.selectedMetaPromptIDs, [cachedMetaPromptID])
            XCTAssertEqual(fixture.boundContext?.promptText, "X0")

            let reply = try await fixture.mutatePrompt(
                connectionID: fixture.connectionID,
                mutation: testCase.mutation
            )

            let stored = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            XCTAssertEqual(reply, testCase.expected, testCase.name)
            XCTAssertEqual(stored.promptText, testCase.expected, testCase.name)
            XCTAssertEqual(stored.selectedMetaPromptIDs, currentMetaPromptIDs, testCase.name)
            XCTAssertEqual(stored.selection, current.selection, testCase.name)
            XCTAssertEqual(stored.contextOverrides, current.contextOverrides, testCase.name)
        }
    }

    func testActivePromptAppendUsesPendingEditorTextAndKeepsCanonicalMetaPrompts() async throws {
        let fixture = try await makePromptMutationFixture(name: "active-prompt-owner")
        await fixture.window.promptManager.switchComposeTab(fixture.tabID)
        XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabID)
        let metaPromptIDs = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity)).selectedMetaPromptIDs
        try fixture.updateStoredPrompt("Stored", metaPromptIDs: metaPromptIDs)
        try fixture.bindPromptConnection(fixture.connectionID)
        fixture.window.promptManager.promptText = "Pending editor text"
        XCTAssertEqual(fixture.boundContext?.promptText, "Stored")

        let reply = try await fixture.mutatePrompt(connectionID: fixture.connectionID) { $0 += "+MCP" }

        XCTAssertEqual(reply, "Pending editor text+MCP")
        XCTAssertEqual(fixture.window.promptManager.promptText, "Pending editor text+MCP")
        let stored = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
        XCTAssertEqual(stored.promptText, "Pending editor text+MCP")
        XCTAssertEqual(stored.selectedMetaPromptIDs, metaPromptIDs)
    }

    func testRunScopedPromptMutationRetainsItsFrozenPromptSemantics() async throws {
        let fixture = try await makePromptMutationFixture(name: "frozen-prompt-owner")
        try fixture.updateStoredPrompt("Frozen")
        _ = try fixture.installContext(selection: .init())
        try fixture.updateStoredPrompt("Newer ordinary prompt")
        XCTAssertEqual(fixture.boundContext?.runID, fixture.runID)

        let reply = try await fixture.mutatePrompt(connectionID: fixture.connectionID) { $0 += "+Run" }

        XCTAssertEqual(reply, "Frozen+Run")
        XCTAssertEqual(fixture.boundContext?.promptText, "Frozen+Run")
        XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: fixture.identity)?.promptText, "Frozen+Run")
    }

    func testOrdinaryPromptMutationRejectsAStaleBindingToARemovedTab() async throws {
        let fixture = try await makePromptMutationFixture(name: "removed-prompt-target")
        try fixture.updateStoredPrompt("Existing prompt")
        try fixture.bindPromptConnection(fixture.connectionID)
        let manager = fixture.window.workspaceManager
        let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == fixture.workspaceID })
        manager.workspaces[workspaceIndex].composeTabs.removeAll { $0.id == fixture.tabID }
        let survivingTabs = manager.workspaces[workspaceIndex].composeTabs
        let activePrompt = fixture.window.promptManager.promptText
        var mutationWasCalled = false

        do {
            _ = try await fixture.mutatePrompt(connectionID: fixture.connectionID) {
                mutationWasCalled = true
                $0 += "+Must not commit"
            }
            XCTFail("A removed target must not report a successful prompt write")
        } catch let error as MCPError {
            guard case let .invalidParams(message) = error else {
                XCTFail("Unexpected prompt mutation error: \(error)")
                return
            }
            let unwrappedMessage = try XCTUnwrap(message)
            XCTAssertTrue(unwrappedMessage.contains("bound tab is no longer available"), unwrappedMessage)
        }

        XCTAssertFalse(mutationWasCalled)
        XCTAssertNil(manager.composeTab(for: fixture.identity))
        XCTAssertEqual(manager.workspaces[workspaceIndex].composeTabs, survivingTabs)
        XCTAssertEqual(fixture.boundContext?.promptText, "Existing prompt")
        XCTAssertEqual(fixture.window.promptManager.promptText, activePrompt)
    }

    func testCursorInitializeNamePromotesQueuedDiscoveryContext() async throws {
        let fixture = try await makeFixture(name: "cursor-initialize-name")
        defer { fixture.cleanup() }
        let server = fixture.window.mcpServer
        let selection = StoredSelection(selectedPaths: [fixture.fileA.path])
        try await fixture.seedCanonical(selection)
        let activeTabID = fixture.window.workspaceManager.activeWorkspace?.activeComposeTabID
        XCTAssertNotEqual(activeTabID, fixture.tabID)

        // Queue through the provider hint, then promote with Cursor's observed initialize name.
        // A route mapping alone is insufficient: the exact frozen run context must follow it.
        try server.installFrozenTabContext(
            clientID: nil,
            clientName: XCTUnwrap(AgentProviderKind.cursor.mcpClientNameHint),
            context: fixture.makeContext(selection: selection)
        )
        let token = try XCTUnwrap(server.registerPendingPolicyRunIDMapping(
            connectionID: fixture.connectionID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "Cursor"
        ))
        let promoted = try XCTUnwrap(token.promotedContext)
        XCTAssertEqual(promoted.runID, fixture.runID)
        XCTAssertEqual(promoted.windowID, fixture.window.windowID)
        XCTAssertEqual(promoted.workspaceID, fixture.workspaceID)
        XCTAssertEqual(promoted.tabID, fixture.tabID)
        XCTAssertEqual(promoted.selection, selection)
        XCTAssertEqual(fixture.boundContext?.selection, selection)
        XCTAssertEqual(server.pendingContextQueueLength(clientName: "Cursor", windowID: fixture.window.windowID), 0)
        XCTAssertEqual(server.contextBuilderFinalContextConnectionID(runID: fixture.runID), fixture.connectionID)
        XCTAssertEqual(fixture.window.workspaceManager.activeWorkspace?.activeComposeTabID, activeTabID)
    }

    func testNamedTabKeepsItsNameAfterTasknamePromptMutation() async throws {
        for name in ["Care", "New Chat about support", "Untitled Chat about support"] {
            let fixture = try await makeFixture(name: "named-taskname")
            defer { fixture.cleanup() }
            fixture.window.promptManager.renameComposeTab(fixture.tabID, to: "T17")
            _ = try fixture.installContext(selection: .init())

            // An explicit rename after discovery captured its context must win over that snapshot.
            fixture.window.agentModeViewModel.renameSession(tabID: fixture.tabID, to: name)
            let prompt = "<taskname=\"Support ticket activity MCP plan\"/>\n<task>Plan support activity</task>"
            let invocation = ToolInvocationContext.trustedLocal(
                toolName: "prompt",
                metadata: fixture.metadata
            )
            _ = try await MCPInvocationContextBridge.withInvocation(invocation) {
                try await fixture.window.mcpServer.updateCurrentTabPrompt(toolName: "prompt") {
                    $0 = prompt
                }
            }

            let storedTab = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            XCTAssertEqual(storedTab.name, name)
            XCTAssertEqual(storedTab.promptText, prompt)
            XCTAssertEqual(fixture.boundContext?.promptText, prompt)
            XCTAssertEqual(fixture.window.promptManager.currentComposeTabs.first { $0.id == fixture.tabID }?.name, name)
            XCTAssertEqual(fixture.window.agentModeViewModel.resolvedSessionDisplayName(for: fixture.tabID), name)
        }
    }

    func testChatPlaceholderTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["New Chat", "Untitled Chat", "Untitled", "  new   CHAT\n"])
    }

    func testEmptyTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["", " \n\t"])
    }

    private func assertTasknameNamesDefaultTabs(named names: [String]) async throws {
        for name in names {
            let fixture = try await makeFixture(name: "placeholder-taskname", tabName: name)
            defer { fixture.cleanup() }
            XCTAssertEqual(fixture.window.workspaceManager.composeTab(for: fixture.identity)?.name, name)
            _ = try fixture.installContext(selection: .init())
            let prompt = "<taskname=\"Support   ticket activity MCP plan\"/>\n<task>Plan support activity</task>"
            let invocation = ToolInvocationContext.trustedLocal(
                toolName: "prompt",
                metadata: fixture.metadata
            )
            _ = try await MCPInvocationContextBridge.withInvocation(invocation) {
                try await fixture.window.mcpServer.updateCurrentTabPrompt(toolName: "prompt") {
                    $0 = prompt
                }
            }

            let expectedName = "Support ticket activity MCP plan"
            let storedTab = try XCTUnwrap(fixture.window.workspaceManager.composeTab(for: fixture.identity))
            XCTAssertEqual(storedTab.name, expectedName, "Original title: \(String(reflecting: name))")
            XCTAssertEqual(storedTab.promptText, prompt)
            XCTAssertEqual(fixture.boundContext?.promptText, prompt)
            XCTAssertEqual(fixture.window.promptManager.currentComposeTabs.first { $0.id == fixture.tabID }?.name, expectedName)
            XCTAssertEqual(fixture.window.agentModeViewModel.resolvedSessionDisplayName(for: fixture.tabID), expectedName)
        }
    }

    func testDefaultTabGetsNamedAfterTasknamePromptMutation() async throws {
        try await assertTasknameNamesDefaultTabs(named: ["T17"])
    }

    /// A headless client (for example Devin) may restart its stdio MCP child mid-run. The successor
    /// re-matches the settlement-retained discovery policy after the pending context was already
    /// consumed, so it must inherit the displaced connection's live run context.
    func testPendingPolicyReplacementInheritsDisplacedDiscoveryContext() async throws {
        let fixture = try await makeFixture(name: "replacement-handover")
        defer { fixture.cleanup() }
        let initialSelection = StoredSelection(selectedPaths: [fixture.fileA.path])
        try await fixture.seedCanonical(initialSelection)
        let server = fixture.window.mcpServer
        try server.installFrozenTabContext(
            clientID: nil,
            clientName: "devin",
            context: fixture.makeContext(selection: initialSelection)
        )
        XCTAssertNotNil(server.registerPendingPolicyRunIDMapping(
            connectionID: fixture.connectionID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        let discoveredSelection = StoredSelection(selectedPaths: [fixture.fileB.path])
        server.tabContextByConnectionID[fixture.connectionID]?.selection = discoveredSelection

        let successorID = UUID()
        let token = try XCTUnwrap(server.registerPendingPolicyRunIDMapping(
            connectionID: successorID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        XCTAssertEqual(token.displacedConnectionID, fixture.connectionID)
        XCTAssertEqual(server.tabContextByConnectionID[successorID]?.runID, fixture.runID)
        XCTAssertEqual(server.tabContextByConnectionID[successorID]?.selection, discoveredSelection)

        // The displaced connection is then torn down as a replacement, not a discovery EOF.
        XCTAssertFalse(server.detachContextBuilderTabContextForDiscoveryTeardown(
            connectionID: fixture.connectionID,
            runID: fixture.runID
        ))
        server.removeTabContext(
            forConnectionID: fixture.connectionID,
            clientName: "devin",
            windowID: fixture.window.windowID,
            runID: nil
        )

        XCTAssertEqual(server.contextBuilderFinalContextConnectionID(runID: fixture.runID), successorID)
        let result = await server.commitContextBuilderTabContext(
            connectionID: successorID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.committedTab?.tab.selection, discoveredSelection)
    }

    func testRolledBackPendingPolicyReplacementKeepsDisplacedDiscoveryContext() async throws {
        let storageRoot = try makeTestDirectory(name: "DiscoveryHandoffRollback")
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: "discovery-handoff-\(UUID().uuidString)",
            storageDirectory: storageRoot.appendingPathComponent("runtime-state"),
            workspaceStorageDirectory: storageRoot,
            eventDirectory: storageRoot.appendingPathComponent("events"),
            temporaryDirectory: storageRoot.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        addTeardownBlock { _ = await runtime.shutdown() }
        let fixture = try await makeFixture(name: "replacement-rollback", domainRuntime: runtime)
        defer { fixture.cleanup() }
        let selection = StoredSelection(selectedPaths: [fixture.fileA.path])
        let server = fixture.window.mcpServer
        try server.installFrozenTabContext(clientID: nil, clientName: "devin", context: fixture.makeContext(selection: selection))
        XCTAssertNotNil(server.registerPendingPolicyRunIDMapping(
            connectionID: fixture.connectionID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))
        let successorID = UUID()
        let token = try XCTUnwrap(server.registerPendingPolicyRunIDMapping(
            connectionID: successorID,
            runID: fixture.runID,
            windowID: fixture.window.windowID,
            clientName: "devin"
        ))

        await server.routeResources.settleRoutingPublications()
        XCTAssertNotNil(server.tabContextCancellablesByConnectionID[successorID])
        let coordinator = try XCTUnwrap(server.domainRoutingCoordinator)
        let beforeRollback = await coordinator.snapshot()
        XCTAssertTrue(beforeRollback.connections.contains { $0.registration.connectionID == successorID })

        XCTAssertEqual(
            server.rollbackPendingPolicyRunIDMapping(
                token,
                clientName: "devin",
                windowID: fixture.window.windowID,
                signalRoutingFailure: false
            ),
            .restored
        )

        // Rollback drops only the successor's inherited copy; the displaced snapshot is untouched.
        await server.routeResources.settleRoutingPublications()
        let afterRollback = await coordinator.snapshot()
        XCTAssertFalse(afterRollback.connections.contains { $0.registration.connectionID == successorID })
        XCTAssertTrue(afterRollback.connections.contains { $0.registration.connectionID == fixture.connectionID })
        XCTAssertNil(server.tabContextCancellablesByConnectionID[successorID])
        XCTAssertNil(server.tabContextByConnectionID[successorID])
        XCTAssertEqual(fixture.boundContext?.runID, fixture.runID)
        XCTAssertEqual(fixture.boundContext?.selection, selection)
        XCTAssertEqual(server.pendingContextQueueLength(clientName: "devin", windowID: fixture.window.windowID), 0)
    }

    func testDiscoveryRoutingErrorDoesNotSuggestDisabledBindContext() {
        XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains("bind_context"))
        let message = MCPServerViewModel.tabContextRoutingErrorMessage(toolName: "git", runPurpose: .discoverRun)
        XCTAssertTrue(message.contains("No tab context is bound for git"))
        XCTAssertFalse(message.contains("bind_context"))
        XCTAssertTrue(MCPServerViewModel.tabContextRoutingErrorMessage(toolName: "git").contains("bind_context"))
    }

    func testContextBuilderToolMutationPublishesCanonicalSelectionImmediately() async throws {
        let fixture = try await makeFixture(name: "immediate")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        let verification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertTrue(verification?.isVerified == true)
        XCTAssertEqual(verification?.canonicalSelection, discovered)
        XCTAssertEqual(fixture.canonicalSelection, discovered)
        XCTAssertEqual(fixture.boundContext?.selection, discovered)
    }

    func testSuccessfulEarlierToolMutationSurvivesLaterDiscoveryFailure() async throws {
        let fixture = try await makeFixture(name: "failure")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )
        fixture.window.mcpServer.removeTabContext(
            forConnectionID: fixture.connectionID,
            clientName: nil,
            windowID: fixture.window.windowID,
            runID: fixture.runID
        )
        let failedCommit = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )

        guard case .missingFinalContext = failedCommit.outcome else {
            return XCTFail("Expected the failed discovery to have no terminal context")
        }
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    func testContextBuilderAndOrdinaryAgentMutationsUseSameCanonicalPath() async throws {
        let fixture = try await makeFixture(name: "shared-path")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let first = StoredSelection(selectedPaths: [fixture.fileB.path])
        let second = StoredSelection(selectedPaths: [fixture.fileC.path])
        try await fixture.seedCanonical(source)

        let contextBuilderContext = try fixture.installContext(selection: source)
        let firstVerification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: contextBuilderContext.withSelection(first)),
            metadata: fixture.metadata,
            mutated: true
        )
        let ordinaryAgentContext = try XCTUnwrap(fixture.boundContext)
        let secondVerification = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: ordinaryAgentContext.withSelection(second)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertEqual(firstVerification?.canonicalSelection, first)
        XCTAssertEqual(secondVerification?.canonicalSelection, second)
        XCTAssertEqual(fixture.canonicalSelection, second)
    }

    func testDeferredUISnapshotCannotClobberImmediateCanonicalPublication() async throws {
        let fixture = try await makeFixture(name: "ui-fence")
        defer { fixture.cleanup() }
        await fixture.window.promptManager.switchComposeTab(fixture.tabID)
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        XCTAssertEqual(
            fixture.window.selectionCoordinator.selectionForActiveUISnapshot(
                source,
                tabID: fixture.tabID
            ),
            discovered,
            "A UI snapshot queued before the tool mutation must not revoke canonical selection"
        )
        XCTAssertEqual(fixture.canonicalSelection, discovered)
    }

    func testOraclePackagingObservesImmediateCanonicalContextBuilderSelection() async throws {
        let fixture = try await makeFixture(name: "oracle-packaging")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let discovered = StoredSelection(selectedPaths: [fixture.fileB.path])
        try await fixture.seedCanonical(source)
        let context = try fixture.installContext(selection: source)

        _ = await fixture.window.mcpServer.persistResolvedTabContextSnapshot(
            .init(snapshot: context.withSelection(discovered)),
            metadata: fixture.metadata,
            mutated: true
        )

        let stabilized = await fixture.window.mcpServer.stabilizedVirtualContext(for: context)
        let packaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: stabilized.tabID,
            sourceWorkspaceID: stabilized.workspaceID,
            sourceSelectionRevision: stabilized.selectionRevision,
            sourceAgentSessionID: stabilized.activeAgentSessionID,
            sourceAgentRunID: stabilized.runID,
            promptText: stabilized.promptText,
            selection: stabilized.selection,
            lookupContext: stabilized.frozenLookupContext,
            reviewGitContext: .automaticOnly(base: "HEAD"),
            provenance: .direct
        )

        XCTAssertEqual(packaging.selection, discovered)
        XCTAssertFalse(packaging.selection.selectedPaths.contains(fixture.fileA.path))
    }

    func testTerminalCommitPreservesNewerCanonicalSelection() async throws {
        let fixture = try await makeFixture(name: "terminal-fence")
        defer { fixture.cleanup() }
        let source = StoredSelection(selectedPaths: [fixture.fileA.path])
        let newer = StoredSelection(selectedPaths: [fixture.fileC.path])
        try await fixture.seedCanonical(source)
        let staleRunContext = try fixture.installContext(selection: source)

        _ = await fixture.window.selectionCoordinator.persistSelection(
            newer,
            for: fixture.identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )
        fixture.window.mcpServer.tabContextByConnectionID[fixture.connectionID] = staleRunContext

        let result = await fixture.window.mcpServer.commitContextBuilderTabContext(
            connectionID: fixture.connectionID,
            expectedRunID: fixture.runID,
            isStillCurrent: { true }
        )

        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(result.committedTab?.tab.selection, newer)
        XCTAssertEqual(fixture.canonicalSelection, newer)
    }

    private func makePromptMutationFixture(name: String) async throws -> Fixture {
        let fixture = try await makeFixture(name: name)
        await fixture.window.workspaceManager.waitUntilPostSwitchGitDataLoadComplete()
        return fixture
    }

    private func makeFixture(name: String, tabName: String? = nil, domainRuntime: MCPDomainRuntime? = nil) async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = if let domainRuntime { WindowState(domainRuntime: domainRuntime) } else { WindowState() }
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        WindowStatesManager.shared.registerWindowState(window)
        await window.workspaceManager.awaitInitialized()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderSelectionTransactionTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["A.swift", "B.swift", "C.swift"].map { root.appendingPathComponent($0) }
        for file in files {
            try "// \(file.lastPathComponent)".write(to: file, atomically: true, encoding: .utf8)
        }
        let storage = WorkspaceFixtureStorage(root: root)
        addTeardownBlock { @MainActor in
            await window.tearDown()
            await window.workspaceManager.debugDrainScheduledSaves()
            WindowStatesManager.shared.unregisterWindowState(window)
            await storage.remove()
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = storage.isolate(
            window.workspaceManager.createWorkspace(name: name, repoPaths: [root.path], ephemeral: true),
            in: window.workspaceManager
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: name)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let backgroundTab = await window.promptManager.createBackgroundComposeTab(
            strategy: .blank,
            name: tabName ?? "Transaction \(name)"
        )
        let tabID = try XCTUnwrap(backgroundTab?.id)
        return Fixture(
            window: window,
            root: root,
            workspaceID: workspaceID,
            tabID: tabID,
            fileA: files[0],
            fileB: files[1],
            fileC: files[2]
        )
    }
}

@MainActor
private struct Fixture {
    let window: WindowState
    let root: URL
    let workspaceID: UUID
    let tabID: UUID
    let fileA: URL
    let fileB: URL
    let fileC: URL
    let connectionID = UUID()
    let runID = UUID()

    var identity: WorkspaceSelectionIdentity {
        .init(workspaceID: workspaceID, tabID: tabID)
    }

    var metadata: MCPServerViewModel.RequestMetadata {
        .init(connectionID: connectionID, clientName: "selection-transaction-test", windowID: window.windowID)
    }

    var canonicalSelection: StoredSelection? {
        window.workspaceManager.composeTab(for: identity)?.selection
    }

    var boundContext: MCPServerViewModel.TabContextSnapshot? {
        window.mcpServer.tabContextByConnectionID[connectionID]
    }

    func seedCanonical(_ selection: StoredSelection) async throws {
        _ = await window.selectionCoordinator.persistSelection(
            selection,
            for: identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )
        XCTAssertEqual(canonicalSelection, selection)
    }

    func updateStoredPrompt(_ prompt: String, metaPromptIDs: [UUID]? = nil) throws {
        var tab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        tab.promptText = prompt
        if let metaPromptIDs {
            tab.selectedMetaPromptIDs = metaPromptIDs
        }
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(tab, inWorkspaceID: workspaceID))
    }

    func bindPromptConnection(_ connectionID: UUID) throws {
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "prompt-mutation-test",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
    }

    func mutatePrompt(
        connectionID: UUID,
        mutation: (inout String) -> Void
    ) async throws -> String {
        let invocation = ToolInvocationContext.trustedLocal(
            toolName: "prompt",
            metadata: .init(connectionID: connectionID, clientName: "prompt-mutation-test", windowID: window.windowID)
        )
        return try await MCPInvocationContextBridge.withInvocation(invocation) {
            try await window.mcpServer.updateCurrentTabPrompt(toolName: "prompt", mutation: mutation)
        }
    }

    func installContext(selection: StoredSelection) throws -> MCPServerViewModel.TabContextSnapshot {
        let context = try makeContext(selection: selection)
        window.mcpServer.tabContextByConnectionID[connectionID] = context
        return context
    }

    func makeContext(selection: StoredSelection) throws -> MCPServerViewModel.TabContextSnapshot {
        let tab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        return MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.windowID,
            workspaceID: workspaceID,
            promptText: tab.promptText,
            selection: selection,
            selectionRevision: window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: tabID
            ),
            selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
            selectedContextBuilderPromptIDs: tab.contextBuilder.selectedContextBuilderPromptIDs,
            tabName: tab.name,
            runID: runID,
            explicitlyBound: false
        )
    }

    func cleanup() {
        // The shared fixture teardown joins saves before removing roots/sidecars.
        WindowStatesManager.shared.unregisterWindowState(window)
    }
}

private extension MCPServerViewModel.TabContextSnapshot {
    func withSelection(_ selection: StoredSelection) -> Self {
        var copy = self
        copy.selection = selection
        return copy
    }
}
