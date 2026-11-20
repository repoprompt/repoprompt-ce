import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
@testable import RepoPromptMCPServer
import RepoPromptShared
import XCTest

final class MCPServerExecutionBoundaryTests: XCTestCase {
    func testSixClassAdapterPathUsesHostAndReleasesPhysicalOwners() async throws {
        for tool in ["file_actions", "oracle_utils", "get_file_tree", "read_file", "git", "file_search"] {
            let fixture = try await ServerExecutionFixture.make(tool: tool)
            do {
                let result = try await fixture.invoke()
                XCTAssertEqual(result.content, [.text(text: "effect", annotations: nil, _meta: nil)], tool)
                XCTAssertEqual(try String(contentsOf: fixture.effectURL, encoding: .utf8), fixture.invocationID.uuidString)
                let order = await fixture.checks.snapshot()
                XCTAssertEqual(order, ["limiter", "authorization", "window", "limiter", "authorization", "window", "format", "observers", "notify"], tool)
                let active = await fixture.limiters.hasInFlightCalls()
                XCTAssertFalse(active, tool)
            } catch {
                await fixture.cleanup()
                throw error
            }
            await fixture.cleanup()
        }
    }

    func testRevocationAtEitherDispatchFenceNeverEntersProvider() async throws {
        for failureIndex in 1 ... 6 {
            let fixture = try await ServerExecutionFixture.make(tool: "read_file", failAt: failureIndex)
            do {
                _ = try await fixture.invoke()
                XCTFail("Revoked authority must not dispatch at check \(failureIndex)")
            } catch {
                XCTAssertTrue(error is MCPToolDispatchAdmissionError, "\(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.effectURL.path))
            let checks = await fixture.checks.snapshot()
            XCTAssertEqual(checks.count, failureIndex)
            await fixture.cleanup()
        }
    }

    func testCapturedResolutionCannotRebindAfterRegistrationRetires() async throws {
        let fixture = try await ServerExecutionFixture.make(tool: "read_file")
        _ = await fixture.runtime.toolRegistry.unregister(fixture.handle)
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definitions.first { $0.name == "read_file" })
        let replacementEffect = fixture.directory.appendingPathComponent("replacement-effect")
        _ = try await fixture.runtime.toolRegistry.register(registrationID: .init(), scope: .window(id: 42), bindings: [
            MCPDomainToolBinding(definition: definition, operation: { _ in
                try Data("replacement".utf8).write(to: replacementEffect)
                return .string("replacement")
            })
        ])
        do {
            _ = try await fixture.invoke()
            XCTFail("A captured resolution must not bind to its successor")
        } catch {
            XCTAssertEqual(error as? MCPDomainHostError, .staleRegistration(toolName: "read_file"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementEffect.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.effectURL.path))
        await fixture.cleanup()
    }

    func testAppliedMutationPublicationRechecksAllAuthorityBeforeClosing() async throws {
        let fixture = try await ServerExecutionFixture.make(tool: "read_file")
        let mutation = PromptExportMutationSettlementObservation()
        mutation.record(.init(state: .applied, operationID: "export"))
        let observation = PromptExportPublicationAuthorityObservation()
        observation.bind(fixture.authorization)
        let checks = ServerBoundaryChecks(failAt: 1)
        let gate = MCPToolPublicationGate(
            promptExportExecutionEnvelope: nil,
            promptExportMutationObservation: mutation,
            promptExportPublicationAuthorityObservation: observation,
            fence: MCPToolDispatchFence(
                admissionDeadline: nil,
                isLimiterCurrent: { await checks.check("limiter") },
                isAuthorizationCurrent: { _ in await checks.check("authorization") },
                isWindowIdentityCurrent: { _ in await checks.check("window") }
            ),
            connectionID: fixture.connectionID, invocationID: fixture.invocationID,
            toolName: "prompt", resolvedRequestIdentity: nil,
            beforeClaim: { await checks.record("claim") },
            closeAfterAuthorityLoss: { await checks.record("close") },
            droppedResult: { CallTool.Result(content: [.text(text: "dropped", annotations: nil, _meta: nil)], isError: true) }
        )
        let result = await gate.finalize(CallTool.Result(content: [.text(text: "must not publish", annotations: nil, _meta: nil)]))
        XCTAssertEqual(result.content, [.text(text: "dropped", annotations: nil, _meta: nil)])
        let order = await checks.snapshot()
        XCTAssertEqual(order, ["claim", "window", "limiter", "authorization", "close"])
        await fixture.cleanup()
    }
}

private actor ServerBoundaryChecks {
    private var events: [String] = []
    private var queryCount = 0
    private let failAt: Int?
    init(failAt: Int? = nil) {
        self.failAt = failAt
    }

    func check(_ name: String) -> Bool {
        events.append(name)
        queryCount += 1
        return queryCount != failAt
    }

    func record(_ name: String) {
        events.append(name)
    }

    func snapshot() -> [String] {
        events
    }
}

/// Exercises the actual server supervisor -> captured invocation -> domain host path.
/// The provider's file effect witnesses entry; this is not a UI or direct-stdio fixture.
private final class ServerExecutionFixture: @unchecked Sendable {
    let runtime: MCPDomainRuntime
    let directory: URL
    let effectURL: URL
    let tool: String
    let connectionID = UUID()
    let invocationID = UUID()
    let limiters = MCPDomainConnectionCallLimiters()
    let checks: ServerBoundaryChecks
    let marker = NSObject()
    let runRoutingRegistrationID = UUID()
    var handle: MCPDomainToolRegistrationHandle!
    var captured: MCPServerResolvedInvocation!
    var authorization: MCPToolDispatchAuthorization!

    private init(tool: String, failAt: Int?) {
        self.tool = tool
        checks = ServerBoundaryChecks(failAt: failAt)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("m7-server-\(UUID())")
        effectURL = directory.appendingPathComponent("provider-effect")
        runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: "m7-server",
            storageDirectory: directory.appendingPathComponent("authority"),
            workspaceStorageDirectory: directory.appendingPathComponent("workspaces"),
            eventDirectory: directory.appendingPathComponent("events"),
            temporaryDirectory: directory.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
    }

    static func make(tool: String, failAt: Int? = nil) async throws -> ServerExecutionFixture {
        let fixture = ServerExecutionFixture(tool: tool, failAt: failAt)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try await fixture.runtime.start()
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definitions.first { $0.name == tool })
        let effectURL = fixture.effectURL
        let invocationID = fixture.invocationID
        let runRoutingRegistrationID = fixture.runRoutingRegistrationID
        fixture.handle = try await fixture.runtime.toolRegistry.register(registrationID: .init(), scope: .window(id: 42), bindings: [
            MCPDomainToolBinding(definition: definition, operation: { _ in
                let context = try MCPInvocationContextBridge.require(toolName: tool, diagnosticSink: { _ in })
                XCTAssertEqual(context.invocationID, invocationID)
                XCTAssertEqual(context.dispatchAuthorization?.runRoutingRegistrationID, runRoutingRegistrationID)
                try Data(context.invocationID.uuidString.utf8).write(to: effectURL)
                return .string("effect")
            })
        ])
        _ = await fixture.runtime.routingCoordinator.registerConnection(connectionID: fixture.connectionID, operationID: UUID())
        let registration = try await fixture.runtime.routingCoordinator.currentRegistration(connectionID: fixture.connectionID)
        let resolution = try await fixture.runtime.domainHost.resolve(toolName: tool, scope: .window(id: 42))
        let security = DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(), stableKey: "m7", displayName: "M7 test", kind: .appProxy,
                assurance: .displayNameOnly, processID: nil, runID: nil, provider: nil, verifiedIdentityFingerprint: nil
            ),
            connectionID: fixture.connectionID,
            connectionGeneration: registration.generation,
            invocationID: invocationID,
            runtimeID: fixture.runtime.identity.runtimeID,
            runtimeGeneration: fixture.runtime.identity.lifecycleGeneration,
            ephemeralGrantedToolNames: []
        )
        let host = fixture.runtime.domainHost
        fixture.captured = MCPServerResolvedInvocation(
            host: { host },
            invocationID: invocationID,
            connectionID: fixture.connectionID,
            resolution: resolution,
            arguments: [:],
            securityContext: security,
            admittedContext: nil,
            admissionDeadline: nil
        )
        fixture.authorization = MCPToolDispatchAuthorization(
            connectionID: fixture.connectionID,
            connectionIdentity: ObjectIdentifier(fixture.marker),
            lifecycleGeneration: 1,
            windowIdentity: MCPWindowToolDispatchIdentity(
                windowID: 42,
                windowStateIdentity: ObjectIdentifier(fixture.marker),
                serverViewModelIdentity: ObjectIdentifier(fixture.marker),
                catalogRegistrationHandle: fixture.handle
            ),
            runRoutingRegistrationID: runRoutingRegistrationID
        )
        return fixture
    }

    func invoke() async throws -> CallTool.Result {
        let admissionClass = try XCTUnwrap(MCPDomainToolCatalog.admissionClass(for: tool))
        let identity = MCPDomainToolCatalog.operationIdentity(for: tool, input: .missing)
        return try await limiters.withPermit(lane: admissionClass.connectionLane) {
            let admission = await MCPServerResourceAdmission.acquire(
                host: self.runtime.domainHost,
                toolName: self.tool,
                admissionClass: admissionClass,
                windowID: 42,
                deadline: nil,
                evidenceClass: .init(admissionClass: admissionClass),
                operationIdentity: identity
            )
            guard case let .admitted(lease) = admission else { throw FixtureError.admissionRejected }
            defer { lease?.release() }
            let context = ToolInvocationContext(
                origin: .network,
                invocationID: self.invocationID,
                requestID: nil,
                toolName: self.tool,
                metadata: MCPRequestMetadata(
                    connectionID: self.connectionID,
                    clientName: nil,
                    windowID: 42,
                    invocationID: self.invocationID
                ),
                dispatchAuthorization: self.authorization
            )
            let checks = self.checks
            let supervisor = MCPToolExecutionSupervisor(
                toolName: self.tool,
                connectionID: self.connectionID,
                invocationID: self.invocationID,
                isPromptExport: false,
                selectedExecutionContract: MCPToolExecutionContractCatalog.contract(for: self.tool, arguments: [:]),
                promptExportExecutionEnvelope: nil,
                fence: MCPToolDispatchFence(
                    admissionDeadline: nil,
                    isLimiterCurrent: { await checks.check("limiter") },
                    isAuthorizationCurrent: { _ in await checks.check("authorization") },
                    isWindowIdentityCurrent: { _ in await checks.check("window") }
                ),
                effects: .init(),
                codeStructureSettlementRegistry: .init(),
                executionWatchdogEnvironment: .continuous(),
                executionSink: NoopMCPToolExecutionEventSink(),
                handlerPhaseRecorder: NoopMCPToolExecutionHandlerPhaseRecorderFactory().make(origin: .zero, now: { .zero }),
                executionTraceOrigin: .zero,
                evidenceOperationIdentity: identity,
                observerRunIDForCallbacksFinal: nil,
                resolvedRequestIdentity: nil,
                lifecycleCorrelation: nil,
                promptExportMutationObservation: nil
            )
            let gate = MCPToolPublicationGate(
                promptExportExecutionEnvelope: nil,
                promptExportMutationObservation: nil,
                promptExportPublicationAuthorityObservation: nil,
                fence: MCPToolDispatchFence(
                    admissionDeadline: nil,
                    isLimiterCurrent: { true },
                    isAuthorizationCurrent: { _ in true },
                    isWindowIdentityCurrent: { _ in true }
                ),
                connectionID: self.connectionID,
                invocationID: self.invocationID,
                toolName: self.tool,
                resolvedRequestIdentity: nil,
                beforeClaim: {},
                closeAfterAuthorityLoss: {},
                droppedResult: { CallTool.Result(content: [], isError: true) }
            )
            let publisher = MCPToolCompletionPublisher(
                toolName: self.tool,
                supervisor: supervisor,
                gate: gate,
                beforeFormatting: { await checks.record("format") },
                beforeObservers: { await checks.record("observers") },
                format: { value in
                    XCTAssertEqual(value, .string("effect"))
                    return [.text(text: "effect", annotations: nil, _meta: nil)]
                },
                notify: { _, isError, windowScoped in
                    XCTAssertFalse(isError)
                    XCTAssertTrue(windowScoped)
                    let snapshot = await self.runtime.domainHost.snapshot()
                    XCTAssertEqual(snapshot.activeInvocationCount, 0)
                    XCTAssertEqual(snapshot.activeResourceAdmissionLeaseCount, 0)
                    await checks.record("notify")
                },
                errorResult: { _ in CallTool.Result(content: [], isError: true) },
                logError: { _ in },
                finish: { result, _ in result }
            )
            return try await publisher.dispatchAndComplete(operation: {
                try await supervisor.dispatch({ bridge, context in
                    try await self.captured.invoke(context: context, providerEntry: bridge, diagnosticSink: { _ in })
                }, invocationContext: context)
            }, windowScoped: true, release: { lease?.release() })
        }
    }

    func cleanup() async {
        _ = await runtime.shutdown()
        let snapshot = await runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.activeInvocationCount, 0)
        XCTAssertEqual(snapshot.activeResourceAdmissionLeaseCount, 0)
        XCTAssertEqual(snapshot.resourceAdmissionWaiterCount, 0)
        let active = await limiters.hasInFlightCalls()
        XCTAssertFalse(active)
        try? FileManager.default.removeItem(at: directory)
    }

    private enum FixtureError: Error { case admissionRejected }
}
