import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessOracleGroupTests: XCTestCase {
    func testSingleOracleUsesConfiguredPrimaryFlatShapeOneCallPerTurnAndColdContinuation() async throws {
        let fixture = try Fixture(name: "single")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.primarySettingKey,
            value: .string("configured-primary")
        )
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )

        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("first question")]
        )
        XCTAssertEqual(Set(started.keys), ["backend", "chat_id", "response"])
        XCTAssertEqual(started["backend"] as? String, "headless")
        XCTAssertEqual(started["response"] as? String, "response-0-configured-primary")
        let chatID = try XCTUnwrap(started["chat_id"] as? String)
        XCTAssertEqual(try fixture.calls().map(\.model), ["configured-primary"])

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
            arguments: ["chat_id": .string(chatID), "message": .string("second question")]
        )
        XCTAssertEqual(Set(continued.keys), ["backend", "chat_id", "response"])
        XCTAssertEqual(continued["chat_id"] as? String, chatID)
        XCTAssertEqual(try fixture.calls().map(\.model), ["configured-primary", "configured-primary"])

        let log = try await cold.oracleAdapter.log(chatID: chatID, limit: 8)
        let logObject = try Self.object(log)
        let messages = try XCTUnwrap(logObject["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(messages.compactMap { $0["text"] as? String }.first, "first question")
    }

    func testSuccessfulProviderResponseIsNotSettledFailedWhenTerminalSaveThrows() async throws {
        let fixture = try Fixture(name: "persist-after-success")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "configured-primary", additional: [])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let task = Task {
            try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "ask_oracle",
                arguments: ["message": .string("keep provider success")]
            )
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while try fixture.calls().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(try fixture.calls().isEmpty, "Expected the provider to run before the terminal save")
        await prepared.oracleStore.failNextSaves(1)
        do {
            _ = try await task.value
            XCTFail("Expected the terminal save to fail")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("debug_forced_save_failure"),
                String(describing: error)
            )
        }
        let owner = try OracleConversationOwner(
            kind: "direct-headless",
            identifier: fixture.profileName
        )
        guard case let .single(conversation)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            return XCTFail("Expected the prepared conversation to remain durable")
        }
        XCTAssertEqual(conversation.turns.last?.state, .prepared)
        XCTAssertEqual(conversation.turns.last?.results ?? [], [])
    }

    func testConcurrentSingleContinuationCannotOverwriteActivePreparedTurn() async throws {
        let fixture = try Fixture(name: "single-claim")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "cancel-0", additional: [])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let task = Task {
            try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "ask_oracle",
                arguments: ["message": .string("active single")]
            )
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while try fixture.calls().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let owner = try OracleConversationOwner(
            kind: "direct-headless",
            identifier: fixture.profileName
        )
        guard case let .single(single)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            task.cancel()
            return XCTFail("Expected an active prepared single conversation")
        }
        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "oracle_send",
                arguments: [
                    "chat_id": .string(single.publicChatID),
                    "message": .string("must be rejected")
                ]
            )
            XCTFail("Expected the live single claim to reject the continuation")
        } catch {
            XCTAssertEqual(error as? OracleGroupClaimError, .conflict)
        }
        let stillPrepared = try await prepared.oracleStore.load(
            publicChatID: single.publicChatID,
            owner: owner
        )
        XCTAssertEqual(stillPrepared?.revision, single.revision)
        XCTAssertEqual(stillPrepared?.turns.last?.state, .prepared)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected structural cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let terminal = try await prepared.oracleStore.load(
            publicChatID: single.publicChatID,
            owner: owner
        )
        XCTAssertEqual(terminal?.turns.last?.state, .terminal)
        XCTAssertEqual(terminal?.turns.last?.results.first?.status, .cancelled)
    }

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

    func testSingleStartRejectsMismatchedCarrierBeforeProviderDispatch() async throws {
        let fixture = try Fixture(name: "single-carrier")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: [])
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )

        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                toolName: "ask_oracle",
                arguments: ["message": .string("single turn")],
                mismatchedBundle: true
            )
            XCTFail("Expected carrier mismatch")
        } catch {
            XCTAssertEqual(error as? DirectHeadlessOracleAdapter.AdapterError, .childCarrierMismatch)
        }
        let owner = try OracleConversationOwner(
            kind: "direct-headless",
            identifier: fixture.profileName
        )
        let conversation = try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        XCTAssertNil(conversation)
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

        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.additionalSettingKey,
            value: .stringArray([])
        )
        let singleContext = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "context_builder",
            arguments: ["instructions": .string("raw single instructions")]
        )
        XCTAssertEqual(Set(singleContext.keys), ["backend", "chat_id", "response"])
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.additionalSettingKey,
            value: .stringArray(["lane-1"])
        )

        let started = try await invoke(
            prepared: prepared,
            backend: backend,
            toolName: "ask_oracle",
            arguments: ["message": .string("start")]
        )
        let chatID = try XCTUnwrap(started["chat_id"] as? String)
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
                arguments: ["chat_id": .string(chatID), "message": .string("conflict")]
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
        do {
            _ = try await task.value
            XCTFail("Expected structural cancellation")
        } catch is CancellationError {
            // Expected after the group coordinator drains both lanes.
        }
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
        toolName: String,
        arguments: [String: Value],
        mismatchedBundle: Bool = false
    ) async throws -> [String: Any] {
        let security = try await securityContext(prepared)
        let plan = try await prepared.oracleAdapter.resolveChildLaunchPlan(
            toolName: toolName,
            arguments: arguments,
            securityContext: security
        )
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
