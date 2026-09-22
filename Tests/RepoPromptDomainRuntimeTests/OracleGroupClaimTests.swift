import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class OracleGroupClaimTests: XCTestCase {
    func testSimultaneousClaimConflictsUntilExplicitRelease() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstManager = OracleGroupClaimManager(
            persistence: fixture.persistence,
            identity: fixture.identity
        )
        let secondManager = OracleGroupClaimManager(
            persistence: fixture.persistence,
            identity: fixture.identity
        )
        let first = try await firstManager.acquire(
            group: fixture.group,
            owner: fixture.group.owner,
            invocationID: UUID(),
            runID: UUID()
        )

        await XCTAssertOracleClaimThrowsErrorAsync {
            _ = try await secondManager.acquire(
                group: fixture.group,
                owner: fixture.group.owner,
                invocationID: UUID(),
                runID: UUID()
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupClaimError, .conflict)
        }

        XCTAssertFalse(first.isReleased)
        first.release()
        XCTAssertTrue(first.isReleased)
        first.release()
        let retry = try await secondManager.acquire(
            group: fixture.group,
            owner: fixture.group.owner,
            invocationID: UUID(),
            runID: UUID()
        )
        retry.release()
    }

    func testRouteOwnerMismatchFailsBeforeLockAcquisition() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = OracleGroupClaimManager(
            persistence: fixture.persistence,
            identity: fixture.identity
        )
        let wrongOwner = try OracleConversationOwner(kind: "workspace", identifier: "other")

        await XCTAssertOracleClaimThrowsErrorAsync {
            _ = try await manager.acquire(
                group: fixture.group,
                owner: wrongOwner,
                invocationID: UUID(),
                runID: UUID()
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupClaimError, .ownerMismatch)
        }

        let valid = try await manager.acquire(
            group: fixture.group,
            owner: fixture.group.owner,
            invocationID: UUID(),
            runID: UUID()
        )
        valid.release()
    }

    func testClaimBindsGroupOwnerInvocationRunAndRuntimeIdentity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = OracleGroupClaimManager(
            persistence: fixture.persistence,
            identity: fixture.identity
        )
        let invocationID = UUID()
        let runID = UUID()
        let claim = try await manager.acquire(
            group: fixture.group,
            owner: fixture.group.owner,
            invocationID: invocationID,
            runID: runID
        )

        XCTAssertEqual(claim.groupID, fixture.group.group.id)
        XCTAssertEqual(claim.owner, fixture.group.owner)
        XCTAssertEqual(claim.invocationID, invocationID)
        XCTAssertEqual(claim.runID, runID)
        XCTAssertEqual(claim.runtimeID, fixture.identity.runtimeID)
        claim.release()
    }

    private func makeFixture() throws -> (
        root: URL,
        persistence: DomainPersistenceCoordinator,
        identity: DomainRuntimeIdentity,
        group: OracleGroupDocument
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleGroupClaimTests-\(UUID().uuidString)", isDirectory: true)
        let identity = DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 7,
            processID: 42,
            mode: .standalone,
            createdAt: Date()
        )
        let persistence = DomainPersistenceCoordinator(
            configuration: DomainRuntimeConfiguration(
                mode: .standalone,
                profileIdentifier: "claim-test",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events"),
                temporaryDirectory: root.appendingPathComponent("Temporary"),
                externalReloadInterval: nil
            ),
            identity: identity
        )
        let owner = try OracleConversationOwner(kind: "workspace", identifier: "claim-route")
        let models = try ["primary", "additional"].map {
            try OracleModelReference(providerID: "fixture", modelID: $0)
        }
        let roster = try OracleRoster(primary: models[0], additional: [models[1]])
        let descriptor = try OracleGroupDescriptor(size: 2)
        let members = try (0 ..< 2).map {
            try OracleGroupMember(
                laneID: OracleLaneID(index: $0),
                publicChatID: "claim-chat-\($0)",
                model: models[$0]
            )
        }
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let turn = OracleTurnRecord(
            input: try OracleInput(mode: .chat, userMessage: "claim"),
            state: .prepared,
            startedAt: timestamp
        )
        let group = try OracleGroupDocument(
            group: descriptor,
            owner: owner,
            name: "Claim",
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            roster: roster,
            members: members,
            turns: [turn]
        )
        return (root, persistence, identity, group)
    }
}

private func XCTAssertOracleClaimThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
