import XCTest
@testable import RepoPromptRemoteProtocol

final class RemoteContractTests: XCTestCase {
    func testMacOnlyInteractionReasonIsOptionalForOlderClientsAndGateways() throws {
        struct LegacyInteraction: Codable, Equatable {
            let id: String
            let kind: RemoteInteractionKind
            let title: String?
            let prompt: String?
            let requiresSecureEntry: Bool
            let createdAt: Date
        }
        let legacy = LegacyInteraction(
            id: UUID().uuidString, kind: .approval, title: "Approval", prompt: "Review request",
            requiresSecureEntry: false, createdAt: Date(timeIntervalSince1970: 100)
        )
        let decoded = try JSONDecoder().decode(
            RemoteInteractionSummary.self, from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(decoded.responseUnavailableReason)
        let current = RemoteInteractionSummary(
            id: legacy.id, kind: legacy.kind, title: legacy.title, prompt: legacy.prompt,
            responseUnavailableReason: "Review hook trust on your Mac.", createdAt: legacy.createdAt
        )
        let data = try JSONEncoder().encode(current)
        XCTAssertEqual(try JSONDecoder().decode(RemoteInteractionSummary.self, from: data), current)
        XCTAssertEqual(try JSONDecoder().decode(LegacyInteraction.self, from: data), legacy)
    }

    func testProtocolCompatibilityAcceptsCurrentVersionOnly() {
        XCTAssertEqual(RemoteProtocol.minimumSupportedVersion, 1)
        XCTAssertEqual(RemoteProtocol.currentVersion, 1)
        XCTAssertEqual(RemoteProtocol.versionedPath, "/remote/v1")
        XCTAssertTrue(RemoteProtocol.supports(RemoteProtocol.currentVersion))
        XCTAssertFalse(RemoteProtocol.supports(RemoteProtocol.currentVersion + 1))
        XCTAssertFalse(RemoteProtocol.supports(RemoteProtocol.minimumSupportedVersion - 1))
    }

    func testAuthorizationUsesDesktopDefaultLevel() {
        let state = RemoteAuthorizationState(defaultLevel: .respond)

        XCTAssertEqual(state.effectiveLevel(), .respond)
        XCTAssertTrue(state.allows(.respond))
        XCTAssertFalse(state.allows(.control))
    }

    func testReplayBufferSequencesEventsAndRequestsSnapshotWhenCursorIsTooOld() async {
        let buffer = RemoteEventReplayBuffer(capacity: 2)
        let desktopID = "desktop-1"

        let first = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .sessionCreated))
        let second = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .runStarted))
        let third = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .runProgressed))

        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(third.sequence, 3)
        let latestCursor = await buffer.latestCursor()
        XCTAssertEqual(latestCursor, 3)

        let replay = await buffer.replay(after: 1, desktopInstanceID: desktopID)
        guard case let .events(events) = replay else {
            return XCTFail("Expected retained events")
        }
        XCTAssertEqual(events.map(\.sequence), [2, 3])

        let stale = await buffer.replay(after: 0, desktopInstanceID: desktopID)
        XCTAssertEqual(stale, .snapshotRequired)
    }

    func testDuplicateEventIDIsNotAppended() async {
        let buffer = RemoteEventReplayBuffer(capacity: 4)
        let eventID = UUID()
        let event = RemoteEvent(desktopInstanceID: "desktop-1", eventID: eventID, type: .catalogChanged)

        let first = await buffer.append(event)
        let duplicate = await buffer.append(event)

        XCTAssertEqual(first, duplicate)
        let latestCursor = await buffer.latestCursor()
        XCTAssertEqual(latestCursor, 1)
    }

    func testReplayBufferRemainsBoundedUnderManyEvents() async {
        let capacity = 128
        let buffer = RemoteEventReplayBuffer(capacity: capacity)
        for index in 0 ..< 5_000 {
            _ = await buffer.append(
                RemoteEvent(
                    desktopInstanceID: "desktop-1",
                    type: index.isMultiple(of: 2) ? .runProgressed : .sessionUpdated
                )
            )
        }

        let latestCursor = await buffer.latestCursor()
        XCTAssertEqual(latestCursor, 5_000)
        let retained = await buffer.replay(after: 4_872, desktopInstanceID: "desktop-1")
        guard case let .events(events) = retained else {
            return XCTFail("Expected the retained window to be replayable")
        }
        XCTAssertEqual(events.count, capacity)
        XCTAssertEqual(events.first?.sequence, 4_873)
        XCTAssertEqual(events.last?.sequence, 5_000)
        let stale = await buffer.replay(after: 4_871, desktopInstanceID: "desktop-1")
        XCTAssertEqual(stale, .snapshotRequired)
    }

    func testEventCoalescerKeepsLatestProjectionAndPreservesLifecycleEvents() {
        let sessionID = UUID()
        let firstProgress = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .runProgressed,
            sessionID: sessionID,
            payload: .text("first")
        )
        let latestProgress = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .runProgressed,
            sessionID: sessionID,
            payload: .text("latest")
        )
        let terminal = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .runCompleted,
            sessionID: sessionID
        )

        let result = RemoteEventCoalescer.coalesce([firstProgress, latestProgress, terminal])

        XCTAssertEqual(result, [latestProgress, terminal])
    }

    func testEventCoalescerCoalescesTranscriptRevisionsSeparatelyFromLifecycleEvents() {
        let sessionID = UUID()
        let runStarted = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .runStarted,
            sessionID: sessionID
        )
        let firstRevision = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .transcriptItemsAppended,
            sessionID: sessionID,
            payload: .text("41")
        )
        let interaction = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .interactionCreated,
            sessionID: sessionID
        )
        let latestRevision = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .transcriptItemsAppended,
            sessionID: sessionID,
            payload: .text("42")
        )
        let runCompleted = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .runCompleted,
            sessionID: sessionID
        )

        let result = RemoteEventCoalescer.coalesce([
            runStarted,
            firstRevision,
            interaction,
            latestRevision,
            runCompleted
        ])

        XCTAssertEqual(result, [runStarted, latestRevision, interaction, runCompleted])
    }

    func testEventCoalescerScalesAcrossLargeFleetProjectionBatch() {
        let events = (0 ..< 2_000).flatMap { index in
            let sessionID = UUID()
            return [
                RemoteEvent(
                    desktopInstanceID: "desktop-1",
                    type: .runProgressed,
                    sessionID: sessionID,
                    payload: .text("stale-(index)")
                ),
                RemoteEvent(
                    desktopInstanceID: "desktop-1",
                    type: .sessionUpdated,
                    sessionID: sessionID,
                    payload: .text("latest-(index)")
                )
            ]
        }

        let result = RemoteEventCoalescer.coalesce(events)

        XCTAssertEqual(result.count, 2_000)
        XCTAssertTrue(result.allSatisfy { $0.type == .sessionUpdated })
    }

    func testSnapshotRoundTripsWithoutSecretAnswerData() throws {
        let session = RemoteSessionSummary(
            sessionID: UUID(),
            workspaceID: "workspace-1",
            runState: .waitingForInput,
            pendingInteraction: RemoteInteractionSummary(
                id: "interaction-1",
                kind: .secretInput,
                prompt: "Enter provider token",
                requiresSecureEntry: true
            ),
            isLive: true
        )
        let snapshot = RemoteSnapshot(
            desktop: RemoteDesktopSummary(
                instanceID: "desktop-1",
                displayName: "Mac",
                appVersion: "1.0",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            sessions: [session],
            eventCursor: 12,
            transcriptRevisionEpoch: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("token-value"))
        XCTAssertTrue(decoded.sessions[0].pendingInteraction?.requiresSecureEntry == true)
    }

    func testCommandRoundTripDoesNotEchoSecretInResponse() throws {
        let request = RemoteCommandRequest(
            commandID: UUID(),
            operation: .respond,
            sessionID: UUID(),
            interactionID: UUID(),
            secret: "one-shot-secret"
        )
        let requestData = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RemoteCommandRequest.self, from: requestData)
        XCTAssertEqual(decoded, request)

        let responseData = try JSONEncoder().encode(
            RemoteCommandResponse(
                commandID: request.commandID,
                accepted: true,
                sessionID: request.sessionID
            )
        )
        XCTAssertFalse(String(decoding: responseData, as: UTF8.self).contains("one-shot-secret"))
    }

    func testAttentionRemovalEventRoundTrips() throws {
        let attentionID = UUID()
        let event = RemoteEvent(
            desktopInstanceID: "desktop",
            sequence: 4,
            type: .interactionResolved,
            payload: .attentionRemoved(attentionID)
        )
        let decoded = try JSONDecoder().decode(RemoteEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded, event)
    }

    func testCatalogChangedEventRoundTrips() throws {
        let event = RemoteEvent(
            desktopInstanceID: "desktop",
            sequence: 5,
            type: .catalogChanged,
            payload: .catalog(
                RemoteCatalogPayload(
                    workflows: [RemoteWorkflowDescriptor(id: "builtin-review", displayName: "Review", isBuiltIn: true)],
                    agents: [RemoteAgentDescriptor(id: "codexExec", displayName: "Codex CLI", models: ["default"], isAvailable: true)]
                )
            )
        )
        let decoded = try JSONDecoder().decode(RemoteEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded, event)
    }

    func testTranscriptAndHistoryPagesRoundTrip() throws {
        let sessionID = UUID()
        let item = RemoteTranscriptItem(
            id: UUID(),
            turnID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1),
            sequenceIndex: 1,
            kind: .activity,
            role: "assistant",
            text: "Done",
            toolName: "read_file",
            toolStatus: "success",
            detailAvailable: true,
            detailText: "Arguments: {}",
            detail: RemoteTranscriptDetail(
                argumentsJSON: "{}",
                reasoning: "Inspecting the selected file",
                keyPaths: ["Sources/App.swift"],
                exitCode: 0
            )
        )
        let transcript = RemoteTranscriptPage(sessionID: sessionID, items: [item], eventCursor: 5)
        let history = RemoteHistoryPage(entries: [
            RemoteHistoryEntry(
                id: sessionID,
                workspaceID: UUID().uuidString,
                sessionName: "Session",
                lastActivityAt: item.timestamp,
                turnCount: 1,
                runState: .completed
            )
        ])
        XCTAssertEqual(try JSONDecoder().decode(RemoteTranscriptPage.self, from: JSONEncoder().encode(transcript)), transcript)
        XCTAssertEqual(try JSONDecoder().decode(RemoteHistoryPage.self, from: JSONEncoder().encode(history)), history)
    }

    func testLegacyV1SnapshotFixtureDecodesWithParityMetadataAbsent() throws {
        let snapshot = try JSONDecoder().decode(
            RemoteSnapshot.self,
            from: fixtureData(named: "protocol-v1-snapshot")
        )

        XCTAssertEqual(snapshot.protocolVersion, 1)
        XCTAssertEqual(snapshot.eventCursor, 7)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].workflow, "Review")
        XCTAssertNil(snapshot.sessions[0].workflowID)
        XCTAssertNil(snapshot.sessions[0].runStartedAt)
        XCTAssertNil(snapshot.sessions[0].transcriptRevision)
        XCTAssertNil(snapshot.transcriptRevisionEpoch)
        XCTAssertEqual(snapshot.workflowCatalog.count, 1)
        XCTAssertNil(snapshot.workflowCatalog[0].iconName)
        XCTAssertNil(snapshot.workflowCatalog[0].accentColorHex)
        XCTAssertNil(snapshot.workflowCatalog[0].descriptionText)
        XCTAssertNil(snapshot.workflowCatalog[0].featuredRank)
    }

    func testLegacyV1TranscriptFixtureDecodesAsLegacyForwardPage() throws {
        let page = try JSONDecoder().decode(
            RemoteTranscriptPage.self,
            from: fixtureData(named: "protocol-v1-transcript-page")
        )

        XCTAssertEqual(page.protocolVersion, 1)
        XCTAssertEqual(page.nextSequenceIndex, 5)
        XCTAssertTrue(page.hasMore)
        XCTAssertNil(page.pagingMode)
        XCTAssertNil(page.olderCursor)
        XCTAssertNil(page.hasOlder)
        XCTAssertNil(page.transcriptRevision)
        XCTAssertNil(page.transcriptRevisionEpoch)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertNil(page.items[0].semanticKind)
        XCTAssertNil(page.items[0].detailText)
        XCTAssertNil(page.items[0].detail)
    }

    func testParityMetadataRoundTripsAndRemainsDecodableByLegacyModels() throws {
        let sessionID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let workflow = RemoteWorkflowDescriptor(
            id: "builtin-review",
            displayName: "Review",
            isBuiltIn: true,
            requiredAuthority: .control,
            iconName: "checkmark.seal",
            accentColorHex: "#44AAFF",
            descriptionText: "Review the selected changes.",
            featuredRank: 1
        )
        let session = RemoteSessionSummary(
            sessionID: sessionID,
            workspaceID: "workspace-1",
            sessionName: "Parity",
            workflow: "Review",
            workflowID: workflow.id,
            runStartedAt: timestamp,
            transcriptRevision: 12,
            agent: "codexExec",
            runState: .working,
            childSessionIDs: [],
            lastUpdatedAt: timestamp,
            isLive: true
        )
        let item = RemoteTranscriptItem(
            id: UUID(),
            turnID: UUID(),
            timestamp: timestamp,
            sequenceIndex: 8,
            kind: .conclusion,
            semanticKind: .assistantAnswer,
            role: "assistant",
            text: "Done",
            summaryOnly: false,
            detailAvailable: false
        )
        let cursor = RemoteTranscriptCursor(
            sequenceIndex: item.sequenceIndex,
            timestamp: item.timestamp,
            itemID: item.id
        )
        let revisionEpoch = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let page = RemoteTranscriptPage(
            sessionID: sessionID,
            items: [item],
            eventCursor: 19,
            pagingMode: .recentBackward,
            olderCursor: cursor,
            hasOlder: true,
            transcriptRevision: 12,
            transcriptRevisionEpoch: revisionEpoch
        )

        XCTAssertEqual(try roundTrip(workflow), workflow)
        XCTAssertEqual(try roundTrip(session), session)
        XCTAssertEqual(try roundTrip(item), item)
        XCTAssertEqual(try roundTrip(page), page)
        XCTAssertEqual(try roundTrip(page).transcriptRevisionEpoch, revisionEpoch)

        let legacyWorkflow = try JSONDecoder().decode(
            LegacyWorkflowDescriptor.self,
            from: JSONEncoder().encode(workflow)
        )
        XCTAssertEqual(legacyWorkflow.id, workflow.id)
        XCTAssertEqual(legacyWorkflow.displayName, workflow.displayName)
        XCTAssertEqual(legacyWorkflow.requiredAuthority, .control)

        let legacySession = try JSONDecoder().decode(
            LegacySessionSummary.self,
            from: JSONEncoder().encode(session)
        )
        XCTAssertEqual(legacySession.sessionID, sessionID)
        XCTAssertEqual(legacySession.workflow, "Review")
        XCTAssertEqual(legacySession.runState, .working)

        let legacyItem = try JSONDecoder().decode(
            LegacyTranscriptItem.self,
            from: JSONEncoder().encode(item)
        )
        XCTAssertEqual(legacyItem.kind, .conclusion)
        XCTAssertEqual(legacyItem.role, "assistant")

        let legacyPage = try JSONDecoder().decode(
            LegacyTranscriptPage.self,
            from: JSONEncoder().encode(page)
        )
        XCTAssertEqual(legacyPage.sessionID, sessionID)
        XCTAssertEqual(legacyPage.eventCursor, 19)
        XCTAssertFalse(legacyPage.hasMore)
    }

    func testAgentSelectionMetadataRoundTripsAndLegacySnapshotDefaultsRemainNil() throws {
        let effort = RemoteReasoningEffortDescriptor(id: "high", displayName: "High")
        let model = RemoteModelDescriptor(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            reasoningEfforts: [effort],
            defaultReasoningEffortID: effort.id
        )
        let agent = RemoteAgentDescriptor(
            id: "codexExec",
            displayName: "Codex CLI",
            models: ["gpt-5.6-sol-high"],
            isAvailable: true,
            modelDescriptors: [model],
            defaultModelID: model.id
        )
        let controls = RemoteSessionConfigurationControls(
            agent: RemoteSelectionControl(isMutable: false, allowedValueIDs: [agent.id]),
            model: RemoteSelectionControl(isMutable: true, allowedValueIDs: [model.id]),
            reasoningEffort: RemoteSelectionControl(isMutable: true, allowedValueIDs: [effort.id])
        )
        let session = RemoteSessionSummary(
            sessionID: UUID(),
            workspaceID: "workspace",
            agent: agent.id,
            model: model.id,
            reasoningEffort: effort.id,
            configurationControls: controls,
            runState: .idle,
            isLive: true
        )
        let metadata = RemoteCatalogMetadata(
            defaultAgentID: agent.id,
            defaultSelection: RemoteAgentSelection(
                agentID: agent.id,
                modelID: model.id,
                reasoningEffort: effort.id
            ),
            supportsStartSelection: true,
            supportsSessionConfiguration: true
        )
        let snapshot = RemoteSnapshot(
            desktop: RemoteDesktopSummary(instanceID: "desktop", displayName: "Mac", appVersion: "test", isAvailable: true),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            sessions: [session],
            agentCatalog: [agent],
            agentCatalogMetadata: metadata
        )
        let response = RemoteCommandResponse(
            commandID: UUID(),
            accepted: true,
            sessionID: session.sessionID,
            resolvedSelection: RemoteAgentSelection(
                agentID: agent.id,
                modelID: model.id,
                reasoningEffort: effort.id
            )
        )

        XCTAssertEqual(try roundTrip(snapshot), snapshot)
        XCTAssertEqual(try roundTrip(response), response)

        let legacySnapshot = try JSONDecoder().decode(
            RemoteSnapshot.self,
            from: fixtureData(named: "protocol-v1-snapshot")
        )
        XCTAssertNil(legacySnapshot.agentCatalogMetadata)
        XCTAssertNil(legacySnapshot.sessions.first?.configurationControls)
    }

    func testTranscriptCursorRoundTripsAndUsesDeterministicTotalOrder() throws {
        let earlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let timestamp = Date(timeIntervalSince1970: 100)
        let cursors = [
            RemoteTranscriptCursor(sequenceIndex: 2, timestamp: timestamp, itemID: earlyID),
            RemoteTranscriptCursor(sequenceIndex: 1, timestamp: timestamp.addingTimeInterval(1), itemID: lateID),
            RemoteTranscriptCursor(sequenceIndex: 1, timestamp: timestamp, itemID: lateID),
            RemoteTranscriptCursor(sequenceIndex: 1, timestamp: timestamp, itemID: earlyID)
        ]

        XCTAssertEqual(cursors.sorted(), [cursors[3], cursors[2], cursors[1], cursors[0]])
        XCTAssertEqual(try roundTrip(cursors[0]), cursors[0])
    }

    func testTranscriptRevisionEventRoundTripsAsNumericTextOnly() throws {
        let event = RemoteEvent(
            desktopInstanceID: "desktop-1",
            sequence: 9,
            type: .transcriptItemsAppended,
            workspaceID: "workspace-1",
            sessionID: UUID(),
            payload: .text("42")
        )
        let data = try JSONEncoder().encode(event)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(try JSONDecoder().decode(RemoteEvent.self, from: data), event)
        XCTAssertTrue(encoded.contains("transcript_items_appended"))
        XCTAssertTrue(encoded.contains("\"text\":\"42\""))
        XCTAssertFalse(encoded.contains("argumentsJSON"))
        XCTAssertFalse(encoded.contains("resultJSON"))
        XCTAssertFalse(encoded.contains("reasoning"))
    }

    func testSecretsAndRawDetailsDoNotLeakIntoOrdinaryProtocolProjections() throws {
        let secret = "ONE_SHOT_SECRET_MARKER"
        let rawDetail = "RAW_TOOL_DETAIL_MARKER"
        let sessionID = UUID()
        let request = RemoteCommandRequest(
            operation: .respond,
            sessionID: sessionID,
            interactionID: UUID(),
            secret: secret
        )
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains(secret))

        let session = RemoteSessionSummary(
            sessionID: sessionID,
            workspaceID: "workspace-1",
            runState: .waitingForInput,
            pendingInteraction: RemoteInteractionSummary(
                id: "interaction-1",
                kind: .secretInput,
                prompt: "Enter a credential",
                requiresSecureEntry: true
            ),
            isLive: true
        )
        let snapshot = RemoteSnapshot(
            desktop: RemoteDesktopSummary(
                instanceID: "desktop-1",
                displayName: "Mac",
                appVersion: "1.0",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            sessions: [session]
        )
        let defaultPage = RemoteTranscriptPage(
            sessionID: sessionID,
            items: [RemoteTranscriptItem(
                id: UUID(),
                turnID: UUID(),
                timestamp: Date(timeIntervalSince1970: 1),
                sequenceIndex: 1,
                kind: .activity,
                semanticKind: .compactActivity,
                role: "tool",
                toolName: "exec",
                detailAvailable: true
            )],
            pagingMode: .recentBackward,
            hasOlder: false,
            transcriptRevision: 1
        )
        let revisionEvent = RemoteEvent(
            desktopInstanceID: "desktop-1",
            type: .transcriptItemsAppended,
            sessionID: sessionID,
            payload: .text("1")
        )
        let response = RemoteCommandResponse(
            commandID: request.commandID,
            accepted: true,
            sessionID: sessionID
        )

        for value in [
            try JSONEncoder().encode(snapshot),
            try JSONEncoder().encode(defaultPage),
            try JSONEncoder().encode(revisionEvent),
            try JSONEncoder().encode(response)
        ] {
            let encoded = String(decoding: value, as: UTF8.self)
            XCTAssertFalse(encoded.contains(secret))
            XCTAssertFalse(encoded.contains(rawDetail))
            XCTAssertFalse(encoded.contains("argumentsJSON"))
            XCTAssertFalse(encoded.contains("resultJSON"))
            XCTAssertFalse(encoded.contains("reasoning"))
        }

        let optInDetail = RemoteTranscriptDetail(argumentsJSON: rawDetail)
        XCTAssertTrue(
            String(decoding: try JSONEncoder().encode(optInDetail), as: UTF8.self).contains(rawDetail)
        )
    }

    func testNotificationEnvelopeIsEncryptedAndRoundTrips() throws {
        let payload = RemoteNotificationPayload(
            category: .approvalRequired,
            desktopInstanceID: "desktop-1",
            sessionID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "RepoPrompt needs approval",
            body: "Open RepoPrompt Remote to continue."
        )
        let envelope = try RemoteNotificationCrypto.seal(
            payload,
            credential: "device-credential",
            desktopInstanceID: "desktop-1",
            deviceID: "device-1"
        )
        let encoded = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertFalse(encoded.contains(payload.title))
        XCTAssertFalse(encoded.contains(payload.body))
        XCTAssertEqual(
            try RemoteNotificationCrypto.open(
                envelope,
                credential: "device-credential",
                expectedDesktopInstanceID: "desktop-1",
                expectedDeviceID: "device-1"
            ),
            payload
        )
        XCTAssertThrowsError(
            try RemoteNotificationCrypto.open(envelope, credential: "wrong", expectedDesktopInstanceID: "desktop-1")
        )
        XCTAssertThrowsError(
            try RemoteNotificationCrypto.open(
                envelope,
                credential: "device-credential",
                expectedDesktopInstanceID: "desktop-1",
                expectedDeviceID: "other-device"
            )
        )
        let unsupportedVersion = RemoteNotificationEnvelope(
            version: 2,
            envelopeID: envelope.envelopeID,
            desktopInstanceID: envelope.desktopInstanceID,
            deviceID: envelope.deviceID,
            category: envelope.category,
            sessionID: envelope.sessionID,
            createdAt: envelope.createdAt,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            authenticationTag: envelope.authenticationTag
        )
        XCTAssertThrowsError(
            try RemoteNotificationCrypto.open(
                unsupportedVersion,
                credential: "device-credential",
                expectedDesktopInstanceID: "desktop-1",
                expectedDeviceID: "device-1"
            )
        )
    }

    func testDiagnosticsAndNotificationRegistrationRoundTrip() throws {
        let registration = RemoteNotificationRegistration(
            platform: .apns,
            deviceToken: "token",
            relayURL: "https://relay.example/v1/notify"
        )
        let request = RemoteCommandRequest(
            operation: .registerNotifications,
            notificationRegistration: registration
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteCommandRequest.self, from: JSONEncoder().encode(request)),
            request
        )

        let diagnostics = RemoteDiagnostics(
            gatewayState: "running",
            lastEventCursor: 9,
            pairedDevice: true,
            notificationRegistration: true,
            notificationRelayConfigured: true
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteDiagnostics.self, from: JSONEncoder().encode(diagnostics)),
            diagnostics
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    func testContextBuilderCommandAndResultRoundTrip() throws {
        let request = RemoteCommandRequest(
            operation: .contextBuilder,
            workspaceID: "workspace-1",
            message: "Make a plan for the next release",
            contextBuilderResponseType: "plan"
        )
        let response = RemoteCommandResponse(
            commandID: request.commandID,
            accepted: true,
            workspaceID: request.workspaceID,
            message: "Context Builder completed.",
            contextBuilderResult: RemoteContextBuilderResult(
                tabID: "tab-1",
                status: "completed",
                prompt: "A rewritten task",
                fileCount: 12,
                totalTokens: 900,
                responseType: "plan",
                plan: "1. Implement\n2. Verify"
            )
        )

        XCTAssertEqual(try JSONDecoder().decode(RemoteCommandRequest.self, from: JSONEncoder().encode(request)), request)
        XCTAssertEqual(try JSONDecoder().decode(RemoteCommandResponse.self, from: JSONEncoder().encode(response)), response)
    }
}

/// Frozen protocol-v1 decoder shapes prove additive fields are ignored by old clients.
private struct LegacyWorkflowDescriptor: Decodable {
    let id: String
    let displayName: String
    let isBuiltIn: Bool
    let requiredAuthority: RemoteAuthorityLevel
}

private struct LegacySessionSummary: Decodable {
    let sessionID: UUID
    let workspaceID: String
    let workflow: String?
    let runState: RemoteRunState
    let childSessionIDs: [UUID]
    let lastUpdatedAt: Date
    let isLive: Bool
}

private struct LegacyTranscriptItem: Decodable {
    let id: UUID
    let turnID: UUID
    let timestamp: Date
    let sequenceIndex: Int
    let kind: RemoteTranscriptItemKind
    let role: String
    let summaryOnly: Bool
    let detailAvailable: Bool
}

private struct LegacyTranscriptPage: Decodable {
    let protocolVersion: Int
    let sessionID: UUID
    let items: [LegacyTranscriptItem]
    let nextSequenceIndex: Int?
    let hasMore: Bool
    let eventCursor: UInt64
}
