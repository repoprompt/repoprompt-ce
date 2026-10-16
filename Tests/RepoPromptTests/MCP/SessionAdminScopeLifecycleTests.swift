import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptVCS
import XCTest

/// Successful phases write the actual file; only the explicitly armed phase fails or waits.
private final class DelegationScopeFileWriteGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "scope file writer reached held phase")
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var failing = false
    private var holdNext = false

    func setFailing(_ value: Bool) {
        lock.withLock { failing = value }
    }

    func holdNextWrite() {
        lock.withLock { holdNext = true }
    }

    func resume() {
        release.signal()
    }

    func write(_ data: Data, to url: URL) throws {
        let phase = lock.withLock { () -> (failing: Bool, held: Bool) in
            let phase = (failing: failing, held: holdNext)
            holdNext = false
            return phase
        }
        if phase.held {
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
        }
        if phase.failing { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}

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

    private func makeStore(
        mode: AgentSessionOversightPersistenceMode = .enabled,
        directory: URL? = nil,
        writer: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) -> DelegationScopeStore {
        let directory = directory ?? temporaryDirectory!
        return DelegationScopeStore(
            fileURL: directory.appendingPathComponent(DelegationScopeStore.filename),
            backupsDirectoryURL: directory.appendingPathComponent("Backups", isDirectory: true),
            mode: mode,
            writer: writer
        )
    }

    private var scopeFile: URL {
        temporaryDirectory.appendingPathComponent(DelegationScopeStore.filename)
    }

    private func scopeDocument() throws -> DelegationScopeDocument {
        try JSONDecoder().decode(DelegationScopeDocument.self, from: Data(contentsOf: scopeFile))
    }

    private func makeSavedSession(_ sessionID: UUID) throws -> (
        service: AgentSessionDataService, workspace: WorkspaceModel, fileURL: URL, bytes: Data
    ) {
        let storage = temporaryDirectory.appendingPathComponent("workspace-\(sessionID.uuidString)", isDirectory: true)
        let folder = storage.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = WorkspaceModel(name: "Scope startup deletion", repoPaths: ["/tmp/repo"], customStoragePath: storage)
        let session = AgentSession(
            id: sessionID, workspaceID: workspace.id, composeTabID: UUID(), name: "Saved anchor", itemCount: 0
        )
        let bytes = try JSONEncoder().encode(session)
        let file = folder.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
        try bytes.write(to: file, options: .atomic)
        return (AgentSessionDataService(), workspace, file, bytes)
    }

    private func assertScopePersistenceRefusesDeletion(
        of sessionID: UUID,
        service: AgentSessionDataService,
        workspace: WorkspaceModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await service.deleteAgentSession(id: sessionID, for: workspace)
            XCTFail("Unavailable scope persistence must refuse physical deletion", file: file, line: line)
        } catch let AgentSessionDeletionRegistry.AdmissionError.scopePersistenceUnavailable(reason) {
            XCTAssertFalse(reason.isEmpty, file: file, line: line)
        } catch {
            XCTFail("Expected scope persistence refusal, got \(error)", file: file, line: line)
        }
    }

    private func grantScope(
        _ runtime: DelegationScopeRuntime, to overseer: UUID
    ) throws -> DomainDelegationScopeRecord {
        let request = try runtime.requestScope(
            requesterSessionID: overseer, requesterTabID: nil, kind: .tree(rootSessionID: overseer),
            capabilities: [.observe, .organize], guardrails: .init(maxDepth: 2), reason: "tidy", idempotencyKey: nil
        ).get()
        return try runtime.approve(requestID: request.id).get()
    }

    private func authorizationRequest(_ record: DomainDelegationScopeRecord) -> DomainDelegationScopeAuthorizationRequest {
        .init(
            operation: .adminInventory,
            caller: .agentSession(record.grant.granteeSessionID),
            scopeID: record.id,
            presentedGeneration: record.generation
        )
    }

    private func lease(_ record: DomainDelegationScopeRecord) -> DomainDelegationScopeLease {
        .init(
            scopeID: record.id, generation: record.generation, capability: .observe,
            granteeSessionID: record.grant.granteeSessionID, targetSessionID: record.grant.granteeSessionID
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

        init(runtime injectedRuntime: DelegationScopeRuntime? = nil) {
            let box = notificationBox
            runtime = injectedRuntime ?? DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { box.ids.append($0) })
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
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store)
        let overseer = UUID()
        let granted = try grantScope(runtime, to: overseer)
        XCTAssertEqual(try scopeDocument().scopes.map(\.id), [granted.id], "A grant is durable before approve returns")
        XCTAssertTrue(runtime.authorize(authorizationRequest(granted)).isAuthorized)
        XCTAssertTrue(runtime.isCurrent(lease(granted)))

        runtime.freezeForTermination(allowRestoration: true)
        let sealed = await runtime.settleForTermination()
        XCTAssertTrue(sealed)
        XCTAssertFalse(runtime.hasLiveScopeForCatalog(grantedTo: overseer))
        XCTAssertFalse(runtime.authorize(authorizationRequest(granted)).isAuthorized)
        store.closeWithoutSealingForTesting()

        let nextStore = makeStore(mode: .dormant)
        let reloaded = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await reloaded.bootstrap(store: nextStore)
        let live = reloaded.liveScopes(grantedTo: overseer)
        XCTAssertEqual(live.map(\.id), [granted.id])
        XCTAssertEqual(live.first?.grant, granted.grant)

        reloaded.revoke(scopeID: granted.id)
        XCTAssertTrue(try scopeDocument().scopes.isEmpty, "A revocation is durable before revoke returns")
        nextStore.closeWithoutSealingForTesting()
        let lastStore = makeStore()
        let again = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await again.bootstrap(store: lastStore)
        XCTAssertFalse(again.hasLiveScope(grantedTo: overseer))
        lastStore.closeWithoutSealingForTesting()
    }

    /// Kill mid-session (no terminate hook): every grant and every revocation made so far survives.
    func testKillWithoutTerminationRestoresGrantsAndKeepsRevocations() async throws {
        let store = makeStore()
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store)
        let kept = try grantScope(runtime, to: UUID())
        let revoked = try grantScope(runtime, to: UUID())
        let released = try grantScope(runtime, to: UUID())
        runtime.revoke(scopeID: revoked.id)
        _ = runtime.release(scopeID: released.id, caller: .agentSession(released.grant.granteeSessionID))
        // No freeze, no settle: the process dies here.
        store.closeWithoutSealingForTesting()

        for _ in 0 ..< 2 {
            let nextStore = makeStore()
            let restarted = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
            await restarted.bootstrap(store: nextStore)
            XCTAssertTrue(restarted.canUseAuthority)
            XCTAssertEqual(restarted.liveScopes(grantedTo: kept.grant.granteeSessionID).map(\.id), [kept.id])
            XCTAssertFalse(restarted.hasLiveScope(grantedTo: revoked.grant.granteeSessionID))
            XCTAssertFalse(restarted.hasLiveScope(grantedTo: released.grant.granteeSessionID))
            XCTAssertEqual(try scopeDocument().scopes.map(\.id), [kept.id], "Relaunch never rewrites grants away")
            try XCTAssertEqual(Set(scopeDocument().revokedScopeIDs ?? []), [revoked.id, released.id])
            // Killed again, before any change: the next launch still restores everything.
            nextStore.closeWithoutSealingForTesting()
        }
    }

    func testStorePreservesFutureSchemaQuarantinesMalformedAndSuppressesIO() async throws {
        let futureBytes = Data(#"{"version": 99, "scopes": []}"#.utf8)
        try futureBytes.write(to: scopeFile)
        let future = makeStore()
        let futureLoad = future.loadForLaunch()
        XCTAssertEqual(futureLoad, .blocked(.unsupportedFutureSchema(onDiskVersion: 99, supportedVersion: 2)))
        let futureWrite = future.replace(with: [])
        XCTAssertEqual(futureWrite, .blocked)
        XCTAssertEqual(try Data(contentsOf: scopeFile), futureBytes)
        future.closeWithoutSealingForTesting()

        let malformedBytes = Data("not json".utf8)
        try malformedBytes.write(to: scopeFile)
        let malformed = makeStore()
        let malformedLoad = malformed.loadForLaunch()
        XCTAssertEqual(malformedLoad, .ready(source: .quarantined, grants: [], revokedScopeIDs: []))
        XCTAssertTrue(try scopeDocument().scopes.isEmpty)
        let backupDirectory = temporaryDirectory.appendingPathComponent("Backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), malformedBytes)
        malformed.closeWithoutSealingForTesting()

        let untouched = temporaryDirectory.appendingPathComponent("suppressed-does-not-exist")
        let suppressed = makeStore(mode: .suppressed, directory: untouched)
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: suppressed)
        XCTAssertEqual(runtime.availability, .ephemeral)
        _ = try grantScope(runtime, to: UUID())
        await runtime.flushPersistence()
        let suppressedWrite = suppressed.replace(with: [])
        XCTAssertEqual(suppressedWrite, .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched.path), "No directory, document, backup, or lock I/O")
    }

    func testFailedRevokeWriteStillAppliesAndTheNextWriteRecordsIt() async throws {
        let gate = DelegationScopeFileWriteGate()
        let store = makeStore(writer: { try gate.write($0, to: $1) })
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store)
        let overseer = UUID()
        let granted = try grantScope(runtime, to: overseer)
        gate.setFailing(true)
        runtime.revoke(scopeID: granted.id)
        XCTAssertEqual(runtime.lastPersistenceOutcome, .writeFailed)
        XCTAssertTrue(runtime.persistenceFailed)
        XCTAssertFalse(runtime.authorize(authorizationRequest(granted)).isAuthorized, "Revocation is immediate in memory")
        XCTAssertEqual(try scopeDocument().scopes.map(\.id), [granted.id], "The failed write left the old bytes")

        // Storage recovers: the next write of any kind carries the revocation.
        gate.setFailing(false)
        _ = try grantScope(runtime, to: UUID())
        XCTAssertFalse(try scopeDocument().scopes.map(\.id).contains(granted.id))
        XCTAssertTrue(try scopeDocument().revokedScopeIDs?.contains(granted.id) == true)
        store.closeWithoutSealingForTesting()

        let nextStore = makeStore()
        let restarted = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await restarted.bootstrap(store: nextStore)
        XCTAssertFalse(restarted.hasLiveScope(grantedTo: overseer))
        nextStore.closeWithoutSealingForTesting()
    }

    func testOpeningFailureBlocksRestorationApprovalAndMCPStatusForExistingAndNewStores() async throws {
        let seed = try grantScope(DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in }), to: UUID())
        for seedCleanDocument in [true, false] {
            if seedCleanDocument {
                try JSONEncoder().encode(DelegationScopeDocument(scopes: [seed.grant], cleanShutdown: true)).write(to: scopeFile)
            } else {
                try FileManager.default.removeItem(at: scopeFile)
            }
            let before = try? Data(contentsOf: scopeFile)
            let store = makeStore(writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
            let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
            await runtime.bootstrap(store: store)
            XCTAssertFalse(runtime.canUseAuthority)
            XCTAssertNotNil(runtime.authorityUnavailableReason)
            XCTAssertTrue(runtime.persistenceFailed)
            XCTAssertFalse(runtime.hasLiveScopeForCatalog(grantedTo: seed.grant.granteeSessionID))
            XCTAssertFalse(runtime.authorize(authorizationRequest(seed)).isAuthorized)
            XCTAssertFalse(runtime.isCurrent(lease(seed)))
            XCTAssertEqual(runtime.attenuate(
                parentScopeID: seed.id, presentedGeneration: seed.generation,
                caller: .agentSession(seed.grant.granteeSessionID), newGranteeSessionID: UUID(),
                newGranteeMemberships: [], capabilities: [.observe], guardrails: .init()
            ).map(\.id), .failure(.unknownScope))
            let fixture = Fixture(runtime: runtime)
            fixture.endpoint = fixture.makeEndpoint(session: seed.grant.granteeSessionID)
            let request = try await fixture.call(["op": .string("request_scope"), "capabilities": .array([.string("observe")])])
            XCTAssertEqual(request["result"], .string("pending_user_approval"))
            XCTAssertEqual(request["authority_available"], .bool(false))
            let requestID = try XCTUnwrap(request["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            XCTAssertEqual(runtime.approve(requestID: requestID).map(\.id), .failure(.unknownScope))
            XCTAssertEqual(runtime.requests[requestID]?.state, .pending)
            let status = try await fixture.call(["op": .string("scope_status")])
            XCTAssertEqual(status["result"], .string("scope_authority_unavailable"))
            XCTAssertEqual(status["authority_available"], .bool(false))
            XCTAssertNotNil(status["authority_status_detail"]?.stringValue)
            XCTAssertEqual(try? Data(contentsOf: scopeFile), before, "Failed opening preserves the trusted bytes or missing file")
            store.closeWithoutSealingForTesting()
        }
    }

    func testFailedCleanOpeningRefusesHumanDeletionAndRestartRestoresOnlyThePreservedSession() async throws {
        let registry = AgentSessionDeletionRegistry.shared
        let previousObserver = registry.commitObserver
        let previousChangeObserver = registry.changeObserver
        registry.test_reset()
        registry.commitObserver = nil
        registry.changeObserver = nil
        defer {
            registry.test_reset()
            registry.commitObserver = previousObserver
            registry.changeObserver = previousChangeObserver
        }
        let overseer = UUID()
        let saved = try makeSavedSession(overseer)
        let record = try grantScope(DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in }), to: overseer)
        let cleanBytes = try JSONEncoder().encode(DelegationScopeDocument(scopes: [record.grant], cleanShutdown: true))
        try cleanBytes.write(to: scopeFile, options: .atomic)
        let failedStore = makeStore(writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let blocked = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        registry.installScopePersistenceAdmission(for: blocked)
        await blocked.bootstrap(store: failedStore)
        XCTAssertFalse(blocked.canUseAuthority)
        XCTAssertNotNil(blocked.durableDeletionUnavailableReason)
        await assertScopePersistenceRefusesDeletion(of: overseer, service: saved.service, workspace: saved.workspace)
        XCTAssertEqual(try Data(contentsOf: saved.fileURL), saved.bytes)
        XCTAssertEqual(try Data(contentsOf: scopeFile), cleanBytes)
        XCTAssertNil(registry.state(forSessionID: overseer), "Refusal must precede even the local deletion tombstone")
        failedStore.closeWithoutSealingForTesting()

        let restartedStore = makeStore()
        let restarted = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        registry.installScopePersistenceAdmission(for: restarted)
        await restarted.bootstrap(store: restartedStore)
        XCTAssertTrue(restarted.hasLiveScope(grantedTo: overseer))
        XCTAssertEqual(try Data(contentsOf: saved.fileURL), saved.bytes, "The restored grant still names an existing payload")
        var committed: [UUID] = []
        registry.commitObserver = { id in
            committed.append(id)
            restarted.revokeAll(involving: id)
        }
        try await saved.service.deleteAgentSession(id: overseer, for: saved.workspace)
        XCTAssertEqual(committed, [overseer])
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.fileURL.path))
        XCTAssertFalse(restarted.hasLiveScope(grantedTo: overseer))
        await restarted.flushPersistence()
        let mayRestore = registry.freezeNewDeletionAdmissionForTermination()
        XCTAssertTrue(mayRestore)
        restarted.freezeForTermination(allowRestoration: mayRestore)
        let sealed = await restarted.settleForTermination()
        XCTAssertTrue(sealed)
        XCTAssertTrue(try scopeDocument().cleanShutdown)
        XCTAssertTrue(try scopeDocument().scopes.isEmpty)
        XCTAssertTrue(try scopeDocument().revokedScopeIDs?.contains(record.id) == true)
        restartedStore.closeWithoutSealingForTesting()
    }

    func testHumanDeletionBeforeOpeningIsRefusedThenCommitRevokesTheRestoredGrant() async throws {
        let registry = AgentSessionDeletionRegistry.shared
        let previousObserver = registry.commitObserver
        let previousChangeObserver = registry.changeObserver
        registry.test_reset()
        registry.commitObserver = nil
        registry.changeObserver = nil
        defer {
            registry.test_reset()
            registry.commitObserver = previousObserver
            registry.changeObserver = previousChangeObserver
        }
        let overseer = UUID()
        let saved = try makeSavedSession(overseer)
        let record = try grantScope(DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in }), to: overseer)
        let cleanBytes = try JSONEncoder().encode(DelegationScopeDocument(scopes: [record.grant]))
        try cleanBytes.write(to: scopeFile, options: .atomic)
        let store = makeStore()
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        registry.installScopePersistenceAdmission(for: runtime)
        var committed: [UUID] = []
        registry.commitObserver = { id in
            committed.append(id)
            runtime.revokeAll(involving: id)
        }
        await assertScopePersistenceRefusesDeletion(of: overseer, service: saved.service, workspace: saved.workspace)
        XCTAssertTrue(committed.isEmpty, "No callback may be lost before restored authority exists")
        XCTAssertNil(registry.state(forSessionID: overseer))
        XCTAssertEqual(try Data(contentsOf: saved.fileURL), saved.bytes)
        XCTAssertEqual(try Data(contentsOf: scopeFile), cleanBytes)
        await runtime.bootstrap(store: store)
        XCTAssertTrue(runtime.hasLiveScope(grantedTo: overseer))
        XCTAssertNil(runtime.durableDeletionUnavailableReason)
        try await saved.service.deleteAgentSession(id: overseer, for: saved.workspace)
        XCTAssertEqual(committed, [overseer])
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.fileURL.path))
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: overseer))
        XCTAssertTrue(try scopeDocument().scopes.isEmpty)
        XCTAssertTrue(try scopeDocument().revokedScopeIDs?.contains(record.id) == true)
        store.closeWithoutSealingForTesting()
    }

    func testDeletionAdmissionRequiresAnOwnerAndDistinguishesFixtureEphemeralFromSuppression() async throws {
        let registry = AgentSessionDeletionRegistry.test_instance(scopePersistenceMode: .requiresStore)
        let sessionID = UUID()
        func assertRefused() {
            XCTAssertThrowsError(try registry.beginDurableDeletion(sessionID: sessionID)) { error in
                guard case let AgentSessionDeletionRegistry.AdmissionError.scopePersistenceUnavailable(reason) = error else {
                    return XCTFail("Expected unavailable persistence, got \(error)")
                }
                XCTAssertFalse(reason.isEmpty)
            }
        }
        assertRefused()
        XCTAssertNil(registry.state(forSessionID: sessionID), "Production has no pre-attach availability bypass")
        var fixture: DelegationScopeRuntime? = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        try registry.installScopePersistenceAdmission(for: XCTUnwrap(fixture))
        let committed = try registry.beginDurableDeletion(sessionID: sessionID)
        await registry.didCommitDurableDeletion(committed)
        fixture = nil
        assertRefused()
        XCTAssertTrue(registry.isPermanentlyDeleted(sessionID: sessionID), "Even a committed-ID retry must pass admission")

        let untouched = temporaryDirectory.appendingPathComponent("suppressed-deletion")
        let suppressed = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        registry.installScopePersistenceAdmission(for: suppressed)
        await suppressed.bootstrap(store: makeStore(mode: .suppressed, directory: untouched))
        XCTAssertTrue(suppressed.canUseAuthority)
        XCTAssertNotNil(suppressed.durableDeletionUnavailableReason)
        assertRefused()
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched.path))
    }

    func testContendingScopeOwnerRefusesHumanDeletionWithoutChangingThePayload() async throws {
        let registry = AgentSessionDeletionRegistry.shared
        let previousObserver = registry.commitObserver
        let previousChangeObserver = registry.changeObserver
        registry.test_reset()
        registry.commitObserver = nil
        registry.changeObserver = nil
        defer {
            registry.test_reset()
            registry.commitObserver = previousObserver
            registry.changeObserver = previousChangeObserver
        }
        let savedID = UUID()
        let saved = try makeSavedSession(savedID)
        let first = makeStore()
        let firstRuntime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await firstRuntime.bootstrap(store: first)
        let before = try Data(contentsOf: scopeFile)
        let contending = makeStore()
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        registry.installScopePersistenceAdmission(for: runtime)
        await runtime.bootstrap(store: contending)
        XCTAssertFalse(runtime.canUseAuthority)
        XCTAssertNotNil(runtime.durableDeletionUnavailableReason)
        await assertScopePersistenceRefusesDeletion(of: savedID, service: saved.service, workspace: saved.workspace)
        XCTAssertNil(registry.state(forSessionID: savedID))
        XCTAssertEqual(try Data(contentsOf: saved.fileURL), saved.bytes)
        XCTAssertEqual(try Data(contentsOf: scopeFile), before)
        contending.closeWithoutSealingForTesting()
        first.closeWithoutSealingForTesting()
    }

    func testStoreOwnershipAndTerminalSealRejectOldQueuedSnapshots() throws {
        let seed = try grantScope(DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in }), to: UUID())
        let first = makeStore()
        _ = first.loadForLaunch()
        _ = first.replace(with: [seed.grant])
        let before = try Data(contentsOf: scopeFile)
        let contending = makeStore()
        let contention = contending.loadForLaunch()
        XCTAssertEqual(contention, .blocked(.ownershipUnavailable))
        XCTAssertEqual(try Data(contentsOf: scopeFile), before)
        let sealed = first.finishLaunch(with: [], revokedScopeIDs: [seed.id])
        XCTAssertEqual(sealed, .applied)
        let sealedBytes = try Data(contentsOf: scopeFile)
        let stale = first.replace(with: [seed.grant])
        XCTAssertEqual(stale, .blocked)
        let repeated = first.finishLaunch(with: [seed.grant])
        XCTAssertEqual(repeated, sealed, "Finalization is terminal and never accepts a second snapshot")
        XCTAssertEqual(try Data(contentsOf: scopeFile), sealedBytes)
        let stillContending = makeStore()
        let stillBlocked = stillContending.loadForLaunch()
        XCTAssertEqual(stillBlocked, .blocked(.ownershipUnavailable), "Successful sealing retains path ownership until exit")
        first.closeWithoutSealingForTesting()
        contending.closeWithoutSealingForTesting()
        stillContending.closeWithoutSealingForTesting()
        let next = makeStore()
        let restored = next.loadForLaunch()
        XCTAssertEqual(restored, .ready(source: .loaded, grants: [], revokedScopeIDs: [seed.id]))
        next.closeWithoutSealingForTesting()
    }

    /// v1 documents migrate their grants, and the legacy launch-state field never gates restoration.
    func testLegacyDocumentsMigrateAndLaunchStateFieldIsIgnored() async throws {
        let record = try grantScope(DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in }), to: UUID())
        for legacy in [true, false] {
            for hasTombstone in [false, true] {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DelegationScopeDocument(
                    scopes: [record.grant], revokedScopeIDs: hasTombstone ? [record.id] : nil, cleanShutdown: false
                ))) as? [String: Any])
                if legacy {
                    object["version"] = 1
                    object.removeValue(forKey: "clean_shutdown")
                }
                try JSONSerialization.data(withJSONObject: object).write(to: scopeFile)
                let store = makeStore()
                let loaded = store.loadForLaunch()
                XCTAssertEqual(loaded, .ready(
                    source: legacy ? .migrated : .loaded,
                    grants: [record.grant], revokedScopeIDs: hasTombstone ? [record.id] : []
                ))
                XCTAssertEqual(try scopeDocument().version, 2)
                XCTAssertEqual(try scopeDocument().scopes, [record.grant], "Loading never rewrites grants away")
                store.closeWithoutSealingForTesting()

                let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
                let nextStore = makeStore()
                await runtime.bootstrap(store: nextStore)
                XCTAssertEqual(runtime.hasLiveScope(grantedTo: record.grant.granteeSessionID), !hasTombstone)
                nextStore.closeWithoutSealingForTesting()
            }
        }
        for field in [nil, NSNull(), "clean", 1] as [Any?] {
            var object: [String: Any] = ["version": 2, "scopes": []]
            object["clean_shutdown"] = field
            try JSONSerialization.data(withJSONObject: object).write(to: scopeFile)
            let store = makeStore()
            XCTAssertEqual(store.loadForLaunch(), .ready(source: .loaded, grants: [], revokedScopeIDs: []))
            store.closeWithoutSealingForTesting()
        }
    }

    /// A corrupt or unverifiable row drops alone; its siblings and tombstones still load.
    func testCorruptEntryDropsOnlyItself() throws {
        let ephemeral = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let first = try grantScope(ephemeral, to: UUID())
        let second = try grantScope(ephemeral, to: UUID())
        let tombstone = UUID()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DelegationScopeDocument(
            scopes: [first.grant, second.grant], revokedScopeIDs: [tombstone]
        ))) as? [String: Any])
        var scopes = try XCTUnwrap(object["scopes"] as? [Any])
        scopes.insert(["id": "not-a-uuid", "kind": ["type": "unknown"]], at: 1)
        scopes.append(42)
        object["scopes"] = scopes
        object["revoked_scope_ids"] = [tombstone.uuidString, "garbage"]
        try JSONSerialization.data(withJSONObject: object).write(to: scopeFile)

        let store = makeStore()
        guard case let .ready(source, grants, revoked) = store.loadForLaunch() else {
            return XCTFail("A document with one corrupt row must still load")
        }
        XCTAssertEqual(source, .loaded)
        XCTAssertEqual(Set(grants.map(\.id)), [first.id, second.id])
        XCTAssertEqual(revoked, [tombstone])
        try XCTAssertEqual(Set(scopeDocument().scopes.map(\.id)), [first.id, second.id])
        store.closeWithoutSealingForTesting()
    }

    /// A deletion that commits while quitting is still recorded, so the next launch cannot restore
    /// authority for the deleted session; the rest of the scope document is untouched.
    func testDeletionCommittedDuringQuitIsStillRecordedAndClosesFurtherDeletionAdmission() async throws {
        let registry = AgentSessionDeletionRegistry.shared
        let previousObserver = registry.commitObserver
        let previousChangeObserver = registry.changeObserver
        registry.test_reset()
        registry.changeObserver = nil
        defer {
            registry.test_reset()
            registry.commitObserver = previousObserver
            registry.changeObserver = previousChangeObserver
        }
        let store = makeStore()
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store)
        let overseer = UUID()
        let record = try grantScope(runtime, to: overseer)
        let bystander = try grantScope(runtime, to: UUID())
        let commitFence = TestReleaseFence(name: "deletion callback before scope revocation")
        defer { commitFence.release() }
        registry.commitObserver = { sessionID in
            await commitFence.enterAndWait()
            runtime.revokeAll(involving: sessionID)
        }
        let attempt = try registry.beginDurableDeletion(sessionID: overseer)
        let callback = Task { await registry.didCommitDurableDeletion(attempt) }
        addTeardownBlock {
            commitFence.release()
            await callback.value
        }
        guard await commitFence.waitUntilEntered(timeout: 3) else { return }
        let mayRestore = registry.freezeNewDeletionAdmissionForTermination()
        runtime.freezeForTermination(allowRestoration: mayRestore)
        XCTAssertThrowsError(try registry.beginDurableDeletion(sessionID: UUID()))
        commitFence.release()
        await callback.value
        XCTAssertEqual(try scopeDocument().scopes.map(\.id), [bystander.id])
        XCTAssertTrue(try scopeDocument().revokedScopeIDs?.contains(record.id) == true)
        let settled = await runtime.settleForTermination()
        XCTAssertTrue(settled)
        store.closeWithoutSealingForTesting()
        let nextStore = makeStore()
        let restarted = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await restarted.bootstrap(store: nextStore)
        XCTAssertFalse(restarted.hasLiveScope(grantedTo: overseer))
        XCTAssertTrue(restarted.hasLiveScope(grantedTo: bystander.grant.granteeSessionID))
        nextStore.closeWithoutSealingForTesting()
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

    func testRequesterCanWithdrawPendingScopeWithoutGrantingAuthority() async throws {
        let fixture = Fixture()
        let requester = UUID(), tab = UUID()
        let endpoint = fixture.makeEndpoint(session: requester, tab: tab)
        fixture.endpoint = endpoint
        let requested = try await fixture.call([
            "op": .string("request_scope"), "idempotency_key": .string("withdraw-pending")
        ])
        let requestID = try XCTUnwrap(requested["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let release: [String: Value] = ["op": .string("release_scope"), "request_id": .string(requestID.uuidString)]
        fixture.endpoint = fixture.makeEndpoint(session: UUID())
        do {
            _ = try await fixture.call(release)
            XCTFail("another requester cannot withdraw the pending card")
        } catch {}
        XCTAssertEqual(fixture.runtime.pendingRequests(forTab: tab, sessionID: requester).map(\.id), [requestID])
        fixture.endpoint = endpoint
        let cancelled = try await fixture.call(release)
        XCTAssertEqual(cancelled["result"], .string("cancelled"))
        XCTAssertTrue(fixture.runtime.pendingRequests(forTab: tab, sessionID: requester).isEmpty)
        XCTAssertFalse(fixture.runtime.hasLiveScope(grantedTo: requester))
        XCTAssertThrowsError(try fixture.runtime.approve(requestID: requestID).get(), "a stale approval card cannot mint authority")
        let repeated = try await fixture.call(release)
        XCTAssertEqual(repeated["result"], .string("already_cancelled"))
        let status = try await fixture.call(["op": .string("scope_status"), "request_id": .string(requestID.uuidString)])
        XCTAssertEqual(status["result"], .string("cancelled"))
        let retriedRequest = try await fixture.call([
            "op": .string("request_scope"), "idempotency_key": .string("withdraw-pending")
        ])
        XCTAssertEqual(retriedRequest["request_id"], requested["request_id"], "withdrawal keeps the idempotency receipt")
        XCTAssertEqual(retriedRequest["result"], .string("cancelled"))
    }

    func testRequestWithdrawalDoesNotReleaseAnAlreadyGrantedScope() async throws {
        let fixture = Fixture()
        let requester = UUID()
        fixture.endpoint = fixture.makeEndpoint(session: requester)
        let requested = try await fixture.call(["op": .string("request_scope")])
        let requestID = try XCTUnwrap(requested["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let granted = try fixture.runtime.approve(requestID: requestID).get()
        let result = try await fixture.call(["op": .string("release_scope"), "request_id": .string(requestID.uuidString)])
        XCTAssertEqual(result["result"], .string("request_not_pending"))
        XCTAssertTrue(fixture.runtime.hasLiveScope(grantedTo: requester))
        do {
            _ = try await fixture.call([
                "op": .string("release_scope"), "request_id": .string(requestID.uuidString),
                "scope_id": .string(granted.id.uuidString)
            ])
            XCTFail("request and grant selectors must not be ambiguous")
        } catch {}
        XCTAssertTrue(fixture.runtime.hasLiveScope(grantedTo: requester))
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
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, now: { clock }, notifyCatalogChanged: { box.ids.append($0) })
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
        let revisionBeforeCatalogRead = runtime.revision
        XCTAssertFalse(runtime.hasLiveScopeForCatalog(grantedTo: overseer))
        XCTAssertEqual(runtime.revision, revisionBeforeCatalogRead, "Catalog reads must not publish or persist expiration")
        XCTAssertEqual(box.ids.count, 5, "Memory-only discovery does not schedule catalog maintenance")
        XCTAssertFalse(runtime.hasLiveScope(grantedTo: overseer))
        XCTAssertEqual(box.ids.count, 6, "expiry relists")
    }

    func testTerminationSealsRevocationAndCleanReloadStillHonorsTombstones() async throws {
        let store = makeStore()
        let runtime = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await runtime.bootstrap(store: store)
        let overseer = UUID()
        let record = try grantScope(runtime, to: overseer)
        await runtime.flushPersistence()
        runtime.revoke(scopeID: record.id)
        // The final snapshot must include the revoke even when its ordinary write is still queued.
        runtime.freezeForTermination(allowRestoration: true)
        let sealed = await runtime.settleForTermination()
        XCTAssertTrue(sealed)
        await runtime.flushPersistence()
        XCTAssertTrue(try scopeDocument().scopes.isEmpty)
        XCTAssertEqual(try scopeDocument().revokedScopeIDs, [record.id])
        store.closeWithoutSealingForTesting()

        // Domain reactivation remains the only decision owner. A clean file with a stale row next
        // to its tombstone never brings the grant back.
        let stale = DelegationScopeDocument(scopes: [record.grant], revokedScopeIDs: [record.id], cleanShutdown: true)
        try JSONEncoder().encode(stale).write(to: scopeFile)
        let nextStore = makeStore()
        let relaunched = DelegationScopeRuntime(persistenceMode: .requiresStore, notifyCatalogChanged: { _ in })
        await relaunched.bootstrap(store: nextStore)
        XCTAssertFalse(relaunched.hasLiveScope(grantedTo: overseer))
        await relaunched.flushPersistence()
        XCTAssertTrue(try scopeDocument().scopes.isEmpty)
        nextStore.closeWithoutSealingForTesting()
    }

    func testAgentProposedGuardrailsAreClampedAndApprovalCannotWidenTheRequest() throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
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
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
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
        var placementAttempts: [UUID] = []
        var placementFailures: Set<UUID> = []
        var placementPersistenceFailures: Set<UUID> = []
        var onPlacementAttempt: (@MainActor () -> Void)?
        fileprivate var links: [Pair: Set<DomainAgentSessionLinkCapability>] = [:]
        fileprivate var added: [Pair] = []
        fileprivate var stopped: [Pair] = []
        var onActiveLink: (@MainActor () -> Void)?
        /// Runs where the shared Add suspends (insert, reservation, activation), before its commit fence.
        var onAddLink: (@MainActor () -> Void)?
        var modelCalls: [(UUID, String)] = []
        var effortCalls: [(UUID, String)] = []
        var lastAuthorization: (@MainActor () -> Bool)?
        var forkCalls: [UUID] = []
        var onForkPreparation: (@MainActor () -> Void)?
        var forkPersistenceFails = false
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
            placementAttempts.append(sessionID)
            onPlacementAttempt?()
            if placementFailures.contains(sessionID) {
                throw NSError(domain: "PlacementFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Placement rejected before commit"])
            }
            placements.append((sessionID, parentID, delegationScopeID))
            let old = provenance.sessions[sessionID]
            provenance.sessions[sessionID] = DelegationSessionProvenance(
                sessionID: sessionID, workspaceID: old?.workspaceID, parentSessionID: old?.parentSessionID,
                createdByOverseerSessionID: nil, organizationalParentID: parentID,
                delegationScopeID: delegationScopeID ?? old?.delegationScopeID, isLive: old?.isLive ?? true,
                boundWorktreeIDs: old?.boundWorktreeIDs ?? [], runState: old?.runState ?? .idle
            )
            let onPersist = onPersist
            let persistenceFails = placementPersistenceFailures.contains(sessionID)
            return DelegationPlacementCommit(pendingWrite: Task { @MainActor in
                await onPersist?()
                if persistenceFails {
                    throw NSError(domain: "PlacementFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Placement persistence failed"])
                }
            })
        }

        func activeLinkCapabilities(observer: UUID, target: UUID) async -> Set<DomainAgentSessionLinkCapability>? {
            onActiveLink?()
            return links[Pair(observer: observer, target: target)]
        }

        var mintedLinkCapabilities: Set<DomainAgentSessionLinkCapability> {
            DomainAgentSessionLinkCapability.managed
        }

        func addLink(
            observer: UUID,
            target: UUID,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async -> SessionAdminLinkOutcome {
            onAddLink?()
            // The bridge re-proves the carried authority at its commit points and fails closed.
            guard isStillAuthorized() else { return .revoked }
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

        func fork(
            sessionID: UUID,
            upToItemID _: UUID?,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async throws -> UUID {
            onForkPreparation?()
            guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
            forkCalls.append(sessionID)
            provenance.add(nextFork, parent: nil)
            if forkPersistenceFails {
                throw SessionAdminPartialForkError(sessionID: nextFork, code: "persist_failed", detail: "Injected first-save failure")
            }
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
        var beforePreviewReturn: (@MainActor () async -> Void)?
        var beforeCreateCommit: (@MainActor () async -> Void)?
        var afterBindAdmission: (@MainActor (UUID, String) async throws -> Void)?
        var failPersistenceAfterBind = false
        var provenance: Provenance?
        var boundElsewhere: [String: Set<UUID>] = [:]
        var retainedBindingsBySession: [UUID: Set<String>] = [:]
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
            baseRef _: String?,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async throws -> SessionAdminWorktreeInfo {
            await beforeCreateCommit?()
            guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
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
            isStillAuthorized: @escaping @MainActor () -> Bool,
            admitBindings: @escaping @MainActor (Set<String>) throws -> Void,
            bindingsCommitted: @escaping @MainActor (Set<String>) -> Void
        ) async throws -> SessionAdminWorktreeInfo {
            guard idle[sessionID] ?? true else { throw SessionAdminHostError.notIdle }
            beforeWrite?()
            guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
            let worktreeID = worktree.hasPrefix("@id:") ? String(worktree.dropFirst(4)) : worktree
            try admitBindings([worktreeID])
            try await afterBindAdmission?(sessionID, worktreeID)
            bindCalls.append((sessionID, worktree))
            bound[sessionID] = [Self.summary(worktreeID)]
            updateProvenance(sessionID, worktrees: [worktreeID])
            bindingsCommitted([worktreeID])
            if failPersistenceAfterBind { throw SessionAdminHostError.invalid("test_persistence_failure") }
            return SessionAdminWorktreeInfo(
                worktreeID: worktreeID, repositoryID: "repo", repoRootPath: "/repo", path: "/managed/\(worktreeID)",
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
            updateProvenance(sessionID, worktrees: Set((bound[sessionID] ?? []).map(\.worktreeID)))
            return removed.map(\.worktreeID)
        }

        private func updateProvenance(_ sessionID: UUID, worktrees: Set<String>) {
            guard let old = provenance?.sessions[sessionID] else { return }
            provenance?.add(
                sessionID, parent: old.parentSessionID, org: old.organizationalParentID,
                workspace: old.workspaceID, scope: old.delegationScopeID,
                laneCreator: old.createdByOverseerSessionID, live: old.isLive, state: old.runState, worktrees: worktrees
            )
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
            for (sessionID, ids) in retainedBindingsBySession {
                for id in ids {
                    result[id, default: []].insert(sessionID)
                }
            }
            for (sessionID, summaries) in bound {
                for summary in summaries {
                    result[summary.worktreeID, default: []].insert(sessionID)
                }
            }
            return result
        }

        func retainedWorktreeIDsAfterReplacingBinding(sessionID: UUID) -> Set<String> {
            retainedBindingsBySession[sessionID] ?? []
        }

        func isWorktreePrunable(path _: String, repoRoot _: String?) async -> Bool {
            false
        }

        func previewMerge(sessionID _: UUID, repoRoot _: String?, mergeTarget _: String?) async throws -> Value {
            await beforePreviewReturn?()
            return .object(["operation_id": .string("op-1")])
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
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let structure: StructureHost
        let worktrees = WorktreeHost()
        let ownership = WorktreeOwnershipStore()
        let core: AgentSessionAdministrationCore
        let worktreeHandler: SessionAdminWorktreeHandler
        let projector: SpawnProvenanceDelegationMembershipProjector
        let names = Names()

        init() {
            structure = StructureHost(provenance: provenance)
            worktrees.provenance = provenance
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

    /// Finding 12: the authority checked before the Add is carried into it. Membership churn or a
    /// revocation landing while the Add itself is suspended fails closed and ends the batch; a live
    /// scope still links.
    func testLinkCarriesScopeAuthorityIntoTheAddTransaction() async throws {
        let fixture = Fixture()
        let overseer = UUID(), a = UUID(), b = UUID(), c = UUID(), outside = UUID()
        fixture.provenance.add(overseer, parent: nil)
        fixture.provenance.add(a, parent: overseer)
        fixture.provenance.add(b, parent: overseer)
        fixture.provenance.add(c, parent: overseer)
        fixture.provenance.add(outside, parent: nil)
        let scope = try fixture.grant(overseer)

        // Live-scope control: the carried predicate holds, so the link is created.
        let live = try await fixture.value(.adminLink, caller: overseer, targets: [a])
        XCTAssertEqual(items(live)[a.uuidString]?["result"], .string("linked"))

        // Membership churn inside the Add: the target leaves the scope's tree mid-transaction.
        fixture.structure.onAddLink = { fixture.provenance.add(b, parent: overseer, org: outside) }
        let churned = try await fixture.value(.adminLink, caller: overseer, targets: [b, c])
        XCTAssertEqual(items(churned)[b.uuidString]?["code"], .string("scope_revoked"))
        XCTAssertEqual(items(churned)[c.uuidString]?["code"], .string("scope_revoked"), "the batch stops")
        XCTAssertEqual(fixture.structure.added, [Pair(observer: overseer, target: a)], "nothing new minted")

        // Revocation inside the Add.
        fixture.structure.onAddLink = { fixture.runtime.revoke(scopeID: scope.id) }
        let revoked = try await fixture.value(.adminLink, caller: overseer, targets: [c])
        XCTAssertEqual(items(revoked)[c.uuidString]?["code"], .string("scope_revoked"))
        XCTAssertEqual(fixture.structure.added, [Pair(observer: overseer, target: a)])
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

    func testPlacementFailureKeepsEarlierReceiptsContinuesAndReleasesReservations() async throws {
        for operation in [DomainAgentSessionTargetOperation.adminReparent, .adminAdopt] {
            let fixture = Fixture()
            let overseer = UUID(), first = UUID(), failed = UUID(), last = UUID()
            let targets = [first, failed, last]
            fixture.provenance.add(overseer, parent: nil)
            for target in targets {
                fixture.provenance.add(target, parent: operation == .adminAdopt ? nil : overseer)
            }
            let scope = try fixture.grant(overseer, guardrails: .init(maxLiveSessions: 4, bulkConfirmationThreshold: 1))
            let args: [String: Value] = ["parent_session_id": .string(overseer.uuidString)]
            let key = "placement-failure-\(operation.rawValue)"
            typealias Organizing = SessionAdminOrganizingOperationTests
            let organizer = Organizing.FakeOrganizer(), links = Organizing.FakeLinks()
            let inventoryProvenance = SessionAdminScopeLifecycleTests.FakeProvenance()
            // FakeInventory deliberately holds unowned references; retain its inputs through apply.
            defer { withExtendedLifetime((organizer, inventoryProvenance, links)) {} }
            let callerTab = UUID()
            let frontDoor = AgentSessionAdministrationFrontDoor(
                core: fixture.core, scopes: fixture.runtime, projector: fixture.projector,
                inventory: Organizing.FakeInventory(
                    organizer: organizer, provenance: inventoryProvenance, links: links, now: Date()
                ),
                liveBoundSession: { $0 == callerTab ? overseer : nil }
            )
            frontDoor.register(SessionAdminRestructureHandler(
                context: SessionAdminHandlerContext(scopes: fixture.runtime, projector: fixture.projector),
                host: fixture.structure
            ))
            let request = AgentSessionAdministrationRequest(
                operation: operation, caller: .agentSession(overseer), callerTabID: callerTab,
                targetSessionIDs: targets, idempotencyKey: key, arguments: args
            )
            guard case let .pendingConfirmation(card, _) = try await frontDoor.perform(request)
            else { return XCTFail("The whole placement batch must be carded") }
            fixture.structure.placementFailures = [failed]
            var persisted = 0
            fixture.structure.onPersist = { persisted += 1 }
            let projector = fixture.projector, runtime = fixture.runtime
            var reservedAtCommit: [Int] = []
            fixture.structure.onPlacementAttempt = {
                let usage = projector.usage(of: scope.grant, spawnParentSessionID: nil)
                reservedAtCommit.append(runtime.usageIncludingReservations(usage).liveSessionCount - usage.liveSessionCount)
            }

            await frontDoor.approveAndApply(confirmationID: card.id, presentedTabID: callerTab, presentedSessionID: overseer)
            let applied = try XCTUnwrap(frontDoor.appliedResult(forConfirmation: card.id))
            let reply = try XCTUnwrap(applied.objectValue)
            let results = items(reply)
            XCTAssertEqual(results.count, 3)
            XCTAssertEqual(results[first.uuidString]?["result"], .string("moved"))
            XCTAssertEqual(results[failed.uuidString]?["result"], .string("not_applied"))
            XCTAssertEqual(results[failed.uuidString]?["code"], .string("placement_failed"))
            XCTAssertEqual(results[failed.uuidString]?["detail"], .string("Placement rejected before commit"))
            XCTAssertEqual(results[last.uuidString]?["result"], .string("moved"), "A failed item must not abort later placements")
            XCTAssertEqual(fixture.structure.placementAttempts, targets)
            XCTAssertEqual(
                reservedAtCommit,
                operation == .adminAdopt ? [1, 1, 1] : [0, 0, 0],
                "Each adoption, including the failing item, holds a live reservation at commit"
            )
            XCTAssertEqual(reply["changed_count"], .int(2), "The stored approval receipt retains both committed placements")
            XCTAssertEqual(fixture.structure.placements.map(\.session), [first, last])
            XCTAssertEqual(persisted, 2, "Both committed placements must finish their durable writes")
            XCTAssertNil(fixture.provenance.sessions[failed]?.organizationalParentID)
            XCTAssertEqual(fixture.provenance.sessions[first]?.organizationalParentID, overseer)
            XCTAssertEqual(fixture.provenance.sessions[last]?.organizationalParentID, overseer)
            XCTAssertEqual(fixture.runtime.confirmations.confirmation(id: card.id, granteeSessionID: overseer)?.state, .consumed)
            await frontDoor.approveAndApply(confirmationID: card.id, presentedTabID: callerTab, presentedSessionID: overseer)
            XCTAssertEqual(frontDoor.appliedResult(forConfirmation: card.id), applied)
            XCTAssertEqual(fixture.structure.placementAttempts, targets, "A consumed card must not apply any item twice")
            let usage = fixture.projector.usage(of: scope.grant, spawnParentSessionID: nil)
            XCTAssertEqual(
                fixture.runtime.usageIncludingReservations(usage).liveSessionCount,
                usage.liveSessionCount,
                "A failed adoption must release its reservation instead of consuming the last slot"
            )
        }
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

    func testForkPartialPersistenceReceiptsReplayWithoutCreatingAnotherSession() async throws {
        for failure in ["first_save", "placement", "placement_save"] {
            let fixture = Fixture()
            let overseer = UUID(), source = UUID()
            fixture.provenance.add(overseer, parent: nil)
            fixture.provenance.add(source, parent: overseer)
            try fixture.grant(overseer)
            let forked = fixture.structure.nextFork
            if failure == "first_save" { fixture.structure.forkPersistenceFails = true }
            if failure == "placement" { fixture.structure.placementFailures.insert(forked) }
            if failure == "placement_save" { fixture.structure.placementPersistenceFailures.insert(forked) }
            let first = try await fixture.value(.adminFork, caller: overseer, targets: [source], key: "partial-fork")
            XCTAssertEqual(first["result"], .string("partial"))
            XCTAssertEqual(first["forked_session_id"], .string(forked.uuidString))
            XCTAssertEqual(first["changed_count"], .int(1))
            XCTAssertEqual(first["joined_scope"], .bool(failure == "placement_save"))
            XCTAssertEqual(first["code"], .string(failure == "placement" ? "placement_failed" : "persist_failed"))
            let replay = try await fixture.value(.adminFork, caller: overseer, targets: [source], key: "partial-fork")
            XCTAssertEqual(replay["result"], .string("replayed"))
            XCTAssertEqual(replay["forked_session_id"], first["forked_session_id"])
            XCTAssertEqual(replay["code"], first["code"])
            XCTAssertEqual(replay["joined_scope"], first["joined_scope"])
            XCTAssertEqual(replay["changed_count"], .int(0))
            XCTAssertEqual(fixture.structure.forkCalls, [source])
            XCTAssertNotNil(fixture.provenance.sessions[forked])
        }
    }

    func testForkRechecksScopeAndMembershipAfterPreparation() async throws {
        for revokeScope in [true, false] {
            let fixture = Fixture()
            let overseer = UUID(), source = UUID()
            fixture.provenance.add(overseer, parent: nil)
            fixture.provenance.add(source, parent: overseer)
            let scope = try fixture.grant(overseer)
            fixture.structure.onForkPreparation = {
                if revokeScope {
                    fixture.runtime.revoke(scopeID: scope.id)
                } else {
                    fixture.provenance.add(source, parent: UUID())
                }
            }
            let result = try await fixture.value(.adminFork, caller: overseer, targets: [source], key: "fork-raced")
            XCTAssertEqual(items(result)[source.uuidString]?["code"], .string("scope_revoked"))
            XCTAssertTrue(fixture.structure.forkCalls.isEmpty)
            XCTAssertTrue(fixture.structure.placements.isEmpty)
            XCTAssertNil(fixture.provenance.sessions[fixture.structure.nextFork])
        }
    }

    // MARK: - Worktrees on behalf

    @MainActor
    private final class BindGate {
        private var hold: CheckedContinuation<Void, Never>?
        private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
        private var paused = false

        func pause() async {
            paused = true
            for waiter in pausedWaiters {
                waiter.resume()
            }
            pausedWaiters.removeAll()
            await withCheckedContinuation { hold = $0 }
        }

        func waitUntilPaused() async {
            if paused { return }
            await withCheckedContinuation { pausedWaiters.append($0) }
        }

        func resume() {
            hold?.resume()
            hold = nil
        }
    }

    func testWorktreeBindEnforcesLimitAndDeduplicatesSharedAndReplacedIdentities() async throws {
        let fixture = Fixture()
        let caller = UUID(), a = UUID(), b = UUID()
        fixture.provenance.add(caller, parent: nil)
        fixture.provenance.add(a, parent: caller, worktrees: ["old"])
        fixture.provenance.add(b, parent: caller)
        fixture.worktrees.bound[a] = [WorktreeHost.summary("old")]
        try fixture.grant(caller, guardrails: .init(maxWorktrees: 1))
        let replacement = try await fixture.value(.adminWorktreeBind, caller: caller, targets: [a], args: ["worktree": .string("new")])
        XCTAssertEqual(items(replacement)[a.uuidString]?["result"], .string("bound"), "Replacing the only binding has no count growth")
        let shared = try await fixture.value(.adminWorktreeBind, caller: caller, targets: [b], args: ["worktree": .string("new")])
        XCTAssertEqual(items(shared)[b.uuidString]?["result"], .string("bound"), "Shared worktree identities count once")
        let denied = try await fixture.value(.adminWorktreeBind, caller: caller, targets: [a], args: ["worktree": .string("third")])
        XCTAssertEqual(items(denied)[a.uuidString]?["code"], .string("scope_guardrail_exceeded"))
        XCTAssertEqual(fixture.worktrees.bound[a]?.map(\.worktreeID), ["new"], "The other member keeps new counted")

        let zero = Fixture()
        let overseer = UUID(), target = UUID()
        zero.provenance.add(overseer, parent: nil)
        zero.provenance.add(target, parent: overseer)
        try zero.grant(overseer, guardrails: .init(maxWorktrees: 0))
        let blocked = try await zero.value(.adminWorktreeBind, caller: overseer, targets: [target], args: ["worktree": .string("external")])
        XCTAssertEqual(items(blocked)[target.uuidString]?["guardrail"], .string("max_worktrees"))
        XCTAssertTrue(zero.worktrees.bindCalls.isEmpty)
    }

    func testWorktreeReplacementCountsTheSameSessionsBindingRetainedInAnotherWindow() async throws {
        let fixture = Fixture()
        let caller = UUID(), target = UUID()
        fixture.provenance.add(caller, parent: nil)
        fixture.provenance.add(target, parent: caller, worktrees: ["old"])
        fixture.worktrees.bound[target] = [WorktreeHost.summary("old")]
        fixture.worktrees.retainedBindingsBySession[target] = ["old"]
        try fixture.grant(caller, guardrails: .init(maxWorktrees: 1))

        let denied = try await fixture.value(.adminWorktreeBind, caller: caller, targets: [target], args: ["worktree": .string("new")])
        XCTAssertEqual(items(denied)[target.uuidString]?["code"], .string("scope_guardrail_exceeded"))
        XCTAssertTrue(fixture.worktrees.bindCalls.isEmpty)
        XCTAssertEqual(fixture.worktrees.bound[target]?.map(\.worktreeID), ["old"])
    }

    func testConcurrentBindsReserveDistinctIdentitiesAndShareTheSameIdentity() async throws {
        for sameIdentity in [false, true] {
            let fixture = Fixture()
            let caller = UUID(), a = UUID(), b = UUID()
            fixture.provenance.add(caller, parent: nil)
            fixture.provenance.add(a, parent: caller)
            fixture.provenance.add(b, parent: caller)
            let scope = try fixture.grant(caller, guardrails: .init(maxWorktrees: 1))
            let gate = BindGate()
            fixture.worktrees.afterBindAdmission = { target, _ in if target == a { await gate.pause() } }
            let first = Task { try await fixture.value(.adminWorktreeBind, caller: caller, targets: [a], args: ["worktree": .string("one")]) }
            await gate.waitUntilPaused()
            let second = try await fixture.value(.adminWorktreeBind, caller: caller, targets: [b], args: ["worktree": .string(sameIdentity ? "one" : "two")])
            XCTAssertEqual(items(second)[b.uuidString]?["result"], .string(sameIdentity ? "bound" : "not_applied"))
            let creation = try await fixture.value(.adminWorktreeCreate, caller: caller, targets: [b])
            XCTAssertEqual(creation["code"], .string("scope_guardrail_exceeded"), "Creation sees a pending bind without double-charging an already-published shared identity")
            gate.resume()
            _ = try await first.value
            let usage = fixture.projector.usage(of: scope.grant, spawnParentSessionID: nil)
            XCTAssertEqual(usage.worktreeCount, 1)
            XCTAssertEqual(fixture.runtime.usageIncludingReservations(usage).worktreeCount, 1, "All binding reservations settle")
        }
    }

    func testCreateAndBindAtTheLimitTransfersReservationToOwnedIdentity() async throws {
        let fixture = Fixture()
        let caller = UUID(), target = UUID()
        fixture.provenance.add(caller, parent: nil)
        fixture.provenance.add(target, parent: caller)
        let scope = try fixture.grant(caller, guardrails: .init(maxWorktrees: 1))
        let reply = try await fixture.value(.adminWorktreeCreate, caller: caller, targets: [target], args: ["bind": .bool(true)])
        XCTAssertEqual(reply["binding"]?.objectValue?["result"], .string("bound"))
        XCTAssertEqual(fixture.worktrees.bound[target]?.map(\.worktreeID), ["wt-1"])
        let usage = fixture.projector.usage(of: scope.grant, spawnParentSessionID: nil)
        XCTAssertEqual(usage.worktreeCount, 1)
        XCTAssertEqual(fixture.runtime.usageIncludingReservations(usage).worktreeCount, 1)
    }

    func testDeferredBindChecksFreshUsageAndFailedPersistenceKeepsCommittedOwnership() async throws {
        let fixture = Fixture()
        let caller = UUID(), target = UUID()
        fixture.provenance.add(caller, parent: nil)
        fixture.provenance.add(target, parent: caller)
        let scope = try fixture.grant(caller, guardrails: .init(maxWorktrees: 1))
        fixture.worktrees.idle[target] = false
        _ = try await fixture.value(.adminWorktreeBind, caller: caller, targets: [target], args: ["worktree": .string("later"), "apply": .string("next_boundary")])
        _ = try await fixture.value(.adminWorktreeCreate, caller: caller, targets: [target])
        fixture.worktrees.becomeIdle(target)
        await fixture.worktreeHandler.settleDeferredBinds()
        guard case .failed? = fixture.worktreeHandler.deferredOutcomes[target] else { return XCTFail("Fresh owned usage must refuse the deferred binding") }
        XCTAssertTrue(fixture.worktrees.bindCalls.isEmpty)

        fixture.ownership.markReleased([WorktreeHost.summary("wt-1")], bySessionID: caller, at: Date())
        fixture.worktrees.failPersistenceAfterBind = true
        let reply = try await fixture.value(.adminWorktreeBind, caller: caller, targets: [target], args: ["worktree": .string("wt-1")])
        XCTAssertEqual(items(reply)[target.uuidString]?["code"], .string("bind_failed"))
        XCTAssertEqual(fixture.worktrees.bound[target]?.map(\.worktreeID), ["wt-1"])
        XCTAssertNil(fixture.ownership.record(worktreeID: "wt-1")?.releasedAt, "Ownership reactivates with publication, even if its later disk flush fails")
        let usage = fixture.projector.usage(of: scope.grant, spawnParentSessionID: nil)
        XCTAssertEqual(fixture.runtime.usageIncludingReservations(usage).worktreeCount, 1)
    }

    func testBindReactivationCannotExceedTheOriginalCreatorsScopeLimit() async throws {
        let fixture = Fixture()
        let original = UUID(), caller = UUID(), target = UUID()
        fixture.provenance.add(original, parent: nil)
        fixture.provenance.add(caller, parent: nil)
        fixture.provenance.add(target, parent: caller)
        let originalScope = try fixture.grant(original, guardrails: .init(maxWorktrees: 0))
        try fixture.grant(caller, guardrails: .init(maxWorktrees: 1))
        fixture.ownership.recordCreation(
            .init(worktreeID: "released", repositoryID: "repo", repoRootPath: "/repo", path: "/managed/released", branch: nil, isPrunable: false),
            createdBySessionID: original, delegationScopeID: originalScope.id, at: Date()
        )
        fixture.ownership.markReleased([WorktreeHost.summary("released")], bySessionID: original, at: Date())
        let reply = try await fixture.value(.adminWorktreeBind, caller: caller, targets: [target], args: ["worktree": .string("released")])
        XCTAssertEqual(items(reply)[target.uuidString]?["code"], .string("scope_guardrail_exceeded"))
        XCTAssertNotNil(fixture.ownership.record(worktreeID: "released")?.releasedAt)
        XCTAssertTrue(fixture.worktrees.bindCalls.isEmpty)
    }

    func testWorktreeCreationRechecksLeaseAndTargetMembershipAtTheFinalFence() async throws {
        for revoke in [true, false] {
            let fixture = Fixture()
            let caller = UUID(), target = UUID()
            fixture.provenance.add(caller, parent: nil)
            fixture.provenance.add(target, parent: caller)
            let scope = try fixture.grant(caller, guardrails: .init(maxWorktrees: 1))
            fixture.worktrees.beforeCreateCommit = {
                await Task.yield()
                if revoke { fixture.runtime.revoke(scopeID: scope.id) }
                else { fixture.provenance.add(target, parent: nil) }
            }
            let reply = try await fixture.value(.adminWorktreeCreate, caller: caller, targets: [target])
            XCTAssertEqual(items(reply)[target.uuidString]?["code"], .string("scope_revoked"))
            XCTAssertTrue(fixture.worktrees.created.isEmpty)
            XCTAssertTrue(fixture.ownership.records.isEmpty)
            let usage = fixture.projector.usage(of: scope.grant, spawnParentSessionID: nil)
            XCTAssertEqual(fixture.runtime.usageIncludingReservations(usage).worktreeCount, 0)
        }
    }

    @MainActor
    private final class CreationFence {
        var preparatoryQueueFinished = false
        var calls = 0
        func deny() throws {
            XCTAssertTrue(preparatoryQueueFinished)
            calls += 1
            throw SessionAdminHostError.authorityEnded
        }
    }

    func testProductionGitCreationFenceRunsAfterPreparationAndDeniesBeforeGitAdd() async throws {
        let repository = try ReviewGitRepositoryFixture(name: "SessionAdminCreationFence")
        defer { repository.cleanup() }
        let source = try repository.makeRepository(named: "source", files: ["README.md": "fixture\n"])
        let destination = repository.sandbox.appendingPathComponent("denied")
        let service = GitService()
        let fence = CreationFence()
        await service.setWorktreeMutationLockAcquiredHandlerForTesting { _ in
            await MainActor.run { fence.preparatoryQueueFinished = true }
        }
        do {
            _ = try await service.createWorktreeWithResult(
                request: .init(path: destination, branch: "denied-branch", cloneTrackedCheckout: false),
                at: source, beforeCommit: { try await fence.deny() }
            )
            XCTFail("Authority lost during preparation must refuse the actual Git creation")
        } catch {
            XCTAssertEqual(error as? SessionAdminHostError, .authorityEnded)
        }
        XCTAssertEqual(fence.calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let refs = try repository.runGit(["for-each-ref", "--format=%(refname)", "refs/heads/denied-branch"], at: source)
        XCTAssertEqual(refs.trimmingCharacters(in: .whitespacesAndNewlines), "")
        let worktrees = try repository.runGit(["worktree", "list", "--porcelain"], at: source)
        XCTAssertFalse(worktrees.contains(destination.path))
    }

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

    func testMergePreviewRechecksAuthorityAfterHostSuspension() async throws {
        for revokeScope in [true, false] {
            let fixture = Fixture()
            let overseer = UUID(), member = UUID()
            fixture.provenance.add(overseer, parent: nil)
            fixture.provenance.add(member, parent: overseer)
            let scope = try fixture.grant(overseer)
            fixture.worktrees.beforePreviewReturn = {
                await Task.yield()
                if revokeScope {
                    fixture.runtime.revoke(scopeID: scope.id)
                } else {
                    fixture.provenance.add(member, parent: nil)
                }
            }
            do {
                _ = try await fixture.value(.adminMergePreview, caller: overseer, targets: [member])
                XCTFail("A preview must not disclose worktree details after its authority ends")
            } catch is MCPError {} catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
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
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
        // The overseer's tab, live-bound to it: cards are presented and approved only there.
        let callerTab = UUID()
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: core, scopes: runtime, projector: projector,
            inventory: Organizing.FakeInventory(organizer: organizer, provenance: inventoryProvenance, links: links, now: Date()),
            liveBoundSession: { $0 == callerTab ? overseer : nil }
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
                operation: operation, caller: .agentSession(overseer), callerTabID: callerTab, targetSessionIDs: targets,
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
        await frontDoor.approveAndApply(confirmationID: card.id, presentedTabID: callerTab, presentedSessionID: overseer)
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
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
        // The overseer's tab, live-bound to it: cards are presented and approved only there.
        let callerTab = UUID()
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: core, scopes: runtime, projector: projector,
            inventory: Organizing.FakeInventory(organizer: organizer, provenance: inventoryProvenance, links: links, now: Date()),
            liveBoundSession: { $0 == callerTab ? overseer : nil }
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
            windowID: window.windowID, workspaceID: workspace, tabID: callerTab, sessionID: overseer,
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
        await frontDoor.approveAndApply(confirmationID: cardID, presentedTabID: callerTab, presentedSessionID: overseer)
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
        /// Distinguishes cancellation admission from its terminal outcome in receipt regressions.
        var stopOutcomeOverride: AgentSessionRunStopOutcome?
        /// Every session whose stored state any write touched, in order.
        var written: [UUID] = []
        /// Archive calls; each re-checks authorization inside the stash's mutation context.
        var archiveAuthorizationChecks = 0
        /// Fail archive after the normal commit-time authority check, without changing stored state.
        var rejectedArchiveSessionIDs: Set<UUID> = []
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
                guard isAuthorized(id), !rejectedArchiveSessionIDs.contains(id) else { continue }
                states[id]?.isArchived = true
                changed.insert(id)
            }
            return changed
        }

        func unarchive(
            _ sessionIDs: [UUID], isAuthorized: @escaping @MainActor (UUID) -> Bool
        ) async -> AgentSessionUnarchiveOutcome {
            var outcome = AgentSessionUnarchiveOutcome()
            for id in sessionIDs where states[id]?.isArchived == true && isAuthorized(id) {
                states[id]?.isArchived = false
                outcome.restored.insert(id)
            }
            return outcome
        }

        func stopRun(
            _ sessionID: UUID, isStillAuthorized: @escaping @MainActor () -> Bool
        ) async -> AgentSessionRunStopOutcome {
            guard isStillAuthorized() else {
                return AgentSessionRunStopOutcome(initiatedCancellation: false, stopped: false)
            }
            stopped.append(sessionID)
            states[sessionID]?.runState = .idle
            return stopOutcomeOverride ?? AgentSessionRunStopOutcome(initiatedCancellation: true, stopped: true)
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
        var recordsComplete = true
        var endpointsComplete = true
        var omittedSessionIDs: Set<UUID> = []
        var readCount = 0
        let now: Date

        init(organizer: FakeOrganizer, provenance: FakeProvenance, links: FakeLinks, now: Date) {
            self.organizer = organizer
            self.provenance = provenance
            self.links = links
            self.now = now
        }

        func snapshot() async -> DomainAgentSessionInventorySnapshot {
            readCount += 1
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
            return DomainAgentSessionInventorySnapshot(
                records: (loaded + historyOnly).filter { !omittedSessionIDs.contains($0.sessionID) },
                edges: edges, isComplete: endpointsComplete, recordsComplete: recordsComplete
            )
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

        func stopLink(
            _ item: DomainAgentSessionLinkInventoryItem,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async -> AgentMonitorStopOutcome {
            guard isStillAuthorized() else { return .failed(message: "authority ended") }
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
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
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

    func testReorderGroupsUndoPreservesLaterGroupAssignmentAtSameRank() async throws {
        let fixture = Fixture()
        let a = fixture.member("A")
        let b = fixture.member("B")
        try fixture.grant()
        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(a.uuidString), "group": .string("Alpha")])
        _ = try await fixture.call(["op": .string("set_group"), "session_id": .string(b.uuidString), "group": .string("Beta")])
        let applied = try await fixture.call([
            "op": .string("reorder_groups"), "workspace": .string(fixture.workspace.uuidString),
            "order": .array([.string("Beta"), .string("Alpha")]),
            "expected_order": .array([.string("Alpha"), .string("Beta")])
        ])
        let token = try XCTUnwrap(applied["undo_token"]?.stringValue)
        XCTAssertEqual(fixture.organizer.states[a]?.sidebarGroupOrder, 1)
        XCTAssertEqual(fixture.organizer.states[b]?.sidebarGroupOrder, 0)

        // A later user edit moves B to another group with the same numeric order.
        fixture.organizer.states[b]?.sidebarGroup = "Gamma"
        fixture.organizer.written.removeAll()
        let undone = try await fixture.call(["op": .string("undo"), "undo_token": .string(token)])
        XCTAssertEqual(undone["result"], .string("partially_undone"))
        XCTAssertEqual(undone["changed_count"], .int(1))
        XCTAssertEqual(items(undone)[a.uuidString], "changed")
        XCTAssertEqual(items(undone)[b.uuidString], "skipped")
        let rows = try XCTUnwrap(undone["items"]?.arrayValue)
        let skipped = try XCTUnwrap(rows.compactMap(\.objectValue).first { $0["session_id"]?.stringValue == b.uuidString })
        XCTAssertEqual(skipped["reason"], .string("changed_since"))
        XCTAssertEqual(fixture.organizer.states[a]?.sidebarGroup, "Alpha")
        XCTAssertEqual(fixture.organizer.states[a]?.sidebarGroupOrder, 0, "unchanged group identity remains undoable")
        XCTAssertEqual(fixture.organizer.states[b]?.sidebarGroup, "Gamma")
        XCTAssertEqual(fixture.organizer.states[b]?.sidebarGroupOrder, 0, "old undo must preserve the later group's rank")
        XCTAssertEqual(fixture.organizer.written, [a])
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

        // One user edit after the original operation must not hide the other target's undo.
        let renamedAgain = try await fixture.call(["op": .string("rename"), "targets": ids([a, b]), "name": .string("Again")])
        let partialToken = try XCTUnwrap(renamedAgain["undo_token"]?.stringValue)
        fixture.organizer.states[b]?.name = "User title"
        let partialUndo = try await fixture.call(["op": .string("undo"), "undo_token": .string(partialToken)])
        XCTAssertEqual(partialUndo["result"], .string("partially_undone"))
        XCTAssertEqual(partialUndo["changed_count"], .int(1))
        XCTAssertEqual(fixture.organizer.states[a]?.name, "A")
        XCTAssertEqual(fixture.organizer.states[b]?.name, "User title")
        let partialReused = try await fixture.call(["op": .string("undo"), "undo_token": .string(partialToken)])
        XCTAssertEqual(partialReused["result"], .string("undo_unavailable"))

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

    func testFilteredPreviewAndMutationRetainIncompleteCoverageAndExactReplay() async throws {
        let fixture = Fixture()
        let known = fixture.member("Known", group: "Cleanup")
        let omitted = fixture.member("Omitted", group: "Cleanup")
        fixture.inventory.recordsComplete = false
        fixture.inventory.endpointsComplete = false
        fixture.inventory.omittedSessionIDs = [omitted]
        try fixture.grant()
        let args: [String: Value] = [
            "op": .string("set_pin"), "filter": .object(["group": .string("Cleanup")]),
            "pinned": .bool(true), "idempotency_key": .string("partial-filter-pin")
        ]
        let preview = try await fixture.call(args.merging(["preview": .bool(true)]) { $1 })
        XCTAssertEqual(preview["result"], .string("preview"))
        XCTAssertEqual(preview["item_count"], .int(1))
        XCTAssertEqual(preview["selection_complete"], .bool(false))
        let coverage = try XCTUnwrap(preview["selection"]?.objectValue)
        XCTAssertEqual(coverage["domain"], .string("loaded_scope_members"))
        XCTAssertEqual(coverage["read_mode"], .string("loaded_only"))
        XCTAssertEqual(coverage["records_complete"], .bool(false))
        XCTAssertEqual(coverage["endpoints_complete"], .bool(false))
        XCTAssertEqual(fixture.organizer.states[known]?.isPinned, false)
        XCTAssertEqual(fixture.organizer.states[omitted]?.isPinned, false)
        XCTAssertTrue(fixture.runtime.confirmations.confirmations.isEmpty)

        let applied = try await fixture.call(args)
        XCTAssertEqual(applied["result"], .string("partial"))
        XCTAssertEqual(applied["selected_result"], .string("applied"))
        XCTAssertEqual(applied["changed_count"], .int(1))
        XCTAssertEqual(Set(items(applied).keys), [known.uuidString])
        XCTAssertEqual(applied["selection"], preview["selection"])
        XCTAssertEqual(fixture.organizer.states[known]?.isPinned, true)
        XCTAssertEqual(fixture.organizer.states[omitted]?.isPinned, false)

        // A later complete scan must not widen an already committed idempotent operation.
        fixture.inventory.recordsComplete = true
        fixture.inventory.endpointsComplete = true
        fixture.inventory.omittedSessionIDs = []
        let reads = fixture.inventory.readCount
        let replay = try await fixture.call(args)
        XCTAssertEqual(replay["idempotent_replay"], .bool(true))
        XCTAssertEqual(replay["result"], .string("partial"))
        XCTAssertEqual(replay["selection"], applied["selection"])
        XCTAssertEqual(fixture.inventory.readCount, reads)
        XCTAssertEqual(fixture.organizer.states[omitted]?.isPinned, false)

        let explicit = try await fixture.call([
            "op": .string("set_pin"), "session_id": .string(omitted.uuidString), "pinned": .bool(true)
        ])
        XCTAssertEqual(explicit["result"], .string("applied"))
        XCTAssertNil(explicit["selection"])
        XCTAssertNil(explicit["selection_complete"])
        XCTAssertEqual(fixture.inventory.readCount, reads, "explicit authorized targets do not enumerate inventory")
        XCTAssertEqual(fixture.organizer.states[omitted]?.isPinned, true)
    }

    func testIncompleteFilteredZeroCannotClaimNoMatchesOrConsumeAnIdempotencyKey() async throws {
        let fixture = Fixture()
        let target = fixture.member("Missing from read", group: "Cleanup")
        fixture.inventory.recordsComplete = false
        fixture.inventory.endpointsComplete = false
        fixture.inventory.omittedSessionIDs = [target]
        try fixture.grant()
        let args: [String: Value] = [
            "op": .string("set_pin"), "filter": .object(["group": .string("Cleanup")]),
            "pinned": .bool(true), "idempotency_key": .string("incomplete-empty")
        ]
        for preview in [true, false] {
            let result = try await fixture.call(args.merging(["preview": .bool(preview)]) { $1 })
            XCTAssertEqual(result["result"], .string("incomplete"))
            XCTAssertEqual(result["code"], .string("inventory_incomplete"))
            XCTAssertEqual(result["retryable"], .bool(true))
            XCTAssertEqual(result["selection_complete"], .bool(false))
            XCTAssertNil(result["items"], "an incomplete zero is not a successful empty target set")
            XCTAssertNil(result["idempotent_replay"])
        }
        XCTAssertEqual(fixture.organizer.states[target]?.isPinned, false)
        XCTAssertTrue(fixture.runtime.confirmations.confirmations.isEmpty)
        fixture.inventory.omittedSessionIDs = []
        let retry = try await fixture.call(args)
        XCTAssertEqual(retry["result"], .string("partial"))
        XCTAssertEqual(retry["changed_count"], .int(1))
        XCTAssertNil(retry["idempotent_replay"])
        XCTAssertEqual(fixture.organizer.states[target]?.isPinned, true)
    }

    func testFilteredCardRetainsOriginalCoverageAndOnlyApprovedTargets() async throws {
        let fixture = Fixture()
        let selected = [fixture.member("A", group: "Cleanup"), fixture.member("B", group: "Cleanup")]
        let omitted = fixture.member("C", group: "Cleanup")
        fixture.inventory.recordsComplete = false
        fixture.inventory.endpointsComplete = false
        fixture.inventory.omittedSessionIDs = [omitted]
        try fixture.grant(threshold: 1)
        let pending = try await fixture.call([
            "op": .string("set_pin"), "filter": .object(["group": .string("Cleanup")]),
            "pinned": .bool(true), "idempotency_key": .string("partial-filter-card")
        ])
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(pending["result"], .string("pending_confirmation"))
        XCTAssertEqual(pending["selection_complete"], .bool(false))
        let before = try await fixture.call([
            "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
        ])
        XCTAssertEqual(before["selection"], pending["selection"])
        fixture.runtime.confirmations.setItem(selected[1], ticked: false, confirmationID: cardID)
        fixture.inventory.recordsComplete = true
        fixture.inventory.endpointsComplete = true
        fixture.inventory.omittedSessionIDs = []
        let reads = fixture.inventory.readCount
        await fixture.approveAndApply(cardID)
        XCTAssertEqual(fixture.inventory.readCount, reads, "approval applies the captured selection without a fresh census")
        XCTAssertEqual(fixture.organizer.states[selected[0]]?.isPinned, true)
        XCTAssertEqual(fixture.organizer.states[selected[1]]?.isPinned, false)
        XCTAssertEqual(fixture.organizer.states[omitted]?.isPinned, false)
        let after = try await fixture.call([
            "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
        ])
        XCTAssertEqual(after["result"], .string("partial"))
        XCTAssertEqual(after["selection"], pending["selection"])
        let receipt = try XCTUnwrap(after["applied_result"]?.objectValue)
        XCTAssertEqual(receipt["result"], .string("partial"))
        XCTAssertEqual(receipt["selected_result"], .string("applied"))
        XCTAssertEqual(receipt["changed_count"], .int(1))
        XCTAssertEqual(receipt["selection"], pending["selection"])
        XCTAssertEqual(fixture.runtime.confirmations.confirmations[cardID]?.state, .consumed)
        await fixture.approveAndApply(cardID)
        XCTAssertEqual(fixture.organizer.states[selected[1]]?.isPinned, false)
        XCTAssertEqual(fixture.organizer.states[omitted]?.isPinned, false)
    }

    func testFilteredCardRetryAfterHandlerFailureKeepsOriginalCoverage() async throws {
        @MainActor
        final class FailOnce: AgentSessionAdministrationOperationHandler {
            let base: AgentSessionOrganizeOperationHandler
            var shouldFail = true
            var operations: Set<DomainAgentSessionTargetOperation> {
                [.adminSetPin]
            }

            init(base: AgentSessionOrganizeOperationHandler) {
                self.base = base
            }

            func confirmationItems(
                for request: AgentSessionAdministrationRequest, scope: DomainDelegationScopeRecord
            ) -> [BatchConfirmationItem] {
                base.confirmationItems(for: request, scope: scope)
            }

            func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
                if shouldFail {
                    shouldFail = false
                    throw NSError(domain: "FilteredCardRetry", code: 1)
                }
                return try await base.perform(batch)
            }
        }
        let fixture = Fixture()
        let targets = [fixture.member("A", group: "Cleanup"), fixture.member("B", group: "Cleanup")]
        fixture.inventory.recordsComplete = false
        fixture.inventory.endpointsComplete = false
        try fixture.grant(threshold: 1)
        let runtime = fixture.runtime
        fixture.frontDoor.register(FailOnce(base: AgentSessionOrganizeOperationHandler(
            backend: fixture.organizer,
            isLeaseCurrent: { runtime.isCurrent($0) },
            holdsControl: { _ in true }
        )))
        let args: [String: Value] = [
            "op": .string("set_pin"), "filter": .object(["group": .string("Cleanup")]),
            "pinned": .bool(true), "idempotency_key": .string("partial-filter-retry")
        ]
        let pending = try await fixture.call(args)
        let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        await fixture.approveAndApply(cardID)
        XCTAssertEqual(fixture.runtime.confirmations.confirmations[cardID]?.state, .approved)
        XCTAssertTrue(targets.allSatisfy { fixture.organizer.states[$0]?.isPinned == false })
        let failed = try await fixture.call([
            "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
        ])
        XCTAssertEqual(failed["applied_result"]?.objectValue?["result"], .string("failed"))
        XCTAssertEqual(failed["selection"], pending["selection"])
        fixture.inventory.recordsComplete = true
        fixture.inventory.endpointsComplete = true
        let retry = try await fixture.call(args.merging(["confirmation_id": .string(cardID.uuidString)]) { $1 })
        XCTAssertEqual(retry["result"], .string("partial"))
        XCTAssertEqual(retry["selected_result"], .string("applied"))
        XCTAssertEqual(retry["changed_count"], .int(2))
        XCTAssertEqual(retry["selection"], pending["selection"])
        XCTAssertEqual(fixture.runtime.confirmations.confirmations[cardID]?.state, .consumed)
        XCTAssertTrue(targets.allSatisfy { fixture.organizer.states[$0]?.isPinned == true })
        let consumed = try await fixture.call([
            "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
        ])
        XCTAssertEqual(consumed["applied_result"]?.objectValue?["selection"], pending["selection"])
        XCTAssertEqual(consumed["result"], .string("partial"))
    }

    func testCompleteWorkspaceRecordCoverageDoesNotRequireGlobalEndpointsForSimpleFilter() async throws {
        let fixture = Fixture()
        let target = fixture.member("A", group: "Cleanup")
        fixture.inventory.recordsComplete = true
        fixture.inventory.endpointsComplete = false
        let request = try fixture.runtime.requestScope(
            requesterSessionID: fixture.overseer, requesterTabID: fixture.tab,
            kind: .workspace(workspaceID: fixture.workspace), capabilities: [.observe, .organize],
            guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        _ = try fixture.runtime.approve(requestID: request.id).get()
        let result = try await fixture.call([
            "op": .string("set_pin"), "filter": .object(["group": .string("Cleanup")]), "pinned": .bool(true)
        ])
        XCTAssertEqual(result["result"], .string("applied"))
        XCTAssertEqual(result["changed_count"], .int(1))
        let coverage = try XCTUnwrap(result["selection"]?.objectValue)
        XCTAssertEqual(coverage["read_mode"], .string("history_and_loaded"))
        XCTAssertEqual(coverage["records_complete"], .bool(true))
        XCTAssertEqual(coverage["endpoints_complete"], .bool(false))
        XCTAssertNil(result["selection_complete"], "complete history alone cannot prove every loaded carrier's identity/membership")
        XCTAssertNil(result["selected_result"])
        XCTAssertEqual(fixture.organizer.states[target]?.isPinned, true)
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

    func testRetireAlreadyArchivedReportsUnchangedAndReplaysConsumedConfirmation() async throws {
        for hasLink in [false, true] {
            let fixture = Fixture()
            let lane = fixture.member("Archived lane", archived: true)
            if hasLink {
                fixture.links.link(fixture.member("Peer"), lane)
            }
            try fixture.grant([.observe, .organize, .restructure])
            let args: [String: Value] = [
                "op": .string("retire"), "session_id": .string(lane.uuidString),
                "idempotency_key": .string("retire-already-archived")
            ]
            let pending = try await fixture.call(args)
            let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            await fixture.approveAndApply(cardID)

            let statusArgs: [String: Value] = [
                "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
            ]
            let status = try await fixture.call(statusArgs)
            let applied = try XCTUnwrap(status["applied_result"]?.objectValue)
            let row = try XCTUnwrap(applied["items"]?.arrayValue?.single?.objectValue)
            let expected: Value = .string(hasLink ? "applied" : "unchanged")
            XCTAssertEqual(status["confirmation_state"], .string("consumed"))
            XCTAssertEqual(status["result"], expected)
            XCTAssertEqual(applied["result"], expected)
            XCTAssertEqual(applied["changed_count"], .int(hasLink ? 1 : 0))
            XCTAssertEqual(row["status"], .string(hasLink ? "changed" : "unchanged"))
            XCTAssertEqual(row["archived"], .bool(true))
            XCTAssertEqual(row["archive_changed"], .bool(false))
            XCTAssertEqual(row["archive_result"], .string("already_archived"))
            XCTAssertNil(row["reason"])
            XCTAssertEqual(fixture.organizer.archiveAuthorizationChecks, 0)
            XCTAssertEqual(fixture.links.stoppedLinkIDs.count, hasLink ? 1 : 0)
            XCTAssertTrue(fixture.links.live.isEmpty, "existing archive state does not skip link release")

            // A later user restore must not be undone by retrying this consumed card's request.
            fixture.organizer.states[lane]?.isArchived = false
            let replay = try await fixture.call(args)
            await fixture.approveAndApply(cardID)
            let repeatedStatus = try await fixture.call(statusArgs)
            XCTAssertEqual(replay["confirmation_id"], .string(cardID.uuidString))
            XCTAssertEqual(replay["confirmation_state"], .string("consumed"))
            XCTAssertEqual(replay["result"], expected)
            XCTAssertEqual(replay["applied_result"], status["applied_result"])
            XCTAssertEqual(repeatedStatus["applied_result"], status["applied_result"])
            XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, false)
            XCTAssertEqual(fixture.organizer.archiveAuthorizationChecks, 0)
            XCTAssertEqual(fixture.links.stoppedLinkIDs.count, hasLink ? 1 : 0)
        }
    }

    func testRetireArchiveFailureRetainsPartialEffectsAndConsumedReceipt() async throws {
        for hasLink in [false, true] {
            let fixture = Fixture()
            let lane = fixture.member("Lane")
            if hasLink {
                fixture.links.link(fixture.member("Peer"), lane)
            }
            fixture.organizer.rejectedArchiveSessionIDs = [lane]
            try fixture.grant([.observe, .organize, .restructure])
            let args: [String: Value] = [
                "op": .string("retire"), "session_id": .string(lane.uuidString),
                "idempotency_key": .string("retire-archive-failure")
            ]
            let pending = try await fixture.call(args)
            let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            await fixture.approveAndApply(cardID)
            let status = try await fixture.call([
                "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
            ])
            let applied = try XCTUnwrap(status["applied_result"]?.objectValue)
            let row = try XCTUnwrap(applied["items"]?.arrayValue?.single?.objectValue)
            let expected: Value = .string(hasLink ? "partial" : "failed")
            XCTAssertEqual(status["confirmation_state"], .string("consumed"))
            XCTAssertEqual(status["result"], expected)
            XCTAssertEqual(applied["result"], expected)
            XCTAssertEqual(applied["changed_count"], .int(0))
            XCTAssertEqual(applied["committed_changes"] == .bool(true), hasLink)
            XCTAssertEqual(row["status"], .string("failed"))
            XCTAssertEqual(row["reason"], .string("archive_rejected"))
            XCTAssertEqual(row["archived"], .bool(false))
            XCTAssertEqual(row["archive_changed"], .bool(false))
            XCTAssertEqual(row["archive_result"], .string("rejected"))
            XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, false)
            XCTAssertEqual(fixture.organizer.archiveAuthorizationChecks, 1)
            XCTAssertEqual(fixture.links.stoppedLinkIDs.count, hasLink ? 1 : 0)

            // Removing the failure does not make the consumed card grant a second attempt.
            fixture.organizer.rejectedArchiveSessionIDs = []
            let replay = try await fixture.call(args)
            await fixture.approveAndApply(cardID)
            XCTAssertEqual(replay["confirmation_id"], .string(cardID.uuidString))
            XCTAssertEqual(replay["result"], expected)
            XCTAssertEqual(replay["applied_result"], status["applied_result"])
            XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, false)
            XCTAssertEqual(fixture.organizer.archiveAuthorizationChecks, 1)
            XCTAssertEqual(fixture.links.stoppedLinkIDs.count, hasLink ? 1 : 0)

            // A new request still requires a new approval before finishing the archive.
            var freshArgs = args
            freshArgs["idempotency_key"] = .string("retire-archive-failure-new-attempt")
            let fresh = try await fixture.call(freshArgs)
            let freshCardID = try XCTUnwrap(fresh["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            XCTAssertNotEqual(freshCardID, cardID)
            XCTAssertEqual(fresh["result"], .string("pending_confirmation"))
            XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, false)
            await fixture.approveAndApply(freshCardID)
            let finished = try await fixture.call([
                "op": .string("confirmation_status"), "confirmation_id": .string(freshCardID.uuidString)
            ])
            XCTAssertEqual(finished["confirmation_state"], .string("consumed"))
            XCTAssertEqual(finished["result"], .string("applied"))
            XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, true)
            XCTAssertEqual(fixture.organizer.archiveAuthorizationChecks, 2)
        }
    }

    func testRetireKeepsInitiatedStopReceiptWhenCompletionWinsAndArchiveFails() async throws {
        let fixture = Fixture()
        do {
            let lane = fixture.member("Running lane", run: .running)
            fixture.organizer.stopOutcomeOverride = AgentSessionRunStopOutcome(initiatedCancellation: true, stopped: false)
            fixture.organizer.rejectedArchiveSessionIDs = [lane]
            try fixture.grant([.observe, .organize, .restructure, .control])
            let args: [String: Value] = [
                "op": .string("retire"), "session_id": .string(lane.uuidString),
                "idempotency_key": .string("retire-admitted-stop-archive-failure")
            ]
            let pending = try await fixture.call(args)
            let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            await fixture.approveAndApply(cardID)
            let status = try await fixture.call([
                "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
            ])
            let applied = try XCTUnwrap(status["applied_result"]?.objectValue)
            let row = try XCTUnwrap(applied["items"]?.arrayValue?.single?.objectValue)
            XCTAssertEqual(status["confirmation_state"], .string("consumed"))
            XCTAssertEqual(status["result"], .string("partial"))
            XCTAssertEqual(applied["result"], .string("partial"))
            XCTAssertEqual(applied["committed_changes"], .bool(true))
            XCTAssertEqual(applied["changed_count"], .int(0))
            XCTAssertEqual(row["stop_requested"], .bool(true))
            XCTAssertEqual(row["stopped"], .bool(false), "cancellation admission must not claim the terminal Stop won")
            XCTAssertEqual(row["status"], .string("failed"))
            XCTAssertEqual(row["reason"], .string("archive_rejected"))
            XCTAssertEqual(row["archive_changed"], .bool(false))
            XCTAssertEqual(row["archive_result"], .string("rejected"))
            XCTAssertEqual(row["archived"], .bool(false))
            XCTAssertEqual(fixture.organizer.stopped, [lane])
            XCTAssertEqual(fixture.organizer.archiveAuthorizationChecks, 1)

            fixture.organizer.stopOutcomeOverride = nil
            fixture.organizer.rejectedArchiveSessionIDs = []
            let replay = try await fixture.call(args)
            await fixture.approveAndApply(cardID)
            XCTAssertEqual(replay["confirmation_id"], .string(cardID.uuidString))
            XCTAssertEqual(replay["result"], .string("partial"))
            XCTAssertEqual(replay["applied_result"], status["applied_result"])
            XCTAssertEqual(fixture.organizer.stopped, [lane], "replay must not issue a second Stop")
            XCTAssertEqual(fixture.organizer.archiveAuthorizationChecks, 1)
            XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, false)
            await fixture.window.tearDown()
        } catch {
            await fixture.window.tearDown()
            throw error
        }
    }

    func testRetireUnlinkFailurePreservesArchiveOutcome() async throws {
        for alreadyArchived in [false, true] {
            let fixture = Fixture()
            let lane = fixture.member("Lane", archived: alreadyArchived)
            fixture.links.link(fixture.member("Peer"), lane)
            let failingLink = try XCTUnwrap(fixture.links.live.single?.linkID)
            fixture.links.failingLinkIDs = [failingLink]
            try fixture.grant([.observe, .organize, .restructure])
            let args: [String: Value] = [
                "op": .string("retire"), "session_id": .string(lane.uuidString),
                "idempotency_key": .string("retire-unlink-failure")
            ]
            let pending = try await fixture.call(args)
            let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            await fixture.approveAndApply(cardID)
            let status = try await fixture.call([
                "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
            ])
            let applied = try XCTUnwrap(status["applied_result"]?.objectValue)
            let row = try XCTUnwrap(applied["items"]?.arrayValue?.single?.objectValue)
            let expected: Value = .string(alreadyArchived ? "failed" : "partial")
            XCTAssertEqual(status["confirmation_state"], .string("consumed"))
            XCTAssertEqual(status["result"], expected)
            XCTAssertEqual(applied["result"], expected)
            XCTAssertEqual(applied["changed_count"], .int(0))
            XCTAssertEqual(applied["committed_changes"] == .bool(true), !alreadyArchived)
            XCTAssertEqual(row["status"], .string("failed"))
            XCTAssertEqual(row["reason"], .string("unlink_failed"))
            XCTAssertEqual(row["archived"], .bool(true))
            XCTAssertEqual(row["archive_changed"], .bool(!alreadyArchived))
            XCTAssertEqual(row["archive_result"], .string(alreadyArchived ? "already_archived" : "changed"))
            XCTAssertEqual(fixture.organizer.states[lane]?.isArchived, true)
            XCTAssertEqual(fixture.links.live.map(\.linkID), [failingLink])
            XCTAssertTrue(fixture.links.stoppedLinkIDs.isEmpty)

            fixture.links.failingLinkIDs = []
            let replay = try await fixture.call(args)
            XCTAssertEqual(replay["applied_result"], status["applied_result"])
            XCTAssertEqual(fixture.links.live.map(\.linkID), [failingLink], "a consumed card does not retry its failed link")
        }
    }

    func testReleaseInterruptedTraversalRetainsReceiptButCompletedTraversalRemainsApplied() async throws {
        for hasRemainingLink in [true, false] {
            let fixture = Fixture()
            addTeardownBlock { @MainActor in
                fixture.links.afterStop = nil
                await fixture.window.tearDown()
            }
            let completedFirst = fixture.member("No links")
            let lane = fixture.member("Lane")
            let first = fixture.member("First")
            let second = fixture.member("Second")
            fixture.links.link(first, lane)
            let firstLink = try XCTUnwrap(fixture.links.live.single?.linkID)
            if hasRemainingLink { fixture.links.link(second, lane) }
            let remainingLink = hasRemainingLink ? fixture.links.live.last?.linkID : nil
            try fixture.grant([.observe, .organize, .restructure], threshold: 1)
            let args: [String: Value] = [
                "op": .string("release"), "targets": ids([completedFirst, lane]),
                "idempotency_key": .string("release-interrupted")
            ]
            let pending = try await fixture.call(args)
            let cardID = try XCTUnwrap(pending["confirmation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            // Both the target and the remaining counterpart leave the tree after the first commit.
            // Checking the counterpart first would hide the interruption as an outside-scope link.
            fixture.links.afterStop = { _ in
                fixture.provenance.add(lane, parent: UUID(), workspace: fixture.workspace)
                fixture.provenance.add(second, parent: UUID(), workspace: fixture.workspace)
            }
            await fixture.approveAndApply(cardID)
            let statusArgs: [String: Value] = [
                "op": .string("confirmation_status"), "confirmation_id": .string(cardID.uuidString)
            ]
            let status = try await fixture.call(statusArgs)
            let applied = try XCTUnwrap(status["applied_result"]?.objectValue)
            let row = try XCTUnwrap(
                applied["items"]?.arrayValue?.compactMap(\.objectValue)
                    .first { $0["session_id"] == .string(lane.uuidString) }
            )
            let expected: Value = .string(hasRemainingLink ? "partial" : "applied")
            XCTAssertEqual(status["confirmation_state"], .string("consumed"))
            XCTAssertEqual(status["result"], expected)
            XCTAssertEqual(applied["result"], expected)
            XCTAssertEqual(applied["committed_changes"], .bool(true))
            XCTAssertEqual(applied["changed_count"], .int(hasRemainingLink ? 0 : 1))
            XCTAssertEqual(applied["unlinked_total"], .int(1))
            XCTAssertEqual(items(applied)[completedFirst.uuidString], "unchanged")
            XCTAssertEqual(row["status"], .string(hasRemainingLink ? "failed" : "changed"))
            XCTAssertEqual(row["reason"]?.stringValue, hasRemainingLink ? "scope_no_longer_current" : nil)
            XCTAssertEqual(row["unlinked"], .int(1))
            XCTAssertNil(row["links_outside_scope"], "authority loss is not an ordinary outsider filter")
            XCTAssertEqual(fixture.links.stoppedLinkIDs, [firstLink])
            XCTAssertEqual(fixture.links.live.map(\.linkID), remainingLink.map { [$0] } ?? [])

            // Restoring membership does not let the consumed approval retry the unfinished link.
            fixture.provenance.add(lane, parent: fixture.overseer, workspace: fixture.workspace)
            fixture.provenance.add(second, parent: fixture.overseer, workspace: fixture.workspace)
            fixture.links.afterStop = nil
            let replay = try await fixture.call(args)
            await fixture.approveAndApply(cardID)
            let repeatedStatus = try await fixture.call(statusArgs)
            XCTAssertEqual(replay["confirmation_id"], .string(cardID.uuidString))
            XCTAssertEqual(replay["confirmation_state"], .string("consumed"))
            XCTAssertEqual(replay["result"], expected)
            XCTAssertEqual(replay["applied_result"], status["applied_result"])
            XCTAssertEqual(repeatedStatus["applied_result"], status["applied_result"])
            XCTAssertEqual(fixture.links.stoppedLinkIDs, [firstLink])
            XCTAssertEqual(fixture.links.live.map(\.linkID), remainingLink.map { [$0] } ?? [])
        }
    }

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
        XCTAssertEqual(first["result"], .string("partial"))
        XCTAssertEqual(first["committed_changes"], .bool(true), "the first unlink still took effect")
        XCTAssertEqual(fixture.links.stoppedLinkIDs.count, 1)

        // The same key replays the partial receipt; it never re-runs the release.
        fixture.links.failingLinkIDs = []
        let retry = try await fixture.call(args)
        XCTAssertEqual(retry["idempotent_replay"], .bool(true))
        XCTAssertEqual(retry["result"], .string("partial"))
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
        XCTAssertEqual(status["confirmation_state"], .string("consumed"))
        XCTAssertEqual(status["result"], .string("not_applied"))
        XCTAssertEqual(applied["result"], .string("not_applied"))
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
        XCTAssertEqual(reply["result"], .string("partial"))
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
        XCTAssertEqual(undone["result"], .string("not_undone"))
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
        XCTAssertEqual(reply["result"], .string("partial"))
        XCTAssertEqual(reply["changed_count"], .int(1))
        XCTAssertEqual(items(reply)[loaded.uuidString], "changed")
        XCTAssertEqual(items(reply)[unloaded.uuidString], "skipped")
        let only = try await fixture.call(["op": .string("set_pin"), "session_id": .string(unloaded.uuidString), "pinned": .bool(true)])
        XCTAssertEqual(only["result"], .string("not_applied"))
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
        XCTAssertEqual(noop["result"], .string("unchanged"))
        XCTAssertEqual(items(noop)[a.uuidString], "unchanged")
        fixture.organizer.states[a]?.isPinned = false
        let retry = try await fixture.call(args)
        XCTAssertNil(retry["idempotent_replay"])
        XCTAssertEqual(retry["result"], .string("applied"))
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
    func testArchiveRechecksMembershipAfterStashPreparation() async throws {
        let fixture = Fixture()
        let target = fixture.member("Moving target")
        try fixture.grant([.observe, .organize])
        fixture.organizer.onStashSuspension = { id in
            fixture.provenance.add(id, parent: UUID(), workspace: fixture.workspace)
        }
        let reply = try await fixture.call(["op": .string("archive"), "session_id": .string(target.uuidString)])
        XCTAssertEqual(reply["changed_count"], .int(0))
        XCTAssertEqual(fixture.organizer.states[target]?.isArchived, false)
    }

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
        XCTAssertEqual(result["result"], .string("partial"))
        XCTAssertEqual(result["committed_changes"], .bool(true))
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
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, windows: { windows }, notifyCatalogChanged: { _ in })
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

    func testModelAndEffortCannotCommitAfterTargetLeavesScopeDuringHostSuspension() async throws {
        for operation in [DomainAgentSessionTargetOperation.adminSetModel, .adminSetEffort] {
            let fixture = SessionAdminStructureTests.Fixture()
            let root = UUID(), target = UUID()
            fixture.provenance.add(root, parent: nil)
            fixture.provenance.add(target, parent: root)
            let scope = try fixture.grant(root, [.control])
            let host = ConfigurationHost()
            let context = SessionAdminHandlerContext(scopes: fixture.runtime, projector: fixture.projector)
            fixture.core.register(SessionAdminLifecycleHandler(context: context, host: host))
            host.beforeCommit = {
                await Task.yield()
                fixture.provenance.add(target, parent: nil, org: UUID())
            }
            let args: [String: Value] = operation == .adminSetModel
                ? ["model_id": .string("claudeCode:opus")] : ["effort": .string("high")]
            let blocked = try await fixture.value(operation, caller: root, targets: [target], args: args)
            XCTAssertEqual(blocked["changed_count"], .int(0))
            XCTAssertEqual(host.committed, [])
            XCTAssertEqual(host.attempts, 1)
            XCTAssertEqual(
                fixture.runtime.record(id: scope.id)?.generation,
                scope.generation,
                "the lease remains current; membership loss alone must fence the write"
            )

            fixture.provenance.add(target, parent: root)
            host.beforeCommit = { await Task.yield() }
            let applied = try await fixture.value(operation, caller: root, targets: [target], args: args)
            XCTAssertEqual(applied["changed_count"], .int(1))
            XCTAssertEqual(host.committed, [target])
        }
    }

    private final class ConfigurationHost: SessionAdminStructureHost {
        var beforeCommit: @MainActor () async -> Void = {}
        var committed: [UUID] = []
        var attempts = 0

        private func commit(_ id: UUID, authorized: @escaping @MainActor () -> Bool) async -> SessionAdminLifecycleOutcome {
            attempts += 1
            await beforeCommit()
            guard authorized() else { return .blocked("authority ended") }
            committed.append(id)
            return .applied(changed: true, fields: [:])
        }

        func setModel(sessionID: UUID, modelID _: String, isStillAuthorized: @escaping @MainActor () -> Bool) async -> SessionAdminLifecycleOutcome {
            await commit(sessionID, authorized: isStillAuthorized)
        }

        func setEffort(sessionID: UUID, effort _: String, isStillAuthorized: @escaping @MainActor () -> Bool) async -> SessionAdminLifecycleOutcome {
            await commit(sessionID, authorized: isStillAuthorized)
        }

        var mintedLinkCapabilities: Set<DomainAgentSessionLinkCapability> {
            []
        }

        func commitOrganizationalPlacement(sessionID _: UUID, parentID _: UUID, delegationScopeID _: UUID?) throws -> DelegationPlacementCommit? {
            XCTFail("unexpected placement")
            return nil
        }

        func activeLinkCapabilities(observer _: UUID, target _: UUID) async -> Set<DomainAgentSessionLinkCapability>? {
            XCTFail("unexpected link lookup")
            return nil
        }

        func addLink(observer _: UUID, target _: UUID, isStillAuthorized _: @escaping @MainActor () -> Bool) async -> SessionAdminLinkOutcome {
            XCTFail("unexpected add link")
            return .revoked
        }

        func stopLink(observer _: UUID, target _: UUID, isStillAuthorized _: @escaping @MainActor () -> Bool) async -> SessionAdminLinkOutcome {
            XCTFail("unexpected stop link")
            return .revoked
        }

        func fork(
            sessionID _: UUID,
            upToItemID _: UUID?,
            isStillAuthorized _: @escaping @MainActor () -> Bool
        ) async throws -> UUID {
            throw SessionAdminHostError.sessionUnavailable
        }
    }
}

// MARK: - SessionAdminDeferredOutcomeTests regressions

@MainActor
final class SessionAdminDeferredOutcomeTests: XCTestCase {
    func testFailedDeferredBindIsVisibleOnlyWhileTargetRemainsScopeMember() async throws {
        let fixture = SessionAdminStructureTests.Fixture()
        let caller = UUID(), target = UUID()
        fixture.provenance.add(caller, parent: nil)
        fixture.provenance.add(target, parent: caller)
        try fixture.grant(caller)
        let host = Host(base: fixture.worktrees)
        host.failBinding = true
        let handler = SessionAdminWorktreeHandler(
            context: .init(scopes: fixture.runtime, projector: fixture.projector), host: host, ownership: fixture.ownership
        )
        fixture.core.register(handler)
        fixture.worktrees.idle[target] = false
        let queued = try await fixture.value(
            .adminWorktreeBind,
            caller: caller,
            targets: [target],
            args: ["worktree": .string("test-worktree"), "apply": .string("next_boundary")]
        )
        XCTAssertEqual(queued["items"]?.arrayValue?.first?.objectValue?["result"], .string("queued"))
        fixture.worktrees.becomeIdle(target)
        await handler.settleDeferredBinds()
        XCTAssertNil(handler.pendingBinds[target])
        let inventory = try await fixture.value(.adminWorktreeInventory, caller: caller)
        let outcome = try XCTUnwrap(inventory["deferred_outcomes"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(outcome["session_id"], .string(target.uuidString))
        XCTAssertEqual(outcome["result"], .string("not_applied"))
        XCTAssertEqual(outcome["code"], .string("bind_failed"))
        XCTAssertEqual(outcome["detail"], .string("test_bind_failure"))
        XCTAssertEqual(inventory["pending_binds"], .array([]))
        fixture.provenance.add(target, parent: nil, org: UUID())
        let restricted = try await fixture.value(.adminWorktreeInventory, caller: caller)
        XCTAssertEqual(restricted["deferred_outcomes"], .array([]), "A prior outcome must not disclose an out-of-scope target")
    }

    func testWorktreeInventoryRefusesRevocationAndMembershipChangeDuringPrunabilityAwait() async throws {
        for revoke in [true, false] {
            let fixture = SessionAdminStructureTests.Fixture()
            let caller = UUID(), target = UUID()
            fixture.provenance.add(caller, parent: nil)
            fixture.provenance.add(target, parent: caller)
            let scope = try fixture.grant(caller)
            fixture.worktrees.bound[target] = [SessionAdminStructureTests.WorktreeHost.summary("private-worktree")]
            let host = Host(base: fixture.worktrees)
            host.onPrunability = {
                if revoke { fixture.runtime.revoke(scopeID: scope.id) }
                else { fixture.provenance.add(target, parent: nil, org: UUID()) }
            }
            fixture.core.register(SessionAdminWorktreeHandler(
                context: .init(scopes: fixture.runtime, projector: fixture.projector), host: host, ownership: fixture.ownership
            ))
            do {
                _ = try await fixture.value(.adminWorktreeInventory, caller: caller)
                XCTFail("A pre-await inventory must not disclose after authority changes")
            } catch {
                XCTAssertEqual(String(describing: error), String(describing: SessionAdminMCPToolService.unavailableError))
            }
        }
    }

    private final class Host: SessionAdminWorktreeHost {
        let base: SessionAdminStructureTests.WorktreeHost
        var failBinding = false
        var onPrunability: (() -> Void)?
        init(base: SessionAdminStructureTests.WorktreeHost) {
            self.base = base
        }

        func createWorktree(
            forSession sessionID: UUID, repoRoot: String?, branch: String?, baseRef: String?,
            isStillAuthorized: @escaping @MainActor () -> Bool
        ) async throws -> SessionAdminWorktreeInfo {
            try await base.createWorktree(
                forSession: sessionID, repoRoot: repoRoot, branch: branch, baseRef: baseRef,
                isStillAuthorized: isStillAuthorized
            )
        }

        func bindWorktree(
            sessionID: UUID, worktree: String, repoRoot: String?, isStillAuthorized: @escaping @MainActor () -> Bool,
            admitBindings: @escaping @MainActor (Set<String>) throws -> Void,
            bindingsCommitted: @escaping @MainActor (Set<String>) -> Void
        ) async throws -> SessionAdminWorktreeInfo {
            if failBinding { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test_bind_failure"]) }
            return try await base.bindWorktree(
                sessionID: sessionID, worktree: worktree, repoRoot: repoRoot, isStillAuthorized: isStillAuthorized,
                admitBindings: admitBindings, bindingsCommitted: bindingsCommitted
            )
        }

        func unbindWorktrees(sessionID: UUID, worktreeID: String?, isStillAuthorized: @escaping @MainActor () -> Bool) async throws -> [String] {
            try await base.unbindWorktrees(sessionID: sessionID, worktreeID: worktreeID, isStillAuthorized: isStillAuthorized)
        }

        func boundWorktrees(sessionID: UUID) -> [AgentSessionWorktreeBindingSummary] {
            base.boundWorktrees(sessionID: sessionID)
        }

        func isIdleForWorktreeTransition(sessionID: UUID) -> Bool {
            base.isIdleForWorktreeTransition(sessionID: sessionID)
        }

        func waitForIdleBoundary(sessionID: UUID) async {
            await base.waitForIdleBoundary(sessionID: sessionID)
        }

        func allBoundWorktrees() -> [String: Set<UUID>] {
            base.allBoundWorktrees()
        }

        func retainedWorktreeIDsAfterReplacingBinding(sessionID: UUID) -> Set<String> {
            base.retainedWorktreeIDsAfterReplacingBinding(sessionID: sessionID)
        }

        func isWorktreePrunable(path: String, repoRoot: String?) async -> Bool {
            await Task.yield()
            onPrunability?()
            return false
        }

        func previewMerge(sessionID: UUID, repoRoot: String?, mergeTarget: String?) async throws -> Value {
            try await base.previewMerge(sessionID: sessionID, repoRoot: repoRoot, mergeTarget: mergeTarget)
        }

        func applyMerge(sessionID: UUID, operationID: String) async throws -> Value {
            try await base.applyMerge(sessionID: sessionID, operationID: operationID)
        }
    }
}

// MARK: - SessionAdminInventoryReadTests regressions

@MainActor
final class SessionAdminInventoryReadTests: XCTestCase {
    private final class Flag {
        var value: Bool
        init(_ value: Bool) {
            self.value = value
        }
    }

    /// Exercises the production inventory source, not a replacement snapshot implementation.
    private actor Scanner: HistorySessionScanning {
        var queries: [String?] = []
        var budgets: [HistoryRequestBudget] = []
        var cancelOnScan = false
        var workspaces: [HistoryWorkspaceScanResult] = []
        var directRecords: [UUID: AgentSessionMetadataRecord] = [:]
        var directQueries: [UUID] = []

        func setDirectRecords(_ records: [AgentSessionMetadataRecord]) {
            directRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        }

        func capturedDirectQueries() -> [UUID] {
            directQueries
        }

        func locateSession(sessionID: UUID, requestBudget: HistoryRequestBudget) async throws -> HistoryDirectSessionLookup {
            directQueries.append(sessionID)
            budgets.append(requestBudget)
            if cancelOnScan { throw CancellationError() }
            let location = directRecords[sessionID].map {
                HistoryDirectSessionLocation(record: $0, workspaceName: "Exact history", workspaceDir: URL(fileURLWithPath: "/tmp/inventory-direct"))
            }
            return HistoryDirectSessionLookup(location: location, diagnostics: [], isComplete: true)
        }

        func setWorkspaces(_ value: [HistoryWorkspaceScanResult]) {
            workspaces = value
        }

        func setCancellation() {
            cancelOnScan = true
        }

        func capturedQueries() -> [String?] {
            queries
        }

        func capturedBudgets() -> [HistoryRequestBudget] {
            budgets
        }

        func scanWorkspaces(matching workspace: String?, requestBudget: HistoryRequestBudget) async throws -> HistoryInventoryScan {
            queries.append(workspace)
            budgets.append(requestBudget)
            if cancelOnScan { throw CancellationError() }
            return HistoryInventoryScan(workspaces: workspaces)
        }

        func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult] {
            XCTFail("inventory must use the budget-aware scanner seam")
            return []
        }

        func scanAllWorkspacesRefreshing() async throws -> [HistoryWorkspaceScanResult] {
            []
        }

        nonisolated func sessionsMatchingFilters(
            _: [HistoryWorkspaceScanResult], workspace _: String?, agentKind _: String?, model _: String?,
            filePath _: String?, from _: Date?, to _: Date?
        ) -> [HistoryFilteredSessionRecord] {
            []
        }

        func loadTranscriptForSearch(sessionID _: UUID, workspaceDir _: URL) async throws -> AgentTranscript {
            throw CancellationError()
        }

        func transcriptDerivedFieldsAreStale(
            for _: AgentSessionMetadataRecord, sessionID _: UUID, workspaceDir _: URL
        ) async -> Bool {
            false
        }
    }

    private func grant(
        runtime: DelegationScopeRuntime, caller: UUID, kind: DomainDelegationScopeKind
    ) throws -> DomainDelegationScopeRecord {
        let request = try runtime.requestScope(
            requesterSessionID: caller, requesterTabID: UUID(), kind: kind,
            capabilities: [.observe, .organize], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        return try runtime.approve(requestID: request.id).get()
    }

    func testWorkspaceReadPushesSelectorAndBudgetIntoProductionScannerWithoutClaimingGlobalCompleteness() async throws {
        let scanner = Scanner()
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let workspace = UUID()
        let budget = HistoryRequestBudget.standalone()
        let snapshot = try await source.snapshot(read: .init(workspaceID: workspace, budget: budget))
        let queries = await scanner.capturedQueries()
        let budgets = await scanner.capturedBudgets()
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first, workspace.uuidString)
        XCTAssertTrue(budgets.first === budget)
        XCTAssertFalse(snapshot.isComplete, "workspace absence is not global deletion proof")
        XCTAssertTrue(snapshot.recordsComplete, "the selected workspace can still have complete record coverage")
    }

    func testWorkspaceInventoryUsesOwnerSelectedCustomLocationWithoutEnumeratingOtherWorkspaces() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-owner-location-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspaceID = UUID(), caller = UUID(), target = UUID()
        // Capture both URL representations before storage exists. An unhinted URL must keep
        // naming this same registered directory after Foundation recognizes it as a directory.
        let locations = [false, true].map { isDirectory in
            HistoryWorkspaceLocation(
                runtimeID: UUID(), workspaceID: workspaceID, name: "Custom inventory",
                directory: directory.appendingPathComponent("CustomWorkspace", isDirectory: isDirectory)
            )
        }
        let sessions = locations[0].directory.appendingPathComponent("AgentSessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [directRecord(id: target, parent: nil, workspace: workspaceID)]))
            .write(to: sessions.appendingPathComponent("AgentSessionIndex.json"))
        for location in locations {
            let scanner = HistorySessionScanner(
                applicationSupportRoot: directory,
                workspaceDirectoryProvider: { _ in XCTFail("workspace inventory must not enumerate the application root")
                    return []
                },
                workspaceLocations: .init(resolve: { selector in
                    guard selector == .id(workspaceID) else {
                        XCTFail("scope selector must reach the owner as its UUID")
                        return .unavailable
                    }
                    return .matched(location)
                })
            )
            let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
            let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
            let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspaceID))
            let handler = AgentSessionInventoryOperationHandler(
                source: source, scopeChain: { runtime.scopeChain(from: $0) },
                isScopeCurrent: { runtime.record(id: $0.id)?.generation == $0.generation },
                isLeaseCurrent: { runtime.isCurrent($0) }
            )
            let value = try await handler.perform(.init(
                request: .init(operation: .adminInventory, caller: .agentSession(caller)),
                scope: scope, leases: [], bases: [], itemsRequiringControl: [], confirmation: nil
            ))
            let reply = try XCTUnwrap(value.objectValue)
            XCTAssertEqual(reply["total"], .int(1))
            XCTAssertEqual(reply["total_complete"], .bool(true))
            XCTAssertEqual(reply["history_complete"], .bool(true))
            XCTAssertEqual(reply["endpoints_complete"], .bool(false))
            let rows = try XCTUnwrap(reply["sessions"]?.arrayValue)
            XCTAssertEqual(rows.compactMap { $0.objectValue?["session_id"]?.stringValue }, [target.uuidString])
            XCTAssertEqual(rows.first?.objectValue?["workspace_id"], .string(workspaceID.uuidString))
            let indexReads = await scanner.indexDecodeCountForTesting
            let transcriptReads = await scanner.transcriptDecodeCountForTesting
            XCTAssertEqual(indexReads, 1)
            XCTAssertEqual(transcriptReads, 0)
        }
    }

    func testWorkspaceInventorySeparatesRecordCoverageFromUnknownOrganizationAndEndpoints() async throws {
        let scanner = Scanner()
        let stored = projectionWorkspace(count: 2)
        await scanner.setWorkspaces([stored])
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: XCTUnwrap(stored.workspaceID)))
        let handler = AgentSessionInventoryOperationHandler(
            source: source, scopeChain: { runtime.scopeChain(from: $0) },
            isScopeCurrent: { runtime.record(id: $0.id)?.generation == $0.generation },
            isLeaseCurrent: { runtime.isCurrent($0) }
        )
        func read(_ filter: [String: Value]? = nil) async throws -> [String: Value] {
            let batch = AgentSessionAdministrationAuthorizedBatch(
                request: .init(
                    operation: .adminInventory, caller: .agentSession(caller),
                    arguments: filter.map { ["filter": .object($0)] } ?? [:]
                ), scope: scope, leases: [], bases: [], itemsRequiringControl: [], confirmation: nil
            )
            let value = try await handler.perform(batch)
            return try XCTUnwrap(value.objectValue)
        }
        let result = try await read()
        XCTAssertEqual(result["total"], .int(2))
        XCTAssertEqual(result["total_complete"], .bool(true))
        XCTAssertEqual(result["history_complete"], .bool(true))
        XCTAssertEqual(result["endpoints_complete"], .bool(false))
        for row in try XCTUnwrap(result["sessions"]?.arrayValue) {
            let object = try XCTUnwrap(row.objectValue)
            XCTAssertEqual(object["organization_complete"], .bool(false))
            XCTAssertNil(object["archived"])
            XCTAssertNil(object["pinned"])
            XCTAssertNil(object["group"])
            XCTAssertEqual(object["orphan_status_complete"], .bool(false))
        }
        let filters: [[String: Value]] = [["pinned": .bool(false)], ["archived": .bool(false)], ["group": .string("")]]
        for filter in filters {
            let filtered = try await read(filter)
            XCTAssertEqual(filtered["sessions"], .array([]))
            XCTAssertEqual(filtered["total_complete"], .bool(false), "unknown sidebar state may hide matches")
        }
        let projector = SpawnProvenanceDelegationMembershipProjector(source: SessionAdminScopeLifecycleTests.FakeProvenance())
        let core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: core, scopes: runtime, projector: projector, inventory: source, liveBoundSession: { _ in caller }
        )
        let mutation = Handler()
        frontDoor.register(mutation)
        let outcome = try await frontDoor.perform(.init(
            operation: .adminRename, caller: .agentSession(caller), scopeID: scope.id,
            arguments: ["filter": .object(["pinned": .bool(false)]), "name": .string("Renamed")]
        ))
        guard case let .completed(value) = outcome else { return XCTFail("expected incomplete inventory outcome") }
        XCTAssertEqual(value.objectValue?["code"], .string("inventory_incomplete"))
        XCTAssertFalse(mutation.performed, "unknown sidebar state must not produce a mutation or false no-matching result")
    }

    func testLoadedOnlyReadDoesNotOpenHistoryAndCannotProveOrphans() async throws {
        let scanner = Scanner()
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let snapshot = try await source.snapshot(read: .init(loadedOnly: true))
        let queries = await scanner.capturedQueries()
        XCTAssertTrue(queries.isEmpty)
        XCTAssertFalse(snapshot.isComplete)
    }

    func testProductionScannerCancellationPropagatesInsteadOfReturningEmptySuccess() async throws {
        let scanner = Scanner()
        await scanner.setCancellation()
        let readLinks = Flag(false)
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: {
            readLinks.value = true
            return ([], [])
        })
        do {
            _ = try await source.snapshot(read: .init())
            XCTFail("cancelled scans must fail the operation")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertFalse(readLinks.value)
    }

    func testHandlerRechecksAuthorityAfterProductionRead() async throws {
        let scanner = Scanner()
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: UUID()))
        let current = Flag(true)
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: {
            current.value = false
            return ([], [])
        })
        let handler = AgentSessionInventoryOperationHandler(
            source: source, scopeChain: { runtime.scopeChain(from: $0) },
            isScopeCurrent: { _ in current.value }, isLeaseCurrent: { _ in true }
        )
        let batch = AgentSessionAdministrationAuthorizedBatch(
            request: .init(operation: .adminInventory, caller: .agentSession(caller)), scope: scope,
            leases: [], bases: [], itemsRequiringControl: [], confirmation: nil
        )
        do {
            _ = try await handler.perform(batch)
            XCTFail("revoked authority must not disclose even empty inventory")
        } catch is MCPError {} catch { XCTFail("unexpected error: \(error)") }
    }

    private final class Handler: AgentSessionAdministrationOperationHandler {
        let operations: Set<DomainAgentSessionTargetOperation>
        var performed = false
        var targets: [UUID] = []
        init(_ operations: Set<DomainAgentSessionTargetOperation> = [.adminRename]) {
            self.operations = operations
        }

        func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
            performed = true
            targets = batch.request.targetSessionIDs
            return .object(["result": .string("ok")])
        }
    }

    func testExactLoadedFrontDoorTargetAvoidsUnrelatedProductionHistoryScan() async throws {
        let scanner = Scanner()
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let target = UUID()
        let workspace = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspace))
        let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        provenance.add(caller, parent: nil, workspace: workspace)
        provenance.add(target, parent: nil, workspace: workspace)
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: core, scopes: runtime, projector: projector, inventory: source, liveBoundSession: { _ in caller }
        )
        let handler = Handler()
        frontDoor.register(handler)
        _ = try await frontDoor.perform(.init(
            operation: .adminRename, caller: .agentSession(caller), scopeID: scope.id,
            targetSessionIDs: [target], arguments: ["name": .string("Renamed")]
        ))
        let queries = await scanner.capturedQueries()
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(handler.performed)
    }

    func testAuthorizedExactGetDoesNotScanHistoryWhenLoadedProjectionDisappears() async throws {
        let scanner = Scanner()
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let target = UUID()
        let workspace = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .allSessions)
        let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        provenance.add(caller, parent: nil, workspace: workspace)
        provenance.add(target, parent: nil, workspace: workspace)
        let core = AgentSessionAdministrationCore(
            scopes: runtime, projector: SpawnProvenanceDelegationMembershipProjector(source: provenance)
        )
        let handler = AgentSessionInventoryOperationHandler(
            source: source, scopeChain: { runtime.scopeChain(from: $0) },
            isScopeCurrent: { runtime.record(id: $0.id)?.generation == $0.generation },
            isLeaseCurrent: { runtime.isCurrent($0) }
        )
        core.register(handler)
        do {
            _ = try await core.perform(.init(
                operation: .adminGet, caller: .agentSession(caller), scopeID: scope.id, targetSessionIDs: [target]
            ))
            XCTFail("an absent live projection must remain uniformly unavailable")
        } catch is MCPError {} catch { XCTFail("unexpected error: \(error)") }
        let queries = await scanner.capturedQueries()
        XCTAssertTrue(queries.isEmpty, "authorized exact get must not fall back to a global history scan")
    }

    func testFrontDoorRechecksAuthorityBeforeEmptyFilterEarlyResult() async throws {
        let scanner = Scanner()
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: UUID()))
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: {
            _ = runtime.release(scopeID: scope.id, caller: .agentSession(caller))
            return ([], [])
        })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: SessionAdminScopeLifecycleTests.FakeProvenance())
        let core = AgentSessionAdministrationCore(scopes: runtime, projector: projector)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: core, scopes: runtime, projector: projector, inventory: source, liveBoundSession: { _ in caller }
        )
        let handler = Handler()
        frontDoor.register(handler)
        do {
            _ = try await frontDoor.perform(.init(
                operation: .adminRename, caller: .agentSession(caller), scopeID: scope.id,
                arguments: ["filter": .object(["loaded": .bool(true)])]
            ))
            XCTFail("revocation must fence no_matching_sessions too")
        } catch is MCPError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertFalse(handler.performed)
    }

    func testExactTabIdentityNeverUsesIndexFallbackOverDifferentActiveSession() {
        let requested = UUID()
        let other = UUID()
        var tab = ComposeTabState(activeAgentSessionID: other)
        XCTAssertFalse(LiveAgentSessionInventorySource.exactTabMatches(tab, sessionID: requested, indexTabID: tab.id))
        tab.activeAgentSessionID = nil
        XCTAssertTrue(LiveAgentSessionInventorySource.exactTabMatches(tab, sessionID: requested, indexTabID: tab.id))
        XCTAssertFalse(LiveAgentSessionInventorySource.exactTabMatches(tab, sessionID: requested, indexTabID: UUID()))
        tab.activeAgentSessionID = requested
        XCTAssertTrue(LiveAgentSessionInventorySource.exactTabMatches(tab, sessionID: requested, indexTabID: nil))
        // Active and stashed lookups intentionally use this same identity predicate.
    }

    private final class FailureSource: AgentSessionInventorySource {
        var afterRead: () -> Void = {}
        func snapshot() async -> DomainAgentSessionInventorySnapshot {
            .init(records: [], edges: [], isComplete: false)
        }

        func snapshot(read _: AgentSessionInventoryRead) async throws -> DomainAgentSessionInventorySnapshot {
            afterRead()
            throw AgentSessionInventoryReadFailure.budgetExceeded
        }
    }

    func testGranteeGetsTypedBudgetOutcomeButRevocationStillGetsUniformDenial() async throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: UUID()))
        let source = FailureSource()
        let handler = AgentSessionInventoryOperationHandler(
            source: source, scopeChain: { runtime.scopeChain(from: $0) },
            isScopeCurrent: { record in
                runtime.record(id: record.id).map { $0.isActive && $0.generation == record.generation } ?? false
            }, isLeaseCurrent: { runtime.isCurrent($0) }
        )
        let batch = AgentSessionAdministrationAuthorizedBatch(
            request: .init(operation: .adminInventory, caller: .agentSession(caller)), scope: scope,
            leases: [], bases: [], itemsRequiringControl: [], confirmation: nil
        )
        let value = try await handler.perform(batch)
        XCTAssertEqual(value.objectValue?["code"], .string("inventory_budget_exceeded"))
        XCTAssertEqual(value.objectValue?["retryable"], .bool(true))
        source.afterRead = { _ = runtime.release(scopeID: scope.id, caller: .agentSession(caller)) }
        do {
            _ = try await handler.perform(batch)
            XCTFail("revocation must not be mislabeled as an operational budget outcome")
        } catch is MCPError {} catch { XCTFail("unexpected error: \(error)") }
    }

    func testHistoryOnlyGetReturnsReadUnavailableInsteadOfAppliedSkippedMutation() async throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let target = UUID()
        let workspace = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspace))
        let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        provenance.add(caller, parent: nil, workspace: workspace)
        let source = LoadedProjectionSource(records: [
            .init(
                sessionID: target,
                name: "History member",
                workspaceID: workspace,
                isLoaded: false,
                runState: .idle,
                lastActivityAt: Date()
            )
        ])
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: AgentSessionAdministrationCore(scopes: runtime, projector: projector), scopes: runtime,
            projector: projector, inventory: source, liveBoundSession: { _ in caller }
        )
        let handler = Handler([.adminGet])
        frontDoor.register(handler)
        guard case let .completed(value) = try await frontDoor.perform(.init(
            operation: .adminGet, caller: .agentSession(caller), scopeID: scope.id, targetSessionIDs: [target]
        )) else { return XCTFail("history-only scope member must get a read-shaped outcome") }
        XCTAssertEqual(value.objectValue?["result"], .string("unavailable"))
        XCTAssertEqual(value.objectValue?["code"], .string("workspace_not_loaded"))
        XCTAssertNil(value.objectValue?["items"])
        XCTAssertFalse(handler.performed)
    }

    func testIncompleteEndpointCensusRefusesFilterWithRecoverableCode() async throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let target = UUID()
        let workspace = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspace))
        let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        provenance.add(target, parent: nil, workspace: workspace)
        let source = LoadedProjectionSource(records: [
            .init(
                sessionID: target,
                name: "Unknown endpoints",
                workspaceID: workspace,
                isLoaded: true,
                runState: .idle,
                lastActivityAt: Date()
            )
        ])
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: AgentSessionAdministrationCore(scopes: runtime, projector: projector), scopes: runtime,
            projector: projector, inventory: source, liveBoundSession: { _ in caller }
        )
        let handler = Handler()
        frontDoor.register(handler)
        guard case let .completed(value) = try await frontDoor.perform(.init(
            operation: .adminRename, caller: .agentSession(caller), scopeID: scope.id,
            arguments: ["filter": .object(["has_links": .bool(false)])]
        )) else { return XCTFail("incomplete census must return a typed refusal") }
        XCTAssertEqual(value.objectValue?["code"], .string("inventory_incomplete"))
        XCTAssertEqual(value.objectValue?["retryable"], .bool(true))
        XCTAssertFalse(handler.performed)
    }

    private final class LoadedProjectionSource: AgentSessionInventorySource {
        let source: LiveAgentSessionInventorySource?
        let records: [DomainAgentSessionInventoryRecord]
        let edges: [DomainAgentSessionInventoryEdge]

        init(
            source: LiveAgentSessionInventorySource? = nil,
            records: [DomainAgentSessionInventoryRecord], edges: [DomainAgentSessionInventoryEdge] = []
        ) {
            self.source = source
            self.records = records
            self.edges = edges
        }

        func snapshot() async -> DomainAgentSessionInventorySnapshot {
            .init(records: records, edges: edges, isComplete: false)
        }

        func snapshot(read: AgentSessionInventoryRead) async throws -> DomainAgentSessionInventorySnapshot {
            if let source {
                let snapshot = try await source.snapshot(read: read)
                return .init(records: records, edges: snapshot.edges, isComplete: snapshot.isComplete)
            }
            return .init(
                records: records.filter { read.sessionIDs?.contains($0.sessionID) ?? true },
                edges: edges, isComplete: false
            )
        }
    }

    func testBoundedLoadedGetWithKnownSameScopeNeighborDoesNotPresentEmptyLinksOrChildren() async throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let target = UUID()
        let child = UUID()
        let workspace = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspace))
        let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        provenance.add(caller, parent: nil, workspace: workspace)
        provenance.add(target, parent: nil, workspace: workspace)
        provenance.add(child, parent: target, workspace: workspace)
        let edge = DomainAgentSessionInventoryEdge(
            observerSessionID: target, targetSessionID: child, isLive: true, isPersisted: true
        )
        let source = LoadedProjectionSource(records: [
            .init(sessionID: target, name: "Target", workspaceID: workspace, isLoaded: true, runState: .idle, lastActivityAt: Date()),
            .init(
                sessionID: child,
                name: "Child",
                workspaceID: workspace,
                isLoaded: true,
                runState: .idle,
                parentSessionID: target,
                lastActivityAt: Date()
            )
        ], edges: [edge])
        let core = AgentSessionAdministrationCore(
            scopes: runtime, projector: SpawnProvenanceDelegationMembershipProjector(source: provenance)
        )
        core.register(AgentSessionInventoryOperationHandler(
            source: source, scopeChain: { runtime.scopeChain(from: $0) },
            isScopeCurrent: { runtime.record(id: $0.id)?.generation == $0.generation },
            isLeaseCurrent: { runtime.isCurrent($0) }
        ))
        guard case let .completed(value) = try await core.perform(.init(
            operation: .adminGet, caller: .agentSession(caller), scopeID: scope.id, targetSessionIDs: [target]
        )) else { return XCTFail("authorized loaded target must be readable") }
        let row = try XCTUnwrap(value.objectValue?["session"]?.objectValue)
        XCTAssertEqual(row["links_complete"], .bool(false))
        XCTAssertEqual(row["children_complete"], .bool(false))
        XCTAssertNil(row["links"], "unknown neighbor links must not be shown as factual empty arrays")
        XCTAssertNil(row["children"], "unknown children must not be shown as factual empty arrays")
        XCTAssertNil(row["link_count"])
        XCTAssertNil(row["roles"])
        XCTAssertEqual(value.objectValue?["history_complete"], .bool(false))
    }

    func testProjectionDeadlineCannotWidenNoLinksMutationFilter() async throws {
        let scanner = Scanner()
        await scanner.setWorkspaces([projectionWorkspace(count: 256)])
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let target = UUID()
        let child = UUID()
        let workspace = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspace))
        let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        provenance.add(target, parent: nil, workspace: workspace)
        provenance.add(child, parent: target, workspace: workspace)
        let liveSource = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: {
            ([], [.init(observerSessionID: target, targetSessionID: child)])
        })
        let source = LoadedProjectionSource(source: liveSource, records: [
            .init(
                sessionID: target,
                name: "Linked target",
                workspaceID: workspace,
                isLoaded: true,
                runState: .idle,
                lastActivityAt: Date()
            )
        ])
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: AgentSessionAdministrationCore(scopes: runtime, projector: projector), scopes: runtime,
            projector: projector, inventory: source, liveBoundSession: { _ in caller }
        )
        let handler = Handler()
        frontDoor.register(handler)
        let clock = ProjectionClock(stopAt: 80)
        let outcome = try await AgentSessionInventoryInvocation.budgetTaskLocal.withValue(clock.budget()) {
            try await frontDoor.perform(.init(
                operation: .adminRename, caller: .agentSession(caller), scopeID: scope.id,
                arguments: ["filter": .object(["has_links": .bool(false)])]
            ))
        }
        guard case let .completed(value) = outcome else { return XCTFail("budget refusal must be a typed grantee-only outcome") }
        XCTAssertEqual(value.objectValue?["code"], .string("inventory_budget_exceeded"))
        XCTAssertEqual(value.objectValue?["retryable"], .bool(true))
        XCTAssertFalse(handler.performed)
    }

    private final class ProjectionClock: @unchecked Sendable {
        let startedAt = ContinuousClock().now
        let lock = NSLock()
        var calls = 0
        let stopAt: Int
        let cancels: Bool

        init(stopAt: Int, cancels: Bool = false) {
            self.stopAt = stopAt
            self.cancels = cancels
        }

        func now() -> ContinuousClock.Instant {
            let stopped = lock.withLock {
                calls += 1
                return calls >= stopAt
            }
            if stopped, cancels { withUnsafeCurrentTask { $0?.cancel() } }
            return stopped && !cancels ? startedAt + .seconds(2) : startedAt
        }

        func budget() -> HistoryRequestBudget {
            HistoryRequestBudget(
                startedAt: startedAt, deadline: startedAt + .seconds(1), maxTurns: 1000,
                yieldEveryTurns: 64, maxIndexBytes: 1_000_000, maxIndexFileBytes: 1_000_000,
                maxTranscriptBytes: 1_000_000, maxTranscriptFileBytes: 1_000_000,
                nowProvider: { self.now() }
            )
        }
    }

    private func projectionWorkspace(count: Int) -> HistoryWorkspaceScanResult {
        let workspaceID = UUID()
        let records = (0 ..< count).map { index in
            AgentSessionMetadataRecord(
                id: UUID(), filename: "\(index).json", workspaceID: workspaceID, composeTabID: nil,
                name: "Record \(index)", savedAt: Date(), lastUserMessageAt: nil, itemCount: 0,
                transcriptProjectionCounts: nil, hasUnknownConversationContent: false,
                agentKindRaw: nil, agentModelRaw: nil, agentReasoningEffortRaw: nil,
                lastRunStateRaw: nil, autoEditEnabled: false, parentSessionID: nil,
                isMCPOriginated: false, serializationVersion: nil, observedFileSize: nil,
                observedFileModificationDate: nil, lastIndexedAt: Date()
            )
        }
        return HistoryWorkspaceScanResult(
            workspaceDir: URL(fileURLWithPath: "/tmp/inventory-projection-fixture"),
            workspaceName: "Projection", workspaceID: workspaceID, records: records,
            indexReadFailed: false, indexSchemaVersion: nil
        )
    }

    func testProjectionDeadlineFailsClosedAfterSuccessfulScan() async throws {
        let scanner = Scanner()
        await scanner.setWorkspaces([projectionWorkspace(count: 256)])
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let clock = ProjectionClock(stopAt: 80)
        do {
            _ = try await source.snapshot(read: .init(budget: clock.budget()))
            XCTFail("deadline exhaustion must not return factual empty edges")
        } catch let failure as AgentSessionInventoryReadFailure {
            XCTAssertEqual(failure, .budgetExceeded)
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testCancellationDuringSuccessfulScanProjectionPropagates() async throws {
        let scanner = Scanner()
        await scanner.setWorkspaces([projectionWorkspace(count: 256)])
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let clock = ProjectionClock(stopAt: 80, cancels: true)
        let task = Task { @MainActor in
            try await source.snapshot(read: .init(budget: clock.budget()))
        }
        do {
            _ = try await task.value
            XCTFail("cancellation must be checked within the record projection, not just around scan")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
    }

    func testCancellationDuringLinkAwaitDoesNotReturnSuccess() async throws {
        let source = LiveAgentSessionInventorySource(scanner: Scanner(), windows: { [] }, links: {
            withUnsafeCurrentTask { $0?.cancel() }
            return ([], [])
        })
        let task = Task { @MainActor in
            try await source.snapshot(read: .init(loadedOnly: true))
        }
        do {
            _ = try await task.value
            XCTFail("cancellation after an await must propagate")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
    }

    func testSuccessiveReadsShareInvocationBudget() async throws {
        let scanner = Scanner()
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let budget = HistoryRequestBudget.standalone()
        try await AgentSessionInventoryInvocation.budgetTaskLocal.withValue(budget) {
            _ = try await source.snapshot(read: .init())
            _ = try await source.snapshot(read: .init())
        }
        let budgets = await scanner.capturedBudgets()
        XCTAssertEqual(budgets.count, 2)
        XCTAssertTrue(budgets.allSatisfy { $0 === budget })
    }

    func testOutputWorkspaceAndLoadedPredicatesDoNotDiscardInScopeLinkEndpoints() {
        var filter = DomainAgentSessionInventoryFilter()
        filter.workspaceID = UUID()
        filter.loaded = true
        filter.hasLinks = false
        let read = AgentSessionInventoryRead.scoped(chain: [], filter: filter)
        XCTAssertNil(read.workspaceID, "an output workspace filter must not narrow all-sessions visibility")
        XCTAssertFalse(read.loadedOnly, "loaded output rows still need unloaded link endpoints")
    }

    func testOrdinaryAllSessionsWorkspaceSelectorPushesDownButEdgePredicateDoesNot() async throws {
        let scanner = Scanner()
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        var filter = DomainAgentSessionInventoryFilter()
        let workspace = UUID()
        filter.workspaceID = workspace
        let read = AgentSessionInventoryRead.scoped(chain: [], filter: filter)
        XCTAssertEqual(read.workspaceID, workspace)
        _ = try await source.snapshot(read: read)
        let queries = await scanner.capturedQueries()
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first, workspace.uuidString)
        filter.hasLinks = false
        XCTAssertNil(AgentSessionInventoryRead.scoped(chain: [], filter: filter).workspaceID)
    }

    func testInventoryReadPredicatesRefuseIncompleteCensusAndPartialRowsOmitNegativeFacts() async throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let target = UUID()
        let workspace = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspace))
        let record = DomainAgentSessionInventoryRecord(
            sessionID: target, name: "Unknown endpoints", workspaceID: workspace, isLoaded: true,
            runState: .idle, lastActivityAt: Date()
        )
        let source = LoadedProjectionSource(records: [record])
        let handler = AgentSessionInventoryOperationHandler(
            source: source, scopeChain: { runtime.scopeChain(from: $0) },
            isScopeCurrent: { record in
                runtime.record(id: record.id).map { $0.isActive && $0.generation == record.generation } ?? false
            }, isLeaseCurrent: { runtime.isCurrent($0) }
        )
        let predicates: [[String: Value]] = [
            ["has_links": .bool(false)], ["orphaned": .bool(false)], ["role": .string("overseer")]
        ]
        for predicate in predicates {
            let batch = AgentSessionAdministrationAuthorizedBatch(
                request: .init(
                    operation: .adminInventory,
                    caller: .agentSession(caller),
                    arguments: ["filter": .object(predicate)]
                ), scope: scope,
                leases: [], bases: [], itemsRequiringControl: [], confirmation: nil
            )
            let value = try await handler.perform(batch)
            XCTAssertEqual(value.objectValue?["code"], .string("inventory_incomplete"))
            XCTAssertNil(value.objectValue?["sessions"], "unknown endpoints must not yield actionable candidate IDs")
        }
        let snapshot = DomainAgentSessionInventorySnapshot(records: [record], edges: [], isComplete: false)
        let row = try XCTUnwrap(AgentSessionInventoryRendering.row(record, snapshot: snapshot, now: Date()).objectValue)
        XCTAssertNil(row["link_count"])
        XCTAssertNil(row["roles"])
        XCTAssertNil(row["orphaned"])
        XCTAssertEqual(row["links_complete"], .bool(false))
        XCTAssertEqual(row["orphan_status_complete"], .bool(false))
    }

    @MainActor
    private final class LoadedWindowFixture {
        let window: WindowState
        let runtime: MCPDomainRuntime
        let directory: URL
        var carriers: WorkspaceModel?
        var indexEntries: [UUID: AgentSessionIndexEntry] = [:]

        /// Install a value-only census fixture after all asynchronous window activation work.
        /// An earlier window's unpublished test projection can otherwise be refreshed while
        /// the next fixture is being activated. No production inventory read is mocked here.
        func installCarriers() throws {
            let expected = try XCTUnwrap(carriers)
            let manager = window.workspaceManager
            let catalog = manager.workspaces.map { "\($0.id):ephemeral=\($0.isEphemeral)" }
            var current = try XCTUnwrap(
                manager.activeWorkspace,
                "window=\(window.windowID) closing=\(window.isClosing) activeID=\(String(describing: manager.activeWorkspaceID)) established=\(manager.hasEstablishedWorkspaceSelectionForTesting) expected=\(expected.id) catalog=\(catalog)"
            )
            XCTAssertEqual(current.id, expected.id, "fixture activation must still own its workspace")
            guard current.id == expected.id else { throw AgentSessionInventoryReadFailure.incomplete }
            current.composeTabs = expected.composeTabs
            current.stashedTabs = expected.stashedTabs
            current.activeComposeTabID = expected.activeComposeTabID
            let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == current.id })
            window.workspaceManager.workspaces[index] = current
            window.promptManager.loadComposeTabsFromWorkspace(current, syncPromptText: true)
            let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: current.id, activationEpoch: 1)
            window.agentModeViewModel.test_installSessionIndexSnapshot(
                indexEntries, owner: owner, latestOwner: owner, activeWorkspace: current
            )
        }

        init(window: WindowState, runtime: MCPDomainRuntime, directory: URL) {
            self.window = window
            self.runtime = runtime
            self.directory = directory
        }

        static func make(activeID: UUID, parentID: UUID?, stashedID: UUID? = nil) async throws -> LoadedWindowFixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-loaded-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // WindowState() is the legacy/no-runtime composition in these headless tests.
            // Persistent creation requires an explicitly started app authority; give this
            // fixture its own bounded storage and lifecycle rather than weakening that guard.
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app, profileIdentifier: "inventory-loaded-\(UUID())",
                storageDirectory: directory.appendingPathComponent("runtime"),
                workspaceStorageDirectory: directory.appendingPathComponent("Workspaces"),
                eventDirectory: directory.appendingPathComponent("events"),
                temporaryDirectory: directory.appendingPathComponent("tmp"), externalReloadInterval: nil
            ))
            try await runtime.start()
            let window = WindowState(domainRuntime: runtime)
            let fixture = LoadedWindowFixture(window: window, runtime: runtime, directory: directory)
            WindowStatesManager.shared.registerWindowState(window)
            do {
                await window.workspaceManager.awaitInitialized()
                let active = ComposeTabState(name: "Loaded", activeAgentSessionID: activeID)
                let stashed = stashedID.map { ComposeTabState(name: "Stashed", activeAgentSessionID: $0) }
                // Use a durably published fixture so both windows can resolve its canonical
                // workspace after activation; no caller-local replacement is treated as truth.
                let creation = try window.workspaceManager.createPersistentWorkspace(name: "Inventory loaded \(activeID)", repoPaths: [])
                var workspace = try await creation.publishedWorkspace()
                workspace.composeTabs = [active]
                workspace.stashedTabs = stashed.map { [StashedTab(tab: $0)] } ?? []
                workspace.activeComposeTabID = active.id
                let switched = await window.workspaceManager.reactivateWorkspaceAfterReplacement(workspace, reason: "inventoryLoadedTreeTest")
                XCTAssertEqual(switched, .switched)
                // Activation reloads the manager's canonical projection; it does not publish
                // arbitrary fields from the caller's local workspace value. Install carriers
                // after activation has settled, rather than assuming that value was accepted.
                var current = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                current.composeTabs = workspace.composeTabs
                current.stashedTabs = workspace.stashedTabs
                current.activeComposeTabID = workspace.activeComposeTabID
                let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == current.id })
                window.workspaceManager.workspaces[index] = current
                window.promptManager.loadComposeTabsFromWorkspace(current, syncPromptText: true)
                XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.map(\.activeAgentSessionID), [activeID])
                XCTAssertEqual(window.workspaceManager.activeWorkspace?.stashedTabs.count, stashedID == nil ? 0 : 1)
                let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
                let entries = ([active] + (stashed.map { [$0] } ?? [])).map { tab in
                    var entry = AgentSessionIndexEntry(
                        id: tab.activeAgentSessionID!, tabID: tab.id, name: tab.name, savedAt: Date(),
                        itemCount: 0, autoEditEnabled: false, hasUnknownConversationContent: false,
                        isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
                    )
                    entry.lastRunStateRaw = "idle"
                    entry.parentSessionID = tab.activeAgentSessionID == activeID ? parentID : UUID()
                    if tab.activeAgentSessionID != activeID { entry.organizationalParentID = activeID }
                    return entry
                }
                fixture.carriers = current
                fixture.indexEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
                window.agentModeViewModel.test_installSessionIndexSnapshot(
                    fixture.indexEntries, owner: owner, latestOwner: owner, activeWorkspace: current
                )
                return fixture
            } catch { await fixture.cleanup()
                throw error
            }
        }

        func cleanup() async {
            WindowStatesManager.shared.unregisterWindowState(window)
            await window.workspaceManager.debugDrainScheduledSaves()
            await window.tearDown()
            let shutdown = await runtime.shutdown()
            XCTAssertEqual(shutdown.finalLifecycle, .stopped)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testOrdinaryTreeProductionReadAvoidsHistoryAndKeepsCrossWorkspaceLoadedAncestryAndEdges() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let root = UUID()
            let child = UUID()
            let stashed = UUID()
            let first = try await LoadedWindowFixture.make(activeID: root, parentID: nil)
            var second: LoadedWindowFixture?
            do {
                let other = try await LoadedWindowFixture.make(activeID: child, parentID: root, stashedID: stashed)
                second = other
                XCTAssertNotEqual(first.window.windowID, other.window.windowID, "headless windows must have distinct registered identities")
                XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === first.window })
                XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === other.window })
                XCTAssertFalse(first.window.isClosing)
                XCTAssertFalse(other.window.isClosing)
                // Both window activations are now complete; publish the test carriers together.
                try first.installCarriers()
                try other.installCarriers()
                let firstWorkspace = try XCTUnwrap(first.window.workspaceManager.activeWorkspace)
                let otherWorkspace = try XCTUnwrap(other.window.workspaceManager.activeWorkspace)
                XCTAssertNotEqual(firstWorkspace.id, otherWorkspace.id)
                XCTAssertEqual(firstWorkspace.composeTabs.compactMap(\.activeAgentSessionID), [root], "root carrier precondition")
                XCTAssertEqual(otherWorkspace.composeTabs.compactMap(\.activeAgentSessionID), [child], "cross-workspace child carrier precondition")
                XCTAssertEqual(otherWorkspace.stashedTabs.compactMap(\.tab.activeAgentSessionID), [stashed], "archived carrier precondition")
                XCTAssertNotNil(first.window.agentModeViewModel.test_ownerValidatedSessionIndex[root])
                XCTAssertNotNil(other.window.agentModeViewModel.test_ownerValidatedSessionIndex[child])
                XCTAssertNotNil(other.window.agentModeViewModel.test_ownerValidatedSessionIndex[stashed])
                let scanner = Scanner()
                let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [first.window, other.window] }, links: {
                    (
                        [.init(
                            linkID: UUID(),
                            generation: 1,
                            observerSessionID: root,
                            targetSessionID: child,
                            displayName: nil,
                            capabilities: [],
                            createdAt: Date()
                        )],
                        [.init(observerSessionID: child, targetSessionID: stashed)]
                    )
                })
                let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
                let scope = try grant(runtime: runtime, caller: root, kind: .tree(rootSessionID: root))
                var filter = DomainAgentSessionInventoryFilter()
                filter.workspaceID = try XCTUnwrap(other.window.workspaceManager.activeWorkspaceID)
                let read = AgentSessionInventoryRead.scoped(chain: [scope], filter: filter)
                XCTAssertTrue(read.loadedOnly)
                XCTAssertNil(read.workspaceID, "output workspace must not remove the root or cross-workspace endpoints")
                let snapshot = try await source.snapshot(read: read)
                let queries = await scanner.capturedQueries()
                XCTAssertTrue(queries.isEmpty)
                XCTAssertNotNil(snapshot.records[root], "root record \(root) disappeared despite its current carrier")
                XCTAssertNotNil(snapshot.records[child], "cross-workspace child record \(child) disappeared")
                XCTAssertNotNil(snapshot.records[stashed], "archived record \(stashed) disappeared")
                XCTAssertEqual(Set(snapshot.records.keys), Set([root, child, stashed]))
                XCTAssertTrue(snapshot.isInTree(child, rootSessionID: root))
                XCTAssertTrue(snapshot.isInTree(stashed, rootSessionID: root))
                XCTAssertTrue(snapshot.records[stashed]?.isArchived == true)
                XCTAssertFalse(snapshot.isComplete)
                XCTAssertFalse(snapshot.isMissing(UUID()))
                let view = snapshot.restricted(to: Set(snapshot.records.keys))
                XCTAssertEqual(view.edges.count, 2, "live and durable same-tree endpoints must survive across workspaces")
                await other.cleanup()
                second = nil
                await first.cleanup()
            } catch {
                if let second { await second.cleanup() }
                await first.cleanup()
                throw error
            }
        }
    }

    private func carrierEntry(
        _ id: UUID, tabID: UUID, savedAt: TimeInterval = 20, state: String? = "idle"
    ) -> AgentSessionIndexEntry {
        var entry = AgentSessionIndexEntry(
            id: id, tabID: tabID, name: "Metadata", savedAt: Date(timeIntervalSince1970: savedAt),
            itemCount: 1, autoEditEnabled: false, hasUnknownConversationContent: false,
            isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
        )
        entry.lastRunStateRaw = state
        return entry
    }

    private func carrierGet(
        _ source: LiveAgentSessionInventorySource, sessionID: UUID, workspaceID: UUID
    ) async throws -> [String: Value] {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspaceID))
        let handler = AgentSessionInventoryOperationHandler(
            source: source, scopeChain: { runtime.scopeChain(from: $0) },
            isScopeCurrent: { runtime.record(id: $0.id)?.generation == $0.generation },
            isLeaseCurrent: { runtime.isCurrent($0) }
        )
        let lease = DomainDelegationScopeLease(
            scopeID: scope.id, generation: scope.generation, capability: .observe,
            granteeSessionID: caller, targetSessionID: sessionID
        )
        let value = try await handler.perform(.init(
            request: .init(operation: .adminGet, caller: .agentSession(caller), targetSessionIDs: [sessionID]),
            scope: scope, leases: [lease], bases: [], itemsRequiringControl: [], confirmation: nil
        ))
        return try XCTUnwrap(value.objectValue)
    }

    private func assertCarrierReadIncomplete(
        _ source: LiveAgentSessionInventorySource, sessionIDs: Set<UUID>? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            _ = try await source.snapshot(read: .init(loadedOnly: true, sessionIDs: sessionIDs))
            XCTFail("Conflicting carrier evidence must not produce a successful row", file: file, line: line)
        } catch let failure as AgentSessionInventoryReadFailure {
            XCTAssertEqual(failure, .incomplete, file: file, line: line)
        }
    }

    func testExactGetAndCensusChooseTheSameCarrierBeforeFilteringRequestedIDs() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let a = UUID(), b = UUID()
            let fixture = try await LoadedWindowFixture.make(activeID: b, parentID: nil)
            do {
                var workspace = try XCTUnwrap(fixture.carriers)
                let x = ComposeTabState(name: "X fallback")
                var y = try XCTUnwrap(workspace.composeTabs.first)
                y.name = "Y explicit"
                y.isPinned = true
                y.sidebarGroup = "Y group"
                y.sidebarGroupOrder = 7
                fixture.indexEntries = [
                    a: carrierEntry(a, tabID: x.id, savedAt: 10),
                    b: carrierEntry(b, tabID: x.id, savedAt: 20)
                ]
                let scanner = Scanner()
                let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [fixture.window] }, links: { ([], []) })
                for tabs in [[x, y], [y, x]] {
                    workspace.composeTabs = tabs
                    fixture.carriers = workspace
                    try fixture.installCarriers()
                    let census = try await source.snapshot(read: .init(loadedOnly: true))
                    XCTAssertEqual(Set(census.records.keys), Set([a, b]))
                    XCTAssertEqual(census.records[a]?.name, x.name)
                    XCTAssertEqual(census.records[b]?.name, y.name)
                    for ids in [Set([a]), Set([b]), Set([a, b])] {
                        let exact = try await source.snapshot(read: .init(loadedOnly: true, sessionIDs: ids))
                        XCTAssertEqual(Set(exact.records.keys), ids)
                        for id in ids {
                            XCTAssertEqual(exact.records[id], census.records[id])
                        }
                    }
                    let result = try await carrierGet(source, sessionID: b, workspaceID: workspace.id)
                    let row = try XCTUnwrap(result["session"]?.objectValue)
                    XCTAssertEqual(row["name"], .string(y.name))
                    XCTAssertEqual(row["pinned"], .bool(true))
                    XCTAssertEqual(row["group"], .string("Y group"))
                    XCTAssertEqual(row["group_order"], .int(7))
                }
                let scans = await scanner.capturedQueries()
                let direct = await scanner.capturedDirectQueries()
                XCTAssertTrue(scans.isEmpty && direct.isEmpty)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testExactLiveAddressSurvivesStaleMetadataButPersistedLiveConflictIsIncomplete() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let b = UUID(), c = UUID()
            let fixture = try await LoadedWindowFixture.make(activeID: b, parentID: nil)
            do {
                var workspace = try XCTUnwrap(fixture.carriers)
                let x = ComposeTabState(name: "Stale metadata address")
                var y = try XCTUnwrap(workspace.composeTabs.first)
                y.name = "Live carrier"
                y.activeAgentSessionID = nil
                workspace.composeTabs = [x, y]
                fixture.carriers = workspace
                fixture.indexEntries = [c: carrierEntry(c, tabID: x.id)]
                try fixture.installCarriers()
                let live = AgentModeViewModel.TabSession(tabID: y.id)
                live.testInstallPersistentSessionBinding(sessionID: c)
                live.runState = .running
                fixture.window.agentModeViewModel.test_installLiveSession(live)
                let source = LiveAgentSessionInventorySource(scanner: Scanner(), windows: { [fixture.window] }, links: { ([], []) })
                let exact = try await source.snapshot(read: .init(loadedOnly: true, sessionIDs: [c]))
                let census = try await source.snapshot(read: .init(loadedOnly: true))
                XCTAssertEqual(exact.records[c], census.records[c])
                XCTAssertEqual(exact.records[c]?.name, y.name)
                XCTAssertEqual(exact.records[c]?.runState, .running)

                // Presentation still prefers C, but B's persisted claim is real authority conflict.
                y.activeAgentSessionID = b
                workspace.composeTabs = [x, y]
                fixture.carriers = workspace
                try fixture.installCarriers()
                fixture.window.agentModeViewModel.test_installLiveSession(live)
                try await assertCarrierReadIncomplete(source, sessionIDs: [c])
                let result = try await carrierGet(source, sessionID: c, workspaceID: workspace.id)
                XCTAssertEqual(result["code"], .string("inventory_incomplete"))
                XCTAssertNil(result["session"])
                XCTAssertNil(result["sessions"])
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testNilBoundArchivedCarrierRanksMetadataWithoutPromotingTheHistoryOnlyLoser() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            try await withCarrierWindows(count: 1) { windows in
                let window = try XCTUnwrap(windows.first)
                let active = UUID(), older = UUID(), newer = UUID()
                let activeTab = ComposeTabState(name: "Active carrier", activeAgentSessionID: active)
                let archived = ComposeTabState(name: "Archived carrier")
                var workspace = WorkspaceModel(name: "Archived metadata ranking", repoPaths: [], ephemeralFlag: true, composeTabs: [activeTab])
                workspace.stashedTabs = [StashedTab(tab: archived)]
                let entries = [
                    active: carrierEntry(active, tabID: activeTab.id),
                    older: carrierEntry(older, tabID: archived.id, savedAt: 10),
                    newer: carrierEntry(newer, tabID: archived.id, savedAt: 20)
                ]
                let scanner = Scanner()
                await scanner.setWorkspaces([.init(
                    workspaceDir: URL(fileURLWithPath: "/tmp/inventory-archived-carrier"),
                    workspaceName: workspace.name, workspaceID: workspace.id,
                    records: [directRecord(id: older, parent: nil, workspace: workspace.id)],
                    indexReadFailed: false, indexSchemaVersion: nil
                )])
                // This exercises projection, not workspace restoration. Install the value fixture
                // after scanner setup so no durable activation can replace its synthetic metadata.
                installCarrierWindow(window, workspace: workspace, entries: entries)
                let installed = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                XCTAssertEqual(installed.id, workspace.id)
                XCTAssertEqual(installed.stashedTabs.map(\.tab.id), [archived.id])
                XCTAssertNil(installed.stashedTabs.first?.tab.activeAgentSessionID)
                let viewModel = window.agentModeViewModel
                let owner = try XCTUnwrap(viewModel.sessionIndexStore.sessionIndexOwner)
                XCTAssertEqual(owner.workspaceID, workspace.id)
                XCTAssertTrue(viewModel.sessionIndexStore.isOwnerCurrent(owner))
                XCTAssertEqual(Set(viewModel.test_ownerValidatedSessionIndex.keys), Set(entries.keys))
                let preferred = try XCTUnwrap(viewModel.preferredSidebarEntry(for: archived.id, tabName: archived.name))
                XCTAssertEqual(preferred.id, newer)

                let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [window] }, links: { ([], []) })
                let census = try await source.snapshot(read: .init(loadedOnly: true))
                XCTAssertEqual(Set(census.records.keys), Set([active, newer]))
                let censusWinner = try XCTUnwrap(census.records[newer])
                for ids in [Set([older]), Set([newer]), Set([older, newer])] {
                    let exact = try await source.snapshot(read: .init(loadedOnly: true, sessionIDs: ids))
                    XCTAssertEqual(Set(exact.records.keys), ids.intersection([newer]))
                    XCTAssertNil(exact.records[older])
                    if ids.contains(newer) { XCTAssertEqual(try XCTUnwrap(exact.records[newer]), censusWinner) }
                }
                XCTAssertEqual(censusWinner.name, archived.name)
                XCTAssertTrue(censusWinner.isArchived)
                XCTAssertTrue(censusWinner.isLoaded)
                XCTAssertTrue(censusWinner.organizationStateIsKnown)
                let history = try await source.snapshot(read: .init())
                XCTAssertEqual(Set(history.records.keys), Set([active, older, newer]))
                let historyLoser = try XCTUnwrap(history.records[older])
                XCTAssertFalse(historyLoser.isLoaded)
                XCTAssertFalse(historyLoser.organizationStateIsKnown)
                let historyWinner = try XCTUnwrap(history.records[newer])
                XCTAssertTrue(historyWinner.isLoaded)
                XCTAssertTrue(historyWinner.isArchived)
                XCTAssertTrue(historyWinner.organizationStateIsKnown)
                XCTAssertEqual(historyWinner.name, archived.name)
            }
        }
    }

    /// All asynchronous initialization precedes installing these identical value projections.
    /// These tests exercise production source joining without independent persistent authorities
    /// turning a same-canonical-carrier fixture into different-workspace conflict accidentally.
    private func withCarrierWindows(
        count: Int, _ body: ([WindowState]) async throws -> Void
    ) async throws {
        var windows: [WindowState] = []
        for _ in 0 ..< count {
            let window = WindowState()
            windows.append(window)
            await window.workspaceManager.awaitInitialized()
        }
        do { try await body(windows) } catch {
            for window in windows.reversed() {
                await window.tearDown()
            }
            throw error
        }
        for window in windows.reversed() {
            await window.tearDown()
        }
    }

    private func installCarrierWindow(
        _ window: WindowState, workspace: WorkspaceModel, entries: [UUID: AgentSessionIndexEntry],
        live: (sessionID: UUID, tabID: UUID, state: AgentSessionRunState)? = nil
    ) {
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        let vm = window.agentModeViewModel
        for tabID in Array(vm.sessions.keys) {
            vm.test_removeSession(tabID: tabID)
        }
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        vm.test_installSessionIndexSnapshot(entries, owner: owner, latestOwner: owner, activeWorkspace: workspace)
        if let live {
            let session = AgentModeViewModel.TabSession(tabID: live.tabID)
            session.testInstallPersistentSessionBinding(sessionID: live.sessionID)
            session.runState = live.state
            vm.test_installLiveSession(session)
        }
    }

    func testInactiveCachedWorkspaceCannotOverrideActiveOwnerInventoryOrReviveRemovedCarrier() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            try await withCarrierWindows(count: 2) { windows in
                let target = UUID()
                let original = ComposeTabState(name: "Original", activeAgentSessionID: target)
                let cached = WorkspaceModel(
                    name: "Active owner", repoPaths: [], ephemeralFlag: true, composeTabs: [original]
                )
                let peer = WorkspaceModel(name: "Other active workspace", repoPaths: [], ephemeralFlag: true)
                let entries = [target: carrierEntry(target, tabID: original.id)]
                // Model the owning window's committed projections while the other workspace's
                // catalog still holds the original active tab. Real mutation/undo is exercised
                // by the paired production-organizer test; this test covers exact get/census.
                var changed = original
                changed.name = "Renamed"
                changed.isPinned = true
                changed.sidebarGroup = "New group"
                changed.sidebarGroupOrder = 3
                var changedWorkspace = cached
                changedWorkspace.composeTabs = [changed]
                var archivedWorkspace = changedWorkspace
                archivedWorkspace.composeTabs = []
                archivedWorkspace.stashedTabs = [StashedTab(tab: changed)]
                var removedWorkspace = cached
                removedWorkspace.composeTabs = []
                for projected in [changedWorkspace, archivedWorkspace, cached, removedWorkspace] {
                    installCarrierWindow(windows[0], workspace: projected, entries: entries)
                    installCarrierWindow(windows[1], workspace: peer, entries: [:])
                    windows[1].workspaceManager.workspaces.append(cached)
                    for ordered in [windows, Array(windows.reversed())] {
                        let source = LiveAgentSessionInventorySource(scanner: Scanner(), windows: { ordered }, links: { ([], []) })
                        let exact = try await source.snapshot(read: .init(loadedOnly: true, sessionIDs: [target]))
                        let census = try await source.snapshot(read: .init(workspaceID: cached.id, loadedOnly: true))
                        if projected.composeTabs.isEmpty, projected.stashedTabs.isEmpty {
                            XCTAssertTrue(exact.records.isEmpty)
                            XCTAssertTrue(census.records.isEmpty, "Inactive cached carrier cannot revive a removed active-owner carrier")
                            continue
                        }
                        let record = try XCTUnwrap(exact.records[target])
                        XCTAssertEqual(Set(exact.records.keys), [target])
                        XCTAssertEqual(census.records[target], record)
                        let expected = try XCTUnwrap(projected.composeTabs.first ?? projected.stashedTabs.first?.tab)
                        XCTAssertEqual(record.name, expected.name)
                        XCTAssertEqual(record.isPinned, expected.isPinned)
                        XCTAssertEqual(record.sidebarGroup, expected.sidebarGroup)
                        XCTAssertEqual(record.isArchived, !projected.stashedTabs.isEmpty)
                        let result = try await carrierGet(source, sessionID: target, workspaceID: cached.id)
                        let row = try XCTUnwrap(result["session"]?.objectValue)
                        XCTAssertEqual(row["name"], .string(expected.name))
                        XCTAssertEqual(row["archived"], .bool(!projected.stashedTabs.isEmpty))
                        XCTAssertEqual(windows[1].workspaceManager.workspace(withID: cached.id)?.composeTabs, [original])
                    }
                }
            }
        }
    }

    func testDuplicatePhysicalCarriersFailClosedWithoutPoisoningUnrelatedExactTargets() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            try await withCarrierWindows(count: 2) { windows in
                let target = UUID(), unaffected = UUID()
                let tab = ComposeTabState(name: "Duplicate", activeAgentSessionID: target)
                let other = ComposeTabState(name: "Other carrier", activeAgentSessionID: target)
                let safe = ComposeTabState(name: "Unaffected", activeAgentSessionID: unaffected)
                let base = WorkspaceModel(name: "Duplicates", repoPaths: [], ephemeralFlag: true, composeTabs: [tab, safe])
                let empty = WorkspaceModel(name: "Other workspace", repoPaths: [], ephemeralFlag: true)
                for shape in ["active-active", "active-stash", "same-tab", "another-workspace"] {
                    var first = base, second = empty
                    switch shape {
                    case "active-active": first.composeTabs.append(other)
                    case "active-stash": first.stashedTabs = [StashedTab(tab: other)]
                    case "same-tab": first.composeTabs.append(tab)
                    default: second.composeTabs = [tab]
                    }
                    installCarrierWindow(windows[0], workspace: first, entries: [
                        target: carrierEntry(target, tabID: tab.id), unaffected: carrierEntry(unaffected, tabID: safe.id)
                    ])
                    installCarrierWindow(windows[1], workspace: second, entries: [target: carrierEntry(target, tabID: tab.id)])
                    for ordered in [windows, Array(windows.reversed())] {
                        let scanner = Scanner()
                        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { ordered }, links: { ([], []) })
                        let exact = try await source.snapshot(read: .init(loadedOnly: true, sessionIDs: [unaffected]))
                        XCTAssertEqual(Set(exact.records.keys), Set([unaffected]), shape)
                        XCTAssertEqual(exact.records[unaffected]?.name, safe.name, shape)
                        try await assertCarrierReadIncomplete(source, sessionIDs: [target])
                        try await assertCarrierReadIncomplete(source)
                        let scans = await scanner.capturedQueries()
                        XCTAssertTrue(scans.isEmpty)
                    }
                }
            }
        }
    }

    func testCanonicalCarrierRuntimeJoinPreservesLiveEvidenceAcrossWindowOrders() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            try await withCarrierWindows(count: 3) { windows in
                let target = UUID()
                var tab = ComposeTabState(name: "Canonical carrier", activeAgentSessionID: target)
                tab.lastModified = Date(timeIntervalSince1970: 20)
                let workspace = WorkspaceModel(name: "Shared canonical workspace", repoPaths: [], ephemeralFlag: true, composeTabs: [tab])
                typealias Observation = (live: AgentSessionRunState?, fallback: String?)
                let cases: [(String, [Observation], DomainAgentSessionInventoryRunState?)] = [
                    ("absent then live", [(nil, nil), (.running, "idle")], .running),
                    ("equal live", [(.running, "idle"), (.running, "idle")], .running),
                    ("different live", [(.running, "idle"), (.idle, "idle")], nil),
                    ("different fallback", [(nil, "running"), (nil, "idle")], nil),
                    ("live fallback live", [(.running, "idle"), (nil, "idle"), (.idle, "idle")], nil),
                    ("conflicting fallback plus live", [(nil, "idle"), (nil, "completed"), (.running, "idle")], .running)
                ]
                for (label, observations, expected) in cases {
                    for (index, observation) in observations.enumerated() {
                        let entries = observation.fallback.map { [target: carrierEntry(target, tabID: tab.id, state: $0)] } ?? [:]
                        installCarrierWindow(
                            windows[index], workspace: workspace, entries: entries,
                            live: observation.live.map { (target, tab.id, $0) }
                        )
                    }
                    let orders = observations.count == 2 ? [[0, 1], [1, 0]] : [
                        [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]
                    ]
                    for order in orders {
                        let ordered = order.map { windows[$0] }
                        let scanner = Scanner()
                        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { ordered }, links: { ([], []) })
                        let selectors: [Set<UUID>?] = [Set([target]), nil]
                        for ids in selectors {
                            if let expected {
                                let snapshot = try await source.snapshot(read: .init(loadedOnly: true, sessionIDs: ids))
                                XCTAssertEqual(Set(snapshot.records.keys), Set([target]), "\(label) \(order)")
                                XCTAssertEqual(snapshot.records[target]?.runState, expected, "\(label) \(order)")
                            } else {
                                try await assertCarrierReadIncomplete(source, sessionIDs: ids)
                            }
                        }
                        let result = try await carrierGet(source, sessionID: target, workspaceID: workspace.id)
                        if let expected {
                            XCTAssertEqual(result["session"]?.objectValue?["state"], .string(expected.rawValue), label)
                        } else {
                            XCTAssertEqual(result["code"], .string("inventory_incomplete"), label)
                            XCTAssertNil(result["session"], label)
                        }
                        let scans = await scanner.capturedQueries()
                        let direct = await scanner.capturedDirectQueries()
                        XCTAssertTrue(scans.isEmpty && direct.isEmpty)
                    }
                }

                // A shared canonical key cannot reconcile different organization projections.
                var pinnedWorkspace = workspace
                pinnedWorkspace.composeTabs[0].isPinned = true
                let entries = [target: carrierEntry(target, tabID: tab.id)]
                installCarrierWindow(windows[0], workspace: workspace, entries: entries)
                installCarrierWindow(windows[1], workspace: pinnedWorkspace, entries: entries)
                for order in [[0, 1], [1, 0]] {
                    let source = LiveAgentSessionInventorySource(scanner: Scanner(), windows: { order.map { windows[$0] } }, links: { ([], []) })
                    try await assertCarrierReadIncomplete(source, sessionIDs: [target])
                    try await assertCarrierReadIncomplete(source)
                    let result = try await carrierGet(source, sessionID: target, workspaceID: workspace.id)
                    XCTAssertEqual(result["code"], .string("inventory_incomplete"))
                    XCTAssertNil(result["session"])
                }

                // Real history fallback is weaker than exact live evidence too; keep every other
                // projected field identical so this tests evidence precedence, not metadata conflict.
                for window in windows.prefix(2) {
                    installCarrierWindow(window, workspace: workspace, entries: [:])
                }
                installCarrierWindow(windows[1], workspace: workspace, entries: [:], live: (target, tab.id, .running))
                let scanner = Scanner()
                var history = directRecord(id: target, parent: nil, workspace: workspace.id)
                history.savedAt = tab.lastModified
                history.lastRunStateRaw = "failed"
                await scanner.setWorkspaces([.init(
                    workspaceDir: URL(fileURLWithPath: "/tmp/inventory-runtime-evidence"),
                    workspaceName: workspace.name, workspaceID: workspace.id, records: [history],
                    indexReadFailed: false, indexSchemaVersion: nil
                )])
                for order in [[0, 1], [1, 0]] {
                    let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { order.map { windows[$0] } }, links: { ([], []) })
                    let snapshot = try await source.snapshot(read: .init())
                    XCTAssertEqual(snapshot.records[target]?.runState, .running)
                    XCTAssertEqual(snapshot.records[target]?.isLoaded, true)
                }
            }
        }
    }

    private func directRecord(id: UUID, parent: UUID?, workspace: UUID?) -> AgentSessionMetadataRecord {
        AgentSessionMetadataRecord(
            id: id, filename: "AgentSession-\(id.uuidString).json", workspaceID: workspace, composeTabID: nil,
            name: "Exact member", savedAt: Date(), lastUserMessageAt: nil, itemCount: 0,
            transcriptProjectionCounts: nil, hasUnknownConversationContent: false,
            agentKindRaw: nil, agentModelRaw: nil, agentReasoningEffortRaw: nil,
            lastRunStateRaw: "idle", autoEditEnabled: false, parentSessionID: parent,
            isMCPOriginated: false, serializationVersion: nil, observedFileSize: nil,
            observedFileModificationDate: nil, lastIndexedAt: Date()
        )
    }

    func testUnloadedTreeGetAndMixedRenameUseExactPersistedAncestryWithoutGlobalScan() async throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let root = UUID(), loaded = UUID(), unloaded = UUID(), ancestor = UUID(), workspace = UUID()
        let scope = try grant(runtime: runtime, caller: root, kind: .tree(rootSessionID: root))
        let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        provenance.add(root, parent: nil, workspace: workspace)
        provenance.add(loaded, parent: root, workspace: workspace)
        let scanner = Scanner()
        await scanner.setDirectRecords([
            directRecord(id: unloaded, parent: ancestor, workspace: workspace),
            directRecord(id: ancestor, parent: root, workspace: workspace)
        ])
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: AgentSessionAdministrationCore(scopes: runtime, projector: projector), scopes: runtime,
            projector: projector, inventory: source, liveBoundSession: { _ in root }
        )
        let handler = Handler([.adminGet, .adminRename])
        frontDoor.register(handler)
        guard case let .completed(get) = try await frontDoor.perform(.init(
            operation: .adminGet, caller: .agentSession(root), scopeID: scope.id, targetSessionIDs: [unloaded]
        )) else { return XCTFail("persisted tree member must have a read-shaped unavailable outcome") }
        XCTAssertEqual(get.objectValue?["code"], .string("workspace_not_loaded"))
        XCTAssertNil(get.objectValue?["items"])
        XCTAssertFalse(handler.performed)
        guard case let .completed(rename) = try await frontDoor.perform(.init(
            operation: .adminRename, caller: .agentSession(root), scopeID: scope.id,
            targetSessionIDs: [loaded, unloaded], arguments: ["name": .string("Renamed")]
        )) else { return XCTFail("mixed batch must retain the proven loaded member") }
        XCTAssertTrue(handler.performed)
        XCTAssertEqual(handler.targets, [loaded])
        guard case let .array(items)? = rename.objectValue?["items"] else {
            return XCTFail("mixed mutation must include an unloaded item receipt")
        }
        XCTAssertEqual(items.first?.objectValue?["session_id"], .string(unloaded.uuidString))
        XCTAssertEqual(items.first?.objectValue?["reason"], .string("workspace_not_loaded"))
        let global = await scanner.capturedQueries()
        let exact = await scanner.capturedDirectQueries()
        let budgets = await scanner.capturedBudgets()
        XCTAssertTrue(global.isEmpty)
        XCTAssertEqual(Set(exact), Set([unloaded, ancestor, root]))
        XCTAssertEqual(exact.count, 6)
        XCTAssertTrue(budgets[0] === budgets[1] && budgets[1] === budgets[2])
    }

    func testColdRealScannerUnloadedTreeGetAndMixedRenameReadOnlyTheExactWorkspaceIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-cold-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = UUID(), loaded = UUID(), unloaded = UUID(), ancestor = UUID(), workspace = UUID()
        let selected = directory.appendingPathComponent("Workspaces/Workspace-\(workspace.uuidString)")
        let unrelated = directory.appendingPathComponent("Workspaces/Workspace-\(UUID().uuidString)")
        let records = [
            directRecord(id: unloaded, parent: ancestor, workspace: workspace),
            directRecord(id: ancestor, parent: root, workspace: workspace)
        ]
        for location in [selected, unrelated] {
            let sessions = location.appendingPathComponent("AgentSessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let entries = location == selected ? records : [directRecord(id: UUID(), parent: nil, workspace: UUID())]
            try JSONEncoder().encode(AgentSessionMetadataIndex(entries: entries))
                .write(to: sessions.appendingPathComponent("AgentSessionIndex.json"))
            for entry in entries {
                try JSONEncoder().encode(AgentSession(id: entry.id, name: entry.name))
                    .write(to: sessions.appendingPathComponent(entry.filename))
            }
            try Data("{\"id\":\"\(workspace.uuidString)\",\"name\":\"Cold workspace\"}".utf8)
                .write(to: location.appendingPathComponent("workspace.json"))
        }
        for operation in [DomainAgentSessionTargetOperation.adminGet, .adminRename] {
            // A fresh scanner for each operation: neither receipt may depend on a warm global cache.
            let scanner = HistorySessionScanner(
                applicationSupportRoot: directory, workspaceDirectoryProvider: { _ in [selected, unrelated] }
            )
            let initialEntries = await scanner.indexScanCacheEntryCountForTesting
            XCTAssertEqual(initialEntries, 0)
            let cold = try await scanner.locateSession(sessionID: unloaded, requestBudget: .standalone())
            XCTAssertEqual(cold.location?.workspaceDir, selected)
            XCTAssertNil(cold.location?.record, "real cold lookup intentionally has location but no cached metadata")
            let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
            let scope = try grant(runtime: runtime, caller: root, kind: .tree(rootSessionID: root))
            let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
            provenance.add(root, parent: nil, workspace: workspace)
            provenance.add(loaded, parent: root, workspace: workspace)
            let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
            let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
            let frontDoor = AgentSessionAdministrationFrontDoor(
                core: AgentSessionAdministrationCore(scopes: runtime, projector: projector), scopes: runtime,
                projector: projector, inventory: source, liveBoundSession: { _ in root }
            )
            let handler = Handler([operation])
            frontDoor.register(handler)
            guard case let .completed(value) = try await frontDoor.perform(.init(
                operation: operation, caller: .agentSession(root), scopeID: scope.id,
                targetSessionIDs: operation == .adminGet ? [unloaded] : [loaded, unloaded],
                arguments: operation == .adminGet ? [:] : ["name": .string("Renamed")]
            )) else { return XCTFail("cold persisted ancestry must prove the unloaded tree member") }
            if operation == .adminGet {
                XCTAssertEqual(value.objectValue?["code"], .string("workspace_not_loaded"))
                XCTAssertNil(value.objectValue?["items"])
                XCTAssertFalse(handler.performed)
            } else {
                XCTAssertEqual(handler.targets, [loaded])
                guard case let .array(items)? = value.objectValue?["items"] else { return XCTFail("missing unloaded receipt") }
                XCTAssertEqual(items.first?.objectValue?["session_id"], .string(unloaded.uuidString))
                XCTAssertEqual(items.first?.objectValue?["reason"], .string("workspace_not_loaded"))
            }
            let decoded = await scanner.indexDecodeCountForTesting
            let inspected = await scanner.workspaceInspectionCountForTesting
            let transcripts = await scanner.transcriptDecodeCountForTesting
            XCTAssertEqual(decoded, 1, "unrelated current-schema index must not be decoded")
            XCTAssertEqual(inspected, 1, "exact metadata fallback must not perform a global inventory")
            XCTAssertEqual(transcripts, 0, "provenance needs only the bounded index, not transcript hydration")
        }
    }

    func testColdAndWarmRealWorkspaceScopeResolveLegacyRecordWorkspaceFromExactIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-legacy-workspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let caller = UUID(), target = UUID(), workspace = UUID()
        let selected = directory.appendingPathComponent("Workspaces/Workspace-\(workspace.uuidString)")
        let sessions = selected.appendingPathComponent("AgentSessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record = directRecord(id: target, parent: nil, workspace: nil)
        try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [record]))
            .write(to: sessions.appendingPathComponent("AgentSessionIndex.json"))
        try JSONEncoder().encode(AgentSession(id: target, name: record.name))
            .write(to: sessions.appendingPathComponent(record.filename))
        try Data("{\"id\":\"\(workspace.uuidString)\",\"name\":\"Legacy placement\"}".utf8)
            .write(to: selected.appendingPathComponent("workspace.json"))
        for warm in [false, true] {
            let scanner = HistorySessionScanner(applicationSupportRoot: directory, workspaceDirectoryProvider: { _ in [selected] })
            if warm {
                _ = try await scanner.scanWorkspaces(matching: selected.lastPathComponent, requestBudget: .standalone())
                let lookup = try await scanner.locateSession(sessionID: target, requestBudget: .standalone())
                XCTAssertNotNil(lookup.location?.record)
                XCTAssertNil(lookup.location?.record?.workspaceID, "warm legacy records still need scanner-owned placement")
            }
            let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
            let scope = try grant(runtime: runtime, caller: caller, kind: .workspace(workspaceID: workspace))
            let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
            provenance.add(caller, parent: nil, workspace: workspace)
            let projector = SpawnProvenanceDelegationMembershipProjector(source: provenance)
            let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
            let frontDoor = AgentSessionAdministrationFrontDoor(
                core: AgentSessionAdministrationCore(scopes: runtime, projector: projector), scopes: runtime,
                projector: projector, inventory: source, liveBoundSession: { _ in caller }
            )
            let handler = Handler([.adminGet])
            frontDoor.register(handler)
            guard case let .completed(value) = try await frontDoor.perform(.init(
                operation: .adminGet, caller: .agentSession(caller), scopeID: scope.id, targetSessionIDs: [target]
            )) else { return XCTFail("scanner-owned exact workspace must prove legacy placement, warm=\(warm)") }
            XCTAssertEqual(value.objectValue?["code"], .string("workspace_not_loaded"))
            XCTAssertFalse(handler.performed)
            let decoded = await scanner.indexDecodeCountForTesting
            let hydrated = await scanner.transcriptDecodeCountForTesting
            XCTAssertEqual(decoded, 1)
            XCTAssertEqual(hydrated, 0)
        }
    }

    func testExactAncestryProbePropagatesCancellation() async throws {
        let scanner = Scanner()
        await scanner.setCancellation()
        let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [] }, links: { ([], []) })
        do {
            _ = try await source.snapshot(read: .init(loadedOnly: true, historyTargetIDs: [UUID()]))
            XCTFail("exact provenance cancellation cannot become a missing target")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        let global = await scanner.capturedQueries()
        XCTAssertTrue(global.isEmpty)
    }

    func testOrdinaryInventoryDoesNotTrustSidebarRowsCachedBeforeIndexOwnerInvalidation() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let target = UUID()
            let fixture = try await LoadedWindowFixture.make(activeID: target, parentID: nil)
            do {
                let window = fixture.window
                var workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                var tab = try XCTUnwrap(workspace.composeTabs.first)
                tab.activeAgentSessionID = nil
                workspace.composeTabs = [tab]
                let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
                window.workspaceManager.workspaces[index] = workspace
                window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                let vm = window.agentModeViewModel
                let oldOwner = try XCTUnwrap(vm.sessionIndexStore.sessionIndexOwner)
                let primed = vm.sidebarSessions(for: workspace.composeTabs)
                XCTAssertTrue(primed.contains { $0.sessionID == target }, "fixture must prime the indexed sidebar row")
                vm.sessionIndexStore.test_installOwnerState(
                    owner: oldOwner,
                    latestOwner: .init(workspaceID: workspace.id, activationEpoch: oldOwner.activationEpoch + 1)
                )
                XCTAssertTrue(vm.test_ownerValidatedSessionIndex.isEmpty)
                let cached = try XCTUnwrap(vm.sidebarSessionRowsCache)
                XCTAssertTrue(cached.rows.contains { $0.sessionID == target }, "fixture retains the previously cached presentation row")
                let scanner = Scanner()
                let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [window] }, links: { ([], []) })
                let snapshot = try await source.snapshot(read: .init(loadedOnly: true))
                XCTAssertNil(snapshot.records[target], "cached sidebar identity cannot override absent physical binding and stale index ownership")
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testStaleIndexOwnerCannotSupplyExactOrArchivedFallbackOrPlacementMetadata() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            let explicit = UUID(), indexedOnly = UUID(), parent = UUID()
            let fixture = try await LoadedWindowFixture.make(activeID: explicit, parentID: parent, stashedID: indexedOnly)
            do {
                let window = fixture.window
                var workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                let entries = window.agentModeViewModel.sessionIndex
                XCTAssertNotNil(entries[indexedOnly], "fixture must contain the stale reverse-index candidate")
                // Remove the archived tab's explicit binding: only the stale reverse index can name it.
                var archived = try XCTUnwrap(workspace.stashedTabs.first, "fixture must really contain an archived carrier")
                archived.tab.activeAgentSessionID = nil
                workspace.stashedTabs = [archived]
                let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
                window.workspaceManager.workspaces[index] = workspace
                window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                let current = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                let vm = window.agentModeViewModel
                let stale = AgentModeViewModel.SessionIndexOwner(workspaceID: current.id, activationEpoch: 1)
                let latest = AgentModeViewModel.SessionIndexOwner(workspaceID: current.id, activationEpoch: 2)
                vm.test_installSessionIndexSnapshot(entries, owner: stale, latestOwner: latest, activeWorkspace: current)
                let scanner = Scanner()
                let source = LiveAgentSessionInventorySource(scanner: scanner, windows: { [window] }, links: { ([], []) })
                let exact = try await source.snapshot(read: .init(loadedOnly: true, sessionIDs: [explicit, indexedOnly]))
                XCTAssertNotNil(exact.records[explicit], "genuine explicit tab bindings survive a stale metadata index")
                XCTAssertNil(exact.records[indexedOnly], "stale index cannot invent an exact tab binding")
                XCTAssertNil(exact.records[explicit]?.parentSessionID)
                XCTAssertNil(exact.records[explicit]?.organizationalParentID)
                XCTAssertFalse(exact.isInTree(explicit, rootSessionID: parent))
                let census = try await source.snapshot(read: .init(loadedOnly: true))
                XCTAssertNil(census.records[indexedOnly], "stale reverse index cannot name archived rows")
                XCTAssertNil(census.records[explicit]?.parentSessionID)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }
    }

    func testOrdinaryTreeIsBoundedPartialButAbsenceAndEdgePredicatesRequireGlobalHistory() throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, notifyCatalogChanged: { _ in })
        let caller = UUID()
        let tree = try grant(runtime: runtime, caller: caller, kind: .tree(rootSessionID: caller))
        var filter = DomainAgentSessionInventoryFilter()
        filter.workspaceID = UUID()
        filter.loaded = true
        let treeRead = AgentSessionInventoryRead.scoped(chain: [tree], filter: filter)
        XCTAssertNil(treeRead.workspaceID)
        XCTAssertTrue(treeRead.loadedOnly)
        var orphan = filter
        orphan.orphaned = true
        var links = filter
        links.hasLinks = false
        var role = filter
        role.role = .overseer
        for requiringCensus in [orphan, links, role] {
            let read = AgentSessionInventoryRead.scoped(chain: [tree], filter: requiringCensus)
            XCTAssertNil(read.workspaceID)
            XCTAssertFalse(read.loadedOnly)
        }
    }
}

// MARK: - In-flight structure operation idempotency

@MainActor
final class SessionAdminInFlightIdempotencyTests: XCTestCase {
    @MainActor
    private final class Gate {
        var paused = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            paused = true
            for observer in observers {
                observer.resume()
            }
            observers.removeAll()
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilPaused() async {
            if paused { return }
            await withCheckedContinuation { observers.append($0) }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class Fixture {
        let base = SessionAdminStructureTests.Fixture()
        let frontDoor: AgentSessionAdministrationFrontDoor
        let inventory: SessionAdminOrganizingOperationTests.FakeInventory
        let organizer = SessionAdminOrganizingOperationTests.FakeOrganizer()
        let provenance = SessionAdminScopeLifecycleTests.FakeProvenance()
        let links = SessionAdminOrganizingOperationTests.FakeLinks()
        let caller = UUID()
        let target = UUID()
        let tab = UUID()
        let scopeID: UUID

        init() throws {
            let workspace = UUID()
            base.provenance.add(caller, parent: nil, workspace: workspace)
            base.provenance.add(target, parent: caller, workspace: workspace)
            provenance.add(caller, parent: nil, workspace: workspace)
            provenance.add(target, parent: caller, workspace: workspace)
            organizer.add(caller, workspace: workspace, name: "Caller")
            organizer.add(target, workspace: workspace, name: "Target")
            inventory = .init(organizer: organizer, provenance: provenance, links: links, now: Date())
            let caller = caller, tab = tab
            frontDoor = .init(
                core: base.core, scopes: base.runtime, projector: base.projector,
                inventory: inventory, liveBoundSession: { $0 == tab ? caller : nil }
            )
            frontDoor.register(base.worktreeHandler)
            scopeID = try base.grant(caller).id
        }

        func request(branch: String = "branch") -> AgentSessionAdministrationRequest {
            .init(
                operation: .adminWorktreeCreate, caller: .agentSession(caller), callerTabID: tab,
                scopeID: scopeID, targetSessionIDs: [target], idempotencyKey: "create-once",
                arguments: ["branch": .string(branch)]
            )
        }

        func value(_ request: AgentSessionAdministrationRequest) async throws -> [String: Value] {
            guard case let .completed(value) = try await frontDoor.perform(request) else {
                XCTFail("Expected completed response")
                return [:]
            }
            return try XCTUnwrap(value.objectValue)
        }
    }

    /// Suspend at the real handler's creation boundary, then retry through the production front
    /// door. Both equal and conflicting concurrent calls must leave the host with one creation.
    func testConcurrentDirectCreateIsReservedUntilItsReceiptCanBeReplayed() async throws {
        let fixture = try Fixture()
        let gate = Gate()
        fixture.base.worktrees.beforeCreateCommit = { await gate.suspend() }
        let request = fixture.request()
        let first = Task { try await fixture.value(request) }
        await gate.waitUntilPaused()
        let pending = try await fixture.value(request)
        XCTAssertEqual(pending["result"], .string("in_progress"))
        XCTAssertEqual(pending["retryable"], .bool(true))
        guard case .idempotencyConflict = try await fixture.frontDoor.perform(fixture.request(branch: "different")) else {
            gate.resume()
            _ = try await first.value
            return XCTFail("A different concurrent request must conflict")
        }
        XCTAssertTrue(fixture.base.worktrees.created.isEmpty)
        gate.resume()
        let applied = try await first.value
        XCTAssertEqual(applied["changed_count"], .int(1))
        let replay = try await fixture.value(request)
        XCTAssertEqual(replay["idempotent_replay"], .bool(true))
        XCTAssertEqual(fixture.base.worktrees.created, [fixture.target])
    }

    func testExplicitRevokedScopeCannotReplayPriorSuccess() async throws {
        let fixture = try Fixture()
        let request = fixture.request()
        _ = try await fixture.value(request)
        _ = fixture.base.runtime.revoke(scopeID: fixture.scopeID)
        guard case .denied = try await fixture.frontDoor.perform(request) else {
            return XCTFail("Revoked authority must reach the core denial before cached success")
        }
        XCTAssertEqual(fixture.base.worktrees.created, [fixture.target])
    }

    func testCancelledCreationReleasesReservationWithoutCachingAnEffect() async throws {
        let fixture = try Fixture()
        let gate = Gate()
        fixture.base.worktrees.beforeCreateCommit = { await gate.suspend() }
        let first = Task { try await fixture.value(fixture.request()) }
        await gate.waitUntilPaused()
        first.cancel()
        gate.resume()
        // The production handler's commit predicate includes cancellation, so the resumed host
        // refuses the effect. Either a cancellation or a structured refusal is acceptable.
        do { _ = try await first.value } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(fixture.base.worktrees.created.isEmpty)
        fixture.base.worktrees.beforeCreateCommit = nil
        let retry = try await fixture.value(fixture.request())
        XCTAssertNotEqual(retry["result"], .string("in_progress"))
        XCTAssertNotEqual(retry["idempotent_replay"], .bool(true))
        XCTAssertEqual(fixture.base.worktrees.created, [fixture.target])
    }
}
