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

        func add(_ id: UUID, parent: UUID?, workspace: UUID? = nil, live: Bool = true) {
            sessions[id] = DelegationSessionProvenance(
                sessionID: id, workspaceID: workspace, parentSessionID: parent,
                createdByOverseerSessionID: nil, isLive: live
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
        XCTAssertEqual(malformedLoad, .ready(source: .quarantined, grants: []))
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
        XCTAssertEqual(fixture.runtime.pendingRequests(forTab: tab).map(\.id), [requestID], "the card shows in the requester's tab")

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
        let scope = try grantTree(fixture, grantee: overseer, threshold: 2)
        let handler = RecordingHandler([.adminSetPin])
        fixture.core.register(handler)
        let tab = UUID()
        func request(_ targets: [UUID], confirmation: UUID? = nil, key: String = "pin-1") -> AgentSessionAdministrationRequest {
            .init(
                operation: .adminSetPin, caller: .agentSession(overseer), callerTabID: tab,
                targetSessionIDs: targets, idempotencyKey: key, confirmationID: confirmation
            )
        }

        guard case let .pendingConfirmation(card) = try await fixture.core.perform(request([a, b, c])) else {
            return XCTFail("three items over a threshold of two must raise a card")
        }
        XCTAssertEqual(card.reason, .bulkThreshold)
        XCTAssertEqual(card.scopeID, scope.id)
        XCTAssertEqual(fixture.runtime.confirmations.pendingConfirmations(forTab: tab).map(\.id), [card.id])
        guard case let .pendingConfirmation(replayed) = try await fixture.core.perform(request([a, b, c])) else {
            return XCTFail("an identical retry returns the same card")
        }
        XCTAssertEqual(replayed.id, card.id)
        guard case .idempotencyConflict = try await fixture.core.perform(request([a, b, d])) else {
            return XCTFail("the key is bound to the exact item set")
        }

        fixture.runtime.confirmations.setItem(c, ticked: false, confirmationID: card.id)
        XCTAssertNotNil(fixture.runtime.confirmations.approve(confirmationID: card.id))
        guard case .denied(.confirmationMismatch, _) = try await fixture.core.perform(request([a, b, c], confirmation: card.id)) else {
            return XCTFail("an unticked item cannot be acted on")
        }
        guard case .completed = try await fixture.core.perform(request([a, b], confirmation: card.id)) else {
            return XCTFail("the approved subset applies")
        }
        XCTAssertEqual(handler.batches.single?.leases.map(\.targetSessionID), [a, b])
        XCTAssertEqual(handler.batches.single?.confirmation?.approvedSessionIDs, [a, b])

        // The approval was consumed: replaying the carded request cannot re-authorize it.
        guard case let .pendingConfirmation(spent) = try await fixture.core.perform(request([a, b, c], confirmation: card.id)) else {
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

        guard case let .pendingConfirmation(card) = try await fixture.core.perform(.init(
            operation: .adminRetire, caller: .agentSession(overseer), targetSessionIDs: [member], idempotencyKey: "retire-1"
        )) else { return XCTFail("destructive ops always raise a card") }
        XCTAssertEqual(card.reason, .destructive)
        fixture.runtime.revoke(scopeID: scope.id)
        XCTAssertEqual(fixture.runtime.confirmations.confirmation(id: card.id, granteeSessionID: overseer)?.state, .invalidated)

        guard case .denied(.unknownScope, _) = try await fixture.core.perform(.init(
            operation: .adminRename, caller: .agentSession(overseer), targetSessionIDs: [member]
        )) else { return XCTFail("no live scope remains") }
        XCTAssertTrue(handler.batches.isEmpty)
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
