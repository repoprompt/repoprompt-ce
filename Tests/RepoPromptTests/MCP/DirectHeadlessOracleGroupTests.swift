import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessOracleGroupTests: XCTestCase {
    func testTwoAndFiveOracleStartsUsePhysicalLaneCarriersAndReturnLaneOrder() async throws {
        let fixture = try Fixture(name: "ordering")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )

        for additional in [["lane-1"], ["lane-1", "lane-2", "lane-3", "lane-4"]] {
            _ = try await prepared.settingsStore.set(
                key: OracleRosterContract.primarySettingKey,
                value: .string("lane-0")
            )
            _ = try await prepared.settingsStore.set(
                key: OracleRosterContract.additionalSettingKey,
                value: .stringArray(additional)
            )
            let result = try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "ask_oracle",
                arguments: ["message": .string("ordered group")]
            )
            let lanes = try XCTUnwrap(result["oracle_results"] as? [[String: Any]])
            XCTAssertEqual(result["oracle_count"] as? Int, additional.count + 1)
            XCTAssertEqual(lanes.compactMap { $0["lane_index"] as? Int }, Array(0 ... additional.count))
            XCTAssertEqual(
                lanes.compactMap { $0["response"] as? String },
                (0 ... additional.count).map { "response-\($0)-lane-\($0)" }
            )
        }

        let calls = try fixture.calls()
        XCTAssertEqual(calls.count, 7)
        XCTAssertEqual(Set(calls.map(\.lane)), Set(0 ... 4))
        XCTAssertTrue(calls.allSatisfy { $0.groupID != nil && $0.claimID != nil && $0.launchID != nil })
    }

    func testGroupedResponseWhitespaceSurvivesMCPEncoding() async throws {
        let fixture = try Fixture(name: "exact-whitespace")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "exact", additional: ["lane-1"])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )

        let result = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("preserve exact output")]
        )
        XCTAssertEqual(result["response"] as? String, "  exact response  ")
        let lanes = try XCTUnwrap(result["oracle_results"] as? [[String: Any]])
        XCTAssertEqual(lanes[0]["response"] as? String, "  exact response  ")
    }

    func testSingleOracleUsesDirectConversationWithoutDurableGroup() async throws {
        let fixture = try Fixture(name: "single-direct")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )

        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("single turn")]
        )
        let chatID = try XCTUnwrap(started["chat_id"] as? String)
        XCTAssertEqual(started["response"] as? String, "response-0-default")

        let continued = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "oracle_send",
            arguments: [
                "chat_id": .string(chatID),
                "message": .string("follow-up")
            ]
        )
        XCTAssertEqual(continued["chat_id"] as? String, chatID)
        XCTAssertEqual(continued["response"] as? String, "response-0-default")

        let explicitStart = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "oracle_send",
            arguments: [
                "chat_id": .string(chatID),
                "new_chat": .bool(true),
                "model": .string("default"),
                "message": .string("start fresh")
            ]
        )
        XCTAssertNotEqual(explicitStart["chat_id"] as? String, chatID)
        XCTAssertEqual(explicitStart["response"] as? String, "response-0-default")

        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let stored = try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        XCTAssertNil(stored)

        let context = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "context_builder",
            arguments: ["instructions": .string("raw context instructions")]
        )
        XCTAssertEqual(context["response"] as? String, "response-0-default")
    }

    func testNamedDirectContinuationStaysSingleLaneAfterEnablingGroupedSettings() async throws {
        let fixture = try Fixture(name: "named-direct-grouped-settings")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )

        try await Self.setRoster(prepared, primary: "lane-0", additional: [])
        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("single direct turn")]
        )
        let chatID = try XCTUnwrap(started["chat_id"] as? String)
        XCTAssertNil(started["oracle_group_id"])

        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let continued = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "oracle_send",
            arguments: [
                "chat_id": .string(chatID),
                "message": .string("continue direct under grouped settings")
            ]
        )

        XCTAssertEqual(continued["chat_id"] as? String, chatID)
        XCTAssertNil(continued["oracle_group_id"])
        XCTAssertNil(continued["oracle_results"])
        XCTAssertEqual(try fixture.calls().map(\.lane), [0, 0])
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let stored = try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        XCTAssertNil(stored)
    }

    func testShutdownClearsPreparedDirectPlanWithoutChangingMissingPlanError() async throws {
        let fixture = try Fixture(name: "shutdown-direct-sentinel")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let arguments: [String: Value] = ["message": .string("direct turn")]
        let security = try await securityContext(prepared)
        let plan = try await prepared.oracleAdapter.resolveChildLaunchPlan(
            toolName: "ask_oracle",
            arguments: arguments,
            securityContext: security
        )

        await prepared.oracleAdapter.shutdown()
        do {
            _ = try await executePrepared(
                backend: backend,
                toolName: "ask_oracle",
                arguments: arguments,
                security: security,
                plan: plan
            )
            XCTFail("Expected the cleared plan to be missing")
        } catch {
            XCTAssertEqual(error as? DirectHeadlessOracleAdapter.AdapterError, .missingPreparedInvocation)
        }
    }

    func testDeletedContinuationAfterPlanningRetainsRosterConflictError() async throws {
        let fixture = try Fixture(name: "deleted-after-planning")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("first turn")]
        )
        let chatID = try XCTUnwrap(started["chat_id"] as? String)
        let groupID = try OracleGroupID(
            rawValue: XCTUnwrap(UUID(uuidString: XCTUnwrap(started["oracle_group_id"] as? String)))
        )
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let loadedGroup = try await prepared.oracleStore.load(groupID: groupID, owner: owner)
        let group = try XCTUnwrap(loadedGroup)
        let arguments: [String: Value] = [
            "chat_id": .string(chatID),
            "message": .string("second turn")
        ]
        let security = try await securityContext(prepared)
        let plan = try await prepared.oracleAdapter.resolveChildLaunchPlan(
            toolName: "oracle_send",
            arguments: arguments,
            securityContext: security
        )
        try await prepared.oracleStore.delete(
            groupID: groupID,
            owner: owner,
            expectedRevision: group.revision
        )

        do {
            _ = try await executePrepared(
                backend: backend,
                toolName: "oracle_send",
                arguments: arguments,
                security: security,
                plan: plan
            )
            XCTFail("Expected deleted continuation to fail")
        } catch {
            XCTAssertEqual(error as? DirectHeadlessOracleAdapter.AdapterError, .rosterConflict)
        }
    }

    func testMessageOnlyOracleSendUsesPrimaryDirectFallbackAndContinuesMostRecent() async throws {
        let fixture = try Fixture(name: "implicit-direct")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])

        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "oracle_send",
            arguments: ["message": .string("implicit first turn")]
        )
        let chatID = try XCTUnwrap(started["chat_id"] as? String)
        XCTAssertEqual(started["response"] as? String, "response-0-lane-0")
        XCTAssertNil(started["oracle_group_id"])
        XCTAssertEqual(try fixture.calls().map(\.lane), [0])

        let continued = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "oracle_send",
            arguments: ["message": .string("implicit second turn")]
        )
        XCTAssertEqual(continued["chat_id"] as? String, chatID)
        XCTAssertEqual(continued["response"] as? String, "response-0-lane-0")
        XCTAssertEqual(try fixture.calls().map(\.lane), [0, 0])

        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let stored = try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        XCTAssertNil(stored)
    }

    func testMessageOnlyOracleSendContinuesMostRecentCanonicalGroup() async throws {
        let fixture = try Fixture(name: "implicit-group")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])

        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("group first turn")]
        )
        let groupID = try XCTUnwrap(started["oracle_group_id"] as? String)
        let primaryChatID = try XCTUnwrap(started["chat_id"] as? String)

        let continued = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "oracle_send",
            arguments: ["message": .string("group second turn")]
        )
        XCTAssertEqual(continued["oracle_group_id"] as? String, groupID)
        XCTAssertEqual(continued["chat_id"] as? String, primaryChatID)
        XCTAssertEqual(continued["oracle_count"] as? Int, 2)
        XCTAssertEqual(try fixture.calls().map(\.lane).sorted(), [0, 0, 1, 1])

        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        guard case let .group(group)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            return XCTFail("Expected implicit continuation to retain the canonical group")
        }
        XCTAssertEqual(group.turns.count, 2)
        XCTAssertTrue(group.turns.allSatisfy { $0.state == .terminal })
    }

    func testLogAndMessageOnlySendChooseNewestDirectOrGroupConversation() async throws {
        let fixture = try Fixture(name: "latest-log")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        _ = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("group turn")]
        )
        try await Self.setRoster(prepared, primary: "default", additional: [])
        let direct = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("direct turn")]
        )
        let log = try await prepared.oracleAdapter.log(chatID: nil, limit: 8)
        XCTAssertEqual(try Self.object(log)["chat_id"] as? String, direct["chat_id"] as? String)

        let continuedDirect = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "oracle_send",
            arguments: ["message": .string("continue newest direct")]
        )
        XCTAssertEqual(continuedDirect["chat_id"] as? String, direct["chat_id"] as? String)
        XCTAssertNil(continuedDirect["oracle_group_id"])

        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let newestGroup = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("newest group turn")]
        )
        let continuedGroup = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "oracle_send",
            arguments: ["message": .string("continue newest group")]
        )
        XCTAssertEqual(continuedGroup["oracle_group_id"] as? String, newestGroup["oracle_group_id"] as? String)
        XCTAssertEqual(continuedGroup["chat_id"] as? String, newestGroup["chat_id"] as? String)
    }

    func testImplicitDirectContinuationFreezesConversationAcrossPlanningBarrier() async throws {
        let fixture = try Fixture(name: "implicit-direct-frozen")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "default", additional: [])
        let standardBackend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let first = try await invoke(
            prepared: prepared,
            backend: standardBackend,
            toolName: "ask_oracle",
            arguments: ["message": .string("first direct conversation")]
        )
        let firstID = try XCTUnwrap(first["chat_id"] as? String)

        let barrierStore = MostRecentConversationBarrierOracleStore(base: prepared.oracleStore)
        let barrierAdapter = try DirectHeadlessOracleAdapter(
            profileIdentifier: fixture.profileName,
            rosterResolver: DirectHeadlessOracleRosterResolver(settingsStore: prepared.settingsStore),
            store: barrierStore,
            claimManager: OracleGroupClaimManager(
                persistence: prepared.runtime.persistenceCoordinator,
                identity: prepared.runtime.identity
            ),
            provider: prepared.providerCoordinator
        )
        let barrierBackend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: barrierAdapter
        )
        let arguments: [String: Value] = ["message": .string("continue frozen direct conversation")]
        let security = try await securityContext(prepared)
        let planningTask = Task {
            try await barrierAdapter.resolveChildLaunchPlan(
                toolName: "oracle_send",
                arguments: arguments,
                securityContext: security
            )
        }
        await barrierStore.waitUntilBlocked()

        let newer: [String: Any]
        do {
            newer = try await invoke(
                prepared: prepared,
                backend: standardBackend,
                toolName: "ask_oracle",
                arguments: ["message": .string("newer direct conversation")]
            )
        } catch {
            await barrierStore.release()
            planningTask.cancel()
            throw error
        }
        let newerID = try XCTUnwrap(newer["chat_id"] as? String)
        XCTAssertNotEqual(newerID, firstID)

        await barrierStore.release()
        let plan = try await planningTask.value
        let continued = try await executePrepared(
            backend: barrierBackend,
            toolName: "oracle_send",
            arguments: arguments,
            security: security,
            plan: plan
        )
        XCTAssertEqual(continued["chat_id"] as? String, firstID)
        XCTAssertNotEqual(continued["chat_id"] as? String, newerID)
    }

    func testGroupContinuationThroughAdditionalMemberColdLoadsSiblingsAndLogsIdentity() async throws {
        let fixture = try Fixture(name: "continuation")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("first group turn")]
        )
        let firstLanes = try XCTUnwrap(started["oracle_results"] as? [[String: Any]])
        let primaryID = try XCTUnwrap(firstLanes[0]["chat_id"] as? String)
        let additionalID = try XCTUnwrap(firstLanes[1]["chat_id"] as? String)

        let coldService = fixture.service()
        let cold = try await coldService.prepareRuntime()
        addTeardownBlock { await coldService.teardown(cold) }
        let coldBackend = DirectHeadlessConversationBackend(
            providerCoordinator: cold.providerCoordinator,
            oracleAdapter: cold.oracleAdapter
        )
        let continued = try await invoke(
            prepared: cold,
            backend: coldBackend,
            toolName: "oracle_send",
            arguments: ["chat_id": .string(additionalID), "message": .string("second group turn")]
        )
        XCTAssertEqual(continued["chat_id"] as? String, primaryID)
        XCTAssertEqual(continued["oracle_count"] as? Int, 2)
        let continuedThroughPrimary = try await invoke(
            prepared: cold,
            backend: coldBackend,
            toolName: "oracle_send",
            arguments: ["chat_id": .string(primaryID), "message": .string("third group turn")]
        )
        XCTAssertEqual(continuedThroughPrimary["chat_id"] as? String, primaryID)

        for (index, chatID) in [primaryID, additionalID].enumerated() {
            let log = try await cold.oracleAdapter.log(chatID: chatID, limit: 8)
            let object = try Self.object(log)
            XCTAssertEqual(object["lane_index"] as? Int, index)
            XCTAssertEqual(object["oracle_count"] as? Int, 2)
            XCTAssertEqual(object["root_chat_id"] as? String, primaryID)
            XCTAssertNotNil(object["oracle_group_id"] as? String)
            XCTAssertEqual((object["messages"] as? [[String: Any]])?.count, 6)
        }
        let latest = try await cold.oracleAdapter.log(chatID: nil, limit: 8)
        XCTAssertEqual(try Self.object(latest)["chat_id"] as? String, primaryID)
    }

    func testGroupContinuationReloadsAfterClaimWhenPriorPublisherAdvancesRevision() async throws {
        let fixture = try Fixture(name: "continuation-post-claim-reload")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let store = MostRecentConversationBarrierOracleStore(base: prepared.oracleStore)
        let adapter = try DirectHeadlessOracleAdapter(
            profileIdentifier: fixture.profileName,
            rosterResolver: DirectHeadlessOracleRosterResolver(settingsStore: prepared.settingsStore),
            store: store,
            claimManager: OracleGroupClaimManager(
                persistence: prepared.runtime.persistenceCoordinator,
                identity: prepared.runtime.identity
            ),
            provider: prepared.providerCoordinator
        )
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: adapter
        )
        await prepared.childLaunchCoordinator.configure(
            runtime: prepared.runtime,
            endpointDescriptor: prepared.childEndpoint.socketURL.path,
            oracleAdapter: adapter
        )
        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            oracleAdapter: adapter,
            toolName: "ask_oracle",
            arguments: ["message": .string("initial group turn")]
        )
        let primaryChatID = try XCTUnwrap(started["chat_id"] as? String)

        await store.armGroupAdvanceOnNextLoad()
        let continued = try await invoke(
            prepared: prepared,
            backend: backend,
            oracleAdapter: adapter,
            toolName: "oracle_send",
            arguments: [
                "chat_id": .string(primaryChatID),
                "message": .string("continue from fresh claimed revision")
            ]
        )

        XCTAssertEqual(continued["status"] as? String, "completed")
        let advancedTerminalSnapshot = await store.advancedGroupTerminal()
        let advancedTerminal = try XCTUnwrap(advancedTerminalSnapshot)
        let persistedSnapshot = try await prepared.oracleStore.load(
            groupID: advancedTerminal.group.id,
            owner: advancedTerminal.owner
        )
        let persisted = try XCTUnwrap(persistedSnapshot)
        XCTAssertEqual(Array(persisted.turns.prefix(advancedTerminal.turns.count)), advancedTerminal.turns)
        XCTAssertEqual(persisted.turns.count, advancedTerminal.turns.count + 1)
        XCTAssertEqual(persisted.revision, advancedTerminal.revision + 2)
        XCTAssertEqual(try fixture.calls().count, 4)
    }

    func testGroupContinuationRejectsMismatchedCarrierBeforeHistoryMutation() async throws {
        let fixture = try Fixture(name: "continuation-carrier")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("first turn")]
        )
        let chatID = try XCTUnwrap(
            (started["oracle_results"] as? [[String: Any]])?.first?["chat_id"] as? String
        )
        let owner = try OracleConversationOwner(
            kind: "direct-headless",
            identifier: fixture.profileName
        )
        guard case let .group(before)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            return XCTFail("Expected a durable group")
        }

        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "oracle_send",
                arguments: ["chat_id": .string(chatID), "message": .string("second turn")],
                mismatchedBundle: true
            )
            XCTFail("Expected carrier mismatch")
        } catch {
            XCTAssertEqual(error as? DirectHeadlessOracleAdapter.AdapterError, .childCarrierMismatch)
        }
        let after = try await prepared.oracleStore.load(groupID: before.group.id, owner: owner)
        XCTAssertEqual(after?.revision, before.revision)
        XCTAssertEqual(after?.turns, before.turns)
    }

    func testPartialAndPrimaryFailuresRemainOrderedStructuredResults() async throws {
        let fixture = try Fixture(name: "failures")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )

        try await Self.setRoster(prepared, primary: "lane-0", additional: ["fail", "lane-2"])
        let partial = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("partial")]
        )
        XCTAssertEqual(partial["status"] as? String, "partial_failure")
        let partialLanes = try XCTUnwrap(partial["oracle_results"] as? [[String: Any]])
        XCTAssertEqual(partialLanes.compactMap { $0["lane_index"] as? Int }, [0, 1, 2])
        XCTAssertEqual(partialLanes[1]["status"] as? String, "failed")
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        guard case let .group(persistedPartial)? =
            try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        else {
            return XCTFail("missing persisted partial-failure group")
        }
        let persistedTurn = try XCTUnwrap(persistedPartial.turns.last)
        XCTAssertEqual(persistedTurn.status, .partialFailure)
        XCTAssertEqual(persistedTurn.warnings.map(\.code), ["lane_failures"])
        XCTAssertEqual(persistedTurn.results.map(\.status), [.completed, .failed, .completed])
        XCTAssertEqual(persistedTurn.results[0].response, "response-0-lane-0")
        XCTAssertEqual(persistedTurn.results[1].error?.code, "provider_error")
        XCTAssertEqual(persistedTurn.results[2].response, "response-2-lane-2")

        try await Self.setRoster(prepared, primary: "fail", additional: ["lane-1"])
        let failed = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("primary failure")]
        )
        XCTAssertEqual(failed["status"] as? String, "failed")
        XCTAssertNil(failed["response"] as? String)
    }

    func testTerminalReconciliationFailureRetriesCanonicalOutcomeWithoutSyntheticSettlement() async throws {
        let fixture = try Fixture(name: "terminal-save")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let store = TerminalPublicationFaultOracleStore(
            base: prepared.oracleStore,
            reconciliationFailuresBeforeDelegation: 1
        )
        let adapter = try DirectHeadlessOracleAdapter(
            profileIdentifier: fixture.profileName,
            rosterResolver: DirectHeadlessOracleRosterResolver(settingsStore: prepared.settingsStore),
            store: store,
            claimManager: OracleGroupClaimManager(
                persistence: prepared.runtime.persistenceCoordinator,
                identity: prepared.runtime.identity
            ),
            provider: prepared.providerCoordinator
        )
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: adapter
        )
        await prepared.childLaunchCoordinator.configure(
            runtime: prepared.runtime,
            endpointDescriptor: prepared.childEndpoint.socketURL.path,
            oracleAdapter: adapter
        )
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])

        let result = try await invoke(
            prepared: prepared,
            backend: backend,
            oracleAdapter: adapter,
            toolName: "ask_oracle",
            arguments: ["message": .string("terminal publication")]
        )
        XCTAssertEqual(result["status"] as? String, "completed")
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        guard case let .group(group)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        else {
            return XCTFail("missing persisted Oracle group")
        }
        let turn = try XCTUnwrap(group.turns.last)
        XCTAssertEqual(turn.state, .terminal)
        XCTAssertEqual(turn.results.map(\.status), [.completed, .completed])
        XCTAssertEqual(turn.results[0].response, "response-0-lane-0")
        XCTAssertEqual(turn.results[1].response, "response-1-lane-1")
        let forcedFailureCount = await store.forcedFailureCount()
        XCTAssertEqual(forcedFailureCount, 1)
    }

    func testTwoTerminalReconciliationFailuresRecoverExactOutcomeOnContinuation() async throws {
        let fixture = try Fixture(name: "terminal-two-failures")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let store = TerminalPublicationFaultOracleStore(
            base: prepared.oracleStore,
            reconciliationFailuresBeforeDelegation: 2
        )
        let adapter = try DirectHeadlessOracleAdapter(
            profileIdentifier: fixture.profileName,
            rosterResolver: DirectHeadlessOracleRosterResolver(settingsStore: prepared.settingsStore),
            store: store,
            claimManager: OracleGroupClaimManager(
                persistence: prepared.runtime.persistenceCoordinator,
                identity: prepared.runtime.identity
            ),
            provider: prepared.providerCoordinator
        )
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: adapter
        )
        await prepared.childLaunchCoordinator.configure(
            runtime: prepared.runtime,
            endpointDescriptor: prepared.childEndpoint.socketURL.path,
            oracleAdapter: adapter
        )
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])

        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                oracleAdapter: adapter,
                toolName: "ask_oracle",
                arguments: ["message": .string("terminal publication with two failures")]
            )
            XCTFail("Expected terminal reconciliation failure")
        } catch is ForcedTerminalPublicationError {
            // The exact terminal journal remains durable for the next store access.
        }
        XCTAssertEqual(try fixture.calls().count, 2)
        let forcedFailureCount = await store.forcedFailureCount()
        let reconciliationAttemptCount = await store.reconciliationAttemptCount()
        let stagedTerminal = await store.stagedTerminal()
        XCTAssertEqual(forcedFailureCount, 2)
        XCTAssertEqual(reconciliationAttemptCount, 2)
        let firstTerminal = try XCTUnwrap(stagedTerminal)
        XCTAssertEqual(firstTerminal.turns.count, 1)
        XCTAssertEqual(firstTerminal.turns[0].state, .terminal)
        XCTAssertEqual(firstTerminal.turns[0].results.map(\.status), [.completed, .completed])

        let continued = try await invoke(
            prepared: prepared,
            backend: backend,
            oracleAdapter: adapter,
            toolName: "oracle_send",
            arguments: [
                "chat_id": .string(firstTerminal.members[0].publicChatID),
                "message": .string("continue after publication recovery")
            ]
        )
        XCTAssertEqual(continued["status"] as? String, "completed")
        XCTAssertEqual(try fixture.calls().count, 4)

        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let recoveredSnapshot = try await prepared.oracleStore.load(
            groupID: firstTerminal.group.id,
            owner: owner
        )
        let recovered = try XCTUnwrap(recoveredSnapshot)
        XCTAssertEqual(recovered.turns.count, 2)
        XCTAssertEqual(recovered.turns[0], firstTerminal.turns[0])
        XCTAssertEqual(recovered.turns[0].results[0].response, "response-0-lane-0")
        XCTAssertEqual(recovered.turns[0].results[1].response, "response-1-lane-1")
        XCTAssertFalse(recovered.turns[0].results.contains { $0.error?.code == "interrupted" })
    }

    func testTerminalReconciliationCommitThenThrowReturnsAndPreservesExactOutcome() async throws {
        let fixture = try Fixture(name: "terminal-commit-throw")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let store = TerminalPublicationFaultOracleStore(
            base: prepared.oracleStore,
            committedThrowPoint: .reconcile
        )
        let adapter = try DirectHeadlessOracleAdapter(
            profileIdentifier: fixture.profileName,
            rosterResolver: DirectHeadlessOracleRosterResolver(settingsStore: prepared.settingsStore),
            store: store,
            claimManager: OracleGroupClaimManager(
                persistence: prepared.runtime.persistenceCoordinator,
                identity: prepared.runtime.identity
            ),
            provider: prepared.providerCoordinator
        )
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: adapter
        )
        await prepared.childLaunchCoordinator.configure(
            runtime: prepared.runtime,
            endpointDescriptor: prepared.childEndpoint.socketURL.path,
            oracleAdapter: adapter
        )
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])

        let result = try await invoke(
            prepared: prepared,
            backend: backend,
            oracleAdapter: adapter,
            toolName: "ask_oracle",
            arguments: ["message": .string("terminal commit then throw")]
        )
        XCTAssertEqual(result["status"] as? String, "completed")
        let forcedFailureCount = await store.forcedFailureCount()
        let reconciliationAttemptCount = await store.reconciliationAttemptCount()
        let stagedTerminal = await store.stagedTerminal()
        XCTAssertEqual(forcedFailureCount, 1)
        XCTAssertEqual(reconciliationAttemptCount, 2)
        let firstTerminal = try XCTUnwrap(stagedTerminal)
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let committedSnapshot = try await prepared.oracleStore.load(
            groupID: firstTerminal.group.id,
            owner: owner
        )
        let committed = try XCTUnwrap(committedSnapshot)
        XCTAssertEqual(committed, firstTerminal)
        XCTAssertEqual(committed.turns.count, 1)

        _ = try await invoke(
            prepared: prepared,
            backend: backend,
            oracleAdapter: adapter,
            toolName: "oracle_send",
            arguments: [
                "chat_id": .string(firstTerminal.members[0].publicChatID),
                "message": .string("continue after commit then throw")
            ]
        )
        let continuedSnapshot = try await prepared.oracleStore.load(
            groupID: firstTerminal.group.id,
            owner: owner
        )
        let continued = try XCTUnwrap(continuedSnapshot)
        XCTAssertEqual(continued.turns.count, 2)
        XCTAssertEqual(continued.turns[0], firstTerminal.turns[0])
        XCTAssertEqual(try fixture.calls().count, 4)
    }

    func testTerminalStageCommitThenPersistenceThrowReturnsExactOutcome() async throws {
        let fixture = try Fixture(name: "terminal-stage-commit-throw")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let store = TerminalPublicationFaultOracleStore(
            base: prepared.oracleStore,
            committedThrowPoint: .stage
        )
        let harness = try await makeFaultHarness(fixture: fixture, prepared: prepared, store: store)

        let result = try await invoke(
            prepared: prepared,
            backend: harness.backend,
            oracleAdapter: harness.adapter,
            toolName: "ask_oracle",
            arguments: ["message": .string("stage commits then throws persistence error")]
        )

        XCTAssertEqual(result["status"] as? String, "completed")
        let forcedFailureCount = await store.forcedFailureCount()
        let stageAttemptCount = await store.stageAttemptCount()
        let reconciliationAttemptCount = await store.reconciliationAttemptCount()
        let stagedTerminal = await store.stagedTerminal()
        XCTAssertEqual(forcedFailureCount, 1)
        XCTAssertEqual(stageAttemptCount, 1)
        XCTAssertEqual(reconciliationAttemptCount, 1)
        let terminal = try XCTUnwrap(stagedTerminal)
        let persisted = try await prepared.oracleStore.load(
            groupID: terminal.group.id,
            owner: terminal.owner
        )
        XCTAssertEqual(persisted, terminal)
    }

    func testFailedStageAndTransientReconcileRetrySameIntent() async throws {
        let fixture = try Fixture(name: "terminal-restage")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let store = TerminalPublicationFaultOracleStore(
            base: prepared.oracleStore,
            stageFailuresBeforeDelegation: 1,
            reconciliationFailuresBeforeDelegation: 1
        )
        let harness = try await makeFaultHarness(fixture: fixture, prepared: prepared, store: store)

        let result = try await invoke(
            prepared: prepared,
            backend: harness.backend,
            oracleAdapter: harness.adapter,
            toolName: "ask_oracle",
            arguments: ["message": .string("retry same terminal intent")]
        )

        XCTAssertEqual(result["status"] as? String, "completed")
        let stageAttemptCount = await store.stageAttemptCount()
        let reconciliationAttemptCount = await store.reconciliationAttemptCount()
        let forcedFailureCount = await store.forcedFailureCount()
        let stagedTerminal = await store.stagedTerminal()
        XCTAssertEqual(stageAttemptCount, 2)
        XCTAssertEqual(reconciliationAttemptCount, 2)
        XCTAssertEqual(forcedFailureCount, 2)
        let terminal = try XCTUnwrap(stagedTerminal)
        let persisted = try await prepared.oracleStore.load(
            groupID: terminal.group.id,
            owner: terminal.owner
        )
        XCTAssertEqual(persisted, terminal)
    }

    func testFailedRestagingPreservesUnderlyingErrorWhenNothingWasStaged() async throws {
        let fixture = try Fixture(name: "terminal-restage-fails")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let store = TerminalPublicationFaultOracleStore(
            base: prepared.oracleStore,
            stageFailuresBeforeDelegation: 2,
            reconciliationFailuresBeforeDelegation: 1
        )
        let harness = try await makeFaultHarness(fixture: fixture, prepared: prepared, store: store)

        do {
            _ = try await invoke(
                prepared: prepared,
                backend: harness.backend,
                oracleAdapter: harness.adapter,
                toolName: "ask_oracle",
                arguments: ["message": .string("no terminal intent staged")]
            )
            XCTFail("Expected the underlying staging error")
        } catch {
            XCTAssertEqual(error as? ForcedTerminalStagingError, ForcedTerminalStagingError(attempt: 2))
        }
        let stageAttemptCount = await store.stageAttemptCount()
        let reconciliationAttemptCount = await store.reconciliationAttemptCount()
        XCTAssertEqual(stageAttemptCount, 2)
        XCTAssertEqual(reconciliationAttemptCount, 2)
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        guard case let .group(group)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            return XCTFail("Expected the uncommitted group to remain prepared")
        }
        XCTAssertEqual(group.turns.last?.state, .prepared)
        XCTAssertEqual(try fixture.calls().count, 2)
    }

    func testRosterConflictAndRawContextBuilderGateFailBeforeProviderDispatch() async throws {
        let fixture = try Fixture(name: "gates")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )

        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "context_builder",
                arguments: ["instructions": .string("raw instructions")]
            )
            XCTFail("Expected context_pack_required")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("context_pack_required"), error.localizedDescription)
        }
        XCTAssertEqual(try fixture.calls().count, 0)

        _ = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("start")]
        )
        let callCount = try fixture.calls().count
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.additionalSettingKey,
            value: .stringArray(["changed"])
        )
        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "oracle_send",
                arguments: ["message": .string("implicit conflict")]
            )
            XCTFail("Expected roster conflict")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("new_chat=true"), error.localizedDescription)
        }
        XCTAssertEqual(try fixture.calls().count, callCount)
    }

    func testThreeOracleContextBuilderUsesOnePersistedCanonicalFrozenPack() async throws {
        let fixture = try Fixture(name: "frozen-context")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1", "lane-2"])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let pack = try OracleFrozenContextPack(
            mode: .review,
            content: "byte-identical frozen review package",
            provenance: [OracleEvidenceReference(path: "Sources/Feature.swift")]
        )
        let data = try pack.canonicalData()
        let artifactID = try await prepared.oracleStore.storeArtifact(data)
        let reference = try OracleFrozenPackReference(artifactID: artifactID)

        let result = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "context_builder",
            arguments: [
                "context_pack_ref": .string(reference.rawValue),
                "response_type": .string("review")
            ]
        )

        XCTAssertEqual(result["oracle_count"] as? Int, 3)
        XCTAssertEqual(try XCTUnwrap(result["oracle_results"] as? [[String: Any]]).count, 3)
        let persistedData = try await prepared.oracleStore.loadArtifact(id: artifactID)
        XCTAssertEqual(persistedData, data)
        XCTAssertEqual(try fixture.calls().map(\.lane).sorted(), [0, 1, 2])
    }

    func testParentCancellationDrainsAllPhysicalLaneProcesses() async throws {
        let fixture = try Fixture(name: "cancellation")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "cancel-0", additional: ["cancel-1"])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let task = Task {
            try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "ask_oracle",
                arguments: ["message": .string("cancel me")]
            )
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while try (fixture.calls().count) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pids = try fixture.calls().map(\.processID)
        XCTAssertEqual(pids.count, 2)
        let owner = try OracleConversationOwner(
            kind: "direct-headless",
            identifier: fixture.profileName
        )
        guard case let .group(preparedGroup)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            task.cancel()
            return XCTFail("Expected an active prepared Oracle group")
        }
        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "oracle_send",
                arguments: [
                    "chat_id": .string(preparedGroup.members[1].publicChatID),
                    "message": .string("must not overwrite the active turn")
                ]
            )
            XCTFail("Expected the live group claim to reject the continuation")
        } catch {
            XCTAssertEqual(error as? OracleGroupClaimError, .conflict)
        }
        let stillPrepared = try await prepared.oracleStore.load(
            groupID: preparedGroup.group.id,
            owner: owner
        )
        XCTAssertEqual(stillPrepared?.revision, preparedGroup.revision)
        XCTAssertEqual(stillPrepared?.turns.last?.state, .prepared)
        task.cancel()
        let cancelled = try await task.value
        XCTAssertEqual(cancelled["status"] as? String, "failed")
        let cancelledLanes = try XCTUnwrap(cancelled["oracle_results"] as? [[String: Any]])
        XCTAssertEqual(cancelledLanes.compactMap { $0["status"] as? String }, ["cancelled", "cancelled"])
        for pid in pids {
            XCTAssertEqual(kill(pid, 0), -1, "provider process still alive: \(pid)")
            XCTAssertEqual(errno, ESRCH)
        }
        guard case let .group(group)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            return XCTFail("Expected the cancelled Oracle group to remain durable")
        }
        XCTAssertEqual(group.turns.last?.state, .terminal)
        XCTAssertEqual(group.turns.last?.results.map(\.status), [.cancelled, .cancelled])
    }

    private func makeFaultHarness(
        fixture: Fixture,
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        store: TerminalPublicationFaultOracleStore
    ) async throws -> (
        adapter: DirectHeadlessOracleAdapter,
        backend: DirectHeadlessConversationBackend
    ) {
        let adapter = try DirectHeadlessOracleAdapter(
            profileIdentifier: fixture.profileName,
            rosterResolver: DirectHeadlessOracleRosterResolver(settingsStore: prepared.settingsStore),
            store: store,
            claimManager: OracleGroupClaimManager(
                persistence: prepared.runtime.persistenceCoordinator,
                identity: prepared.runtime.identity
            ),
            provider: prepared.providerCoordinator
        )
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: adapter
        )
        await prepared.childLaunchCoordinator.configure(
            runtime: prepared.runtime,
            endpointDescriptor: prepared.childEndpoint.socketURL.path,
            oracleAdapter: adapter
        )
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        return (adapter, backend)
    }

    private static func setRoster(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        primary: String,
        additional: [String]
    ) async throws {
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.primarySettingKey,
            value: .string(primary)
        )
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.additionalSettingKey,
            value: .stringArray(additional)
        )
    }

    private func invoke(
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        backend: DirectHeadlessConversationBackend,
        oracleAdapter: DirectHeadlessOracleAdapter? = nil,
        toolName: String,
        arguments: [String: Value],
        mismatchedBundle: Bool = false
    ) async throws -> [String: Any] {
        let security = try await securityContext(prepared)
        let plan = try await (oracleAdapter ?? prepared.oracleAdapter).resolveChildLaunchPlan(
            toolName: toolName,
            arguments: arguments,
            securityContext: security
        )
        return try await executePrepared(
            backend: backend,
            toolName: toolName,
            arguments: arguments,
            security: security,
            plan: plan,
            mismatchedBundle: mismatchedBundle
        )
    }

    private func executePrepared(
        backend: DirectHeadlessConversationBackend,
        toolName: String,
        arguments: [String: Value],
        security: DomainToolInvocationSecurityContext,
        plan: DomainChildLaunchPlan,
        mismatchedBundle: Bool = false
    ) async throws -> [String: Any] {
        let bundlePlan = if mismatchedBundle {
            try DomainChildLaunchPlan(
                runID: plan.runID,
                oracleGroupID: plan.oracleGroupID,
                oracleGroupClaimID: plan.oracleGroupClaimID,
                lanes: plan.lanes.map {
                    DomainChildLaunchLanePlan(
                        providerIdentifier: $0.providerIdentifier,
                        oracleLaneID: $0.oracleLaneID
                    )
                }
            )
        } else {
            plan
        }
        let carriers = bundlePlan.lanes.map { lane in
            var environment: [String: String] = [
                DomainChildLaunchCarrier.runIDEnvironmentKey: bundlePlan.runID.uuidString,
                DomainChildLaunchCarrier.launchIDEnvironmentKey: lane.launchID.uuidString,
                DomainChildLaunchCarrier.providerIdentifierEnvironmentKey: lane.providerIdentifier
            ]
            if let groupID = bundlePlan.oracleGroupID {
                environment[DomainChildLaunchCarrier.oracleGroupIDEnvironmentKey] = groupID.rawValue.uuidString
            }
            if let laneID = lane.oracleLaneID {
                environment[DomainChildLaunchCarrier.oracleLaneIDEnvironmentKey] = "\(laneID.index)"
            }
            if let claimID = bundlePlan.oracleGroupClaimID {
                environment[DomainChildLaunchCarrier.oracleGroupClaimIDEnvironmentKey] = claimID.uuidString
            }
            return DomainChildLaunchCarrier(
                runID: bundlePlan.runID,
                launchID: lane.launchID,
                providerIdentifier: lane.providerIdentifier,
                oracleGroupID: bundlePlan.oracleGroupID,
                oracleLaneID: lane.oracleLaneID,
                oracleGroupClaimID: bundlePlan.oracleGroupClaimID,
                launchTokenID: UUID(),
                credentialEnvelope: nil,
                environment: environment
            )
        }
        let bundle = try DomainChildLaunchCarrierBundle(plan: bundlePlan, carriers: carriers)
        let request = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(arguments),
            securityContext: security
        )
        let result = try await DomainChildLaunchContext.$bundle.withValue(bundle) {
            try await DomainChildLaunchContext.$current.withValue(bundle.singleCarrier) {
                switch toolName {
                case "ask_oracle":
                    try await backend.startOracleConversation(request)
                case "oracle_send":
                    try await backend.continueOracleConversation(request)
                case "context_builder":
                    try await backend.buildContext(request)
                default:
                    throw MCPError.invalidParams("unsupported test tool")
                }
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
    }

    private func securityContext(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> DomainToolInvocationSecurityContext {
        let snapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        return DomainToolInvocationSecurityContext(
            principal: prepared.principal,
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: snapshot.identity.workspaceID,
            workspaceRevision: snapshot.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(snapshot.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: [],
            ephemeralGrantedOperations: []
        )
    }

    private static func object(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor MostRecentConversationBarrierOracleStore: DirectHeadlessOracleStore {
    private let base: DomainOracleConversationStore
    private var didBlock = false
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var advancesNextGroupLoad = false
    private var advancedTerminal: OracleGroupDocument?

    init(base: DomainOracleConversationStore) {
        self.base = base
    }

    func waitUntilBlocked() async {
        while !isBlocked {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isBlocked = false
    }

    func armGroupAdvanceOnNextLoad() {
        advancesNextGroupLoad = true
    }

    func advancedGroupTerminal() -> OracleGroupDocument? {
        advancedTerminal
    }

    func create(_ group: OracleGroupDocument) async throws {
        try await base.create(group)
    }

    func load(
        member: OracleMemberLookup,
        owner: OracleConversationOwner
    ) async throws -> OracleGroupDocument? {
        try await base.load(member: member, owner: owner)
    }

    func load(
        groupID: OracleGroupID,
        owner: OracleConversationOwner
    ) async throws -> OracleGroupDocument? {
        let observed = try await base.load(groupID: groupID, owner: owner)
        guard advancesNextGroupLoad,
              let observed,
              observed.turns.last?.state == .terminal
        else {
            return observed
        }
        advancesNextGroupLoad = false
        let now = Date()
        let prepared = try OracleGroupDocument(
            schemaVersion: observed.schemaVersion,
            group: observed.group,
            owner: observed.owner,
            name: observed.name,
            revision: observed.revision &+ 1,
            createdAt: observed.createdAt,
            updatedAt: now,
            roster: observed.roster,
            members: observed.members,
            turns: observed.turns + [OracleTurnRecord(
                input: OracleInput(mode: .chat, userMessage: "prior publisher turn"),
                state: .prepared,
                startedAt: now
            )]
        )
        try await base.save(prepared, expectedRevision: observed.revision)
        let terminal = try prepared.settlingInterrupted(
            status: .failed,
            code: "prior_publication",
            message: "Prior publisher committed before claim acquisition."
        )
        let intent = try OracleTerminalPublicationIntent(
            terminal: terminal,
            expectedRevision: prepared.revision
        )
        try await base.stageTerminalPublication(intent)
        _ = try await base.reconcileTerminalPublication(intent)
        advancedTerminal = terminal
        return observed
    }

    func loadMostRecentConversation(owner: OracleConversationOwner) async throws -> OracleStoredConversation? {
        if !didBlock {
            didBlock = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isBlocked = true
            }
        }
        return try await base.loadMostRecentConversation(owner: owner)
    }

    func save(_ group: OracleGroupDocument, expectedRevision: UInt64) async throws {
        try await base.save(group, expectedRevision: expectedRevision)
    }

    func stageTerminalPublication(_ intent: OracleTerminalPublicationIntent) async throws {
        try await base.stageTerminalPublication(intent)
    }

    func reconcileTerminalPublication(
        _ intent: OracleTerminalPublicationIntent
    ) async throws -> OracleGroupDocument {
        try await base.reconcileTerminalPublication(intent)
    }

    func rename(
        groupID: OracleGroupID,
        owner: OracleConversationOwner,
        name: String,
        expectedRevision: UInt64
    ) async throws {
        try await base.rename(groupID: groupID, owner: owner, name: name, expectedRevision: expectedRevision)
    }

    func delete(
        groupID: OracleGroupID,
        owner: OracleConversationOwner,
        expectedRevision: UInt64
    ) async throws {
        try await base.delete(groupID: groupID, owner: owner, expectedRevision: expectedRevision)
    }

    func retainMostRecentGroups(
        _ maximumCount: Int,
        owner: OracleConversationOwner
    ) async throws -> [OracleGroupID] {
        try await base.retainMostRecentGroups(maximumCount, owner: owner)
    }

    func recoverPreparedGroups(owner: OracleConversationOwner) async throws -> [OracleGroupDocument] {
        try await base.recoverPreparedGroups(owner: owner)
    }

    func storeArtifact(_ data: Data) async throws -> String {
        try await base.storeArtifact(data)
    }

    func loadArtifact(id: String) async throws -> Data {
        try await base.loadArtifact(id: id)
    }
}

private enum TerminalPublicationCommittedThrowPoint {
    case none
    case stage
    case reconcile
}

private actor TerminalPublicationFaultOracleStore: DirectHeadlessOracleStore {
    private let base: DomainOracleConversationStore
    private let stageFailuresBeforeDelegation: Int
    private let reconciliationFailuresBeforeDelegation: Int
    private let committedThrowPoint: TerminalPublicationCommittedThrowPoint
    private var stageAttempts = 0
    private var reconciliationAttempts = 0
    private var forcedFailures = 0
    private var stagedIntent: OracleTerminalPublicationIntent?

    init(
        base: DomainOracleConversationStore,
        stageFailuresBeforeDelegation: Int = 0,
        reconciliationFailuresBeforeDelegation: Int = 0,
        committedThrowPoint: TerminalPublicationCommittedThrowPoint = .none
    ) {
        self.base = base
        self.stageFailuresBeforeDelegation = stageFailuresBeforeDelegation
        self.reconciliationFailuresBeforeDelegation = reconciliationFailuresBeforeDelegation
        self.committedThrowPoint = committedThrowPoint
    }

    func create(_ group: OracleGroupDocument) async throws {
        try await base.create(group)
    }

    func load(
        member: OracleMemberLookup,
        owner: OracleConversationOwner
    ) async throws -> OracleGroupDocument? {
        try await base.load(member: member, owner: owner)
    }

    func load(
        groupID: OracleGroupID,
        owner: OracleConversationOwner
    ) async throws -> OracleGroupDocument? {
        try await base.load(groupID: groupID, owner: owner)
    }

    func loadMostRecentConversation(owner: OracleConversationOwner) async throws -> OracleStoredConversation? {
        try await base.loadMostRecentConversation(owner: owner)
    }

    func save(_ group: OracleGroupDocument, expectedRevision: UInt64) async throws {
        try await base.save(group, expectedRevision: expectedRevision)
    }

    func stageTerminalPublication(_ intent: OracleTerminalPublicationIntent) async throws {
        stageAttempts += 1
        stagedIntent = intent
        if stageAttempts <= stageFailuresBeforeDelegation {
            forcedFailures += 1
            throw ForcedTerminalStagingError(attempt: stageAttempts)
        }
        try await base.stageTerminalPublication(intent)
        if committedThrowPoint == .stage, stageAttempts == 1 {
            _ = try await base.reconcileTerminalPublication(intent)
            forcedFailures += 1
            throw OraclePersistenceError.invalidDocument("stage_committed_then_threw")
        }
    }

    func reconcileTerminalPublication(
        _ intent: OracleTerminalPublicationIntent
    ) async throws -> OracleGroupDocument {
        reconciliationAttempts += 1
        if reconciliationAttempts <= reconciliationFailuresBeforeDelegation {
            forcedFailures += 1
            throw ForcedTerminalPublicationError()
        }
        if committedThrowPoint == .reconcile, reconciliationAttempts == 1 {
            _ = try await base.reconcileTerminalPublication(intent)
            forcedFailures += 1
            throw OraclePersistenceError.invalidDocument("reconcile_committed_then_threw")
        }
        return try await base.reconcileTerminalPublication(intent)
    }

    func rename(
        groupID: OracleGroupID,
        owner: OracleConversationOwner,
        name: String,
        expectedRevision: UInt64
    ) async throws {
        try await base.rename(
            groupID: groupID,
            owner: owner,
            name: name,
            expectedRevision: expectedRevision
        )
    }

    func delete(
        groupID: OracleGroupID,
        owner: OracleConversationOwner,
        expectedRevision: UInt64
    ) async throws {
        try await base.delete(groupID: groupID, owner: owner, expectedRevision: expectedRevision)
    }

    func retainMostRecentGroups(
        _ maximumCount: Int,
        owner: OracleConversationOwner
    ) async throws -> [OracleGroupID] {
        try await base.retainMostRecentGroups(maximumCount, owner: owner)
    }

    func recoverPreparedGroups(owner: OracleConversationOwner) async throws -> [OracleGroupDocument] {
        try await base.recoverPreparedGroups(owner: owner)
    }

    func storeArtifact(_ data: Data) async throws -> String {
        try await base.storeArtifact(data)
    }

    func loadArtifact(id: String) async throws -> Data {
        try await base.loadArtifact(id: id)
    }

    func forcedFailureCount() -> Int {
        forcedFailures
    }

    func stageAttemptCount() -> Int {
        stageAttempts
    }

    func reconciliationAttemptCount() -> Int {
        reconciliationAttempts
    }

    func stagedTerminal() -> OracleGroupDocument? {
        stagedIntent?.terminal
    }
}

private struct ForcedTerminalPublicationError: Error {}

private struct ForcedTerminalStagingError: Error, Equatable {
    let attempt: Int
}

private struct Fixture {
    struct Call {
        let lane: Int
        let model: String
        let processID: Int32
        let launchID: String?
        let groupID: String?
        let claimID: String?
    }

    let root: URL
    let profile: URL
    let executable: URL
    let callLog: URL
    let profileName: String

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-oracle-root-\(name)-\(UUID().uuidString)", isDirectory: true)
        profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-oracle-profile-\(name)-\(UUID().uuidString)", isDirectory: true)
        executable = profile.appendingPathComponent("codex-stub")
        callLog = profile.appendingPathComponent("calls.log")
        profileName = "oracle-\(name)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        model=default
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--model" ]; then
            shift
            model="$1"
          fi
          shift
        done
        lane="${REPOPROMPT_MCP_ORACLE_LANE_ID:-0}"
        /usr/bin/printf '%s|%s|%s|%s|%s|%s\\n' "$lane" "$model" "$$" \
          "${REPOPROMPT_MCP_LAUNCH_ID:-}" "${REPOPROMPT_MCP_ORACLE_GROUP_ID:-}" \
          "${REPOPROMPT_MCP_ORACLE_GROUP_CLAIM_ID:-}" >> '\(callLog.path)'
        /bin/cat >/dev/null
        case "$model" in
          cancel-*) trap 'exit 0' TERM INT; /bin/sleep 30 ;;
          fail) /usr/bin/printf '%s\\n' 'fake provider failure' >&2; exit 7 ;;
          exact) /usr/bin/printf '%s\\n' '{"type":"message","text":"  exact response  "}'; exit 0 ;;
        esac
        case "$lane" in
          0) /bin/sleep 0.15 ;;
          1) /bin/sleep 0.10 ;;
          2) /bin/sleep 0.06 ;;
          3) /bin/sleep 0.03 ;;
        esac
        /usr/bin/printf '{"type":"message","text":"response-%s-%s"}\\n' "$lane" "$model"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func service() -> DirectHeadlessMCPService {
        DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_CODEX_COMMAND": executable.path,
                "REPOPROMPT_MCP_HEADLESS_PROFILE": profileName,
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": root.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: root
        )
    }

    func calls() throws -> [Call] {
        guard FileManager.default.fileExists(atPath: callLog.path) else { return [] }
        return try String(contentsOf: callLog, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return Call(
                    lane: Int(fields[0]) ?? -1,
                    model: fields[1],
                    processID: Int32(fields[2]) ?? -1,
                    launchID: fields[3].isEmpty ? nil : fields[3],
                    groupID: fields[4].isEmpty ? nil : fields[4],
                    claimID: fields[5].isEmpty ? nil : fields[5]
                )
            }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: profile)
    }
}
