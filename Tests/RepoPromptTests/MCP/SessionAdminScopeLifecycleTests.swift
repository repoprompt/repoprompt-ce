import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// App-side delegation scopes: durable store, runtime, the `session_admin` scope lifecycle over MCP,
/// and the shared administration core's single authority check and batch cards.
@MainActor
final class SessionAdminScopeLifecycleTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-admin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Fixtures

    private func makeStore(mode: AgentSessionOversightPersistenceMode = .enabled) -> DelegationScopeStore {
        DelegationScopeStore(
            fileURL: temporaryDirectory.appendingPathComponent(DelegationScopeStore.filename),
            backupsDirectoryURL: temporaryDirectory.appendingPathComponent("Backups", isDirectory: true),
            mode: mode
        )
    }

    @MainActor
    private final class Fixture {
        let window = WindowState()
        let runtime: DelegationScopeRuntime
        let core: AgentSessionAdministrationCore
        let notificationBox = NotificationBox()
        let source = FakeProvenance()
        var endpoint: DomainAgentSessionLinkEndpointIdentity?
        var enabled = true

        init() {
            let box = notificationBox
            runtime = DelegationScopeRuntime(notifyCatalogChanged: { box.ids.append($0) })
            core = AgentSessionAdministrationCore(
                scopes: runtime,
                projector: SpawnProvenanceDelegationMembershipProjector(source: source)
            )
        }

        func makeEndpoint(session: UUID, tab: UUID = UUID(), workspace: UUID = UUID()) -> DomainAgentSessionLinkEndpointIdentity {
            DomainAgentSessionLinkEndpointIdentity(
                windowID: window.windowID, workspaceID: workspace, tabID: tab, sessionID: session,
                persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
            )
        }

        var service: SessionAdminMCPToolService {
            var service = SessionAdminMCPToolService(
                captureRequestMetadata: { .init(connectionID: UUID(), clientName: "session-admin-test", windowID: self.window.windowID) },
                requireTargetWindow: { self.window },
                resolveObserverEndpoint: { _, _ in self.endpoint },
                scopes: { self.runtime },
                administration: { self.core }
            )
            service.isToolEnabled = { self.enabled }
            return service
        }

        func call(_ args: [String: Value]) async throws -> [String: Value] {
            let value = try await service.execute(args: args)
            return try XCTUnwrap(value.objectValue)
        }
    }

    @MainActor
    private final class NotificationBox {
        var ids: [UUID] = []
    }

    @MainActor
    final class FakeProvenance: DelegationProvenanceSource {
        var sessions: [UUID: DelegationSessionProvenance] = [:]

        func add(
            _ id: UUID,
            parent: UUID?,
            workspace: UUID? = nil,
            live: Bool = true,
            state: DomainDelegationScopeTargetState = .idle
        ) {
            sessions[id] = DelegationSessionProvenance(
                sessionID: id, workspaceID: workspace, parentSessionID: parent,
                createdByOverseerSessionID: nil, isLive: live, runState: state
            )
        }

        func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
            sessions[sessionID]
        }

        func allKnownSessions() -> [DelegationSessionProvenance] {
            Array(sessions.values)
        }
    }

    @MainActor
    private final class RecordingHandler: AgentSessionAdministrationOperationHandler {
        let operations: Set<DomainAgentSessionTargetOperation>
        var batches: [AgentSessionAdministrationAuthorizedBatch] = []

        init(_ operations: Set<DomainAgentSessionTargetOperation>) {
            self.operations = operations
        }

        func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
            batches.append(batch)
            return .object(["result": .string("applied"), "count": .int(batch.leases.count)])
        }
    }

    private func grantTree(_ fixture: Fixture, grantee: UUID, threshold: Int = 25) throws -> DomainDelegationScopeRecord {
        let request = try fixture.runtime.requestScope(
            requesterSessionID: grantee, requesterTabID: UUID(), kind: .tree(rootSessionID: grantee),
            capabilities: DomainDelegationScopeCapability.fullPreset,
            guardrails: .init(bulkConfirmationThreshold: threshold), reason: nil, idempotencyKey: nil
        ).get()
        return try fixture.runtime.approve(requestID: request.id).get()
    }

    // MARK: - Store

    func testStoreRoundTripsActiveGrantsAndReloadsUnderAFreshRuntime() async throws {
        let store = makeStore()
        let runtime = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store)
        let overseer = UUID()
        let request = try runtime.requestScope(
            requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
            capabilities: [.observe, .organize], guardrails: .init(maxDepth: 2), reason: "tidy", idempotencyKey: nil
        ).get()
        let granted = try runtime.approve(requestID: request.id).get()
        await runtime.flushPersistence()

        let reloaded = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        await reloaded.bootstrap(store: makeStore())
        let live = reloaded.liveScopes(grantedTo: overseer)
        XCTAssertEqual(live.map(\.id), [granted.id])
        XCTAssertEqual(live.first?.grant, granted.grant)

        // Revocation removes the row durably.
        reloaded.revoke(scopeID: granted.id)
        await reloaded.flushPersistence()
        let again = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        await again.bootstrap(store: makeStore())
        XCTAssertFalse(again.hasLiveScope(grantedTo: overseer))
    }

    func testStorePreservesFutureSchemaQuarantinesMalformedAndSuppressesIO() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent(DelegationScopeStore.filename)
        try Data(#"{"version": 99, "scopes": []}"#.utf8).write(to: fileURL)
        let future = makeStore()
        let futureLoad = await future.loadForLaunch()
        XCTAssertEqual(futureLoad, .blocked(.unsupportedFutureSchema(onDiskVersion: 99, supportedVersion: 1)))
        let futureWrite = await future.replace(with: [])
        XCTAssertEqual(futureWrite, .blocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try Data("not json".utf8).write(to: fileURL)
        let malformed = makeStore()
        let malformedLoad = await malformed.loadForLaunch()
        XCTAssertEqual(malformedLoad, .ready(source: .quarantined, grants: [], revokedScopeIDs: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.appendingPathComponent("Backups").path)
        XCTAssertEqual(backups.count, 1)

        let suppressed = makeStore(mode: .suppressed)
        let suppressedLoad = await suppressed.loadForLaunch()
        XCTAssertEqual(suppressedLoad, .suppressed)
        let suppressedWrite = await suppressed.replace(with: [])
        XCTAssertEqual(suppressedWrite, .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - request_scope / scope_status / release_scope

    func testRequestScopeIsPendingUntilTheUserApprovesThenStatusAndReleaseFollow() async throws {
        let fixture = Fixture()
        let overseer = UUID()
        let tab = UUID()
        fixture.endpoint = fixture.makeEndpoint(session: overseer, tab: tab)

        let requested = try await fixture.call(["op": .string("request_scope"), "reason": .string("Clean up my lanes")])
        XCTAssertEqual(requested["result"], .string("pending_user_approval"))
        XCTAssertEqual(requested["kind"], .string("tree"))
        let requestID = try XCTUnwrap(requested["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        XCTAssertFalse(fixture.runtime.hasLiveScope(grantedTo: overseer), "nothing is granted before approval")
        XCTAssertEqual(
            fixture.runtime.pendingRequests(forTab: tab, sessionID: overseer).map(\.id), [requestID],
            "the card shows in the requester's tab while it is bound to the requesting session"
        )
        XCTAssertTrue(fixture.runtime.pendingRequests(forTab: tab, sessionID: UUID()).isEmpty)

        let pending = try await fixture.call(["op": .string("scope_status"), "request_id": .string(requestID.uuidString)])
        XCTAssertEqual(pending["result"], .string("pending_user_approval"))

        let record = try fixture.runtime.approve(requestID: requestID, capabilities: [.observe, .organize]).get()
        XCTAssertEqual(fixture.notificationBox.ids, [overseer], "the grantee's catalog is republished")
        let granted = try await fixture.call(["op": .string("scope_status"), "request_id": .string(requestID.uuidString)])
        XCTAssertEqual(granted["result"], .string("granted"))
        XCTAssertEqual(granted["scope"]?.objectValue?["capabilities"], .array([.string("observe"), .string("organize")]))

        let all = try await fixture.call(["op": .string("scope_status")])
        XCTAssertEqual(all["has_live_scope"], .bool(true))

        let released = try await fixture.call(["op": .string("release_scope")])
        XCTAssertEqual(released["result"], .string("released"))
        XCTAssertEqual(released["revoked_scope_ids"], .array([.string(record.id.uuidString)]))
        XCTAssertFalse(fixture.runtime.hasLiveScope(grantedTo: overseer))

        let afterRelease = try await fixture.call(["op": .string("scope_status"), "scope_id": .string(record.id.uuidString)])
        XCTAssertEqual(afterRelease["scope"]?.objectValue?["state"], .string("revoked"))
        let none = try await fixture.call(["op": .string("release_scope")])
        XCTAssertEqual(none["result"], .string("no_live_scope"))
    }

    func testRequestScopeIdempotencyReplaysAndConflicts() async throws {
        let fixture = Fixture()
        fixture.endpoint = fixture.makeEndpoint(session: UUID())
        let args: [String: Value] = [
            "op": .string("request_scope"), "idempotency_key": .string("k1"),
            "capabilities": .array([.string("observe")]),
            "guardrails": .object(["expires_in_seconds": .int(600)])
        ]
        let first = try await fixture.call(args)
        let replay = try await fixture.call(args)
        XCTAssertEqual(first["request_id"], replay["request_id"], "a relative lifetime makes the retry identical")
        XCTAssertEqual(first["guardrails"]?.objectValue?["expires_in_seconds"], .int(600))

        // The lifetime starts at approval.
        let requestID = try XCTUnwrap(first["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let beforeApproval = Date()
        let record = try fixture.runtime.approve(requestID: requestID).get()
        let expiresAt = try XCTUnwrap(record.grant.guardrails.expiresAt)
        XCTAssertGreaterThanOrEqual(expiresAt.timeIntervalSince(beforeApproval), 600)

        var changed = args
        changed["capabilities"] = .array([.string("organize")])
        let conflict = try await fixture.call(changed)
        XCTAssertEqual(conflict["result"], .string("idempotency_conflict"))
    }

    func testRequestScopeValidationIsReportedToTheRequester() async throws {
        let fixture = Fixture()
        fixture.endpoint = fixture.makeEndpoint(session: UUID())
        let restricted = try await fixture.call([
            "op": .string("request_scope"), "kind": .string("all_sessions"),
            "capabilities": .array([.string("observe"), .string("control")])
        ])
        XCTAssertEqual(restricted["result"], .string("invalid_request"))
        XCTAssertEqual(restricted["code"], .string("capability_not_permitted_for_kind"))

        let allSessions = try await fixture.call(["op": .string("request_scope"), "kind": .string("all_sessions")])
        XCTAssertEqual(allSessions["capabilities"], .array([.string("observe"), .string("organize"), .string("restructure")]))

        do {
            _ = try await fixture.call(["op": .string("request_scope"), "capabilities": .array([.string("delete_session")])])
            XCTFail("human-only actions are not capabilities")
        } catch {}
        do {
            _ = try await fixture.call(["op": .string("scope_status"), "targets": .array([])])
            XCTFail("lifecycle ops reject unknown keys")
        } catch {}
    }

    func testUnresolvedCallersAndOtherSessionsSeeOnlyTheUniformDenial() async throws {
        let fixture = Fixture()
        fixture.endpoint = nil
        await assertUnavailable { _ = try await fixture.call(["op": .string("request_scope")]) }

        var unbound = fixture.makeEndpoint(session: UUID())
        unbound = DomainAgentSessionLinkEndpointIdentity(
            windowID: unbound.windowID, workspaceID: unbound.workspaceID, tabID: unbound.tabID,
            sessionID: unbound.sessionID, persistentBindingGeneration: nil, bindingTransitionGeneration: 1
        )
        fixture.endpoint = unbound
        await assertUnavailable { _ = try await fixture.call(["op": .string("scope_status")]) }

        let owner = UUID()
        let record = try grantTree(fixture, grantee: owner)
        fixture.endpoint = fixture.makeEndpoint(session: UUID())
        await assertUnavailable {
            _ = try await fixture.call(["op": .string("scope_status"), "scope_id": .string(record.id.uuidString)])
        }
        await assertUnavailable {
            _ = try await fixture.call(["op": .string("release_scope"), "scope_id": .string(record.id.uuidString)])
        }
        XCTAssertTrue(fixture.runtime.hasLiveScope(grantedTo: owner), "a non-grantee cannot release")

        fixture.enabled = false
        do {
            _ = try await fixture.call(["op": .string("scope_status")])
            XCTFail("a disabled tool refuses every call")
        } catch {}
    }

    func testUnimplementedOperationsReportNotImplemented() async throws {
        let fixture = Fixture()
        let overseer = UUID()
        _ = try grantTree(fixture, grantee: overseer)
        fixture.endpoint = fixture.makeEndpoint(session: overseer)
        do {
            _ = try await fixture.call(["op": .string("rename"), "session_id": .string(UUID().uuidString)])
            XCTFail("rename has no handler in this lane")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not_implemented"), "\(error)")
        }
    }

    // MARK: - Administration core

    func testCoreRaisesOneCardHonoursUntickAndAppliesOnlyTheApprovedSubset() async throws {
        let fixture = Fixture()
        let overseer = UUID()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        fixture.source.add(overseer, parent: nil)
        for child in [a, b, c, d] {
            fixture.source.add(child, parent: overseer)
        }
        // Threshold 1, so the narrowed applying call (two items) still requires its card.
        let scope = try grantTree(fixture, grantee: overseer, threshold: 1)
        let handler = RecordingHandler([.adminSetPin])
        fixture.core.register(handler)
        let tab = UUID()
        func request(
            _ targets: [UUID],
            confirmation: UUID? = nil,
            key: String = "pin-1",
            arguments: [String: Value] = ["pinned": .bool(true)]
        ) -> AgentSessionAdministrationRequest {
            .init(
                operation: .adminSetPin, caller: .agentSession(overseer), callerTabID: tab,
                targetSessionIDs: targets, idempotencyKey: key, confirmationID: confirmation,
                arguments: arguments
            )
        }

        guard case let .pendingConfirmation(card, _) = try await fixture.core.perform(request([a, b, c])) else {
            return XCTFail("three items over a threshold of two must raise a card")
        }
        XCTAssertEqual(card.reason, .bulkThreshold)
        XCTAssertEqual(card.scopeID, scope.id)
        XCTAssertEqual(fixture.runtime.confirmations.pendingConfirmations(forTab: tab).map(\.id), [card.id])
        guard case let .pendingConfirmation(replayed, _) = try await fixture.core.perform(request([a, b, c])) else {
            return XCTFail("an identical retry returns the same card")
        }
        XCTAssertEqual(replayed.id, card.id)
        guard case .idempotencyConflict = try await fixture.core.perform(request([a, b, d])) else {
            return XCTFail("the key is bound to the exact item set")
        }
        guard case .idempotencyConflict = try await fixture.core.perform(request([a, b, c], arguments: ["pinned": .bool(false)])) else {
            return XCTFail("the key is bound to the exact arguments: never the earlier card")
        }

        fixture.runtime.confirmations.setItem(c, ticked: false, confirmationID: card.id)
        XCTAssertNotNil(fixture.runtime.confirmations.approve(confirmationID: card.id))
        guard case .denied(.confirmationMismatch, _) = try await fixture.core.perform(request([a, b, c], confirmation: card.id)) else {
            return XCTFail("an unticked item cannot be acted on")
        }
        guard case .denied(.confirmationMismatch, _) = try await fixture.core.perform(
            request([a, b], confirmation: card.id, arguments: ["pinned": .bool(false)])
        ) else {
            return XCTFail("changed arguments cannot ride an approval")
        }
        // The grantee gets a recoverable answer listing what was actually approved.
        let mismatch = try XCTUnwrap(SessionAdminMCPToolService.confirmationMismatchValue(
            fixture.runtime.confirmations.confirmation(id: card.id, granteeSessionID: overseer)
        ).objectValue)
        XCTAssertEqual(mismatch["code"], .string("confirmation_mismatch"))
        XCTAssertEqual(mismatch["approved_session_ids"], .array([.string(a.uuidString), .string(b.uuidString)]))
        XCTAssertEqual(
            fixture.runtime.confirmations.confirmation(id: card.id, granteeSessionID: overseer)?.state, .approved,
            "a refused call never consumes the approval"
        )
        guard case .completed = try await fixture.core.perform(request([a, b], confirmation: card.id)) else {
            return XCTFail("the approved subset applies")
        }
        XCTAssertEqual(handler.batches.single?.leases.map(\.targetSessionID), [a, b])
        XCTAssertEqual(handler.batches.single?.confirmation?.approvedSessionIDs, [a, b])

        // The approval was consumed: replaying the carded request cannot re-authorize it.
        guard case let .pendingConfirmation(spent, _) = try await fixture.core.perform(request([a, b, c], confirmation: card.id)) else {
            return XCTFail("a consumed card authorizes nothing")
        }
        XCTAssertEqual(spent.id, card.id)
        XCTAssertEqual(spent.state, .consumed)
        XCTAssertEqual(handler.batches.count, 1)
    }

    func testCoreDeniesNonMembersUniformlyAndRevocationInvalidatesCards() async throws {
        let fixture = Fixture()
        let overseer = UUID()
        let member = UUID()
        let outsider = UUID()
        fixture.source.add(overseer, parent: nil)
        fixture.source.add(member, parent: overseer)
        fixture.source.add(outsider, parent: UUID())
        let scope = try grantTree(fixture, grantee: overseer)
        let handler = RecordingHandler([.adminRetire, .adminRename])
        fixture.core.register(handler)

        guard case let .denied(denial, sessionID) = try await fixture.core.perform(.init(
            operation: .adminRename, caller: .agentSession(overseer), targetSessionIDs: [member, outsider]
        )) else { return XCTFail("a non-member is refused") }
        XCTAssertEqual(denial, .membershipProofMissing)
        XCTAssertEqual(sessionID, outsider)
        XCTAssertNil(denial.publicCode, "non-membership is never disclosed with a specific code")
        XCTAssertThrowsError(try SessionAdminMCPToolService.deniedValue(denial, sessionID: sessionID))

        guard case let .pendingConfirmation(card, _) = try await fixture.core.perform(.init(
            operation: .adminRetire, caller: .agentSession(overseer), targetSessionIDs: [member], idempotencyKey: "retire-1"
        )) else { return XCTFail("retire always raises a card") }
        XCTAssertEqual(card.reason, .destructive)
        fixture.runtime.revoke(scopeID: scope.id)
        XCTAssertEqual(fixture.runtime.confirmations.confirmation(id: card.id, granteeSessionID: overseer)?.state, .invalidated)

        guard case .denied(.unknownScope, _) = try await fixture.core.perform(.init(
            operation: .adminRename, caller: .agentSession(overseer), targetSessionIDs: [member]
        )) else { return XCTFail("no live scope remains") }
        XCTAssertTrue(handler.batches.isEmpty)
    }

    func testCoreRetireCardsIdleMembersAndReportsRunningOnesWithoutControl() async throws {
        let fixture = Fixture()
        let overseer = UUID()
        let idle = UUID()
        let running = UUID()
        fixture.source.add(overseer, parent: nil)
        fixture.source.add(idle, parent: overseer, state: .idle)
        fixture.source.add(running, parent: overseer, state: .running)
        let request = try fixture.runtime.requestScope(
            requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
            capabilities: [.organize, .restructure], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        _ = try fixture.runtime.approve(requestID: request.id).get()
        let handler = RecordingHandler([.adminRetire])
        fixture.core.register(handler)
        func retire(_ confirmation: UUID? = nil, targets: [UUID]) -> AgentSessionAdministrationRequest {
            .init(
                operation: .adminRetire, caller: .agentSession(overseer), targetSessionIDs: targets,
                idempotencyKey: "retire-mixed", confirmationID: confirmation
            )
        }

        guard case let .pendingConfirmation(card, requiresControl) = try await fixture.core.perform(retire(targets: [idle, running])) else {
            return XCTFail("the idle member is carded")
        }
        XCTAssertEqual(card.items.map(\.sessionID), [idle], "running members are never carded")
        XCTAssertEqual(requiresControl, [running])
        let rendered = try XCTUnwrap(SessionAdminMCPToolService.confirmationValue(card, itemsRequiringControl: requiresControl).objectValue)
        XCTAssertEqual(rendered["requires_control"], .array([.string(running.uuidString)]))

        XCTAssertNotNil(fixture.runtime.confirmations.approve(confirmationID: card.id))
        guard case .completed = try await fixture.core.perform(retire(card.id, targets: [idle, running])) else {
            return XCTFail("the approved idle member is retired")
        }
        let batch = try XCTUnwrap(handler.batches.single)
        XCTAssertEqual(batch.admittedSessionIDs, [idle])
        XCTAssertEqual(batch.itemsRequiringControl, [running], "the handler reports it and must not stop it")
    }

    func testCoreRefusesAdministrativeAndUnresolvedCallers() async throws {
        let fixture = Fixture()
        fixture.core.register(RecordingHandler([.adminRename]))
        for caller in [DomainAgentSessionCallerIdentity.administrativePrincipal, .unresolvedAgentRun] {
            guard case .denied(.callerNotAgentSession, _) = try await fixture.core.perform(.init(
                operation: .adminRename, caller: caller, targetSessionIDs: [UUID()]
            )) else { return XCTFail("\(caller) must never act through a scope") }
        }
    }

    // MARK: - Review fixes

    func testWorkspaceScopeIsLimitedToTheRequestersOwnWorkspace() async throws {
        let fixture = Fixture()
        let ownWorkspace = UUID()
        fixture.endpoint = fixture.makeEndpoint(session: UUID(), workspace: ownWorkspace)
        let foreign = try await fixture.call([
            "op": .string("request_scope"), "kind": .string("workspace"), "workspace": .string(UUID().uuidString)
        ])
        XCTAssertEqual(foreign["result"], .string("invalid_request"))
        XCTAssertEqual(foreign["code"], .string("workspace_not_own"))
        XCTAssertTrue(fixture.runtime.requests.isEmpty, "a refused request raises no card")

        let own = try await fixture.call([
            "op": .string("request_scope"), "kind": .string("workspace"), "workspace": .string(ownWorkspace.uuidString)
        ])
        XCTAssertEqual(own["result"], .string("pending_user_approval"))
        let request = try XCTUnwrap(fixture.runtime.requests.values.first)
        XCTAssertEqual(request.kind, .workspace(workspaceID: ownWorkspace))
    }

    func testGrantRevokeReleaseAndExpiryRepublishTheGranteeCatalog() throws {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let box = NotificationBox()
        let runtime = DelegationScopeRuntime(now: { clock }, notifyCatalogChanged: { box.ids.append($0) })
        let overseer = UUID()
        func grant(seconds: Int? = nil) throws -> DomainDelegationScopeRecord {
            let request = try runtime.requestScope(
                requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
                capabilities: [.observe], guardrails: .init(), expiresInSeconds: seconds, reason: nil, idempotencyKey: nil
            ).get()
            return try runtime.approve(requestID: request.id).get()
        }
        let first = try grant()
        XCTAssertEqual(box.ids, [overseer])
        runtime.revoke(scopeID: first.id)
        XCTAssertEqual(box.ids.count, 2, "revocation relists")
        let second = try grant()
        _ = runtime.release(scopeID: second.id, caller: .agentSession(overseer))
        XCTAssertEqual(box.ids.count, 4, "grant and release each relist")
        _ = try grant(seconds: 60)
        XCTAssertEqual(box.ids.count, 5)
        clock = clock.addingTimeInterval(61)
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: overseer))
        XCTAssertEqual(box.ids.count, 6, "expiry relists")
    }

    func testRevocationIsDurableThroughTombstonesAndTheTerminationFlush() async throws {
        let runtime = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: makeStore())
        let overseer = UUID()
        let request = try runtime.requestScope(
            requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
            capabilities: [.observe], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        let record = try runtime.approve(requestID: request.id).get()
        await runtime.flushPersistence()
        runtime.revoke(scopeID: record.id)
        // No await: the synchronous termination flush alone must make the revocation durable.
        runtime.flushForTermination()
        let reloaded = makeStore()
        guard case let .ready(_, grants, revoked) = await reloaded.loadForLaunch() else {
            return XCTFail("store must load")
        }
        XCTAssertTrue(grants.isEmpty)
        XCTAssertEqual(revoked, [record.id])

        // A stale file that still lists the grant next to its tombstone never brings it back.
        let fileURL = temporaryDirectory.appendingPathComponent(DelegationScopeStore.filename)
        let stale = DelegationScopeDocument(scopes: [record.grant], revokedScopeIDs: [record.id])
        try JSONEncoder().encode(stale).write(to: fileURL)
        let relaunched = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        await relaunched.bootstrap(store: makeStore())
        XCTAssertFalse(relaunched.hasLiveScope(grantedTo: overseer))
    }

    func testAgentProposedGuardrailsAreClampedAndApprovalCannotWidenTheRequest() throws {
        let runtime = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        let overseer = UUID()
        func request(threshold: Int, seconds: Int? = 600) throws -> DelegationScopeRequest {
            try runtime.requestScope(
                requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
                capabilities: [.observe, .organize], guardrails: .init(bulkConfirmationThreshold: threshold),
                expiresInSeconds: seconds, reason: nil, idempotencyKey: nil
            ).get()
        }
        XCTAssertEqual(try request(threshold: 100).guardrails.bulkConfirmationThreshold, 25, "an agent cannot loosen the card threshold")
        XCTAssertEqual(try request(threshold: 5).guardrails.bulkConfirmationThreshold, 5, "an agent may tighten it")
        XCTAssertEqual(
            runtime.requestScope(
                requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
                capabilities: [.observe], guardrails: .init(), expiresInSeconds: DelegationScopeRuntime.maximumExpirySeconds + 1,
                reason: nil, idempotencyKey: nil
            ).map(\.id),
            .failure(.invalid(.expiryInPast)),
            "agent-proposed lifetimes are capped"
        )

        let pending = try request(threshold: 10)
        XCTAssertEqual(
            runtime.approve(requestID: pending.id, capabilities: [.observe, .control]).map(\.id),
            .failure(.approvalExceedsRequest)
        )
        XCTAssertEqual(runtime.requests[pending.id]?.state, .pending, "a refused approval leaves the card open")

        // The user may loosen the threshold, but the requested lifetime survives a guardrail override.
        var loosened = pending.guardrails
        loosened.bulkConfirmationThreshold = 100
        let before = Date()
        let granted = try runtime.approve(requestID: pending.id, capabilities: [.observe], guardrails: loosened).get()
        XCTAssertEqual(granted.grant.guardrails.bulkConfirmationThreshold, 100)
        XCTAssertEqual(granted.grant.capabilities, [.observe])
        let expiresAt = try XCTUnwrap(granted.grant.guardrails.expiresAt)
        XCTAssertLessThanOrEqual(expiresAt.timeIntervalSince(before), 601)
    }

    func testGrantCardIsCancelledWhenTheTabSessionChanges() throws {
        let runtime = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        let overseer = UUID()
        let tab = UUID()
        let request = try runtime.requestScope(
            requesterSessionID: overseer, requesterTabID: tab, kind: .tree(rootSessionID: overseer),
            capabilities: [.observe], guardrails: .init(), reason: nil, idempotencyKey: nil, requesterTitle: "Overseer"
        ).get()
        XCTAssertEqual(request.requesterTitle, "Overseer")
        runtime.cancelStaleRequests(tabID: tab, currentSessionID: overseer)
        XCTAssertEqual(runtime.requests[request.id]?.state, .pending)
        runtime.cancelStaleRequests(tabID: tab, currentSessionID: UUID())
        XCTAssertEqual(runtime.requests[request.id]?.state.label, "cancelled")
        XCTAssertEqual(runtime.approve(requestID: request.id).map(\.id), .failure(.unknownScope))
    }

    func testScopeIsKeyedBySessionAcrossIncarnations() async throws {
        let fixture = Fixture()
        let overseer = UUID()
        _ = try grantTree(fixture, grantee: overseer)
        // The same session open in two windows/tabs: both incarnations hold the scope.
        for _ in 0 ..< 2 {
            fixture.endpoint = fixture.makeEndpoint(session: overseer)
            let status = try await fixture.call(["op": .string("scope_status")])
            XCTAssertEqual(status["has_live_scope"], .bool(true))
        }
        fixture.endpoint = fixture.makeEndpoint(session: UUID())
        let other = try await fixture.call(["op": .string("scope_status")])
        XCTAssertEqual(other["has_live_scope"], .bool(false))
    }

    func testScopeLevelOperationsRejectTargetSelectors() async throws {
        let fixture = Fixture()
        let overseer = UUID()
        _ = try grantTree(fixture, grantee: overseer)
        fixture.endpoint = fixture.makeEndpoint(session: overseer)
        for key in ["targets", "session_id"] {
            let value: Value = key == "targets" ? .array([.string(UUID().uuidString)]) : .string(UUID().uuidString)
            do {
                _ = try await fixture.call(["op": .string("inventory"), key: value])
                XCTFail("\(key) must be rejected on a scope-level op")
            } catch {
                XCTAssertTrue(String(describing: error).contains("names no target"), "\(error)")
            }
        }
    }

    // MARK: - App adapter schema

    /// The app catalog reprojects every canonical schema through `Tool(canonicalizing:)`, whose
    /// JSONSchema decoder accepts only a single-string `type`. A union such as `["string","null"]`
    /// fails the whole `session_admin` registration, so decode it through that production path.
    func testSessionAdminSchemaDecodesThroughAppAdapterCanonicalization() throws {
        let definition = MCPDomainSessionAdminToolDefinition.definition
        let adapted = try RepoPromptApp.Tool(domainBinding: MCPDomainToolBinding(definition: definition) { _ in .null })
        let canonical = try RepoPromptApp.Tool(canonicalizing: adapted)
        XCTAssertEqual(canonical.name, MCPWindowToolName.sessionAdmin)

        let schema = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(canonical.inputSchema))
        let properties = try XCTUnwrap(schema.objectValue?["properties"]?.objectValue)
        let expected = try XCTUnwrap(definition.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(Set(properties.keys), Set(expected.keys), "decoding must keep every property")
        XCTAssertEqual(properties["group"]?.objectValue?["type"], .string("string"))

        for candidate in MCPDomainCanonicalToolDefinitions.definitions {
            XCTAssertNoThrow(
                try RepoPromptApp.Tool(domainBinding: MCPDomainToolBinding(definition: candidate) { _ in .null }),
                candidate.name
            )
        }
    }

    // MARK: - Helpers

    private func assertUnavailable(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected the uniform unavailable denial", file: file, line: line)
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("session_admin is not available"),
                "\(error)", file: file, line: line
            )
        }
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}

// MARK: - Lane C: structure, lifecycle, worktree on behalf

/// Structural `session_admin` ops through the shared administration core with fake app hosts:
/// link ceiling and never-upgrade, re-parent/adopt placement (S9), attenuation, spawn admission and
/// guardrails, lifecycle (model/effort/fork), worktree on behalf (ownership, guardrail, deferred bind,
/// release card), lease re-checks after suspension, and placement persistence.
@MainActor
final class SessionAdminStructureTests: XCTestCase {
    fileprivate struct Pair: Hashable {
        let observer: UUID
        let target: UUID
    }

    @MainActor
    final class Provenance: DelegationProvenanceSource {
        var sessions: [UUID: DelegationSessionProvenance] = [:]

        func add(
            _ id: UUID,
            parent: UUID?,
            org: UUID? = nil,
            workspace: UUID? = nil,
            scope: UUID? = nil,
            laneCreator: UUID? = nil,
            live: Bool = true,
            state: DomainDelegationScopeTargetState = .idle,
            worktrees: Set<String> = []
        ) {
            sessions[id] = DelegationSessionProvenance(
                sessionID: id, workspaceID: workspace, parentSessionID: parent, createdByOverseerSessionID: laneCreator,
                organizationalParentID: org, delegationScopeID: scope, isLive: live, worktreeCount: worktrees.count,
                boundWorktreeIDs: worktrees, runState: state
            )
        }

        func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
            sessions[sessionID]
        }

        func allKnownSessions() -> [DelegationSessionProvenance] {
            Array(sessions.values)
        }
    }

    @MainActor
    final class StructureHost: SessionAdminStructureHost {
        let provenance: Provenance
        var placements: [(session: UUID, parent: UUID, scope: UUID?)] = []
        fileprivate var links: [Pair: Set<DomainAgentSessionLinkCapability>] = [:]
        fileprivate var added: [Pair] = []
        fileprivate var stopped: [Pair] = []
        var onActiveLink: (@MainActor () -> Void)?
        var modelCalls: [(UUID, String)] = []
        var effortCalls: [(UUID, String)] = []
        var lastAuthorization: (@MainActor () -> Bool)?
        var forkCalls: [UUID] = []
        var nextFork = UUID()
        /// Runs inside each placement's durable write, after the in-memory write (a slow disk rewrite).
        var onPersist: (@MainActor () async -> Void)?

        init(provenance: Provenance) {
            self.provenance = provenance
        }

        func commitOrganizationalPlacement(
            sessionID: UUID,
            parentID: UUID,
            delegationScopeID: UUID?
        ) throws -> DelegationPlacementCommit? {
            placements.append((sessionID, parentID, delegationScopeID))
            let old = provenance.sessions[sessionID]
            provenance.sessions[sessionID] = DelegationSessionProvenance(
                sessionID: sessionID, workspaceID: old?.workspaceID, parentSessionID: old?.parentSessionID,
                createdByOverseerSessionID: nil, organizationalParentID: parentID,
                delegationScopeID: delegationScopeID ?? old?.delegationScopeID, isLive: old?.isLive ?? true,
                boundWorktreeIDs: old?.boundWorktreeIDs ?? [], runState: old?.runState ?? .idle
            )
            let onPersist = onPersist
            return DelegationPlacementCommit(pendingWrite: Task { @MainActor in await onPersist?() })
        }

        func activeLinkCapabilities(observer: UUID, target: UUID) async -> Set<DomainAgentSessionLinkCapability>? {
            onActiveLink?()
            return links[Pair(observer: observer, target: target)]
        }

        var mintedLinkCapabilities: Set<DomainAgentSessionLinkCapability> {
            DomainAgentSessionLinkCapability.managed
        }

        func addLink(observer: UUID, target: UUID) async -> SessionAdminLinkOutcome {
            added.append(Pair(observer: observer, target: target))
            links[Pair(observer: observer, target: target)] = DomainAgentSessionLinkCapability.managed
            return .linked
        }

        func stopLink(
            observer: UUID,
            target: UUID,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async -> SessionAdminLinkOutcome {
            let pair = Pair(observer: observer, target: target)
            guard links[pair] != nil else { return .notLinked }
            onActiveLink?()
            guard isStillAuthorized() else { return .failed("authority ended") }
            links.removeValue(forKey: pair)
            stopped.append(pair)
            return .stopped
        }

        func setModel(
            sessionID: UUID,
            modelID: String,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async -> SessionAdminLifecycleOutcome {
            modelCalls.append((sessionID, modelID))
            lastAuthorization = isStillAuthorized
            return isStillAuthorized() ? .applied(changed: true, fields: ["model_id": modelID]) : .blocked("revoked")
        }

        func setEffort(
            sessionID: UUID,
            effort: String,
            isStillAuthorized _: @escaping @MainActor () -> Bool
        ) async -> SessionAdminLifecycleOutcome {
            effortCalls.append((sessionID, effort))
            return effort == "bogus" ? .invalid("unsupported") : .applied(changed: true, fields: ["effort": effort])
        }

        func fork(sessionID: UUID, upToItemID _: UUID?) async throws -> UUID {
            forkCalls.append(sessionID)
            provenance.add(nextFork, parent: nil)
            return nextFork
        }
    }

    @MainActor
    final class Names {
        var map: [UUID: String] = [:]
    }

    @MainActor
    final class WorktreeHost: SessionAdminWorktreeHost {
        var idle: [UUID: Bool] = [:]
        var bound: [UUID: [AgentSessionWorktreeBindingSummary]] = [:]
        var created: [UUID] = []
        var bindCalls: [(UUID, String)] = []
        var unbindCalls: [UUID] = []
        /// Runs inside a bind/unbind just before the write-time authority check (a revocation or a
        /// membership change landing mid-transition).
        var beforeWrite: (@MainActor () -> Void)?
        var boundElsewhere: [String: Set<UUID>] = [:]
        private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

        func becomeIdle(_ sessionID: UUID) {
            idle[sessionID] = true
            for waiter in waiters.removeValue(forKey: sessionID) ?? [] {
                waiter.resume()
            }
        }

        func createWorktree(
            forSession sessionID: UUID,
            repoRoot _: String?,
            branch: String?,
            baseRef _: String?
        ) async throws -> SessionAdminWorktreeInfo {
            created.append(sessionID)
            return SessionAdminWorktreeInfo(
                worktreeID: "wt-\(created.count)", repositoryID: "repo", repoRootPath: "/repo",
                path: "/managed/wt-\(created.count)", branch: branch, isPrunable: false
            )
        }

        func bindWorktree(
            sessionID: UUID,
            worktree: String,
            repoRoot _: String?,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async throws -> SessionAdminWorktreeInfo {
            guard idle[sessionID] ?? true else { throw SessionAdminHostError.notIdle }
            beforeWrite?()
            guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
            bindCalls.append((sessionID, worktree))
            bound[sessionID] = [Self.summary(worktree)]
            return SessionAdminWorktreeInfo(
                worktreeID: worktree, repositoryID: "repo", repoRootPath: "/repo", path: "/managed/\(worktree)",
                branch: nil, isPrunable: false
            )
        }

        func unbindWorktrees(
            sessionID: UUID,
            worktreeID: String?,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async throws -> [String] {
            guard idle[sessionID] ?? true else { throw SessionAdminHostError.notIdle }
            beforeWrite?()
            guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
            unbindCalls.append(sessionID)
            let removed = (bound[sessionID] ?? []).filter { worktreeID == nil || $0.worktreeID == worktreeID }
            bound[sessionID] = (bound[sessionID] ?? []).filter { !removed.contains($0) }
            return removed.map(\.worktreeID)
        }

        func boundWorktrees(sessionID: UUID) -> [AgentSessionWorktreeBindingSummary] {
            bound[sessionID] ?? []
        }

        func isIdleForWorktreeTransition(sessionID: UUID) -> Bool {
            idle[sessionID] ?? true
        }

        func waitForIdleBoundary(sessionID: UUID) async {
            guard !(idle[sessionID] ?? true) else { return }
            await withCheckedContinuation { waiters[sessionID, default: []].append($0) }
        }

        func allBoundWorktrees() -> [String: Set<UUID>] {
            var result = boundElsewhere
            for (sessionID, summaries) in bound {
                for summary in summaries {
                    result[summary.worktreeID, default: []].insert(sessionID)
                }
            }
            return result
        }

        func isWorktreePrunable(path _: String, repoRoot _: String?) async -> Bool {
            false
        }

        func previewMerge(sessionID _: UUID, repoRoot _: String?, mergeTarget _: String?) async throws -> Value {
            .object(["operation_id": .string("op-1")])
        }

        func applyMerge(sessionID _: UUID, operationID: String) async throws -> Value {
            .object(["status": .string("completed"), "operation_id": .string(operationID)])
        }

        static func summary(_ worktreeID: String) -> AgentSessionWorktreeBindingSummary {
            AgentSessionWorktreeBindingSummary(
                id: UUID().uuidString, repositoryID: "repo", repoKey: "repo", logicalRootPath: "/repo",
                worktreeID: worktreeID, worktreeRootPath: "/managed/\(worktreeID)", boundAt: Date()
            )
        }
    }

    @MainActor
    final class Fixture {
        let provenance = Provenance()
        let runtime = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        let structure: StructureHost
        let worktrees = WorktreeHost()
        let ownership = WorktreeOwnershipStore()
        let core: AgentSessionAdministrationCore
        let worktreeHandler: SessionAdminWorktreeHandler
        let projector: SpawnProvenanceDelegationMembershipProjector
        let names = Names()

        init() {
            structure = StructureHost(provenance: provenance)
            var projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
            let ownership = ownership
            projector.ownedUnreleasedWorktreeIDs = { ownership.ownedUnreleasedWorktreeIDs(createdBy: $0) }
            self.projector = projector
            core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
            var context = SessionAdminHandlerContext(scopes: runtime, projector: projector)
            let names = names
            context.displayName = { names.map[$0] }
            worktreeHandler = SessionAdminWorktreeHandler(context: context, host: worktrees, ownership: ownership)
            core.register(SessionAdminRestructureHandler(context: context, host: structure))
            core.register(SessionAdminLifecycleHandler(context: context, host: structure))
            core.register(worktreeHandler)
        }

        @discardableResult
        func grant(
            _ grantee: UUID,
            _ capabilities: Set<DomainDelegationScopeCapability> = DomainDelegationScopeCapability.manageTreePreset,
            kind: DomainDelegationScopeKind? = nil,
            guardrails: DomainDelegationScopeGuardrails = .init()
        ) throws -> DomainDelegationScopeRecord {
            let request = try runtime.requestScope(
                requesterSessionID: grantee, requesterTabID: nil, kind: kind ?? .tree(rootSessionID: grantee),
                capabilities: capabilities, guardrails: guardrails, reason: nil, idempotencyKey: nil
            ).get()
            return try runtime.approve(requestID: request.id).get()
        }

        func perform(
            _ operation: DomainAgentSessionTargetOperation,
            caller: UUID,
            targets: [UUID] = [],
            args: [String: Value] = [:],
            key: String? = nil,
            confirmation: UUID? = nil
        ) async throws -> AgentSessionAdministrationOutcome {
            try await core.perform(.init(
                operation: operation, caller: .agentSession(caller), callerTabID: UUID(),
                targetSessionIDs: targets, idempotencyKey: key, confirmationID: confirmation, arguments: args
            ))
        }

        func admit(_ creator: UUID?, target: DelegationSpawnTarget = .newSession) -> DelegationSpawnAdmission.Outcome {
            DelegationSpawnAdmission.admit(
                creatorSessionID: creator, target: target, scopes: runtime, administration: core, projector: projector
            )
        }

        func value(
            _ operation: DomainAgentSessionTargetOperation,
            caller: UUID,
            targets: [UUID] = [],
            args: [String: Value] = [:],
            key: String? = nil,
            confirmation: UUID? = nil
        ) async throws -> [String: Value] {
            let outcome = try await perform(operation, caller: caller, targets: targets, args: args, key: key, confirmation: confirmation)
            switch outcome {
            case let .completed(value):
                return try XCTUnwrap(value.objectValue)
            case let .denied(denial, sessionID):
                return try XCTUnwrap(SessionAdminMCPToolService.deniedValue(denial, sessionID: sessionID).objectValue)
            default:
                XCTFail("unexpected outcome \(outcome)")
                return [:]
            }
        }
    }

    /// Every refusal code in a reply: the top-level one and each item's.
    private func codes(_ reply: [String: Value]) -> [String] {
        [reply["code"]?.stringValue].compactMap(\.self)
            + (reply["items"]?.arrayValue ?? []).compactMap { $0.objectValue?["code"]?.stringValue }
    }

    private func items(_ reply: [String: Value]) -> [String: [String: Value]] {
        var result: [String: [String: Value]] = [:]
        for item in reply["items"]?.arrayValue ?? [] {
            guard let object = item.objectValue, let id = object["session_id"]?.stringValue else { continue }
            result[id] = object
        }
        return result
    }

    private func assertUniformDenial(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected the uniform denial", file: file, line: line)
        } catch {
            XCTAssertFalse(String(describing: error).contains("not_implemented"), "\(error)", file: file, line: line)
        }
    }

    // MARK: - Links (S8)

    func testLinkWithoutControlIsRefusedBeforeAnyLinkIsMinted() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        try fixture.grant(overseer, [.observe, .restructure])
        let reply = try await fixture.value(.adminLink, caller: overseer, targets: [member])
        XCTAssertEqual(reply["code"], .string("scope_capability_missing"))
        XCTAssertEqual(reply["capability"], .string("control"))
        XCTAssertTrue(fixture.structure.added.isEmpty)
    }

    func testAllSessionsScopeCanNeverCreateALink() async throws {
        let fixture = Fixture()
        let overseer = UUID(), other = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(other, parent: nil)
        try fixture.grant(overseer, DomainDelegationScopeCapability.organizeEverythingPreset, kind: .allSessions)
        let reply = try await fixture.value(.adminLink, caller: overseer, targets: [other])
        XCTAssertEqual(reply["code"], .string("scope_capability_missing"))
        XCTAssertTrue(fixture.structure.added.isEmpty)
    }

    func testLinkCreatesThroughTheBridgeAndNeverUpgradesAnExistingLink() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), b = UUID(), outsider = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(a, parent: overseer)
        fixture.provenance.add(b, parent: overseer)
        fixture.provenance.add(outsider, parent: nil)
        try fixture.grant(overseer)
        fixture.structure.links[Pair(observer: overseer, target: a)] = [.poll]

        let reply = try await fixture.value(.adminLink, caller: overseer, targets: [a, b])
        let rows = items(reply)
        XCTAssertEqual(rows[a.uuidString]?["result"], .string("already_linked"))
        XCTAssertEqual(rows[a.uuidString]?["capabilities"], .array([.string("poll")]))
        XCTAssertEqual(rows[b.uuidString]?["result"], .string("linked"))
        XCTAssertEqual(fixture.structure.added, [Pair(observer: overseer, target: b)])
        XCTAssertEqual(fixture.structure.links[Pair(observer: overseer, target: a)], [.poll], "never upgraded")

        // A scope only mints links its own grantee observes (S6); links between two other sessions,
        // members or not, are the user's to create.
        for observer in [outsider, a] {
            let refused = try await fixture.value(
                .adminLink, caller: overseer, targets: [b], args: ["observer_session_id": .string(observer.uuidString)]
            )
            XCTAssertEqual(refused["code"], .string("observer_must_be_caller"))
        }
        XCTAssertEqual(fixture.structure.added.count, 1)
        guard case .denied = try await fixture.perform(.adminLink, caller: overseer, targets: [outsider]) else {
            return XCTFail("a non-member target is refused by the core")
        }

        let unlink = try await fixture.value(.adminUnlink, caller: overseer, targets: [b])
        XCTAssertEqual(items(unlink)[b.uuidString]?["result"], .string("unlinked"))
    }

    func testLinkRechecksScopeAfterEverySuspension() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), b = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(a, parent: overseer)
        fixture.provenance.add(b, parent: overseer)
        let scope = try fixture.grant(overseer)
        fixture.structure.onActiveLink = { fixture.runtime.revoke(scopeID: scope.id) }
        let reply = try await fixture.value(.adminLink, caller: overseer, targets: [a, b])
        let rows = items(reply)
        XCTAssertEqual(rows[a.uuidString]?["code"], .string("scope_revoked"))
        XCTAssertEqual(rows[b.uuidString]?["code"], .string("scope_revoked"))
        XCTAssertTrue(fixture.structure.added.isEmpty, "a revocation mid-op mints nothing")
    }

    // MARK: - Re-parent and adopt (S9)

    func testReparentMovesOnlyOrganizationalPlacementWithinTheScope() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), b = UUID(), outsider = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(a, parent: overseer)
        fixture.provenance.add(b, parent: overseer)
        fixture.provenance.add(outsider, parent: nil)
        let scope = try fixture.grant(overseer)

        let reply = try await fixture.value(
            .adminReparent, caller: overseer, targets: [a], args: ["parent_session_id": .string(b.uuidString)]
        )
        XCTAssertEqual(items(reply)[a.uuidString]?["result"], .string("moved"))
        XCTAssertEqual(fixture.structure.placements.single?.parent, b)
        XCTAssertNil(fixture.structure.placements.single?.scope, "reparent keeps the existing scope stamp")
        XCTAssertEqual(fixture.provenance.sessions[a]?.parentSessionID, overseer, "spawn provenance is immutable")
        let projector = SpawnProvenanceDelegationMembershipProjector(source: fixture.provenance)
        XCTAssertEqual(projector.membershipProof(for: a, in: scope.grant)?.basis, .treePath([a, b, overseer]))

        let cycle = try await fixture.value(
            .adminReparent, caller: overseer, targets: [b], args: ["parent_session_id": .string(a.uuidString)]
        )
        XCTAssertEqual(cycle["code"], .string("placement_cycle"))

        // Scopes never grow: an outside destination is the uniform denial.
        await assertUniformDenial {
            _ = try await fixture.perform(
                .adminReparent, caller: overseer, targets: [a], args: ["parent_session_id": .string(outsider.uuidString)]
            )
        }
        XCTAssertEqual(fixture.structure.placements.count, 1)
    }

    func testReparentUnderAnotherOverseerWouldGrowItsScopeAndIsRefused() async throws {
        let fixture = Fixture()
        let overseer = UUID(), other = UUID(), a = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(other, parent: overseer)
        fixture.provenance.add(a, parent: overseer)
        try fixture.grant(overseer)
        let otherScope = try fixture.grant(other, [.observe])
        let reply = try await fixture.value(
            .adminReparent, caller: overseer, targets: [a], args: ["parent_session_id": .string(other.uuidString)]
        )
        XCTAssertEqual(reply["code"], .string("placement_affects_other_scopes"))
        XCTAssertEqual(reply["affected_scope_count"], .int(1))
        XCTAssertNil(reply["affected_scope_ids"], "other scopes' identities are never disclosed")
        _ = otherScope
        XCTAssertTrue(fixture.structure.placements.isEmpty)
    }

    func testAdoptIsCardedAndStampsTheScope() async throws {
        let fixture = Fixture()
        let overseer = UUID(), outsider = UUID(), second = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(outsider, parent: nil)
        fixture.provenance.add(second, parent: nil)
        let scope = try fixture.grant(overseer)
        guard case let .pendingConfirmation(card, _) = try await fixture.perform(
            .adminAdopt, caller: overseer, targets: [outsider, second], key: "adopt-1"
        ) else {
            return XCTFail("adopt always raises a card")
        }
        XCTAssertEqual(card.reason, .adoption)
        XCTAssertEqual(card.items.map(\.sessionID), [outsider, second])
        XCTAssertTrue(fixture.structure.placements.isEmpty, "nothing moves before the user approves")
        XCTAssertNotNil(fixture.runtime.confirmations.approve(confirmationID: card.id))
        let reply = try await fixture.value(
            .adminAdopt, caller: overseer, targets: [outsider, second], key: "adopt-1", confirmation: card.id
        )
        XCTAssertEqual(items(reply)[outsider.uuidString]?["result"], .string("moved"))
        XCTAssertEqual(items(reply)[second.uuidString]?["result"], .string("moved"), "each item is re-decided on its own")
        XCTAssertEqual(fixture.structure.placements.map(\.session), [outsider, second])
        XCTAssertEqual(Set(fixture.structure.placements.map(\.parent)), [overseer])
        XCTAssertEqual(Set(fixture.structure.placements.compactMap(\.scope)), [scope.id])
    }

    func testAdoptIsRefusedBeforeAnyCardForNestedScopesAndForeignMembership() async throws {
        let fixture = Fixture()
        let overseer = UUID(), nested = UUID(), outsider = UUID(), otherRoot = UUID(), claimed = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(nested, parent: overseer)
        fixture.provenance.add(outsider, parent: nil)
        fixture.provenance.add(otherRoot, parent: nil)
        fixture.provenance.add(claimed, parent: otherRoot)
        try fixture.grant(overseer, DomainDelegationScopeCapability.fullPreset)
        let attenuated = try await fixture.value(.adminAttenuate, caller: overseer, targets: [nested])
        XCTAssertEqual(attenuated["result"], .string("attenuated"))

        let nestedAdopt = try await fixture.value(.adminAdopt, caller: nested, targets: [outsider], key: "n-adopt")
        XCTAssertEqual(nestedAdopt["code"], .string("adopt_requires_user_granted_scope"))

        let otherScope = try fixture.grant(otherRoot, [.observe])
        let foreign = try await fixture.value(.adminAdopt, caller: overseer, targets: [claimed], key: "o-adopt")
        XCTAssertEqual(foreign["code"], .string("placement_affects_other_scopes"))
        XCTAssertEqual(foreign["affected_scope_count"], .int(1))
        _ = otherScope
        XCTAssertTrue(fixture.runtime.confirmations.confirmations.isEmpty, "no card was raised")
    }

    // MARK: - Attenuation

    func testAttenuateIsANoLooserSubsetAndNeedsAMember() async throws {
        let fixture = Fixture()
        let overseer = UUID(), nested = UUID(), outsider = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(nested, parent: overseer)
        fixture.provenance.add(outsider, parent: nil)
        let parent = try fixture.grant(overseer, [.observe, .spawn, .restructure], guardrails: .init(maxLiveSessions: 5))

        let widened = try await fixture.value(
            .adminAttenuate, caller: overseer, targets: [nested], args: ["capabilities": .array([.string("control")])]
        )
        XCTAssertEqual(widened["code"], .string("attenuation_widens_capabilities"))

        let reply = try await fixture.value(
            .adminAttenuate, caller: overseer, targets: [nested], args: ["capabilities": .array([.string("observe")])]
        )
        let scope = try XCTUnwrap(reply["scope"]?.objectValue)
        XCTAssertEqual(scope["parent_scope_id"], .string(parent.id.uuidString))
        XCTAssertEqual(scope["root_session_id"], .string(nested.uuidString))
        let child = try XCTUnwrap(fixture.runtime.liveScopes(grantedTo: nested).single)
        XCTAssertEqual(child.grant.capabilities, [.observe])
        XCTAssertEqual(child.grant.guardrails.maxLiveSessions, 5, "omitted limits are inherited, never loosened")

        guard case .denied = try await fixture.perform(.adminAttenuate, caller: overseer, targets: [outsider]) else {
            return XCTFail("a non-member cannot receive a nested scope")
        }
    }

    // MARK: - Spawn under scope

    func testSpawnAdmissionIsANoOpWithoutASpawnScopeAndEnforcesGuardrails() throws {
        let fixture = Fixture()
        let unscoped = UUID(), observer = UUID(), overseer = UUID(), member = UUID()
        for id in [unscoped, observer, overseer] {
            fixture.provenance.add(id, parent: nil)
        }
        fixture.provenance.add(member, parent: overseer)
        let admit = { (creator: UUID?) in fixture.admit(creator) }
        XCTAssertEqual(admit(unscoped), .unscoped, "agent_run/agent_manage/create_lane are unchanged without a scope")
        XCTAssertEqual(admit(nil), .unscoped)
        try fixture.grant(observer, [.observe])
        guard case let .admitted(observed) = admit(observer) else { return XCTFail("a member is admitted") }
        XCTAssertNil(observed.stampScopeID, "a scope without spawn checks guardrails but stamps nothing")
        fixture.runtime.release(observed.reservation)

        let scope = try fixture.grant(overseer, [.spawn, .observe], guardrails: .init(maxLiveSessions: 2))
        XCTAssertEqual(admit(overseer), .denied(.guardrailExceeded(guardrail: .maxLiveSessions, limit: 2, current: 2)))
        fixture.provenance.add(member, parent: overseer, live: false)
        guard case let .admitted(admission) = admit(overseer) else { return XCTFail("room under the limit admits") }
        XCTAssertEqual(admission.stampScopeID, scope.id)
        XCTAssertEqual(admission.creatorSessionID, overseer)
        XCTAssertTrue(
            DelegationSpawnAdmission.error(for: .guardrailExceeded(guardrail: .maxDepth, limit: 1, current: 2))
                .localizedDescription.contains("scope_guardrail_exceeded")
        )
    }

    func testNestedSpawnCountsDepthAgainstEveryAncestorScope() async throws {
        let fixture = Fixture()
        let overseer = UUID(), nested = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(nested, parent: overseer)
        try fixture.grant(overseer, [.spawn, .observe], guardrails: .init(maxDepth: 1))
        let attenuated = try await fixture.value(.adminAttenuate, caller: overseer, targets: [nested])
        XCTAssertEqual(attenuated["result"], .string("attenuated"))
        XCTAssertEqual(fixture.admit(nested), .denied(.guardrailExceeded(guardrail: .maxDepth, limit: 1, current: 2)))
    }

    // MARK: - Lifecycle

    func testSetModelAndEffortUseTheScopeLeaseAsTheFinalFence() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        let scope = try fixture.grant(overseer)
        let model = try await fixture.value(
            .adminSetModel, caller: overseer, targets: [member], args: ["model_id": .string("claudeCode:opus")]
        )
        XCTAssertEqual(items(model)[member.uuidString]?["result"], .string("applied"))
        XCTAssertEqual(fixture.structure.modelCalls.single?.1, "claudeCode:opus")
        XCTAssertEqual(fixture.structure.lastAuthorization?(), true)
        let effort = try await fixture.value(.adminSetEffort, caller: overseer, targets: [member], args: ["effort": .string("bogus")])
        XCTAssertEqual(items(effort)[member.uuidString]?["code"], .string("invalid_value"))

        // Control over oneself is never delegated.
        guard case .denied = try await fixture.perform(
            .adminSetModel, caller: overseer, targets: [overseer], args: ["model_id": .string("x:y")]
        ) else {
            return XCTFail("self-target control is refused")
        }
        fixture.runtime.revoke(scopeID: scope.id)
        XCTAssertEqual(fixture.structure.lastAuthorization?(), false, "a revoked scope cannot commit a late model change")
    }

    func testForkIsIdempotentJoinsTheScopeAndHonorsGuardrails() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), b = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(a, parent: overseer)
        fixture.provenance.add(b, parent: overseer, live: false)
        let scope = try fixture.grant(overseer, guardrails: .init(maxLiveSessions: 4))
        let forkID = fixture.structure.nextFork

        let first = try await fixture.value(.adminFork, caller: overseer, targets: [a], key: "fork-1")
        XCTAssertEqual(first["forked_session_id"], .string(forkID.uuidString))
        XCTAssertEqual(first["joined_scope"], .bool(true))
        XCTAssertEqual(fixture.structure.placements.single?.parent, overseer)
        XCTAssertEqual(fixture.structure.placements.single?.scope, scope.id)

        let replay = try await fixture.value(.adminFork, caller: overseer, targets: [a], key: "fork-1")
        XCTAssertEqual(replay["result"], .string("replayed"))
        XCTAssertEqual(fixture.structure.forkCalls, [a])
        let conflict = try await fixture.value(.adminFork, caller: overseer, targets: [b], key: "fork-1")
        XCTAssertEqual(conflict["result"], .string("idempotency_conflict"))
        do {
            _ = try await fixture.perform(.adminFork, caller: overseer, targets: [b])
            XCTFail("fork requires an idempotency key")
        } catch {}

        // The overseer, a, the fork, and now b are live: a fifth would exceed the limit of four.
        fixture.provenance.add(b, parent: overseer, live: true)
        let limited = try await fixture.value(.adminFork, caller: overseer, targets: [a], key: "fork-2")
        XCTAssertEqual(limited["code"], .string("scope_guardrail_exceeded"))
        XCTAssertEqual(limited["guardrail"], .string("max_live_sessions"))
    }

    // MARK: - Worktrees on behalf

    func testWorktreeCreateRecordsOwnershipAndCountsTowardMaxWorktrees() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        let scope = try fixture.grant(overseer, guardrails: .init(maxWorktrees: 1))
        let created = try await fixture.value(
            .adminWorktreeCreate, caller: overseer, targets: [member], args: ["branch": .string("feature")]
        )
        XCTAssertEqual(created["result"], .string("created"))
        let record = try XCTUnwrap(fixture.ownership.record(worktreeID: "wt-1"))
        XCTAssertEqual(record.createdBySessionID, overseer)
        XCTAssertEqual(record.delegationScopeID, scope.id)
        XCTAssertNil(record.releasedAt)

        let second = try await fixture.value(.adminWorktreeCreate, caller: overseer, targets: [member])
        XCTAssertEqual(second["code"], .string("scope_guardrail_exceeded"))
        XCTAssertEqual(second["guardrail"], .string("max_worktrees"))
        XCTAssertEqual(fixture.worktrees.created.count, 1, "an unbound owned worktree still counts")
    }

    func testDeferredBindAppliesAtTheNextIdleBoundaryAndRespectsRevocation() async throws {
        let fixture = Fixture()
        let overseer = UUID(), busy = UUID(), revokedTarget = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(busy, parent: overseer)
        fixture.provenance.add(revokedTarget, parent: overseer)
        let scope = try fixture.grant(overseer)
        fixture.worktrees.idle[busy] = false

        let immediate = try await fixture.value(.adminWorktreeBind, caller: overseer, targets: [busy], args: ["worktree": .string("w1")])
        XCTAssertEqual(items(immediate)[busy.uuidString]?["code"], .string("target_busy"))

        let queued = try await fixture.value(
            .adminWorktreeBind, caller: overseer, targets: [busy],
            args: ["worktree": .string("w1"), "apply": .string("next_boundary")]
        )
        XCTAssertEqual(items(queued)[busy.uuidString]?["result"], .string("queued"))
        XCTAssertTrue(fixture.worktrees.bindCalls.isEmpty)
        XCTAssertNotNil(fixture.worktreeHandler.pendingBinds[busy])
        fixture.worktrees.becomeIdle(busy)
        await fixture.worktreeHandler.settleDeferredBinds()
        XCTAssertEqual(fixture.worktrees.bindCalls.map(\.0), [busy])
        XCTAssertEqual(fixture.worktreeHandler.deferredOutcomes[busy], .applied(worktreeID: "w1"))

        fixture.worktrees.idle[revokedTarget] = false
        _ = try await fixture.value(
            .adminWorktreeBind, caller: overseer, targets: [revokedTarget],
            args: ["worktree": .string("w2"), "apply": .string("next_boundary")]
        )
        fixture.runtime.revoke(scopeID: scope.id)
        fixture.worktrees.becomeIdle(revokedTarget)
        await fixture.worktreeHandler.settleDeferredBinds()
        XCTAssertEqual(fixture.worktreeHandler.deferredOutcomes[revokedTarget], .revoked)
        XCTAssertEqual(fixture.worktrees.bindCalls.count, 1, "a revoked scope never applies a queued bind")
    }

    func testWorktreeReleaseIsAlwaysCardedUnbindsAndMarksStale() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        try fixture.grant(overseer)
        fixture.worktrees.bound[member] = [WorktreeHost.summary("w1")]

        guard case let .pendingConfirmation(card, _) = try await fixture.perform(
            .adminWorktreeRelease, caller: overseer, targets: [member], key: "release-1"
        ) else { return XCTFail("worktree_release always raises a card, even for one item") }
        XCTAssertTrue(card.items.single?.effect.contains("nothing is deleted") ?? false)
        XCTAssertTrue(fixture.worktrees.unbindCalls.isEmpty)
        XCTAssertNotNil(fixture.runtime.confirmations.approve(confirmationID: card.id))

        let reply = try await fixture.value(
            .adminWorktreeRelease, caller: overseer, targets: [member], key: "release-1", confirmation: card.id
        )
        XCTAssertEqual(items(reply)[member.uuidString]?["result"], .string("released"))
        XCTAssertNotNil(fixture.ownership.record(worktreeID: "w1")?.releasedAt)
        XCTAssertEqual(fixture.worktrees.unbindCalls, [member])
    }

    func testWorktreeInventoryFlagsUnboundOwnedWorktrees() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        try fixture.grant(overseer)
        _ = try await fixture.value(.adminWorktreeCreate, caller: overseer, targets: [member])
        fixture.worktrees.bound[member] = [WorktreeHost.summary("w-bound")]
        let inventory = try await fixture.value(.adminWorktreeInventory, caller: overseer)
        var flags: [String: Value] = [:]
        for entry in inventory["worktrees"]?.arrayValue ?? [] {
            guard let object = entry.objectValue, let id = object["worktree_id"]?.stringValue else { continue }
            flags[id] = object["stale_flags"]
        }
        XCTAssertEqual(flags["wt-1"], .array([.string("unbound")]))
        XCTAssertEqual(flags["w-bound"], .array([]))
    }

    func testMergeApplyRoutesThroughTheReviewHost() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        try fixture.grant(overseer)
        let preview = try await fixture.value(.adminMergePreview, caller: overseer, targets: [member])
        XCTAssertEqual(preview["merge"]?.objectValue?["operation_id"], .string("op-1"))
        let applied = try await fixture.value(
            .adminMergeApply, caller: overseer, targets: [member], args: ["operation_id": .string("op-1")]
        )
        XCTAssertEqual(applied["result"], .string("reviewed"))
    }

    // MARK: - Persistence

    func testOrganizationalPlacementPersistsAndLegacyFilesFallBackToSpawnProvenance() throws {
        let parent = UUID(), org = UUID(), scope = UUID()
        let session = AgentSession(name: "Placed", parentSessionID: parent, organizationalParentID: org, delegationScopeID: scope)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.parentSessionID, parent)
        XCTAssertEqual(decoded.organizationalParentID, org)
        XCTAssertEqual(decoded.delegationScopeID, scope)
        XCTAssertEqual(decoded.serializationVersion, 9)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        legacy.removeValue(forKey: "organizationalParentID")
        legacy.removeValue(forKey: "delegationScopeID")
        legacy["serializationVersion"] = 8
        let migrated = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(migrated.organizationalParentID)
        XCTAssertEqual(migrated.parentSessionID, parent)

        let record = AgentSessionMetadataRecord.record(
            from: session, fileURL: URL(fileURLWithPath: "/tmp/AgentSession-x.json"),
            observedFileSize: nil, observedFileModificationDate: nil
        )
        XCTAssertEqual(record.organizationalParentID, org)
        XCTAssertEqual(AgentSessionMetadataIndex.currentSchemaVersion, 8, "placement is additive; history keeps reading v8 indexes")
        let roundTripped = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(roundTripped.delegationScopeID, scope)
        XCTAssertEqual(roundTripped.sidebarEntry(tabID: UUID())?.organizationalParentID, org)

        let provenance = DelegationSessionProvenance(
            sessionID: UUID(), workspaceID: nil, parentSessionID: parent, createdByOverseerSessionID: nil,
            organizationalParentID: nil, isLive: true
        )
        XCTAssertEqual(provenance.effectiveOrganizationalParentID, parent, "no placement follows spawn provenance")
    }

    // MARK: - Review fixes (M1, S2, M2, M3, S1, S3, S6, nits)

    /// M1: a worker inside an overseer's tree is bounded by the overseer's guardrails, whatever the
    /// worker's own capabilities, and a session in no scope is untouched.
    func testWorkerOfAnOverseerCannotBypassSpawnGuardrails() throws {
        let fixture = Fixture()
        let overseer = UUID(), worker = UUID(), stranger = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(worker, parent: overseer)
        fixture.provenance.add(stranger, parent: nil)
        try fixture.grant(overseer, [.observe], guardrails: .init(maxLiveSessions: 2))
        XCTAssertEqual(
            fixture.admit(worker),
            .denied(.guardrailExceeded(guardrail: .maxLiveSessions, limit: 2, current: 2)),
            "the worker's spawn joins the overseer's tree, so the overseer's limit applies"
        )
        XCTAssertEqual(fixture.admit(stranger), .unscoped)
        let error = DelegationSpawnAdmission.error(for: .guardrailExceeded(guardrail: .maxLiveSessions, limit: 2, current: 2))
        XCTAssertTrue(error.localizedDescription.contains("\"code\":\"scope_guardrail_exceeded\""), "\(error)")
        XCTAssertTrue(error.localizedDescription.contains("\"guardrail\":\"max_live_sessions\""), "\(error)")
    }

    /// S2: an in-flight creation is reserved until it settles, so two concurrent spawns (or forks or
    /// worktree creations) cannot both pass a limit with room for one.
    func testConcurrentCreationsCannotOvershootAGuardrail() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        let scope = try fixture.grant(overseer, guardrails: .init(maxLiveSessions: 3, maxWorktrees: 1))
        guard case let .admitted(first) = fixture.admit(overseer) else { return XCTFail("room for one") }
        XCTAssertEqual(fixture.admit(overseer), .denied(.guardrailExceeded(guardrail: .maxLiveSessions, limit: 3, current: 3)))
        let forkWhileReserved = try await fixture.value(.adminFork, caller: overseer, targets: [member], key: "f")
        XCTAssertEqual(forkWhileReserved["code"], .string("scope_guardrail_exceeded"), "a fork counts the pending spawn too")
        DelegationSpawnAdmission.finish(first, scopes: fixture.runtime)
        guard case .admitted = fixture.admit(overseer) else { return XCTFail("released reservations free the slot") }

        let held = fixture.runtime.reserve(scopeIDs: [scope.id], worktrees: 1)
        let blocked = try await fixture.value(.adminWorktreeCreate, caller: overseer, targets: [member])
        XCTAssertEqual(blocked["guardrail"], .string("max_worktrees"))
        fixture.runtime.release(held)
    }

    /// M1: `agent_run start` with a `tab_id` adds a member unless the tab's session already has a
    /// tree placement; an empty or unknown tab always does.
    func testSpawnIntoAnEmptyTabIsANewMember() {
        let viewModel = WindowState().agentModeViewModel
        XCTAssertEqual(viewModel.delegationSpawnTarget(tabID: nil, creatorSessionID: UUID()), .newSession)
        XCTAssertEqual(
            viewModel.delegationSpawnTarget(tabID: UUID(), creatorSessionID: UUID()), .newSession, "a tab with no bound session"
        )
    }

    /// Review M2: an `agent_run start` whose `tab_id` holds an adopted session (organizational parent,
    /// no spawn parent) or a lane is already placed: it is neither admitted, nor stamped, nor moved,
    /// and a stamp never overwrites another overseer's placement or scope.
    func testAgentRunIntoAnAlreadyPlacedSessionKeepsItsPlacementAndScope() throws {
        let session = UUID(), overseerA = UUID(), overseerB = UUID(), scopeA = UUID()
        func classify(_ placement: DelegationSpawnTargetPlacement?, by creator: UUID? = overseerB) -> DelegationSpawnTarget {
            DelegationSpawnTarget.classify(sessionID: session, placement: placement, creatorSessionID: creator)
        }
        let adopted = DelegationSpawnTargetPlacement(organizationalParentID: overseerA, delegationScopeID: scopeA)
        XCTAssertEqual(classify(adopted), .placedSession, "the organizational parent wins over any spawn parent agent_run writes")
        XCTAssertFalse(adopted.admitsStamp(by: overseerB), "another overseer never re-stamps an adopted session")
        XCTAssertFalse(adopted.admitsStamp(by: overseerA), "an existing placement is never overwritten")
        XCTAssertNil(
            try DelegationSpawnAdmission.admitOrThrow(creatorSessionID: overseerB, target: .placedSession),
            "a placed target is not admitted, so nothing is reserved or stamped"
        )

        let lane = DelegationSpawnTargetPlacement(createdByOverseerSessionID: overseerA)
        XCTAssertEqual(classify(lane, by: overseerA), .placedSession, "its own creator's start leaves a lane in place")
        XCTAssertEqual(classify(lane), .otherCreatorsLane(session), "another creator's spawn parent would move the lane")
        XCTAssertTrue(lane.admitsStamp(by: overseerA), "a lane's own creator stamps it at creation")
        XCTAssertFalse(lane.admitsStamp(by: overseerB))

        let spawned = DelegationSpawnTargetPlacement(parentSessionID: overseerA)
        XCTAssertEqual(classify(spawned), .placedSession, "a spawn parent is write-once")
        XCTAssertTrue(spawned.admitsStamp(by: overseerA), "a new child is stamped under its own spawn parent")
        XCTAssertFalse(spawned.admitsStamp(by: overseerB))

        XCTAssertEqual(classify(DelegationSpawnTargetPlacement()), .unplacedSession(session))
        XCTAssertEqual(classify(nil), .unplacedSession(session))
        XCTAssertEqual(DelegationSpawnTarget.classify(sessionID: nil, placement: nil, creatorSessionID: overseerB), .newSession)
    }

    /// Review M2 (follow-up): `agent_run`'s spawn-parent write would move another overseer's lane out
    /// of that overseer's tree, so the start is refused whenever that changes a live scope's members,
    /// even for a creator with no scope of its own.
    func testAnotherOverseersLaneIsNotMovedBetweenScopes() throws {
        let fixture = Fixture()
        let overseerA = UUID(), overseerB = UUID(), lane = UUID(), freeLane = UUID(), freeCreator = UUID()
        fixture.provenance.add(overseerA, parent: nil)
        fixture.provenance.add(overseerB, parent: nil)
        fixture.provenance.add(lane, parent: nil, laneCreator: overseerA)
        fixture.provenance.add(freeCreator, parent: nil)
        fixture.provenance.add(freeLane, parent: nil, laneCreator: freeCreator)
        try fixture.grant(overseerA, [.observe])
        XCTAssertEqual(fixture.admit(overseerB, target: .otherCreatorsLane(lane)), .targetMovesBetweenScopes(count: 1))
        XCTAssertEqual(
            fixture.admit(overseerB, target: .otherCreatorsLane(freeLane)), .unscoped,
            "a lane in no scope moves no scope's membership"
        )
        XCTAssertEqual(fixture.admit(overseerB, target: .placedSession), .unscoped)
    }

    /// Review M1: placement writes for a session with no live tab are queued per session in the order
    /// they were applied, so the last applied placement is the last written.
    func testPlacementDiskWritesRunInTheOrderTheyWereApplied() async throws {
        @MainActor final class Log {
            var entries: [Int] = []
        }
        let log = Log()
        let session = UUID()
        let first = DelegationPlacementWriteQueue.schedule(session) {
            for _ in 0 ..< 5 {
                await Task.yield()
            }
            log.entries.append(1)
        }
        let second = DelegationPlacementWriteQueue.schedule(session) { log.entries.append(2) }
        try await second.value
        try await first.value
        XCTAssertEqual(log.entries, [1, 2])
    }

    /// Review M2: an unplaced `tab_id` target joins with its whole subtree, so a scoped creator may not
    /// graft a scope anchor (or a tree holding one), and the joining subtree counts against limits.
    func testScopeAnchorTabIsNotGraftedAndAJoiningSubtreeIsCounted() throws {
        let fixture = Fixture()
        let overseer = UUID(), worker = UUID(), stranger = UUID()
        let anchor = UUID(), holder = UUID(), nestedAnchor = UUID()
        let loose = UUID(), looseChildA = UUID(), looseChildB = UUID(), single = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(worker, parent: overseer)
        fixture.provenance.add(stranger, parent: nil)
        fixture.provenance.add(anchor, parent: nil)
        fixture.provenance.add(holder, parent: nil)
        fixture.provenance.add(nestedAnchor, parent: holder)
        fixture.provenance.add(loose, parent: nil)
        fixture.provenance.add(looseChildA, parent: loose)
        fixture.provenance.add(looseChildB, parent: loose)
        fixture.provenance.add(single, parent: nil)
        try fixture.grant(overseer, [.spawn, .observe], guardrails: .init(maxLiveSessions: 4))
        try fixture.grant(anchor, [.observe])
        try fixture.grant(nestedAnchor, [.observe])

        XCTAssertEqual(fixture.admit(overseer, target: .unplacedSession(anchor)), .targetAnchorsScope, "a scope root is never grafted")
        XCTAssertEqual(fixture.admit(worker, target: .unplacedSession(anchor)), .targetAnchorsScope, "nor by a worker inside the scope")
        XCTAssertEqual(fixture.admit(overseer, target: .unplacedSession(holder)), .targetAnchorsScope, "nor a tree that holds a scope")
        XCTAssertEqual(
            fixture.admit(stranger, target: .unplacedSession(anchor)), .unscoped,
            "an unscoped creator moves no scope's membership"
        )

        // overseer + worker are live; the loose tree (its idle root is about to run) adds three to a
        // limit of four. `current` is the scope's own count.
        fixture.provenance.add(loose, parent: nil, live: false)
        XCTAssertEqual(
            fixture.admit(overseer, target: .unplacedSession(loose)),
            .denied(.guardrailExceeded(guardrail: .maxLiveSessions, limit: 4, current: 2))
        )
        guard case let .admitted(admission) = fixture.admit(overseer, target: .unplacedSession(single)) else {
            return XCTFail("a single unplaced session fits")
        }
        XCTAssertEqual(admission.reservation.sessions, 1)
        fixture.runtime.release(admission.reservation)

        // A joining subtree's bound worktrees count against `maxWorktrees` too.
        let busyRoot = UUID()
        fixture.provenance.add(busyRoot, parent: nil, worktrees: ["w1", "w2"])
        try fixture.grant(worker, [.observe], guardrails: .init(maxWorktrees: 1))
        XCTAssertEqual(
            fixture.admit(worker, target: .unplacedSession(busyRoot)),
            .denied(.guardrailExceeded(guardrail: .maxWorktrees, limit: 1, current: 0))
        )
    }

    /// Review S3: a `.workspace` scope's guardrails bound only its grantee and the sessions stamped
    /// with it, never an unrelated session that merely lives in the workspace.
    func testWorkspaceScopeGuardrailsBoundOnlyItsDelegatedSessions() throws {
        let fixture = Fixture()
        let workspace = UUID(), grantee = UUID(), unrelated = UUID(), delegated = UUID()
        fixture.provenance.add(grantee, parent: nil, workspace: workspace)
        fixture.provenance.add(unrelated, parent: nil, workspace: workspace)
        let scope = try fixture.grant(
            grantee, [.observe], kind: .workspace(workspaceID: workspace), guardrails: .init(maxLiveSessions: 2)
        )
        fixture.provenance.add(delegated, parent: grantee, workspace: workspace, scope: scope.id)
        let child = UUID(), grandchild = UUID(), unrelatedChild = UUID()
        fixture.provenance.add(child, parent: grantee, workspace: workspace)
        fixture.provenance.add(grandchild, parent: delegated, workspace: workspace)
        fixture.provenance.add(unrelatedChild, parent: unrelated, workspace: workspace)
        let atLimit = DelegationSpawnAdmission.Outcome.denied(.guardrailExceeded(guardrail: .maxLiveSessions, limit: 2, current: 6))
        XCTAssertEqual(fixture.admit(unrelated), .unscoped, "an unrelated session can still agent_run start")
        XCTAssertEqual(fixture.admit(unrelatedChild), .unscoped, "and so can its own descendants")
        XCTAssertEqual(fixture.admit(grantee), atLimit)
        XCTAssertEqual(fixture.admit(delegated), atLimit, "a session stamped with the scope is bounded by it")
        XCTAssertEqual(fixture.admit(child), atLimit, "the grantee's unstamped descendants cannot escape the limit")
        XCTAssertEqual(fixture.admit(grandchild), atLimit, "nor can a stamped session's descendants")
    }

    /// Review S2: `fork` and `worktree_create` count toward every scope the caller's creations join,
    /// not only the caller's own chain: a worker with its own unlimited scope inside an overseer's
    /// limited tree is bounded by the overseer's limits.
    func testForkAndWorktreeCreateHonorEveryScopeTheyCountToward() async throws {
        let fixture = Fixture()
        let overseer = UUID(), worker = UUID(), member = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(worker, parent: overseer)
        fixture.provenance.add(member, parent: worker, worktrees: ["w0"])
        try fixture.grant(overseer, [.observe], guardrails: .init(maxLiveSessions: 3, maxWorktrees: 1))
        try fixture.grant(worker)

        let fork = try await fixture.value(.adminFork, caller: worker, targets: [member], key: "fork-1")
        XCTAssertEqual(fork["code"], .string("scope_guardrail_exceeded"))
        XCTAssertEqual(fork["guardrail"], .string("max_live_sessions"))
        XCTAssertTrue(fixture.structure.forkCalls.isEmpty)

        let worktree = try await fixture.value(.adminWorktreeCreate, caller: worker, targets: [member])
        XCTAssertEqual(worktree["code"], .string("scope_guardrail_exceeded"))
        XCTAssertEqual(worktree["guardrail"], .string("max_worktrees"))
        XCTAssertTrue(fixture.worktrees.created.isEmpty)
    }

    /// Review M1: two concurrent cross re-parents (A under B, B under A) both pass preflight, but each
    /// item's final check and its in-memory write are one synchronous step: one is refused as a cycle
    /// and no cycle forms.
    func testConcurrentCrossReparentsCannotFormACycle() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), b = UUID(), x = UUID(), y = UUID()
        fixture.provenance.add(overseer, parent: nil)
        for id in [a, b, x, y] {
            fixture.provenance.add(id, parent: overseer)
        }
        try fixture.grant(overseer)
        // Every durable write suspends, so the two batches interleave item by item.
        fixture.structure.onPersist = {
            for _ in 0 ..< 5 {
                await Task.yield()
            }
        }
        async let first = fixture.value(
            .adminReparent, caller: overseer, targets: [x, a], args: ["parent_session_id": .string(b.uuidString)]
        )
        async let second = fixture.value(
            .adminReparent, caller: overseer, targets: [y, b], args: ["parent_session_id": .string(a.uuidString)]
        )
        let replies = try await [first, second]
        XCTAssertTrue(replies.flatMap(codes).contains("placement_cycle"), "\(replies)")
        let movedEndpoints = Set(fixture.structure.placements.map(\.session)).intersection([a, b])
        XCTAssertEqual(movedEndpoints.count, 1, "exactly one of the cross moves applies")
        XCTAssertNotNil(fixture.projector.organizationalAncestry(of: a), "no cycle formed")
        XCTAssertNotNil(fixture.projector.organizationalAncestry(of: b), "no cycle formed")
    }

    /// Review M1: two approved adopts racing for the last slot under `maxLiveSessions`: the second
    /// sees the first adoptee as a member (and its reservation) at its final check, so only one applies.
    func testConcurrentAdoptsAtTheLimitApplyOnlyOne() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID(), p = UUID(), q = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        fixture.provenance.add(p, parent: nil)
        fixture.provenance.add(q, parent: nil)
        let scope = try fixture.grant(overseer, guardrails: .init(maxLiveSessions: 3))
        var cards: [UUID: UUID] = [:]
        for (adoptee, key) in [(p, "adopt-p"), (q, "adopt-q")] {
            guard case let .pendingConfirmation(card, _) = try await fixture.perform(
                .adminAdopt, caller: overseer, targets: [adoptee], key: key
            ) else { return XCTFail("adopt always raises a card, and each fits the limit on its own") }
            XCTAssertNotNil(fixture.runtime.confirmations.approve(confirmationID: card.id))
            cards[adoptee] = card.id
        }
        fixture.structure.onPersist = {
            for _ in 0 ..< 5 {
                await Task.yield()
            }
        }
        let cardP = cards[p], cardQ = cards[q]
        async let first = fixture.value(.adminAdopt, caller: overseer, targets: [p], key: "adopt-p", confirmation: cardP)
        async let second = fixture.value(.adminAdopt, caller: overseer, targets: [q], key: "adopt-q", confirmation: cardQ)
        let replies = try await [first, second]
        XCTAssertEqual(fixture.structure.placements.count, 1, "only one adoption fits the limit: \(replies)")
        XCTAssertTrue(replies.flatMap(codes).contains("scope_guardrail_exceeded"), "\(replies)")
        XCTAssertEqual(fixture.projector.usage(of: scope.grant, spawnParentSessionID: nil).liveSessionCount, 3)
        XCTAssertEqual(
            fixture.runtime.usageIncludingReservations(fixture.projector.usage(of: scope.grant, spawnParentSessionID: nil))
                .liveSessionCount,
            3,
            "adopt reservations are released once placement is durable"
        )
    }

    /// M2: a `.workspace` caller cannot re-parent a session whose organizational parent lives in a
    /// closed workspace: a scope could be rooted there.
    func testWorkspaceCallerCannotReparentAcrossAnUnloadedWorkspace() async throws {
        let fixture = Fixture()
        let workspace = UUID(), caller = UUID(), source = UUID(), destination = UUID(), closedParent = UUID()
        fixture.provenance.add(caller, parent: nil, workspace: workspace)
        fixture.provenance.add(source, parent: closedParent, workspace: workspace)
        fixture.provenance.add(destination, parent: nil, workspace: workspace)
        try fixture.grant(caller, [.observe, .restructure], kind: .workspace(workspaceID: workspace))
        let reply = try await fixture.value(
            .adminReparent, caller: caller, targets: [source], args: ["parent_session_id": .string(destination.uuidString)]
        )
        XCTAssertEqual(reply["code"], .string("placement_unresolved"))
        XCTAssertTrue(fixture.structure.placements.isEmpty)
    }

    func testAdoptThroughAnUnloadedSessionIsUnresolved() async throws {
        let fixture = Fixture()
        let overseer = UUID(), adoptee = UUID(), unloadedParent = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(adoptee, parent: unloadedParent)
        try fixture.grant(overseer)
        let reply = try await fixture.value(.adminAdopt, caller: overseer, targets: [adoptee], key: "a")
        XCTAssertEqual(reply["code"], .string("placement_unresolved"))
        XCTAssertTrue(fixture.runtime.confirmations.confirmations.isEmpty, "refused before any card")
    }

    /// M3: the card lists every session that moves, with names and run state; a descendant the user
    /// unticks keeps its parent from moving.
    func testAdoptCardListsTheWholeSubtreeAndHonorsUnticks() async throws {
        let fixture = Fixture()
        let overseer = UUID(), adoptee = UUID(), child = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(adoptee, parent: nil)
        fixture.provenance.add(child, parent: adoptee, state: .running)
        fixture.names.map = [adoptee: "Research", child: "Worker"]
        try fixture.grant(overseer)
        guard case let .pendingConfirmation(card, _) = try await fixture.perform(
            .adminAdopt, caller: overseer, targets: [adoptee], key: "adopt-tree"
        ) else { return XCTFail("adopt is carded") }
        XCTAssertEqual(card.items.map(\.sessionID), [adoptee, child])
        XCTAssertEqual(card.items.map(\.title), ["Research", "Worker (running)"])
        XCTAssertTrue(card.items[1].effect.contains("Moves with Research"))

        fixture.runtime.confirmations.setItem(child, ticked: false, confirmationID: card.id)
        XCTAssertNotNil(fixture.runtime.confirmations.approve(confirmationID: card.id))
        let reply = try await fixture.value(.adminAdopt, caller: overseer, targets: [adoptee], key: "adopt-tree", confirmation: card.id)
        XCTAssertEqual(items(reply)[adoptee.uuidString]?["code"], .string("subtree_not_approved"))
        XCTAssertTrue(fixture.structure.placements.isEmpty)
    }

    func testAdoptRefusesScopeAnchorsAndPostAdoptGuardrailsBeforeAnyCard() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID(), otherOverseer = UUID(), adoptee = UUID(), adopteeChild = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        fixture.provenance.add(otherOverseer, parent: nil)
        fixture.provenance.add(adoptee, parent: nil)
        fixture.provenance.add(adopteeChild, parent: adoptee)
        try fixture.grant(overseer, guardrails: .init(maxLiveSessions: 3))
        try fixture.grant(otherOverseer, [.observe])

        let anchor = try await fixture.value(.adminAdopt, caller: overseer, targets: [otherOverseer], key: "anchor")
        XCTAssertEqual(anchor["code"], .string("adopt_target_anchors_scope"))

        // Two live members plus a live adoptee and its live child would be four.
        let limited = try await fixture.value(.adminAdopt, caller: overseer, targets: [adoptee], key: "limit")
        XCTAssertEqual(limited["code"], .string("scope_guardrail_exceeded"))
        XCTAssertEqual(limited["guardrail"], .string("max_live_sessions"))
        XCTAssertTrue(fixture.runtime.confirmations.confirmations.isEmpty)
    }

    func testReparentEnforcesMaxDepthOnTheMovedSubtree() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), a1 = UUID(), b = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(a, parent: overseer)
        fixture.provenance.add(a1, parent: a)
        fixture.provenance.add(b, parent: overseer)
        try fixture.grant(overseer, guardrails: .init(maxDepth: 2))
        let reply = try await fixture.value(.adminReparent, caller: overseer, targets: [a], args: ["parent_session_id": .string(b.uuidString)])
        XCTAssertEqual(reply["code"], .string("scope_guardrail_exceeded"))
        XCTAssertEqual(reply["guardrail"], .string("max_depth"))
        XCTAssertEqual(reply["current"], .int(3))
        XCTAssertTrue(fixture.structure.placements.isEmpty)
    }

    /// S1: authority (lease and membership) is re-checked at the write itself, for immediate and
    /// deferred binds.
    func testBindsRecheckLeaseAndMembershipAtTheWrite() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID(), queued = UUID(), outsideRoot = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        fixture.provenance.add(queued, parent: overseer)
        fixture.provenance.add(outsideRoot, parent: nil)
        let scope = try fixture.grant(overseer)

        // A deferred bind whose target leaves the scope before its idle boundary never applies.
        fixture.worktrees.idle[queued] = false
        _ = try await fixture.value(
            .adminWorktreeBind, caller: overseer, targets: [queued], args: ["worktree": .string("w-q"), "apply": .string("next_boundary")]
        )
        fixture.provenance.add(queued, parent: overseer, org: outsideRoot)
        fixture.worktrees.becomeIdle(queued)
        await fixture.worktreeHandler.settleDeferredBinds()
        XCTAssertEqual(fixture.worktreeHandler.deferredOutcomes[queued], .revoked)

        // A revocation landing mid-await (inside the host, before the write) stops the bind.
        fixture.worktrees.beforeWrite = { fixture.runtime.revoke(scopeID: scope.id) }
        let reply = try await fixture.value(.adminWorktreeBind, caller: overseer, targets: [member], args: ["worktree": .string("w1")])
        XCTAssertEqual(items(reply)[member.uuidString]?["code"], .string("scope_revoked"))
        XCTAssertTrue(fixture.worktrees.bindCalls.isEmpty)
    }

    /// S3: binding a released worktree clears its stale mark, and inventory judges `unbound` and
    /// `released` against every loaded session's bindings.
    func testBindClearsTheStaleMarkAndInventoryCountsBindingsOutsideTheScope() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID(), elsewhere = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        try fixture.grant(overseer)
        fixture.ownership.markReleased([WorktreeHost.summary("w-old")], bySessionID: overseer, at: Date())
        _ = try await fixture.value(.adminWorktreeBind, caller: overseer, targets: [member], args: ["worktree": .string("w-old")])
        XCTAssertNil(fixture.ownership.record(worktreeID: "w-old")?.releasedAt)

        _ = try await fixture.value(.adminWorktreeCreate, caller: overseer, targets: [member])
        fixture.ownership.markReleased([WorktreeHost.summary("wt-1")], bySessionID: overseer, at: Date())
        fixture.worktrees.boundElsewhere["wt-1"] = [elsewhere]
        let inventory = try await fixture.value(.adminWorktreeInventory, caller: overseer)
        let row = try XCTUnwrap(inventory["worktrees"]?.arrayValue?.compactMap(\.objectValue).first { $0["worktree_id"] == .string("wt-1") })
        XCTAssertEqual(row["stale_flags"], .array([]), "bound elsewhere: neither unbound nor released")
        XCTAssertEqual(row["bound_session_ids"], .array([]), "a non-member is never named")
        XCTAssertNil(row["bound_outside_scope_count"], "scope-restricted: sessions outside the scope are not counted either")
        XCTAssertFalse(String(describing: inventory).contains(elsewhere.uuidString))
    }

    func testUnlinkStopsThroughTheBridgeAndRechecksBeforeTheStop() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), b = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(a, parent: overseer)
        fixture.provenance.add(b, parent: overseer)
        let scope = try fixture.grant(overseer)
        fixture.structure.links[Pair(observer: overseer, target: a)] = DomainAgentSessionLinkCapability.managed
        fixture.structure.links[Pair(observer: overseer, target: b)] = DomainAgentSessionLinkCapability.managed
        let first = try await fixture.value(.adminUnlink, caller: overseer, targets: [a])
        XCTAssertEqual(items(first)[a.uuidString]?["result"], .string("unlinked"))
        XCTAssertEqual(fixture.structure.stopped, [Pair(observer: overseer, target: a)])

        // Review S4: the target leaving the scope during the lookup (a membership change, not a
        // revocation) also stops the unlink.
        let c = UUID(), outside = UUID()
        fixture.provenance.add(c, parent: overseer)
        fixture.provenance.add(outside, parent: nil)
        fixture.structure.links[Pair(observer: overseer, target: c)] = DomainAgentSessionLinkCapability.managed
        fixture.structure.onActiveLink = { fixture.provenance.add(c, parent: overseer, org: outside) }
        let moved = try await fixture.value(.adminUnlink, caller: overseer, targets: [c])
        XCTAssertEqual(items(moved)[c.uuidString]?["code"], .string("link_failed"))
        XCTAssertNotNil(fixture.structure.links[Pair(observer: overseer, target: c)], "a non-member's link is not stopped")

        fixture.structure.onActiveLink = { fixture.runtime.revoke(scopeID: scope.id) }
        let second = try await fixture.value(.adminUnlink, caller: overseer, targets: [b])
        XCTAssertEqual(items(second)[b.uuidString]?["code"], .string("link_failed"))
        XCTAssertNotNil(fixture.structure.links[Pair(observer: overseer, target: b)], "nothing was stopped")
    }

    func testLinkAboveTheThresholdRaisesOneCard() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), b = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(a, parent: overseer)
        fixture.provenance.add(b, parent: overseer)
        try fixture.grant(overseer, guardrails: .init(bulkConfirmationThreshold: 1))
        guard case let .pendingConfirmation(card, _) = try await fixture.perform(
            .adminLink, caller: overseer, targets: [a, b], key: "bulk-link"
        ) else { return XCTFail("two links over a threshold of one are carded") }
        XCTAssertEqual(card.reason, .bulkThreshold)
        XCTAssertEqual(Set(card.items.map(\.sessionID)), [a, b])
        XCTAssertTrue(fixture.structure.added.isEmpty)
    }

    func testForkReplayIsBoundToTheCutoffAndReportsJoinedScope() async throws {
        let fixture = Fixture()
        let overseer = UUID(), member = UUID(), cutoff = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(member, parent: overseer)
        try fixture.grant(overseer)
        let args: [String: Value] = ["up_to_item_id": .string(cutoff.uuidString)]
        _ = try await fixture.value(.adminFork, caller: overseer, targets: [member], args: args, key: "k")
        let replay = try await fixture.value(.adminFork, caller: overseer, targets: [member], args: args, key: "k")
        XCTAssertEqual(replay["result"], .string("replayed"))
        XCTAssertEqual(replay["joined_scope"], .bool(true))
        let other = try await fixture.value(.adminFork, caller: overseer, targets: [member], key: "k")
        XCTAssertEqual(other["result"], .string("idempotency_conflict"), "a different cutoff is a different fork")
        XCTAssertEqual(fixture.structure.forkCalls.count, 1)
    }

    func testWorktreeOwnershipStoreBlocksFutureSchemaAndQuarantinesCorruptFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wt-ownership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(WorktreeOwnershipStore.filename)
        let backups = directory.appendingPathComponent("Backups")

        try Data(#"{"version": 99, "worktrees": []}"#.utf8).write(to: fileURL)
        let future = WorktreeOwnershipStore()
        await future.bootstrap(fileURL: fileURL, backupsDirectoryURL: backups)
        XCTAssertEqual(future.loadState, .blocked("unsupported_future_schema"))
        future.markReleased([WorktreeHost.summary("w")], bySessionID: UUID(), at: Date())
        await future.flushPersistence()
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), #"{"version": 99, "worktrees": []}"#, "a future file is preserved")

        try Data("not json".utf8).write(to: fileURL)
        let corrupt = WorktreeOwnershipStore()
        await corrupt.bootstrap(fileURL: fileURL, backupsDirectoryURL: backups)
        XCTAssertEqual(corrupt.loadState, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
    }

    /// The pre-load stale mark is merged onto the durable ownership row, never lost.
    func testWorktreeOwnershipStoreMergesAPreLoadReleaseOntoTheDurableRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wt-ownership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(WorktreeOwnershipStore.filename)
        let creator = UUID()
        let first = WorktreeOwnershipStore()
        await first.bootstrap(fileURL: fileURL, backupsDirectoryURL: nil)
        first.recordCreation(
            SessionAdminWorktreeInfo(worktreeID: "w1", repositoryID: "r", repoRootPath: "/r", path: "/m/w1", branch: nil, isPrunable: false),
            createdBySessionID: creator, delegationScopeID: UUID(), at: Date(timeIntervalSince1970: 100)
        )
        await first.flushPersistence()

        let second = WorktreeOwnershipStore()
        second.markReleased([WorktreeHost.summary("w1")], bySessionID: creator, at: Date(timeIntervalSince1970: 200))
        await second.bootstrap(fileURL: fileURL, backupsDirectoryURL: nil)
        let row = try XCTUnwrap(second.record(worktreeID: "w1"))
        XCTAssertEqual(row.createdBySessionID, creator, "the durable creator survives")
        XCTAssertEqual(row.releasedAt, Date(timeIntervalSince1970: 200), "the pre-load release survives")
    }

    /// Production wiring: structure ops registered through Lane B's front door get filter targeting,
    /// preview (which runs preflight), and apply-on-approval.
    func testStructureOpsThroughTheProductionFrontDoor() async throws {
        typealias Organizing = SessionAdminOrganizingOperationTests
        let overseer = UUID(), a = UUID(), b = UUID(), outsider = UUID(), workspace = UUID()
        let provenance = Provenance()
        let inventoryProvenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        let organizer = Organizing.FakeOrganizer()
        let links = Organizing.FakeLinks()
        for (id, parent) in [(overseer, nil), (a, overseer), (b, overseer), (outsider, nil)] as [(UUID, UUID?)] {
            provenance.add(id, parent: parent, workspace: workspace)
            inventoryProvenance.add(id, parent: parent, workspace: workspace)
            organizer.add(id, workspace: workspace, name: id == outsider ? "Outsider" : "Member")
        }
        let runtime = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: core, scopes: runtime, projector: projector,
            inventory: Organizing.FakeInventory(organizer: organizer, provenance: inventoryProvenance, links: links, now: Date())
        )
        frontDoor.registerOrganizingHandlers(backend: organizer, links: links)
        let host = StructureHost(provenance: provenance)
        let worktreeHost = WorktreeHost()
        frontDoor.registerStructureHandlers(
            scopes: runtime, worktreeOwnership: WorktreeOwnershipStore(), projector: projector,
            structureHost: host, worktreeHost: worktreeHost
        )
        let request = try runtime.requestScope(
            requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
            capabilities: DomainDelegationScopeCapability.manageTreePreset, guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        _ = try runtime.approve(requestID: request.id).get()
        func perform(
            _ operation: DomainAgentSessionTargetOperation,
            targets: [UUID] = [],
            args: [String: Value] = [:],
            key: String? = nil,
            preview: Bool = false
        ) async throws -> AgentSessionAdministrationOutcome {
            try await frontDoor.perform(.init(
                operation: operation, caller: .agentSession(overseer), targetSessionIDs: targets,
                idempotencyKey: key, preview: preview, arguments: args
            ))
        }

        // Preview runs the handler preflight: the refusal a real call would return.
        guard case let .completed(previewed) = try await perform(
            .adminLink, targets: [b], args: ["observer_session_id": .string(a.uuidString)], preview: true
        ) else { return XCTFail("preview completes") }
        XCTAssertEqual(previewed.objectValue?["code"], .string("observer_must_be_caller"))

        // Filter targeting: every loaded member except the caller (control never targets itself).
        guard case .completed = try await perform(
            .adminSetModel, args: ["filter": .object(["workspace": .string(workspace.uuidString)]), "model_id": .string("claudeCode:opus")]
        ) else { return XCTFail("filtered set_model completes") }
        XCTAssertEqual(Set(host.modelCalls.map(\.0)), [a, b])

        // Apply-on-approval: the approved adopt card applies without a second call.
        guard case let .pendingConfirmation(card, _) = try await perform(.adminAdopt, targets: [outsider], key: "adopt") else {
            return XCTFail("adopt is carded")
        }
        await frontDoor.approveAndApply(confirmationID: card.id)
        XCTAssertEqual(host.placements.single?.session, outsider)
        XCTAssertEqual(host.placements.single?.parent, overseer)
        XCTAssertNotNil(frontDoor.appliedResult(forConfirmation: card.id))

        // The front door's idempotency ledger replays a changed result: a retry never creates twice.
        guard case let .completed(created) = try await perform(.adminWorktreeCreate, targets: [a], key: "wc"),
              case let .completed(replayed) = try await perform(.adminWorktreeCreate, targets: [a], key: "wc")
        else { return XCTFail("worktree_create completes") }
        XCTAssertEqual(created.objectValue?["changed_count"], .int(1))
        XCTAssertEqual(replayed.objectValue?["idempotent_replay"], .bool(true))
        XCTAssertEqual(worktreeHost.created.count, 1)
    }

    /// The user's adopt card lists the whole subtree; every agent-facing reply (preview,
    /// pending_confirmation, confirmation_status before and after apply, confirmation_mismatch) shows
    /// only the adoptee the caller named, its descendant count, and aggregates — never an outside
    /// descendant's ID or title.
    func testAgentFacingAdoptRepliesNeverRevealOutsideDescendants() async throws {
        typealias Organizing = SessionAdminOrganizingOperationTests
        let overseer = UUID(), adoptee = UUID(), child = UUID(), grandchild = UUID(), other = UUID(), workspace = UUID()
        let provenance = Provenance()
        let inventoryProvenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        let organizer = Organizing.FakeOrganizer()
        let links = Organizing.FakeLinks()
        let tree: [(UUID, UUID?, DomainDelegationScopeTargetState, String)] = [
            (overseer, nil, .idle, "Overseer"), (adoptee, nil, .idle, "Research"),
            (child, adoptee, .running, "SecretWorker"), (grandchild, child, .idle, "SecretGrandchild"),
            (other, nil, .idle, "Other")
        ]
        let names = Names()
        for (id, parent, state, name) in tree {
            provenance.add(id, parent: parent, workspace: workspace, state: state)
            inventoryProvenance.add(id, parent: parent, workspace: workspace, state: state)
            organizer.add(id, workspace: workspace, name: name)
            names.map[id] = name
        }
        let runtime = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: core, scopes: runtime, projector: projector,
            inventory: Organizing.FakeInventory(organizer: organizer, provenance: inventoryProvenance, links: links, now: Date())
        )
        var context = SessionAdminHandlerContext(scopes: runtime, projector: projector)
        context.displayName = { names.map[$0] }
        let host = StructureHost(provenance: provenance)
        frontDoor.register(SessionAdminRestructureHandler(context: context, host: host))
        let request = try runtime.requestScope(
            requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
            capabilities: DomainDelegationScopeCapability.manageTreePreset, guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        _ = try runtime.approve(requestID: request.id).get()

        let window = WindowState()
        let endpoint = DomainAgentSessionLinkEndpointIdentity(
            windowID: window.windowID, workspaceID: workspace, tabID: UUID(), sessionID: overseer,
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
        )
        let service = SessionAdminMCPToolService(
            captureRequestMetadata: { .init(connectionID: UUID(), clientName: "adopt-projection-test", windowID: window.windowID) },
            requireTargetWindow: { window },
            resolveObserverEndpoint: { _, _ in endpoint },
            scopes: { runtime },
            administration: { frontDoor }
        )
        var replies: [Value] = []
        func call(_ args: [String: Value]) async throws -> [String: Value] {
            let value = try await service.execute(args: args)
            replies.append(value)
            return try XCTUnwrap(value.objectValue)
        }

        let preview = try await call(["op": .string("adopt"), "session_id": .string(adoptee.uuidString), "preview": .bool(true)])
        XCTAssertEqual(preview["result"], .string("preview"))
        let pending = try await call(["op": .string("adopt"), "session_id": .string(adoptee.uuidString), "idempotency_key": .string("adopt-1")])
        XCTAssertEqual(pending["result"], .string("pending_confirmation"))
        for reply in [preview, pending] {
            let rows = try XCTUnwrap(reply["items"]?.arrayValue?.compactMap(\.objectValue))
            XCTAssertEqual(rows.map { $0["session_id"] }, [.string(adoptee.uuidString)], "only the adoptee the caller named")
            XCTAssertEqual(rows.first?["descendant_count"], .int(2))
            XCTAssertEqual(reply["total_session_count"], .int(3))
            XCTAssertEqual(reply["running_session_count"], .int(1))
        }
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let card = try XCTUnwrap(runtime.confirmations.confirmation(id: cardID, granteeSessionID: overseer))
        XCTAssertEqual(card.items.map(\.sessionID), [adoptee, child, grandchild], "the user's card keeps the whole subtree")
        XCTAssertEqual(card.items.map(\.title), ["Research", "SecretWorker (running)", "SecretGrandchild"])
        _ = try await call(["op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)])

        // A mismatching repeat of an approved card reports approved adoptees only.
        let second = try await call(["op": .string("adopt"), "session_id": .string(adoptee.uuidString), "idempotency_key": .string("adopt-2")])
        let secondID = try XCTUnwrap(second["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        XCTAssertNotNil(runtime.confirmations.approve(confirmationID: secondID))
        let mismatch = try await call([
            "op": .string("adopt"), "targets": .array([.string(adoptee.uuidString), .string(other.uuidString)]),
            "idempotency_key": .string("adopt-2"), "confirmation_id": .string(secondID.uuidString)
        ])
        XCTAssertEqual(mismatch["code"], .string("confirmation_mismatch"))
        XCTAssertEqual(mismatch["approved_session_ids"], .array([.string(adoptee.uuidString)]))

        // After the user approves (with a descendant unticked), the applied result names the adoptee only.
        runtime.confirmations.setItem(child, ticked: false, confirmationID: cardID)
        await frontDoor.approveAndApply(confirmationID: cardID)
        let applied = try await call(["op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)])
        XCTAssertNotNil(applied["applied_result"])

        let rendered = replies.map { String(describing: $0) }.joined(separator: "\n")
        for secret in [child.uuidString, grandchild.uuidString, "SecretWorker", "SecretGrandchild"] {
            XCTAssertFalse(rendered.contains(secret), "agent-facing adopt replies must not reveal \(secret)")
        }
        XCTAssertTrue(rendered.contains(adoptee.uuidString))
    }

    /// A descendant already in the caller's scope is shown normally; one outside it is only counted.
    func testAdoptProjectionShowsMemberDescendantsAndCountsOutsideOnes() {
        let adoptee = UUID(), member = UUID(), outside = UUID()
        let items = [
            BatchConfirmationItem(sessionID: adoptee, title: "Research", effect: "Bring into this delegation scope under Overseer"),
            BatchConfirmationItem(sessionID: member, title: "KnownWorker", effect: "Moves with Research (descendant)"),
            BatchConfirmationItem(sessionID: outside, title: "SecretWorker", effect: "Moves with Research (descendant)")
        ]
        let layout = SessionAdminAdoptCardProjection.Layout(
            adoptees: [adoptee], descendantsByAdoptee: [adoptee: [member, outside]],
            runningSessionIDs: [outside], memberDescendants: [member]
        )
        let rows = SessionAdminAdoptCardProjection.agentItems(items, layout: layout, approved: [adoptee, member])
            .compactMap(\.objectValue)
        XCTAssertEqual(rows.map { $0["session_id"] }, [.string(adoptee.uuidString), .string(member.uuidString)])
        XCTAssertEqual(rows[0]["descendant_count"], .int(2))
        XCTAssertEqual(rows[0]["all_descendants_approved"], .bool(false))
        XCTAssertNil(rows[0]["title"], "the adoptee's title is not the caller's to see")
        XCTAssertEqual(rows[1]["title"], .string("KnownWorker"))
        XCTAssertEqual(rows[1]["moves_with_session_id"], .string(adoptee.uuidString))
        XCTAssertEqual(layout.visibleSessionIDs, [adoptee, member])
        let aggregates = SessionAdminAdoptCardProjection.aggregates(items, layout: layout)
        XCTAssertEqual(aggregates["total_session_count"], .int(3))
        XCTAssertEqual(aggregates["running_session_count"], .int(1))
        let rendered = String(describing: Value.array(rows.map(Value.object)))
        XCTAssertFalse(rendered.contains(outside.uuidString))
        XCTAssertFalse(rendered.contains("SecretWorker"))
        XCTAssertFalse(rendered.contains("Research"))
    }

    func testWorktreeOwnershipStoreRoundTripsAndMarksReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wt-ownership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(WorktreeOwnershipStore.filename)
        let store = WorktreeOwnershipStore()
        await store.bootstrap(fileURL: fileURL, backupsDirectoryURL: directory.appendingPathComponent("Backups"))
        let creator = UUID(), scope = UUID()
        store.recordCreation(
            SessionAdminWorktreeInfo(worktreeID: "w1", repositoryID: "r", repoRootPath: "/r", path: "/m/w1", branch: "b", isPrunable: false),
            createdBySessionID: creator, delegationScopeID: scope, at: Date(timeIntervalSince1970: 100)
        )
        store.markReleased([WorktreeHost.summary("w1")], bySessionID: creator, at: Date(timeIntervalSince1970: 200))
        await store.flushPersistence()
        XCTAssertTrue(store.ownedUnreleasedWorktreeIDs(createdBy: [creator]).isEmpty)

        let reloaded = WorktreeOwnershipStore()
        await reloaded.bootstrap(fileURL: fileURL, backupsDirectoryURL: nil)
        let row = try XCTUnwrap(reloaded.record(worktreeID: "w1"))
        XCTAssertEqual(row.createdBySessionID, creator)
        XCTAssertEqual(row.delegationScopeID, scope)
        XCTAssertEqual(row.releasedAt, Date(timeIntervalSince1970: 200))
    }
}

// MARK: - Organizing operations (Lane B)

/// `session_admin` inventory, organize, release, batch cards, idempotency, CAS, and undo, driven over
/// MCP through the front door with in-memory backends.
@MainActor
final class SessionAdminOrganizingOperationTests: XCTestCase {
    typealias FakeProvenance = SessionAdminScopeLifecycleTests.FakeProvenance

    @MainActor
    final class FakeOrganizer: AgentSessionOrganizingBackend {
        var states: [UUID: AgentSessionOrganizeState] = [:]
        var stopped: [UUID] = []
        /// Every session whose stored state any write touched, in order.
        var written: [UUID] = []
        /// Archive calls; each re-checks authorization inside the stash's mutation context.
        var archiveAuthorizationChecks = 0
        /// Run state of the same session in another window (production aggregates every window).
        var otherWindowRunStates: [UUID: DomainDelegationScopeTargetState] = [:]
        /// Runs inside each per-session stash, at its suspension point before the commit-time check.
        var onStashSuspension: (@MainActor (UUID) -> Void)?

        func add(
            _ id: UUID, workspace: UUID, name: String, pinned: Bool = false, pinnedOrder: Int? = nil,
            group: String? = nil, archived: Bool = false, run: DomainDelegationScopeTargetState = .idle
        ) {
            states[id] = AgentSessionOrganizeState(
                sessionID: id, workspaceID: workspace, tabID: UUID(), name: name, isArchived: archived,
                isPinned: pinned, pinnedOrder: pinnedOrder, sidebarGroup: group, sidebarGroupOrder: group == nil ? nil : 0,
                runState: run
            )
        }

        func state(of sessionID: UUID) -> AgentSessionOrganizeState? {
            states[sessionID]
        }

        func loadedSessionIDs() -> [UUID] {
            Array(states.keys)
        }

        func pinnedSessionOrder(workspaceID: UUID) -> [UUID]? {
            states.values
                .filter { $0.workspaceID == workspaceID && $0.isPinned && !$0.isArchived }
                .sorted { ($0.pinnedOrder ?? .max, $0.sessionID.uuidString) < ($1.pinnedOrder ?? .max, $1.sessionID.uuidString) }
                .map(\.sessionID)
        }

        func groupEntries(workspaceID: UUID) -> [(sessionID: UUID, group: String, order: Int?)]? {
            states.values.compactMap { state in
                guard state.workspaceID == workspaceID, !state.isArchived, let group = state.sidebarGroup else { return nil }
                return (state.sessionID, group, state.sidebarGroupOrder)
            }
        }

        func rename(_ sessionID: UUID, to name: String) -> Bool {
            states[sessionID]?.name = name
            return true
        }

        func setPinned(_ pinned: Bool, sessionIDs: [UUID]) -> Set<UUID> {
            var changed: Set<UUID> = []
            for id in sessionIDs where states[id]?.isPinned != pinned {
                states[id]?.isPinned = pinned
                if !pinned { states[id]?.pinnedOrder = nil }
                changed.insert(id)
            }
            return changed
        }

        func setPinnedRanks(_ ranks: [UUID: Int?]) -> Set<UUID> {
            var changed: Set<UUID> = []
            for (id, rank) in ranks where states[id]?.isPinned == true && states[id]?.isArchived == false {
                guard states[id]?.pinnedOrder != rank else { continue }
                states[id]?.pinnedOrder = rank
                written.append(id)
                changed.insert(id)
            }
            return changed
        }

        func setGroup(_ group: String?, order: Int?, sessionIDs: [UUID]) -> Set<UUID> {
            var changed: Set<UUID> = []
            for id in sessionIDs
                where states[id]?.sidebarGroup != group || states[id]?.sidebarGroupOrder != (group == nil ? nil : order)
            {
                states[id]?.sidebarGroup = group
                states[id]?.sidebarGroupOrder = group == nil ? nil : order
                written.append(id)
                changed.insert(id)
            }
            return changed
        }

        func setGroupOrderValues(_ values: [UUID: Int?]) -> Set<UUID> {
            var changed: Set<UUID> = []
            for (id, value) in values where states[id]?.sidebarGroup != nil && states[id]?.sidebarGroupOrder != value {
                states[id]?.sidebarGroupOrder = value
                written.append(id)
                changed.insert(id)
            }
            return changed
        }

        func runState(of sessionID: UUID) -> DomainDelegationScopeTargetState {
            let observed = [states[sessionID]?.runState ?? .unknown, otherWindowRunStates[sessionID] ?? .idle]
            if observed.contains(.running) { return .running }
            return observed.contains(.unknown) ? .unknown : .idle
        }

        func archive(_ sessionIDs: [UUID], isAuthorized: @escaping @MainActor (UUID) -> Bool) async -> Set<UUID> {
            var changed: Set<UUID> = []
            for id in sessionIDs where states[id]?.isArchived == false {
                // Like the real stash: a suspension (preflight), then the commit-time context check.
                onStashSuspension?(id)
                await Task.yield()
                archiveAuthorizationChecks += 1
                guard isAuthorized(id) else { continue }
                states[id]?.isArchived = true
                changed.insert(id)
            }
            return changed
        }

        func unarchive(_ sessionIDs: [UUID]) -> Set<UUID> {
            var changed: Set<UUID> = []
            for id in sessionIDs where states[id]?.isArchived == true {
                states[id]?.isArchived = false
                changed.insert(id)
            }
            return changed
        }

        func stopRun(_ sessionID: UUID) async -> Bool {
            stopped.append(sessionID)
            states[sessionID]?.runState = .idle
            return true
        }
    }

    @MainActor
    final class FakeInventory: AgentSessionInventorySource {
        unowned let organizer: FakeOrganizer
        unowned let provenance: FakeProvenance
        unowned let links: FakeLinks
        var historyOnly: [DomainAgentSessionInventoryRecord] = []
        var idleDays: [UUID: Double] = [:]
        var creators: [UUID: UUID] = [:]
        let now: Date

        init(organizer: FakeOrganizer, provenance: FakeProvenance, links: FakeLinks, now: Date) {
            self.organizer = organizer
            self.provenance = provenance
            self.links = links
            self.now = now
        }

        func snapshot() async -> DomainAgentSessionInventorySnapshot {
            let loaded = organizer.states.values.map { state in
                DomainAgentSessionInventoryRecord(
                    sessionID: state.sessionID, name: state.name, workspaceID: state.workspaceID, isLoaded: true,
                    isArchived: state.isArchived, isPinned: state.isPinned, pinnedOrder: state.pinnedOrder,
                    sidebarGroup: state.sidebarGroup, sidebarGroupOrder: state.sidebarGroupOrder,
                    runState: state.runState == .idle ? .idle : .running,
                    parentSessionID: provenance.sessions[state.sessionID]?.parentSessionID,
                    createdByOverseerSessionID: creators[state.sessionID],
                    lastActivityAt: now.addingTimeInterval(-(idleDays[state.sessionID] ?? 0) * 86400)
                )
            }
            let edges = DomainAgentSessionInventoryEdge.merge(
                live: links.live.map { ($0.observerSessionID, $0.targetSessionID, $0.linkID, $0.generation) },
                persisted: links.persisted.map { ($0.observerSessionID, $0.targetSessionID) }
            )
            return DomainAgentSessionInventorySnapshot(records: loaded + historyOnly, edges: edges, isComplete: true)
        }
    }

    @MainActor
    final class FakeLinks: AgentSessionLinkReleasing {
        var live: [DomainAgentSessionLinkInventoryItem] = []
        var persisted: [AgentSessionOversightIntent] = []
        var stoppedLinkIDs: [UUID] = []
        /// Runs after each stop completes (the stop's suspension), before the next step.
        var afterStop: (@MainActor (DomainAgentSessionLinkInventoryItem) -> Void)?

        func link(_ observer: UUID, _ target: UUID) {
            live.append(DomainAgentSessionLinkInventoryItem(
                linkID: UUID(), generation: 1, observerSessionID: observer, targetSessionID: target,
                displayName: nil, capabilities: [], createdAt: Date()
            ))
            persisted.append(AgentSessionOversightIntent(observerSessionID: observer, targetSessionID: target))
        }

        func oversightInventory() async -> (live: [DomainAgentSessionLinkInventoryItem], persisted: [AgentSessionOversightIntent]) {
            (live, persisted)
        }

        func stopLink(_ item: DomainAgentSessionLinkInventoryItem) async -> AgentMonitorStopOutcome {
            stoppedLinkIDs.append(item.linkID)
            live.removeAll { $0.linkID == item.linkID }
            persisted.removeAll { $0.observerSessionID == item.observerSessionID && $0.targetSessionID == item.targetSessionID }
            afterStop?(item)
            return .stopped
        }
    }

    @MainActor
    private final class Fixture {
        let window = WindowState()
        let runtime = DelegationScopeRuntime(notifyCatalogChanged: { _ in })
        let provenance = FakeProvenance()
        let organizer = FakeOrganizer()
        let links = FakeLinks()
        let inventory: FakeInventory
        let core: AgentSessionAdministrationCore
        let frontDoor: AgentSessionAdministrationFrontDoor
        let overseer = UUID()
        let workspace = UUID()
        let tab = UUID()
        let now = Date()

        init() {
            let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
            core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
            inventory = FakeInventory(organizer: organizer, provenance: provenance, links: links, now: now)
            frontDoor = AgentSessionAdministrationFrontDoor(
                core: core, scopes: runtime, projector: projector, inventory: inventory
            )
            frontDoor.registerOrganizingHandlers(backend: organizer, links: links)
            provenance.add(overseer, parent: nil, workspace: workspace)
            organizer.add(overseer, workspace: workspace, name: "Overseer")
        }

        /// A member session of the overseer's tree.
        @discardableResult
        func member(
            _ name: String, pinned: Bool = false, pinnedOrder: Int? = nil, group: String? = nil,
            archived: Bool = false, run: DomainDelegationScopeTargetState = .idle, parent: UUID? = nil
        ) -> UUID {
            let id = UUID()
            provenance.add(id, parent: parent ?? overseer, workspace: workspace, state: run)
            organizer.add(
                id,
                workspace: workspace,
                name: name,
                pinned: pinned,
                pinnedOrder: pinnedOrder,
                group: group,
                archived: archived,
                run: run
            )
            return id
        }

        func outsider(_ name: String) -> UUID {
            let id = UUID()
            provenance.add(id, parent: UUID(), workspace: workspace)
            organizer.add(id, workspace: workspace, name: name)
            return id
        }

        @discardableResult
        func grant(
            _ capabilities: Set<DomainDelegationScopeCapability> = DomainDelegationScopeCapability.manageTreePreset,
            threshold: Int = 25
        ) throws -> DomainDelegationScopeRecord {
            let request = try runtime.requestScope(
                requesterSessionID: overseer, requesterTabID: tab, kind: .tree(rootSessionID: overseer),
                capabilities: capabilities, guardrails: .init(bulkConfirmationThreshold: threshold),
                reason: nil, idempotencyKey: nil
            ).get()
            return try runtime.approve(requestID: request.id).get()
        }

        func call(_ args: [String: Value]) async throws -> [String: Value] {
            let service = SessionAdminMCPToolService(
                captureRequestMetadata: { .init(connectionID: UUID(), clientName: "organize-test", windowID: self.window.windowID) },
                requireTargetWindow: { self.window },
                resolveObserverEndpoint: { _, _ in
                    DomainAgentSessionLinkEndpointIdentity(
                        windowID: self.window.windowID, workspaceID: self.workspace, tabID: self.tab,
                        sessionID: self.overseer, persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
                    )
                },
                scopes: { self.runtime },
                administration: { self.frontDoor },
                isToolEnabled: { true }
            )
            let value = try await service.execute(args: args)
            return try XCTUnwrap(value.objectValue)
        }
    }

    private func ids(_ values: [UUID]) -> Value {
        .array(values.map { .string($0.uuidString) })
    }

    private func items(_ reply: [String: Value]) -> [String: String] {
        var result: [String: String] = [:]
        for item in reply["items"]?.arrayValue ?? [] {
            if let object = item.objectValue, let id = object["session_id"]?.stringValue {
                result[id] = object["status"]?.stringValue
            }
        }
        return result
    }

    // MARK: - Authority

    func testSetPinActsOnMembersAndDeniesOutsidersAndMissingCapability() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        let outsider = fixture.outsider("X")
        try fixture.grant([.observe, .organize])

        let reply = try await fixture.call(["op": .string("set_pin"), "session_id": .string(a.uuidString), "pinned": .bool(true)])
        XCTAssertEqual(reply["result"], .string("applied"))
        XCTAssertEqual(items(reply)[a.uuidString], "changed")
        XCTAssertEqual(fixture.organizer.states[a]?.isPinned, true)
        XCTAssertNotNil(reply["undo_token"])

        do {
            _ = try await fixture.call(["op": .string("set_pin"), "targets": ids([a, outsider]), "pinned": .bool(false)])
            XCTFail("an outsider is refused with the uniform denial")
        } catch {
            XCTAssertEqual(fixture.organizer.states[a]?.isPinned, true, "a refused batch changes nothing")
        }

        let observeOnly = Fixture()
        let b = observeOnly.member("B")
        try observeOnly.grant([.observe])
        let denied = try await observeOnly.call(["op": .string("rename"), "session_id": .string(b.uuidString), "name": .string("n")])
        XCTAssertEqual(denied["code"], .string("scope_capability_missing"))
        XCTAssertEqual(denied["capability"], .string("organize"))
        XCTAssertEqual(observeOnly.organizer.states[b]?.name, "B")
    }

    // MARK: - Idempotency

    func testIdempotencyKeyReplaysTheFirstResultAndConflictsOnDifferentArguments() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        try fixture.grant()
        let args: [String: Value] = [
            "op": .string("rename"), "session_id": .string(a.uuidString), "name": .string("First"),
            "idempotency_key": .string("rename-1")
        ]
        let first = try await fixture.call(args)
        XCTAssertEqual(items(first)[a.uuidString], "changed")
        fixture.organizer.states[a]?.name = "Changed by user"
        let replay = try await fixture.call(args)
        XCTAssertEqual(replay["idempotent_replay"], .bool(true))
        XCTAssertEqual(replay["undo_token"], first["undo_token"])
        XCTAssertEqual(fixture.organizer.states[a]?.name, "Changed by user", "a replay re-applies nothing")

        var different = args
        different["name"] = .string("Second")
        let conflict = try await fixture.call(different)
        XCTAssertEqual(conflict["result"], .string("idempotency_conflict"))
    }

    // MARK: - CAS

    func testReorderPinsIsCompareAndSwapAndKeepsOtherPinsInPlace() async throws {
        let fixture = Fixture()
        let a = fixture.member("A", pinned: true, pinnedOrder: 0)
        let x = fixture.outsider("X")
        fixture.organizer.states[x]?.isPinned = true
        fixture.organizer.states[x]?.pinnedOrder = 1
        let b = fixture.member("B", pinned: true, pinnedOrder: 2)
        try fixture.grant()

        let stale = try await fixture.call([
            "op": .string("reorder_pins"), "order": ids([b, a]), "expected_order": ids([b, a])
        ])
        XCTAssertEqual(stale["result"], .string("order_conflict"))
        XCTAssertEqual(stale["current_order"], ids([a, b]))
        XCTAssertEqual(fixture.organizer.pinnedSessionOrder(workspaceID: fixture.workspace), [a, x, b])
        let applied = try await fixture.call([
            "op": .string("reorder_pins"), "order": ids([b, a]), "expected_order": ids([a, b])
        ])
        XCTAssertEqual(applied["result"], .string("applied"))
        XCTAssertEqual(
            fixture.organizer.pinnedSessionOrder(workspaceID: fixture.workspace),
            [b, x, a],
            "the outsider keeps its slot"
        )
        XCTAssertFalse(fixture.organizer.written.contains(x), "the outsider's rank is never written")

        let token = try XCTUnwrap(applied["undo_token"]?.stringValue)
        let undone = try await fixture.call(["op": .string("undo"), "undo_token": .string(token)])
        XCTAssertEqual(undone["result"], .string("undone"))
        XCTAssertEqual(fixture.organizer.pinnedSessionOrder(workspaceID: fixture.workspace), [a, x, b])
        XCTAssertFalse(fixture.organizer.written.contains(x), "undo never writes the outsider either")
    }

    func testReorderGroupsCASOverEveryMemberOfTheNamedGroups() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        let b = fixture.member("B")
        try fixture.grant()
        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(a.uuidString), "group": .string("Alpha")])
        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(b.uuidString), "group": .string("Beta")])
        XCTAssertEqual(fixture.organizer.states[a]?.sidebarGroupOrder, 0)
        XCTAssertEqual(fixture.organizer.states[b]?.sidebarGroupOrder, 1, "a new group is appended")

        let conflict = try await fixture.call([
            "op": .string("reorder_groups"), "workspace": .string(fixture.workspace.uuidString),
            "order": .array([.string("Beta"), .string("Alpha")]),
            "expected_order": .array([.string("Beta"), .string("Alpha")])
        ])
        XCTAssertEqual(conflict["result"], .string("order_conflict"))
        let applied = try await fixture.call([
            "op": .string("reorder_groups"), "workspace": .string(fixture.workspace.uuidString),
            "order": .array([.string("Beta"), .string("Alpha")]),
            "expected_order": .array([.string("Alpha"), .string("Beta")])
        ])
        XCTAssertEqual(applied["group_order"], .array([.string("Beta"), .string("Alpha")]))
        XCTAssertEqual(fixture.organizer.states[b]?.sidebarGroupOrder, 0)
        XCTAssertEqual(fixture.organizer.states[a]?.sidebarGroupOrder, 1)

        // A group that also holds a session outside the scope is refused without naming it.
        let outsider = fixture.outsider("X")
        fixture.organizer.states[outsider]?.sidebarGroup = "Alpha"
        fixture.organizer.states[outsider]?.sidebarGroupOrder = 1
        let shared = try await fixture.call([
            "op": .string("reorder_groups"), "workspace": .string(fixture.workspace.uuidString),
            "order": .array([.string("Alpha"), .string("Beta")]),
            "expected_order": .array([.string("Beta"), .string("Alpha")])
        ])
        XCTAssertEqual(shared["result"], .string("groups_outside_scope"))
        XCTAssertFalse(String(describing: shared).contains(outsider.uuidString))
        XCTAssertEqual(fixture.organizer.states[outsider]?.sidebarGroupOrder, 1)
    }

    func testSetGroupWithEmptyStringClearsTheGroup() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        try fixture.grant()
        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(a.uuidString), "group": .string("Alpha")])
        XCTAssertEqual(fixture.organizer.states[a]?.sidebarGroup, "Alpha")

        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(a.uuidString), "group": .string("")])
        XCTAssertNil(fixture.organizer.states[a]?.sidebarGroup, "an empty string ungroups")
    }

    // MARK: - Cards, untick, apply-on-approval

    func testOverThresholdRaisesOneCardAndApprovalAppliesOnlyTickedItems() async throws {
        let fixture = Fixture()
        let members = (0 ..< 3).map { fixture.member("M\($0)") }
        try fixture.grant(threshold: 2)
        let args: [String: Value] = [
            "op": .string("set_group"), "targets": ids(members), "group": .string("Batch"),
            "idempotency_key": .string("group-batch")
        ]

        let preview = try await fixture.call(args.merging(["preview": .bool(true)]) { $1 })
        XCTAssertEqual(preview["result"], .string("preview"))
        XCTAssertEqual(preview["requires_confirmation"], .bool(true))
        XCTAssertEqual(preview["item_count"], .int(3))
        XCTAssertTrue(members.allSatisfy { fixture.organizer.states[$0]?.sidebarGroup == nil }, "a preview mutates nothing")

        let pending = try await fixture.call(args)
        XCTAssertEqual(pending["result"], .string("pending_confirmation"))
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(members.allSatisfy { fixture.organizer.states[$0]?.sidebarGroup == nil })

        fixture.runtime.confirmations.setItem(members[2], ticked: false, confirmationID: cardID)
        await fixture.frontDoor.approveAndApply(confirmationID: cardID)
        XCTAssertEqual(fixture.organizer.states[members[0]]?.sidebarGroup, "Batch")
        XCTAssertEqual(fixture.organizer.states[members[1]]?.sidebarGroup, "Batch")
        XCTAssertNil(fixture.organizer.states[members[2]]?.sidebarGroup, "an unticked item is never applied")
        XCTAssertEqual(
            fixture.runtime.confirmations.confirmation(id: cardID, granteeSessionID: fixture.overseer)?.state,
            .consumed,
            "a card applied below the threshold after unticking still ends applied"
        )

        let status = try await fixture.call(["op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)])
        let applied = try XCTUnwrap(status["applied_result"]?.objectValue)
        XCTAssertEqual(applied["changed_count"], .int(2))

        // Re-calling with the same key reports the card, not a second application.
        let again = try await fixture.call(args)
        XCTAssertEqual(again["confirmation_id"], .string(cardID.uuidString))
        XCTAssertNotNil(again["applied_result"])
    }

    // MARK: - Undo

    func testUndoRestoresExactPriorStateOnceAndOnlyForTheGrantee() async throws {
        let fixture = Fixture()
        let a = fixture.member("A", group: "Old")
        let b = fixture.member("B")
        try fixture.grant()
        let renamed = try await fixture.call(["op": .string("rename"), "targets": ids([a, b]), "name": .string("Same")])
        let token = try XCTUnwrap(renamed["undo_token"]?.stringValue)
        XCTAssertEqual(fixture.organizer.states[a]?.name, "Same")

        let undone = try await fixture.call(["op": .string("undo"), "undo_token": .string(token)])
        XCTAssertEqual(undone["result"], .string("undone"))
        XCTAssertEqual(fixture.organizer.states[a]?.name, "A")
        XCTAssertEqual(fixture.organizer.states[b]?.name, "B")
        XCTAssertEqual(fixture.organizer.states[a]?.sidebarGroup, "Old")

        let reused = try await fixture.call(["op": .string("undo"), "undo_token": .string(token)])
        XCTAssertEqual(reused["result"], .string("undo_unavailable"))

        let archived = try await fixture.call(["op": .string("archive"), "session_id": .string(b.uuidString)])
        XCTAssertEqual(fixture.organizer.states[b]?.isArchived, true)
        let archiveToken = try XCTUnwrap(archived["undo_token"]?.stringValue)
        _ = try await fixture.call(["op": .string("undo"), "undo_token": .string(archiveToken)])
        XCTAssertEqual(fixture.organizer.states[b]?.isArchived, false, "undoing archive unarchives")

        // A revoked scope undoes nothing.
        let pinned = try await fixture.call(["op": .string("set_pin"), "session_id": .string(a.uuidString), "pinned": .bool(true)])
        let pinToken = try XCTUnwrap(pinned["undo_token"]?.stringValue)
        for scope in fixture.runtime.liveScopes(grantedTo: fixture.overseer) {
            fixture.runtime.revoke(scopeID: scope.id)
        }
        let refused = try await fixture.call(["op": .string("undo"), "undo_token": .string(pinToken)])
        XCTAssertEqual(refused["result"], .string("denied"), "a revoked scope's undo is refused")
        XCTAssertEqual(refused["code"], .string("scope_revoked"))
        XCTAssertEqual(fixture.organizer.states[a]?.isPinned, true)
    }

    // MARK: - Filters and inventory

    func testFilterResolvesOnlyLoadedMembersAndInventoryHidesNonMembers() async throws {
        let fixture = Fixture()
        let stale = fixture.member("Stale lane")
        let fresh = fixture.member("Fresh lane")
        let outsider = fixture.outsider("Stale outsider")
        fixture.inventory.idleDays = [stale: 10, outsider: 10]
        let unloaded = UUID()
        fixture.inventory.historyOnly = [DomainAgentSessionInventoryRecord(
            sessionID: unloaded, name: "Unloaded child", workspaceID: UUID(), isLoaded: false,
            parentSessionID: fixture.overseer, lastActivityAt: fixture.now.addingTimeInterval(-20 * 86400)
        )]
        try fixture.grant()

        let archived = try await fixture.call([
            "op": .string("archive"), "filter": .object(["idle_days_gt": .int(5)])
        ])
        XCTAssertEqual(Set(items(archived).keys), [stale.uuidString], "outsiders and unloaded sessions are never resolved")
        XCTAssertEqual(fixture.organizer.states[stale]?.isArchived, true)
        XCTAssertEqual(fixture.organizer.states[outsider]?.isArchived, false)
        XCTAssertEqual(fixture.organizer.states[fresh]?.isArchived, false)

        let inventory = try await fixture.call(["op": .string("inventory"), "filter": .object(["idle_days_gt": .int(5)])])
        let listed = Set((inventory["sessions"]?.arrayValue ?? []).compactMap { $0.objectValue?["session_id"]?.stringValue })
        XCTAssertEqual(listed, [stale.uuidString, unloaded.uuidString], "history-only members are listed, outsiders never")

        let byQuery = try await fixture.call(["op": .string("inventory"), "filter": .object(["query": .string("fresh")])])
        XCTAssertEqual(byQuery["total"], .int(1))

        do {
            _ = try await fixture.call(["op": .string("archive"), "filter": .object(["bogus": .bool(true)])])
            XCTFail("unknown filter keys are rejected")
        } catch {}
    }

    func testOrphanFilterAndLinksInventory() async throws {
        let fixture = Fixture()
        let lane = fixture.member("Lane")
        let watcher = fixture.member("Watcher", archived: true)
        fixture.links.link(watcher, lane)
        let ghost = UUID()
        fixture.links.persisted.append(AgentSessionOversightIntent(observerSessionID: ghost, targetSessionID: lane))
        try fixture.grant()

        let orphans = try await fixture.call(["op": .string("inventory"), "filter": .object(["orphaned": .bool(true)])])
        let row = try XCTUnwrap(orphans["sessions"]?.arrayValue?.single?.objectValue)
        XCTAssertEqual(row["session_id"], .string(lane.uuidString))
        XCTAssertEqual(row["orphan_reasons"], .array([
            .string("link_intent_missing_session"), .string("observer_archived_or_deleted")
        ]))

        let links = try await fixture.call(["op": .string("links"), "session_id": .string(lane.uuidString)])
        XCTAssertEqual(links["total"], .int(2))
        let tree = try await fixture.call(["op": .string("tree")])
        let root = try XCTUnwrap(tree["tree"]?.objectValue)
        XCTAssertEqual(root["session_id"], .string(fixture.overseer.uuidString))
        XCTAssertEqual(root["children"]?.arrayValue?.count, 2)
    }

    func testMutationsOnUnloadedWorkspacesReportWorkspaceNotLoaded() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        try fixture.grant()
        fixture.organizer.states.removeValue(forKey: a)
        let reply = try await fixture.call(["op": .string("set_pin"), "session_id": .string(a.uuidString), "pinned": .bool(true)])
        XCTAssertEqual(items(reply)[a.uuidString], "skipped")
        let item = try XCTUnwrap(reply["items"]?.arrayValue?.single?.objectValue)
        XCTAssertEqual(item["reason"], .string("workspace_not_loaded"))
    }

    // MARK: - Release and retire

    func testReleaseUnlinksOnlyAmongMembersAndRetireReportsRunningWithoutControl() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        let b = fixture.member("B")
        let running = fixture.member("Running", run: .running)
        let outsider = fixture.outsider("X")
        fixture.links.link(a, b)
        fixture.links.link(outsider, a)
        try fixture.grant([.observe, .organize, .restructure])

        let released = try await fixture.call(["op": .string("release"), "session_id": .string(a.uuidString)])
        XCTAssertEqual(items(released)[a.uuidString], "changed")
        XCTAssertEqual(fixture.links.stoppedLinkIDs.count, 1, "the outsider's link is outside the scope")
        XCTAssertEqual(fixture.links.live.map(\.observerSessionID), [outsider])

        let retire = try await fixture.call([
            "op": .string("retire"), "targets": ids([b, running]), "idempotency_key": .string("retire-1")
        ])
        XCTAssertEqual(retire["result"], .string("pending_confirmation"), "retire is always carded")
        XCTAssertEqual(retire["requires_control"], ids([running]))
        let cardID = try XCTUnwrap(retire["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        await fixture.frontDoor.approveAndApply(confirmationID: cardID)
        XCTAssertEqual(fixture.organizer.states[b]?.isArchived, true)
        XCTAssertEqual(fixture.organizer.states[running]?.isArchived, false, "a running member needs control")
        XCTAssertEqual(
            fixture.runtime.confirmations.confirmation(id: cardID, granteeSessionID: fixture.overseer)?.state,
            .consumed,
            "an always-carded op is claimed by the core and ends applied"
        )
        XCTAssertTrue(fixture.organizer.stopped.isEmpty)
    }

    // MARK: - Review fixes

    /// M1: archive stashes the tab (cancelling a run), so a non-idle target needs `control`, both as
    /// authorized and as re-read by the handler; undo of unarchive follows the same rule.
    func testArchiveRequiresControlForNonIdleTargetsIncludingFreshStateAndUndo() async throws {
        let fixture = Fixture()
        let running = fixture.member("Running", run: .running)
        let turnedRunning = fixture.member("Turned running")
        let idle = fixture.member("Idle")
        try fixture.grant([.observe, .organize, .restructure])
        // Authorized as idle (projector) but running when the handler re-reads it.
        fixture.organizer.states[turnedRunning]?.runState = .running

        let reply = try await fixture.call(["op": .string("archive"), "targets": ids([running, turnedRunning, idle])])
        XCTAssertEqual(reply["requires_control"], ids([running]))
        XCTAssertEqual(items(reply)[turnedRunning.uuidString], "skipped")
        XCTAssertEqual(items(reply)[idle.uuidString], "changed")
        XCTAssertEqual(fixture.organizer.states[running]?.isArchived, false)
        XCTAssertEqual(fixture.organizer.states[turnedRunning]?.isArchived, false)
        XCTAssertEqual(fixture.organizer.states[idle]?.isArchived, true)

        // Undo of unarchive is an archive: re-authorized and re-checked the same way.
        let unarchived = try await fixture.call(["op": .string("unarchive"), "session_id": .string(idle.uuidString)])
        let token = try XCTUnwrap(unarchived["undo_token"]?.stringValue)
        fixture.provenance.add(idle, parent: fixture.overseer, workspace: fixture.workspace, state: .running)
        fixture.organizer.states[idle]?.runState = .running
        let undone = try await fixture.call(["op": .string("undo"), "undo_token": .string(token)])
        XCTAssertEqual(undone["requires_control"], ids([idle]))
        XCTAssertNil(items(undone)[idle.uuidString], "reported once, under requires_control")
        XCTAssertEqual(fixture.organizer.states[idle]?.isArchived, false, "a running session is not stashed without control")

        // With control, a running member is archived.
        let full = Fixture()
        let busy = full.member("Busy", run: .running)
        try full.grant()
        _ = try await full.call(["op": .string("archive"), "session_id": .string(busy.uuidString)])
        XCTAssertEqual(full.organizer.states[busy]?.isArchived, true)
    }

    /// M2: a retire target that started running after authorization is neither stopped, unlinked,
    /// nor archived without `control`.
    func testRetireReverifiesControlForATargetThatStartedRunning() async throws {
        let fixture = Fixture()
        let lane = fixture.member("Lane")
        let peer = fixture.member("Peer")
        fixture.links.link(peer, lane)
        try fixture.grant([.observe, .organize, .restructure])
        let pending = try await fixture.call([
            "op": .string("retire"), "session_id": .string(lane.uuidString), "idempotency_key": .string("retire-m2")
        ])
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        // Starts running after the card; the projector still reports idle, the handler re-reads it.
        fixture.organizer.states[lane]?.runState = .running
        await fixture.frontDoor.approveAndApply(confirmationID: cardID)
        let result = try XCTUnwrap(fixture.frontDoor.appliedResult(forConfirmation: cardID)?.objectValue)
        let item = try XCTUnwrap(result["items"]?.arrayValue?.single?.objectValue)
        XCTAssertEqual(item["reason"], .string("requires_control"))
        XCTAssertTrue(fixture.organizer.stopped.isEmpty)
        XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, false)
        XCTAssertTrue(fixture.links.stoppedLinkIDs.isEmpty, "nothing is done to the target")
    }

    /// M4: no output names, counts, or reflects a session outside the scope.
    func testInventoryOutputsNeverRevealOutOfScopeSessions() async throws {
        let fixture = Fixture()
        let secretName = "SECRET-OUTSIDER"
        let outsider = fixture.outsider(secretName)
        let lane = fixture.member("Lane")
        let spawned = fixture.member("Spawned")
        fixture.inventory.creators[spawned] = outsider
        fixture.links.link(outsider, lane)
        fixture.links.link(lane, outsider)
        let ghost = UUID()
        fixture.links.persisted.append(AgentSessionOversightIntent(observerSessionID: ghost, targetSessionID: lane))
        try fixture.grant()

        var outputs: [[String: Value]] = []
        try await outputs.append(fixture.call(["op": .string("inventory")]))
        try await outputs.append(fixture.call(["op": .string("inventory"), "filter": .object(["has_links": .bool(true)])]))
        try await outputs.append(fixture.call(["op": .string("get"), "session_id": .string(lane.uuidString)]))
        try await outputs.append(fixture.call(["op": .string("get"), "session_id": .string(spawned.uuidString)]))
        try await outputs.append(fixture.call(["op": .string("tree")]))
        try await outputs.append(fixture.call(["op": .string("links")]))
        try await outputs.append(fixture.call(["op": .string("links"), "session_id": .string(lane.uuidString)]))
        for output in outputs {
            let text = String(describing: output)
            XCTAssertFalse(text.contains(outsider.uuidString), text)
            XCTAssertFalse(text.contains(secretName), text)
            XCTAssertFalse(text.contains(ghost.uuidString), "deleted sessions are reported as missing, without IDs")
        }
        let laneRow = try XCTUnwrap(outputs[2]["session"]?.objectValue)
        XCTAssertEqual(laneRow["link_count"], .int(1), "only the deleted-observer intent counts")
        XCTAssertEqual(
            laneRow["orphan_reasons"],
            .array([.string("link_intent_missing_session"), .string("observer_archived_or_deleted")])
        )
        let spawnedRow = try XCTUnwrap(outputs[3]["session"]?.objectValue)
        XCTAssertNil(spawnedRow["created_by_overseer_session_id"])
        XCTAssertEqual(spawnedRow["orphaned"], .bool(false), "an out-of-scope creator is hidden, not missing")
        do {
            _ = try await fixture.call(["op": .string("links"), "session_id": .string(outsider.uuidString)])
            XCTFail("focusing an outside session is refused uniformly")
        } catch {}
    }

    /// S2: explicit targets in an unloaded workspace get a per-item result; unknown ones stay uniform.
    func testExplicitUnloadedTargetsReportWorkspaceNotLoadedWithAProductionShapedProjector() async throws {
        let fixture = Fixture()
        let loaded = fixture.member("Loaded")
        let unloaded = UUID()
        // Production projectors only see loaded workspaces: the unloaded member is in history only.
        fixture.inventory.historyOnly = [DomainAgentSessionInventoryRecord(
            sessionID: unloaded, name: "Unloaded", workspaceID: UUID(), isLoaded: false,
            parentSessionID: fixture.overseer, lastActivityAt: fixture.now
        )]
        try fixture.grant()
        let reply = try await fixture.call(["op": .string("set_pin"), "targets": ids([loaded, unloaded]), "pinned": .bool(true)])
        XCTAssertEqual(items(reply)[loaded.uuidString], "changed")
        XCTAssertEqual(items(reply)[unloaded.uuidString], "skipped")
        let only = try await fixture.call(["op": .string("set_pin"), "session_id": .string(unloaded.uuidString), "pinned": .bool(true)])
        XCTAssertEqual(items(only)[unloaded.uuidString], "skipped")
        do {
            _ = try await fixture.call(["op": .string("set_pin"), "session_id": .string(UUID().uuidString), "pinned": .bool(true)])
            XCTFail("an unknown session keeps the uniform denial")
        } catch {}
    }

    /// S3/S4: joining a group takes the group's own order value; a new group goes after the largest.
    func testSetGroupUsesExistingOrderValuesAndNewGroupsAppend() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        let b = fixture.member("B")
        let c = fixture.member("C")
        let x = fixture.outsider("X")
        fixture.organizer.states[x]?.sidebarGroup = "Shared"
        fixture.organizer.states[x]?.sidebarGroupOrder = 7
        try fixture.grant()
        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(a.uuidString), "group": .string("Shared")])
        XCTAssertEqual(fixture.organizer.states[a]?.sidebarGroupOrder, 7)
        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(b.uuidString), "group": .string("New")])
        XCTAssertEqual(fixture.organizer.states[b]?.sidebarGroupOrder, 8)
        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(c.uuidString), "group": .string("Newer")])
        XCTAssertEqual(fixture.organizer.states[c]?.sidebarGroupOrder, 9)
        XCTAssertFalse(fixture.organizer.written.contains(x))

        // Reordering two groups swaps only their values and writes only their carriers.
        _ = try await fixture.call([
            "op": .string("reorder_groups"), "workspace": .string(fixture.workspace.uuidString),
            "order": .array([.string("Newer"), .string("New")]),
            "expected_order": .array([.string("New"), .string("Newer")])
        ])
        XCTAssertEqual(fixture.organizer.states[c]?.sidebarGroupOrder, 8)
        XCTAssertEqual(fixture.organizer.states[b]?.sidebarGroupOrder, 9)
        XCTAssertEqual(fixture.organizer.states[x]?.sidebarGroupOrder, 7)
        XCTAssertFalse(fixture.organizer.written.contains(x))
    }

    /// S8: only calls that changed something are replayed; a no-op is re-evaluated on retry.
    func testIdempotencyLedgerRecordsOnlyChangingResults() async throws {
        let fixture = Fixture()
        let a = fixture.member("A", pinned: true)
        try fixture.grant()
        let args: [String: Value] = [
            "op": .string("set_pin"), "session_id": .string(a.uuidString), "pinned": .bool(true),
            "idempotency_key": .string("pin-noop")
        ]
        let noop = try await fixture.call(args)
        XCTAssertEqual(items(noop)[a.uuidString], "unchanged")
        fixture.organizer.states[a]?.isPinned = false
        let retry = try await fixture.call(args)
        XCTAssertNil(retry["idempotent_replay"])
        XCTAssertEqual(items(retry)[a.uuidString], "changed")
        XCTAssertEqual(fixture.organizer.states[a]?.isPinned, true)
        let replay = try await fixture.call(args)
        XCTAssertEqual(replay["idempotent_replay"], .bool(true))
    }

    /// Named pins without distinct explicit ranks move to the end of the ranked block; no pin outside
    /// the call is ever written, and undo restores the original sort exactly.
    func testReorderPinsWithUnrankedPinsNeverWritesOtherPinsAndUndoRestoresTheSort() async throws {
        let fixture = Fixture()
        let a = fixture.member("A", pinned: true)
        let b = fixture.member("B", pinned: true, pinnedOrder: 0)
        let x = fixture.outsider("X")
        fixture.organizer.states[x]?.isPinned = true
        try fixture.grant()
        let original = try XCTUnwrap(fixture.organizer.pinnedSessionOrder(workspaceID: fixture.workspace))
        let reply = try await fixture.call([
            "op": .string("reorder_pins"), "order": ids([a, b]), "expected_order": ids([b, a])
        ])
        XCTAssertEqual(reply["moved_to_ordered_block"], .bool(true))
        XCTAssertNil(reply["ranks_materialized"])
        XCTAssertEqual(Array(fixture.organizer.pinnedSessionOrder(workspaceID: fixture.workspace)?.prefix(2) ?? []), [a, b])
        XCTAssertFalse(fixture.organizer.written.contains(x))
        XCTAssertNil(fixture.organizer.states[x]?.pinnedOrder)

        let token = try XCTUnwrap(reply["undo_token"]?.stringValue)
        _ = try await fixture.call(["op": .string("undo"), "undo_token": .string(token)])
        XCTAssertEqual(fixture.organizer.pinnedSessionOrder(workspaceID: fixture.workspace), original)
        XCTAssertNil(fixture.organizer.states[a]?.pinnedOrder)
        XCTAssertFalse(fixture.organizer.written.contains(x))
    }

    // MARK: - Commit-time run-state races

    private func reason(_ reply: [String: Value], _ id: UUID) -> String? {
        (reply["items"]?.arrayValue ?? []).compactMap(\.objectValue)
            .first { $0["session_id"] == .string(id.uuidString) }?["reason"]?.stringValue
    }

    /// A target that starts running while its stash is suspended is refused at commit time, in this
    /// or another window; with `control` the same race archives.
    func testArchiveChecksRunStateAtStashCommitTime() async throws {
        let fixture = Fixture()
        let lane = fixture.member("Lane")
        let other = fixture.member("Other")
        let elsewhere = fixture.member("Elsewhere")
        try fixture.grant([.observe, .organize, .restructure])
        let organizer = fixture.organizer
        organizer.onStashSuspension = { id in
            if id == lane { organizer.states[lane]?.runState = .running }
            if id == elsewhere { organizer.otherWindowRunStates[elsewhere] = .running }
        }
        let reply = try await fixture.call(["op": .string("archive"), "targets": ids([lane, other, elsewhere])])
        XCTAssertEqual(reason(reply, lane), "requires_control")
        XCTAssertEqual(reason(reply, elsewhere), "requires_control", "running in another window counts")
        XCTAssertEqual(items(reply)[other.uuidString], "changed")
        XCTAssertEqual(organizer.states[lane]?.isArchived, false)
        XCTAssertEqual(organizer.states[elsewhere]?.isArchived, false)
        XCTAssertEqual(organizer.states[other]?.isArchived, true)

        let full = Fixture()
        let busy = full.member("Busy")
        try full.grant()
        let fullOrganizer = full.organizer
        fullOrganizer.onStashSuspension = { _ in fullOrganizer.states[busy]?.runState = .running }
        _ = try await full.call(["op": .string("archive"), "session_id": .string(busy.uuidString)])
        XCTAssertEqual(fullOrganizer.states[busy]?.isArchived, true, "control covers a target that started running")
    }

    /// Retire re-checks at stash commit time too.
    func testRetireArchiveChecksRunStateAtStashCommitTime() async throws {
        let fixture = Fixture()
        let lane = fixture.member("Lane")
        try fixture.grant([.observe, .organize, .restructure])
        let pending = try await fixture.call([
            "op": .string("retire"), "session_id": .string(lane.uuidString), "idempotency_key": .string("retire-race-1")
        ])
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let organizer = fixture.organizer
        organizer.onStashSuspension = { _ in organizer.states[lane]?.runState = .running }
        await fixture.frontDoor.approveAndApply(confirmationID: cardID)
        let result = try XCTUnwrap(fixture.frontDoor.appliedResult(forConfirmation: cardID)?.objectValue)
        XCTAssertEqual(reason(result, lane), "requires_control")
        XCTAssertEqual(organizer.states[lane]?.isArchived, false)
    }

    /// Retire re-checks run state after each unlink suspension: a target that starts running is
    /// neither unlinked further nor archived.
    func testRetireStopsUnlinkingATargetThatStartsRunning() async throws {
        let fixture = Fixture()
        let lane = fixture.member("Lane")
        let first = fixture.member("First")
        let second = fixture.member("Second")
        fixture.links.link(first, lane)
        fixture.links.link(second, lane)
        try fixture.grant([.observe, .organize, .restructure])
        let pending = try await fixture.call([
            "op": .string("retire"), "session_id": .string(lane.uuidString), "idempotency_key": .string("retire-race-2")
        ])
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let organizer = fixture.organizer
        fixture.links.afterStop = { _ in organizer.states[lane]?.runState = .running }
        await fixture.frontDoor.approveAndApply(confirmationID: cardID)
        let result = try XCTUnwrap(fixture.frontDoor.appliedResult(forConfirmation: cardID)?.objectValue)
        XCTAssertEqual(reason(result, lane), "requires_control")
        XCTAssertEqual(fixture.links.stoppedLinkIDs.count, 1, "no link is stopped after the target started running")
        XCTAssertEqual(fixture.links.live.count, 1)
        XCTAssertEqual(organizer.states[lane]?.isArchived, false)
        XCTAssertTrue(organizer.stopped.isEmpty)
    }

    /// S1: an index written under another schema leaves the scan incomplete (orphan detection off).
    func testSchemaMismatchedHistoryIndexMakesTheScanIncomplete() {
        let directory = URL(fileURLWithPath: "/tmp/history-fixture")
        func scan(schema: Int?, readFailed: Bool = false) -> HistoryInventoryScan {
            HistoryInventoryScan(
                workspaces: [HistoryWorkspaceScanResult(
                    workspaceDir: directory, workspaceName: "W", workspaceID: UUID(), records: [],
                    indexReadFailed: readFailed, indexSchemaVersion: schema
                )],
                diagnostics: []
            )
        }
        XCTAssertTrue(LiveAgentSessionInventorySource.isComplete(scan(schema: nil)))
        XCTAssertFalse(LiveAgentSessionInventorySource.isComplete(scan(schema: 7)))
        XCTAssertFalse(LiveAgentSessionInventorySource.isComplete(scan(schema: nil, readFailed: true)))
    }
}
