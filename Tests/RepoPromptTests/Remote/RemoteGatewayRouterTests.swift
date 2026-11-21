import Foundation
import MCP
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptRemoteProtocol
import RepoPromptSecureStorage
import XCTest

@MainActor
final class RemoteGatewayRouterTests: XCTestCase {
    func testWorkspaceHistoryScopesBeforePagingAndKeepsEqualTimestamps() throws {
        let workspace = UUID()
        let busyWorkspace = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 10)
        let targetEntries = (0 ..< 131).map { index in
            RemoteHistoryEntry(
                id: UUID(), workspaceID: workspace.uuidString, sessionName: "Saved chat \(index)", lastActivityAt: date
            )
        }
        let otherEntries = (0 ..< 150).map { index in
            RemoteHistoryEntry(
                id: UUID(), workspaceID: busyWorkspace.uuidString, sessionName: "New chat \(index)",
                lastActivityAt: date.addingTimeInterval(100)
            )
        }
        let entries = targetEntries + otherEntries
        let legacy = WindowRemoteReadService.historyPage(entries: entries, request: .init(limit: 100))
        XCTAssertTrue(legacy.entries.allSatisfy { $0.workspaceID == busyWorkspace.uuidString })
        XCTAssertNil(legacy.workspaceID)

        let first = WindowRemoteReadService.historyPage(entries: entries, request: .init(limit: 100, workspaceID: workspace))
        let cursor = try XCTUnwrap(first.olderCursor)
        let second = WindowRemoteReadService.historyPage(
            entries: entries,
            request: .init(limit: 100, workspaceID: workspace, before: cursor)
        )

        XCTAssertEqual(first.workspaceID, workspace)
        XCTAssertEqual(first.entries.count, 100)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.entries.count, 31)
        XCTAssertFalse(second.hasMore)
        XCTAssertNil(second.olderCursor)
        XCTAssertEqual(
            (first.entries + second.entries).map(\.id),
            targetEntries.map(\.id).sorted { $0.uuidString > $1.uuidString }
        )
    }

    func testLegacyHTTPDecodesWorkspaceHistoryScopeAndCursor() {
        let workspace = UUID()
        let session = UUID()
        let request = RemoteLegacyHTTPRequest(
            method: "GET",
            target: "\(RemoteProtocol.historyPath)?workspace_id=\(workspace)&before_date=12.5&before_id=\(session)&limit=25",
            headers: [:],
            body: Data()
        )
        guard case let .request(.history(history)) = RemoteLegacyHTTPRequestDecoder.decode(request) else {
            return XCTFail("Expected a workspace history request.")
        }
        XCTAssertEqual(history, RemoteHistoryRPCRequest(
            limit: 25, workspaceID: workspace,
            before: RemoteHistoryCursor(lastActivityAt: Date(timeIntervalSinceReferenceDate: 12.5), sessionID: session)
        ))
    }

    func testProtectedRequestsRequireAuthorizationBeforeRoutingForEveryTransportContext() async throws {
        var snapshotCalls = 0
        let router = makeRouter(
            authorize: { _ in false },
            snapshot: {
                snapshotCalls += 1
                return nil
            }
        )

        for context in [
            RemoteGatewayRequestContext.legacyHTTPS(authorizationHeader: nil),
            RemoteGatewayRequestContext(
                transport: .authenticatedPeer(endpointID: "peer-1", deviceID: "device-1"),
                authorizationHeader: "Bearer invalid"
            )
        ] {
            let response = await router.route(.snapshot, context: context)
            XCTAssertEqual(response.status, 401)
            XCTAssertEqual(try error(from: response).code, "unauthorized")
        }
        XCTAssertEqual(snapshotCalls, 0)
    }

    func testUnpairReportsDurableRevocationFailure() async throws {
        let router = makeRouter(unpair: { .failed })

        let response = await router.route(
            .unpair,
            context: .legacyHTTPS(authorizationHeader: "Bearer credential")
        )

        XCTAssertEqual(response.status, 500)
        let responseError = try error(from: response)
        XCTAssertEqual(responseError.code, "revocation_failed")
        XCTAssertTrue(responseError.retryable)
    }

    func testUnpairReturnsAcknowledgementOnlyAfterSuccessfulRevocation() async throws {
        var revocationCalls = 0
        let router = makeRouter(unpair: {
            revocationCalls += 1
            return .success
        })

        let response = await router.route(
            .unpair,
            context: .init(
                transport: .authenticatedPeer(endpointID: "peer", deviceID: "device"),
                authorizationHeader: "Bearer credential"
            )
        )
        let acknowledgement = try JSONDecoder().decode(
            RemoteUnpairResponse.self,
            from: json(from: response)
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(acknowledgement.unpaired)
        XCTAssertEqual(revocationCalls, 1)
    }

    func testPairingBypassesEstablishedCredentialAuthorization() async throws {
        let pairingRequest = RemotePairingRequest(
            desktopInstanceID: "desktop",
            oneTimeSecret: "secret",
            deviceName: "Phone"
        )
        let desktop = RemoteDesktopSummary(
            instanceID: "desktop",
            displayName: "RepoPrompt CE",
            appVersion: "test",
            isAvailable: true,
            lastSeenAt: Date(timeIntervalSince1970: 1)
        )
        let expected = RemotePairingResponse(
            desktop: desktop,
            deviceID: "device",
            credential: "credential"
        )
        let router = makeRouter(
            authorize: { _ in false },
            pair: { request in
                XCTAssertEqual(request, pairingRequest)
                return .success(expected)
            }
        )

        let response = await router.route(
            .pair(pairingRequest),
            context: .legacyHTTPS(authorizationHeader: nil)
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(RemotePairingResponse.self, from: json(from: response)), expected)
    }

    func testCommandResponsePreservesResolvedFieldsAndAddsCurrentEventCursor() async throws {
        let command = RemoteCommandRequest(operation: .startRun)
        let selection = RemoteAgentSelection(
            agentID: "codex",
            modelID: "gpt-test",
            reasoningEffort: "high"
        )
        let catalog = RemoteToolCatalog(
            providerID: "codex",
            revision: 7,
            settings: [
                RemoteToolSettingDescriptor(
                    id: "web",
                    displayName: "Web",
                    category: "network",
                    isEnabled: true
                )
            ],
            isMutable: true
        )
        let contextBuilderResult = RemoteContextBuilderResult(
            tabID: "tab",
            status: "complete",
            prompt: "prompt",
            fileCount: 2,
            totalTokens: 100
        )
        let serviceResponse = RemoteCommandResponse(
            commandID: command.commandID,
            accepted: true,
            message: "accepted",
            eventCursor: 3,
            contextBuilderResult: contextBuilderResult,
            resolvedSelection: selection,
            resolvedToolCatalog: catalog
        )
        let router = makeRouter(
            authorizationState: { RemoteAuthorizationState(defaultLevel: .control) },
            execute: { request in
                XCTAssertEqual(request, command)
                return .success(serviceResponse)
            },
            eventCursor: { 42 }
        )

        let response = await router.route(
            .command(command, endpoint: .commands),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )
        let decoded = try JSONDecoder().decode(RemoteCommandResponse.self, from: json(from: response))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(decoded.eventCursor, 42)
        XCTAssertEqual(decoded.contextBuilderResult, contextBuilderResult)
        XCTAssertEqual(decoded.resolvedSelection, selection)
        XCTAssertEqual(decoded.resolvedToolCatalog, catalog)
    }

    func testCommandAuthorityMatrixMatchesLegacyPolicy() {
        let expected: [(RemoteCommandOperation, RemoteAuthorityLevel)] = [
            (.respond, .respond),
            (.startRun, .control),
            (.configureSession, .control),
            (.configureTools, .control),
            (.followUp, .control),
            (.steer, .control),
            (.cancel, .control),
            (.resume, .control),
            (.contextBuilder, .control),
            (.registerNotifications, .observe)
        ]

        for (operation, authority) in expected {
            XCTAssertEqual(RemoteGatewayRequestRouter.requiredAuthority(for: operation), authority)
        }
    }

    func testNotificationRegistrationRetainsObserveLevelBehaviorAndCursor() async throws {
        let registration = RemoteNotificationRegistration(platform: .apns, deviceToken: "token")
        let command = RemoteCommandRequest(
            operation: .registerNotifications,
            notificationRegistration: registration
        )
        var registered: RemoteNotificationRegistration?
        var executeCalls = 0
        let router = makeRouter(
            authorizationState: { RemoteAuthorizationState(defaultLevel: .observe) },
            registerNotifications: { value in
                registered = value
                return .success
            },
            execute: { _ in
                executeCalls += 1
                return .failed
            },
            eventCursor: { 55 }
        )

        let response = await router.route(
            .command(command, endpoint: .commands),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )
        let decoded = try JSONDecoder().decode(RemoteCommandResponse.self, from: json(from: response))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(registered, registration)
        XCTAssertEqual(decoded.eventCursor, 55)
        XCTAssertEqual(decoded.message, "Notification registration saved.")
        XCTAssertEqual(executeCalls, 0)
    }

    func testContextBuilderEndpointRejectsOtherOperationsBeforeExecution() async throws {
        var executeCalls = 0
        let router = makeRouter(execute: { _ in
            executeCalls += 1
            return .failed
        })

        let response = await router.route(
            .command(RemoteCommandRequest(operation: .cancel), endpoint: .contextBuilder),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try error(from: response).code, "invalid_context_builder_command")
        XCTAssertEqual(executeCalls, 0)
    }

    func testIrohTranscriptInitialPageDefaultsToRecentAndExplicitLegacyRemainsAvailable() {
        let sessionID = UUID()
        XCTAssertEqual(
            RemoteIrohGatewayAdapter.transcriptPaging(for: .init(sessionID: sessionID)),
            .recentBackward(before: nil)
        )
        XCTAssertEqual(
            RemoteIrohGatewayAdapter.transcriptPaging(for: .init(
                sessionID: sessionID,
                afterSequenceIndex: nil,
                pagingMode: .legacyForward
            )),
            .legacyForward(afterSequenceIndex: nil)
        )
        XCTAssertEqual(
            RemoteIrohGatewayAdapter.transcriptPaging(for: .init(
                sessionID: sessionID,
                pagingMode: .recentBackward
            )),
            .recentBackward(before: nil)
        )
    }

    func testIrohEndpointBindingIsRejectedOutsidePinnedLegacyHTTPS() async throws {
        var bindingCalls = 0
        let router = makeRouter(bindIrohEndpoint: { _, _ in
            bindingCalls += 1
            return .failure(TestFailure.unexpectedResponse)
        })
        let request = RemoteIrohBindingRequest(
            desktopInstanceID: "desktop",
            deviceID: "device",
            expectedServerEndpointID: String(repeating: "a", count: 64),
            clientEndpointID: String(repeating: "b", count: 64)
        )
        let response = await router.route(
            .bindIrohEndpoint(request),
            context: .init(
                transport: .authenticatedPeer(
                    endpointID: String(repeating: "b", count: 64),
                    deviceID: "device"
                ),
                authorizationHeader: "Bearer valid"
            )
        )

        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(try error(from: response).code, "endpoint_binding_requires_legacy_https")
        XCTAssertEqual(bindingCalls, 0)
    }

    func testEventsRemainTypedUntilTheLegacyAdapterSerializesSSE() async throws {
        let event = RemoteEvent(
            desktopInstanceID: "desktop",
            sequence: 9,
            type: .sessionUpdated
        )
        let replayRouter = makeRouter(replay: { cursor in
            XCTAssertEqual(cursor, 8)
            return .events([event])
        })

        let response = await replayRouter.route(
            .events(after: 8),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(response.status, 200)
        guard case let .events(events) = response.content else {
            return XCTFail("Expected typed events")
        }
        XCTAssertEqual(events, [event])

        let staleRouter = makeRouter(replay: { _ in .snapshotRequired })
        let staleResponse = await staleRouter.route(
            .events(after: 1),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(staleResponse.status, 409)
        XCTAssertEqual(try error(from: staleResponse).code, "snapshot_required")
    }

    func testLegacyDecoderPreservesRouteAndTranscriptQuerySemantics() {
        let sessionID = UUID()
        let request = RemoteLegacyHTTPRequest(
            method: "GET",
            target: "\(RemoteProtocol.transcriptPath)?session_id=\(sessionID.uuidString)&after=12&limit=33&details=1",
            headers: ["authorization": "Bearer token"],
            body: Data()
        )

        guard case let .request(.transcript(transcript)) = RemoteLegacyHTTPRequestDecoder.decode(request) else {
            return XCTFail("Expected a transcript router request")
        }
        XCTAssertEqual(transcript.sessionID, sessionID)
        XCTAssertEqual(transcript.paging, .legacyForward(afterSequenceIndex: 12))
        XCTAssertEqual(transcript.limit, 33)
        XCTAssertTrue(transcript.includeDetails)
    }

    func testLegacyDecoderPreservesValidationErrorsAndRouteTable() throws {
        let invalidTranscript = RemoteLegacyHTTPRequest(
            method: "GET",
            target: "\(RemoteProtocol.transcriptPath)?session_id=invalid",
            headers: [:],
            body: Data()
        )
        guard case let .response(response) = RemoteLegacyHTTPRequestDecoder.decode(invalidTranscript) else {
            return XCTFail("Expected an immediate validation response")
        }
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try error(from: response).code, "invalid_session")

        let routes: [(String, String, String)] = [
            ("POST", RemoteProtocol.unpairPath, "unpair"),
            ("GET", RemoteProtocol.snapshotPath, "snapshot"),
            ("GET", RemoteProtocol.diagnosticsPath, "diagnostics"),
            ("GET", RemoteProtocol.workspacesPath, "workspaces"),
            ("GET", RemoteProtocol.sessionsPath, "sessions"),
            ("GET", RemoteProtocol.agentsPath, "agents"),
            ("GET", RemoteProtocol.workflowsPath, "workflows"),
            ("GET", RemoteProtocol.historyPath, "history"),
            ("GET", RemoteProtocol.eventsPath, "events")
        ]
        for (method, path, expected) in routes {
            let request = RemoteLegacyHTTPRequest(method: method, target: path, headers: [:], body: Data())
            guard case let .request(route) = RemoteLegacyHTTPRequestDecoder.decode(request) else {
                XCTFail("Expected route for \(method) \(path)")
                continue
            }
            XCTAssertEqual(routeName(route), expected)
        }
    }

    func testLegacyParserRetainsBoundedBodyAndHeaderBehavior() {
        var buffer = Data("POST /remote/v1/commands HTTP/1.1\r\nAuthorization: Bearer token\r\nContent-Length: 4\r\n\r\ntesttrailing".utf8)
        let request = RemoteLegacyHTTPParser.nextRequest(from: &buffer)

        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.target, "/remote/v1/commands")
        XCTAssertEqual(request?.headers["authorization"], "Bearer token")
        XCTAssertEqual(request?.body, Data("test".utf8))
        XCTAssertEqual(buffer, Data("trailing".utf8))

        var oversized = Data("POST / HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n".utf8)
        XCTAssertNil(RemoteLegacyHTTPParser.nextRequest(from: &oversized))
        XCTAssertTrue(oversized.isEmpty)
    }

    func testLegacyResponseEncoderPreservesHTTPAndShortSSEWireBehavior() {
        let event = RemoteEvent(
            desktopInstanceID: "desktop",
            sequence: 11,
            type: .sessionUpdated
        )
        let encodedEvent = RemoteLegacyHTTPResponseEncoder.encode(
            RemoteGatewayResponse(status: 200, content: .events([event]))
        )
        let eventText = String(decoding: encodedEvent.data, as: UTF8.self)
        XCTAssertTrue(eventText.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(eventText.contains("Content-Type: text/event-stream; charset=utf-8\r\n"))
        XCTAssertTrue(eventText.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(eventText.contains("id: 11\ndata: "))

        let connected = RemoteLegacyHTTPResponseEncoder.encode(
            RemoteGatewayResponse(status: 200, content: .events([]))
        )
        XCTAssertTrue(String(decoding: connected.data, as: UTF8.self).hasSuffix(": connected\n\n"))

        let error = RemoteLegacyHTTPResponseEncoder.encode(.error(
            .init(code: "snapshot_required", message: "Refresh.", retryable: true),
            status: 409
        ))
        let errorText = String(decoding: error.data, as: UTF8.self)
        XCTAssertTrue(errorText.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        XCTAssertTrue(errorText.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(errorText.contains("\"code\":\"snapshot_required\""))
    }

    func testLegacyAdapterRetainsOneMegabyteInboundBound() {
        XCTAssertEqual(RemoteLegacyHTTPSGatewayAdapter.maximumBufferedRequestBytes, 1_048_576)
    }

    private func makeRouter(
        authorize: @escaping (RemoteGatewayRequestContext) -> Bool = { _ in true },
        pair: @escaping (RemotePairingRequest) -> RemoteGatewayPairingResult = { _ in .failed },
        unpair: @escaping () -> RemoteGatewayRevocationResult = { .success },
        snapshot: @escaping () async -> RemoteSnapshot? = { nil },
        replay: @escaping (UInt64?) async -> RemoteEventReplayResult = { _ in .events([]) },
        authorizationState: @escaping () -> RemoteAuthorizationState = {
            RemoteAuthorizationState(defaultLevel: .control)
        },
        registerNotifications: @escaping (RemoteNotificationRegistration) -> RemoteGatewayRegistrationResult = { _ in .failed },
        execute: @escaping (RemoteCommandRequest) async -> RemoteGatewayCommandResult = { _ in .unavailable },
        eventCursor: @escaping () async -> UInt64 = { 0 },
        bindIrohEndpoint: @escaping (RemoteIrohBindingRequest, String?) -> Result<RemoteIrohBindingResponse, Error> = { _, _ in
            .failure(TestFailure.unexpectedResponse)
        }
    ) -> RemoteGatewayRequestRouter {
        RemoteGatewayRequestRouter(services: RemoteGatewayRoutingServices(
            authorize: authorize,
            pair: pair,
            unpair: unpair,
            snapshot: snapshot,
            diagnostics: { nil },
            history: { _ in nil },
            transcript: { _ in .unavailable },
            replay: replay,
            registerNotifications: registerNotifications,
            authorizationState: authorizationState,
            execute: execute,
            eventCursor: eventCursor,
            bindIrohEndpoint: bindIrohEndpoint
        ))
    }

    private func json(from response: RemoteGatewayResponse) throws -> Data {
        guard case let .json(data) = response.content else {
            throw TestFailure.unexpectedResponse
        }
        return data
    }

    private func error(from response: RemoteGatewayResponse) throws -> RemoteErrorResponse {
        guard case let .error(error) = response.content else {
            throw TestFailure.unexpectedResponse
        }
        return error
    }

    private func routeName(_ request: RemoteGatewayRequest) -> String {
        switch request {
        case .pair: "pair"
        case .pairIroh: "pair_iroh"
        case .transportBootstrap: "transport_bootstrap"
        case .bindIrohEndpoint: "bind_iroh_endpoint"
        case .unpair: "unpair"
        case .snapshot: "snapshot"
        case .diagnostics: "diagnostics"
        case .workspaces: "workspaces"
        case .sessions: "sessions"
        case .agents: "agents"
        case .workflows: "workflows"
        case .history: "history"
        case .transcript: "transcript"
        case .events: "events"
        case .command: "command"
        }
    }
}

private enum TestFailure: Error {
    case unexpectedResponse
}

@MainActor
final class RemoteIrohSecurityTests: XCTestCase {
    private final class TestClock {
        var date: Date

        init(_ date: Date) {
            self.date = date
        }
    }

    private enum PersistenceFailure: Error {
        case failed
    }

    func testIssuedLegacyAndIrohAdvertisementsShareExpiringSecret() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let manager = makeManager(clock: clock)
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: "192.0.2.1",
            server: RemoteIrohEndpointAddress(endpointID: endpointID("a"))
        )

        XCTAssertEqual(issued.legacy.oneTimeSecret, issued.iroh.oneTimeSecret)
        XCTAssertEqual(issued.legacy.expiresAt, clock.date.addingTimeInterval(300))
        XCTAssertEqual(issued.iroh.expiresAt, clock.date.addingTimeInterval(300))
        XCTAssertEqual(issued.iroh.legacyFallback, issued.legacy)
        XCTAssertEqual(Data(base64URL: issued.legacy.oneTimeSecret)?.count, 32)
    }

    func testPairingSecretExpiresAndIsSingleUse() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 2000))
        var persisted: [RemoteStoredDeviceCredential?] = []
        let manager = makeManager(clock: clock) { persisted.append($0) }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        clock.date = try XCTUnwrap(advertisement.expiresAt?.addingTimeInterval(1))

        XCTAssertThrowsError(try manager.pair(
            request: pairingRequest(secret: advertisement.oneTimeSecret),
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.pairingSecretExpired = error else {
                return XCTFail("Expected pairingSecretExpired, got \(error)")
            }
        }
        XCTAssertTrue(persisted.isEmpty)

        XCTAssertThrowsError(try manager.pair(
            request: pairingRequest(secret: advertisement.oneTimeSecret),
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.pairingSecretInvalid = error else {
                return XCTFail("Expected pairingSecretInvalid, got \(error)")
            }
        }
    }

    func testPairingReplayFailsEvenWhenCredentialPersistenceFails() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3000))
        let manager = makeManager(clock: clock) { _ in throw PersistenceFailure.failed }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        let request = pairingRequest(secret: advertisement.oneTimeSecret)

        XCTAssertThrowsError(try manager.pair(request: request, desktop: desktopSummary())) { error in
            XCTAssertTrue(error is PersistenceFailure)
        }
        XCTAssertThrowsError(try manager.pair(request: request, desktop: desktopSummary())) { error in
            guard case RemoteGatewaySecurityError.pairingSecretInvalid = error else {
                return XCTFail("Expected consumed secret rejection, got \(error)")
            }
        }
    }

    func testFreshValidIrohPairingReplacesStaleOneDeviceRecord() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3500))
        let stale = RemoteStoredDeviceCredential(
            deviceID: "stale-device",
            credential: "stale-credential",
            expiresAt: clock.date.addingTimeInterval(3600),
            deviceName: "Old phone",
            irohPeerEndpointID: endpointID("b")
        )
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock, storedDevice: stale) { persisted = $0 }
        let serverID = endpointID("a")
        let replacementClientID = endpointID("c")
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil,
            server: RemoteIrohEndpointAddress(endpointID: serverID)
        )

        let response = try manager.pairIroh(
            request: RemoteIrohPairingRequest(
                desktopInstanceID: "desktop",
                expectedServerEndpointID: serverID,
                clientEndpointID: replacementClientID,
                oneTimeSecret: issued.iroh.oneTimeSecret,
                deviceName: "Replacement phone"
            ),
            authenticatedPeerEndpointID: replacementClientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )

        XCTAssertNotEqual(response.pairingResponse.deviceID, stale.deviceID)
        XCTAssertEqual(persisted?.deviceID, response.pairingResponse.deviceID)
        XCTAssertEqual(persisted?.irohPeerEndpointID, replacementClientID)
        XCTAssertFalse(manager.isAuthorized("Bearer \(stale.credential)"))
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer \(response.pairingResponse.credential)",
            deviceID: response.pairingResponse.deviceID,
            authenticatedPeerEndpointID: replacementClientID
        ))
    }

    func testIrohPairingAuthenticatesBothEndpointBindingsBeforeConsumingSecret() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 4000))
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock) { persisted = $0 }
        let serverID = endpointID("a")
        let clientID = endpointID("b")
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil,
            server: RemoteIrohEndpointAddress(endpointID: serverID)
        )
        let request = RemoteIrohPairingRequest(
            desktopInstanceID: "desktop",
            expectedServerEndpointID: serverID,
            clientEndpointID: clientID,
            oneTimeSecret: issued.iroh.oneTimeSecret,
            deviceName: "Phone"
        )

        XCTAssertThrowsError(try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: endpointID("c"),
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.endpointBindingInvalid = error else {
                return XCTFail("Expected endpointBindingInvalid, got \(error)")
            }
        }

        let response = try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: clientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )
        XCTAssertEqual(response.serverEndpointID, serverID)
        XCTAssertEqual(response.clientEndpointID, clientID)
        XCTAssertEqual(persisted?.irohPeerEndpointID, clientID)
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer \(response.pairingResponse.credential)",
            deviceID: response.pairingResponse.deviceID,
            authenticatedPeerEndpointID: clientID
        ))

        XCTAssertThrowsError(try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: clientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        ))
    }

    func testAuthenticatedHTTPSBindingUpdatesExistingCredentialWithoutReplacement() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5000))
        let original = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone"
        )
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock, storedDevice: original) { persisted = $0 }
        let serverID = endpointID("a")
        let firstClientID = endpointID("b")
        let request = RemoteIrohBindingRequest(
            desktopInstanceID: "desktop",
            deviceID: original.deviceID,
            expectedServerEndpointID: serverID,
            clientEndpointID: firstClientID
        )

        let response = try manager.bindIrohEndpoint(
            request: request,
            authorizationHeader: "Bearer bearer",
            serverEndpointID: serverID
        )
        XCTAssertEqual(response.deviceID, original.deviceID)
        XCTAssertEqual(persisted?.credential, original.credential)
        XCTAssertEqual(persisted?.irohPeerEndpointID, firstClientID)
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: firstClientID
        ))
        XCTAssertFalse(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: endpointID("c")
        ))

        let replacementClientID = endpointID("d")
        _ = try manager.bindIrohEndpoint(
            request: RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: original.deviceID,
                expectedServerEndpointID: serverID,
                clientEndpointID: replacementClientID
            ),
            authorizationHeader: "Bearer bearer",
            serverEndpointID: serverID
        )
        XCTAssertEqual(persisted?.irohPeerEndpointID, replacementClientID)
        XCTAssertFalse(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: firstClientID
        ))
    }

    func testBindingRejectsWrongBearerDeviceAndServer() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6000))
        let original = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone"
        )
        let manager = makeManager(clock: clock, storedDevice: original)
        let serverID = endpointID("a")

        for (request, bearer, actualServer) in [
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "device",
                expectedServerEndpointID: serverID,
                clientEndpointID: endpointID("b")
            ), "Bearer wrong", serverID),
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "other",
                expectedServerEndpointID: serverID,
                clientEndpointID: endpointID("b")
            ), "Bearer bearer", serverID),
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "device",
                expectedServerEndpointID: endpointID("c"),
                clientEndpointID: endpointID("b")
            ), "Bearer bearer", serverID)
        ] {
            XCTAssertThrowsError(try manager.bindIrohEndpoint(
                request: request,
                authorizationHeader: bearer,
                serverEndpointID: actualServer
            ))
        }
    }

    func testPersistedPairingFieldsAreBoundedAndEndpointIDsAreCanonical() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6500))
        var persisted: RemoteStoredDeviceCredential?
        let manager = makeManager(clock: clock) { persisted = $0 }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        let request = RemotePairingRequest(
            desktopInstanceID: "desktop",
            oneTimeSecret: advertisement.oneTimeSecret,
            deviceName: String(repeating: "📱", count: 512)
        )
        _ = try manager.pair(request: request, desktop: desktopSummary())
        XCTAssertEqual(persisted?.deviceName.count, RemotePairingManager.maximumDeviceNameCharacters)

        let boundManager = makeManager(clock: clock, storedDevice: persisted)
        XCTAssertThrowsError(try boundManager.bindIrohEndpoint(
            request: RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: persisted?.deviceID ?? "",
                expectedServerEndpointID: endpointID("a"),
                clientEndpointID: "not-an-endpoint"
            ),
            authorizationHeader: "Bearer \(persisted?.credential ?? "")",
            serverEndpointID: endpointID("a")
        )) { error in
            guard case RemoteGatewaySecurityError.endpointBindingInvalid = error else {
                return XCTFail("Expected endpointBindingInvalid, got \(error)")
            }
        }
    }

    func testStoredCredentialDecodesLegacyShapeAndOldDecoderIgnoresBinding() throws {
        let oldJSON = """
        {
          "deviceID": "device",
          "credential": "bearer",
          "expiresAt": 1000
        }
        """
        let decoded = try JSONDecoder().decode(
            RemoteStoredDeviceCredential.self,
            from: Data(oldJSON.utf8)
        )
        XCTAssertEqual(decoded.deviceName, "Remote device")
        XCTAssertNil(decoded.irohPeerEndpointID)

        let updated = RemoteStoredDeviceCredential(
            deviceID: decoded.deviceID,
            credential: decoded.credential,
            expiresAt: decoded.expiresAt,
            deviceName: decoded.deviceName,
            irohPeerEndpointID: endpointID("a")
        )
        struct LegacyCredential: Decodable {
            let deviceID: String
            let credential: String
            let expiresAt: Date
            let deviceName: String
        }
        let legacy = try JSONDecoder().decode(
            LegacyCredential.self,
            from: JSONEncoder().encode(updated)
        )
        XCTAssertEqual(legacy.deviceID, updated.deviceID)
        XCTAssertEqual(legacy.credential, updated.credential)
        XCTAssertEqual(legacy.expiresAt, updated.expiresAt)
        XCTAssertEqual(legacy.deviceName, updated.deviceName)
    }

    func testLegacyCredentialMigratesAndCannotReturnAfterRevocation() throws {
        let backend = TestSecureStorageBackend()
        let legacy = Data("old pairing fixture".utf8)
        let store = RemoteGatewayKeychain(backend: backend) { service in
            XCTAssertEqual(service, SecureStorageAccount.remotePairedDevice.identifier)
            return legacy
        }
        XCTAssertEqual(try store.read(.remotePairedDevice), legacy)
        XCTAssertEqual(backend.value(for: .remotePairedDevice), legacy.base64EncodedString())
        try store.remove(.remotePairedDevice)

        let reopened = RemoteGatewayKeychain(backend: backend) { _ in
            XCTFail("A revoked device must never fall back to legacy storage.")
            return legacy
        }
        XCTAssertNil(try reopened.read(.remotePairedDevice))

        let replacement = Data("new pairing fixture".utf8)
        try reopened.write(replacement, for: .remotePairedDevice)
        XCTAssertEqual(try reopened.read(.remotePairedDevice), replacement)
    }

    func testFailedDurableRevocationRetainsPairedAuthorizationState() {
        let clock = TestClock(Date(timeIntervalSince1970: 7000))
        let stored = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone",
            irohPeerEndpointID: endpointID("a")
        )
        let manager = makeManager(clock: clock, storedDevice: stored) { _ in
            throw PersistenceFailure.failed
        }

        XCTAssertThrowsError(try manager.revokeDevice()) { error in
            XCTAssertTrue(error is PersistenceFailure)
        }
        XCTAssertTrue(manager.isPaired)
        XCTAssertTrue(manager.isAuthorized("Bearer bearer"))
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: endpointID("a")
        ))
    }

    func testConstantTimeComparisonHandlesEqualDifferentAndDifferentLengthValues() {
        XCTAssertTrue(RemoteConstantTimeComparison.equals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([9, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([1, 2, 9]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([1, 2]), Data([1, 2, 0])))
    }

    func testDesktopIdentityStoreLoadsCreatesAndReplacesCorruptValues() throws {
        let stable = Data(repeating: 1, count: 32)
        var writes: [Data] = []
        let loaded = try RemoteIrohIdentityStore(
            read: { stable },
            write: { writes.append($0) },
            generate: { XCTFail("Should not generate")
                return Data()
            }
        ).loadOrCreate()
        XCTAssertEqual(loaded, RemoteIrohIdentity(secret: stable, origin: .loaded))
        XCTAssertTrue(writes.isEmpty)

        let createdSecret = Data(repeating: 2, count: 32)
        let created = try RemoteIrohIdentityStore(
            read: { nil },
            write: { writes.append($0) },
            generate: { createdSecret }
        ).loadOrCreate()
        XCTAssertEqual(created, RemoteIrohIdentity(secret: createdSecret, origin: .created))
        XCTAssertEqual(writes.last, createdSecret)

        let replacement = Data(repeating: 3, count: 32)
        let replaced = try RemoteIrohIdentityStore(
            read: { Data(repeating: 9, count: 31) },
            write: { writes.append($0) },
            generate: { replacement }
        ).loadOrCreate()
        XCTAssertEqual(replaced, RemoteIrohIdentity(secret: replacement, origin: .replacedCorruptValue))
        XCTAssertEqual(writes.last, replacement)
    }

    private func makeManager(
        clock: TestClock,
        storedDevice: RemoteStoredDeviceCredential? = nil,
        persist: @escaping (RemoteStoredDeviceCredential?) throws -> Void = { _ in }
    ) -> RemotePairingManager {
        RemotePairingManager(
            desktopInstanceID: "desktop",
            certificateSHA256: String(repeating: "f", count: 64),
            storedDevice: storedDevice,
            now: { clock.date },
            randomBytes: { count in Data(repeating: UInt8(count), count: count) },
            persistStoredDevice: persist
        )
    }

    private func pairingRequest(secret: String) -> RemotePairingRequest {
        RemotePairingRequest(
            desktopInstanceID: "desktop",
            oneTimeSecret: secret,
            deviceName: "Phone"
        )
    }

    private func desktopSummary() -> RemoteDesktopSummary {
        RemoteDesktopSummary(
            instanceID: "desktop",
            displayName: "Mac",
            appVersion: "test",
            isAvailable: true
        )
    }

    private func endpointID(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}

private extension Data {
    init?(base64URL: String) {
        var normalized = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}

@MainActor
final class RemoteMutationBehaviorTests: XCTestCase {
    @MainActor
    func testRemoteAttachmentUploadRequiresControlAndConsumesOnlyCompleteSubmission() throws {
        XCTAssertEqual(RemoteGatewayRequestRouter.requiredAuthority(for: .uploadAttachment), .control)
        let submissionID = UUID()
        let attachmentID = UUID()
        let now = Date(timeIntervalSince1970: 100)
        var uploads = RemoteAttachmentUploads()
        func chunk(name: String = "notes.txt", offset: Int, bytes: [UInt8]) -> RemoteAttachmentChunk {
            RemoteAttachmentChunk(
                submissionID: submissionID, attachmentID: attachmentID, fileName: name,
                fileSize: 3, offset: offset, bytes: Data(bytes)
            )
        }

        XCTAssertThrowsError(try uploads.append(chunk(name: "../notes.txt", offset: 0, bytes: [1]), now: now))
        XCTAssertThrowsError(try uploads.append(chunk(offset: 1, bytes: [2]), now: now))
        try uploads.append(chunk(offset: 0, bytes: [1, 2]), now: now)
        try uploads.append(chunk(offset: 0, bytes: [1, 2]), now: now)
        XCTAssertThrowsError(try uploads.append(chunk(offset: 0, bytes: [9]), now: now))
        XCTAssertThrowsError(try uploads.take(submissionID: submissionID, ids: [attachmentID], now: now))
        try uploads.append(chunk(offset: 2, bytes: [3]), now: now)

        XCTAssertThrowsError(try uploads.take(submissionID: UUID(), ids: [attachmentID], now: now))
        let files = try uploads.take(submissionID: submissionID, ids: [attachmentID], now: now)
        XCTAssertEqual(files.map(\.name), ["notes.txt"])
        XCTAssertEqual(files.map(\.bytes), [Data([1, 2, 3])])
        XCTAssertThrowsError(try uploads.take(submissionID: submissionID, ids: [attachmentID], now: now))

        try uploads.append(chunk(offset: 0, bytes: [4, 5, 6]), now: now)
        XCTAssertThrowsError(try uploads.take(
            submissionID: submissionID, ids: [attachmentID], now: now.addingTimeInterval(121)
        ))
    }

    func testMCPInvalidParamsBecomeActionableRemoteRejection() {
        let message = WindowRemoteAgentControlService.remoteRejectionMessage(
            for: MCPError.invalidParams("The requested agent session is not currently available.")
        )

        XCTAssertEqual(message, "The requested agent session is not currently available.")
    }

    func testMCPInternalFailuresDoNotExposeInternalDetails() {
        let sensitive = "/private/sensitive/provider-state.json"
        let failures: [MCPError] = [
            .internalError(sensitive),
            .serverError(code: -32000, message: sensitive),
            .parseError(sensitive),
            .methodNotFound(sensitive)
        ]

        for failure in failures {
            let message = WindowRemoteAgentControlService.remoteRejectionMessage(for: failure)
            XCTAssertEqual(message, "The Mac could not deliver this command to the agent session.")
            XCTAssertFalse(message.contains(sensitive))
        }
    }

    func testMCPTransportFailureDoesNotExposeInternalDetails() {
        let message = WindowRemoteAgentControlService.remoteRejectionMessage(
            for: MCPError.transportError(NSError(
                domain: "fixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "/private/sensitive/socket failed"]
            ))
        )

        XCTAssertEqual(
            message,
            "The Mac lost its connection to the agent while delivering this command. Try again."
        )
        XCTAssertFalse(message.contains("/private/sensitive"))
    }

    func testRemoteMutationBoundaryRejectsIncompleteRequestsForEveryMutation() async {
        let service = WindowRemoteAgentControlService(windowStatesManager: WindowStatesManager.shared)

        for operation in RemoteMutationFailurePolicy.mutationOperations {
            do {
                _ = try await service.execute(RemoteCommandRequest(operation: operation))
                XCTFail("Incomplete \(operation.rawValue) request must be rejected.")
            } catch let error as RemoteAgentControlServiceError {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            } catch {
                XCTFail("Expected a typed remote rejection for \(operation.rawValue), got \(error).")
            }
        }
    }

    func testCancelRejectsTerminalSessionWithoutChangingItsState() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let agentMode = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first?.id)
        let session = await agentMode.ensureSessionReady(tabID: tabID)
        let sessionID = UUID()
        _ = agentMode.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .completed

        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id.uuidString)
        let request = RemoteCommandRequest(
            operation: .cancel,
            workspaceID: workspaceID,
            sessionID: sessionID
        )
        let service = WindowRemoteAgentControlService(windowStatesManager: WindowStatesManager.shared)

        do {
            _ = try await service.execute(request)
            XCTFail("A terminal session must not accept cancellation.")
        } catch let error as RemoteAgentControlServiceError {
            guard case .commandRejected = error else {
                return XCTFail("Expected command rejection, got \(error).")
            }
        }
        XCTAssertEqual(session.runState, .completed)
    }

    func testConfigureSessionRejectsActiveRunWithoutChangingSelection() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let agentMode = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first?.id)
        let session = await agentMode.ensureSessionReady(tabID: tabID)
        let sessionID = UUID()
        _ = agentMode.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .running
        let originalAgent = session.selectedAgent
        let originalModel = session.selectedModelRaw

        do {
            _ = try await agentMode.mcpConfigureRemoteSession(
                tabID: tabID,
                sessionID: sessionID,
                agentRaw: nil,
                modelRaw: "unavailable-model",
                reasoningEffortRaw: nil
            )
            XCTFail("An active run must reject selection changes.")
        } catch let error as MCPError {
            XCTAssertEqual(
                WindowRemoteAgentControlService.remoteRejectionMessage(for: error),
                "Model and effort controls are locked during an active run."
            )
        }
        XCTAssertEqual(session.selectedAgent, originalAgent)
        XCTAssertEqual(session.selectedModelRaw, originalModel)
    }

    func testStartCommandSavesConfiguredSessionAndDeliversUploadedFile() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.apiSettingsViewModel.isClaudeCodeConnected = true
        try await AsyncTestWait.waitUntil("remote run fixture availability") {
            window.apiSettingsViewModel.agentAvailability.claudeCodeAvailable
        }
        let agentMode = window.agentModeViewModel
        var sessionIDAtDispatch: UUID?
        var savedAgentAtDispatch: String?
        var inputAtDispatch: String?
        var attachmentAtDispatch: AgentFileAttachment?
        agentMode.test_providerSwitchStart = { session, providerInput, _ in
            inputAtDispatch = providerInput
            attachmentAtDispatch = session.transcript.turns.last?.request?.attachments.first
            if let sessionID = session.activeAgentSessionID {
                let saved = try? await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
                savedAgentAtDispatch = saved?.agentKind
                sessionIDAtDispatch = sessionID
            }
        }
        defer { agentMode.test_providerSwitchStart = nil }

        let service = WindowRemoteAgentControlService(windowStatesManager: WindowStatesManager.shared)
        let submissionID = UUID()
        let attachmentID = UUID()
        let contents = "Sample bytes uploaded from iPhone."
        let bytes = Data(contents.utf8)
        let upload = try await service.execute(.init(
            operation: .uploadAttachment,
            attachmentChunk: .init(
                submissionID: submissionID, attachmentID: attachmentID, fileName: "notes.txt",
                fileSize: bytes.count, offset: 0, bytes: bytes
            )
        ))
        XCTAssertTrue(upload.accepted)
        let response = try await service.execute(.init(
            commandID: submissionID,
            operation: .startRun,
            workspaceID: workspace.id.uuidString,
            message: "Exercise the Remote launch path.",
            agentID: "claudeCode",
            attachmentIDs: [attachmentID]
        ))

        XCTAssertTrue(response.accepted)
        let sessionID = try XCTUnwrap(response.sessionID)
        try await AsyncTestWait.waitUntil("remote run reached the stub provider") { sessionIDAtDispatch != nil }
        XCTAssertEqual(sessionIDAtDispatch, sessionID)
        XCTAssertEqual(savedAgentAtDispatch, "claudeCode")
        XCTAssertEqual(response.resolvedSelection?.agentID, "claudeCode")
        let attachment = try XCTUnwrap(attachmentAtDispatch)
        XCTAssertEqual(attachment.title, "notes.txt")
        guard case let .localFile(path) = attachment.source else {
            return XCTFail("Expected the uploaded file in managed attachment storage.")
        }
        let escapedPath = AgentSessionProviderInputRuntime.escapePathForAtCommand(path)
        XCTAssertTrue(try XCTUnwrap(inputAtDispatch).contains("@\(escapedPath)"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }

    func testProvisionalSessionRollbackReportsCompleteCleanup() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let target = try await window.agentModeViewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Remote rollback fixture"
        )

        let cleanupCompleted = await window.agentModeViewModel.mcpDiscardSessionTarget(target)

        XCTAssertEqual(cleanupCompleted, .complete)
        XCTAssertNil(window.agentModeViewModel.session(for: target.tabID, createIfNeeded: false))
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Remote mutation (UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "remoteMutationTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }
}

@MainActor
final class RemoteProducerParityTests: XCTestCase {
    func testWorkflowDescriptorsUseAuthoritativeVisualsAndFeaturedRanks() throws {
        let customID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000901"))
        let custom = AgentWorkflowDefinition(
            customID: customID,
            displayName: "Custom Audit",
            iconName: "checkmark.shield.fill",
            accentColorHex: "#123456",
            descriptionText: "Audits a custom boundary."
        )
        let orchestrate = AgentWorkflow.orchestrate.definition
        let review = AgentWorkflow.review.definition

        let descriptors = DesktopRemoteCatalogService.workflowDescriptors(
            workflows: [orchestrate, review, custom],
            featuredWorkflowIDs: [review.id, custom.id, orchestrate.id]
        )

        let orchestrateDescriptor = try XCTUnwrap(descriptors.first { $0.id == orchestrate.id })
        XCTAssertEqual(orchestrateDescriptor.displayName, "Orchestrate")
        XCTAssertEqual(orchestrateDescriptor.iconName, "arrow.triangle.branch")
        XCTAssertEqual(orchestrateDescriptor.accentColorHex, "#34C759")
        XCTAssertEqual(orchestrateDescriptor.descriptionText, orchestrate.descriptionText)
        XCTAssertEqual(orchestrateDescriptor.featuredRank, 2)
        XCTAssertTrue(orchestrateDescriptor.isBuiltIn)

        let customDescriptor = try XCTUnwrap(descriptors.first { $0.id == custom.id })
        XCTAssertEqual(customDescriptor.iconName, "checkmark.shield.fill")
        XCTAssertEqual(customDescriptor.accentColorHex, "#123456")
        XCTAssertEqual(customDescriptor.descriptionText, "Audits a custom boundary.")
        XCTAssertEqual(customDescriptor.featuredRank, 1)
        XCTAssertFalse(customDescriptor.isBuiltIn)
        XCTAssertFalse(descriptors.contains { $0.displayName == "Director" })
    }

    func testCatalogKeepsReasoningForAGroupedCodexModel() throws {
        let discovery = AgentModelCatalog.discoveryAgent(
            .codexExec,
            availability: .none,
            modelOptions: [
                AgentModelOption(
                    rawValue: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", description: nil, isDefault: true,
                    supportedReasoningEfforts: [.medium, .high], defaultReasoningEffort: .medium
                )
            ]
        )
        let model = try XCTUnwrap(discovery.models.first)
        XCTAssertEqual(model.remoteReasoningEfforts(for: .codexExec).map(\.id), ["medium", "high"])
        XCTAssertEqual(try AgentModeViewModel.resolveRemoteReasoningEffort(
            for: model, agent: .codexExec, requestedEffort: "high", currentEffort: nil
        ), "high")
        XCTAssertEqual(try AgentModeViewModel.resolveRemoteReasoningEffort(
            for: model, agent: .codexExec, currentEffort: nil
        ), "medium")
    }

    func testSwitchingToAProviderWithoutReasoningDropsTheOldEffort() throws {
        let discovery = AgentModelCatalog.discoveryAgent(
            .openCode,
            availability: .none,
            modelOptions: [
                AgentModelOption(rawValue: "opencode/example", displayName: "Example", description: nil, isDefault: true)
            ]
        )
        let model = try XCTUnwrap(discovery.models.first)
        XCTAssertNil(try AgentModeViewModel.resolveRemoteReasoningEffort(for: model, agent: .openCode, currentEffort: "high"))
    }

    func testUploadedPDFUsesAStablePathBeforeProviderDispatch() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("remote-pdf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent("AgentSessions/attachments", isDirectory: true)
        let sessionID = UUID()
        let bytes = Data("%PDF-1.4\n%%EOF\n".utf8)
        let attachments = try await RemoteAttachmentUploads.prepareFiles(
            [.init(name: "notes.pdf", size: bytes.count, bytes: bytes)], sessionID: sessionID, workspaceDirectory: workspace, retainedRoot: root
        )
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachment.kind, .pdf)
        let store = AgentSessionAttachmentStore(rootURL: root)
        let retained = try XCTUnwrap(store.locateRetainedFile(attachmentID: attachment.id, sessionID: sessionID))
        let initialMessage = AgentSessionProviderInputRuntime.renderProviderMessage(
            text: "Read the PDF", attachments: attachments, agent: .codexExec
        )
        XCTAssertTrue(initialMessage.contains(retained.path))
        _ = await AgentSessionDataService.shared.retainConsumedAttachments(
            attachments, sessionID: sessionID, store: store, workspaceDirectory: workspace
        )
        XCTAssertEqual(try Data(contentsOf: retained), bytes)
    }

    func testCatalogDefaultSelectionUsesPersistedPreferenceInsteadOfTransientWindowSelection() throws {
        let agents = [
            RemoteAgentDescriptor(
                id: "codexExec",
                displayName: "Codex",
                models: ["transient-model", "persisted-model"],
                isAvailable: true,
                modelDescriptors: [
                    RemoteModelDescriptor(id: "transient-model", displayName: "Transient"),
                    RemoteModelDescriptor(
                        id: "persisted-model", displayName: "Persisted",
                        reasoningEfforts: [.init(id: "high", displayName: "High")]
                    )
                ],
                defaultModelID: "transient-model"
            )
        ]
        let preferred = RemoteAgentSelection(
            agentID: "codexExec",
            modelID: "persisted-model",
            reasoningEffort: "high"
        )

        let resolved = try XCTUnwrap(DesktopRemoteCatalogService.resolvedDefaultSelection(
            preferred,
            agents: agents
        ))

        XCTAssertEqual(resolved, preferred)
    }

    func testAcceptedRunMetadataIsWriteOnceForOriginAndUpdatesLastStart() {
        let firstStart = Date(timeIntervalSinceReferenceDate: 10)
        let secondStart = Date(timeIntervalSinceReferenceDate: 20)
        let session = AgentModeViewModel.TabSession(tabID: UUID())

        XCTAssertTrue(session.recordAcceptedRunMetadata(
            workflow: AgentWorkflow.orchestrate.definition,
            startedAt: firstStart
        ))
        XCTAssertEqual(session.originWorkflowID, AgentWorkflow.orchestrate.definition.id)
        XCTAssertEqual(session.originWorkflowDisplayName, "Orchestrate")
        XCTAssertEqual(session.lastRunStartedAt, firstStart)

        XCTAssertTrue(session.recordAcceptedRunMetadata(
            workflow: AgentWorkflow.review.definition,
            startedAt: secondStart
        ))
        XCTAssertEqual(session.originWorkflowID, AgentWorkflow.orchestrate.definition.id)
        XCTAssertEqual(session.originWorkflowDisplayName, "Orchestrate")
        XCTAssertEqual(session.lastRunStartedAt, secondStart)

        let noWorkflowOrigin = AgentModeViewModel.TabSession(tabID: UUID())
        noWorkflowOrigin.recordAcceptedRunMetadata(workflow: nil, startedAt: firstStart)
        noWorkflowOrigin.recordAcceptedRunMetadata(workflow: AgentWorkflow.review.definition, startedAt: secondStart)
        XCTAssertNil(noWorkflowOrigin.originWorkflowID)
        XCTAssertNil(noWorkflowOrigin.originWorkflowDisplayName)
        XCTAssertEqual(noWorkflowOrigin.lastRunStartedAt, secondStart)

        let failedProvisionalStart = AgentModeViewModel.TabSession(tabID: UUID())
        failedProvisionalStart.selectedAgent = .codexExec
        XCTAssertFalse(failedProvisionalStart.recordRunMetadataIfAccepted(
            wasActiveBeforeStart: false,
            dispatchAccepted: false,
            workflow: AgentWorkflow.orchestrate.definition,
            startedAt: firstStart
        ))
        XCTAssertNil(failedProvisionalStart.originWorkflowID)
        XCTAssertNil(failedProvisionalStart.originWorkflowDisplayName)
        XCTAssertNil(failedProvisionalStart.lastRunStartedAt)
    }

    func testLegacySessionAndMetadataIndexDecodeWithoutLaunchMetadata() throws {
        let sessionPayload = """
        {
          "id": "00000000-0000-0000-0000-000000000902",
          "serializationVersion": 6,
          "name": "Legacy Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(sessionPayload.utf8))
        XCTAssertNil(session.originWorkflowID)
        XCTAssertNil(session.originWorkflowDisplayName)
        XCTAssertNil(session.lastRunStartedAt)

        let indexPayload = """
        {
          "schemaVersion": 5,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000903",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000903.json",
              "name": "Legacy Indexed Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """
        let index = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(indexPayload.utf8))
        let record = try XCTUnwrap(index.entries.first)
        XCTAssertNil(record.originWorkflowID)
        XCTAssertNil(record.originWorkflowDisplayName)
        XCTAssertNil(record.lastRunStartedAt)
    }

    func testWorkspaceHistoryInventoryFindsSavedFileMissingFromExistingIndex() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        let importWorkspace = makeTemporaryWorkspace()
        let workspaceFolder = try XCTUnwrap(workspace.customStoragePath)
        let importFolder = try XCTUnwrap(importWorkspace.customStoragePath)
        defer {
            try? FileManager.default.removeItem(at: workspaceFolder)
            try? FileManager.default.removeItem(at: importFolder)
        }

        let firstID = UUID()
        let importedID = UUID()
        func fixture(_ id: UUID) -> AgentSession {
            AgentSessionPayloadBuilder.makePayload(
                session: AgentTabSession(tabID: UUID()),
                sessionID: id,
                workspaceID: workspace.id,
                name: "Saved chat",
                snapshot: .init(
                    transcript: .empty,
                    projectionCounts: .zero,
                    canonicalVisibleRowCount: 1,
                    lastUserMessageAt: nil
                )
            )
        }
        let first = try await service.saveAgentSession(fixture(firstID), for: workspace)
        let indexed = try await service.indexedAgentSessionMetadataRecords(for: workspace)
        XCTAssertEqual(indexed.map(\.id), [firstID])

        let incoming = try await service.saveAgentSession(fixture(importedID), for: importWorkspace)
        try FileManager.default.copyItem(
            at: incoming,
            to: first.deletingLastPathComponent().appendingPathComponent(incoming.lastPathComponent)
        )

        let refreshed = try await service.indexedAgentSessionMetadataRecords(for: workspace, verifyInventory: true)
        XCTAssertEqual(Set(refreshed.map(\.id)), Set([firstID, importedID]))
    }

    func testDataServicePreservesLaunchMetadataAcrossFullStubIndexAndSidebar() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        let storageURL = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000904"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000905"))
        let startedAt = Date(timeIntervalSinceReferenceDate: 30)
        let live = AgentTabSession(tabID: tabID)
        live.recordAcceptedRunMetadata(workflow: AgentWorkflow.deepPlan.definition, startedAt: startedAt)
        let session = AgentSessionPayloadBuilder.makePayload(
            session: live,
            sessionID: sessionID,
            workspaceID: workspace.id,
            name: "Durable Remote Metadata",
            snapshot: .init(
                transcript: .empty,
                projectionCounts: .zero,
                canonicalVisibleRowCount: 1,
                lastUserMessageAt: nil
            )
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let loaded = try await service.loadAgentSession(from: fileURL)
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let records = try await service.indexedAgentSessionMetadataRecords(for: workspace)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Durable Remote Metadata"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        for value in [loaded, stub] {
            XCTAssertEqual(value.originWorkflowID, AgentWorkflow.deepPlan.definition.id)
            XCTAssertEqual(value.originWorkflowDisplayName, AgentWorkflow.deepPlan.displayName)
            XCTAssertEqual(value.lastRunStartedAt, startedAt)
        }
        let record = try XCTUnwrap(records.first { $0.id == sessionID })
        XCTAssertEqual(record.originWorkflowID, AgentWorkflow.deepPlan.definition.id)
        XCTAssertEqual(record.originWorkflowDisplayName, AgentWorkflow.deepPlan.displayName)
        XCTAssertEqual(record.lastRunStartedAt, startedAt)
        let entry = try XCTUnwrap(sidebar.entriesBySessionID[sessionID])
        XCTAssertEqual(entry.originWorkflowID, AgentWorkflow.deepPlan.definition.id)
        XCTAssertEqual(entry.originWorkflowDisplayName, AgentWorkflow.deepPlan.displayName)
        XCTAssertEqual(entry.lastRunStartedAt, startedAt)
    }

    func testLiveSessionProjectionMatchesSessionIdentityNotOnlyComposeTab() {
        let tabID = fixedUUID(906)
        let activeSessionID = fixedUUID(907)
        let inactiveSessionID = fixedUUID(908)
        let live = AgentModeViewModel.TabSession(tabID: tabID)
        live.testInstallPersistentSessionBinding(sessionID: activeSessionID)
        live.originWorkflowID = AgentWorkflow.orchestrate.definition.id

        let liveByTabID = [tabID: live]
        XCTAssertTrue(AgentModeRemoteSessionQueryService.matchingLiveSession(
            entryID: activeSessionID,
            tabID: tabID,
            liveByTabID: liveByTabID
        ) === live)
        XCTAssertNil(AgentModeRemoteSessionQueryService.matchingLiveSession(
            entryID: inactiveSessionID,
            tabID: tabID,
            liveByTabID: liveByTabID
        ))
    }

    func testTranscriptProjectionClassifiesNarrativeAndKeepsRawDetailsOptIn() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let request = AgentChatItem(
            id: fixedUUID(910),
            timestamp: timestamp,
            kind: .user,
            text: #"Use {"token":"request-secret"}"#,
            sequenceIndex: 0
        )
        let preamble = AgentTranscriptActivity(
            id: fixedUUID(911),
            timestamp: timestamp.addingTimeInterval(1),
            sequenceIndex: 1,
            role: .assistant,
            itemKind: .assistantInline,
            text: "Checking the relevant files",
            isSubstantiveAssistant: false
        )
        let answer = AgentTranscriptActivity(
            id: fixedUUID(912),
            timestamp: timestamp.addingTimeInterval(2),
            sequenceIndex: 2,
            role: .assistant,
            itemKind: .assistant,
            text: "The implementation is complete.",
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: true
        )
        let substantiveAnswer = AgentTranscriptActivity(
            id: fixedUUID(916),
            timestamp: timestamp.addingTimeInterval(3),
            sequenceIndex: 3,
            role: .assistant,
            itemKind: .assistant,
            text: "A second answer without a conclusion marker.",
            isSubstantiveAssistant: true
        )
        let failedTool = AgentTranscriptActivity(
            id: fixedUUID(913),
            timestamp: timestamp.addingTimeInterval(4),
            sequenceIndex: 4,
            role: .toolExecution,
            itemKind: .toolResult,
            text: #"{"password":"raw-result"}"#,
            toolExecution: toolExecution(
                name: "exec_command",
                status: .failed,
                argsJSON: #"{"api_key":"raw-argument"}"#,
                resultJSON: #"{"password":"raw-result"}"#,
                isError: true,
                summaryText: "Command failed"
            ),
            reasoning: "Bearer raw-reasoning"
        )
        let question = AgentTranscriptActivity(
            id: fixedUUID(914),
            timestamp: timestamp.addingTimeInterval(5),
            sequenceIndex: 5,
            role: .toolExecution,
            itemKind: .toolCall,
            text: #"{"question":"Choose?"}"#,
            toolExecution: toolExecution(name: "ask_user", status: .running)
        )
        let permission = AgentTranscriptActivity(
            id: fixedUUID(917),
            timestamp: timestamp.addingTimeInterval(6),
            sequenceIndex: 6,
            role: .toolExecution,
            itemKind: .toolCall,
            text: "",
            toolExecution: toolExecution(name: "request_permissions", status: .running)
        )
        let approval = AgentTranscriptActivity(
            id: fixedUUID(918),
            timestamp: timestamp.addingTimeInterval(7),
            sequenceIndex: 7,
            role: .toolExecution,
            itemKind: .toolCall,
            text: "",
            toolExecution: toolExecution(name: "request_approval", status: .running)
        )
        let compact = AgentTranscriptActivity(
            id: fixedUUID(919),
            timestamp: timestamp.addingTimeInterval(8),
            sequenceIndex: 8,
            role: .progress,
            itemKind: .system,
            text: "Indexed three files"
        )
        let summaryID = fixedUUID(950)
        let turn = AgentTranscriptTurn(
            id: fixedUUID(915),
            request: AgentTranscriptRequestAnchor(from: request),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    startedAt: timestamp,
                    activities: [
                        preamble,
                        answer,
                        substantiveAnswer,
                        failedTool,
                        question,
                        permission,
                        approval,
                        compact
                    ]
                )
            ],
            conclusionActivityID: answer.id,
            retentionTier: .condensed,
            summary: AgentTranscriptTurnSummary(
                middleSummaryItemID: summaryID,
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: "Compacted final answer",
                middleSummaryText: nil,
                toolCount: 3,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 3,
                hadWarning: false,
                hadError: true
            ),
            startedAt: timestamp,
            lastActivityAt: timestamp.addingTimeInterval(9)
        )
        let transcript = AgentTranscript(turns: [turn], nextSequenceIndex: 10)

        let sanitized = WindowRemoteReadService.project(transcript: transcript, includeDetails: false)
        XCTAssertEqual(sanitized.first?.semanticKind, .userRequest)
        XCTAssertEqual(sanitized.first?.text, #"Use {"token":"[REDACTED]"}"#)
        XCTAssertEqual(sanitized.first { $0.id == preamble.id }?.semanticKind, .assistantPreamble)
        XCTAssertEqual(sanitized.first { $0.id == answer.id }?.semanticKind, .assistantAnswer)
        XCTAssertEqual(sanitized.first { $0.id == answer.id }?.kind, .conclusion)
        XCTAssertEqual(sanitized.first { $0.id == substantiveAnswer.id }?.semanticKind, .assistantAnswer)
        XCTAssertEqual(sanitized.first { $0.id == failedTool.id }?.semanticKind, .error)
        XCTAssertEqual(sanitized.first { $0.id == failedTool.id }?.text, "Command failed")
        XCTAssertNil(sanitized.first { $0.id == failedTool.id }?.detail)
        XCTAssertEqual(sanitized.first { $0.id == question.id }?.semanticKind, .question)
        XCTAssertNil(sanitized.first { $0.id == question.id }?.text)
        XCTAssertEqual(sanitized.first { $0.id == permission.id }?.semanticKind, .permission)
        XCTAssertEqual(sanitized.first { $0.id == approval.id }?.semanticKind, .approval)
        XCTAssertEqual(sanitized.first { $0.id == compact.id }?.semanticKind, .compactActivity)
        XCTAssertEqual(sanitized.first { $0.id == summaryID }?.semanticKind, .summary)
        XCTAssertEqual(sanitized.first { $0.id == summaryID }?.text, "Compacted final answer")

        let encodedDefault = try String(decoding: JSONEncoder().encode(sanitized), as: UTF8.self)
        XCTAssertFalse(encodedDefault.contains("raw-argument"))
        XCTAssertFalse(encodedDefault.contains("raw-result"))
        XCTAssertFalse(encodedDefault.contains("raw-reasoning"))
        XCTAssertFalse(encodedDefault.contains("request-secret"))

        let detailed = WindowRemoteReadService.project(transcript: transcript, includeDetails: true)
        let toolDetail = try XCTUnwrap(detailed.first { $0.id == failedTool.id }?.detail)
        XCTAssertEqual(toolDetail.argumentsJSON, #"{"api_key":"[REDACTED]"}"#)
        XCTAssertEqual(toolDetail.resultJSON, #"{"password":"[REDACTED]"}"#)
        XCTAssertEqual(toolDetail.reasoning, "Bearer [REDACTED]")
    }

    func testRecentBackwardPagingUsesStableCursorWithoutDuplicates() throws {
        let sessionID = fixedUUID(920)
        let timestamp = Date(timeIntervalSinceReferenceDate: 200)
        let items = (0 ..< 5).map { index in
            RemoteTranscriptItem(
                id: fixedUUID(921 + index),
                turnID: fixedUUID(930 + index),
                timestamp: timestamp.addingTimeInterval(TimeInterval(index)),
                sequenceIndex: index,
                kind: .activity,
                semanticKind: .compactActivity,
                role: "toolExecution",
                text: "Item \(index)"
            )
        }

        let latest = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: items,
            paging: .recentBackward(before: nil),
            limit: 2,
            transcriptRevision: 7
        )
        XCTAssertEqual(latest.items.map(\.sequenceIndex), [3, 4])
        XCTAssertEqual(latest.pagingMode, .recentBackward)
        XCTAssertEqual(latest.hasOlder, true)
        XCTAssertEqual(latest.transcriptRevision, 7)

        let cursor = try XCTUnwrap(latest.olderCursor)
        XCTAssertEqual(try RemoteTranscriptCursorCodec.decode(RemoteTranscriptCursorCodec.encode(cursor)), cursor)
        let older = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: items,
            paging: .recentBackward(before: cursor),
            limit: 2
        )
        XCTAssertEqual(older.items.map(\.sequenceIndex), [1, 2])
        XCTAssertTrue(Set(latest.items.map(\.id)).isDisjoint(with: Set(older.items.map(\.id))))

        let oldest = try WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: items,
            paging: .recentBackward(before: XCTUnwrap(older.olderCursor)),
            limit: 2
        )
        XCTAssertEqual(oldest.items.map(\.sequenceIndex), [0])
        XCTAssertEqual(oldest.hasOlder, false)
        XCTAssertNil(oldest.olderCursor)

        let empty = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: [],
            paging: .recentBackward(before: nil),
            limit: 2
        )
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.hasOlder, false)

        let oneItem = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: [items[0]],
            paging: .recentBackward(before: nil),
            limit: 1
        )
        XCTAssertEqual(oneItem.items.map(\.id), [items[0].id])
        XCTAssertEqual(oneItem.hasOlder, false)

        let tiedItems = [
            RemoteTranscriptItem(
                id: fixedUUID(960),
                turnID: fixedUUID(962),
                timestamp: timestamp,
                sequenceIndex: 10,
                kind: .activity,
                role: "toolExecution"
            ),
            RemoteTranscriptItem(
                id: fixedUUID(961),
                turnID: fixedUUID(962),
                timestamp: timestamp,
                sequenceIndex: 10,
                kind: .activity,
                role: "toolExecution"
            )
        ]
        let tiedLatest = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: tiedItems,
            paging: .recentBackward(before: nil),
            limit: 1
        )
        XCTAssertEqual(tiedLatest.items.map(\.id), [fixedUUID(961)])
        let tiedOlder = try WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: tiedItems,
            paging: .recentBackward(before: XCTUnwrap(tiedLatest.olderCursor)),
            limit: 1
        )
        XCTAssertEqual(tiedOlder.items.map(\.id), [fixedUUID(960)])

        let exact = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: tiedItems,
            paging: .exactItem(fixedUUID(960)),
            limit: 1
        )
        XCTAssertEqual(exact.items.map(\.id), [fixedUUID(960)])

        let legacy = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: items,
            paging: .legacyForward(afterSequenceIndex: 1),
            limit: 2
        )
        XCTAssertEqual(legacy.items.map(\.sequenceIndex), [2, 3])
        XCTAssertEqual(legacy.nextSequenceIndex, 3)
        XCTAssertThrowsError(try RemoteTranscriptCursorCodec.decode("not-a-cursor"))
    }

    func testRevisionTrackerIsMonotonicAndRevisionEventContainsOnlyNumericRevision() throws {
        let tracker = RemoteTranscriptRevisionTracker()
        let sessionID = fixedUUID(940)
        let baseTranscript = fingerprintTranscript(firstVisibleText: "first")
        let editedEarlierRow = fingerprintTranscript(firstVisibleText: "edited")
        let live = RemoteTranscriptRevisionFingerprint.live(transcript: baseTranscript)
        let equivalentPersisted = RemoteTranscriptRevisionFingerprint.persisted(transcript: baseTranscript)
        let changed = RemoteTranscriptRevisionFingerprint.live(transcript: editedEarlierRow)

        XCTAssertEqual(live, equivalentPersisted, "Live and persisted forms of the same visible transcript must normalize")
        XCTAssertEqual(tracker.observePersisted(
            sessionID: sessionID,
            savedAt: Date(timeIntervalSinceReferenceDate: 1),
            fingerprint: equivalentPersisted
        ), 1)
        XCTAssertEqual(tracker.observePersisted(
            sessionID: sessionID,
            savedAt: Date(timeIntervalSinceReferenceDate: 2),
            fingerprint: equivalentPersisted
        ), 1, "A metadata-only save must not increment the revision")
        XCTAssertEqual(tracker.cachedPersistedRevision(
            sessionID: sessionID,
            savedAt: Date(timeIntervalSinceReferenceDate: 2)
        ), 1)
        XCTAssertEqual(tracker.observe(sessionID: sessionID, fingerprint: changed), 2)
        XCTAssertEqual(tracker.revision(for: sessionID), 2)

        let commonDate = Date(timeIntervalSinceReferenceDate: 3)
        let old = RemoteSessionSummary(
            sessionID: sessionID,
            workspaceID: fixedUUID(941).uuidString,
            transcriptRevision: 1,
            runState: .working,
            lastUpdatedAt: commonDate,
            isLive: true
        )
        let current = RemoteSessionSummary(
            sessionID: sessionID,
            workspaceID: fixedUUID(941).uuidString,
            transcriptRevision: 2,
            runState: .working,
            lastUpdatedAt: commonDate,
            isLive: true
        )
        let event = try XCTUnwrap(RemoteGatewayController.transcriptRevisionEvent(
            old: old,
            current: current,
            desktopInstanceID: "desktop"
        ))
        XCTAssertEqual(event.type, .transcriptItemsAppended)
        XCTAssertEqual(event.sessionID, sessionID)
        XCTAssertEqual(event.payload, .text("2"))
        XCTAssertFalse(RemoteGatewayController.hasSessionChangeExcludingTranscriptRevision(
            old: old,
            current: current
        ))
        let encoded = try String(decoding: JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("transcript text"))
        XCTAssertFalse(encoded.contains("argumentsJSON"))
        XCTAssertFalse(encoded.contains("resultJSON"))
        XCTAssertFalse(encoded.contains("reasoning"))
    }

    func testConfigurationControlsChangeProducesSessionUpdate() {
        let commonDate = Date(timeIntervalSinceReferenceDate: 4)
        let base = RemoteSessionSummary(
            sessionID: fixedUUID(942),
            workspaceID: fixedUUID(943).uuidString,
            configurationControls: RemoteSessionConfigurationControls(
                agent: RemoteSelectionControl(isMutable: false),
                model: RemoteSelectionControl(isMutable: false),
                reasoningEffort: RemoteSelectionControl(isMutable: false)
            ),
            runState: .idle,
            lastUpdatedAt: commonDate,
            isLive: true
        )
        let changed = RemoteSessionSummary(
            sessionID: base.sessionID,
            workspaceID: base.workspaceID,
            configurationControls: RemoteSessionConfigurationControls(
                agent: RemoteSelectionControl(isMutable: true, allowedValueIDs: ["codexExec"]),
                model: RemoteSelectionControl(isMutable: true, allowedValueIDs: ["gpt-5"]),
                reasoningEffort: RemoteSelectionControl(isMutable: true, allowedValueIDs: ["high"])
            ),
            runState: .idle,
            lastUpdatedAt: commonDate,
            isLive: true
        )

        XCTAssertTrue(RemoteGatewayController.hasSessionChangeExcludingTranscriptRevision(
            old: base,
            current: changed
        ))
    }

    func testGatewayCursorAttachmentPreservesResolvedMetadata() {
        let selection = RemoteAgentSelection(agentID: "codexExec", modelID: "gpt-5", reasoningEffort: "high")
        let tools = RemoteToolCatalog(
            providerID: "codexExec",
            revision: 7,
            settings: [],
            isMutable: true
        )
        let response = RemoteCommandResponse(
            commandID: fixedUUID(944),
            accepted: true,
            resolvedSelection: selection,
            resolvedToolCatalog: tools
        )

        let attached = RemoteGatewayRequestRouter.attachingEventCursor(to: response, eventCursor: 42)

        XCTAssertEqual(attached.eventCursor, 42)
        XCTAssertEqual(attached.resolvedSelection, selection)
        XCTAssertEqual(attached.resolvedToolCatalog, tools)
    }

    func testTabSessionTranscriptMutationRevisionTracksTranscriptChanges() {
        let session = AgentModeViewModel.TabSession(tabID: fixedUUID(945))
        let initial = session.remoteTranscriptMutationRevision

        session.transcript = AgentTranscript(nextSequenceIndex: 1)
        let afterAssignment = session.remoteTranscriptMutationRevision
        session.transcript.nextSequenceIndex += 1

        XCTAssertGreaterThan(afterAssignment, initial)
        XCTAssertGreaterThan(session.remoteTranscriptMutationRevision, afterAssignment)
    }

    private func fingerprintTranscript(firstVisibleText: String) -> AgentTranscript {
        let timestamp = Date(timeIntervalSinceReferenceDate: 500)
        let request = AgentChatItem(
            id: fixedUUID(970),
            timestamp: timestamp,
            kind: .user,
            text: "request",
            sequenceIndex: 0
        )
        let first = AgentTranscriptActivity(
            id: fixedUUID(971),
            timestamp: timestamp.addingTimeInterval(1),
            sequenceIndex: 1,
            role: .assistant,
            itemKind: .assistantInline,
            text: firstVisibleText,
            isSubstantiveAssistant: false
        )
        let unchangedTail = AgentTranscriptActivity(
            id: fixedUUID(972),
            timestamp: timestamp.addingTimeInterval(2),
            sequenceIndex: 2,
            role: .assistant,
            itemKind: .assistant,
            text: "unchanged tail",
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: true
        )
        return AgentTranscript(
            turns: [AgentTranscriptTurn(
                id: fixedUUID(973),
                request: AgentTranscriptRequestAnchor(from: request),
                responseSpans: [AgentTranscriptProviderResponseSpan(
                    startedAt: timestamp,
                    activities: [first, unchangedTail]
                )],
                conclusionActivityID: unchangedTail.id,
                startedAt: timestamp,
                lastActivityAt: unchangedTail.timestamp
            )],
            nextSequenceIndex: 3
        )
    }

    private func toolExecution(
        name: String,
        status: AgentTranscriptToolStatus,
        argsJSON: String? = nil,
        resultJSON: String? = nil,
        isError: Bool? = nil,
        summaryText: String? = nil
    ) -> AgentTranscriptToolExecution {
        AgentTranscriptToolExecution(
            stableExecutionID: UUID().uuidString,
            toolName: name,
            invocationID: UUID(),
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            toolIsError: isError,
            status: status,
            summaryText: summaryText
        )
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteProducerParityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Remote Producer Parity",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }

    private func fixedUUID(_ suffix: Int) -> UUID {
        let value = String(format: "%012d", suffix)
        return UUID(uuidString: "00000000-0000-0000-0000-\(value)")!
    }
}

@MainActor
final class RemoteSnapshotProjectionTests: XCTestCase {
    func testCanonicalApprovalProjectionIncludesReviewDetailsAndStableIdentity() throws {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: id, kind: .approval, responseType: .decision,
            title: "Permission required", prompt: "Review requested scope",
            context: nil, allowsMultiple: nil, options: [], fields: [],
            details: [.init(label: "Requested Permissions", value: "Read project files", isCode: false)]
        )
        let result = try XCTUnwrap(AgentModeRemoteSessionQueryService.projectInteraction(
            interaction, createdAt: createdAt
        ))
        XCTAssertEqual(result.id, id.uuidString)
        XCTAssertEqual(result.kind, .approval)
        XCTAssertTrue(result.prompt?.contains("Read project files") == true)
        XCTAssertEqual(result.createdAt, createdAt)
        XCTAssertNil(result.responseUnavailableReason)
        XCTAssertEqual(result, AgentModeRemoteSessionQueryService.projectInteraction(interaction, createdAt: createdAt))
    }

    func testHookTrustAndUnsupportedApprovalOptionsRequireMacReview() throws {
        for kind in [AgentRunMCPSnapshot.Interaction.Kind.hookApproval, .approval] {
            let interaction = AgentRunMCPSnapshot.Interaction(
                id: UUID(), kind: kind, responseType: .decision,
                title: "Review required", prompt: "Review this request",
                context: nil, allowsMultiple: nil, options: [], fields: [], details: []
            )
            let result = try XCTUnwrap(AgentModeRemoteSessionQueryService.projectInteraction(
                interaction, createdAt: .distantPast, supportsPlainApproval: false
            ))
            XCTAssertEqual(result.kind, .approval)
            XCTAssertNotNil(result.responseUnavailableReason)
        }
    }

    func testSecretAndMultipartInputRetainSecureEntryWithoutPretendingToSupportMultipart() throws {
        let secret = AgentRunMCPSnapshot.Interaction.Field(
            id: "token", prompt: "Enter token", isSecret: true, allowsOther: true, options: []
        )
        for fields in [[secret], [secret, secret]] {
            let interaction = AgentRunMCPSnapshot.Interaction(
                id: UUID(), kind: .userInput, responseType: .structured,
                title: "Input", prompt: nil, context: nil, allowsMultiple: nil,
                options: [], fields: fields, details: []
            )
            let result = try XCTUnwrap(AgentModeRemoteSessionQueryService.projectInteraction(
                interaction, createdAt: .distantPast
            ))
            XCTAssertEqual(result.kind, .secretInput)
            XCTAssertTrue(result.requiresSecureEntry)
            XCTAssertEqual(result.responseUnavailableReason == nil, fields.count == 1)
        }
    }

    func testAvailabilityPolicyCoversActiveWaitingAndTerminalStates() {
        XCTAssertTrue(RemoteAvailabilityController.requiresSleepAssertion(.opening))
        XCTAssertTrue(RemoteAvailabilityController.requiresSleepAssertion(.working))
        XCTAssertTrue(RemoteAvailabilityController.requiresSleepAssertion(.waitingForInput))
        XCTAssertTrue(RemoteAvailabilityController.requiresSleepAssertion(.blocked))
        XCTAssertFalse(RemoteAvailabilityController.requiresSleepAssertion(.idle))
        XCTAssertFalse(RemoteAvailabilityController.requiresSleepAssertion(.completed))
        XCTAssertFalse(RemoteAvailabilityController.requiresSleepAssertion(.failed))
        XCTAssertFalse(RemoteAvailabilityController.requiresSleepAssertion(.cancelled))
    }

    func testFixtureProjectsOpeningBlockedAndCancelledTransitions() async {
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 200)
        let records = [
            fixtureSession(id: UUID(), workspaceID: workspaceID, state: .opening, date: now),
            fixtureSession(id: UUID(), workspaceID: workspaceID, state: .blocked, date: now.addingTimeInterval(-1)),
            fixtureSession(id: UUID(), workspaceID: workspaceID, state: .cancelled, date: now.addingTimeInterval(-2))
        ]
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: FixtureWorkspaceCatalog(records: [
                RemoteWorkspaceRecord(
                    workspaceID: workspaceID,
                    name: "Lifecycle fixture",
                    repositoryRootSummary: "repo",
                    isOpen: true,
                    activeSessionIDs: [],
                    lastActivityAt: now
                )
            ]),
            sessionQuery: FixtureSessionQuery(records: records),
            workflowCatalog: StaticRemoteCatalogService()
        )

        let revisionEpoch = UUID()
        let snapshot = await builder.build(
            desktop: RemoteDesktopSummary(
                instanceID: "lifecycle-desktop",
                displayName: "Fixture Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            transcriptRevisionEpoch: revisionEpoch
        )

        XCTAssertEqual(snapshot.transcriptRevisionEpoch, revisionEpoch)
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .opening })
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .blocked })
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .cancelled })
        XCTAssertEqual(snapshot.attentionItems.count, 0)
    }

    func testCredentialAuthorityRejectsRevokedExpiredAndMismatchedCredentials() {
        let now = Date(timeIntervalSince1970: 100)
        let credential = RemoteStoredDeviceCredential(
            deviceID: "device-1",
            credential: "credential-1",
            expiresAt: now.addingTimeInterval(60),
            deviceName: "Test phone"
        )
        XCTAssertTrue(RemoteCredentialAuthority.accepts(
            authorizationHeader: "Bearer credential-1",
            credential: credential,
            at: now
        ))
        XCTAssertFalse(RemoteCredentialAuthority.accepts(
            authorizationHeader: "Bearer old-credential",
            credential: credential,
            at: now
        ))
        XCTAssertFalse(RemoteCredentialAuthority.accepts(
            authorizationHeader: "Bearer credential-1",
            credential: credential,
            at: now.addingTimeInterval(61)
        ))
        XCTAssertFalse(RemoteCredentialAuthority.accepts(
            authorizationHeader: "Bearer credential-1",
            credential: nil,
            at: now
        ))
    }

    func testWorkspaceActivationPlannerHandlesReusableClosingAndMissingWindows() {
        XCTAssertEqual(
            RemoteWorkspaceActivationPlanner.decision(
                workspaceExists: true,
                reusableWindowExists: true
            ),
            .reuseExistingWindow
        )
        XCTAssertEqual(
            RemoteWorkspaceActivationPlanner.decision(
                workspaceExists: true,
                reusableWindowExists: false
            ),
            .openNewWindow
        )
        XCTAssertEqual(
            RemoteWorkspaceActivationPlanner.decision(
                workspaceExists: false,
                reusableWindowExists: false
            ),
            .workspaceNotFound
        )
    }

    func testMutationFailurePolicyCoversEveryRemoteMutation() {
        XCTAssertEqual(
            Set(RemoteMutationFailurePolicy.mutationOperations),
            Set([
                .startRun,
                .configureSession,
                .configureTools,
                .followUp,
                .steer,
                .uploadAttachment,
                .respond,
                .cancel,
                .resume,
                .contextBuilder
            ])
        )
        XCTAssertEqual(
            RemoteMutationFailurePolicy.disposition(for: .startRun),
            .rollbackProvisionalSession
        )

        for operation in RemoteMutationFailurePolicy.mutationOperations where operation != .startRun {
            XCTAssertEqual(
                RemoteMutationFailurePolicy.disposition(for: operation),
                .preserveExistingSession,
                "A failed \(operation.rawValue) mutation must not claim acceptance or discard an existing session."
            )
        }
    }

    func testProjectionRebuildsAfterRestartAndPreservesLifecycleState() async {
        let workspaceID = UUID()
        let waitingID = UUID()
        let cancelledID = UUID()
        let now = Date(timeIntervalSince1970: 250)
        let workspace = RemoteWorkspaceRecord(
            workspaceID: workspaceID,
            name: "Restart fixture",
            repositoryRootSummary: "repo",
            isOpen: false,
            activeSessionIDs: [],
            lastActivityAt: now
        )
        let records = [
            RemoteSessionRecord(
                sessionID: waitingID,
                workspaceID: workspaceID,
                composeTabID: UUID(),
                parentSessionID: nil,
                sessionName: "Waiting",
                workflow: nil,
                agent: nil,
                model: nil,
                reasoningEffort: nil,
                runState: .waitingForInput,
                lifecycleStage: "waiting",
                latestMeaningfulActivity: "Waiting for input",
                pendingInteraction: RemoteInteractionSummary(
                    id: "waiting",
                    kind: .question,
                    prompt: "Continue?"
                ),
                worktreeSummary: nil,
                mergeAttention: nil,
                failureSummary: nil,
                lastUpdatedAt: now,
                isLive: true
            ),
            RemoteSessionRecord(
                sessionID: cancelledID,
                workspaceID: workspaceID,
                composeTabID: UUID(),
                parentSessionID: nil,
                sessionName: "Cancelled",
                workflow: nil,
                agent: nil,
                model: nil,
                reasoningEffort: nil,
                runState: .cancelled,
                lifecycleStage: "cancelled",
                latestMeaningfulActivity: "Cancelled",
                pendingInteraction: nil,
                worktreeSummary: nil,
                mergeAttention: nil,
                failureSummary: nil,
                lastUpdatedAt: now.addingTimeInterval(-1),
                isLive: false
            )
        ]

        func build() async -> RemoteSnapshot {
            await RemoteSnapshotBuilder(
                workspaceCatalog: FixtureWorkspaceCatalog(records: [workspace]),
                sessionQuery: FixtureSessionQuery(records: records),
                workflowCatalog: StaticRemoteCatalogService()
            ).build(
                desktop: RemoteDesktopSummary(
                    instanceID: "restart-desktop",
                    displayName: "Fixture Mac",
                    appVersion: "test",
                    isAvailable: true
                ),
                connection: RemoteConnectionSummary(state: .connected),
                authorization: RemoteAuthorizationState()
            )
        }

        let beforeRestart = await build()
        let afterRestart = await build()

        XCTAssertEqual(afterRestart.workspaces, beforeRestart.workspaces)
        XCTAssertEqual(afterRestart.sessions, beforeRestart.sessions)
        XCTAssertTrue(afterRestart.sessions.contains { $0.runState == .waitingForInput })
        XCTAssertTrue(afterRestart.sessions.contains { $0.runState == .cancelled })
        XCTAssertTrue(afterRestart.workspaces.contains { !$0.isOpen })
    }

    func testProjectionHandlesLargeFleetWithParentChildRelationships() async {
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 300)
        let sessionIDs = (0 ..< 2000).map { _ in UUID() }
        let records = sessionIDs.enumerated().map { index, sessionID in
            RemoteSessionRecord(
                sessionID: sessionID,
                workspaceID: workspaceID,
                composeTabID: UUID(),
                parentSessionID: index == 0 ? nil : (index.isMultiple(of: 10) ? nil : sessionIDs[index / 10]),
                sessionName: "Fleet (index)",
                workflow: index.isMultiple(of: 2) ? "review" : "implement",
                agent: "codex",
                model: "default",
                reasoningEffort: "medium",
                runState: index.isMultiple(of: 3) ? .working : .idle,
                lifecycleStage: "running",
                latestMeaningfulActivity: "Processing item (index)",
                pendingInteraction: nil,
                worktreeSummary: nil,
                mergeAttention: nil,
                failureSummary: nil,
                lastUpdatedAt: now.addingTimeInterval(TimeInterval(-index)),
                isLive: true
            )
        }
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: FixtureWorkspaceCatalog(records: [
                RemoteWorkspaceRecord(
                    workspaceID: workspaceID,
                    name: "Large fleet",
                    repositoryRootSummary: "repo",
                    isOpen: true,
                    activeSessionIDs: sessionIDs,
                    lastActivityAt: now
                )
            ]),
            sessionQuery: FixtureSessionQuery(records: records),
            workflowCatalog: StaticRemoteCatalogService()
        )

        let snapshot = await builder.build(
            desktop: RemoteDesktopSummary(
                instanceID: "large-fleet-desktop",
                displayName: "Fixture Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState()
        )

        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.sessions.count, 2000)
        XCTAssertEqual(snapshot.sessions.count(where: { !$0.childSessionIDs.isEmpty }), 200)
        XCTAssertEqual(snapshot.sessions.reduce(0) { $0 + $1.childSessionIDs.count }, 1800)
    }

    func testFixtureProjectsLiveWaitingFailedCompletedAndChildSessions() async {
        let liveWorkspaceID = UUID()
        let closedWorkspaceID = UUID()
        let liveSessionID = UUID()
        let waitingSessionID = UUID()
        let failedSessionID = UUID()
        let completedSessionID = UUID()
        let childSessionID = UUID()
        let now = Date(timeIntervalSince1970: 100)

        let workspaces = FixtureWorkspaceCatalog(
            records: [
                RemoteWorkspaceRecord(
                    workspaceID: liveWorkspaceID,
                    name: "Live workspace",
                    repositoryRootSummary: "repo",
                    isOpen: true,
                    activeSessionIDs: [liveSessionID, waitingSessionID],
                    lastActivityAt: now
                ),
                RemoteWorkspaceRecord(
                    workspaceID: closedWorkspaceID,
                    name: "Closed workspace",
                    repositoryRootSummary: "archived-repo",
                    isOpen: false,
                    activeSessionIDs: [],
                    lastActivityAt: now.addingTimeInterval(-10)
                )
            ]
        )
        let sessions = FixtureSessionQuery(
            records: [
                RemoteSessionRecord(
                    sessionID: liveSessionID,
                    workspaceID: liveWorkspaceID,
                    composeTabID: UUID(),
                    parentSessionID: nil,
                    sessionName: "Live run",
                    workflow: "Engineer",
                    agent: "codex",
                    model: "gpt",
                    reasoningEffort: "high",
                    runState: .working,
                    lifecycleStage: "running",
                    latestMeaningfulActivity: "Editing files",
                    pendingInteraction: nil,
                    worktreeSummary: nil,
                    mergeAttention: nil,
                    failureSummary: nil,
                    lastUpdatedAt: now,
                    isLive: true,
                    workflowID: AgentWorkflow.orchestrate.definition.id,
                    runStartedAt: now.addingTimeInterval(-5),
                    transcriptRevision: 7
                ),
                RemoteSessionRecord(
                    sessionID: waitingSessionID,
                    workspaceID: liveWorkspaceID,
                    composeTabID: UUID(),
                    parentSessionID: nil,
                    sessionName: "Needs input",
                    workflow: nil,
                    agent: "claude",
                    model: "sonnet",
                    reasoningEffort: nil,
                    runState: .waitingForInput,
                    lifecycleStage: "waiting",
                    latestMeaningfulActivity: "Waiting for your answer",
                    pendingInteraction: RemoteInteractionSummary(
                        id: "question-1",
                        kind: .question,
                        title: "Choose a direction",
                        prompt: "Which option should the agent use?"
                    ),
                    worktreeSummary: nil,
                    mergeAttention: nil,
                    failureSummary: nil,
                    lastUpdatedAt: now,
                    isLive: true
                ),
                fixtureSession(id: failedSessionID, workspaceID: closedWorkspaceID, state: .failed, date: now.addingTimeInterval(-2)),
                fixtureSession(id: completedSessionID, workspaceID: closedWorkspaceID, state: .completed, date: now.addingTimeInterval(-3)),
                RemoteSessionRecord(
                    sessionID: childSessionID,
                    workspaceID: liveWorkspaceID,
                    composeTabID: UUID(),
                    parentSessionID: liveSessionID,
                    sessionName: "Child run",
                    workflow: nil,
                    agent: "codex",
                    model: "gpt",
                    reasoningEffort: nil,
                    runState: .working,
                    lifecycleStage: "running",
                    latestMeaningfulActivity: "Delegated task",
                    pendingInteraction: nil,
                    worktreeSummary: nil,
                    mergeAttention: nil,
                    failureSummary: nil,
                    lastUpdatedAt: now,
                    isLive: true
                )
            ]
        )
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: workspaces,
            sessionQuery: sessions,
            workflowCatalog: StaticRemoteCatalogService()
        )

        let snapshot = await builder.build(
            desktop: RemoteDesktopSummary(
                instanceID: "fixture-desktop",
                displayName: "Fixture Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState()
        )

        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertTrue(snapshot.workspaces.contains { $0.workspaceID == closedWorkspaceID.uuidString && !$0.isOpen })
        XCTAssertEqual(snapshot.sessions.count, 5)
        let liveSummary = snapshot.sessions.first { $0.sessionID == liveSessionID }
        XCTAssertEqual(liveSummary?.childSessionIDs, [childSessionID])
        XCTAssertEqual(liveSummary?.workflow, "Engineer")
        XCTAssertEqual(liveSummary?.workflowID, AgentWorkflow.orchestrate.definition.id)
        XCTAssertEqual(liveSummary?.runStartedAt, now.addingTimeInterval(-5))
        XCTAssertEqual(liveSummary?.transcriptRevision, 7)
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .waitingForInput })
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .failed })
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .completed })
        XCTAssertTrue(snapshot.attentionItems.contains { $0.kind == .agentNeedsInput && $0.sessionID == waitingSessionID })
        XCTAssertTrue(snapshot.attentionItems.contains { $0.kind == .failed && $0.sessionID == failedSessionID })
    }

    private func fixtureSession(
        id: UUID,
        workspaceID: UUID,
        state: RemoteRunState,
        date: Date
    ) -> RemoteSessionRecord {
        RemoteSessionRecord(
            sessionID: id,
            workspaceID: workspaceID,
            composeTabID: UUID(),
            parentSessionID: nil,
            sessionName: state.rawValue,
            workflow: nil,
            agent: nil,
            model: nil,
            reasoningEffort: nil,
            runState: state,
            lifecycleStage: nil,
            latestMeaningfulActivity: nil,
            pendingInteraction: nil,
            worktreeSummary: nil,
            mergeAttention: nil,
            failureSummary: state == .failed ? "failed" : nil,
            lastUpdatedAt: date,
            isLive: false
        )
    }
}

@MainActor
private final class FixtureWorkspaceCatalog: WorkspaceCatalogService {
    let records: [RemoteWorkspaceRecord]

    init(records: [RemoteWorkspaceRecord]) {
        self.records = records
    }

    func allSavedWorkspaces() async -> [RemoteWorkspaceRecord] {
        records
    }
}

@MainActor
private final class FixtureSessionQuery: SessionQueryService {
    let records: [RemoteSessionRecord]

    init(records: [RemoteSessionRecord]) {
        self.records = records
    }

    func remoteSessions() async -> [RemoteSessionRecord] {
        records
    }
}
