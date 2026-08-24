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
        XCTAssertEqual(loadedTerminal.turns.last?.status, .completed)
        XCTAssertEqual(loadedTerminal.turns.last?.warnings, [])

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await coldStore.save(terminal, expectedRevision: prepared.revision)
        } verify: {
            XCTAssertEqual(
                $0 as? OraclePersistenceError,
                .revisionConflict(expected: prepared.revision, actual: terminal.revision)
            )
        }
    }

    func testPartialFailureRoundTripRetainsCanonicalOutcome() async throws {
        let fixture = makeStore(profile: "partial-round-trip")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try makeGroup(count: 3, seed: "partial")
        try await fixture.store.create(prepared)
        let results = try prepared.members.map { member in
            switch member.laneID.index {
            case 0:
                try OracleLaneResult(
                    laneIndex: 0,
                    chatID: member.publicChatID,
                    providerID: member.model.providerID,
                    modelID: member.model.modelID,
                    status: .completed,
                    response: "primary response"
                )
            case 1:
                try OracleLaneResult(
                    laneIndex: 1,
                    chatID: member.publicChatID,
                    providerID: member.model.providerID,
                    modelID: member.model.modelID,
                    status: .failed,
                    error: OracleLaneError(
                        code: "provider_error",
                        message: "provider failed",
                        partialResponse: "partial response"
                    )
                )
            default:
                try OracleLaneResult(
                    laneIndex: 2,
                    chatID: member.publicChatID,
                    providerID: member.model.providerID,
                    modelID: member.model.modelID,
                    status: .cancelled,
                    error: OracleLaneError(code: "cancelled", message: "cancelled")
                )
            }
        }
        let warning = OracleGroupWarning(code: "lane_failures", message: "Two lanes did not complete")
        let result = try OracleGroupResult(
            groupID: prepared.group.id,
            status: .partialFailure,
            oracleResults: results,
            warnings: [warning]
        )
        let terminal = try prepared.settling(result)
        try await fixture.store.save(terminal, expectedRevision: prepared.revision)

        let loadedDocument = try await fixture.store.load(
            groupID: prepared.group.id,
            owner: prepared.owner
        )
        let loaded = try XCTUnwrap(loadedDocument)
        let turn = try XCTUnwrap(loaded.turns.last)
        XCTAssertEqual(turn.status, .partialFailure)
        XCTAssertEqual(turn.warnings, [warning])
        XCTAssertEqual(turn.results, results)
    }

    func testPreparedAndTerminalOutcomeShapeValidation() async throws {
        let fixture = makeStore(profile: "outcome-validation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try makeGroup(count: 2, seed: "invalid-shapes")
        let sourceTurn = try XCTUnwrap(prepared.turns.last)
        let completedResults = try prepared.members.map { member in
            try OracleLaneResult(
                laneIndex: member.laneID.index,
                chatID: member.publicChatID,
                providerID: member.model.providerID,
                modelID: member.model.modelID,
                status: .completed,
                response: "response-\(member.laneID.index)"
            )
        }
        let warning = OracleGroupWarning(code: "lane_failures", message: "One lane did not complete")
        let invalidPreparedTurn = OracleTurnRecord(
            id: sourceTurn.id,
            input: sourceTurn.input,
            state: .prepared,
            startedAt: sourceTurn.startedAt,
            status: .partialFailure,
            warnings: [warning],
            results: completedResults
        )
        let invalidPrepared = try replacingLastTurn(in: prepared, with: invalidPreparedTurn)
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.create(invalidPrepared)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .invalidDocument("invalid_prepared_turn"))
        }

        try await fixture.store.create(prepared)
        let missingStatusTurn = OracleTurnRecord(
            id: sourceTurn.id,
            input: sourceTurn.input,
            state: .terminal,
            startedAt: sourceTurn.startedAt,
            finishedAt: sourceTurn.startedAt.addingTimeInterval(1),
            results: completedResults
        )
        let missingStatus = try replacingLastTurn(
            in: prepared,
            with: missingStatusTurn,
            revision: prepared.revision + 1
        )
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.save(missingStatus, expectedRevision: prepared.revision)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .invalidDocument("invalid_terminal_turn"))
        }

        var mismatchedResults = completedResults
        mismatchedResults[1] = try OracleLaneResult(
            laneIndex: 1,
            chatID: prepared.members[1].publicChatID,
            providerID: prepared.members[1].model.providerID,
            modelID: prepared.members[1].model.modelID,
            status: .failed,
            error: OracleLaneError(code: "provider_error", message: "failed")
        )
        let mismatchedTurn = OracleTurnRecord(
            id: sourceTurn.id,
            input: sourceTurn.input,
            state: .terminal,
            startedAt: sourceTurn.startedAt,
            finishedAt: sourceTurn.startedAt.addingTimeInterval(1),
            status: .completed,
            results: mismatchedResults
        )
        let mismatched = try replacingLastTurn(
            in: prepared,
            with: mismatchedTurn,
            revision: prepared.revision + 1
        )
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.save(mismatched, expectedRevision: prepared.revision)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .invalidDocument("invalid_terminal_outcome"))
        }
    }

    func testSchemaVersionOneGroupIsRejectedWithoutMigration() async throws {
        let fixture = makeStore(profile: "schema-version")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let current = try makeGroup(count: 2, seed: "schema")
        let versionOne = try OracleGroupDocument(
            schemaVersion: 1,
            group: current.group,
            owner: current.owner,
            name: current.name,
            revision: current.revision,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt,
            roster: current.roster,
            members: current.members,
            turns: current.turns
        )

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.create(versionOne)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .futureSchema(1))
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

    func testTerminalPublicationIntentRejectsPreparedAndWrongRevision() throws {
        let prepared = try makeGroup(count: 2, seed: "intent-validation")
        let terminal = try terminalDocument(from: prepared)

        XCTAssertThrowsError(
            try OracleTerminalPublicationIntent(
                terminal: prepared,
                expectedRevision: prepared.revision - 1
            )
        ) {
            XCTAssertEqual($0 as? OracleGroupContractError, .invalidTerminalPublicationIntent)
        }
        XCTAssertThrowsError(
            try OracleTerminalPublicationIntent(
                terminal: terminal,
                expectedRevision: prepared.revision + 1
            )
        ) {
            XCTAssertEqual($0 as? OracleGroupContractError, .invalidTerminalPublicationIntent)
        }
    }

    func testStagedTerminalPublicationColdRecoversExactOutcomeBeforePreparedRecovery() async throws {
        let fixture = makeStore(profile: "terminal-publication-cold-recovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try makeGroup(count: 2, seed: "terminal-publication-cold-recovery")
        try await fixture.store.create(prepared)
        let terminal = try terminalDocument(from: prepared)
        let intent = try OracleTerminalPublicationIntent(
            terminal: terminal,
            expectedRevision: prepared.revision
        )

        try await fixture.store.stageTerminalPublication(intent)

        let groupURL = fixture.persistence.oracleStorageRoot
            .appendingPathComponent("groups", isDirectory: true)
            .appendingPathComponent("\(prepared.group.id.rawValue.uuidString).json")
        let onDiskBeforeRecovery = try JSONDecoder().decode(
            OracleGroupDocument.self,
            from: Data(contentsOf: groupURL)
        )
        XCTAssertEqual(onDiskBeforeRecovery, prepared)
        let transactionsURL = fixture.persistence.oracleStorageRoot
            .appendingPathComponent("transactions", isDirectory: true)
        let pendingJournals = try FileManager.default.contentsOfDirectory(
            at: transactionsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(pendingJournals.count, 1)

        let coldStore = DomainOracleConversationStore(
            persistence: fixture.persistence,
            identity: makeIdentity()
        )
        let recoverable = try await coldStore.recoverPreparedGroups(owner: prepared.owner)
        XCTAssertFalse(recoverable.contains { $0.group.id == prepared.group.id })
        let recovered = try await coldStore.load(groupID: prepared.group.id, owner: prepared.owner)
        XCTAssertEqual(recovered, terminal)
    }

    func testTerminalPublicationJournalPersistedThrowStillColdRecoversExactOutcome() async throws {
        let fixture = makeStore(profile: "terminal-publication-observer-throw")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try makeGroup(count: 2, seed: "terminal-publication-observer-throw")
        try await fixture.store.create(prepared)
        let terminal = try terminalDocument(from: prepared)
        let intent = try OracleTerminalPublicationIntent(
            terminal: terminal,
            expectedRevision: prepared.revision
        )
        let interrupter = OneShotPersistenceInterrupter()
        let interruptedStore = DomainOracleConversationStore(
            persistence: fixture.persistence,
            identity: makeIdentity(),
            mutationObserver: { phase in try interrupter.observe(phase) }
        )

        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await interruptedStore.stageTerminalPublication(intent)
        } verify: { _ in }

        let coldStore = DomainOracleConversationStore(
            persistence: fixture.persistence,
            identity: makeIdentity()
        )
        let recovered = try await coldStore.load(groupID: prepared.group.id, owner: prepared.owner)
        XCTAssertEqual(recovered, terminal)
    }

    func testConflictingTerminalPublicationCannotReplaceCanonicalOutcome() async throws {
        let fixture = makeStore(profile: "terminal-publication-conflict")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try makeGroup(count: 2, seed: "terminal-publication-conflict")
        try await fixture.store.create(prepared)
        let canonical = try terminalDocument(from: prepared)
        let canonicalIntent = try OracleTerminalPublicationIntent(
            terminal: canonical,
            expectedRevision: prepared.revision
        )
        try await fixture.store.stageTerminalPublication(canonicalIntent)
        _ = try await fixture.store.reconcileTerminalPublication(canonicalIntent)

        let conflicting = try prepared.settling(
            try completedResult(for: prepared, responsePrefix: "conflicting"),
            finishedAt: prepared.updatedAt.addingTimeInterval(2)
        )
        let conflictingIntent = try OracleTerminalPublicationIntent(
            terminal: conflicting,
            expectedRevision: prepared.revision
        )
        await XCTAssertOraclePersistenceThrowsErrorAsync {
            try await fixture.store.stageTerminalPublication(conflictingIntent)
        } verify: {
            XCTAssertEqual($0 as? OraclePersistenceError, .terminalPublicationMismatch)
        }
        let persisted = try await fixture.store.load(groupID: prepared.group.id, owner: prepared.owner)
        XCTAssertEqual(persisted, canonical)
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
                timestamp: Date(timeIntervalSince1970: TimeInterval(1000 + index))
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

    func testArtifactReservationSurvivesFinalGroupReferenceDeletion() async throws {
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
    }

    func testDestructiveGroupOperationsRespectActiveClaim() async throws {
        let fixture = makeStore(profile: "claimed-deletion")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var group = try makeGroup(count: 2, seed: "claimed-deletion")
        try await fixture.store.create(group)
        group = try terminalDocument(from: group)
        try await fixture.store.save(group, expectedRevision: group.revision - 1)
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
            try await fixture.store.rename(
                groupID: group.group.id,
                owner: group.owner,
                name: "Claimed rename",
                expectedRevision: group.revision
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupClaimError, .conflict)
        }
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
        timestamp: Date = Date(timeIntervalSince1970: 1000)
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
        let turn = try OracleTurnRecord(
            input: OracleInput(mode: .chat, userMessage: "message-\(seed)", context: context),
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

    private func replacingLastTurn(
        in document: OracleGroupDocument,
        with turn: OracleTurnRecord,
        revision: UInt64? = nil
    ) throws -> OracleGroupDocument {
        try OracleGroupDocument(
            schemaVersion: document.schemaVersion,
            group: document.group,
            owner: document.owner,
            name: document.name,
            revision: revision ?? document.revision,
            createdAt: document.createdAt,
            updatedAt: turn.finishedAt ?? document.updatedAt,
            roster: document.roster,
            members: document.members,
            turns: Array(document.turns.dropLast()) + [turn]
        )
    }

    private func completedResult(
        for prepared: OracleGroupDocument,
        responsePrefix: String = "response"
    ) throws -> OracleGroupResult {
        let results = try prepared.members.map { member in
            try OracleLaneResult(
                laneIndex: member.laneID.index,
                chatID: member.publicChatID,
                providerID: member.model.providerID,
                modelID: member.model.modelID,
                status: .completed,
                response: "\(responsePrefix)-\(member.laneID.index)"
            )
        }
        return try OracleGroupResult(
            groupID: prepared.group.id,
            status: .completed,
            oracleResults: results
        )
    }

    private func terminalDocument(from prepared: OracleGroupDocument) throws -> OracleGroupDocument {
        let turn = try XCTUnwrap(prepared.turns.last)
        let results = try completedResult(for: prepared).oracleResults
        let terminal = OracleTurnRecord(
            id: turn.id,
            input: turn.input,
            state: .terminal,
            startedAt: turn.startedAt,
            finishedAt: turn.startedAt.addingTimeInterval(1),
            status: .completed,
            warnings: [],
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
}

private func XCTAssertOraclePersistenceThrowsErrorAsync(
    _ expression: () async throws -> some Any,
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
