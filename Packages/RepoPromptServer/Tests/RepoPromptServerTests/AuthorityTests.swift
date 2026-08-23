import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class AuthorityTests: XCTestCase {
    func testCollaborationRevisionsAndExecutionPermissionsAreOperational() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: DelayedProviderRunner())
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let owner = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let controller = ExternalActor(userID: "u2", username: "bob", displayName: "Bob")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: owner, idempotencyKey: "policy-project", requestDigest: "policy-project")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "hello"), externalActor: owner, idempotencyKey: "policy-session", requestDigest: "policy-session")

        let initialPermission = try await authority.permissionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(initialPermission?.mode, "workspaceWrite")
        let initial = try await authority.collaborationMetadata(sessionID: session.sessionID)
        XCTAssertEqual(initial.controllerUserID, owner.userID)
        XCTAssertEqual(initial.policyRevision, 1)

        let transferred = try await authority.updateCollaborationMetadata(
            sessionID: session.sessionID,
            input: .init(expectedPolicyRevision: 1, expectedControllerRevision: 1, expectedMembershipRevision: 1, visibility: .collaborative, collaborativeSteeringEnabled: true, controllerUserID: controller.userID),
            actor: owner,
            idempotencyKey: "policy-transfer",
            requestDigest: "policy-transfer"
        )
        XCTAssertEqual(transferred.policyRevision, 2)
        XCTAssertEqual(transferred.controllerRevision, 2)
        XCTAssertEqual(transferred.membershipRevision, 2)

        _ = try await authority.execute(command: .sendFollowup(text: "collaborator", expectedSessionRevision: 2), sessionID: session.sessionID, externalActor: owner, idempotencyKey: "collaborator-followup", requestDigest: "collaborator-followup")
        _ = try await authority.updatePermissions(sessionID: session.sessionID, expectedRevision: 1, mode: "disabled", providerSettings: [:], actor: controller, idempotencyKey: "disable-provider", requestDigest: "disable-provider")
        do {
            _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: session.sessionID, externalActor: controller, idempotencyKey: "disabled-run", requestDigest: "disabled-run")
            XCTFail("expected execution policy rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }
        try await store.close()
    }

    func testCollaborationAcknowledgementIsExactEventedAndRestored() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("authority.sqlite")
        let store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let authority = RepoPromptHeadlessAuthority(store: store)
        let owner = ExternalActor(userID: "owner", username: "alice", displayName: "Alice")
        let controller = ExternalActor(userID: "controller", username: "bob", displayName: "Bob")
        let project = try await authority.createProject(
            input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
            externalActor: owner,
            idempotencyKey: "ack-project",
            requestDigest: "ack-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: owner,
            idempotencyKey: "ack-session",
            requestDigest: "ack-session"
        )
        let requestID = UUID()
        let correlationID = UUID()
        let decisionID = UUID()
        let decision = AuthorizationDecision(
            decisionID: decisionID,
            actor: owner,
            sessionID: session.sessionID,
            projectID: project.projectID,
            operation: "setSessionVisibility",
            requestDigest: "ack-digest",
            policyRevision: 2,
            controllerRevision: 2,
            membershipRevision: 2,
            attributionLabels: .init(
                creatorUserID: owner.userID,
                controllerUserID: controller.userID,
                visibility: .collaborative
            ),
            issuedAt: Date().addingTimeInterval(-1),
            expiresAt: Date().addingTimeInterval(60),
            requestID: requestID,
            correlationID: correlationID,
            keyID: "test-app",
            signature: "verified-upstream"
        )
        let mismatchedDecision = AuthorizationDecision(
            decisionID: UUID(),
            actor: owner,
            sessionID: session.sessionID,
            projectID: project.projectID,
            operation: "setSessionVisibility",
            requestDigest: "wrong-digest",
            policyRevision: 1,
            controllerRevision: 1,
            membershipRevision: 1,
            attributionLabels: decision.attributionLabels,
            issuedAt: decision.issuedAt,
            expiresAt: decision.expiresAt,
            requestID: UUID(),
            correlationID: UUID(),
            keyID: decision.keyID,
            signature: decision.signature
        )
        do {
            _ = try await authority.updateCollaborationMetadata(
                sessionID: session.sessionID,
                input: .init(
                    expectedPolicyRevision: 1,
                    expectedControllerRevision: 1,
                    expectedMembershipRevision: 1,
                    policyRevision: 2,
                    controllerRevision: 2,
                    membershipRevision: 2,
                    visibility: .collaborative,
                    collaborativeSteeringEnabled: true,
                    controllerUserID: controller.userID
                ),
                actor: owner,
                idempotencyKey: "ack-mismatch",
                requestDigest: "ack-digest",
                authorizationDecision: mismatchedDecision
            )
            XCTFail("expected operation-bound authorization acknowledgement rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }
        let unchangedCollaboration = try await authority.collaborationMetadata(sessionID: session.sessionID)
        XCTAssertEqual(unchangedCollaboration.policyRevision, 1)
        let updated = try await authority.updateCollaborationMetadata(
            sessionID: session.sessionID,
            input: .init(
                expectedPolicyRevision: 1,
                expectedControllerRevision: 1,
                expectedMembershipRevision: 1,
                policyRevision: 2,
                controllerRevision: 2,
                membershipRevision: 2,
                visibility: .collaborative,
                collaborativeSteeringEnabled: true,
                controllerUserID: controller.userID
            ),
            actor: owner,
            idempotencyKey: "ack-update",
            requestDigest: "ack-digest",
            authorizationDecision: decision
        )
        let expectedAck = CollaborationAcknowledgement(
            decisionID: decisionID,
            acknowledgedPolicyRevision: 2,
            acknowledgedControllerRevision: 2,
            acknowledgedMembershipRevision: 2,
            resultingPolicyRevision: 2,
            resultingControllerRevision: 2,
            resultingMembershipRevision: 2,
            requestID: requestID,
            correlationID: correlationID
        )
        XCTAssertEqual(updated.collaborationAcknowledgement, expectedAck)

        let page = try await authority.events(after: session.cursor, limit: 10)
        let collaborationEvents = page.events.filter {
            $0.eventType == .visibilityUpdated || $0.eventType == .controllerUpdated
        }
        XCTAssertEqual(collaborationEvents.map(\.eventType), [.visibilityUpdated, .controllerUpdated])
        for event in collaborationEvents {
            XCTAssertEqual(event.correlationID, correlationID)
            let payloadData = try JSONEncoder.serviceEncoder.encode(event.payload.object)
            let payload = try JSONDecoder.serviceDecoder.decode(CollaborationMetadataSnapshot.self, from: payloadData)
            XCTAssertEqual(payload, updated)
            XCTAssertEqual(payload.collaborationAcknowledgement, expectedAck)
        }

        try await authority.quiesce()
        try await store.close(clean: true)
        let reopenedStore = try await SQLiteServiceStore.open(storage: .file(database.path))
        let restoredAuthority = RepoPromptHeadlessAuthority(store: reopenedStore)
        try await restoredAuthority.recover()
        let restored = try await restoredAuthority.collaborationMetadata(sessionID: session.sessionID)
        XCTAssertEqual(restored, updated)
        XCTAssertEqual(restored.collaborationAcknowledgement, expectedAck)
        try await restoredAuthority.quiesce()
        try await reopenedStore.close(clean: true)
    }

    func testSignedAuthorizationDecisionBindsWithoutLocalEligibility() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let owner = ExternalActor(userID: "owner", username: "alice", displayName: "Alice")
        let controller = ExternalActor(userID: "controller", username: "bob", displayName: "Bob")
        let collaborator = ExternalActor(userID: "collaborator", username: "carol", displayName: "Carol")
        let project = try await authority.createProject(
            input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
            externalActor: owner,
            idempotencyKey: "policy-project",
            requestDigest: "policy-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "hello"),
            externalActor: owner,
            idempotencyKey: "policy-session",
            requestDigest: "policy-session"
        )
        _ = try await authority.updateCollaborationMetadata(
            sessionID: session.sessionID,
            input: .init(
                expectedPolicyRevision: 1,
                expectedControllerRevision: 1,
                expectedMembershipRevision: 1,
                visibility: .collaborative,
                collaborativeSteeringEnabled: true,
                controllerUserID: controller.userID
            ),
            actor: owner,
            idempotencyKey: "policy-transfer",
            requestDigest: "policy-transfer"
        )
        let collaborative = try await authority.collaborationMetadata(sessionID: session.sessionID)

        try await authority.authorizeSessionCollaboration(
            sessionID: session.sessionID,
            actor: collaborator,
            operation: "replaceSelection",
            requestDigest: "policy-selection",
            authorizationDecision: signedDecision(
                actor: collaborator,
                sessionID: session.sessionID,
                projectID: project.projectID,
                operation: "replaceSelection",
                requestDigest: "policy-selection",
                metadata: collaborative
            )
        )

        _ = try await authority.updateCollaborationMetadata(
            sessionID: session.sessionID,
            input: .init(
                expectedPolicyRevision: collaborative.policyRevision,
                visibility: .collaborative,
                collaborativeSteeringEnabled: false,
                controllerUserID: controller.userID
            ),
            actor: controller,
            idempotencyKey: "policy-signed-visibility",
            requestDigest: "policy-signed-visibility",
            authorizationDecision: signedDecision(
                actor: controller,
                sessionID: session.sessionID,
                projectID: project.projectID,
                operation: "setSessionVisibility",
                requestDigest: "policy-signed-visibility",
                metadata: collaborative,
                policyRevision: collaborative.policyRevision + 1,
                controllerRevision: collaborative.controllerRevision,
                membershipRevision: collaborative.membershipRevision
            )
        )

        do {
            _ = try await authority.updatePermissions(
                sessionID: session.sessionID,
                expectedRevision: 1,
                mode: "disabled",
                providerSettings: [:],
                actor: collaborator,
                idempotencyKey: "policy-permissions",
                requestDigest: "policy-permissions"
            )
            XCTFail("expected unsigned collaborator permission update to stay locally rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }

        do {
            _ = try await authority.execute(
                command: .sendFollowup(text: "stale", expectedSessionRevision: session.revision + 1),
                sessionID: session.sessionID,
                externalActor: controller,
                idempotencyKey: "policy-stale",
                requestDigest: "policy-stale",
                authorizationDecision: signedDecision(
                    actor: controller,
                    sessionID: session.sessionID,
                    projectID: project.projectID,
                    operation: "sendFollowup",
                    requestDigest: "policy-stale",
                    metadata: collaborative
                )
            )
            XCTFail("expected stale authorization revisions to be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }

        try await authority.quiesce()
        try await store.close()
    }

    func testProviderRunSupportsSteeringCompletionAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runtime = SteeringProviderRuntime()
        let provider = ProviderCLIAdapter(runtimes: [runtime])
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-run", requestDigest: "p-run")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "first"), externalActor: actor, idempotencyKey: "s-run", requestDigest: "s-run")

        do {
            _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "resume", requestDigest: "resume")
        } catch {
            print("NATIVE RESUME ERROR: \(error)")
            XCTFail("native resume failed: \(error)")
            try? await store.close()
            return
        }
        do {
            _ = try await authority.execute(command: .steerSession(text: "second", targetTurnEpoch: 1), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "steer", requestDigest: "steer")
        } catch {
            print("NATIVE STEER ERROR: \(error)")
            XCTFail("native steer failed: \(error)")
            try? await store.close()
            return
        }
        try await Task.sleep(for: .milliseconds(150))
        let completed = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.transcript.suffix(2).map(\.content), ["second", "provider:second"])

        let cancelSession: SessionSnapshot
        do {
            cancelSession = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "cancel"), externalActor: actor, idempotencyKey: "s-cancel", requestDigest: "s-cancel")
            await runtime.holdNextRun()
            _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: cancelSession.sessionID, externalActor: actor, idempotencyKey: "resume-cancel", requestDigest: "resume-cancel")
            _ = try await authority.execute(command: .cancelSession(expectedRunID: nil, expectedGeneration: 1), sessionID: cancelSession.sessionID, externalActor: actor, idempotencyKey: "cancel", requestDigest: "cancel")
        } catch {
            print("NATIVE CANCEL ERROR: \(error)")
            XCTFail("native cancel phase failed: \(error)")
            try? await store.close()
            return
        }
        let canceled = try await authority.sessionSnapshot(sessionID: cancelSession.sessionID)
        XCTAssertEqual(canceled.state, .canceled)
        await authority.waitForProviderRunsToSettle()
        try await authority.quiesce()
        do { try await store.close() } catch {
            XCTFail("store close after provider controls failed: \(error)")
            return
        }
    }

    func testExecutionPermissionSnapshotIsAppliedToNativeProviderRequest() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runtime = PolicyRecordingProviderRuntime()
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: ProviderCLIAdapter(runtimes: [runtime]))
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-policy-runtime", requestDigest: "p-policy-runtime")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "inspect"), externalActor: actor, idempotencyKey: "s-policy-runtime", requestDigest: "s-policy-runtime")
        _ = try await authority.updatePermissions(sessionID: session.sessionID, expectedRevision: 1, mode: "readOnly", providerSettings: ["codex.approvalPolicy": "never"], actor: actor)
        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "run-policy-runtime", requestDigest: "run-policy-runtime")
        await authority.waitForProviderRunsToSettle()
        let recordedPolicy = await runtime.lastPolicy()
        let policy = try XCTUnwrap(recordedPolicy)
        XCTAssertEqual(policy.mode, .readOnly)
        XCTAssertTrue(policy.writableRoots.isEmpty)
        XCTAssertEqual(policy.providerSettings["codex.approvalPolicy"], "never")
        try await authority.quiesce()
        try await store.close()
    }

    func testFollowupResumesDurableProviderConversationAutomatically() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/authority-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runtime = ResumeRecordingProviderRuntime()
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            providerAdapter: ProviderCLIAdapter(runtimes: [runtime])
        )
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(
            input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "p-auto-resume",
            requestDigest: "p-auto-resume"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "s-auto-resume",
            requestDigest: "s-auto-resume"
        )

        for index in 1 ... 2 {
            _ = try await authority.startEmbeddedProviderRun(
                sessionID: session.sessionID,
                actor: actor,
                userMessage: "turn \(index)",
                providerPrompt: "turn \(index)",
                idempotencyKey: "auto-resume-\(index)",
                requestDigest: "auto-resume-\(index)"
            )
            await authority.waitForProviderRunsToSettle()
        }

        let resumeIdentities = await runtime.resumeIdentities()
        XCTAssertEqual(resumeIdentities.count, 2)
        XCTAssertNil(resumeIdentities[0])
        XCTAssertEqual(resumeIdentities[1], "durable-thread")
        let fallbackPrompts = await runtime.fallbackPrompts()
        XCTAssertNil(fallbackPrompts[0])
        let recoveredContext = try XCTUnwrap(fallbackPrompts[1])
        XCTAssertTrue(recoveredContext.contains("User:\nturn 1"))
        XCTAssertTrue(recoveredContext.contains("Assistant:\ndone"))
        XCTAssertTrue(recoveredContext.contains("<current_turn>\nturn 2"), recoveredContext)
        try await authority.quiesce()
        try await store.close()
    }

    func testProviderEventsAndInteractionDeliveryUseDurableAuthority() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/authority-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runtime = InteractiveEventProviderRuntime()
        let provider = ProviderCLIAdapter(runtimes: [runtime])
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-events", requestDigest: "p-events")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "run"), externalActor: actor, idempotencyKey: "s-events", requestDigest: "s-events")
        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "run-events", requestDigest: "run-events")

        var interaction: InteractionSnapshot?
        for _ in 0 ..< 100 {
            interaction = try await authority.interactionSnapshots(sessionID: session.sessionID).first
            if interaction != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = try XCTUnwrap(interaction)
        let answer = try JSONSerialization.data(withJSONObject: ["decision": "accept"])
        _ = try await authority.answerInteraction(sessionID: session.sessionID, interactionID: pending.interactionID, expectedRevision: pending.revision, payload: answer, actor: actor, idempotencyKey: "answer-events", requestDigest: "answer-events")
        let interactionSnapshots = try await authority.interactionSnapshots(sessionID: session.sessionID)
        let settledInteraction = try XCTUnwrap(interactionSnapshots.first)
        let settledPayload = try JSONDecoder.serviceDecoder.decode(ProviderInteractionPayload.self, from: settledInteraction.payload)
        XCTAssertEqual(settledInteraction.state, .resolved)
        XCTAssertEqual(settledPayload.prompt, "Approve tool")
        XCTAssertEqual(settledPayload.choices, ["accept", "decline"])
        XCTAssertEqual(settledPayload.resolution, "accept")
        let resumedPresentation = try await store.runPresentation(sessionID: session.sessionID)
        XCTAssertEqual(resumedPresentation?.phase, .working)
        XCTAssertEqual(resumedPresentation?.runningStatusCode, "interaction_resolved")
        await runtime.allowCompletion()

        var completed = try await authority.sessionSnapshot(sessionID: session.sessionID)
        for _ in 0 ..< 100 where completed.state != .completed {
            try await Task.sleep(for: .milliseconds(10))
            completed = try await authority.sessionSnapshot(sessionID: session.sessionID)
        }
        XCTAssertEqual(completed.state, .completed)
        XCTAssertTrue(completed.transcript.contains { $0.kind == .reasoning && $0.content == "thinking" })
        XCTAssertTrue(completed.transcript.contains { $0.kind == .assistant && $0.content == "finished" })
        let events = try await authority.events(after: nil, limit: 100)
        XCTAssertTrue(events.events.contains { $0.eventType == .toolStarted })
        XCTAssertTrue(events.events.contains { $0.eventType == .toolUpdated })
        XCTAssertTrue(events.events.contains { $0.eventType == .toolCompleted })
        XCTAssertTrue(events.events.contains { $0.eventType == .interactionRequested })
        XCTAssertTrue(events.events.contains { $0.eventType == .interactionResolved })
        let deliveredRequestID = await runtime.deliveredRequestID()
        XCTAssertEqual(deliveredRequestID, "approval-1")
        await authority.waitForProviderRunsToSettle()
        try await authority.quiesce()
        try await store.close()
    }

    func testProjectRoutingAndSessionPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project-key", requestDigest: "project-digest")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .collaborative, initialPrompt: "hello"), externalActor: actor, idempotencyKey: "session-key", requestDigest: "session-digest")
        XCTAssertEqual(session.projectID, project.projectID)
        XCTAssertEqual(session.transcript.first?.content, "hello")
        let restored = try await authority.sessionSnapshot(sessionID: session.sessionID)
        let events = try await authority.events(after: nil, limit: 10)
        XCTAssertEqual(restored.rootSessionID, session.sessionID)
        XCTAssertEqual(events.events.map(\.eventType), [.projectCreated, .sessionCreated, .agentStarted])
        try await store.close()
    }

    func testProjectUpdateAndRemovalUseExpectedRevisionAndArchiveAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "Old", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-mutate", requestDigest: "p-mutate")
        let updated = try await authority.updateProject(projectID: project.projectID, input: .init(expectedRevision: project.revision, name: "New", roots: [.init(logicalName: "renamed", path: root.path, writable: false)]), actor: actor, idempotencyKey: "p-update", requestDigest: "p-update")
        XCTAssertEqual(updated.name, "New")
        XCTAssertEqual(updated.roots.first?.rootID, project.roots.first?.rootID)
        XCTAssertEqual(updated.roots.first?.writable, false)

        try await authority.removeProject(projectID: project.projectID, expectedRevision: updated.revision, actor: actor, idempotencyKey: "p-remove", requestDigest: "p-remove")
        let activeProjects = await authority.projectSnapshots()
        let archived = try await store.project(id: project.projectID)
        let events = try await store.events(after: nil, limit: 10)
        XCTAssertTrue(activeProjects.isEmpty)
        XCTAssertEqual(archived?.state, .archived)
        XCTAssertEqual(events.events.map(\.eventType), [.projectCreated, .projectUpdated, .projectRemoved])
        try await store.close()
    }

    func testIdempotencyReturnsOriginalSnapshotsAndCommandReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let projectInput = CreateProjectInput(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)])
        let project = try await authority.createProject(input: projectInput, externalActor: actor, idempotencyKey: "project-key", requestDigest: "project-digest")
        let repeatedProject = try await authority.createProject(input: projectInput, externalActor: actor, idempotencyKey: "project-key", requestDigest: "project-digest")
        XCTAssertEqual(project, repeatedProject)

        let sessionInput = CreateSessionInput(projectID: project.projectID, provider: .codex, visibility: .collaborative)
        let session = try await authority.createSession(input: sessionInput, externalActor: actor, idempotencyKey: "session-key", requestDigest: "session-digest")
        let repeatedSession = try await authority.createSession(input: sessionInput, externalActor: actor, idempotencyKey: "session-key", requestDigest: "session-digest")
        XCTAssertEqual(session, repeatedSession)

        let command = SessionCommand.sendFollowup(text: "next", expectedSessionRevision: session.revision)
        let receipt = try await authority.execute(command: command, sessionID: session.sessionID, externalActor: actor, idempotencyKey: "command-key", requestDigest: "command-digest")
        let repeatedReceipt = try await authority.execute(command: command, sessionID: session.sessionID, externalActor: actor, idempotencyKey: "command-key", requestDigest: "command-digest")
        XCTAssertEqual(receipt, repeatedReceipt)

        let events = try await authority.events(after: nil, limit: 10)
        XCTAssertEqual(events.events.map(\.eventType), [.projectCreated, .sessionCreated, .agentStarted, .transcriptMessage])
        try await store.close()
    }

    func testRootCancellationDoesNotCancelDescendantsOrFenceNewChildren() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath()
            .appendingPathComponent(".test-root-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runtime = SteeringProviderRuntime()
        await runtime.holdNextRun()
        let provider = ProviderCLIAdapter(runtimes: [runtime])
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-tree-cancel", requestDigest: "p-tree-cancel")
        let rootSession = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "root"), externalActor: actor, idempotencyKey: "s-tree-cancel", requestDigest: "s-tree-cancel")
        let child = try await authority.spawnChildSession(parentSessionID: rootSession.sessionID, initialPrompt: "child", role: "explore", label: "probe")

        let hierarchy = try await authority.agentSnapshots(rootSessionID: rootSession.sessionID)
        XCTAssertEqual(hierarchy.count, 2)
        XCTAssertEqual(hierarchy.first(where: { $0.sessionID == child.sessionID })?.parentAgentID, rootSession.sessionID)
        XCTAssertEqual(hierarchy.first(where: { $0.sessionID == child.sessionID })?.role, "explore")
        XCTAssertEqual(hierarchy.first(where: { $0.sessionID == child.sessionID })?.label, "probe")

        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: rootSession.sessionID, externalActor: actor, idempotencyKey: "resume-tree", requestDigest: "resume-tree")
        _ = try await authority.execute(command: .cancelSession(expectedRunID: nil, expectedGeneration: 1), sessionID: rootSession.sessionID, externalActor: actor, idempotencyKey: "cancel-tree", requestDigest: "cancel-tree")
        let survivingChild = try await authority.sessionSnapshot(sessionID: child.sessionID)
        let canceledRoot = try await authority.sessionSnapshot(sessionID: rootSession.sessionID)
        let agents = try await authority.agentSnapshots(rootSessionID: rootSession.sessionID)
        XCTAssertEqual(canceledRoot.state, .canceled)
        XCTAssertEqual(survivingChild.state, .idle)
        XCTAssertEqual(agents.first(where: { $0.sessionID == child.sessionID })?.state, .idle)

        let late = try await authority.spawnChildSession(parentSessionID: rootSession.sessionID, initialPrompt: "late")
        XCTAssertEqual(late.parentSessionID, rootSession.sessionID)
        XCTAssertEqual(late.state, .idle)
        try await authority.quiesce()
        try await store.close()
    }

    func testChildCancellationDoesNotCancelParentOrSiblings() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath()
            .appendingPathComponent(".test-child-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runtime = SteeringProviderRuntime()
        await runtime.holdNextRun()
        let provider = ProviderCLIAdapter(runtimes: [runtime])
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-child-cancel", requestDigest: "p-child-cancel")
        let rootSession = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "root"), externalActor: actor, idempotencyKey: "s-child-cancel", requestDigest: "s-child-cancel")
        let childA = try await authority.spawnChildSession(parentSessionID: rootSession.sessionID, initialPrompt: "child-a", role: "explore", label: "probe-a")
        let childB = try await authority.spawnChildSession(parentSessionID: rootSession.sessionID, initialPrompt: "child-b", role: "explore", label: "probe-b")

        _ = try await authority.startChildAgentRun(sessionID: childA.sessionID)
        try await Task.sleep(for: .milliseconds(50))
        _ = try await authority.cancelChildAgentRun(sessionID: childA.sessionID)

        let canceledChild = try await authority.sessionSnapshot(sessionID: childA.sessionID)
        let survivingSibling = try await authority.sessionSnapshot(sessionID: childB.sessionID)
        let survivingParent = try await authority.sessionSnapshot(sessionID: rootSession.sessionID)
        XCTAssertEqual(canceledChild.state, .canceled)
        XCTAssertEqual(survivingSibling.state, .idle)
        XCTAssertEqual(survivingParent.state, .idle)

        let late = try await authority.spawnChildSession(parentSessionID: rootSession.sessionID, initialPrompt: "child-c")
        XCTAssertEqual(late.parentSessionID, rootSession.sessionID)
        XCTAssertEqual(late.state, .idle)
        try await authority.quiesce()
        try await store.close()
    }

    func testQuiesceInterruptsActiveProviderTreeBeforeCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = DelayedProviderRunner()
        await runner.setDelay(.seconds(10))
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-drain", requestDigest: "p-drain")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "run"), externalActor: actor, idempotencyKey: "s-drain", requestDigest: "s-drain")
        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "resume-drain", requestDigest: "resume-drain")

        try await authority.quiesce()

        let ready = await authority.isReady()
        let interrupted = try await authority.sessionSnapshot(sessionID: session.sessionID)
        let interruptedAgent = try await authority.agentSnapshots(rootSessionID: session.sessionID).first
        XCTAssertFalse(ready)
        XCTAssertEqual(interrupted.state, .interrupted)
        XCTAssertEqual(interruptedAgent?.state, .interrupted)
        try await store.close()
    }

    func testIdempotencyKeyDigestConflictFailsClosed() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: cursor)
        let key = IdempotencyInput(actorID: actor.userID, operation: "createProject", key: "same-key", requestDigest: "digest-a")
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: key)

        do {
            _ = try await store.idempotencyResult(.init(actorID: actor.userID, operation: "createProject", key: "same-key", requestDigest: "digest-b"))
            XCTFail("expected conflict")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .idempotencyConflict)
        }
        try await store.close()
    }

    func testSubscriptionHandsOffFromDurableReplayToLiveEvents() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project-key", requestDigest: "project-digest")
        let stream = try await authority.subscribe(after: nil)
        _ = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "session-key", requestDigest: "session-digest")

        var iterator = stream.makeAsyncIterator()
        let replayed = try await iterator.next()
        let live = try await iterator.next()
        XCTAssertEqual(replayed?.eventType, .projectCreated)
        XCTAssertEqual(live?.eventType, .sessionCreated)
        XCTAssertEqual(live?.globalSequence, replayed.map { $0.globalSequence + 1 })
        try await store.close()
    }

    func testUnknownProjectFailsClosed() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        do { _ = try await authority.projectSnapshot(projectID: UUID())
            XCTFail("expected not found")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .notFound) }
        try await store.close()
    }

    func testVisibilityArchiveAndExactWorktreeRebindMutateDurableAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-transitions", requestDigest: "p-transitions")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-transitions", requestDigest: "s-transitions")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let binding = WorktreeBindingSnapshot(bindingID: UUID(), projectID: project.projectID, rootID: rootID, sessionID: nil, baseRef: "main", branch: "existing", physicalPath: root.path, ownershipState: .active, mergeState: .clean, revision: 1)
        _ = try await store.persistWorktree(binding, actor: actor, correlationID: UUID())

        let rebound = try await authority.bindWorktree(sessionID: session.sessionID, bindingID: binding.bindingID, expectedRevision: 1, expectedSelectionBindingRevision: 1, actor: actor, idempotencyKey: "bind", requestDigest: "bind")
        XCTAssertEqual(rebound.sessionID, session.sessionID)
        XCTAssertEqual(rebound.revision, 2)
        let reboundSelection = try await authority.selectionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(reboundSelection.bindingRevision, 2)

        _ = try await authority.execute(command: .setSessionVisibility(expectedPolicyRevision: 1, visibility: .collaborative, collaborativeSteeringEnabled: false, controllerUserID: actor.userID), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "visibility", requestDigest: "visibility")
        let visible = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(visible.visibility, .collaborative)
        _ = try await authority.execute(command: .archiveSession(expectedRevision: visible.revision), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "archive", requestDigest: "archive")
        let archived = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(archived.state, .archived)
        try await store.close()
    }

    func testInteractionResolutionRequiresExactProviderAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let delivery = RecordingInteractionDelivery()
        let authority = RepoPromptHeadlessAuthority(store: store, interactionDelivery: delivery)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-interaction", requestDigest: "p-interaction")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-interaction", requestDigest: "s-interaction")
        let requested = try await authority.requestInteraction(sessionID: session.sessionID, kind: .approval, payload: Data("approve?".utf8))
        let resolved = try await authority.answerInteraction(sessionID: session.sessionID, interactionID: requested.interactionID, expectedRevision: requested.revision, payload: Data("approveOnce".utf8), actor: actor, idempotencyKey: "answer", requestDigest: "answer")
        XCTAssertEqual(resolved.state, .resolved)
        XCTAssertEqual(resolved.revision, 3)
        let deliveryCount = await delivery.deliveryCount()
        let stored = try await authority.interactionSnapshots(sessionID: session.sessionID)
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertEqual(stored.first?.state, .resolved)
        try await store.close()
    }

    func testEmbeddedMacOSAndDirectHeadlessUseOneDurableSessionAuthority() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath()
            .appendingPathComponent(".test-authority-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("authority.sqlite")

        let store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let runtime = TerminalFencingProviderRuntime()
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            providerAdapter: ProviderCLIAdapter(runtimes: [runtime])
        )
        let actor = ExternalActor(userID: "macos", username: "macos", displayName: "macOS")
        let projectID = UUID()
        let rootID = UUID()
        let sessionID = UUID()
        let worktree = WorktreeBindingSnapshot(
            bindingID: UUID(),
            projectID: projectID,
            rootID: rootID,
            sessionID: sessionID,
            baseRef: "main",
            branch: "authority-parity",
            physicalPath: root.path,
            ownershipState: .active,
            mergeState: .clean,
            revision: 1
        )
        let initialEntry = TranscriptEntry(
            entryID: UUID(),
            sessionSequence: 1,
            kind: .human,
            content: "legacy migration",
            actor: actor,
            timestamp: Date(timeIntervalSince1970: 1),
            presentationPayload: Data("macos-user-row".utf8)
        )
        let admitted = try await authority.ensureEmbeddedSession(EmbeddedSessionSeed(
            projectID: projectID,
            projectName: "macOS Project",
            roots: [.init(rootID: rootID, logicalName: "source", canonicalPath: root.path, writable: true)],
            sessionID: sessionID,
            rootSessionID: sessionID,
            creator: actor,
            provider: .codex,
            transcript: [initialEntry],
            permissionMode: "workspaceWrite",
            providerSettings: ["macos.profile": "userConfigured"],
            worktrees: [worktree]
        ))
        XCTAssertEqual(admitted.session.transcript, [initialEntry])
        XCTAssertEqual(admitted.worktrees, [worktree])

        // Re-admission is observation-only. Rich UI state cannot replace canonical
        // transcript, permissions, or worktrees after the one migration import.
        let reAdmitted = try await authority.ensureEmbeddedSession(EmbeddedSessionSeed(
            projectID: projectID,
            projectName: "ignored",
            roots: [],
            sessionID: sessionID,
            rootSessionID: sessionID,
            creator: actor,
            provider: .codex,
            transcript: [],
            permissionMode: "disabled",
            providerSettings: [:],
            worktrees: []
        ))
        XCTAssertEqual(reAdmitted.session.transcript, [initialEntry])
        XCTAssertEqual(reAdmitted.permissions, admitted.permissions)
        XCTAssertEqual(reAdmitted.worktrees, [worktree])

        let running = try await authority.startEmbeddedProviderRun(
            sessionID: sessionID,
            actor: actor,
            userMessage: "implement",
            providerPrompt: "provider prompt",
            presentationPayload: Data("rich-human-row".utf8),
            idempotencyKey: "macos-provider-run",
            requestDigest: "macos-provider-run"
        )
        let binding = try XCTUnwrap(running.activeBinding)
        XCTAssertEqual(binding.runID, running.activeRun?.runID)
        XCTAssertEqual(binding.generation, running.session.runGeneration)
        XCTAssertEqual(binding.turnEpoch, running.session.turnEpoch)

        await authority.waitForProviderRunsToSettle()
        try await Task.sleep(for: .milliseconds(50))
        let settled = try await authority.authoritySessionSnapshot(sessionID: sessionID)
        XCTAssertEqual(settled.session.state, .completed)
        XCTAssertNil(settled.activeBinding)
        XCTAssertEqual(settled.activeRun?.runID, binding.runID)
        XCTAssertEqual(settled.session.transcript.map(\.content), ["legacy migration", "implement", "authoritative answer"])
        XCTAssertFalse(settled.session.transcript.contains(where: { $0.content == "late provider frame" }))
        XCTAssertEqual(settled.permissions, admitted.permissions)
        XCTAssertEqual(settled.worktrees, [worktree])

        let pendingInteraction = try await authority.requestInteraction(
            sessionID: sessionID,
            kind: .question,
            payload: try JSONSerialization.data(withJSONObject: [
                "prompt": "Authority question",
                "choices": ["yes", "no"]
            ])
        )
        let projected = try await authority.authoritySessionSnapshot(sessionID: sessionID)
        XCTAssertEqual(projected.interactions, [pendingInteraction])
        XCTAssertEqual(projected.session.interactions, [pendingInteraction])

        // Direct MCP observes the identical durable session rather than another
        // controller/transcript runtime.
        let directMCP = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let historyData = try await directMCP.invoke(
            toolName: "history",
            argumentsJSON: try JSONSerialization.data(withJSONObject: [
                "op": "get_session",
                "session_id": sessionID.uuidString
            ]),
            binding: .init(sessionID: sessionID, actor: actor)
        )
        let directHistory = try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: historyData)
        XCTAssertEqual(directHistory, projected.session)

        try await authority.quiesce()
        try await store.close(clean: true)

        let reopenedStore = try await SQLiteServiceStore.open(storage: .file(database.path))
        let restoredAuthority = RepoPromptHeadlessAuthority(store: reopenedStore)
        try await restoredAuthority.recover()
        let restored = try await restoredAuthority.authoritySessionSnapshot(sessionID: sessionID)
        XCTAssertEqual(restored.session, projected.session)
        XCTAssertEqual(restored.activeRun, projected.activeRun)
        XCTAssertEqual(restored.permissions, projected.permissions)
        XCTAssertEqual(restored.interactions, projected.interactions)
        XCTAssertEqual(restored.worktrees, projected.worktrees)
        try await restoredAuthority.quiesce()
        try await reopenedStore.close(clean: true)
    }

    func testEmbeddedProviderFailureCannotDivergeFromDirectMCPOrRestart() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("failure-authority.sqlite")
        let store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            providerAdapter: ProviderCLIAdapter(runtimes: [FailingProviderRuntime()])
        )
        let actor = ExternalActor(userID: "macos", username: "macos", displayName: "macOS")
        let projectID = UUID()
        let rootID = UUID()
        let sessionID = UUID()
        _ = try await authority.ensureEmbeddedSession(EmbeddedSessionSeed(
            projectID: projectID,
            projectName: "Failure Project",
            roots: [.init(rootID: rootID, logicalName: "source", canonicalPath: root.path, writable: true)],
            sessionID: sessionID,
            rootSessionID: sessionID,
            creator: actor,
            provider: .codex
        ))
        let running = try await authority.startEmbeddedProviderRun(
            sessionID: sessionID,
            actor: actor,
            userMessage: "fail",
            providerPrompt: "fail",
            idempotencyKey: "failure-run",
            requestDigest: "failure-run"
        )
        let runID = try XCTUnwrap(running.activeBinding?.runID)
        await authority.waitForProviderRunsToSettle()
        let failed = try await authority.authoritySessionSnapshot(sessionID: sessionID)
        XCTAssertEqual(failed.session.state, .failed)
        XCTAssertNil(failed.activeBinding)
        XCTAssertEqual(failed.activeRun?.runID, runID)
        XCTAssertEqual(failed.activeRun?.state, "failed")
        XCTAssertTrue(failed.session.transcript.contains { $0.content == "partial authority output" })

        let direct = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let historyData = try await direct.invoke(
            toolName: "history",
            argumentsJSON: try JSONSerialization.data(withJSONObject: [
                "op": "get_session",
                "session_id": sessionID.uuidString
            ]),
            binding: .init(sessionID: sessionID, actor: actor)
        )
        XCTAssertEqual(
            try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: historyData),
            failed.session
        )

        try await authority.quiesce()
        try await store.close(clean: true)
        let reopenedStore = try await SQLiteServiceStore.open(storage: .file(database.path))
        let restoredAuthority = RepoPromptHeadlessAuthority(store: reopenedStore)
        try await restoredAuthority.recover()
        let restored = try await restoredAuthority.authoritySessionSnapshot(sessionID: sessionID)
        XCTAssertEqual(restored.session, failed.session)
        XCTAssertEqual(restored.activeRun, failed.activeRun)
        XCTAssertNil(restored.activeBinding)
        try await restoredAuthority.quiesce()
        try await reopenedStore.close(clean: true)
    }
}

private actor TerminalFencingProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.codex

    func capability() -> ProviderCapability {
        .init(kind: kind, enabled: true, executable: "/test/codex", supportsResume: true, supportsSteering: true)
    }

    func preflight() -> ProviderCapability { capability() }

    func execute(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        await onEvent(.providerIdentity("authority-thread"))
        await onEvent(.assistantFinal("authoritative answer"))
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            await onEvent(.assistantFinal("late provider frame"))
        }
        return .init(output: "authoritative answer", providerSessionID: "authority-thread")
    }

    func interrupt(runID _: UUID) {}
}

private actor FailingProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.codex

    func capability() -> ProviderCapability {
        .init(kind: kind, enabled: true, executable: "/test/codex", supportsResume: true, supportsSteering: true)
    }

    func preflight() -> ProviderCapability { capability() }

    func execute(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        await onEvent(.providerIdentity("failure-thread"))
        await onEvent(.assistantDelta("partial authority output"))
        throw ServiceAPIError(code: .dependencyUnavailable, message: "provider failed after partial output")
    }

    func steer(runID _: UUID, text _: String, targetTurnEpoch _: Int64) async throws {}
    func interrupt(runID _: UUID) async throws {}
    func deliverInteraction(runID _: UUID, providerRequestID _: String, answer _: Data) async throws {}
    func hasActiveRun(_ runID: UUID) -> Bool { false }
    func recoverProcessFamilies() async throws {}
    func shutdownProcessFamilies() async {}
}

private actor DelayedProviderRunner: WorkspaceCommandRunning {
    private var delay: Duration = .milliseconds(50)

    func setDelay(_ value: Duration) {
        delay = value
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        try await Task.sleep(for: delay)
        return "provider:\(arguments.last ?? "")"
    }
}

private actor SteeringProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.codex
    private var active: Set<UUID> = []
    private var steeredText: [UUID: String] = [:]
    private var hold = false

    func capability() -> ProviderCapability {
        .init(kind: kind, enabled: true, executable: "/test/codex", supportsResume: true, supportsSteering: true, protocolVersion: "app-server-v2")
    }

    func preflight() -> ProviderCapability {
        capability()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        active.contains(runID)
    }

    func holdNextRun() {
        hold = true
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        active.insert(request.runID)
        defer { active.remove(request.runID)
            steeredText[request.runID] = nil
        }
        await onEvent(.providerIdentity("thread-\(request.runID.uuidString)"))
        while steeredText[request.runID] == nil, !hold {
            try await Task.sleep(for: .milliseconds(5))
        }
        if hold {
            while active.contains(request.runID) {
                try await Task.sleep(for: .seconds(1))
            }
            throw CancellationError()
        }
        let text = steeredText[request.runID] ?? request.prompt
        let output = "provider:\(text)"
        await onEvent(.assistantFinal(output))
        await onEvent(.completed(providerSessionID: "thread-\(request.runID.uuidString)"))
        return .init(output: output, providerSessionID: "thread-\(request.runID.uuidString)")
    }

    func steer(runID: UUID, text: String, targetTurnEpoch _: Int64) throws {
        guard active.contains(runID) else { throw ServiceAPIError(code: .notFound, message: "run missing") }
        steeredText[runID] = text
    }

    func interrupt(runID: UUID) {
        active.remove(runID)
    }
}

private actor InteractiveEventProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.codex
    private var activeRunID: UUID?
    private var deliveredID: String?
    private var answered = false
    private var canFinish = false

    func capability() -> ProviderCapability {
        .init(kind: kind, enabled: true, executable: "/test/codex", supportsResume: true, supportsSteering: true, protocolVersion: "app-server-v2")
    }

    func preflight() -> ProviderCapability {
        capability()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        activeRunID == runID
    }

    func deliveredRequestID() -> String? {
        deliveredID
    }

    func allowCompletion() {
        canFinish = true
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        activeRunID = request.runID
        defer { activeRunID = nil }
        await onEvent(.providerIdentity("event-thread"))
        await onEvent(.reasoning("thinking"))
        await onEvent(.progress("working"))
        await onEvent(.toolStarted(providerToolID: "tool-1", name: "read_file", arguments: Data("{}".utf8)))
        await onEvent(.toolUpdated(providerToolID: "tool-1", output: "partial"))
        await onEvent(.toolCompleted(providerToolID: "tool-1", name: "read_file", output: "done", status: .success))
        await onEvent(.interactionRequested(providerRequestID: "approval-1", kind: .approval, prompt: "Approve tool", choices: ["accept", "decline"]))
        while !answered {
            try await Task.sleep(for: .milliseconds(5))
        }
        while !canFinish {
            try await Task.sleep(for: .milliseconds(5))
        }
        await onEvent(.assistantFinal("finished"))
        await onEvent(.completed(providerSessionID: "event-thread"))
        return .init(output: "finished", providerSessionID: "event-thread")
    }

    func steer(runID _: UUID, text _: String, targetTurnEpoch _: Int64) {}
    func interrupt(runID _: UUID) {
        answered = true
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer _: Data) throws {
        guard activeRunID == runID else { throw ServiceAPIError(code: .notFound, message: "run missing") }
        deliveredID = providerRequestID
        answered = true
    }
}

private actor PolicyRecordingProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.codex
    private var policy: ProviderExecutionPolicy?

    func capability() -> ProviderCapability {
        .init(kind: kind, enabled: true, executable: "/test/codex", supportsResume: true, supportsSteering: true)
    }

    func preflight() -> ProviderCapability {
        capability()
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        policy = request.policy
        await onEvent(.providerIdentity("policy-thread"))
        await onEvent(.assistantFinal("done"))
        await onEvent(.completed(providerSessionID: "policy-thread"))
        return .init(output: "done", providerSessionID: "policy-thread")
    }

    func interrupt(runID _: UUID) {}

    func lastPolicy() -> ProviderExecutionPolicy? {
        policy
    }
}

private actor ResumeRecordingProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.codex
    private var recordedResumeIdentities: [String?] = []
    private var recordedFallbackPrompts: [String?] = []

    func capability() -> ProviderCapability {
        .init(kind: kind, enabled: true, executable: "/test/codex", supportsResume: true, supportsSteering: false)
    }

    func preflight() -> ProviderCapability { capability() }

    func execute(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        recordedResumeIdentities.append(request.resumeProviderSessionID)
        recordedFallbackPrompts.append(request.resumeFallbackPrompt)
        await onEvent(.providerIdentity("durable-thread"))
        await onEvent(.assistantFinal("done"))
        await onEvent(.completed(providerSessionID: "durable-thread"))
        return .init(output: "done", providerSessionID: "durable-thread")
    }

    func interrupt(runID _: UUID) {}

    func resumeIdentities() -> [String?] {
        recordedResumeIdentities
    }

    func fallbackPrompts() -> [String?] {
        recordedFallbackPrompts
    }
}

private actor RecordingInteractionDelivery: InteractionDeliveryPort {
    private var count = 0

    func deliverAnswer(session _: SessionSnapshot, interaction _: InteractionSnapshot, answer _: Data) async throws {
        count += 1
    }

    func deliveryCount() -> Int {
        count
    }
}

private func signedDecision(
    actor: ExternalActor,
    sessionID: UUID,
    projectID: UUID,
    operation: String,
    requestDigest: String,
    metadata: CollaborationMetadataSnapshot,
    policyRevision: Int64? = nil,
    controllerRevision: Int64? = nil,
    membershipRevision: Int64? = nil
) -> AuthorizationDecision {
    AuthorizationDecision(
        decisionID: UUID(),
        actor: actor,
        sessionID: sessionID,
        projectID: projectID,
        operation: operation,
        requestDigest: requestDigest,
        policyRevision: policyRevision ?? metadata.policyRevision,
        controllerRevision: controllerRevision ?? metadata.controllerRevision,
        membershipRevision: membershipRevision ?? metadata.membershipRevision,
        attributionLabels: .init(
            controllerUserID: metadata.controllerUserID,
            visibility: metadata.visibility
        ),
        issuedAt: Date().addingTimeInterval(-1),
        expiresAt: Date().addingTimeInterval(30),
        requestID: UUID(),
        correlationID: UUID(),
        keyID: "test-app",
        signature: "verified-upstream"
    )
}
