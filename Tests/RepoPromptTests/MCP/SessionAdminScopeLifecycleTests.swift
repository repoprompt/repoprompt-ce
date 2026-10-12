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

    // MARK: - undo strict keys

    /// `undo` accepts only `op` and `undo_token`: any other key is refused before the caller or the
    /// token is resolved, so an extra key can never ride a redemption. The public description and
    /// schema must state that exception instead of the generic "mutating calls take idempotency_key".
    func testUndoAcceptsOnlyOpAndTokenAndThePublicContractSaysSo() async throws {
        let fixture = Fixture()
        fixture.endpoint = fixture.makeEndpoint(session: UUID())
        let base: [String: Value] = ["op": .string("undo"), "undo_token": .string(UUID().uuidString)]
        let extras: [String: Value] = [
            "scope_id": .string(UUID().uuidString),
            "idempotency_key": .string("k"),
            "preview": .bool(true),
            "session_id": .string(UUID().uuidString)
        ]
        for (key, value) in extras.sorted(by: { $0.key < $1.key }) {
            var args = base
            args[key] = value
            do {
                _ = try await fixture.call(args)
                XCTFail("undo must refuse '\(key)'")
            } catch let MCPError.invalidParams(message) {
                XCTAssertEqual(message, "session_admin undo does not support '\(key)'.", key)
            }
        }
        // Parser contract only: the bare form passes key validation. This fixture administers through
        // the core, not the front door, so the service then stops at its explicit not_implemented
        // guard; no redemption is exercised here. Success or any other error fails the test.
        do {
            _ = try await fixture.call(base)
            XCTFail("the bare undo form must reach the service's not_implemented guard in this fixture")
        } catch let MCPError.invalidParams(message) {
            XCTAssertEqual(message, "not_implemented: session_admin 'undo' is not implemented yet in this build.")
        }

        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.sessionAdmin))
        XCTAssertTrue(definition.description.contains("except `undo`, which accepts only `op` and `undo_token`"))
        let properties = try XCTUnwrap(definition.inputSchema.objectValue?["properties"]?.objectValue)
        for key in ["scope_id", "idempotency_key", "preview"] {
            let text = try XCTUnwrap(properties[key]?.objectValue?["description"]?.stringValue)
            XCTAssertTrue(text.contains("except undo"), "\(key): \(text)")
        }
        let token = try XCTUnwrap(properties["undo_token"]?.objectValue?["description"]?.stringValue)
        XCTAssertTrue(token.contains("undo accepts only op and undo_token"), token)
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
        // Unticking narrows to the threshold: the supplied card must still bind and apply once.
        let scope = try grantTree(fixture, grantee: overseer, threshold: 2)
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
        XCTAssertEqual(fixture.runtime.confirmations.pendingConfirmations(forTab: tab, sessionID: overseer).map(\.id), [card.id])
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
        guard case .denied(.confirmationMismatch, _) = try await fixture.core.perform(request([a, b], confirmation: card.id)) else {
            return XCTFail("a consumed card authorizes nothing, even below the threshold")
        }
        XCTAssertEqual(handler.batches.count, 1)
        guard case .completed = try await fixture.core.perform(request([a], key: "uncarded")) else {
            return XCTFail("under-threshold scope authority still works without a supplied card")
        }
        XCTAssertEqual(handler.batches.count, 2)
    }

    func testBatchCardsCannotFollowATabRebindAndApplyingCardsRetainTheirKeys() throws {
        let fixture = Fixture()
        let owner = UUID()
        let rebound = UUID()
        let tab = UUID()
        let scope = try grantTree(fixture, grantee: owner)
        let coordinator = fixture.runtime.confirmations
        func request(_ key: String) throws -> PendingBatchConfirmation {
            guard case let .created(card) = coordinator.request(
                scope: scope, operation: .adminRetire, idempotencyKey: key,
                granteeTabID: tab, reason: .destructive,
                items: [.init(sessionID: UUID(), title: "Member", effect: "Retire")]
            ) else { throw NSError(domain: "test", code: 1) }
            return card
        }
        let pending = try request("pending")
        let applying = try request("applying")
        XCTAssertNotNil(coordinator.approve(confirmationID: applying.id))
        XCTAssertTrue(coordinator.beginApplying(confirmationID: applying.id))
        XCTAssertTrue(coordinator.pendingConfirmations(forTab: tab, sessionID: rebound).isEmpty)
        XCTAssertFalse(coordinator.isCurrentPresentation(confirmationID: pending.id, tabID: tab, sessionID: rebound))
        // A persisted sidebar candidate is not a live requesting-session binding. With no
        // explicit binding, even a card whose old owner still exists must not be actionable.
        XCTAssertFalse(coordinator.isCurrentPresentation(confirmationID: pending.id, tabID: tab, sessionID: nil))
        XCTAssertTrue(coordinator.isCurrentPresentation(confirmationID: pending.id, tabID: tab, sessionID: owner))
        coordinator.invalidateStaleConfirmations(tabID: tab, currentSessionID: rebound)
        XCTAssertNil(coordinator.approve(confirmationID: pending.id))
        for index in 0 ... BatchConfirmationCoordinator.maxRetainedConfirmations {
            let terminal = try request("terminal-\(index)")
            coordinator.deny(confirmationID: terminal.id)
        }
        XCTAssertEqual(coordinator.confirmation(id: applying.id, granteeSessionID: owner)?.state, .applying)
        guard case let .existing(retained) = coordinator.request(
            scope: scope, operation: .adminRetire, idempotencyKey: applying.idempotencyKey,
            granteeTabID: tab, reason: .destructive, items: applying.items
        ) else { return XCTFail("applying card must keep its key ownership") }
        XCTAssertEqual(retained.id, applying.id)
        coordinator.finishApplying(confirmationID: applying.id, succeeded: true)
        XCTAssertEqual(coordinator.confirmation(id: applying.id, granteeSessionID: owner)?.state, .consumed)
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

    func testAbsentAndUnauthorizedTargetsHaveIdenticalScopeDenials() async throws {
        let fixture = Fixture()
        let caller = UUID()
        let target = UUID()
        fixture.source.add(caller, parent: nil)
        _ = try grantTree(fixture, grantee: caller)
        fixture.endpoint = fixture.makeEndpoint(session: caller)
        let handler = RecordingHandler([.adminRename])
        fixture.core.register(handler)
        let args: [String: Value] = ["op": .string("rename"), "session_id": .string(target.uuidString)]
        var messages: [String] = []
        // The same target is first absent, then present but outside this caller's tree.
        for exists in [false, true] {
            if exists { fixture.source.add(target, parent: UUID()) }
            do {
                _ = try await fixture.call(args)
                XCTFail("target must be refused")
            } catch {
                messages.append(String(describing: error))
            }
        }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first, messages.last)
        XCTAssertTrue(messages[0].contains("Session '\(target.uuidString)' is not available to this caller's scope."))
        XCTAssertFalse(messages[0].contains("active workspace"))
        XCTAssertTrue(handler.batches.isEmpty)

        // No-scope failure remains distinct and tells the caller how to request authority.
        fixture.endpoint = fixture.makeEndpoint(session: UUID())
        do {
            _ = try await fixture.call(args)
            XCTFail("a scope is required")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("session_admin is not available for this session"))
            XCTAssertTrue(message.contains("request_scope"))
            XCTAssertFalse(message.contains(target.uuidString))
        }
    }

    func testCleanupGuidanceDoesNotSilentlyAddObserve() async throws {
        let fixture = Fixture()
        let caller = UUID()
        fixture.endpoint = fixture.makeEndpoint(session: caller)
        let reply = try await fixture.call([
            "op": .string("request_scope"), "kind": .string("workspace"),
            "capabilities": .array([.string("organize"), .string("restructure")])
        ])
        let guidance = try XCTUnwrap(reply["guidance"]?.stringValue)
        for text in ["observe", "inventory", "only that workspace", "history is not a scope inventory"] {
            XCTAssertTrue(guidance.contains(text), guidance)
        }
        XCTAssertEqual(reply["capabilities"], .array([.string("organize"), .string("restructure")]))
        let requestID = try XCTUnwrap(reply["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let grant = try fixture.runtime.approve(requestID: requestID).get()
        XCTAssertEqual(grant.grant.capabilities, [.organize, .restructure])
        let missingObserve = try SessionAdminMCPToolService.deniedValue(.capabilityMissing(.observe), sessionID: nil)
        XCTAssertTrue(try XCTUnwrap(missingObserve.objectValue?["detail"]?.stringValue).contains("Request a new scope including observe"))
        let noScope = SessionAdminMCPToolService.scopeSelectionRequiredValue([])
        XCTAssertTrue(try XCTUnwrap(noScope.objectValue?["guidance"]?.stringValue).contains("request_scope"))
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
        /// Links whose stop fails (and stays live), for partial-commit witnesses.
        var failingLinkIDs: Set<UUID> = []
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
            if failingLinkIDs.contains(item.linkID) { return .failed(message: "injected stop failure") }
            stoppedLinkIDs.append(item.linkID)
            live.removeAll { $0.linkID == item.linkID }
            persisted.removeAll { $0.observerSessionID == item.observerSessionID && $0.targetSessionID == item.targetSessionID }
            afterStop?(item)
            return .stopped
        }
    }

    /// Live tab → session bindings the front door re-reads when the user acts on a card.
    @MainActor
    final class FakeTabBindings {
        var sessions: [UUID: UUID] = [:]
    }

    @MainActor
    private final class Fixture {
        let window = WindowState()
        let tabBindings = FakeTabBindings()
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

        var physicalObserverEndpoint: (@MainActor () -> DomainAgentSessionLinkEndpointIdentity?)?

        init(liveBoundSessionOverride: (@MainActor (UUID) -> UUID?)? = nil) {
            let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
            core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
            inventory = FakeInventory(organizer: organizer, provenance: provenance, links: links, now: now)
            let tabBindings = tabBindings
            frontDoor = AgentSessionAdministrationFrontDoor(
                core: core, scopes: runtime, projector: projector, inventory: inventory,
                liveBoundSession: liveBoundSessionOverride ?? { tabBindings.sessions[$0] }
            )
            tabBindings.sessions[tab] = overseer
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
                    if let physical = self.physicalObserverEndpoint { return physical() }
                    return DomainAgentSessionLinkEndpointIdentity(
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

        /// The user approves the card on the tab that still shows the requesting overseer.
        func approveAndApply(_ cardID: UUID) async {
            await frontDoor.approveAndApply(confirmationID: cardID, presentedTabID: tab, presentedSessionID: overseer)
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
        // Exercise the actual production allWindows presenter predicate, not the fake tab map.
        let fixture = Fixture(liveBoundSessionOverride: { AgentSessionAdministrationFrontDoor.liveExplicitBinding(forTab: $0) })
        let second = WindowState()
        WindowStatesManager.shared.registerWindowState(fixture.window)
        WindowStatesManager.shared.registerWindowState(second)
        addTeardownBlock { @MainActor in
            await second.tearDown()
            await fixture.window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(second)
            WindowStatesManager.shared.unregisterWindowState(fixture.window)
        }
        await fixture.window.workspaceManager.awaitInitialized()
        await second.workspaceManager.awaitInitialized()
        // awaitInitialized joins completion, not successful default activation. Establish our own
        // app-owned nonpersisted presentation explicitly before creating lifecycle carriers.
        let requestedPresentation = fixture.window.workspaceManager.createEphemeralWorkspace(
            name: "Batch physical presenter fixture", repoPaths: []
        )
        let activation = await fixture.window.workspaceManager.requestWorkspaceSwitch(
            to: requestedPresentation, saveState: false, reason: "batch physical presenter fixture"
        )
        guard activation.didSwitch else {
            return XCTFail("Fixture presentation activation failed: \(activation)")
        }
        let presentingWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
        XCTAssertEqual(presentingWorkspace.id, requestedPresentation.id)
        XCTAssertEqual(fixture.window.workspaceManager.activeWorkspaceID, requestedPresentation.id)
        XCTAssertTrue(presentingWorkspace.isEphemeral)
        let presentingIndex = try XCTUnwrap(fixture.window.workspaceManager.workspaces.firstIndex { $0.id == presentingWorkspace.id })
        fixture.window.workspaceManager.workspaces[presentingIndex].composeTabs.append(
            ComposeTabState(id: fixture.tab, name: "Loaded batch presenter", activeAgentSessionID: fixture.overseer)
        )
        let presenter = AgentModeViewModel.TabSession(tabID: fixture.tab)
        fixture.window.agentModeViewModel.test_installLiveSession(presenter)
        _ = try XCTUnwrap(fixture.window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: fixture.overseer, on: presenter
        ))
        let endpoint = try XCTUnwrap(fixture.window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: fixture.tab))
        XCTAssertTrue(endpoint.hasResolvedPersistentBinding)
        XCTAssertEqual(endpoint.sessionID, fixture.overseer)
        XCTAssertEqual(endpoint.workspaceID, presentingWorkspace.id)
        XCTAssertEqual(endpoint.windowID, fixture.window.windowID)
        let physicalTab = fixture.tab
        fixture.physicalObserverEndpoint = { [weak window = fixture.window] in
            window?.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: physicalTab)
        }
        var catalog = WorkspaceModel(name: "Non-presenting batch catalog", repoPaths: [], isSavedWorkspace: false)
        catalog.isEphemeral = true
        catalog.composeTabs = [ComposeTabState(id: fixture.tab, name: "Catalog only", activeAgentSessionID: fixture.overseer)]
        let secondActive = second.workspaceManager.activeWorkspaceID
        second.workspaceManager.workspaces.append(catalog)
        XCTAssertEqual(second.workspaceManager.activeWorkspaceID, secondActive)
        XCTAssertNotEqual(second.workspaceManager.activeWorkspaceID, catalog.id)
        XCTAssertNil(second.agentModeViewModel.sessions[fixture.tab])
        XCTAssertEqual(second.agentModeViewModel.explicitActiveSessionID(for: fixture.tab), fixture.overseer)
        XCTAssertEqual(AgentSessionAdministrationFrontDoor.liveExplicitBinding(forTab: fixture.tab), fixture.overseer)
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

        func cardState() -> PendingBatchConfirmation.State? {
            fixture.runtime.confirmations.confirmation(id: cardID, granteeSessionID: fixture.overseer)?.state
        }
        _ = try await fixture.call(["op": .string("inventory")])
        XCTAssertEqual(cardState(), .pending, "an inactive catalog copy cannot invalidate a pending card")
        // A genuinely loaded duplicate is still ambiguous, even when its session ID matches.
        let duplicate = AgentModeViewModel.TabSession(tabID: fixture.tab)
        second.agentModeViewModel.test_installLiveSession(duplicate)
        _ = try XCTUnwrap(second.agentModeViewModel.test_installPersistentSessionBinding(sessionID: fixture.overseer, on: duplicate))
        XCTAssertNil(AgentSessionAdministrationFrontDoor.liveExplicitBinding(forTab: fixture.tab))
        await fixture.approveAndApply(cardID)
        XCTAssertEqual(cardState(), .pending)
        XCTAssertTrue(fixture.organizer.written.isEmpty)
        _ = second.agentModeViewModel.test_installPersistentSessionBinding(sessionID: nil, on: duplicate)
        XCTAssertNil(duplicate.activeAgentSessionID)
        XCTAssertEqual(AgentSessionAdministrationFrontDoor.liveExplicitBinding(forTab: fixture.tab), fixture.overseer)
        let rebound = UUID()
        _ = try XCTUnwrap(fixture.window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: rebound, on: presenter))
        await fixture.approveAndApply(cardID)
        XCTAssertEqual(cardState(), .pending, "a stale button cannot follow a real rebind")
        XCTAssertTrue(fixture.organizer.written.isEmpty)
        _ = try XCTUnwrap(fixture.window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: fixture.overseer, on: presenter))
        fixture.runtime.confirmations.setItem(members[2], ticked: false, confirmationID: cardID)
        // Separate state-only card: the coordinator is an explicit approval stand-in here.
        // Never route its already-approved state through a pending-only UI callback.
        let stateOnly = try await fixture.call(args.merging([
            "idempotency_key": .string("approved-state-only"), "group": .string("Approved state only")
        ]) { $1 })
        let approvedID = try XCTUnwrap(stateOnly["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        XCTAssertNotEqual(approvedID, cardID)
        XCTAssertNotNil(fixture.runtime.confirmations.approve(confirmationID: approvedID))
        _ = try await fixture.call(["op": .string("inventory")])
        XCTAssertEqual(
            fixture.runtime.confirmations.confirmation(id: approvedID, granteeSessionID: fixture.overseer)?.state,
            .approved, "an inactive catalog copy cannot invalidate an approved card"
        )
        XCTAssertEqual(cardState(), .pending, "the real UI application card must still be pending")
        XCTAssertTrue(fixture.organizer.written.isEmpty)
        let changed = try await fixture.call(args.merging(["group": .string("Changed")]) { $1 })
        XCTAssertEqual(changed["result"], .string("idempotency_conflict"))
        XCTAssertEqual(cardState(), .pending)
        // Actual pending UI path approves, removes its stored request, applies and records result.
        await fixture.approveAndApply(cardID)
        XCTAssertEqual(Set(fixture.organizer.written), Set(members.prefix(2)))
        XCTAssertEqual(fixture.organizer.written.count, 2)
        await fixture.approveAndApply(cardID)
        XCTAssertEqual(fixture.organizer.written.count, 2, "approval callback replay applies nothing twice")
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

    func testApprovalAppliesOnlyForTheTabStillShowingTheRequestingSession() async throws {
        let fixture = Fixture()
        let members = (0 ..< 3).map { fixture.member("M\($0)") }
        try fixture.grant(threshold: 2)
        let pending = try await fixture.call([
            "op": .string("set_group"), "targets": ids(members), "group": .string("Batch"),
            "idempotency_key": .string("group-rebind")
        ])
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let state = { fixture.runtime.confirmations.confirmation(id: cardID, granteeSessionID: fixture.overseer)?.state }

        // A presentation for another session or tab acts on nothing.
        await fixture.frontDoor.approveAndApply(confirmationID: cardID, presentedTabID: fixture.tab, presentedSessionID: UUID())
        fixture.frontDoor.denyConfirmation(confirmationID: cardID, presentedTabID: UUID(), presentedSessionID: fixture.overseer)
        XCTAssertEqual(state(), .pending)

        // The tab was rebound after the user's tap but before the deferred apply ran (and before the
        // view's invalidation pass): the front door re-reads the live binding and refuses.
        fixture.tabBindings.sessions[fixture.tab] = UUID()
        await fixture.approveAndApply(cardID)
        fixture.frontDoor.denyConfirmation(confirmationID: cardID, presentedTabID: fixture.tab, presentedSessionID: fixture.overseer)
        XCTAssertEqual(state(), .pending)
        XCTAssertTrue(members.allSatisfy { fixture.organizer.states[$0]?.sidebarGroup == nil })

        // Once the rebind invalidates the card, even its original presentation cannot apply it.
        fixture.tabBindings.sessions[fixture.tab] = fixture.overseer
        fixture.runtime.confirmations.invalidateStaleConfirmations(tabID: fixture.tab, currentSessionID: UUID())
        await fixture.approveAndApply(cardID)
        XCTAssertEqual(state(), .invalidated)
        XCTAssertTrue(members.allSatisfy { fixture.organizer.states[$0]?.sidebarGroup == nil })
    }

    func testCardsOnATabThatNoLongerShowsTheGranteeStopHoldingPendingSlots() async throws {
        let fixture = Fixture()
        let members = (0 ..< 3).map { fixture.member("M\($0)") }
        try fixture.grant(threshold: 2)
        let pending = try await fixture.call([
            "op": .string("set_group"), "targets": ids(members), "group": .string("Batch"),
            "idempotency_key": .string("group-moved")
        ])
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))

        // The grantee's old tab now shows another session while that tab's view is off screen, so the
        // view's invalidation pass never runs. The grantee's next call releases the hidden card.
        fixture.tabBindings.sessions[fixture.tab] = UUID()
        _ = try await fixture.call(["op": .string("inventory")])
        XCTAssertEqual(
            fixture.runtime.confirmations.confirmation(id: cardID, granteeSessionID: fixture.overseer)?.state,
            .invalidated
        )
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

    func testPartiallyCommittedReleaseIsRecordedAndReplayedUnderItsKey() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        let b = fixture.member("B")
        let c = fixture.member("C")
        fixture.links.link(a, b)
        fixture.links.link(a, c)
        let failing = try XCTUnwrap(fixture.links.live.last?.linkID)
        fixture.links.failingLinkIDs = [failing]
        try fixture.grant([.observe, .organize, .restructure])
        let args: [String: Value] = [
            "op": .string("release"), "session_id": .string(a.uuidString), "idempotency_key": .string("release-partial")
        ]

        let first = try await fixture.call(args)
        XCTAssertEqual(items(first)[a.uuidString], "failed", "a later unlink failed")
        XCTAssertEqual(first["changed_count"], .int(0))
        XCTAssertEqual(first["committed_changes"], .bool(true), "the first unlink still took effect")
        XCTAssertEqual(fixture.links.stoppedLinkIDs.count, 1)

        // The same key replays the partial receipt; it never re-runs the release.
        fixture.links.failingLinkIDs = []
        let retry = try await fixture.call(args)
        XCTAssertEqual(retry["idempotent_replay"], .bool(true))
        XCTAssertEqual(fixture.links.stoppedLinkIDs.count, 1, "a replay unlinks nothing further")
        XCTAssertEqual(fixture.links.live.map(\.linkID), [failing])

        // A new key is a new release and finishes the remaining link.
        var fresh = args
        fresh["idempotency_key"] = .string("release-partial-2")
        let finished = try await fixture.call(fresh)
        XCTAssertEqual(items(finished)[a.uuidString], "changed")
        XCTAssertTrue(fixture.links.live.isEmpty)
    }

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
        await fixture.approveAndApply(cardID)
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

    func testApprovedRetireWhoseTargetsAllStartedRunningSettlesAndReportsRequiresControl() async throws {
        let fixture = Fixture()
        let lane = fixture.member("Lane")
        try fixture.grant([.observe, .organize, .restructure])
        let retire = try await fixture.call([
            "op": .string("retire"), "session_id": .string(lane.uuidString), "idempotency_key": .string("retire-raced")
        ])
        let cardID = try XCTUnwrap(retire["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))

        // The only approved item starts running before the approval is applied; there is no `control`.
        fixture.provenance.add(lane, parent: fixture.overseer, workspace: fixture.workspace, state: .running)
        fixture.organizer.states[lane]?.runState = .running
        await fixture.approveAndApply(cardID)

        XCTAssertEqual(
            fixture.runtime.confirmations.confirmation(id: cardID, granteeSessionID: fixture.overseer)?.state,
            .consumed,
            "the card is settled rather than stranded as approved"
        )
        XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, false)
        let status = try await fixture.call(["op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)])
        let applied = try XCTUnwrap(status["applied_result"]?.objectValue)
        XCTAssertEqual(applied["requires_control"], ids([lane]), "reported as requires_control, not confirmation_mismatch")
    }

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
        await fixture.approveAndApply(cardID)
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
        await fixture.approveAndApply(cardID)
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
        await fixture.approveAndApply(cardID)
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

// MARK: - DelegationCommitFenceTests regressions

@MainActor
final class DelegationCommitFenceTests: XCTestCase {
    func testGrantApprovalReReadsBindingAndRejectsAnotherPhysicalWindow() async throws {
        let first = WindowState(), second = WindowState()
        addTeardownBlock { @MainActor in
            await first.tearDown()
            await second.tearDown()
        }
        await first.workspaceManager.awaitInitialized()
        await second.workspaceManager.awaitInitialized()
        let requester = UUID()
        let catalogTab = ComposeTabState(name: "Catalog-only requester", activeAgentSessionID: requester)
        let tab = catalogTab.id
        let session = AgentModeViewModel.TabSession(tabID: tab)
        first.agentModeViewModel.test_installLiveSession(session)
        _ = try XCTUnwrap(first.agentModeViewModel.test_installPersistentSessionBinding(sessionID: requester, on: session))
        // A different window knows the saved carrier without presenting its Agent session.
        // Exercise the real catalog lookup; do not fabricate a physical endpoint.
        var catalog = WorkspaceModel(name: "Inactive catalog copy", repoPaths: [], isSavedWorkspace: false)
        catalog.isEphemeral = true
        catalog.composeTabs = [catalogTab]
        second.workspaceManager.workspaces.append(catalog)
        XCTAssertNil(second.agentModeViewModel.sessions[tab])
        XCTAssertEqual(
            second.agentModeViewModel.explicitActiveSessionID(for: tab),
            requester,
            "the old lookup sees the non-presenting catalog copy"
        )
        var windows = [first, second]
        let runtime = DelegationScopeRuntime(windows: { windows }, notifyCatalogChanged: { _ in })
        let request = try runtime.requestScope(
            requesterSessionID: requester, requesterTabID: tab, kind: .tree(rootSessionID: requester),
            capabilities: [.observe], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        XCTAssertEqual(request.requesterWindowID, first.windowID)
        func approve(in window: WindowState) -> Bool {
            if case .success = runtime.approve(
                requestID: request.id, presentedWindowID: window.windowID,
                presentedTabID: tab, presentedSessionID: requester
            ) { return true }
            return false
        }

        XCTAssertFalse(approve(in: second), "catalog knowledge does not grant physical presentation authority")
        XCTAssertEqual(runtime.requests[request.id]?.state, .pending)
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: requester))

        // No render/task cancellation runs between the rebind and the stale button callback.
        _ = try XCTUnwrap(first.agentModeViewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session))
        XCTAssertFalse(approve(in: first))
        XCTAssertEqual(runtime.requests[request.id]?.state, .pending)
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: requester))

        let otherSession = AgentModeViewModel.TabSession(tabID: tab)
        second.agentModeViewModel.test_installLiveSession(otherSession)
        _ = try XCTUnwrap(second.agentModeViewModel.test_installPersistentSessionBinding(sessionID: requester, on: otherSession))
        windows = [second]
        XCTAssertFalse(approve(in: second), "matching IDs in a different physical window are not the presented request")
        windows = [first]
        _ = try XCTUnwrap(first.agentModeViewModel.test_installPersistentSessionBinding(sessionID: requester, on: session))
        windows = [first, second]
        XCTAssertFalse(approve(in: first), "ambiguous cross-window tab ownership fails closed")
        windows = [first]
        XCTAssertTrue(approve(in: first), "the original physical window's current explicit binding can approve")
        XCTAssertTrue(runtime.hasLiveScope(grantedTo: requester))
    }
}

@MainActor
final class AgentSessionInventoryScalingTests: XCTestCase {
    func testTwoHundredFiftyTargetsShareCarrierAndLivenessCensusAndSeeFreshChanges() async {
        let window = WindowState()
        addTeardownBlock { @MainActor in await window.tearDown() }
        await window.workspaceManager.awaitInitialized()
        let ids = (0 ..< 250).map { _ in UUID() }
        var tabs = (0 ..< 1500).map { ComposeTabState(name: "Tab \($0)") }
        for index in 0 ..< 200 {
            tabs[index].activeAgentSessionID = ids[index]
        }
        tabs[1250].activeAgentSessionID = ids[0] // Duplicate persisted carrier must stay ambiguous.
        let stashes = (200 ..< 250).map { StashedTab(tab: ComposeTabState(name: "Stash \($0)")) }
        var workspace = WorkspaceModel(name: "Scale", repoPaths: [], composeTabs: tabs, activeComposeTabID: tabs[0].id)
        workspace.stashedTabs = stashes
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        window.promptManager.loadComposeTabsFromWorkspace(workspace)
        let entries = ids.enumerated().map { index, id in
            AgentSessionIndexEntry(
                id: id, tabID: index < 200 ? tabs[index].id : stashes[index - 200].tab.id,
                name: "Indexed \(index)", savedAt: Date(timeIntervalSince1970: 0), itemCount: 1,
                autoEditEnabled: false, hasUnknownConversationContent: false, isMCPOriginated: false,
                worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
            )
        }
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        let vm = window.agentModeViewModel
        vm.test_installSessionIndexSnapshot(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), owner: owner, latestOwner: owner, activeWorkspace: workspace)
        var windowReads = 0
        let organizer = OpenWindowsAgentSessionOrganizer(windows: { windowReads += 1
            return [window]
        })
        vm.test_resetPersistentBindingResolutionSnapshotBuildCount()
        let states = organizer.states(of: ids)
        XCTAssertEqual(states.count, 250)
        XCTAssertEqual(states.values.count(where: \.isArchived), 50)
        XCTAssertEqual(states[ids[0]]?.runState, .unknown)
        XCTAssertEqual(states[ids[1]]?.runState, .idle)
        XCTAssertEqual(windowReads, 1, "Do not rediscover windows/carriers per target")
        XCTAssertEqual(vm.test_persistentBindingResolutionBuildCount, 1)
        XCTAssertLessThanOrEqual(vm.test_sidebarSessionRowsBuildCount, 1)

        windowReads = 0
        let changed = organizer.setGroup("Grouped", order: 3, sessionIDs: ids)
        XCTAssertEqual(changed, Set(ids.prefix(200)))
        XCTAssertEqual(windowReads, 1, "One carrier census per synchronous mutation region")
        let fresh = organizer.states(of: ids)
        XCTAssertEqual(fresh[ids[1]]?.sidebarGroup, "Grouped")
        XCTAssertNil(fresh[ids[249]]?.sidebarGroup, "Nil-bound stashes must not be mistaken for active tabs")

        windowReads = 0
        let restoredGroups = Dictionary(uniqueKeysWithValues: ids.prefix(200).map { ($0, (name: String?.none, order: Int?.none)) })
        XCTAssertEqual(organizer.setGroups(restoredGroups), Set(ids.prefix(200)))
        XCTAssertEqual(windowReads, 1, "Distinct undo group values must share one carrier census")
        windowReads = 0
        XCTAssertEqual(organizer.unarchive(Array(ids.suffix(50))), Set(ids.suffix(50)))
        XCTAssertEqual(windowReads, 1)
        XCTAssertTrue(window.workspaceManager.activeWorkspace?.stashedTabs.isEmpty == true)
        XCTAssertEqual(organizer.states(of: ids).values.count(where: \.isArchived), 0)
        XCTAssertEqual(organizer.loadedSessionIDs().count, 250)
    }

    func testChainMembershipAndUsageReuseOneFreshSynchronousCensus() {
        let ids = (0 ..< 250).map { _ in UUID() }
        let workspace = UUID()
        let rows = ids.enumerated().map { index, id in
            DelegationSessionProvenance(sessionID: id, workspaceID: workspace, parentSessionID: index == 0 ? nil : ids[index - 1], createdByOverseerSessionID: nil, isLive: true, worktreeCount: 1, runState: .idle)
        }
        let source = CountingSource(rows: rows)
        var lookups = 0
        let projector = SpawnProvenanceDelegationMembershipProjector(source: source, onAncestryLookup: { _ in lookups += 1 })
        let scope = DomainDelegationScopeGrant(id: UUID(), granteeSessionID: ids[0], kind: .tree(rootSessionID: ids[0]), capabilities: [.observe], guardrails: .init(), origin: .user, grantedAt: Date(timeIntervalSince1970: 0))
        projector.withSynchronousCensus { census in
            for id in ids {
                XCTAssertEqual(census.members(of: scope), ids)
                XCTAssertEqual(census.usage(of: scope, spawnParentSessionID: id).liveSessionCount, 250)
                XCTAssertEqual(census.membershipProof(for: id, in: scope)?.treeDepth, ids.firstIndex(of: id))
            }
        }
        XCTAssertEqual(source.censusReads, 1)
        XCTAssertEqual(source.individualReads, 0)
        XCTAssertEqual(lookups, 249_498, "Members, usage and parent depth share bounded scalar ancestry lookups")
        source.rows = [rows[0]]
        XCTAssertEqual(projector.members(of: scope), [ids[0]], "A later region must not reuse stale membership")
        XCTAssertEqual(source.censusReads, 2)
    }

    private final class CountingSource: DelegationProvenanceSource {
        var rows: [DelegationSessionProvenance]
        var censusReads = 0
        var individualReads = 0
        init(rows: [DelegationSessionProvenance]) {
            self.rows = rows
        }

        func provenance(for id: UUID) -> DelegationSessionProvenance? {
            individualReads += 1
            return rows.first { $0.sessionID == id }
        }

        func allKnownSessions() -> [DelegationSessionProvenance] {
            censusReads += 1
            return rows
        }
    }
}
