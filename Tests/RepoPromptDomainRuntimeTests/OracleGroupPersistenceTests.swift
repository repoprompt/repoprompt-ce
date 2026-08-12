import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class OracleGroupPersistenceTests: XCTestCase {
    func testPreparedArtifactGroupColdLoadsThroughEveryMemberAndCommitsTerminalCAS() async throws {
        let fixture = makeStore(profile: "prepared-terminal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifact = Data("exact frozen context".utf8)
        let artifactID = try await fixture.store.storeArtifact(artifact)
        let prepared = try makeGroup(count: 5, seed: "cold", artifactID: artifactID)
        try await fixture.store.create(prepared)

        let coldStore = DomainOracleConversationStore(
            persistence: fixture.persistence,
            identity: makeIdentity()
        )
        for member in prepared.members {
            let loaded = try await coldStore.load(
                member: OracleMemberLookup(publicChatID: member.publicChatID),
                owner: prepared.owner
            )
            XCTAssertEqual(loaded, prepared)
        }
        let loadedArtifact = try await coldStore.loadArtifact(id: artifactID)
        XCTAssertEqual(loadedArtifact, artifact)

        let terminal = try terminalDocument(from: prepared)
        try await coldStore.save(terminal, expectedRevision: prepared.revision)
        let terminalSnapshot = try await coldStore.load(
            groupID: prepared.group.id,
            owner: prepared.owner
        )
        let loadedTerminal = try XCTUnwrap(terminalSnapshot)
        XCTAssertEqual(loadedTerminal.turns.last?.state, .terminal)
        XCTAssertEqual(loadedTerminal.turns.last?.results.count, 5)

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await coldStore.save(terminal, expectedRevision: prepared.revision)
        } verify: {
            XCTAssertEqual(
                $0 as? OraclePersistenceError,
                .revisionConflict(expected: prepared.revision, actual: terminal.revision)
            )
        }
    }

    func testInterruptedAggregatePublicationRecoversDocumentAndCompleteIndex() async throws {
        let fixture = makeStore(profile: "recovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let interrupter = OneShotPersistenceInterrupter()
        let interruptedStore = DomainOracleConversationStore(
            persistence: fixture.persistence,
            identity: makeIdentity(),
            mutationObserver: { phase in try interrupter.observe(phase) }
        )
        let prepared = try makeGroup(count: 2, seed: "recover")

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await interruptedStore.create(prepared)
        } verify: { _ in }

        let recoveredStore = DomainOracleConversationStore(
            persistence: fixture.persistence,
            identity: makeIdentity()
        )
        let loaded = try await recoveredStore.load(
            member: OracleMemberLookup(publicChatID: prepared.members[1].publicChatID),
            owner: prepared.owner
        )
        XCTAssertEqual(loaded, prepared)
        let recoverable = try await recoveredStore.recoverPreparedGroups(owner: prepared.owner)
        XCTAssertTrue(recoverable.contains { $0.group.id == prepared.group.id })
    }

    func testRenameDeleteAndRetentionOperateOnLogicalGroupsAndArtifacts() async throws {
        let fixture = makeStore(profile: "lifecycle")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try OracleConversationOwner(kind: "workspace", identifier: "lifecycle")
        var groups: [OracleGroupDocument] = []
        var artifactIDs: [String] = []
        for index in 0 ..< 3 {
            let artifactID = try await fixture.store.storeArtifact(Data("artifact-\(index)".utf8))
            artifactIDs.append(artifactID)
            let group = try makeGroup(
                count: index == 2 ? 5 : 2,
                seed: "group-\(index)",
                owner: owner,
                artifactID: artifactID,
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
            )
            groups.append(group)
            try await fixture.store.create(group)
        }

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.rename(
                groupID: groups[2].group.id,
                owner: owner,
                name: "Too early",
                expectedRevision: groups[2].revision
            )
        } verify: {
            XCTAssertEqual(
                $0 as? OraclePersistenceError,
                .invalidDocument("cannot_rename_prepared_group")
            )
        }
        groups[2] = try terminalDocument(from: groups[2])
        try await fixture.store.save(groups[2], expectedRevision: groups[2].revision - 1)

        try await fixture.store.rename(
            groupID: groups[2].group.id,
            owner: owner,
            name: "Renamed logical group",
            expectedRevision: groups[2].revision
        )
        let renamedSnapshot = try await fixture.store.load(groupID: groups[2].group.id, owner: owner)
        let renamed = try XCTUnwrap(renamedSnapshot)
        XCTAssertEqual(renamed.name, "Renamed logical group")
        XCTAssertEqual(renamed.revision, groups[2].revision + 1)

        let removed = try await fixture.store.retainMostRecentGroups(1, owner: owner)
        XCTAssertEqual(Set(removed), Set([groups[0].group.id, groups[1].group.id]))
        let retainedGroup = try await fixture.store.load(groupID: groups[2].group.id, owner: owner)
        XCTAssertNotNil(retainedGroup)
        for id in artifactIDs.prefix(2) {
            await XCTAssertOraclePersistenceThrowsErrorAsync { try await fixture.store.loadArtifact(id: id) } verify: {
                XCTAssertEqual($0 as? OraclePersistenceError, .artifactMissing(id))
            }
        }

        try await fixture.store.delete(
            groupID: groups[2].group.id,
            owner: owner,
            expectedRevision: renamed.revision
        )
        let deletedGroup = try await fixture.store.load(groupID: groups[2].group.id, owner: owner)
        XCTAssertNil(deletedGroup)
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.loadArtifact(id: artifactIDs[2])
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .artifactMissing(artifactIDs[2]))
        }
    }

    func testDeleteAllGroupsRemovesOnlyTheRequestedOwnersGroups() async throws {
        let fixture = makeStore(profile: "delete-all")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try OracleConversationOwner(kind: "workspace", identifier: "delete-all")
        let otherOwner = try OracleConversationOwner(kind: "workspace", identifier: "retained")
        let owned = try makeGroup(count: 2, seed: "owned", owner: owner)
        let retained = try makeGroup(count: 2, seed: "retained", owner: otherOwner)
        try await fixture.store.create(owned)
        try await fixture.store.create(retained)

        try await fixture.store.deleteAllGroups(owner: owner)

        let deleted = try await fixture.store.load(groupID: owned.group.id, owner: owner)
        let remaining = try await fixture.store.load(groupID: retained.group.id, owner: otherOwner)
        XCTAssertNil(deleted)
        XCTAssertNotNil(remaining)

        let openTabOwner = try OracleConversationOwner(
            kind: "app-tab",
            identifier: "workspace:workspace-id:tab:open"
        )
        let closedTabOwner = try OracleConversationOwner(
            kind: "app-tab",
            identifier: "workspace:workspace-id:tab:closed"
        )
        let otherWorkspaceOwner = try OracleConversationOwner(
            kind: "app-tab",
            identifier: "workspace:other:tab:closed"
        )
        let openTab = try makeGroup(count: 2, seed: "open-tab", owner: openTabOwner)
        let closedTab = try makeGroup(count: 2, seed: "closed-tab", owner: closedTabOwner)
        let otherWorkspace = try makeGroup(count: 2, seed: "other-workspace", owner: otherWorkspaceOwner)
        try await fixture.store.create(openTab)
        try await fixture.store.create(closedTab)
        try await fixture.store.create(otherWorkspace)

        try await fixture.store.deleteAllGroups(
            ownerKind: "app-tab",
            identifierPrefix: "workspace:workspace-id:tab:"
        )

        let deletedOpenTab = try await fixture.store.load(groupID: openTab.group.id, owner: openTabOwner)
        let deletedClosedTab = try await fixture.store.load(groupID: closedTab.group.id, owner: closedTabOwner)
        let retainedOtherWorkspace = try await fixture.store.load(
            groupID: otherWorkspace.group.id,
            owner: otherWorkspaceOwner
        )
        XCTAssertNil(deletedOpenTab)
        XCTAssertNil(deletedClosedTab)
        XCTAssertNotNil(retainedOtherWorkspace)
    }

    func testDigestMismatchedArtifactFailsColdLoadClosed() async throws {
        let fixture = makeStore(profile: "digest-mismatch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifactID = try await fixture.store.storeArtifact(Data("trusted".utf8))
        let group = try makeGroup(count: 2, seed: "digest", artifactID: artifactID)
        try await fixture.store.create(group)
        let artifactURL = fixture.persistence.oracleStorageRoot
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("\(artifactID).blob")
        try Data("tampered".utf8).write(to: artifactURL)

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            _ = try await fixture.store.load(groupID: group.group.id, owner: group.owner)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .artifactDigestMismatch(artifactID))
        }
    }

    func testUnreferencedArtifactCleanupPreservesReferencedContent() async throws {
        let fixture = makeStore(profile: "artifact-cleanup")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let orphanID = try await fixture.store.storeArtifact(Data("orphan".utf8))
        try await fixture.store.removeArtifactIfUnreferenced(id: orphanID)
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.loadArtifact(id: orphanID)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .artifactMissing(orphanID))
        }

        let sharedData = Data("shared".utf8)
        let sharedID = try await fixture.store.storeArtifact(sharedData)
        let group = try makeGroup(count: 2, seed: "shared-artifact", artifactID: sharedID)
        try await fixture.store.create(group)
        try await fixture.store.removeArtifactIfUnreferenced(id: sharedID)
        let retainedData = try await fixture.store.loadArtifact(id: sharedID)
        XCTAssertEqual(retainedData, sharedData)
    }

    func testArtifactReservationPreventsConcurrentPublisherCleanup() async throws {
        let fixture = makeStore(profile: "artifact-reservations")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = Data("shared-unpublished".utf8)
        let first = try await fixture.store.reserveArtifact(data)
        let second = try await fixture.store.reserveArtifact(data)
        XCTAssertEqual(first.artifactID, second.artifactID)

        try await fixture.store.releaseArtifactReservation(first, removeIfUnreferenced: true)
        let retained = try await fixture.store.loadArtifact(id: second.artifactID)
        XCTAssertEqual(retained, data)

        try await fixture.store.releaseArtifactReservation(second, removeIfUnreferenced: true)
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.loadArtifact(id: second.artifactID)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .artifactMissing(second.artifactID))
        }
    }

    func testArtifactReservationSurvivesFinalGroupAndSingleReferenceDeletion() async throws {
        let fixture = makeStore(profile: "reserved-deletion")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try OracleConversationOwner(kind: "workspace", identifier: "reserved-deletion")

        let groupData = Data("reserved-group".utf8)
        let groupReservation = try await fixture.store.reserveArtifact(groupData)
        let group = try makeGroup(
            count: 2,
            seed: "reserved-group",
            owner: owner,
            artifactID: groupReservation.artifactID
        )
        try await fixture.store.create(group)
        try await fixture.store.delete(
            groupID: group.group.id,
            owner: owner,
            expectedRevision: group.revision
        )
        let retainedGroupArtifact = try await fixture.store.loadArtifact(id: groupReservation.artifactID)
        XCTAssertEqual(retainedGroupArtifact, groupData)
        try await fixture.store.releaseArtifactReservation(groupReservation, removeIfUnreferenced: true)

        let singleData = Data("reserved-single".utf8)
        let singleReservation = try await fixture.store.reserveArtifact(singleData)
        let single = try makeSingle(
            chatID: "reserved-single",
            owner: owner,
            artifactID: singleReservation.artifactID
        )
        try await fixture.store.create(single)
        try await fixture.store.delete(
            publicChatID: single.publicChatID,
            owner: owner,
            expectedRevision: single.revision
        )
        let retainedSingleArtifact = try await fixture.store.loadArtifact(id: singleReservation.artifactID)
        XCTAssertEqual(retainedSingleArtifact, singleData)
        try await fixture.store.releaseArtifactReservation(singleReservation, removeIfUnreferenced: true)
    }

    func testDestructiveGroupOperationsRespectActiveClaim() async throws {
        let fixture = makeStore(profile: "claimed-deletion")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let group = try makeGroup(count: 2, seed: "claimed-deletion")
        try await fixture.store.create(group)
        let claimManager = OracleGroupClaimManager(
            persistence: fixture.persistence,
            identity: makeIdentity()
        )
        let claim = try await claimManager.acquire(
            group: group,
            owner: group.owner,
            invocationID: UUID(),
            runID: UUID()
        )

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.delete(
                groupID: group.group.id,
                owner: group.owner,
                expectedRevision: group.revision
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupClaimError, .conflict)
        }
        let retainedGroups = try await fixture.store.retainMostRecentGroups(0, owner: group.owner)
        XCTAssertEqual(retainedGroups, [])
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.deleteAllGroups(owner: group.owner)
        } verify: {
            XCTAssertEqual($0 as? OracleGroupClaimError, .conflict)
        }
        let claimedGroup = try await fixture.store.load(groupID: group.group.id, owner: group.owner)
        XCTAssertNotNil(claimedGroup)

        claim.release()
        try await fixture.store.deleteAllGroups(owner: group.owner)
        let deletedGroup = try await fixture.store.load(groupID: group.group.id, owner: group.owner)
        XCTAssertNil(deletedGroup)
    }

    func testUnreadableGroupFailsRetentionClosedWithoutDeletingValidGroup() async throws {
        let fixture = makeStore(profile: "fail-closed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let valid = try makeGroup(count: 2, seed: "valid")
        try await fixture.store.create(valid)
        let corruptURL = fixture.persistence.oracleStorageRoot
            .appendingPathComponent("groups", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: corruptURL)

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            _ = try await fixture.store.retainMostRecentGroups(0, owner: valid.owner)
        } verify: { _ in }

        try FileManager.default.removeItem(at: corruptURL)
        let validAfterFailure = try await fixture.store.load(groupID: valid.group.id, owner: valid.owner)
        XCTAssertNotNil(validAfterFailure)
    }

    func testDurableSingleUsesIndependentCASRecord() async throws {
        let fixture = makeStore(profile: "single")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try OracleConversationOwner(kind: "direct", identifier: "route")
        let model = try OracleModelReference(providerID: "codex", modelID: "primary")
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let input = try OracleInput(mode: .chat, userMessage: "single message")
        let preparedTurn = OracleTurnRecord(
            input: input,
            state: .prepared,
            startedAt: createdAt
        )
        let single = try OracleSingleConversationDocument(
            publicChatID: "single-chat",
            owner: owner,
            model: model,
            revision: 1,
            createdAt: createdAt,
            updatedAt: createdAt,
            turns: [preparedTurn]
        )
        try await fixture.store.create(single)
        let loadedSingle = try await fixture.store.load(
            publicChatID: single.publicChatID,
            owner: owner
        )
        XCTAssertEqual(loadedSingle, single)

        let singleResult = try OracleLaneResult(
            laneIndex: 0,
            chatID: single.publicChatID,
            providerID: model.providerID,
            modelID: model.modelID,
            status: .completed,
            response: "single response"
        )
        let terminalTurn = OracleTurnRecord(
            id: preparedTurn.id,
            input: input,
            state: .terminal,
            startedAt: createdAt,
            finishedAt: createdAt.addingTimeInterval(1),
            results: [singleResult]
        )
        let saved = try OracleSingleConversationDocument(
            publicChatID: single.publicChatID,
            owner: owner,
            model: model,
            providerConversationID: "provider-chat",
            revision: 2,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1),
            turns: [terminalTurn]
        )
        try await fixture.store.save(saved, expectedRevision: 1)
        let loadedSaved = try await fixture.store.load(
            publicChatID: single.publicChatID,
            owner: owner
        )
        XCTAssertEqual(loadedSaved, saved)
        try await fixture.store.delete(
            publicChatID: single.publicChatID,
            owner: owner,
            expectedRevision: 2
        )
        let deletedSingle = try await fixture.store.load(
            publicChatID: single.publicChatID,
            owner: owner
        )
        XCTAssertNil(deletedSingle)
    }

    func testSharedArtifactsRemainUntilLastGroupOrSingleReferenceIsDeleted() async throws {
        let fixture = makeStore(profile: "shared-artifacts")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try OracleConversationOwner(kind: "workspace", identifier: "shared-artifacts")

        let groupFirstArtifact = try await fixture.store.storeArtifact(Data("group-first".utf8))
        let groupFirst = try makeGroup(
            count: 2,
            seed: "group-first",
            owner: owner,
            artifactID: groupFirstArtifact
        )
        let groupFirstSingle = try makeSingle(
            chatID: "group-first-single",
            owner: owner,
            artifactID: groupFirstArtifact
        )
        try await fixture.store.create(groupFirst)
        try await fixture.store.create(groupFirstSingle)
        try await fixture.store.delete(
            groupID: groupFirst.group.id,
            owner: owner,
            expectedRevision: groupFirst.revision
        )
        let retainedAfterGroupDelete = try await fixture.store.loadArtifact(id: groupFirstArtifact)
        XCTAssertEqual(retainedAfterGroupDelete, Data("group-first".utf8))
        try await fixture.store.delete(
            publicChatID: groupFirstSingle.publicChatID,
            owner: owner,
            expectedRevision: groupFirstSingle.revision
        )
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.loadArtifact(id: groupFirstArtifact)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .artifactMissing(groupFirstArtifact))
        }

        let singleFirstArtifact = try await fixture.store.storeArtifact(Data("single-first".utf8))
        let singleFirst = try makeSingle(
            chatID: "single-first-single",
            owner: owner,
            artifactID: singleFirstArtifact
        )
        let singleFirstGroup = try makeGroup(
            count: 2,
            seed: "single-first",
            owner: owner,
            artifactID: singleFirstArtifact
        )
        try await fixture.store.create(singleFirst)
        try await fixture.store.create(singleFirstGroup)
        try await fixture.store.delete(
            publicChatID: singleFirst.publicChatID,
            owner: owner,
            expectedRevision: singleFirst.revision
        )
        let retainedAfterSingleDelete = try await fixture.store.loadArtifact(id: singleFirstArtifact)
        XCTAssertEqual(retainedAfterSingleDelete, Data("single-first".utf8))
        try await fixture.store.delete(
            groupID: singleFirstGroup.group.id,
            owner: owner,
            expectedRevision: singleFirstGroup.revision
        )
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.loadArtifact(id: singleFirstArtifact)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .artifactMissing(singleFirstArtifact))
        }
    }

    private func makeStore(
        profile: String
    ) -> (root: URL, persistence: DomainPersistenceCoordinator, store: DomainOracleConversationStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleGroupPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        let identity = makeIdentity()
        let persistence = DomainPersistenceCoordinator(
            configuration: DomainRuntimeConfiguration(
                mode: .standalone,
                profileIdentifier: profile,
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events"),
                temporaryDirectory: root.appendingPathComponent("Temporary"),
                externalReloadInterval: nil
            ),
            identity: identity
        )
        return (
            root,
            persistence,
            DomainOracleConversationStore(persistence: persistence, identity: identity)
        )
    }

    private func makeIdentity() -> DomainRuntimeIdentity {
        DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42,
            mode: .standalone,
            createdAt: Date()
        )
    }

    private func makeGroup(
        count: Int,
        seed: String,
        owner: OracleConversationOwner? = nil,
        artifactID: String? = nil,
        timestamp: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> OracleGroupDocument {
        let owner = try owner ?? OracleConversationOwner(kind: "workspace", identifier: seed)
        let models = try (0 ..< count).map {
            try OracleModelReference(providerID: "fixture", modelID: "model-\($0)")
        }
        let roster = try OracleRoster(primary: models[0], additional: Array(models.dropFirst()))
        let group = try OracleGroupDescriptor(size: count)
        let members = try (0 ..< count).map {
            try OracleGroupMember(
                laneID: OracleLaneID(index: $0),
                publicChatID: "\(seed)-chat-\($0)",
                model: models[$0]
            )
        }
        let context: OracleContextEnvelope?
        if let artifactID {
            context = OracleContextEnvelope(
                content: .durableArtifact(id: artifactID),
                sha256: artifactID,
                provenance: [OracleEvidenceReference(path: "/fixture/\(seed)")]
            )
        } else {
            let inline = "inline-\(seed)"
            context = OracleContextEnvelope(
                content: .inline(inline),
                sha256: DomainContentDigest.sha256(Data(inline.utf8))
            )
        }
        let turn = OracleTurnRecord(
            input: try OracleInput(mode: .chat, userMessage: "message-\(seed)", context: context),
            state: .prepared,
            startedAt: timestamp
        )
        return try OracleGroupDocument(
            group: group,
            owner: owner,
            name: "Group \(seed)",
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            roster: roster,
            members: members,
            turns: [turn]
        )
    }

    private func terminalDocument(from prepared: OracleGroupDocument) throws -> OracleGroupDocument {
        let turn = try XCTUnwrap(prepared.turns.last)
        let results = try prepared.members.map { member in
            try OracleLaneResult(
                laneIndex: member.laneID.index,
                chatID: member.publicChatID,
                providerID: member.model.providerID,
                modelID: member.model.modelID,
                status: .completed,
                response: "response-\(member.laneID.index)"
            )
        }
        let terminal = OracleTurnRecord(
            id: turn.id,
            input: turn.input,
            state: .terminal,
            startedAt: turn.startedAt,
            finishedAt: turn.startedAt.addingTimeInterval(1),
            results: results
        )
        return try OracleGroupDocument(
            group: prepared.group,
            owner: prepared.owner,
            name: prepared.name,
            revision: prepared.revision + 1,
            createdAt: prepared.createdAt,
            updatedAt: prepared.updatedAt.addingTimeInterval(1),
            roster: prepared.roster,
            members: prepared.members,
            turns: Array(prepared.turns.dropLast()) + [terminal]
        )
    }

    private func makeSingle(
        chatID: String,
        owner: OracleConversationOwner,
        artifactID: String
    ) throws -> OracleSingleConversationDocument {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let model = try OracleModelReference(providerID: "fixture", modelID: "single-model")
        let context = OracleContextEnvelope(
            content: .durableArtifact(id: artifactID),
            sha256: artifactID
        )
        return try OracleSingleConversationDocument(
            publicChatID: chatID,
            owner: owner,
            model: model,
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            turns: [OracleTurnRecord(
                input: OracleInput(mode: .chat, userMessage: "single-message", context: context),
                state: .prepared,
                startedAt: timestamp
            )]
        )
    }
}

private func XCTAssertOraclePersistenceThrowsErrorAsync<T>(
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

private final class OneShotPersistenceInterrupter: @unchecked Sendable {
    private let lock = NSLock()
    private var didInterrupt = false

    func observe(_ phase: OraclePersistenceMutationPhase) throws {
        guard case .journalPersisted = phase else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !didInterrupt else { return }
        didInterrupt = true
        throw CocoaError(.fileWriteUnknown)
    }
}
