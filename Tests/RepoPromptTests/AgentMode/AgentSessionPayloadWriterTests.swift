import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionPayloadWriterTests: XCTestCase {
    func testPayloadPersistsWithoutPresentationAndDoesNotInventAcknowledgment() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = AgentSessionDataService()
        var phases: [AgentSessionRequiredSavePhase] = []
        let outcome = try await fixture.write(observingPhase: { phases.append($0) }) { payload, workspace, count in
            try await service.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
        }
        guard case let .written(url) = outcome else { return XCTFail("Exact writer must persist") }
        let loaded = try await service.loadAgentSession(from: url)
        XCTAssertEqual(loaded.id, fixture.payload.id)
        XCTAssertEqual(loaded.workspaceID, fixture.workspace.id)
        XCTAssertEqual(loaded.composeTabID, fixture.session.tabID)
        XCTAssertEqual(phases, [.writeMayHaveCommitted, .writeReturned])
        XCTAssertTrue(fixture.session.isDirty, "Payload IO cannot acknowledge first-save or terminal settlement on behalf of their owners")
    }

    func testMismatchedPayloadAndStaleCapabilitiesNeverReachSaver() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var calls = 0
        let saver: AgentSessionPayloadWriter.Saver = { _, _, _ in
            calls += 1
            return fixture.root.appendingPathComponent("unexpected.json")
        }
        var wrong = fixture.payload
        wrong.workspaceID = UUID()
        let wrongID = AgentSession(id: UUID(), workspaceID: fixture.workspace.id, composeTabID: fixture.session.tabID, name: "Wrong ID")
        let wrongTab = AgentSession(id: fixture.payload.id, workspaceID: fixture.workspace.id, composeTabID: UUID(), name: "Wrong tab")
        for payload in [wrong, wrongID, wrongTab] {
            let misplaced = try await fixture.write(payload: payload, saver: saver)
            guard case .rejectedBeforeWrite = misplaced else { return XCTFail("Payload placement must be checked") }
        }
        fixture.session.installPersistentSessionBinding(.init(
            tabID: fixture.session.tabID, sessionID: fixture.payload.id, workspaceID: fixture.workspace.id
        ))
        let stale = try await fixture.write(saver: saver)
        guard case .rejectedBeforeWrite = stale else { return XCTFail("Same UUID does not revive an old capability") }
        XCTAssertEqual(calls, 0)
    }

    func testSuspendedWritePreservesEffectEvidenceAcrossOwnershipAndPlacementChanges() async throws {
        enum Change: CaseIterable { case rebind, mutation, storageMove, competingWriter }
        for change in Change.allCases {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let service = AgentSessionDataService()
            let entered = expectation(description: "Payload committed before \(change)")
            var release: CheckedContinuation<Void, Never>?
            var storageCurrent = true
            var phases: [AgentSessionRequiredSavePhase] = []
            let task = Task { @MainActor in
                try await fixture.write(storageIsCurrent: { storageCurrent }, observingPhase: { phases.append($0) }) { payload, workspace, count in
                    let url = try await service.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
                    await withCheckedContinuation { release = $0
                        entered.fulfill()
                    }
                    return url
                }
            }
            await fulfillment(of: [entered], timeout: 5)
            var competingScope: AgentSessionRuntimeStore.Scope?
            switch change {
            case .rebind:
                fixture.session.installPersistentSessionBinding(.init(
                    tabID: fixture.session.tabID, sessionID: fixture.payload.id, workspaceID: fixture.workspace.id
                ))
            case .mutation:
                fixture.session.saveRequestGeneration &+= 1
            case .storageMove:
                storageCurrent = false
            case .competingWriter:
                competingScope = fixture.store.makeScope()
                let competitor = AgentTabSession(tabID: fixture.session.tabID)
                competitor.installPersistentSessionBinding(.init(
                    tabID: competitor.tabID, sessionID: fixture.payload.id, workspaceID: fixture.workspace.id
                ))
                competingScope?.replaceSessions([competitor.tabID: competitor])
            }
            release?.resume()
            let outcome = try await task.value
            withExtendedLifetime(competingScope) {}
            guard case let .supersededAfterWrite(url) = outcome else { return XCTFail("\(change) must not acknowledge a stale write") }
            let loaded = try await service.loadAgentSession(from: url)
            XCTAssertEqual(loaded.id, fixture.payload.id, "The durable effect exists even when acknowledgment is rejected")
            XCTAssertEqual(phases, [.writeMayHaveCommitted, .writeReturned])
            XCTAssertTrue(fixture.session.isDirty)
        }
    }

    func testSaverFailureAfterDurableEffectDoesNotClaimNoWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = AgentSessionDataService()
        var phases: [AgentSessionRequiredSavePhase] = []
        var committedURL: URL?
        do {
            _ = try await fixture.write(observingPhase: { phases.append($0) }) { payload, workspace, count in
                committedURL = try await service.saveAgentSession(payload, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: count)
                throw CancellationError()
            }
            XCTFail("Saver cancellation must propagate")
        } catch is CancellationError {} catch { throw error }
        let loaded = try await service.loadAgentSession(from: XCTUnwrap(committedURL))
        XCTAssertEqual(loaded.id, fixture.payload.id)
        XCTAssertEqual(phases, [.writeMayHaveCommitted])
        XCTAssertTrue(fixture.session.isDirty)
    }

    @MainActor
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M9PayloadWriter-\(UUID().uuidString)")
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let session = AgentTabSession(tabID: UUID())
        let workspace: WorkspaceModel
        let payload: AgentSession
        let writer: AgentSessionRuntimeStore.Writer
        let token: AgentSessionSaveCommitToken

        init() throws {
            workspace = WorkspaceModel(name: "Runtime writer", repoPaths: [], customStoragePath: root)
            scope = store.makeScope()
            let sessionID = UUID()
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: sessionID, workspaceID: workspace.id))
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            session.hasLoadedPersistedState = true
            session.isDirty = true
            scope.replaceSessions([session.tabID: session])
            guard case let .unique(resolved) = store.resolveWriter(workspaceID: workspace.id, sessionID: sessionID) else {
                throw XCTUnwrapError()
            }
            writer = resolved
            payload = AgentSession(id: sessionID, workspaceID: workspace.id, composeTabID: session.tabID, name: "Runtime writer")
            token = AgentSessionSaveCommitToken(
                tabID: session.tabID, sessionIdentity: ObjectIdentifier(session), workspaceID: workspace.id,
                workspaceDirectoryPath: root.standardizedFileURL.path, binding: resolved.binding,
                bindingTransitionGeneration: session.bindingTransitionGeneration, sourceItemsRevision: session.sourceItemsRevision,
                persistenceMutationGeneration: session.persistenceMutationGeneration, saveRequestGeneration: session.saveRequestGeneration
            )
        }

        func write(
            payload: AgentSession? = nil,
            storageIsCurrent: () -> Bool = { true },
            observingPhase: ((AgentSessionRequiredSavePhase) -> Void)? = nil,
            saver: AgentSessionPayloadWriter.Saver
        ) async throws -> AgentSessionPayloadWriter.Outcome {
            try await AgentSessionPayloadWriter.write(
                payload ?? self.payload, workspace: workspace, canonicalItemCount: 0, writer: writer, token: token,
                storageIsCurrent: storageIsCurrent, observingPhase: observingPhase, saver: saver
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private struct XCTUnwrapError: Error {}
    }
}
