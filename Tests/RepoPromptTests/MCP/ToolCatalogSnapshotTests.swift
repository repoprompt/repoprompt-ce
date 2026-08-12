import Darwin
import Foundation
import MCP
import Ontology
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

@MainActor
final class ToolCatalogSnapshotTests: XCTestCase {
    func testWindowToolCatalogSignatureMatchesGolden() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let signatures = try Self.signatures(for: tools)

        XCTAssertEqual(
            tools.map(\.name),
            MCPAppToolGroup.orderedToolNames,
            "Window catalog order should follow MCPAppToolGroup."
        )
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count, "Window catalog should not contain duplicate tool names.")
        XCTAssertTrue(
            tools.allSatisfy { MCPToolExecutionContractCatalog.contract(for: $0.name) != nil },
            "Every live window tool must have an explicit execution contract."
        )
        XCTAssertEqual(
            MCPAppToolGroup.git.orderedToolNames,
            [MCPWindowToolName.git, MCPWindowToolName.manageWorktree],
            ".git group should reserve deterministic provider order for git-related tools."
        )
        XCTAssertEqual(
            tools.map(\.name).filter { MCPAppToolGroup.git.orderedToolNames.contains($0) },
            MCPAppToolGroup.git.orderedToolNames,
            "Window catalog should keep .git providers ordered as git, manage_worktree."
        )

        XCTAssertEqual(signatures, Self.expectedSignatures)
    }

    func testCanonicalDefinitionsMatchReadableGeneratedReviewSnapshot() throws {
        let generated = try MCPDomainCanonicalToolDefinitions.reviewSnapshotData()
        let repoRoot = try RepoRoot.url()
        let snapshotURL = repoRoot
            .appendingPathComponent("docs/spec/mcp-domain-canonical-tool-definitions.generated.json")
        let updateMarker = repoRoot.appendingPathComponent(".build/update-mcp-domain-schema-review-snapshot")
        if FileManager.default.fileExists(atPath: updateMarker.path) {
            try generated.write(to: snapshotURL, options: .atomic)
            try FileManager.default.removeItem(at: updateMarker)
        }
        let committed = try Data(contentsOf: snapshotURL)
        XCTAssertEqual(
            committed,
            generated,
            "Regenerate the readable projection with the command recorded in its provenance block."
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: committed) as? [String: Any])
        let provenance = try XCTUnwrap(object["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["authority"] as? String, "generated-review-projection-only")
        XCTAssertEqual((object["tools"] as? [[String: Any]])?.count, 27)
    }

    func testShippingAppRegistrationUsesCanonicalTwentySevenSchemaFingerprints() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let expected = try Dictionary(uniqueKeysWithValues: MCPDomainCanonicalToolDefinitions.definitions.map {
            try ($0.name, MCPDomainToolFingerprint(definition: $0))
        })
        try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
        let registration = try await AppDomainRuntimeComposition.shared.register(
            window.mcpServer.windowMCPToolCatalogService
        )
        let snapshot = await AppDomainRuntimeComposition.shared.runtime.toolRegistry.snapshot()

        XCTAssertEqual(MCPDomainCanonicalToolDefinitions.definitions.count, 27)
        XCTAssertEqual(snapshot.fingerprintsByToolName, expected)
        XCTAssertEqual(Set(snapshot.toolNames), Set(MCPDomainToolCatalog.orderedToolNames))
        await AppDomainRuntimeComposition.shared.unregister(registration.handle)
    }

    func testLongRunningAppRegistrationPreservesTypedAuthoritativeRoutingDenial() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let registration = try await AppDomainRuntimeComposition.shared.register(
            window.mcpServer.windowMCPToolCatalogService
        )
        guard let resolved = await AppDomainRuntimeComposition.shared.resolve(
            toolName: MCPWindowToolName.askOracle,
            scope: .window(id: window.windowID)
        ) else {
            await AppDomainRuntimeComposition.shared.unregister(registration.handle)
            return XCTFail("Expected registered ask_oracle binding")
        }
        let runtimeIdentity = AppDomainRuntimeComposition.shared.runtime.identity
        let context = DomainToolInvocationSecurityContext(
            principal: .init(
                principalID: UUID(),
                stableKey: "m5-app-seam",
                displayName: "M5 app seam",
                kind: .runScoped,
                assurance: .verifiedProcess,
                processID: runtimeIdentity.processID,
                runID: UUID(),
                provider: "fixture",
                verifiedIdentityFingerprint: "m5-app-seam"
            ),
            connectionID: UUID(),
            connectionGeneration: 1,
            invocationID: UUID(),
            runtimeID: runtimeIdentity.runtimeID,
            runtimeGeneration: runtimeIdentity.lifecycleGeneration,
            hasAuthoritativeRoutingContext: false,
            ephemeralGrantedToolNames: [MCPWindowToolName.askOracle]
        )
        do {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(context) {
                try await resolved.binding(["message": .string("must not execute")])
            }
            XCTFail("Unrouted run-scoped AI work must fail before its physical provider")
        } catch {
            XCTAssertEqual(error as? DomainMutationPolicyError, .routingContextUnavailable)
        }
        await AppDomainRuntimeComposition.shared.unregister(registration.handle)
    }

    func testSharedReadCutoverPreservesUnmigratedFileActionsCatalogProjection() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let fileActions = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.fileActions })
        let projected = try fileActions.domainBinding().definition
        let schema = try XCTUnwrap(projected.inputSchema.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let operationID = try XCTUnwrap(properties["operation_id"]?.objectValue)
        let required = try XCTUnwrap(schema["required"]?.arrayValue?.compactMap(\.stringValue))

        XCTAssertFalse(
            MCPDomainReadToolDefinitions.definitions.contains { $0.name == MCPWindowToolName.fileActions },
            "file_actions must remain an app-owned legacy provider until its mutation milestone."
        )
        XCTAssertTrue(projected.description.contains("Create, delete, or move files."))
        XCTAssertEqual(
            operationID["description"]?.stringValue,
            "Optional caller-stable correlation ID echoed in the mutation acknowledgement; not a deduplication or status lookup key"
        )
        XCTAssertEqual(Set(required), ["action", "path"])
        XCTAssertEqual(projected.annotations.readOnlyHint, false)
        XCTAssertEqual(projected.annotations.destructiveHint, true)
        XCTAssertEqual(projected.isEnabledByDefault, true)
    }

    func testSharedReadBindingRetainsAppRuntimeExecutionEnvelope() async throws {
        let definition = try XCTUnwrap(
            MCPDomainReadToolDefinitions.definitions.first { $0.name == MCPWindowToolName.readFile }
        )
        let binding = MCPDomainToolBinding(definition: definition) { arguments in
            .object(["path": arguments["path"] ?? .null])
        }
        let recorder = SharedBindingRuntimeRecorder()
        let runtime = MCPAppToolBinder(windowID: 73) { name, freshnessPolicy, arguments, implementation in
            let providerManaged = if case .providerManaged = freshnessPolicy { true } else { false }
            await recorder.record(name: name, providerManaged: providerManaged, arguments: arguments)
            return try await implementation(
                MCPAppToolInvocation(toolName: name, windowID: 73),
                arguments
            )
        }
        let catalog = MCPAppToolCatalogRegistration(
            windowID: 73,
            providers: [],
            sharedBindings: [binding],
            runtime: runtime,
            requiredToolNames: [definition.name]
        )

        let tools = try catalog.materializeTools()
        let tool = try XCTUnwrap(tools.first)
        let value = try await tool(["path": .string("README.md")])
        let invocation = await recorder.snapshot()

        XCTAssertEqual(tool.name, MCPWindowToolName.readFile)
        XCTAssertEqual(value.objectValue?["path"]?.stringValue, "README.md")
        XCTAssertEqual(invocation?.name, MCPWindowToolName.readFile)
        XCTAssertEqual(invocation?.providerManaged, true)
        XCTAssertEqual(invocation?.arguments["path"]?.stringValue, "README.md")
    }

    func testReadinessCoalescesLightweightScopeQueriesForOneTenAndOneHundredWaiters() async throws {
        #if DEBUG
            for waiterCount in [1, 10, 100] {
                let queryProbe = MCPReadinessScopePresenceProbe()
                let joinedObservations = AsyncTestCondition<[Int?]>([])
                let readiness = MCPToolCatalogReadiness(
                    scopePresenceOperation: { requiredNames, scope in
                        await queryProbe.query(requiredNames: requiredNames, scope: scope)
                    },
                    windowStateOperation: { _ in
                        MCPToolCatalogReadiness.WindowRegistrationState(
                            toolsEnabled: true,
                            toolsRequested: true
                        )
                    },
                    checkJoinedOperation: { windowID in
                        joinedObservations.update { $0.append(windowID) }
                    }
                )

                let waiters = (0 ..< waiterCount).map { _ in
                    Task { await readiness.awaitReady(windowID: 901, timeout: 5) }
                }
                do {
                    try await AsyncTestWait.waitUntil("first readiness scope query", timeout: 3) {
                        await queryProbe.queryCount == 1
                    }
                    try await joinedObservations.waitUntil(
                        "\(waiterCount) readiness callers joining the shared check",
                        timeout: 3
                    ) { $0.count >= waiterCount }
                    let queriesWhileBlocked = await queryProbe.queryCount
                    XCTAssertEqual(
                        queriesWhileBlocked,
                        1,
                        "\(waiterCount) concurrent waiters must share the initial application-scope query."
                    )

                    await queryProbe.releaseFirstQuery()
                    for waiter in waiters {
                        let ready = await waiter.value
                        XCTAssertTrue(ready)
                    }
                    let finalQueryCount = await queryProbe.queryCount
                    XCTAssertEqual(
                        finalQueryCount,
                        2,
                        "Readiness should perform one application and one window scope-presence query regardless of waiter count."
                    )
                } catch {
                    waiters.forEach { $0.cancel() }
                    await queryProbe.releaseFirstQuery()
                    for waiter in waiters {
                        _ = await waiter.value
                    }
                    let observedCount = joinedObservations.snapshot().count
                    let queryCount = await queryProbe.queryCount
                    XCTFail(
                        "Readiness coalescing setup failed for \(waiterCount) waiters: \(error); "
                            + "joined=\(observedCount), queries=\(queryCount)"
                    )
                }
            }
        #else
            throw XCTSkip("Readiness operation-count probes require DEBUG test seams.")
        #endif
    }

    func testPresentationSummaryPublicationDoesNotReregisterActiveWindowCatalog() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = Self.makeWindowWithoutAutoStart()
                window.mcpServer.setServiceForTesting(MCPService(
                    controllerStartOperation: {},
                    controllerFullShutdownOperation: {}
                ))

                let enabled = await window.mcpServer.setWindowToolsEnabled(true)
                XCTAssertTrue(enabled)
                let generationBeforeSummary = window.mcpServer.windowToolRegistrationIntentGenerationForTesting()
                let fixtureToolName = "presentation_only_summary_\(UUID().uuidString)"
                ToolAvailabilityStore.shared.registerTools([
                    RepoPromptApp.Tool(
                        name: fixtureToolName,
                        description: "Presentation-only summary fixture.",
                        inputSchema: .object(properties: [:]),
                        returnsValue: { _ in .object([:]) }
                    )
                ])

                await Task { @MainActor in }.value
                let generationAfterSummary = window.mcpServer.windowToolRegistrationIntentGenerationForTesting()
                XCTAssertEqual(
                    generationAfterSummary,
                    generationBeforeSummary,
                    "Presentation summaries must not invalidate or re-register the window catalog."
                )

                ToolAvailabilityStore.shared.unregisterTools([fixtureToolName])
                _ = await window.mcpServer.setWindowToolsEnabled(false)
            }
        #else
            throw XCTSkip("Window registration intent inspection is DEBUG-only.")
        #endif
    }

    func testProviderCatalogExecutesOneAppRuntimeEnvelopePerCall() async throws {
        let definition = try XCTUnwrap(
            MCPDomainReadToolDefinitions.definitions.first { $0.name == MCPWindowToolName.readFile }
        )
        let recorder = SharedBindingRuntimeRecorder()
        let runtime = MCPAppToolBinder(windowID: 74) { name, freshnessPolicy, arguments, implementation in
            let providerManaged = if case .providerManaged = freshnessPolicy { true } else { false }
            await recorder.record(name: name, providerManaged: providerManaged, arguments: arguments)
            return try await implementation(
                MCPAppToolInvocation(toolName: name, windowID: 74),
                arguments
            )
        }
        let provider = SingleEnvelopeToolProvider(runtime: runtime, definition: definition)
        let catalog = MCPAppToolCatalogRegistration(
            windowID: 74,
            providers: [provider],
            runtime: runtime,
            requiredToolNames: [definition.name]
        )

        let tool = try XCTUnwrap(try catalog.materializeTools().first)
        _ = try await tool(["path": .string("README.md")])

        let invocationCount = await recorder.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testAppCatalogRejectsDuplicateProviderToolsWithoutTrapping() throws {
        let definition = try XCTUnwrap(
            MCPDomainReadToolDefinitions.definitions.first { $0.name == MCPWindowToolName.readFile }
        )
        let runtime = MCPAppToolBinder(windowID: 75) { _, _, arguments, implementation in
            try await implementation(
                MCPAppToolInvocation(toolName: MCPWindowToolName.readFile, windowID: 75),
                arguments
            )
        }
        let catalog = MCPAppToolCatalogRegistration(
            windowID: 75,
            providers: [
                SingleEnvelopeToolProvider(runtime: runtime, definition: definition),
                SingleEnvelopeToolProvider(runtime: runtime, definition: definition)
            ],
            runtime: runtime,
            requiredToolNames: [definition.name]
        )

        XCTAssertThrowsError(try catalog.materializeTools()) { error in
            XCTAssertEqual(
                error as? MCPAppToolCatalogMaterializationError,
                .duplicateTool(MCPWindowToolName.readFile)
            )
        }
    }

    func testAppCatalogRejectsMissingCanonicalTools() async throws {
        let definition = try XCTUnwrap(
            MCPDomainReadToolDefinitions.definitions.first { $0.name == MCPWindowToolName.readFile }
        )
        let runtime = MCPAppToolBinder(windowID: 76) { _, _, arguments, implementation in
            try await implementation(
                MCPAppToolInvocation(toolName: MCPWindowToolName.readFile, windowID: 76),
                arguments
            )
        }
        let catalog = MCPAppToolCatalogRegistration(
            windowID: 76,
            providers: [SingleEnvelopeToolProvider(runtime: runtime, definition: definition)],
            runtime: runtime
        )

        XCTAssertThrowsError(try catalog.materializeTools()) { error in
            guard case let .missingCanonicalTools(names) = error as? MCPAppToolCatalogMaterializationError else {
                return XCTFail("Expected missing canonical tool failure, got \(error)")
            }
            XCTAssertFalse(names.isEmpty)
            XCTAssertFalse(names.contains(MCPWindowToolName.readFile))
        }

        let compatibilityProjection = await catalog.tools
        XCTAssertTrue(compatibilityProjection.isEmpty)
        XCTAssertNotNil(catalog.materializationErrorDescription)
    }

    func testMCPServiceWindowAttachmentDoesNotControlProcessTransportLifetime() async throws {
        let startProbe = ControlledMCPServiceStartProbe(outcomes: [.success])
        let teardownProbe = ControlledMCPServiceTeardownProbe(attempts: 1)
        let service = MCPService(
            controllerStartOperation: { try await startProbe.start() },
            controllerFullShutdownOperation: { await teardownProbe.tearDown() }
        )

        let explicitStart = Task { try await service.start() }
        await startProbe.waitUntilAttemptCount(1)
        await startProbe.releaseAttempt(1)
        try await explicitStart.value

        await service.join(windowID: 101)
        await service.leave(windowID: 101)
        await service.join(windowID: 102)
        let startCount = await startProbe.attemptCount
        let runningAfterDetach = await service.currentState().isRunning
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(runningAfterDetach)

        let shutdown = Task { await service.fullShutdown() }
        await teardownProbe.waitUntilAttemptCount(1)
        await teardownProbe.releaseAttempt(1)
        await shutdown.value
        let runningAfterShutdown = await service.currentState().isRunning
        XCTAssertFalse(runningAfterShutdown)

        await service.join(windowID: 103)
        let startCountAfterReattach = await startProbe.attemptCount
        let runningAfterReattach = await service.currentState().isRunning
        let joinedWindows = await service.joinedWindowIDsForTesting()
        XCTAssertEqual(startCountAfterReattach, 1)
        XCTAssertFalse(runningAfterReattach)
        XCTAssertEqual(joinedWindows, Set([102, 103]))
    }

    func testServerControllerAwaitsGlobalRegistrationAndFencesSupersededStart() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = Self.makeWindowWithoutAutoStart()
                try await Self.withIsolatedBootstrapSocketNamespace(window: window) { _ in
                    let orderingProbe = ServerControllerRegistrationOrderingProbe()
                    let controller = ServerController(
                        globalRegistrationOperation: { try await orderingProbe.register() },
                        beforeTransportActivationOperation: { try await orderingProbe.assertCompleted() },
                        installNetworkCallbacks: false
                    )
                    let start = Task { try await controller.startServer() }
                    let registrationEntered = await orderingProbe.waitUntilEntered()
                    XCTAssertTrue(registrationEntered, "ServerController.startServer must invoke global registration.")

                    let blockedState = await ServerNetworkManager.shared.debugTransportState()
                    XCTAssertFalse(blockedState.isRunning, "Transport must remain stopped while global registration is suspended.")
                    await orderingProbe.release()
                    try await start.value

                    let runningState = await ServerNetworkManager.shared.debugTransportState()
                    XCTAssertTrue(runningState.isRunning)
                    let catalog = await AppDomainRuntimeComposition.shared.catalogSnapshot()
                    XCTAssertTrue(MCPGlobalToolName.orderedToolNames.allSatisfy { toolName in
                        catalog.activeScopesByToolName[toolName]?.contains(.application) == true
                    })

                    await controller.fullShutdown()
                    let supersessionProbe = ServerControllerRegistrationOrderingProbe()
                    let supersededController = ServerController(
                        globalRegistrationOperation: { try await supersessionProbe.register() },
                        beforeTransportActivationOperation: { try await supersessionProbe.assertCompleted() },
                        installNetworkCallbacks: false
                    )
                    let supersededStart = Task { try await supersededController.startServer() }
                    let supersessionEntered = await supersessionProbe.waitUntilEntered()
                    XCTAssertTrue(supersessionEntered, "Supersession coverage requires registration to be in flight.")
                    await supersededController.fullShutdown()
                    await supersessionProbe.release()
                    do {
                        try await supersededStart.value
                        XCTFail("A full shutdown must supersede registration-blocked startup.")
                    } catch ServerController.LifecycleError.startSuperseded {
                        // Expected.
                    }
                    let stoppedState = await ServerNetworkManager.shared.debugTransportState()
                    XCTAssertFalse(stoppedState.isRunning)
                }
            }
        #else
            throw XCTSkip("Server controller ordering probes require DEBUG lifecycle isolation.")
        #endif
    }

    func testServerControllerSetEnabledUsesOrderedSingleFlightAndPropagatesFailure() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = Self.makeWindowWithoutAutoStart()
                try await Self.withIsolatedBootstrapSocketNamespace(window: window) { _ in
                    let orderingProbe = ServerControllerRegistrationOrderingProbe()
                    let controller = ServerController(
                        globalRegistrationOperation: { try await orderingProbe.register() },
                        beforeTransportActivationOperation: { try await orderingProbe.assertCompleted() },
                        installNetworkCallbacks: false
                    )
                    let enable = Task { try await controller.setEnabled(true) }
                    let orderingEntered = await orderingProbe.waitUntilEntered()
                    XCTAssertTrue(orderingEntered)
                    let blockedState = await ServerNetworkManager.shared.debugTransportState()
                    XCTAssertFalse(blockedState.isRunning)
                    await orderingProbe.release()
                    try await enable.value
                    let orderedCounts = await orderingProbe.counts()
                    XCTAssertEqual(orderedCounts.registration, 1)
                    XCTAssertEqual(orderedCounts.preActivation, 1)

                    await controller.fullShutdown()
                    let failureProbe = ServerControllerRegistrationOrderingProbe(failsRegistration: true)
                    let failingController = ServerController(
                        globalRegistrationOperation: { try await failureProbe.register() },
                        beforeTransportActivationOperation: { try await failureProbe.assertCompleted() },
                        installNetworkCallbacks: false
                    )
                    let failedEnable = Task { try await failingController.setEnabled(true) }
                    let failureEntered = await failureProbe.waitUntilEntered()
                    XCTAssertTrue(failureEntered)
                    await failureProbe.release()
                    do {
                        try await failedEnable.value
                        XCTFail("setEnabled(true) must surface global registration failure.")
                    } catch ServerControllerRegistrationOrderingProbe.Failure.injected {
                        // Expected.
                    }
                    let failureCounts = await failureProbe.counts()
                    let stoppedState = await ServerNetworkManager.shared.debugTransportState()
                    XCTAssertEqual(failureCounts.registration, 1)
                    XCTAssertEqual(failureCounts.preActivation, 0)
                    XCTAssertFalse(stoppedState.isRunning)
                }
            }
        #else
            throw XCTSkip("Server controller ordering probes require DEBUG lifecycle isolation.")
        #endif
    }

    func testServerControllerSetEnabledReenablesColdTransportAfterDisableAndFullShutdown() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = Self.makeWindowWithoutAutoStart()
                try await Self.withIsolatedBootstrapSocketNamespace(window: window) { _ in
                    let controller = ServerController(
                        globalRegistrationOperation: {},
                        beforeTransportActivationOperation: {},
                        installNetworkCallbacks: false
                    )

                    try await controller.setEnabled(true)
                    try await controller.setEnabled(false)
                    let disabledState = await ServerNetworkManager.shared.debugTransportState()
                    XCTAssertTrue(disabledState.isRunning)
                    XCTAssertFalse(disabledState.isEnabled)

                    await controller.fullShutdown()
                    let stoppedState = await ServerNetworkManager.shared.debugTransportState()
                    XCTAssertFalse(stoppedState.isRunning)
                    XCTAssertFalse(stoppedState.isEnabled)

                    try await controller.setEnabled(true)
                    let restartedState = await ServerNetworkManager.shared.debugTransportState()
                    XCTAssertTrue(restartedState.isRunning)
                    XCTAssertTrue(
                        restartedState.isEnabled,
                        "A cold restart must clear the disabled flag before exposing the transport."
                    )

                    await controller.fullShutdown()
                }
            }
        #else
            throw XCTSkip("Server controller transport-state inspection is DEBUG-only.")
        #endif
    }

    func testRequestedWindowRegistrationDoesNotStartProcessTransport() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = Self.makeWindowWithoutAutoStart()
                let startProbe = ControlledMCPServiceStartProbe(outcomes: [.success])
                let service = MCPService(
                    controllerStartOperation: { try await startProbe.start() },
                    controllerFullShutdownOperation: {}
                )
                window.mcpServer.setServiceForTesting(service)
                WindowStatesManager.shared.registerWindowState(window)

                let bootstrapReady = await window.mcpServer.ensureServerReadyForAgentBootstrap()
                XCTAssertTrue(bootstrapReady)
                XCTAssertTrue(window.mcpServer.windowToolsAreRequested)
                XCTAssertTrue(window.mcpServer.windowToolsEnabled)
                XCTAssertNil(window.mcpServer.windowToolRegistrationFailureDescription)
                let startAttemptCount = await startProbe.attemptCount
                let serviceIsRunning = await service.currentState().isRunning
                XCTAssertEqual(startAttemptCount, 0)
                XCTAssertFalse(serviceIsRunning)
                let ready = await MCPToolCatalogReadiness.shared.awaitReady(
                    windowID: window.windowID,
                    timeout: 0.2
                )
                XCTAssertTrue(ready)

                await window.mcpServer.stopServer()
                WindowStatesManager.shared.unregisterWindowState(window)
            }
        #else
            throw XCTSkip("Window registration ownership probes require DEBUG service injection.")
        #endif
    }

    func testSupersededEnableRetainsRegistrationForDisableAndUniqueWindowRouting() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
                await Self.purgeStaleWindowScopeRegistrations()

                let supersededWindow = Self.makeWindowWithoutAutoStart()
                supersededWindow.mcpServer.setServiceForTesting(MCPService(
                    controllerStartOperation: {},
                    controllerFullShutdownOperation: {}
                ))
                WindowStatesManager.shared.registerWindowState(supersededWindow)

                let registrationGate = AsyncTestGate()
                supersededWindow.mcpServer.setAfterWindowToolRegistrationBeforeRetentionForTesting {
                    await registrationGate.arriveAndWait()
                }
                let firstEnable = Task { @MainActor in
                    await supersededWindow.mcpServer.setWindowToolsEnabled(true)
                }
                let registrationSuspended = await registrationGate.waitUntilEntered(timeout: .seconds(2))
                XCTAssertTrue(registrationSuspended, "The first enable must suspend after registering its generation.")

                let supersedingEnable = Task { @MainActor in
                    await supersededWindow.mcpServer.setWindowToolsEnabled(true)
                }
                let secondIntentObserved = await Self.waitForWindowToolIntentGeneration(
                    2,
                    window: supersededWindow
                )
                XCTAssertTrue(secondIntentObserved)

                let disabling = Task { @MainActor in
                    await supersededWindow.mcpServer.stopServer()
                }
                let disableIntentObserved = await Self.waitForWindowToolIntentGeneration(
                    3,
                    window: supersededWindow
                )
                XCTAssertTrue(disableIntentObserved)

                await registrationGate.release()
                let firstEnableResult = await firstEnable.value
                let supersedingEnableResult = await supersedingEnable.value
                await disabling.value
                XCTAssertFalse(firstEnableResult)
                XCTAssertFalse(supersedingEnableResult)
                supersededWindow.mcpServer.setAfterWindowToolRegistrationBeforeRetentionForTesting(nil)

                let supersededScope = MCPDomainToolRegistrationScope.window(id: supersededWindow.windowID)
                let afterDisable = await AppDomainRuntimeComposition.shared.catalogSnapshot()
                XCTAssertFalse(
                    afterDisable.activeScopesByToolName[MCPWindowToolName.readFile]?.contains(supersededScope) == true,
                    "The disable must reclaim the generation registered by the superseded enable."
                )

                supersededWindow.beginClose()
                await supersededWindow.tearDown()
                WindowStatesManager.shared.unregisterWindowState(supersededWindow)

                let liveWindow = Self.makeWindowWithoutAutoStart()
                WindowStatesManager.shared.registerWindowState(liveWindow)
                let liveRegistration: MCPDomainToolRegistrationResult
                do {
                    liveRegistration = try await AppDomainRuntimeComposition.shared.register(
                        liveWindow.mcpServer.windowMCPToolCatalogService
                    )
                } catch {
                    liveWindow.beginClose()
                    await liveWindow.tearDown()
                    WindowStatesManager.shared.unregisterWindowState(liveWindow)
                    throw error
                }
                guard liveRegistration.disposition == .inserted else {
                    liveWindow.beginClose()
                    await liveWindow.tearDown()
                    WindowStatesManager.shared.unregisterWindowState(liveWindow)
                    throw ToolCatalogFixtureError.windowCatalogRegistrationWasNotOwned(
                        String(describing: liveRegistration.disposition)
                    )
                }

                let uniqueReadFile = await AppDomainRuntimeComposition.shared.resolve(
                    toolName: MCPWindowToolName.readFile,
                    scope: .window(id: liveWindow.windowID)
                )
                XCTAssertEqual(
                    uniqueReadFile?.handle,
                    liveRegistration.handle,
                    "A closed superseded window must not poison single-window routing."
                )

                // The fixture owns this exact generation; release it before window teardown.
                await AppDomainRuntimeComposition.shared.unregister(liveRegistration.handle)
                liveWindow.beginClose()
                await liveWindow.tearDown()
                WindowStatesManager.shared.unregisterWindowState(liveWindow)
            }
        #else
            throw XCTSkip("Window registration supersession inspection is DEBUG-only")
        #endif
    }

    func testWindowStopWithoutOwnedHandlePreservesExternalRegistrationGeneration() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = Self.makeWindowWithoutAutoStart()
                let registration: MCPDomainToolRegistrationResult
                do {
                    registration = try await AppDomainRuntimeComposition.shared.register(
                        window.mcpServer.windowMCPToolCatalogService
                    )
                } catch {
                    await window.tearDown()
                    throw error
                }
                guard registration.disposition == .inserted else {
                    await window.tearDown()
                    throw ToolCatalogFixtureError.windowCatalogRegistrationWasNotOwned(
                        String(describing: registration.disposition)
                    )
                }

                await window.mcpServer.stopServer()
                let externalRegistrationIsActive = await AppDomainRuntimeComposition.shared.isActive(registration.handle)
                XCTAssertTrue(
                    externalRegistrationIsActive,
                    "A window without the generation handle must not unregister an external participant."
                )

                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                await window.tearDown()
                let externalRegistrationIsActiveAfterCleanup = await AppDomainRuntimeComposition.shared.isActive(registration.handle)
                XCTAssertFalse(externalRegistrationIsActiveAfterCleanup)
            }
        #else
            throw XCTSkip("Window registration ownership inspection is DEBUG-only")
        #endif
    }

    func testDomainRegistrationReregistrationPreservesLiveHandleAndSurfacesFailures() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                await Self.purgeStaleWindowScopeRegistrations()
                let window = Self.makeWindowWithoutAutoStart()
                try await Self.withIsolatedBootstrapSocketNamespace(window: window) { _ in
                    let before = await AppDomainRuntimeComposition.shared.catalogSnapshot()

                    XCTAssertFalse(window.mcpServer.windowToolsEnabled)
                    let serverStarted = await window.mcpServer.startServer()
                    XCTAssertTrue(serverStarted)
                    XCTAssertTrue(window.mcpServer.windowToolsEnabled)

                    let afterInitialStart = await AppDomainRuntimeComposition.shared.catalogSnapshot()
                    let resolved = await AppDomainRuntimeComposition.shared.resolve(
                        toolName: MCPWindowToolName.readFile,
                        scope: .window(id: window.windowID)
                    )
                    let captured = try XCTUnwrap(resolved)
                    let bootstrapReady = await window.mcpServer.ensureServerReadyForAgentBootstrap()
                    let afterRepeat = await AppDomainRuntimeComposition.shared.catalogSnapshot()

                    XCTAssertTrue(bootstrapReady)
                    let capturedHandleIsActive = await AppDomainRuntimeComposition.shared.isActive(captured.handle)
                    XCTAssertTrue(capturedHandleIsActive, "An in-flight call handle must survive byte-identical bootstrap re-registration")
                    XCTAssertGreaterThan(afterInitialStart.revision, before.revision)
                    XCTAssertEqual(
                        afterRepeat.revision,
                        afterInitialStart.revision,
                        "Byte-identical bootstrap must preserve handles and catalog revision."
                    )

                    let disabling = Task { @MainActor in
                        await window.mcpServer.stopServer()
                    }
                    await Task.yield()
                    let reenabled = await window.mcpServer.startServer()
                    await disabling.value
                    let reenabledTool = await AppDomainRuntimeComposition.shared.resolve(
                        toolName: MCPWindowToolName.readFile,
                        scope: .window(id: window.windowID)
                    )
                    XCTAssertTrue(reenabled)
                    XCTAssertTrue(window.mcpServer.windowToolsEnabled)
                    XCTAssertNotNil(reenabledTool, "A superseded disable must not remove the newer enable registration")

                    do {
                        _ = try await AppDomainRuntimeComposition.shared.register(UnknownCatalogToolService())
                        XCTFail("Unknown canonical tools must surface registration failure")
                    } catch let error as MCPDomainToolRegistryError {
                        XCTAssertEqual(error, .unknownToolName("unknown_catalog_tool"))
                    }
                }
            }
        #else
            throw XCTSkip("Bootstrap socket isolation is DEBUG-only")
        #endif
    }

    func testAppDelegateTerminationInvokesDomainRuntimeShutdownSeam() async {
        let probe = AppDelegateTerminationProbe()
        let appDelegate = AppDelegate()
        appDelegate.setDomainRuntimeShutdownOperationForTesting {
            await probe.shutdown()
        }

        await appDelegate.shutdownDomainRuntimeForTerminationForTesting()

        XCTAssertEqual(probe.invocationCount, 1)
    }

    func testAppDelegateStartupPublishesGlobalRegistrationBeforeObservationOnlyReadiness() async {
        let wiringProbe = AppDelegateRegistrationProbe()
        let wiringDelegate = AppDelegate()
        wiringDelegate.setGlobalMCPRegistrationOperationForTesting {
            try await wiringProbe.register()
        }
        let wiringTasks = (0 ..< 8).map { _ in
            wiringDelegate.startGlobalMCPServiceRegistration()
        }
        for wiringTask in wiringTasks {
            await wiringTask.value
        }
        XCTAssertEqual(wiringProbe.invocationCount, 1)
        XCTAssertNil(wiringDelegate.domainRuntimeStartupFailureDescription)

        let failureProbe = AppDelegateRegistrationProbe(failure: .injected)
        let failureDelegate = AppDelegate()
        failureDelegate.setGlobalMCPRegistrationOperationForTesting {
            try await failureProbe.register()
        }
        await failureDelegate.startGlobalMCPServiceRegistration().value
        await failureDelegate.startGlobalMCPServiceRegistration().value
        XCTAssertEqual(failureProbe.invocationCount, 1, "A stored startup failure must not retry or log per caller.")
        XCTAssertNotNil(failureDelegate.domainRuntimeStartupFailureDescription)

        let appDelegate = AppDelegate()
        await appDelegate.startGlobalMCPServiceRegistration().value
        XCTAssertNil(appDelegate.domainRuntimeStartupFailureDescription)
        XCTAssertEqual(
            AppGlobalMCPServiceComposition.shared.registrationStatus(),
            .registered
        )

        let snapshot = await AppDomainRuntimeComposition.shared.catalogSnapshot()
        XCTAssertTrue(
            MCPGlobalToolName.orderedToolNames.allSatisfy { toolName in
                snapshot.activeScopesByToolName[toolName]?.contains(.application) == true
            },
            "AppDelegate startup must publish every application-scoped tool before readiness observes it."
        )
        XCTAssertTrue(
            MCPGlobalToolName.orderedToolNames.allSatisfy { toolName in
                ToolAvailabilityStore.shared.toolSummaries.contains { $0.name == toolName }
            },
            "Composition-owned availability must remain published with the canonical catalog."
        )
        let globallyReady = await MCPToolCatalogReadiness.shared.awaitReady(windowID: nil, timeout: 1)
        XCTAssertTrue(globallyReady)

        let timeout: TimeInterval = 0.2
        let readinessRevision = snapshot.revision
        let start = Date()
        let missingWindowReady = await MCPToolCatalogReadiness.shared.awaitReady(
            windowID: Int.min,
            timeout: timeout
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(missingWindowReady, "A missing window must remain fail-closed.")
        let afterMissingWindowReadiness = await AppDomainRuntimeComposition.shared.catalogSnapshot()
        XCTAssertEqual(
            afterMissingWindowReadiness.revision,
            readinessRevision,
            "Observation-only readiness must not mutate or repair registration."
        )
        XCTAssertGreaterThanOrEqual(elapsed, timeout * 0.85, "Readiness must retain the full recovery window.")
        XCTAssertLessThan(elapsed, timeout + 0.75, "Readiness must remain bounded.")

        let cancellationStart = Date()
        let cancelledReadiness = Task {
            await MCPToolCatalogReadiness.shared.awaitReady(windowID: Int.min, timeout: 5)
        }
        cancelledReadiness.cancel()
        let cancelledReady = await cancelledReadiness.value
        XCTAssertFalse(cancelledReady)
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStart), 0.5, "Cancellation must not consume the timeout window.")
    }

    func testAgentRunRespondSchemaAdvertisesCanonicalScalarResponseOnly() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let agentRun = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun })
        let schema = try XCTUnwrap(Value(agentRun.inputSchema).objectValue)
        let properties = try Self.schemaProperties(for: agentRun)
        let response = try XCTUnwrap(properties["response"]?.objectValue)
        let responseDescription = try XCTUnwrap(response["description"]?.stringValue)
        let required = try XCTUnwrap(schema["required"]?.arrayValue?.compactMap(\.stringValue))

        XCTAssertEqual(response["type"]?.stringValue, "string")
        XCTAssertTrue(responseDescription.contains("top-level scalar string"), responseDescription)
        XCTAssertTrue(responseDescription.contains("response=\"accept\""), responseDescription)
        XCTAssertTrue(responseDescription.contains("decision and nested response objects are unsupported"), responseDescription)
        XCTAssertNil(properties["decision"])
        XCTAssertEqual(required, ["op"])
        XCTAssertTrue(agentRun.description.contains("response=\"accept\""), agentRun.description)
    }

    func testLifecycleSchemasAdvertiseConfigurableDefaultsWithoutMaximumClamp() async throws {
        do {
            let caseLabel = "testAgentLifecycleSchemasAdvertiseTwoMinuteDefaultsWithoutMaximumClamp"
            let window = Self.makeWindowWithoutAutoStart()
            let tools = await window.mcpServer.windowMCPTools
            let agentExplore = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentExplore }, caseLabel)
            let agentRun = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun }, caseLabel)

            let exploreTimeout = try XCTUnwrap(
                Self.schemaProperties(for: agentExplore, label: caseLabel)["timeout"]?.objectValue?["description"]?.stringValue,
                caseLabel
            )
            let runProperties = try Self.schemaProperties(for: agentRun, label: caseLabel)
            let runTimeout = try XCTUnwrap(runProperties["timeout"]?.objectValue?["description"]?.stringValue, caseLabel)
            let steerTimeout = try XCTUnwrap(runProperties["timeout_seconds"]?.objectValue?["description"]?.stringValue, caseLabel)

            let defaultText = "Default \(Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds))."
            for description in [exploreTimeout, runTimeout, steerTimeout] {
                XCTAssertTrue(description.contains(defaultText), caseLabel + ": " + description)
                XCTAssertFalse(description.lowercased().contains("maximum"), caseLabel + ": " + description)
            }
        }

        do {
            let caseLabel = "testInteractiveLifecycleSchemasPreserveConfigurableWaitsWithoutMaximumClamp"
            let window = Self.makeWindowWithoutAutoStart()
            let tools = await window.mcpServer.windowMCPTools
            let askUser = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.askUser }, caseLabel)
            let waitForNextInstruction = try XCTUnwrap(
                tools.first { $0.name == MCPWindowToolName.waitForNextInstruction },
                caseLabel
            )

            let askUserTimeout = try XCTUnwrap(
                Self.schemaProperties(for: askUser, label: caseLabel)["timeout_seconds"]?.objectValue?["description"]?.stringValue,
                caseLabel
            )
            let instructionTimeout = try XCTUnwrap(
                Self.schemaProperties(for: waitForNextInstruction, label: caseLabel)["timeout_seconds"]?.objectValue?["description"]?.stringValue,
                caseLabel
            )

            XCTAssertTrue(askUserTimeout.contains("global Question Timeout preference"), caseLabel + ": " + askUserTimeout)
            XCTAssertTrue(
                instructionTimeout.contains(
                    "Default \(Int(MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds))."
                ),
                caseLabel + ": " + instructionTimeout
            )
            XCTAssertFalse(askUserTimeout.lowercased().contains("maximum"), caseLabel + ": " + askUserTimeout)
            XCTAssertFalse(instructionTimeout.lowercased().contains("maximum"), caseLabel + ": " + instructionTimeout)
        }
    }

    func testCodexAnnotationProjectionPreservesCanonicalMetadataAcrossIdentityMatrix() async {
        do {
            let caseLabel = "testCanonicalReadOnlyAnnotationsRemainTruthfulOutsideCodexProjection"
            let window = Self.makeWindowWithoutAutoStart()
            let tools = await window.mcpServer.windowMCPTools
            let canonicalReadOnlyTools = tools.filter { $0.annotations.readOnlyHint == true }

            XCTAssertFalse(canonicalReadOnlyTools.isEmpty, caseLabel)
            XCTAssertTrue(canonicalReadOnlyTools.allSatisfy { $0.annotations.readOnlyHint == true }, caseLabel)
            XCTAssertTrue(
                canonicalReadOnlyTools.allSatisfy {
                    CodexMCPToolAnnotationProjection.project(
                        $0.annotations,
                        clientIdentifier: "generic-mcp-client"
                    ) == $0.annotations
                },
                caseLabel
            )
        }

        do {
            let caseLabel = "testCodexProjectionClearsOnlyReadOnlyHintForPositiveCodexIdentity"
            let canonical = MCP.Tool.Annotations(
                title: "Read workspace",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
            let codexIdentities: [String?] = [
                "codex-mcp-client",
                "Codex MCP Client",
                "codex-mcp-client/1.2.3",
                "codex-mcp-client-v2"
            ]

            for identity in codexIdentities {
                let projected = CodexMCPToolAnnotationProjection.project(
                    canonical,
                    clientIdentifier: identity
                )
                let identityLabel = caseLabel + ": " + (identity ?? "nil")
                XCTAssertNil(projected.readOnlyHint, identityLabel)
                XCTAssertEqual(projected.title, canonical.title, identityLabel)
                XCTAssertEqual(projected.destructiveHint, canonical.destructiveHint, identityLabel)
                XCTAssertEqual(projected.idempotentHint, canonical.idempotentHint, identityLabel)
                XCTAssertEqual(projected.openWorldHint, canonical.openWorldHint, identityLabel)
            }

            for readOnlyHint in [false, nil] as [Bool?] {
                XCTAssertNil(
                    CodexMCPToolAnnotationProjection.project(
                        MCP.Tool.Annotations(
                            title: canonical.title,
                            readOnlyHint: readOnlyHint,
                            destructiveHint: canonical.destructiveHint,
                            idempotentHint: canonical.idempotentHint,
                            openWorldHint: canonical.openWorldHint
                        ),
                        clientIdentifier: "codex-mcp-client"
                    ).readOnlyHint,
                    caseLabel + ": \(String(describing: readOnlyHint))"
                )
            }

            XCTAssertEqual(canonical.readOnlyHint, true, caseLabel + ": Projection must not mutate canonical catalog metadata.")
        }

        do {
            let caseLabel = "testCodexProjectionPreservesMetadataForMissingAmbiguousAndNonCodexIdentities"
            let canonical = MCP.Tool.Annotations(
                title: "Read workspace",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
            let identities: [String?] = [
                nil,
                "",
                "codex",
                "codex-client",
                "codex-wrapper-beta",
                "claude-code",
                "repoprompt-cli"
            ]

            for identity in identities {
                XCTAssertEqual(
                    CodexMCPToolAnnotationProjection.project(
                        canonical,
                        clientIdentifier: identity
                    ),
                    canonical,
                    caseLabel + ": " + (identity ?? "nil")
                )
            }
        }
    }

    func testProductionRegistrationUsesCatalogServiceNotViewModel() async throws {
        #if DEBUG
            XCTAssertTrue(AppLaunchConfiguration.debugBuildForcesMCPAutoStart(
                bundleURL: URL(fileURLWithPath: "/tmp/RepoPrompt.app", isDirectory: true)
            ))
            XCTAssertFalse(AppLaunchConfiguration.debugBuildForcesMCPAutoStart(
                bundleURL: URL(fileURLWithPath: "/tmp/RepoPromptTests.xctest", isDirectory: true)
            ))
            XCTAssertFalse(AppLaunchConfiguration.debugBuildForcesMCPAutoStart(
                bundleURL: URL(fileURLWithPath: "/tmp/RepoPrompt.app", isDirectory: true),
                arguments: ["-RP_UITEST"]
            ))
            XCTAssertFalse(AppLaunchConfiguration.debugBuildForcesMCPAutoStart(
                bundleURL: URL(fileURLWithPath: "/tmp/RepoPrompt.app", isDirectory: true),
                environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
            ))

            try await MCPSharedServerTestLease.shared.withLease { _ in
                await Self.purgeStaleWindowScopeRegistrations()
                let window = Self.makeWindowWithoutAutoStart()
                let catalogService = window.mcpServer.windowMCPToolCatalogService

                try await Self.withIsolatedBootstrapSocketNamespace(window: window) { socketURL in
                    let storedAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
                    let started = await window.mcpServer.ensureServerReadyForAgentBootstrap()
                    XCTAssertTrue(started)
                    XCTAssertEqual(GlobalSettingsStore.shared.mcpAutoStart(), storedAutoStart)
                    let catalogIsRegistered = await AppDomainRuntimeComposition.shared.isRegistered(catalogService)
                    let catalog = await AppDomainRuntimeComposition.shared.catalogSnapshot()
                    XCTAssertTrue(catalogIsRegistered)
                    XCTAssertTrue(MCPGlobalToolName.orderedToolNames.allSatisfy { toolName in
                        catalog.activeScopesByToolName[toolName]?.contains(.application) == true
                    })
                    let windowScope = MCPDomainToolRegistrationScope.window(id: window.windowID)
                    XCTAssertTrue(MCPAppToolGroup.orderedToolNames.allSatisfy { toolName in
                        catalog.activeScopesByToolName[toolName]?.contains(windowScope) == true
                    })
                    XCTAssertFalse(catalog.definitions.isEmpty)
                    XCTAssertEqual(
                        catalog.activeScopesByToolName[MCPWindowToolName.readFile],
                        [windowScope],
                        "read_file must have exactly one authoritative registration scope"
                    )

                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: socketURL.path),
                        "Window catalog registration must not start the process-owned bootstrap transport."
                    )
                    let transportState = await window.mcpServer.service.currentState()
                    XCTAssertFalse(transportState.isRunning)
                }
            }
        #else
            throw XCTSkip("Bootstrap socket URL override seam is DEBUG-only")
        #endif
    }

    func testWorktreePublicAPISchemaFieldsRemainAdvertised() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let manageWorktree = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.manageWorktree })
        let agentExplore = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentExplore })
        let agentRun = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun })

        let manageProperties = try Self.schemaProperties(for: manageWorktree)
        for field in [
            "include_graph",
            "graph_limit",
            "worktree",
            "worktree_id",
            "session_id",
            "persist_visuals",
            "marker_style",
            "bind"
        ] {
            XCTAssertNotNil(manageProperties[field], "manage_worktree schema should advertise property \(field)")
        }
        let manageOpEnum = manageProperties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(manageOpEnum.contains("list"))
        XCTAssertTrue(manageOpEnum.contains("create"))
        XCTAssertTrue(manageOpEnum.contains("bind"))

        for field in [
            "operation_id",
            "target",
            "target_worktree_id",
            "confirm_preview",
            "confirm",
            "publish_artifacts",
            "context_lines",
            "detect_renames"
        ] {
            XCTAssertNotNil(manageProperties[field], "manage_worktree schema should advertise merge property \(field)")
        }
        XCTAssertTrue(manageOpEnum.contains("preview"))
        XCTAssertTrue(manageOpEnum.contains("apply"))
        XCTAssertTrue(manageOpEnum.contains("status"))
        XCTAssertTrue(manageOpEnum.contains("continue"))
        XCTAssertTrue(manageOpEnum.contains("abort"))

        let agentExploreProperties = try Self.schemaProperties(for: agentExplore)
        let agentRunProperties = try Self.schemaProperties(for: agentRun)
        let worktreeFields = [
            "worktree",
            "worktree_id",
            "worktree_create",
            "worktree_repo_root",
            "worktree_branch",
            "worktree_base_ref",
            "worktree_path",
            "worktree_label",
            "worktree_color",
            "allow_external_worktree_path",
            "inherit_worktree"
        ]
        for field in worktreeFields {
            XCTAssertNotNil(agentRunProperties[field], "agent_run schema should advertise property \(field)")
            XCTAssertNotNil(agentExploreProperties[field], "agent_explore schema should advertise property \(field)")
        }
        #if DEBUG
            XCTAssertNotNil(agentRunProperties["_worktree_startup_benchmark_token"])
            XCTAssertNil(agentExploreProperties["_worktree_startup_benchmark_token"])
        #endif

        let exploreOpEnum = agentExploreProperties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(exploreOpEnum, ["start", "poll", "wait", "cancel"])
        for field in [
            "model_id",
            "workflow_id",
            "workflow_name",
            "session_name",
            "wait",
            "timeout_seconds",
            "interaction_id",
            "response",
            "answers",
            "content",
            "meta",
            "amendment"
        ] {
            XCTAssertNil(agentExploreProperties[field], "agent_explore schema must not advertise run-only property \(field)")
        }
    }

    private enum ToolCatalogFixtureError: Error {
        case windowCatalogRegistrationWasNotOwned(String)
    }

    private final class UnknownCatalogToolService: Service {
        let domainRegistrationID = MCPDomainToolRegistrationID()

        var tools: [RepoPromptApp.Tool] {
            get async {
                [
                    RepoPromptApp.Tool(
                        name: "unknown_catalog_tool",
                        description: "Registration failure fixture.",
                        inputSchema: .object(properties: [:]),
                        returnsValue: { _ in .object([:]) }
                    )
                ]
            }
        }
    }

    private static func purgeStaleWindowScopeRegistrations() async {
        let liveWindowIDs = Set(WindowStatesManager.shared.allWindows.map(\.windowID))
        let snapshot = await AppDomainRuntimeComposition.shared.catalogSnapshot()
        var staleScopes = Set<MCPDomainToolRegistrationScope>()
        for scopes in snapshot.activeScopesByToolName.values {
            for scope in scopes {
                guard case let .window(id) = scope,
                      !liveWindowIDs.contains(id)
                else { continue }
                staleScopes.insert(scope)
            }
        }

        var staleHandles = Set<MCPDomainToolRegistrationHandle>()
        for scope in staleScopes {
            for toolName in MCPDomainToolCatalog.windowToolNames {
                if let resolved = await AppDomainRuntimeComposition.shared.resolve(toolName: toolName, scope: scope) {
                    staleHandles.insert(resolved.handle)
                }
            }
        }
        for handle in staleHandles {
            await AppDomainRuntimeComposition.shared.unregister(handle)
        }
    }

    private static func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    #if DEBUG
        private static func waitForWindowToolIntentGeneration(
            _ expectedGeneration: UInt64,
            window: WindowState,
            timeout: Duration = .seconds(1)
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while window.mcpServer.windowToolRegistrationIntentGenerationForTesting() < expectedGeneration,
                  clock.now < deadline
            {
                try? await clock.sleep(for: .milliseconds(5))
            }
            return window.mcpServer.windowToolRegistrationIntentGenerationForTesting() >= expectedGeneration
        }

        private static func waitForTeardownRequestCount(
            _ expectedCount: Int,
            service: MCPService,
            timeout: Duration = .seconds(1)
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while await service.teardownRequestCountForTesting() < expectedCount, clock.now < deadline {
                try? await clock.sleep(for: .milliseconds(5))
            }
            return await service.teardownRequestCountForTesting() >= expectedCount
        }

        private struct BootstrapSocketNamespaceFixture {
            let directoryURL: URL
            let socketURL: URL

            static func make() throws -> Self {
                let directoryURL = URL(
                    fileURLWithPath: "/tmp/rpce-xctest-bs-\(getpid())-\(UUID().uuidString)",
                    isDirectory: true
                )
                let socketURL = directoryURL.appendingPathComponent("bootstrap.sock")
                XCTAssertLessThan(socketURL.path.utf8CString.count, MemoryLayout<sockaddr_un>.size)
                XCTAssertNotEqual(socketURL.standardizedFileURL, MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL)
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return .init(directoryURL: directoryURL, socketURL: socketURL)
            }

            func removeOwnedDirectory() {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        private static func withIsolatedBootstrapSocketNamespace(
            window: WindowState,
            operation: (URL) async throws -> Void
        ) async throws {
            let fixture = try BootstrapSocketNamespaceFixture.make()
            let manager = ServerNetworkManager.shared
            await manager.debugResumeAllLifecycleFenceCheckpoints()
            await manager.stop()
            let productionSocketURL = MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL
            let defaultSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(defaultSocketURL, productionSocketURL)
            let previousEnabledState = await manager.debugIsEnabledForBootstrapSocketURLOverride()

            await assertBootstrapSocketOverrideError(.productionSocketURLRejected) {
                try await manager.debugInstallBootstrapSocketURLOverride(productionSocketURL)
            }

            do {
                try await manager.debugInstallBootstrapSocketURLOverride(fixture.socketURL)
            } catch {
                fixture.removeOwnedDirectory()
                throw error
            }

            await assertBootstrapSocketOverrideError(.overrideAlreadyInstalled) {
                try await manager.debugInstallBootstrapSocketURLOverride(fixture.socketURL)
            }

            do {
                try await operation(fixture.socketURL)
            } catch {
                do {
                    try await cleanupIsolatedBootstrapSocketNamespace(
                        window: window,
                        fixture: fixture,
                        previousEnabledState: previousEnabledState
                    )
                } catch {
                    XCTFail("Failed to clean isolated bootstrap socket namespace: \(error)")
                }
                throw error
            }

            try await cleanupIsolatedBootstrapSocketNamespace(
                window: window,
                fixture: fixture,
                previousEnabledState: previousEnabledState
            )
        }

        private static func cleanupIsolatedBootstrapSocketNamespace(
            window: WindowState,
            fixture: BootstrapSocketNamespaceFixture,
            previousEnabledState: Bool
        ) async throws {
            await window.mcpServer.stopServer()
            await window.mcpServer.shutdownListener()

            let manager = ServerNetworkManager.shared
            let runningAfterShutdown = await manager.isRunning()
            XCTAssertFalse(runningAfterShutdown)
            let productionSocketURL = MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL
            let resolvedSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(resolvedSocketURL, fixture.socketURL.standardizedFileURL)
            try await manager.debugRestoreBootstrapSocketURLOverride(expected: fixture.socketURL)
            let restoredSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(restoredSocketURL, productionSocketURL)
            await manager.setEnabled(previousEnabledState)
            let restoredEnabledState = await manager.debugIsEnabledForBootstrapSocketURLOverride()
            XCTAssertEqual(restoredEnabledState, previousEnabledState)
            let runningAfterEnabledRestore = await manager.isRunning()
            XCTAssertFalse(runningAfterEnabledRestore)
            let resolvedSocketURLAfterEnabledRestore = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(resolvedSocketURLAfterEnabledRestore, productionSocketURL)
            fixture.removeOwnedDirectory()
        }

        private static func assertBootstrapSocketOverrideError(
            _ expectedError: ServerNetworkManager.DebugBootstrapSocketURLOverrideError,
            operation: () async throws -> Void
        ) async {
            do {
                try await operation()
                XCTFail("Expected bootstrap socket URL override error: \(expectedError)")
            } catch let error as ServerNetworkManager.DebugBootstrapSocketURLOverrideError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("Unexpected bootstrap socket URL override error: \(error)")
            }
        }
    #endif

    @MainActor
    private final class AppDelegateTerminationProbe {
        private(set) var invocationCount = 0

        func shutdown() {
            invocationCount += 1
        }
    }

    @MainActor
    private final class AppDelegateRegistrationProbe {
        enum Failure: Error {
            case injected
        }

        private let failure: Failure?
        private(set) var invocationCount = 0

        init(failure: Failure? = nil) {
            self.failure = failure
        }

        func register() async throws {
            invocationCount += 1
            if let failure { throw failure }
        }
    }

    private static func schemaProperties(
        for tool: RepoPromptApp.Tool,
        label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Value] {
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue, label, file: file, line: line)
        return try XCTUnwrap(schema["properties"]?.objectValue, label, file: file, line: line)
    }

    private static let expectedSignatures: [String] = [
        "0|manage_selection|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=b2facb46e2b8f9d4cfb00551bdfa19454b7f3eecd81bac510f4fed12f99452c3|schema=4b7a043e8e48130ee84cc6bbf7b9fd597b495aef238d44f17df6600088a2bb6f",
        "1|file_actions|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=81230c22d826458cae079855b133d59da34c4a66ae4a68252727e564931335b8|schema=4fd6a59a00940e13efc05b74c81372928d3ad3de0e028c8b34586e2168d16103",
        "2|get_code_structure|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=22f87c78aabfda053a0a62d731743d8ba06db649f6f2497820aea0e2a97fa769|schema=3e87702a79eee436137bef3cf5fec4ee42ab5d252bd69d4eaa7a82ca62ad736a",
        "3|get_file_tree|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=9bf648121646b463554d58373f61c2dcede04640482994e0cf1533d21ae77093|schema=91972027e030989cf242fed03377bdc5056c6317cc77d351d3fa5348dd1767a0",
        "4|read_file|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=7e7949aed9a99c362eedc048ec8f41ffc62536269578d3c762a25fdc70fbb321|schema=d023edb446167481751886bebeac7dc8896e2b3f57c12b18591761f846618bb1",
        "5|file_search|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=f2c9e16ca780c4e94f795b6c9489658856052e6d159aa467a64c906ee48a3fe4|schema=08904f5e241c06414ff476b80b81338a5798961a69d93227d7ed098694546b99",
        "6|workspace_context|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=fb968e72d430d354b03a0dfdb5251d95bbdea2a38cddcd58fe402f6bcb4f1035|schema=d41b9e8db1ccb1ce385d2d20619485a211bda4a8474270ef0c08fc77647e8376",
        "7|prompt|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=e1377f12a6495829c0ade3e37b9325f7a07dc2065288b16bb810d01a4df9e55d|schema=8c8ea22a39bbb9e10c364ad483527faf109a52e1eb9c45c0c939f569ecf144d1",
        "8|apply_edits|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=d33efa75e3e29e1e4e1cfe90d0e9d621337c397e5329aee02f4a261726d790fa|schema=e1ad464843910182006a484b0545305f8d53821a795cd8e116c07a01eededed8",
        "9|oracle_utils|enabled=true|ann=title=nil,readOnly=nil,destructive=nil,idempotent=nil,openWorld=nil|desc=af161abbd2edf82b9cf502e1cf794bc48366b816b3ddc0ec2034b154ecc35c3a|schema=7d3c55c22f02f8825008521e4c20cd304a7c12f3679743b34f5a2bf315d19d7b",
        "10|ask_oracle|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=7a4771154006b3dcf158003d04b2b78da91fe4cc63d1acb5942f64f8a3e04e98|schema=03968f76ace268ccd7128c088ecc2544ca5ec77f47100d03e38a29a155cf81eb",
        "11|oracle_send|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=4608413a45189586669c6cc3339af4d467939a2477036545ef5d879b676b51fb|schema=6f940dcd0a0d39789189120217abdb60cd0f520b85f862beb81349f98bc1b19c",
        "12|oracle_chat_log|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=5acbb74a0fcf76bd3717faac8fc355f582f13523685d3bfebf11fda7241958b1|schema=50db94327abe785e20d3628135efa29cf184d18272d5af5b94a43d7246a4a201",
        "13|git|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=1a9ff83872cf8842146dd84563dd880f7d9b8f6190cc6e9204a0ea82fc8feca6|schema=51bd804997d6acfaa17d529867f6188b969282a4db95956e859a74ab07de626a",
        "14|manage_worktree|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=857ab8975667e3d2e5b35a09c7415e07ca0ab2f0ff16de6895170d4d1b47a820|schema=9263f9f047982b3709d92040f749804d69928d222ce46038a4171ded34d12bc6",
        "15|context_builder|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=d83348b6b803b303965401075041ddc5d7dcea3512020afa3f352c04413750fb|schema=2da87e6e171809a1e0eb0614fa8f7db2f91311f655f8427745060be80755da1f",
        "16|ask_user|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=d50e80bf18cf5fde469cacd4386870ce8a0bcc65f121ceafec82b29ea4210a9f|schema=9260bb80fd11da1bb022af337e489608a4b113e8e77bd4677637fb57d501f1d1",
        "17|agent_explore|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=698ab006db47713a51f394bfe3f832ada8637440d8acb4715be5430ec380cef8|schema=d367738ad179d8f6b39b98f73082d594f53c42d771c4f2e512790593c5b3f9f4",
        "18|agent_run|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=2b5e211868964f961f2d369c2aa54da7035a92a83e900770ad433e4ceb00fd96|schema=0b4f819f3aa6624df0f54fdaba6f8717ac64667d07a0528240d26905ba480520",
        "19|agent_manage|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=80d302d4391d6136f8acfbe8fc0bafe394c5110c5e63aefcf8f4c59fcbdbf95f|schema=83f34927eacac4dc6352db72eae312ac3a5477b2f70c9031f09a2101dc8f2e97",
        "20|share_thoughts|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=b1ac755b39a4ac2d8a621e78801a258c5d95ec2ff4e063f600081fa27891a852|schema=a5dea0c92fd4da06a15f991e1e8a287235ca681ae381cef1b594bc7c07e538d7",
        "21|set_status|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=19bbfd6fc47639e02295de4e9289ea77f25c6a91ad150998726768b84c266783|schema=0854d727c81f1eb8fa0a14edb9d6ab8bb58974d919cc53150bd72473f1ae0196",
        "22|wait_for_next_user_instruction|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=3a59a13a0026414ae04dd21d730a7144b91c67146dce77340fe730c865bea3d7|schema=15335c3bbadf042948d0a1ba52f0fcb01125428dda4952dbda418051904d82ef",
        "23|history|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=fdc6ec2292ef0962b5fcfadf8691d905849a28474a832042789f14c444f6b0b6|schema=584dfe4f4200b3c795505461c3889c23d455a3af97c761e3bb5dd40ae46a8d71"
    ]

    private static func signatures(for tools: [RepoPromptApp.Tool]) throws -> [String] {
        try tools.enumerated().map { index, tool in
            let definition = try tool.domainBinding().definition
            return try MCPDomainToolFingerprint(definition: definition).goldenSignature(index: index)
        }
    }

    private static func renderGolden(_ signatures: [String]) -> String {
        let body = signatures
            .map { "        \"\($0)\"" }
            .joined(separator: ",\n")
        return "\n        private static let expectedSignatures: [String] = [\n"
            + body
            + "\n        ]\n"
    }
}

private actor AsyncTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func waitUntilEntered(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor MCPReadinessScopePresenceProbe {
    private let firstQueryGate = AsyncTestGate()
    private(set) var queryCount = 0

    func query(
        requiredNames _: [String],
        scope _: MCPDomainToolRegistrationScope
    ) async -> MCPDomainToolScopePresence {
        queryCount += 1
        if queryCount == 1 {
            await firstQueryGate.arriveAndWait()
        }
        return MCPDomainToolScopePresence(revision: 1, isComplete: true)
    }

    func releaseFirstQuery() async {
        await firstQueryGate.release()
    }
}

private actor ControlledMCPServiceStartProbe {
    enum Outcome: Equatable {
        case success
        case failure
    }

    enum Failure: Error {
        case injected
        case unexpectedAttempt(Int)
    }

    private let outcomes: [Outcome]
    private let gates: [AsyncTestGate]
    private var attemptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var attemptCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
        gates = outcomes.map { _ in AsyncTestGate() }
    }

    func start() async throws {
        attemptCount += 1
        let attempt = attemptCount
        let readyWaiters = attemptWaiters.filter { $0.count <= attempt }
        attemptWaiters.removeAll { $0.count <= attempt }
        readyWaiters.forEach { $0.continuation.resume() }

        guard outcomes.indices.contains(attempt - 1) else {
            throw Failure.unexpectedAttempt(attempt)
        }
        await gates[attempt - 1].arriveAndWait()
        if outcomes[attempt - 1] == .failure {
            throw Failure.injected
        }
    }

    func waitUntilAttemptCount(_ count: Int) async {
        guard attemptCount < count else { return }
        await withCheckedContinuation { continuation in
            attemptWaiters.append((count, continuation))
        }
    }

    func releaseAttempt(_ attempt: Int) async {
        guard gates.indices.contains(attempt - 1) else { return }
        await gates[attempt - 1].release()
    }
}

private actor ControlledMCPServiceTeardownProbe {
    private let gates: [AsyncTestGate]
    private var attemptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var attemptCount = 0

    init(attempts: Int) {
        gates = (0 ..< attempts).map { _ in AsyncTestGate() }
    }

    func tearDown() async {
        attemptCount += 1
        let attempt = attemptCount
        let readyWaiters = attemptWaiters.filter { $0.count <= attempt }
        attemptWaiters.removeAll { $0.count <= attempt }
        readyWaiters.forEach { $0.continuation.resume() }

        guard gates.indices.contains(attempt - 1) else { return }
        await gates[attempt - 1].arriveAndWait()
    }

    func waitUntilAttemptCount(_ count: Int) async {
        guard attemptCount < count else { return }
        await withCheckedContinuation { continuation in
            attemptWaiters.append((count, continuation))
        }
    }

    func releaseAttempt(_ attempt: Int) async {
        guard gates.indices.contains(attempt - 1) else { return }
        await gates[attempt - 1].release()
    }
}

private actor ServerControllerRegistrationOrderingProbe {
    enum Failure: Error {
        case injected
        case transportObservedBeforeRegistration
    }

    private let gate = AsyncTestGate()
    private let failsRegistration: Bool
    private var completed = false
    private var registrationCount = 0
    private var preActivationCount = 0

    init(failsRegistration: Bool = false) {
        self.failsRegistration = failsRegistration
    }

    func register() async throws {
        registrationCount += 1
        await gate.arriveAndWait()
        if failsRegistration {
            throw Failure.injected
        }
        try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
        completed = true
    }

    func waitUntilEntered(timeout: Duration = .seconds(1)) async -> Bool {
        await gate.waitUntilEntered(timeout: timeout)
    }

    func release() async {
        await gate.release()
    }

    func assertCompleted() throws {
        preActivationCount += 1
        guard completed else { throw Failure.transportObservedBeforeRegistration }
    }

    func counts() -> (registration: Int, preActivation: Int) {
        (registrationCount, preActivationCount)
    }
}

@MainActor
private final class SingleEnvelopeToolProvider: MCPAppToolProviding {
    let group = MCPAppToolGroup.files
    private let runtime: MCPAppToolBinder
    private let definition: MCPDomainToolDefinition

    init(runtime: MCPAppToolBinder, definition: MCPDomainToolDefinition) {
        self.runtime = runtime
        self.definition = definition
    }

    func buildTools() -> [RepoPromptApp.Tool] {
        let binding = MCPDomainToolBinding(definition: definition) { arguments in
            .object(["path": arguments["path"] ?? .null])
        }
        return [try! RepoPromptApp.Tool(domainBinding: binding, runtime: runtime)]
    }
}

private actor SharedBindingRuntimeRecorder {
    struct Invocation {
        let name: String
        let providerManaged: Bool
        let arguments: [String: Value]
    }

    private var invocation: Invocation?
    private var count = 0

    func record(name: String, providerManaged: Bool, arguments: [String: Value]) {
        count += 1
        invocation = Invocation(
            name: name,
            providerManaged: providerManaged,
            arguments: arguments
        )
    }

    func snapshot() -> Invocation? {
        invocation
    }

    func invocationCount() -> Int {
        count
    }
}
