import Foundation
import MCP
import RepoPromptAIContracts
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptRemoteProtocol
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import RepoPromptVCS
import XCTest

@MainActor
final class RemoteGatewayRouterTests: XCTestCase {
    func testVoiceStartRequiresConfirmedSyncWhileStatusEndAndUnpairRemainAvailable() throws {
        let workspaceID = UUID()
        let callID = UUID()
        let start = RemoteGatewayRequest.workspaceVoice(.init(action: .start, callID: callID, workspaceID: workspaceID, offerSDP: "v=0"))
        let status = RemoteGatewayRequest.workspaceVoice(.init(action: .status, callID: callID, workspaceID: workspaceID))
        let end = RemoteGatewayRequest.workspaceVoice(.init(action: .end, callID: callID, workspaceID: workspaceID))
        var sync = RemoteIrohGatewayAdapter.SyncState(sessionID: UUID())
        XCTAssertFalse(sync.permits(start))
        XCTAssertFalse(RemoteIrohGatewayAdapter.SyncState(sessionID: nil).permits(start))
        XCTAssertTrue(sync.permits(status))
        XCTAssertTrue(sync.permits(end))
        XCTAssertTrue(sync.permits(.unpair))
        let ticket = try XCTUnwrap(sync.issueTicket())
        XCTAssertFalse(sync.permits(start))
        XCTAssertTrue(sync.confirm(ticket))
        XCTAssertTrue(sync.permits(start))
    }

    func testWorkspaceVoiceStartRequiresConsentWhileStatusAndEndStillRoute() async throws {
        let workspaceID = UUID()
        let callID = UUID()
        var hasConsent = false
        var routed: [RemoteWorkspaceVoiceRequest.Action] = []
        let router = makeRouter(
            workspaceVoiceConsent: { hasConsent },
            workspaceVoice: { request, _ in
                routed.append(request.action)
                return .init(callID: callID, workspaceID: workspaceID, phase: .ended)
            }
        )
        let peer = RemoteGatewayRequestContext.testPeer(authorizationHeader: "Bearer valid")
        let start = RemoteGatewayRequest.workspaceVoice(.init(action: .start, callID: callID, workspaceID: workspaceID, offerSDP: "v=0"))
        let denied = await router.route(start, context: peer)
        XCTAssertEqual(denied.status, 403)
        XCTAssertEqual(try error(from: denied).code, "workspace_voice_consent_required")
        XCTAssertTrue(routed.isEmpty)

        for action: RemoteWorkspaceVoiceRequest.Action in [.status, .end] {
            let response = await router.route(.workspaceVoice(.init(action: action, callID: callID, workspaceID: workspaceID)), context: peer)
            XCTAssertEqual(response.status, 200)
        }
        hasConsent = true
        let accepted = await router.route(start, context: peer)
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(routed, [.status, .end, .start])
    }

    func testWorkspacePresentationRequiresPairedControlAndReturnsRequestedState() async throws {
        var authority: RemoteAuthorityLevel = .observe
        var changes: [RemoteWorkspacePresentation] = []
        let router = makeRouter(
            authorize: { $0.authorizationHeader == "Bearer valid" },
            authorizationState: { .init(defaultLevel: authority) },
            workspacePresentation: { request, authorize in
                try authorize()
                changes.append(request)
            }
        )
        let paired = RemoteGatewayRequestContext.testPeer(authorizationHeader: "Bearer valid")
        let open = RemoteWorkspacePresentation(workspaceID: UUID(), isOpen: true)
        let unpairedReply = await router.route(.workspacePresentation(open), context: .testPeer(authorizationHeader: nil))
        XCTAssertEqual(unpairedReply.status, 401)
        let observeReply = await router.route(.workspacePresentation(open), context: paired)
        XCTAssertEqual(observeReply.status, 403)
        XCTAssertTrue(changes.isEmpty)

        authority = .control
        let close = RemoteWorkspacePresentation(workspaceID: open.workspaceID, isOpen: false)
        for request in [open, close] {
            let reply = await router.route(.workspacePresentation(request), context: paired)
            XCTAssertEqual(reply.status, 200)
            XCTAssertEqual(try JSONDecoder().decode(RemoteWorkspacePresentation.self, from: json(from: reply)), request)
        }
        XCTAssertEqual(changes, [open, close])
    }

    func testWorkspacePresentationRevalidatesAuthorityBeforeChangingWindows() async throws {
        var generation: UInt64 = 1
        let router = makeRouter(
            commandGeneration: { generation },
            workspacePresentation: { _, authorize in
                generation += 1
                try authorize()
                XCTFail("A stale workspace change must be rejected")
            }
        )
        let reply = await router.route(
            .workspacePresentation(.init(workspaceID: UUID(), isOpen: true)),
            context: .testPeer(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(reply.status, 409)
        XCTAssertEqual(try error(from: reply).code, "workspace_presentation")
    }

    func testFirstSyncDoesNotSendSavedSessionIndexForTwoWorkspaces() async throws {
        let workspaceIDs = [UUID(), UUID()]
        let liveID = UUID()
        let workspaces = workspaceIDs.map {
            RemoteWorkspaceRecord(
                workspaceID: $0, name: "Open workspace", repositoryRootSummary: nil, isOpen: true,
                activeSessionIDs: $0 == workspaceIDs[0] ? [liveID] : [], lastActivityAt: nil
            )
        }
        let controls = RemoteSessionConfigurationControls(
            agent: .init(isMutable: true, allowedValueIDs: ["codex"]),
            model: .init(isMutable: true, allowedValueIDs: (0 ..< 100).map {
                "provider/model-\($0)-" + String(repeating: "x", count: 180)
            }),
            reasoningEffort: .init(isMutable: true, allowedValueIDs: ["high"])
        )
        let saved = (0 ..< 256).map {
            RemoteSessionRecord(
                sessionID: UUID(), workspaceID: workspaceIDs[$0 % 2], composeTabID: nil, parentSessionID: nil,
                sessionName: "Saved chat \($0)", workflow: nil, agent: "codex", model: nil, reasoningEffort: nil,
                runState: .completed, lifecycleStage: nil, latestMeaningfulActivity: nil, pendingInteraction: nil,
                worktreeSummary: nil, mergeAttention: nil, failureSummary: nil,
                lastUpdatedAt: .distantPast, isLive: false, configurationControls: controls
            )
        }
        let active = RemoteSessionRecord(
            sessionID: liveID, workspaceID: workspaceIDs[0], composeTabID: UUID(), parentSessionID: nil,
            sessionName: "Active chat", workflow: nil, agent: "codex", model: nil, reasoningEffort: nil,
            runState: .working, lifecycleStage: nil, latestMeaningfulActivity: nil, pendingInteraction: nil,
            worktreeSummary: nil, mergeAttention: nil, failureSummary: nil, lastUpdatedAt: Date(), isLive: true
        )
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: FixtureWorkspaceCatalog(records: workspaces),
            sessionQuery: FixtureSessionQuery(records: saved + [active]),
            workflowCatalog: StaticRemoteCatalogService()
        )
        func snapshot(bootstrap: Bool) async -> RemoteSnapshot {
            await builder.build(
                desktop: .init(instanceID: "desktop", displayName: "Mac", appVersion: "test", isAvailable: true),
                connection: .init(state: .connecting), authorization: .init(), eventCursor: 42,
                bootstrap: bootstrap
            )
        }

        let full = await snapshot(bootstrap: false)
        let fullJSON = try JSONEncoder().encode(full)
        let oldFrame = try RemoteWireFrame(
            kind: .rpcResponse, messageID: UUID(), encoding: RemoteRPCResponse(result: fullJSON, syncTicket: UUID())
        )
        XCTAssertThrowsError(try oldFrame.validateEncodedLimit(direction: .serverResponse))
        let router = makeRouter(snapshot: { full }, bootstrapSnapshot: { await snapshot(bootstrap: true) })
        let context = RemoteGatewayRequestContext.testPeer(authorizationHeader: "Bearer valid")
        let reply = await router.route(.snapshot, context: context)
        XCTAssertEqual(reply.status, 200)
        let data = try json(from: reply)
        let syncFrame = try RemoteWireFrame(
            kind: .rpcResponse, messageID: UUID(), encoding: RemoteRPCResponse(result: data, syncTicket: UUID())
        )
        try syncFrame.validateEncodedLimit(direction: .serverResponse)

        let firstSync = try JSONDecoder().decode(RemoteSnapshot.self, from: data)
        XCTAssertEqual(Set(firstSync.workspaces.map(\.workspaceID)), Set(workspaceIDs.map(\.uuidString)))
        XCTAssertEqual(firstSync.sessions.map(\.sessionID), [liveID])
        XCTAssertEqual(firstSync.eventCursor, 42)

        let sessionsReply = await router.route(.sessions, context: context)
        let sessionList = try JSONDecoder().decode([RemoteSessionSummary].self, from: json(from: sessionsReply))
        XCTAssertEqual(sessionList.count, saved.count + 1)
    }

    func testFirstSyncPreservesSavedRelationshipsAroundLiveSession() async throws {
        let workspaceID = UUID()
        let liveID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let unrelatedID = UUID()
        func record(_ id: UUID, parent: UUID? = nil, live: Bool = false) -> RemoteSessionRecord {
            RemoteSessionRecord(
                sessionID: id, workspaceID: workspaceID, composeTabID: nil, parentSessionID: parent,
                sessionName: "Chat", workflow: nil, agent: "codex", model: nil, reasoningEffort: nil,
                runState: live ? .working : .completed, lifecycleStage: nil, latestMeaningfulActivity: nil,
                pendingInteraction: nil, worktreeSummary: nil, mergeAttention: nil, failureSummary: nil,
                lastUpdatedAt: .distantPast, isLive: live
            )
        }
        let workspaces = FixtureWorkspaceCatalog(records: [.init(
            workspaceID: workspaceID, name: "Open workspace", repositoryRootSummary: nil, isOpen: true,
            activeSessionIDs: [liveID], lastActivityAt: nil
        )])
        let sessions = FixtureSessionQuery(records: [
            record(parentID), record(liveID, parent: parentID, live: true),
            record(childID, parent: liveID), record(unrelatedID)
        ])
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: workspaces, sessionQuery: sessions, workflowCatalog: StaticRemoteCatalogService()
        )
        let router = makeRouter(bootstrapSnapshot: {
            await builder.build(
                desktop: .init(instanceID: "desktop", displayName: "Mac", appVersion: "test", isAvailable: true),
                connection: .init(state: .connecting), authorization: .init(), bootstrap: true
            )
        })

        let reply = await router.route(.snapshot, context: .testPeer(authorizationHeader: "Bearer valid"))
        let snapshot = try JSONDecoder().decode(RemoteSnapshot.self, from: json(from: reply))
        let byID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionID, $0) })
        XCTAssertEqual(Set(byID.keys), [parentID, liveID, childID])
        XCTAssertEqual(byID[parentID]?.childSessionIDs, [liveID])
        XCTAssertEqual(byID[liveID]?.parentSessionID, parentID)
        XCTAssertEqual(byID[liveID]?.childSessionIDs, [childID])
        XCTAssertEqual(byID[childID]?.parentSessionID, liveID)
        XCTAssertEqual(byID[liveID]?.isLive, true)
        XCTAssertEqual(byID[childID]?.isLive, false)
    }

    func testFirstSyncCompactsOversizedLiveDataAndKeepsCoreState() async throws {
        let workspaceID = UUID().uuidString
        let sessionID = UUID()
        let epoch = UUID()
        let prompt = String(repeating: "x", count: RemoteSnapshotBootstrap.maximumJSONBytes + 1)
        let snapshot = RemoteSnapshot(
            desktop: .init(instanceID: "desktop", displayName: "Mac", appVersion: "test", isAvailable: true),
            connection: .init(state: .connecting), authorization: .init(defaultLevel: .control),
            workspaces: [.init(workspaceID: workspaceID, name: "Open workspace", isOpen: true)],
            sessions: [.init(
                sessionID: sessionID, workspaceID: workspaceID, runState: .waitingForInput,
                pendingInteraction: .init(id: "request", kind: .approval, prompt: prompt), isLive: true
            )],
            eventCursor: 73, transcriptRevisionEpoch: epoch
        )
        let router = makeRouter(bootstrapSnapshot: { snapshot })
        let reply = await router.route(.snapshot, context: .testPeer(authorizationHeader: "Bearer valid"))
        XCTAssertEqual(reply.status, 200)
        let data = try json(from: reply)
        XCTAssertLessThanOrEqual(data.count, RemoteSnapshotBootstrap.maximumJSONBytes)

        let core = try JSONDecoder().decode(RemoteSnapshot.self, from: data)
        XCTAssertEqual(core.workspaces, snapshot.workspaces)
        XCTAssertEqual(core.sessions.map(\.sessionID), [sessionID])
        XCTAssertEqual(core.sessions.first?.runState, .waitingForInput)
        XCTAssertNil(core.sessions.first?.pendingInteraction?.prompt)
        XCTAssertNotNil(core.sessions.first?.pendingInteraction?.responseUnavailableReason)
        XCTAssertEqual(core.authorization, snapshot.authorization)
        XCTAssertEqual(core.eventCursor, 73)
        XCTAssertEqual(core.transcriptRevisionEpoch, epoch)
    }

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

    func testProtectedRequestsRequireAuthorizationBeforeRouting() async throws {
        var snapshotCalls = 0
        let router = makeRouter(
            authorize: { _ in false },
            snapshot: {
                snapshotCalls += 1
                return nil
            }
        )

        for context in [
            RemoteGatewayRequestContext.testPeer(authorizationHeader: nil),
            RemoteGatewayRequestContext(
                endpointID: "peer-1", deviceID: "device-1",
                authorizationHeader: "Bearer invalid"
            )
        ] {
            let response = await router.route(.snapshot, context: context)
            XCTAssertEqual(response.status, 401)
            XCTAssertEqual(try error(from: response).code, "unauthorized")
        }
        XCTAssertEqual(snapshotCalls, 0)
    }

    func testImageRouteRequiresPairedAuthorityAndValidChunkRequest() async throws {
        let request = RemoteImageAttachmentRequest(sessionID: UUID(), itemID: UUID(), attachmentID: UUID(), variant: .thumbnail)
        let chunk = RemoteImageAttachmentChunk(offset: 0, totalBytes: 2, bytes: Data([1, 2]))
        var reads = 0
        let router = makeRouter(
            authorize: { $0.authorizationHeader == "Bearer paired" },
            imageAttachment: { requestFromClient in
                reads += 1
                XCTAssertEqual(requestFromClient, request)
                return chunk
            }
        )
        let denied = await router.route(.imageAttachment(request), context: .testPeer(authorizationHeader: nil))
        XCTAssertEqual(denied.status, 401)
        XCTAssertEqual(reads, 0)

        let response = await router.route(.imageAttachment(request), context: .testPeer(authorizationHeader: "Bearer paired"))
        XCTAssertEqual(try JSONDecoder().decode(RemoteImageAttachmentChunk.self, from: json(from: response)), chunk)

        let invalid = RemoteImageAttachmentRequest(
            sessionID: request.sessionID, itemID: request.itemID, attachmentID: request.attachmentID, variant: .original, offset: 20
        )
        let rejected = await router.route(.imageAttachment(invalid), context: .testPeer(authorizationHeader: "Bearer paired"))
        XCTAssertEqual(rejected.status, 400)
        XCTAssertEqual(reads, 1)
    }

    func testUnpairReportsDurableRevocationFailure() async throws {
        let router = makeRouter(unpair: { .failed })

        let response = await router.route(
            .unpair,
            context: .testPeer(authorizationHeader: "Bearer credential")
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
                endpointID: "peer", deviceID: "device",
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
        let pairingRequest = RemoteIrohPairingRequest(
            desktopInstanceID: "desktop",
            expectedServerEndpointID: "server",
            clientEndpointID: "peer",
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
        let expected = RemoteIrohPairingResponse(
            pairingResponse: .init(desktop: desktop, deviceID: "device", credential: "credential"),
            serverEndpointID: "server",
            clientEndpointID: "peer"
        )
        let router = makeRouter(
            authorize: { _ in false },
            pairIroh: { request, peer in
                XCTAssertEqual(peer, "peer")
                XCTAssertEqual(request, pairingRequest)
                return .success(expected)
            }
        )

        let response = await router.route(
            .pairIroh(pairingRequest, authenticatedPeerEndpointID: "peer"),
            context: .testPeer(authorizationHeader: nil)
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(RemoteIrohPairingResponse.self, from: json(from: response)), expected)
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
            execute: { request, _ in
                XCTAssertEqual(request, command)
                return .success(serviceResponse)
            },
            eventCursor: { 42 }
        )

        let response = await router.route(
            .command(command, endpoint: .commands),
            context: .testPeer(authorizationHeader: "Bearer valid")
        )
        let decoded = try JSONDecoder().decode(RemoteCommandResponse.self, from: json(from: response))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(decoded.eventCursor, 42)
        XCTAssertEqual(decoded.contextBuilderResult, contextBuilderResult)
        XCTAssertEqual(decoded.resolvedSelection, selection)
        XCTAssertEqual(decoded.resolvedToolCatalog, catalog)
    }

    func testDispatchAuthorizationChecksLiveStateAndCannotBeRestoredForAnOldCommand() async {
        var authorized = true
        var generation: UInt64 = 0
        var authority = RemoteAuthorityLevel.control
        let router = makeRouter(
            authorize: { _ in authorized },
            authorizationState: { RemoteAuthorizationState(defaultLevel: authority) },
            commandGeneration: { generation },
            execute: { _, authorizeDispatch in
                XCTAssertNotNil(try? authorizeDispatch())
                authorized = false
                XCTAssertNil(try? authorizeDispatch())
                authorized = true
                authority = .respond
                XCTAssertNil(try? authorizeDispatch())
                generation += 1
                authority = .control
                XCTAssertNil(try? authorizeDispatch())
                return .rejected("Remote access changed")
            }
        )
        let response = await router.route(
            .command(.init(operation: .startRun), endpoint: .commands),
            context: .testPeer(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(response.status, 409)
    }

    func testRemoteApprovalPolicyAllowsOneTimeResponseButKeepsPersistentAndMergeDecisionsOnMac() throws {
        let request = AgentApprovalRequest(
            requestID: .acp("permission"), method: "session/request_permission", kind: .commandExecution,
            threadID: "thread", turnID: "turn", itemID: "item", plainApproveAvailable: true
        )
        let validate = WindowRemoteAgentControlService.requireRemoteInteractionResolution
        XCTAssertNoThrow(try validate(.approval(request: request, decision: .accept)))
        XCTAssertNoThrow(try validate(.approval(request: request, decision: .decline)))
        XCTAssertThrowsError(try validate(.approval(request: request, decision: .acceptForSession)))
        XCTAssertThrowsError(try validate(.worktreeMerge(reviewID: UUID(), decision: .accept)))
    }

    func testCommandAuthorityMatrix() {
        let expected: [(RemoteCommandOperation, RemoteAuthorityLevel)] = [
            (.respond, .respond),
            (.startRun, .control),
            (.configureSession, .control),
            (.configureTools, .danger),
            (.uploadAttachment, .control),
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

    func testNotificationRegistrationIsUnavailableEvenWithDangerAuthority() async throws {
        let registration = RemoteNotificationRegistration(platform: .apns, deviceToken: "token")
        let command = RemoteCommandRequest(
            operation: .registerNotifications,
            notificationRegistration: registration
        )
        var executeCalls = 0
        let router = makeRouter(
            authorizationState: { RemoteAuthorizationState(defaultLevel: .danger) },
            execute: { _, _ in
                executeCalls += 1
                return .failed
            }
        )

        let response = await router.route(
            .command(command, endpoint: .commands),
            context: .testPeer(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(try error(from: response).code, "notifications_unavailable")
        XCTAssertEqual(executeCalls, 0)
    }

    func testContextBuilderEndpointRejectsOtherOperationsBeforeExecution() async throws {
        var executeCalls = 0
        let router = makeRouter(execute: { _, _ in
            executeCalls += 1
            return .failed
        })

        let response = await router.route(
            .command(RemoteCommandRequest(operation: .cancel), endpoint: .contextBuilder),
            context: .testPeer(authorizationHeader: "Bearer valid")
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

    func testEventsRemainTypedAndStaleCursorsRequestSnapshot() async throws {
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
            context: .testPeer(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(response.status, 200)
        guard case let .events(events) = response.content else {
            return XCTFail("Expected typed events")
        }
        XCTAssertEqual(events, [event])

        let staleRouter = makeRouter(replay: { _ in .snapshotRequired })
        let staleResponse = await staleRouter.route(
            .events(after: 1),
            context: .testPeer(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(staleResponse.status, 409)
        XCTAssertEqual(try error(from: staleResponse).code, "snapshot_required")
    }

    private func makeRouter(
        authorize: @escaping (RemoteGatewayRequestContext) -> Bool = { _ in true },
        unpair: @escaping () -> RemoteGatewayRevocationResult = { .success },
        snapshot: @escaping () async -> RemoteSnapshot? = { nil },
        replay: @escaping (UInt64?) async -> RemoteEventReplayResult = { _ in .events([]) },
        authorizationState: @escaping () -> RemoteAuthorizationState = {
            RemoteAuthorizationState(defaultLevel: .control)
        },
        commandGeneration: @escaping () -> UInt64 = { 0 },
        execute: @escaping (RemoteCommandRequest, @escaping RemoteDispatchAuthorization) async -> RemoteGatewayCommandResult = { _, _ in .unavailable },
        eventCursor: @escaping () async -> UInt64 = { 0 },
        imageAttachment: @escaping (RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk? = { _ in nil },
        pairIroh: @escaping (RemoteIrohPairingRequest, String) -> Result<RemoteIrohPairingResponse, Error> = { _, _ in
            .failure(TestFailure.unexpectedResponse)
        },
        bootstrapSnapshot: (() async -> RemoteSnapshot?)? = nil,
        workspaceVoiceConsent: @escaping () -> Bool = { false },
        workspaceVoice: @escaping (RemoteWorkspaceVoiceRequest, RemoteGatewayRequestContext) throws -> RemoteWorkspaceVoiceStatus = { _, _ in
            throw TestFailure.unexpectedResponse
        },
        workspacePresentation: @escaping (RemoteWorkspacePresentation, @escaping RemoteDispatchAuthorization) async throws -> Void = { _, _ in
            throw TestFailure.unexpectedResponse
        }
    ) -> RemoteGatewayRequestRouter {
        RemoteGatewayRequestRouter(services: RemoteGatewayRoutingServices(
            authorize: authorize,
            unpair: unpair,
            snapshot: snapshot,
            diagnostics: { nil },
            history: { _ in nil },
            transcript: { _ in .unavailable },
            replay: replay,
            authorizationState: authorizationState,
            commandGeneration: commandGeneration,
            execute: execute,
            eventCursor: eventCursor,
            imageAttachment: imageAttachment,
            pairIroh: pairIroh,
            bootstrapSnapshot: bootstrapSnapshot,
            workspaceVoiceConsent: workspaceVoiceConsent,
            workspaceVoice: workspaceVoice,
            workspacePresentation: workspacePresentation
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
        case .pairIroh: "pair_iroh"
        case .unpair: "unpair"
        case .snapshot: "snapshot"
        case .diagnostics: "diagnostics"
        case .workspaces: "workspaces"
        case .sessions: "sessions"
        case .agents: "agents"
        case .workflows: "workflows"
        case .history: "history"
        case .transcript: "transcript"
        case .imageAttachment: "image_attachment"
        case .workspaceVoice: "workspace_voice"
        case .workspacePresentation: "workspace_presentation"
        case .events: "events"
        case .command: "command"
        }
    }
}

private extension RemoteGatewayRequestContext {
    static func testPeer(authorizationHeader: String?) -> Self {
        Self(endpointID: "peer", deviceID: "device", authorizationHeader: authorizationHeader)
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

    func testPairingAdvertisementContainsAnExpiringSingleUseSecret() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let server = RemoteIrohEndpointAddress(endpointID: endpointID("a"))
        let issued = try makeManager(clock: clock).issueAdvertisement(server: server)

        XCTAssertEqual(issued.server, server)
        XCTAssertEqual(issued.expiresAt, clock.date.addingTimeInterval(300))
        XCTAssertEqual(Data(base64URL: issued.oneTimeSecret)?.count, 32)
    }

    func testIssuedCodeCanBeUsedAfterMacRestartsBeforePrepare() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1800))
        var disk = RemoteStoredPairingState()
        let firstMac = makeManager(clock: clock, persist: { disk = $0 })
        let server = RemoteIrohEndpointAddress(endpointID: endpointID("a"))
        let issued = try firstMac.issueAdvertisement(server: server)
        let reopened = makeManager(clock: clock, storedState: disk)
        XCTAssertEqual(reopened.restoreAdvertisement(server: server), issued)
        _ = try prepare(pairingRequest(secret: issued.oneTimeSecret), on: reopened)
        XCTAssertFalse(reopened.isPaired)
    }

    func testLostCredentialReplyCanResumeAfterMacRestart() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 2000))
        var disk = RemoteStoredPairingState()
        let firstMac = makeManager(clock: clock, persist: { disk = $0 })
        let issued = try firstMac.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        XCTAssertEqual(issued.requiresPairingConfirmation, true)
        let request = pairingRequest(secret: issued.oneTimeSecret)
        let droppedResponse = try prepare(request, on: firstMac)
        XCTAssertFalse(firstMac.isPaired)
        XCTAssertFalse(isAuthorized(droppedResponse, on: firstMac))
        XCTAssertNil(disk.active)
        XCTAssertEqual(disk.pending?.attemptID, request.attemptID)

        let restoredState = try RemoteStoredPairingState.decode(JSONEncoder().encode(disk))
        let reopenedMac = makeManager(clock: clock, storedState: restoredState, persist: { disk = $0 })
        XCTAssertThrowsError(try prepare(pairingRequest(secret: issued.oneTimeSecret), on: reopenedMac))
        let competingPeer = RemoteIrohPairingRequest(
            desktopInstanceID: "desktop",
            expectedServerEndpointID: endpointID("a"),
            clientEndpointID: endpointID("c"),
            oneTimeSecret: issued.oneTimeSecret,
            deviceName: "Other phone",
            attemptID: request.attemptID
        )
        XCTAssertThrowsError(try prepare(competingPeer, on: reopenedMac, peer: endpointID("c")))
        XCTAssertEqual(try prepare(request, on: reopenedMac), droppedResponse)
        XCTAssertFalse(reopenedMac.isPaired)
        XCTAssertFalse(isAuthorized(droppedResponse, on: reopenedMac))
    }

    func testLostFinalAcknowledgementReturnsTheSameResultAfterMacRestart() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3000))
        var disk = RemoteStoredPairingState()
        let manager = makeManager(clock: clock, persist: { disk = $0 })
        let advertised = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        let response = try prepare(pairingRequest(secret: advertised.oneTimeSecret), on: manager)
        let confirmation = try confirmation(for: response)

        XCTAssertThrowsError(try confirm(confirmation, on: manager, peer: endpointID("c")))
        XCTAssertFalse(manager.isPaired)
        XCTAssertTrue(try confirm(confirmation, on: manager))
        XCTAssertTrue(manager.isPaired)
        XCTAssertTrue(isAuthorized(response, on: manager))
        let committed = disk
        XCTAssertNil(committed.pending)

        clock.date = clock.date.addingTimeInterval(2)
        let reopenedMac = makeManager(clock: clock, storedState: committed, persist: { _ in
            XCTFail("Confirm retry must not write or renew a credential")
        })
        XCTAssertThrowsError(try confirm(confirmation, on: reopenedMac, peer: endpointID("c")))
        XCTAssertFalse(try confirm(confirmation, on: reopenedMac))
        XCTAssertTrue(isAuthorized(response, on: reopenedMac))
    }

    func testFailedPhoneSaveLeavesOnlyAnExpiringAttemptAndAllowsNewCode() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3500))
        let manager = makeManager(clock: clock)
        let issued = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        let request = pairingRequest(secret: issued.oneTimeSecret)
        let response = try prepare(request, on: manager)
        // The phone Keychain save fails and the app stops before submitting a confirmation.
        XCTAssertEqual(manager.status, .pending(deviceName: "Phone", expiresAt: clock.date.addingTimeInterval(300)))
        XCTAssertFalse(manager.isPaired)
        XCTAssertFalse(isAuthorized(response, on: manager))
        clock.date = clock.date.addingTimeInterval(301)
        XCTAssertEqual(manager.status, .attemptExpired)
        XCTAssertThrowsError(try confirm(confirmation(for: response), on: manager))
        let replacement = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        XCTAssertThrowsError(try confirm(confirmation(for: response), on: manager))
        let next = try prepare(pairingRequest(secret: replacement.oneTimeSecret), on: manager)
        XCTAssertNotEqual(next.pairingResponse.deviceID, response.pairingResponse.deviceID)
        XCTAssertFalse(manager.isPaired)
    }

    func testPrepareAndConfirmationRemainRetryableAfterDesktopStorageFailure() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 4000))
        var shouldFail = false
        var disk = RemoteStoredPairingState()
        let manager = makeManager(clock: clock, persist: {
            if shouldFail {
                throw PersistenceFailure.failed
            }
            disk = $0
        })
        let issued = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        let request = pairingRequest(secret: issued.oneTimeSecret)
        let initial = disk
        shouldFail = true
        XCTAssertThrowsError(try prepare(request, on: manager))
        XCTAssertEqual(disk, initial)
        shouldFail = false
        let receipt = try prepare(request, on: manager)
        let confirmation = try confirmation(for: receipt)
        shouldFail = true
        XCTAssertThrowsError(try confirm(confirmation, on: manager))
        XCTAssertNil(disk.active)
        XCTAssertFalse(isAuthorized(receipt, on: manager))
        shouldFail = false
        XCTAssertTrue(try confirm(confirmation, on: manager))
        XCTAssertTrue(manager.isPaired)
    }

    func testLegacyHelloPairsOnceAndPreservesTheCredentialAcrossRestart() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 4600))
        var disk = RemoteStoredPairingState()
        let manager = makeManager(clock: clock, persist: { disk = $0 })
        let issued = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        let legacy = pairingRequest(secret: issued.oneTimeSecret, attemptID: nil)
        XCTAssertThrowsError(try prepare(legacy, on: manager, peer: endpointID("c")))
        let receipt = try prepare(legacy, on: manager)
        XCTAssertNil(receipt.attemptID)
        XCTAssertNil(disk.pending)
        XCTAssertNil(disk.advertisement)
        XCTAssertTrue(isAuthorized(receipt, on: manager))
        XCTAssertThrowsError(try prepare(legacy, on: manager))
        let restored = makeManager(clock: clock, storedState: disk)
        XCTAssertTrue(isAuthorized(receipt, on: restored))
    }

    func testLegacyHelloCannotReplacePendingConfirmationOrUseExpiredCode() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 4600))
        let manager = makeManager(clock: clock)
        let issued = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        let receipt = try prepare(pairingRequest(secret: issued.oneTimeSecret), on: manager)
        XCTAssertThrowsError(try prepare(pairingRequest(secret: issued.oneTimeSecret, attemptID: nil), on: manager))
        XCTAssertFalse(isAuthorized(receipt, on: manager))
        XCTAssertTrue(try confirm(confirmation(for: receipt), on: manager))
        try manager.revokeDevice()
        let next = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        clock.date = next.expiresAt
        XCTAssertEqual(manager.status, .codeExpired)
        XCTAssertThrowsError(try prepare(pairingRequest(secret: next.oneTimeSecret, attemptID: nil), on: manager))
        XCTAssertFalse(manager.isPaired)
    }

    func testExpiredActiveCredentialAllowsReplacementAndLegacyStorageLoads() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5000))
        let legacy = RemoteStoredDeviceCredential(
            deviceID: "old-phone", credential: "legacy-bearer", expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Old phone", irohPeerEndpointID: endpointID("b")
        )
        let decoded = try RemoteStoredPairingState.decode(JSONEncoder().encode(legacy))
        let manager = makeManager(clock: clock, storedState: decoded)
        XCTAssertTrue(manager.isPaired)
        XCTAssertThrowsError(try manager.issueAdvertisement(server: .init(endpointID: endpointID("a"))))
        clock.date = legacy.expiresAt
        XCTAssertEqual(manager.status, .credentialExpired)
        let issued = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        let receipt = try prepare(pairingRequest(secret: issued.oneTimeSecret), on: manager)
        XCTAssertFalse(manager.isPaired)
        XCTAssertTrue(try confirm(confirmation(for: receipt), on: manager))
    }

    func testPersistedPairingFieldsAreBoundedAndEndpointIDsAreCanonical() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6500))
        var disk = RemoteStoredPairingState()
        let manager = makeManager(clock: clock, persist: { disk = $0 })
        let advertisement = try manager.issueAdvertisement(server: .init(endpointID: endpointID("a")))
        let request = pairingRequest(secret: advertisement.oneTimeSecret, deviceName: String(repeating: "📱", count: 512))
        XCTAssertThrowsError(try prepare(request, on: manager, peer: "invalid-endpoint"))
        _ = try prepare(request, on: manager)
        XCTAssertEqual(disk.pending?.credential.deviceName.count, RemotePairingManager.maximumDeviceNameCharacters)
    }

    func testFailedFirstSyncDoesNotReportConnected() throws {
        let now = Date(timeIntervalSince1970: 6750)
        var firstConnection = RemoteIrohGatewayAdapter.SyncState(sessionID: UUID())
        firstConnection.recordActivity(at: now)
        XCTAssertEqual(firstConnection.readiness(at: now), .syncing)
        let lostSnapshotTicket = try XCTUnwrap(firstConnection.issueTicket())
        XCTAssertEqual(firstConnection.readiness(at: now), .syncing)

        var reconnect = RemoteIrohGatewayAdapter.SyncState(sessionID: UUID())
        let newTicket = try XCTUnwrap(reconnect.issueTicket())
        XCTAssertFalse(reconnect.confirm(lostSnapshotTicket, at: now))
        XCTAssertEqual(reconnect.readiness(at: now), .offline)
        XCTAssertTrue(reconnect.confirm(newTicket, at: now))
        XCTAssertTrue(reconnect.confirm(newTicket, at: now))
        XCTAssertEqual(reconnect.readiness(at: now), .connected)
        XCTAssertEqual(reconnect.readiness(at: now.addingTimeInterval(26)), .offline)
    }

    func testLegacyPhoneShowsActivityWithoutClaimingConfirmedSync() {
        let now = Date(timeIntervalSince1970: 6800)
        var legacy = RemoteIrohGatewayAdapter.SyncState(sessionID: nil)
        legacy.recordActivity(at: now)
        XCTAssertEqual(legacy.readiness(at: now), .legacyActive)
        XCTAssertNil(legacy.issueTicket())
        XCTAssertFalse(legacy.confirm(UUID(), at: now))
        XCTAssertEqual(legacy.readiness(at: now.addingTimeInterval(26)), .offline)
    }

    func testCorruptStorageCanBeResetAfterDurableWrite() throws {
        var disk: Data? = Data("damaged".utf8)
        var failWrites = true
        let manager = RemotePairingManager(
            desktopInstanceID: "desktop", now: Date.init, randomBytes: { Data(repeating: 43, count: $0) },
            reloadStoredState: { try disk.map(RemoteStoredPairingState.decode) ?? .init() },
            persistState: { state in
                if failWrites {
                    throw PersistenceFailure.failed
                }
                disk = try JSONEncoder().encode(state)
            }
        )
        XCTAssertEqual(manager.status, .storageUnreadable)
        XCTAssertThrowsError(try manager.resetUnreadableStorage())
        XCTAssertEqual(manager.status, .storageUnreadable)
        failWrites = false
        try manager.resetUnreadableStorage()
        manager.retryStorageRead()
        XCTAssertEqual(manager.status, .idle)
        XCTAssertNoThrow(try manager.issueAdvertisement(server: .init(endpointID: endpointID("a"))))
    }

    func testTemporaryKeychainFailureCannotResetPairing() {
        let manager = RemotePairingManager(
            desktopInstanceID: "desktop", now: Date.init, randomBytes: { Data(repeating: 43, count: $0) },
            reloadStoredState: { throw PersistenceFailure.failed },
            persistState: { _ in XCTFail("An inaccessible Keychain item must not be replaced") }
        )
        XCTAssertEqual(manager.status, .storageUnavailable)
        XCTAssertThrowsError(try manager.resetUnreadableStorage())
    }

    func testRevokedCredentialStaysUnavailableAfterReopeningStorage() throws {
        let backend = TestSecureStorageBackend()
        let store = RemoteGatewayKeychain(backend: backend)
        let data = Data("pairing fixture".utf8)
        try store.write(data, for: .remotePairedDevice)
        XCTAssertEqual(try store.read(.remotePairedDevice), data)
        try store.remove(.remotePairedDevice)

        let reopened = RemoteGatewayKeychain(backend: backend)
        XCTAssertNil(try reopened.read(.remotePairedDevice))
        let replacement = Data("new pairing fixture".utf8)
        try reopened.write(replacement, for: .remotePairedDevice)
        XCTAssertEqual(try reopened.read(.remotePairedDevice), replacement)
    }

    func testUnpairAllowsSamePhoneToConfirmFreshPairingAfterRestart() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6800))
        let server = RemoteIrohEndpointAddress(endpointID: endpointID("a"))
        var disk = RemoteStoredPairingState()
        var nextByte: UInt8 = 0
        let randomBytes: (Int) -> Data = { count in
            nextByte += 1
            return Data(repeating: nextByte, count: count)
        }
        let manager = makeManager(clock: clock, randomBytes: randomBytes, persist: { disk = $0 })
        let oldCode = try manager.issueAdvertisement(server: server)
        let oldRequest = pairingRequest(secret: oldCode.oneTimeSecret)
        let oldResponse = try prepare(oldRequest, on: manager)
        let oldConfirmation = try confirmation(for: oldResponse)
        XCTAssertTrue(try confirm(oldConfirmation, on: manager))
        XCTAssertTrue(isAuthorized(oldResponse, on: manager))

        try manager.revokeDevice()
        XCTAssertEqual(manager.status, .idle)
        XCTAssertFalse(isAuthorized(oldResponse, on: manager))

        let restoredState = try RemoteStoredPairingState.decode(JSONEncoder().encode(disk))
        let reopened = makeManager(clock: clock, storedState: restoredState, randomBytes: randomBytes, persist: { disk = $0 })
        XCTAssertEqual(reopened.status, .idle)
        let newCode = try reopened.issueAdvertisement(server: server)
        XCTAssertNotEqual(newCode.oneTimeSecret, oldCode.oneTimeSecret)
        XCTAssertThrowsError(try prepare(oldRequest, on: reopened))

        let replacement = try prepare(pairingRequest(secret: newCode.oneTimeSecret), on: reopened)
        XCTAssertEqual(replacement.clientEndpointID, oldResponse.clientEndpointID)
        XCTAssertThrowsError(try confirm(oldConfirmation, on: reopened))
        XCTAssertFalse(isAuthorized(replacement, on: reopened))
        XCTAssertTrue(try confirm(confirmation(for: replacement), on: reopened))
        XCTAssertTrue(isAuthorized(replacement, on: reopened))
        XCTAssertFalse(isAuthorized(oldResponse, on: reopened))
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
        let manager = makeManager(clock: clock, storedState: .init(active: stored), persist: { _ in
            throw PersistenceFailure.failed
        })

        XCTAssertThrowsError(try manager.revokeDevice()) { error in
            XCTAssertTrue(error is PersistenceFailure)
        }
        XCTAssertTrue(manager.isPaired)
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
        storedState: RemoteStoredPairingState = .init(),
        randomBytes: @escaping (Int) -> Data = { count in Data(repeating: UInt8(count), count: count) },
        persist: @escaping (RemoteStoredPairingState) throws -> Void = { _ in }
    ) -> RemotePairingManager {
        RemotePairingManager(
            desktopInstanceID: "desktop",
            storedState: storedState,
            now: { clock.date },
            randomBytes: randomBytes,
            persistState: persist
        )
    }

    private func pairingRequest(
        secret: String, deviceName: String = "Phone", attemptID: UUID? = UUID()
    ) -> RemoteIrohPairingRequest {
        RemoteIrohPairingRequest(
            desktopInstanceID: "desktop",
            expectedServerEndpointID: endpointID("a"),
            clientEndpointID: endpointID("b"),
            oneTimeSecret: secret,
            deviceName: deviceName,
            attemptID: attemptID
        )
    }

    private func prepare(
        _ request: RemoteIrohPairingRequest, on manager: RemotePairingManager, peer: String? = nil
    ) throws -> RemoteIrohPairingResponse {
        try manager.pairIroh(
            request: request, authenticatedPeerEndpointID: peer ?? endpointID("b"),
            serverEndpointID: endpointID("a"), desktop: desktopSummary()
        )
    }

    private func confirmation(for response: RemoteIrohPairingResponse) throws -> RemotePairingConfirmation {
        try RemotePairingConfirmation(
            attemptID: XCTUnwrap(response.attemptID),
            authentication: .init(
                desktopInstanceID: "desktop",
                expectedServerEndpointID: response.serverEndpointID,
                deviceID: response.pairingResponse.deviceID,
                credential: response.pairingResponse.credential
            )
        )
    }

    private func confirm(
        _ confirmation: RemotePairingConfirmation, on manager: RemotePairingManager, peer: String? = nil
    ) throws -> Bool {
        try manager.confirmIroh(
            confirmation, authenticatedPeerEndpointID: peer ?? endpointID("b"), serverEndpointID: endpointID("a")
        )
    }

    private func isAuthorized(_ response: RemoteIrohPairingResponse, on manager: RemotePairingManager) -> Bool {
        manager.isAuthorizedIroh(
            authorizationHeader: "Bearer \(response.pairingResponse.credential)",
            deviceID: response.pairingResponse.deviceID,
            authenticatedPeerEndpointID: response.clientEndpointID
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
                _ = try await service.execute(RemoteCommandRequest(operation: operation), authorizeDispatch: {})
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
            _ = try await service.execute(request, authorizeDispatch: {})
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

    func testRemoteInterviewRejectsCodexControlCommandBeforeSubmission() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let agentMode = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first?.id)
        let session = await agentMode.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .codexExec

        let result = agentMode.submitUserTurn(
            text: "/goal", tabID: tabID, isLocalComposerInput: false, remoteInterviewFirst: true
        )

        XCTAssertEqual(result, .blocked(message: "Interview first requires a message that starts an agent turn."))
        XCTAssertTrue(session.items.isEmpty)
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
        ), authorizeDispatch: {})
        XCTAssertTrue(upload.accepted)
        let response = try await service.execute(.init(
            commandID: submissionID,
            operation: .startRun,
            workspaceID: workspace.id.uuidString,
            message: "Exercise the Remote launch path.",
            agentID: "claudeCode",
            interviewFirst: true,
            attachmentIDs: [attachmentID]
        ), authorizeDispatch: {})

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
        let input = try XCTUnwrap(inputAtDispatch)
        XCTAssertTrue(input.contains("@\(escapedPath)"))
        XCTAssertTrue(input.contains("<interview_first>"))
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
    func testRecordedQuestionsProjectLiveAndSavedExchangesWithoutRawToolPayloads() throws {
        struct LegacyTranscriptRow: Decodable {
            struct Detail: Decodable {
                let argumentsJSON: String?
                let resultJSON: String?
                let keyPaths: [String]
            }

            let text: String?
            let detail: Detail?
        }

        let arguments = """
        {"title":"Badge setup","provider_context":"internal test metadata","questions":[
            {"id":"shape","header":"Shape","question":"What shape should the badge be?"},
            {"id":"placement","header":"Placement","question":"Where should the badge appear?"},
            {"id":"notes","header":"Notes","question":"Any other notes? Bearer fixture-only-value"}
        ]}
        """
        let result = """
        {"answers":{
            "shape":{"answers":["Square"]},
            "placement":{"answers":["Sidebar","Header"]},
            "notes":{"skipped":true}
        },"timed_out":false,"skipped":false}
        """
        let stored = try XCTUnwrap(
            AgentAskUserTranscriptExchange.decode(argsJSON: arguments, resultJSON: result)?
                .persistedResultJSON(statusWord: "success", summaryText: "ask_user • success", byteBudget: 4096)
        )
        let executions = [
            toolExecution(name: "mcp__RepoPrompt__ask_user", status: .success, argsJSON: arguments, resultJSON: result),
            toolExecution(name: "ask_user", status: .success, resultJSON: stored),
            toolExecution(
                name: "ask_user",
                status: .success,
                argsJSON: arguments,
                resultJSON: #"{"answers":{},"timed_out":true}"#
            ),
            toolExecution(
                name: "ask_user",
                status: .success,
                argsJSON: arguments,
                resultJSON: #"{"status":"success"}"#
            )
        ]
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let activities = executions.enumerated().map { index, execution in
            AgentTranscriptActivity(
                id: fixedUUID(960 + index), timestamp: timestamp, sequenceIndex: index,
                role: index == 1 ? .assistant : .toolExecution, itemKind: .toolResult,
                text: index == 1 ? "Previously recorded answer" : "", toolExecution: execution,
                isSubstantiveAssistant: index == 1, sealsAssistantBoundary: index == 0
            )
        }
        let transcript = AgentTranscript(
            turns: [.init(
                id: fixedUUID(965), request: nil, responseSpans: [.init(startedAt: timestamp, activities: activities)],
                startedAt: timestamp
            )],
            nextSequenceIndex: activities.count
        )

        let collapsed = WindowRemoteReadService.project(transcript: transcript, includeDetails: false)
        let expanded = WindowRemoteReadService.project(transcript: transcript, includeDetails: true)
        XCTAssertEqual(collapsed.map(\.semanticKind), [.question, .question, .question, .question])
        XCTAssertTrue(collapsed.allSatisfy { $0.kind == .activity })
        XCTAssertEqual(collapsed.map(\.text), [
            "Shape: Square · Placement: Sidebar, Header · Notes: Skipped",
            "Shape: Square · Placement: Sidebar, Header · Notes: Skipped",
            "Timed out",
            nil
        ])
        XCTAssertTrue(collapsed.allSatisfy { $0.detail == nil })
        let exchange = try XCTUnwrap(expanded.first?.detail?.questionExchange)
        XCTAssertEqual(exchange.title, "Badge setup")
        XCTAssertEqual(exchange.questions[1].prompt, "Where should the badge appear?")
        XCTAssertEqual(exchange.questions[1].answer, "Sidebar, Header")
        XCTAssertTrue(exchange.questions[2].skipped)
        XCTAssertEqual(expanded[1].detail?.questionExchange, exchange)
        XCTAssertEqual(expanded[2].detail?.questionExchange?.outcome, .timedOut)
        XCTAssertNil(expanded[3].detail?.questionExchange)
        XCTAssertNil(expanded[0].detail?.argumentsJSON)
        XCTAssertNil(expanded[0].detailText)

        // Older iOS builds ignore questionExchange and display detail.resultJSON
        // even when the collapsed row already has text.
        let legacyRows = try JSONDecoder().decode([LegacyTranscriptRow].self, from: JSONEncoder().encode(expanded))
        XCTAssertNotNil(legacyRows[0].text)
        XCTAssertNil(legacyRows[0].detail?.argumentsJSON)
        XCTAssertEqual(legacyRows[0].detail?.keyPaths, [])
        let legacyResult = try XCTUnwrap(legacyRows[0].detail?.resultJSON)
        XCTAssertTrue(legacyResult.contains("What shape should the badge be?\nAnswer\nSquare"))
        XCTAssertTrue(legacyResult.contains("Where should the badge appear?\nAnswer\nSidebar, Header"))
        XCTAssertTrue(legacyResult.contains("Bearer [REDACTED]\nAnswer\nSkipped"))
        XCTAssertFalse(legacyResult.contains("fixture-only-value"))
        XCTAssertFalse(legacyResult.contains("internal test metadata"))
        XCTAssertEqual(legacyRows[1].detail?.resultJSON, legacyResult)
        XCTAssertTrue(try XCTUnwrap(legacyRows[2].detail?.resultJSON).contains("Answer\nTimed out"))
    }

    func testLiveTranscriptRecoversGitPreviewAfterToolResultCompaction() async throws {
        let diff = try await MCPGitToolProjection.makeDiffDTO(
            compare: "uncommitted",
            detail: "patches",
            changedFiles: [VCSUncommittedFile(path: "README.md", status: "M", additions: 2, deletions: 1)],
            perFilePatches: ["README.md": "--- a/README.md\n+++ b/README.md\n@@ -1 +1,2 @@\n-old\n+new\n+extra\n"],
            maxLinesForPatches: 100
        )
        let resultJSON = try String(decoding: JSONEncoder().encode(
            ToolResultDTOs.GitToolReplyDTO(op: "diff", diff: diff)
        ), as: UTF8.self)
        let result = AgentChatItem.toolResult(
            name: "git", invocationID: UUID(),
            argsJSON: #"{"op":"diff","detail":"patches","path":"README.md"}"#,
            resultJSON: resultJSON, isError: false, sequenceIndex: 1
        )
        let agentMode = AgentModeViewModel(
            testWindowID: -993, testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("No provider is needed") },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let tabID = UUID()
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: agentMode, tabID: tabID, name: "Remote live diff"
        )
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        let sessionID = UUID()
        agentMode.test_installLiveSession(session)
        _ = try XCTUnwrap(agentMode.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
        session.setItemsSilently([.user("Show the README diff", sequenceIndex: 0), result], reason: .testOverride)
        session.compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap()
        session.transcript = AgentTranscriptIO.buildTranscript(from: session.items, compact: false)
        let compacted = try XCTUnwrap(session.transcript.allActivities.first { $0.id == result.id }?.toolExecution?.resultJSON)
        XCTAssertTrue(AgentTranscriptToolNormalizer.isSummaryOnly(raw: compacted))
        XCTAssertEqual(agentMode.rawToolResultPayloadForRendering(tabID: tabID, itemID: result.id), resultJSON)

        let service = WindowRemoteReadService(contexts: [(agentMode, workspaceManager)])
        let page = try await service.transcript(
            sessionID: sessionID, paging: .recentBackward(before: nil), limit: 20, includeDetails: false
        )
        let collapsed = try XCTUnwrap(page.items.first { $0.id == result.id })
        XCTAssertEqual(collapsed.diffSummary, .init(fileCount: 1, singleFilePath: "README.md", additions: 2, deletions: 1))
        XCTAssertNil(collapsed.detail)

        let expanded = try await service.transcript(
            sessionID: sessionID, paging: .exactItem(result.id), limit: 1, includeDetails: true
        )
        let detail = try XCTUnwrap(expanded.items.first?.detail)
        let preview = try XCTUnwrap(detail.diffPreview)
        let patch = try XCTUnwrap(preview.files.first?.patch)
        XCTAssertTrue(patch.contains("@@ -1 +1,2 @@\n-old\n+new\n+extra"))
        XCTAssertFalse(preview.isTruncated)
        XCTAssertEqual(detail.resultJSON, compacted)

        let oversizedResult = resultJSON.replacingOccurrences(of: "+new", with: "+" + String(repeating: "界", count: 23000))
        XCTAssertLessThan(oversizedResult.count, 65536)
        XCTAssertGreaterThan(oversizedResult.utf8.count, 65536)
        session.replaceEphemeralToolResultPayloadMap([result.id: oversizedResult], liveItemIDs: [result.id])

        let boundedPage = try await service.transcript(
            sessionID: sessionID, paging: .recentBackward(before: nil), limit: 20, includeDetails: false
        )
        let boundedRow = try XCTUnwrap(boundedPage.items.first { $0.id == result.id })
        XCTAssertNil(boundedRow.diffSummary)
        XCTAssertTrue(try XCTUnwrap(boundedRow.text).contains("1 files (+2 -1)"))
        let boundedDetails = try await service.transcript(
            sessionID: sessionID, paging: .exactItem(result.id), limit: 1, includeDetails: true
        )
        XCTAssertNil(boundedDetails.items.first?.detail?.diffPreview)
        XCTAssertEqual(boundedDetails.items.first?.detail?.resultJSON, compacted)
    }

    func testRecordedDiffUsesDesktopCardPatchAndKeepsLargeGitSummaries() throws {
        let edit = #"""
        {"structuredContent":{"status":"success","edits_requested":1,"edits_applied":1,
        "added_lines":1,"deleted_lines":1,"card_unified_diff":"--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new"}}
        """#
        let gitPatch = "-old\n+first change\n+" + String(repeating: "x", count: 13000)
        let gitPatchJSON = try String(decoding: JSONEncoder().encode(gitPatch), as: UTF8.self)
        let git = #"""
        {"op":"diff","diff":{"compare":"uncommitted","oneliner":"1 file","totals":{"files":1,"insertions":2,"deletions":1},
        "files":[{"path":"Sources/A.swift","status":"modified","insertions":2,"deletions":1,
        "hunks":[{"header":"@@ -1 +1,2 @@","old_start":1,"new_start":1,"patch":\#(gitPatchJSON)}]}]}}
        """#
        let executions = [
            toolExecution(name: "apply_edits", status: .success, argsJSON: #"{"path":"/project/README.md"}"#, resultJSON: edit),
            toolExecution(name: "git", status: .success, resultJSON: git),
            toolExecution(name: "git", status: .success, resultJSON: #"{"op":"status"}"#)
        ]
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let activities = executions.enumerated().map { index, execution in
            AgentTranscriptActivity(
                id: fixedUUID(980 + index), timestamp: timestamp, sequenceIndex: index,
                role: .toolExecution, itemKind: .toolResult, text: "", toolExecution: execution,
                sealsAssistantBoundary: index == 0
            )
        }
        let transcript = AgentTranscript(
            turns: [.init(
                id: fixedUUID(985), request: nil, responseSpans: [.init(startedAt: timestamp, activities: activities)],
                startedAt: timestamp
            )],
            nextSequenceIndex: activities.count
        )

        let collapsed = WindowRemoteReadService.project(transcript: transcript, includeDetails: false)
        let expanded = WindowRemoteReadService.project(transcript: transcript, includeDetails: true)
        XCTAssertEqual(collapsed[0].kind, .activity)
        XCTAssertEqual(collapsed[0].semanticKind, .compactActivity)
        XCTAssertEqual(collapsed[0].diffSummary, .init(fileCount: 1, singleFilePath: "README.md", additions: 1, deletions: 1))
        XCTAssertEqual(collapsed[1].diffSummary, .init(fileCount: 1, singleFilePath: "Sources/A.swift", additions: 2, deletions: 1))
        XCTAssertNil(collapsed[2].diffSummary)
        XCTAssertTrue(collapsed.allSatisfy { $0.detail == nil })
        XCTAssertEqual(expanded.map(\.diffSummary), collapsed.map(\.diffSummary))
        XCTAssertEqual(expanded[0].detail?.diffPreview?.files.first?.patch, "--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new")
        let preview = try XCTUnwrap(expanded[1].detail?.diffPreview)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(preview.files.first?.patch, "@@ -1 +1,2 @@\n-old\n+first change")
        XCTAssertNil(expanded[2].detail?.diffPreview)
        XCTAssertEqual(try JSONDecoder().decode([RemoteTranscriptItem].self, from: JSONEncoder().encode(expanded)), expanded)
    }

    func testCompactToolSummariesIncludeResultMetadataWithoutFullOutput() {
        let read = toolExecution(
            name: "read_file", status: .success, argsJSON: #"{"path":"Sources/A.swift"}"#,
            resultJSON: #"{"content":"omitted body","total_lines":100,"first_line":3,"last_line":6,"display_path":"Sources/A.swift"}"#
        )
        XCTAssertEqual(WindowRemoteReadService.compactToolSummary(read), "Sources/A.swift • Lines 3–6")
        let search = toolExecution(
            name: "file_search", status: .success, argsJSON: #"{"pattern":"needle"}"#,
            resultJSON: #"{"total_matches":12,"content_match_groups":[]}"#
        )
        XCTAssertEqual(WindowRemoteReadService.compactToolSummary(search), "\"needle\" • 12 matches")
        let command = toolExecution(
            name: "functions.exec_command", status: .failed,
            resultJSON: #"{"type":"commandExecution","command":"swift build","exitCode":1,"aggregatedOutput":"omitted output","status":"failed"}"#
        )
        XCTAssertEqual(WindowRemoteReadService.compactToolSummary(command), "Shell command • Exit 1")
        let patch = toolExecution(
            name: "apply_patch", status: .success,
            resultJSON: #"{"status":"success","change_count":1,"changes":[{"path":"Sources/A.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}]}"#
        )
        XCTAssertEqual(WindowRemoteReadService.compactToolSummary(patch), "Sources/A.swift • +1 −1 lines")
        XCTAssertNil(WindowRemoteReadService.compactToolSummary(toolExecution(name: "unrecognized", status: .success)))
    }

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

    func testImageDownloadIsScopedToTranscriptAndRejectsReplacedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-image-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentSessionAttachmentStore(rootURL: directory)
        let sessionID = UUID()
        let attachment = AgentFileAttachment(source: .localFile(path: "/other/photo.jpg"), title: "Photo", kind: .image)
        let row = AgentTranscriptRequestAnchor(from: .user("Photo", attachments: [attachment]))
        let transcript = AgentTranscript(turns: [.init(request: row, startedAt: Date())], nextSequenceIndex: 1)
        let request = RemoteImageAttachmentRequest(
            sessionID: sessionID, itemID: row.id, attachmentID: attachment.id, variant: .original
        )
        XCTAssertEqual(WindowRemoteReadService.imageAttachment(in: transcript, request: request)?.id, attachment.id)
        XCTAssertNil(WindowRemoteReadService.imageAttachment(
            in: transcript, request: .init(sessionID: sessionID, itemID: UUID(), attachmentID: attachment.id, variant: .original)
        ))
        XCTAssertNil(WindowRemoteReadService.ownedImageURL(
            attachment: attachment, sessionID: sessionID, retainedRoot: directory, workspaceDirectory: directory
        ))
        let folder = store.sessionFolderURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(attachment.id.uuidString).appendingPathExtension("jpg")
        let size = RemoteImageAttachmentRequest.chunkBytes + 2
        try Data(repeating: 7, count: size).write(to: url)
        let owned = try XCTUnwrap(WindowRemoteReadService.ownedImageURL(
            attachment: attachment, sessionID: sessionID, retainedRoot: directory, workspaceDirectory: nil
        ))
        let first = try WindowRemoteReadService.readImage(at: owned, request: request)
        XCTAssertEqual(first.bytes.count, RemoteImageAttachmentRequest.chunkBytes)
        let remainder = RemoteImageAttachmentRequest(
            sessionID: sessionID, itemID: row.id, attachmentID: attachment.id, variant: .original,
            offset: first.bytes.count, revision: first.revision
        )
        XCTAssertEqual(try WindowRemoteReadService.readImage(at: owned, request: remainder).bytes, Data([7, 7]))
        try Data(repeating: 9, count: size).write(to: url, options: .atomic)
        XCTAssertThrowsError(try WindowRemoteReadService.readImage(at: owned, request: remainder)) { error in
            guard case RemoteImageReadError.changed = error else { return XCTFail("Expected an image revision mismatch.") }
        }
    }

    func testClientTaskAttachmentShowsMessageInsteadOfProviderMarkup() throws {
        let text = "Look at <this> & keep &lt; literal."
        let frame = AgentModeViewModel.mcpResidentTaskFrame(text)
        let photo = AgentFileAttachment(source: .localFile(path: "/fixture/photo.jpg"), title: "Photo", kind: .image)
        let turn = AgentTranscriptTurn(
            id: UUID(),
            request: AgentTranscriptRequestAnchor(from: .user(frame, attachments: [photo])),
            startedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let projected = WindowRemoteReadService.project(
            transcript: AgentTranscript(turns: [turn], nextSequenceIndex: 1), includeDetails: false
        )
        let item = try XCTUnwrap(projected.first)
        XCTAssertEqual(item.text, text)
        XCTAssertEqual(item.attachments?.first?.id, photo.id)
        XCTAssertEqual(turn.request?.text, frame)
        XCTAssertEqual(AgentModeViewModel.mcpResidentTaskDisplayText(frame, origin: .localComposer, attribution: nil), frame)
        let nested = AgentModeViewModel.mcpResidentTaskFrame(frame)
        XCTAssertEqual(AgentModeViewModel.mcpResidentTaskDisplayText(nested, origin: nil, attribution: nil), frame)
    }

    func testSavedTranscriptCarriesModelAndControlsWithoutASnapshotSession() throws {
        let capabilities = AgentSessionSelectionCapabilities(
            allowedAgentRawValues: ["codexExec"],
            allowedModelRawValues: ["gpt-5.6-sol"],
            allowedReasoningEffortRawValues: ["medium", "high"],
            resolvedModelRaw: "gpt-5.6-sol",
            resolvedReasoningEffortRaw: "high",
            isMutable: true,
            agentUnavailableReason: nil,
            selectionUnavailableReason: nil
        )
        let configuration = try XCTUnwrap(WindowRemoteReadService.chatConfiguration(
            agent: "codexExec", model: "gpt-5.6-sol-high", reasoningEffort: nil, capabilities: capabilities
        ))
        let page = WindowRemoteReadService.page(
            sessionID: UUID(), allItems: [], paging: .recentBackward(before: nil), limit: 15,
            chatConfiguration: configuration
        )
        XCTAssertEqual(page.chatConfiguration?.selection.modelID, "gpt-5.6-sol")
        XCTAssertEqual(page.chatConfiguration?.selection.reasoningEffort, "high")
        XCTAssertEqual(page.chatConfiguration?.controls?.reasoningEffort.allowedValueIDs, ["medium", "high"])
        XCTAssertEqual(page.chatConfiguration?.controls?.model.isMutable, true)
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
                summaryText: "TOKEN=shell-secret do-work"
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
        XCTAssertEqual(sanitized.first { $0.id == failedTool.id }?.text, "Shell command")
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
        XCTAssertFalse(encodedDefault.contains("shell-secret"))

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

    func testMultipartInputProjectsChoicesAndMarksOnlySecretFields() throws {
        let secret = AgentRunMCPSnapshot.Interaction.Field(
            id: "token", prompt: "Enter token", isSecret: true, allowsOther: false, options: []
        )
        let choice = AgentRunMCPSnapshot.Interaction.Field(
            id: "mode", prompt: "Choose a mode", isSecret: false, allowsOther: true,
            options: [.init(label: "Read", description: "Only read files")]
        )
        let interaction = AgentRunMCPSnapshot.Interaction(
            id: UUID(), kind: .userInput, responseType: .structured,
            title: "Input", prompt: nil, context: nil, allowsMultiple: nil,
            options: [], fields: [choice, secret], details: []
        )
        let result = try XCTUnwrap(AgentModeRemoteSessionQueryService.projectInteraction(
            interaction, createdAt: .distantPast
        ))
        XCTAssertEqual(result.kind, .secretInput)
        XCTAssertTrue(result.requiresSecureEntry)
        XCTAssertNil(result.responseUnavailableReason)
        let questions = try XCTUnwrap(result.questionnaire?.questions)
        XCTAssertEqual(questions.map(\.id), ["mode", "token"])
        XCTAssertEqual(questions.map(\.isSecret), [false, true])
        XCTAssertEqual(questions[0].options.map(\.label), ["Read", AgentRequestUserInputQuestion.otherOptionLabel])
        XCTAssertEqual(questions[0].options.first?.description, "Only read files")
        XCTAssertTrue(questions[0].allowsNote)
        XCTAssertFalse(questions[1].allowsSkip)

        struct LegacyInteraction: Decodable {
            let responseUnavailableReason: String?
        }
        let encoded = try JSONEncoder().encode(result)
        XCTAssertNotNil(try JSONDecoder().decode(LegacyInteraction.self, from: encoded).responseUnavailableReason)
        XCTAssertEqual(try JSONDecoder().decode(RemoteInteractionSummary.self, from: encoded), result)

        let unavailable = AgentModeRemoteSessionQueryService.projectInteraction(
            interaction, createdAt: .distantPast, requiresLocalUserInput: true
        )
        XCTAssertNil(unavailable?.questionnaire)
        XCTAssertNotNil(unavailable?.responseUnavailableReason)
    }

    func testRemoteAskUserConvertsChoicesAndPerQuestionSkipAndRejectsIncompleteAnswers() throws {
        let questionnaire = RemoteQuestionnaire(questions: [
            .init(
                id: "modes", prompt: "Choose modes", options: [.init(label: "Read"), .init(label: "Write")],
                allowsMultiple: true, allowsCustom: true, allowsSkip: true
            ),
            .init(id: "notes", prompt: "Anything else?", allowsCustom: true, allowsSkip: true)
        ])
        let answers: [String: RemoteQuestionAnswer] = [
            "modes": .init(selectedOptionIndices: [1, 0], text: "Read both"),
            "notes": .init(skipped: true)
        ]
        let payload = try WindowRemoteAgentControlService.questionResponsePayload(
            answers, questionnaire: questionnaire, userInput: nil
        )
        XCTAssertEqual(payload.askUserAnswersByQuestionID["modes"]?.selectedOptions, ["Write", "Read"])
        XCTAssertEqual(payload.askUserAnswersByQuestionID["modes"]?.customResponse, "Read both")
        XCTAssertEqual(payload.askUserAnswersByQuestionID["notes"]?.skipped, true)
        XCTAssertFalse(payload.skip)
        XCTAssertThrowsError(try WindowRemoteAgentControlService.questionResponsePayload(
            ["modes": .init(selectedOptionIndices: [1])], questionnaire: questionnaire, userInput: nil
        ))
    }

    func testRemoteUserInputUsesProviderDraftEncodingForOtherAndSecureNotes() throws {
        let request = AgentRequestUserInputRequest(
            receipt: .fixture(.int(9)), method: "item/tool/requestUserInput", threadID: "t", turnID: "t", itemID: "i",
            questions: [
                .init(
                    id: "mode",
                    header: "Mode",
                    question: "Which mode?",
                    isOther: true,
                    isSecret: false,
                    options: [.init(label: "Read", description: "Read files")]
                ),
                .init(id: "code", header: "Code", question: "Enter a code", isOther: false, isSecret: true, options: [])
            ]
        )
        let questionnaire = RemoteQuestionnaire(questions: [
            .init(
                id: "mode", prompt: "Which mode?", options: [.init(label: "Read"), .init(label: "None of the above")],
                allowsCustom: true, allowsNote: true
            ),
            .init(id: "code", prompt: "Enter a code", isSecret: true, allowsCustom: true)
        ])
        let payload = try WindowRemoteAgentControlService.questionResponsePayload(
            ["mode": .init(selectedOptionIndices: [1], text: "Another mode"), "code": .init(text: " test-code ")],
            questionnaire: questionnaire, userInput: request
        )
        XCTAssertEqual(payload.answersByQuestionID["mode"], ["None of the above", "user_note: Another mode"])
        XCTAssertEqual(payload.answersByQuestionID["code"], ["user_note: test-code"])
        XCTAssertNil(payload.text)
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
            deviceName: "Test phone",
            irohPeerEndpointID: String(repeating: "a", count: 64)
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
