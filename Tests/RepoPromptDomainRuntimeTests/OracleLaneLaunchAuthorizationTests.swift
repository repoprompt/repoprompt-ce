import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class OracleLaneLaunchAuthorizationTests: XCTestCase {
    func testFiveLanePlanInstallsBundleAndRevokesAfterExecution() async throws {
        let runtime = makeRuntime(mode: .app, profile: "bundle")
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let groupID = OracleGroupID()
        let claimID = UUID()
        let runID = UUID()
        let lanes = try (0 ..< 5).map {
            DomainChildLaunchLanePlan(
                providerIdentifier: "provider-\($0)",
                oracleLaneID: try OracleLaneID(index: $0)
            )
        }
        let plan = try DomainChildLaunchPlan(
            runID: runID,
            oracleGroupID: groupID,
            oracleGroupClaimID: claimID,
            lanes: lanes,
            approvalMetadata: ["estimated_cost": "full-roster"]
        )
        let wrongProviderCarriers = plan.lanes.map { lane in
            DomainChildLaunchCarrier(
                runID: plan.runID,
                launchID: lane.launchID,
                providerIdentifier: lane.oracleLaneID?.index == 2 ? "wrong-provider" : lane.providerIdentifier,
                oracleGroupID: plan.oracleGroupID,
                oracleLaneID: lane.oracleLaneID,
                oracleGroupClaimID: plan.oracleGroupClaimID,
                launchTokenID: UUID(),
                credentialEnvelope: nil,
                environment: [:]
            )
        }
        XCTAssertThrowsError(
            try DomainChildLaunchCarrierBundle(plan: plan, carriers: wrongProviderCarriers)
        ) { error in
            XCTAssertEqual(error as? DomainChildLaunchPlanError, .carrierMismatch)
        }
        let recorder = LaunchRecorder()
        let provider = MCPDomainLongRunningToolProvider(
            identity: runtime.identity,
            policyStore: runtime.mutationPolicyStore,
            interactionBroker: runtime.interactionBroker,
            activityCenter: runtime.activityCenter,
            resolveChildLaunchPlan: { _, _, _ in plan },
            prepareChildLaunches: { preparedPlan, _, _, _ in
                await recorder.record("prepared:\(preparedPlan.approvalMetadata["lane_count"] ?? "missing")")
                let carriers = preparedPlan.lanes.map { lane in
                    DomainChildLaunchCarrier(
                        runID: preparedPlan.runID,
                        launchID: lane.launchID,
                        providerIdentifier: lane.providerIdentifier,
                        oracleGroupID: preparedPlan.oracleGroupID,
                        oracleLaneID: lane.oracleLaneID,
                        oracleGroupClaimID: preparedPlan.oracleGroupClaimID,
                        launchTokenID: UUID(),
                        credentialEnvelope: nil,
                        environment: [:]
                    )
                }
                return try DomainChildLaunchCarrierBundle(plan: preparedPlan, carriers: carriers)
            },
            revokeChildLaunches: { _, bundle in
                await recorder.record("revoked:\(bundle?.carriers.count ?? 0)")
            }
        )
        let binding = MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: "ask_oracle",
                description: "group fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            XCTAssertNil(DomainChildLaunchContext.current)
            let installed = try XCTUnwrap(DomainChildLaunchContext.bundle)
            XCTAssertEqual(installed.carriers.count, 5)
            XCTAssertEqual(installed.carriers.map(\.oracleLaneID?.index), [0, 1, 2, 3, 4])
            XCTAssertEqual(installed.carriers.map(\.launchID), lanes.map(\.launchID))
            await recorder.record("executed")
            return .string("ok")
        }
        let security = makeSecurityContext(identity: runtime.identity, toolName: "ask_oracle")
        let value = try await MCPDomainInvocationSecurityContext.$current.withValue(security) {
            try await provider.wrapping(binding)(["message": .string("hello")])
        }

        XCTAssertEqual(value, .string("ok"))
        let recorded = await recorder.values()
        XCTAssertEqual(recorded, ["prepared:5", "executed", "revoked:5"])
        XCTAssertEqual(plan.approvalMetadata["estimated_cost"], "full-roster")
        XCTAssertEqual(plan.approvalMetadata["providers"], lanes.map(\.providerIdentifier).joined(separator: ","))
    }

    func testPlannedModeRejectsMissingLaunchPlanBeforeAuthorizationOrDispatch() async throws {
        let runtime = makeRuntime(mode: .app, profile: "missing-plan")
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let recorder = LaunchRecorder()
        let provider = MCPDomainLongRunningToolProvider(
            identity: runtime.identity,
            policyStore: runtime.mutationPolicyStore,
            interactionBroker: runtime.interactionBroker,
            activityCenter: runtime.activityCenter,
            resolveChildLaunchPlan: { _, _, _ in nil },
            prepareChildLaunches: { _, _, _, _ in
                await recorder.record("unexpected-prepare")
                throw DomainChildLaunchPlanError.carrierMismatch
            },
            revokeChildLaunches: { _, _ in await recorder.record("unexpected-revoke") }
        )
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "ask_oracle",
                description: "missing plan fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            await recorder.record("unexpected-dispatch")
            return .string("unexpected")
        }
        let security = makeSecurityContext(identity: runtime.identity, toolName: "ask_oracle")

        await XCTAssertOracleLaunchThrowsErrorAsync {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(security) {
                try await provider.wrapping(binding)([:])
            }
        } verify: {
            XCTAssertTrue(String(describing: $0).contains("child_launch_plan_missing"))
        }
        let recorded = await recorder.values()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testPreparationFailureRevokesReservedPlanBeforeDispatch() async throws {
        let runtime = makeRuntime(mode: .app, profile: "prepare-failure")
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let recorder = LaunchRecorder()
        let plan = try DomainChildLaunchPlan(
            runID: UUID(),
            oracleGroupID: OracleGroupID(),
            oracleGroupClaimID: UUID(),
            lanes: try (0 ..< 2).map {
                DomainChildLaunchLanePlan(
                    providerIdentifier: "fixture",
                    oracleLaneID: try OracleLaneID(index: $0)
                )
            }
        )
        let provider = MCPDomainLongRunningToolProvider(
            identity: runtime.identity,
            policyStore: runtime.mutationPolicyStore,
            interactionBroker: runtime.interactionBroker,
            activityCenter: runtime.activityCenter,
            resolveChildLaunchPlan: { _, _, _ in plan },
            prepareChildLaunches: { _, _, _, _ in
                throw DomainChildLaunchPlanError.carrierMismatch
            },
            revokeChildLaunches: { _, bundle in
                await recorder.record(bundle == nil ? "revoked-plan" : "revoked-bundle")
            }
        )
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "ask_oracle",
                description: "failure fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            await recorder.record("unexpected-dispatch")
            return .string("unexpected")
        }
        let security = makeSecurityContext(identity: runtime.identity, toolName: "ask_oracle")

        await XCTAssertOracleLaunchThrowsErrorAsync {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(security) {
                try await provider.wrapping(binding)([:])
            }
        } verify: {
            XCTAssertEqual($0 as? DomainChildLaunchPlanError, .carrierMismatch)
        }
        let recorded = await recorder.values()
        XCTAssertEqual(recorded, ["revoked-plan"])
    }

    func testRoutingKeepsSharedRunPendingUntilAllFiveLaunchesSettle() async throws {
        let fixture = try await makeRuntimeWithContext(profile: "routing-count")
        defer { Task { await fixture.runtime.shutdown() } }
        let runID = UUID()
        let groupID = OracleGroupID()
        let claimID = UUID()
        let harness = DomainPrivateChildLaunchHarness(
            endpointDescriptor: "private://oracle",
            credentialStore: fixture.runtime.credentialEnvelopeStore,
            issueLaunchToken: { try await fixture.runtime.routingCoordinator.issueLaunchToken($0) },
            revokeLaunchToken: { await fixture.runtime.routingCoordinator.revokeLaunchToken($0) }
        )
        var carriers: [DomainChildLaunchCarrier] = []
        for laneIndex in 0 ..< 5 {
            let laneID = try OracleLaneID(index: laneIndex)
            let request = DomainRunLaunchReservationRequest(
                runID: runID,
                oracleGroupID: groupID,
                oracleLaneID: laneID,
                oracleGroupClaimID: claimID,
                context: fixture.context,
                expectedContextRevision: 1,
                windowID: nil,
                clientPrincipal: "oracle-agent",
                providerIdentifier: "provider-\(laneIndex)",
                runPurpose: "oracle-group"
            )
            let scope = DomainCredentialScope(
                providerIdentifier: request.providerIdentifier,
                runID: runID,
                launchID: request.launchID,
                oracleGroupID: groupID,
                oracleLaneID: laneID,
                oracleGroupClaimID: claimID,
                principalID: UUID(),
                purpose: "oracle-group"
            )
            carriers.append(try await harness.prepare(
                request: request,
                credential: (bytes: [UInt8(laneIndex + 1)], scope: scope)
            ))
        }

        XCTAssertEqual(Set(carriers.map(\.launchTokenID)).count, 5)
        XCTAssertEqual(Set(carriers.map(\.launchID)).count, 5)
        let conflictingRequest = DomainRunLaunchReservationRequest(
            runID: runID,
            context: fixture.alternateContext,
            expectedContextRevision: 1,
            windowID: nil,
            clientPrincipal: "oracle-agent",
            providerIdentifier: "provider-conflict",
            runPurpose: "oracle-group"
        )
        await XCTAssertOracleLaunchThrowsErrorAsync {
            _ = try await fixture.runtime.routingCoordinator.issueLaunchToken(conflictingRequest)
        } verify: {
            XCTAssertEqual($0 as? DomainRunLaunchTokenError, .runContextConflict)
        }
        let issuedSnapshot = await fixture.runtime.routingCoordinator.snapshot()
        XCTAssertEqual(issuedSnapshot.pendingRunContexts[runID], fixture.context)

        let first = carriers[0]
        let material = try XCTUnwrap(
            first.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey]
        )
        let redemption = await fixture.runtime.routingCoordinator.redeemLaunchToken(
            material: material,
            runtimeID: fixture.runtime.identity.runtimeID,
            runtimeGeneration: fixture.runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: "oracle-agent",
            providerIdentifier: "provider-0"
        )
        guard case let .accepted(accepted) = redemption else {
            return XCTFail("Expected lane redemption, received \(redemption)")
        }
        XCTAssertEqual(accepted.launchID, first.launchID)
        XCTAssertEqual(accepted.oracleGroupID, groupID)
        XCTAssertEqual(accepted.oracleLaneID?.index, 0)
        XCTAssertEqual(accepted.oracleGroupClaimID, claimID)
        let partiallyRedeemedSnapshot = await fixture.runtime.routingCoordinator.snapshot()
        XCTAssertNotNil(partiallyRedeemedSnapshot.pendingRunContexts[runID])

        for carrier in carriers.dropFirst() {
            await fixture.runtime.routingCoordinator.revokeLaunchToken(carrier.launchTokenID)
            if let envelopeID = carrier.credentialEnvelope?.envelopeID {
                await fixture.runtime.credentialEnvelopeStore.revoke(envelopeID)
            }
        }
        let settledSnapshot = await fixture.runtime.routingCoordinator.snapshot()
        XCTAssertNil(settledSnapshot.pendingRunContexts[runID])
    }

    func testCredentialScopeRejectsWrongLaneBeforeIssuingToken() async throws {
        let fixture = try await makeRuntimeWithContext(profile: "scope-mismatch")
        defer { Task { await fixture.runtime.shutdown() } }
        let harness = DomainPrivateChildLaunchHarness(
            endpointDescriptor: "private://oracle",
            credentialStore: fixture.runtime.credentialEnvelopeStore,
            issueLaunchToken: { try await fixture.runtime.routingCoordinator.issueLaunchToken($0) },
            revokeLaunchToken: { await fixture.runtime.routingCoordinator.revokeLaunchToken($0) }
        )
        let groupID = OracleGroupID()
        let claimID = UUID()
        let runID = UUID()
        let request = DomainRunLaunchReservationRequest(
            runID: runID,
            oracleGroupID: groupID,
            oracleLaneID: try OracleLaneID(index: 0),
            oracleGroupClaimID: claimID,
            context: fixture.context,
            expectedContextRevision: 1,
            windowID: nil,
            clientPrincipal: "oracle-agent",
            providerIdentifier: "fixture",
            runPurpose: "oracle-group"
        )
        let wildcardScope = DomainCredentialScope(
            providerIdentifier: request.providerIdentifier,
            runID: runID,
            principalID: UUID(),
            purpose: "oracle-group"
        )
        let wrongLaneScope = DomainCredentialScope(
            providerIdentifier: request.providerIdentifier,
            runID: runID,
            launchID: request.launchID,
            oracleGroupID: groupID,
            oracleLaneID: try OracleLaneID(index: 1),
            oracleGroupClaimID: claimID,
            principalID: UUID(),
            purpose: "oracle-group"
        )

        for scope in [wildcardScope, wrongLaneScope] {
            await XCTAssertOracleLaunchThrowsErrorAsync {
                _ = try await harness.prepare(request: request, credential: (bytes: [1], scope: scope))
            } verify: {
                XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .scopeMismatch)
            }
        }
        let counts = await fixture.runtime.routingCoordinator.tokenBookkeepingCounts()
        XCTAssertEqual(counts.records, 0)
        XCTAssertEqual(counts.pendingRunContexts, 0)
    }

    func testPartialOracleIdentityIsRejectedBeforeTokenIssuance() async throws {
        let fixture = try await makeRuntimeWithContext(profile: "partial-oracle-identity")
        defer { Task { await fixture.runtime.shutdown() } }
        let groupID = OracleGroupID()
        let laneID = try OracleLaneID(index: 0)
        let claimID = UUID()
        let identities: [(OracleGroupID?, OracleLaneID?, UUID?)] = [
            (groupID, nil, nil),
            (nil, laneID, nil),
            (nil, nil, claimID),
            (groupID, laneID, nil),
            (groupID, nil, claimID),
            (nil, laneID, claimID),
        ]

        for identity in identities {
            let request = DomainRunLaunchReservationRequest(
                runID: UUID(),
                oracleGroupID: identity.0,
                oracleLaneID: identity.1,
                oracleGroupClaimID: identity.2,
                context: fixture.context,
                expectedContextRevision: 1,
                windowID: nil,
                clientPrincipal: "oracle-agent",
                providerIdentifier: "fixture",
                runPurpose: "oracle-group"
            )
            await XCTAssertOracleLaunchThrowsErrorAsync {
                _ = try await fixture.runtime.routingCoordinator.issueLaunchToken(request)
            } verify: {
                XCTAssertEqual($0 as? DomainRunLaunchTokenError, .incompleteOracleIdentity)
            }
        }
        let counts = await fixture.runtime.routingCoordinator.tokenBookkeepingCounts()
        XCTAssertEqual(counts.records, 0)
        XCTAssertEqual(counts.pendingRunContexts, 0)
    }

    func testCredentialEnvelopeRejectsPartialOracleIdentity() async throws {
        let runtime = makeRuntime(mode: .standalone, profile: "partial-envelope-identity")
        defer { Task { await runtime.shutdown() } }
        let groupID = OracleGroupID()
        let laneID = try OracleLaneID(index: 0)
        let claimID = UUID()
        let launchID = UUID()
        let identities: [(OracleGroupID?, OracleLaneID?, UUID?)] = [
            (groupID, nil, nil),
            (nil, laneID, nil),
            (nil, nil, claimID),
            (groupID, laneID, nil),
            (groupID, nil, claimID),
            (nil, laneID, claimID),
        ]

        for identity in identities {
            let scope = DomainCredentialScope(
                providerIdentifier: "fixture",
                runID: UUID(),
                launchID: launchID,
                oracleGroupID: identity.0,
                oracleLaneID: identity.1,
                oracleGroupClaimID: identity.2,
                principalID: UUID(),
                purpose: "oracle-group"
            )
            await XCTAssertOracleLaunchThrowsErrorAsync {
                _ = try await runtime.credentialEnvelopeStore.issue(bytes: [1], scope: scope)
            } verify: {
                XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .scopeMismatch)
            }
        }
        let recordCount = await runtime.credentialEnvelopeStore.test_recordCount()
        XCTAssertEqual(recordCount, 0)
    }

    func testExpiredTokenIsSweptBeforeSameRunContextConflictCheck() async throws {
        let fixture = try await makeRuntimeWithContext(profile: "expired-context")
        defer { Task { await fixture.runtime.shutdown() } }
        let runID = UUID()
        let expired = DomainRunLaunchReservationRequest(
            runID: runID,
            context: fixture.context,
            expectedContextRevision: 1,
            windowID: nil,
            clientPrincipal: "oracle-agent",
            providerIdentifier: "fixture",
            runPurpose: "oracle-group",
            lifetime: .zero
        )
        _ = try await fixture.runtime.routingCoordinator.issueLaunchToken(expired)

        let replacement = DomainRunLaunchReservationRequest(
            runID: runID,
            context: fixture.alternateContext,
            expectedContextRevision: 1,
            windowID: nil,
            clientPrincipal: "oracle-agent",
            providerIdentifier: "fixture",
            runPurpose: "oracle-group"
        )
        _ = try await fixture.runtime.routingCoordinator.issueLaunchToken(replacement)

        let snapshot = await fixture.runtime.routingCoordinator.snapshot()
        XCTAssertEqual(snapshot.pendingRunContexts[runID], fixture.alternateContext)
    }

    private func makeRuntime(mode: DomainRuntimeMode, profile: String) -> MCPDomainRuntime {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleLaneLaunchAuthorizationTests-\(UUID().uuidString)", isDirectory: true)
        return MCPDomainRuntime(configuration: .init(
            mode: mode,
            profileIdentifier: profile,
            storageDirectory: root,
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("Temporary"),
            externalReloadInterval: nil
        ))
    }

    private func makeRuntimeWithContext(
        profile: String
    ) async throws -> (
        runtime: MCPDomainRuntime,
        context: DomainContextIdentity,
        alternateContext: DomainContextIdentity
    ) {
        let runtime = makeRuntime(mode: .standalone, profile: profile)
        try await runtime.start()
        let root = runtime.configuration.storageDirectory
        let workspaceID = UUID()
        let contextID = UUID()
        let alternateContextID = UUID()
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Oracle lanes",
            "repoPaths": [root.path],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [
                ["id": contextID.uuidString, "name": "Context", "prompt": ""],
                ["id": alternateContextID.uuidString, "name": "Other", "prompt": ""]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: data,
            fileURL: root.appendingPathComponent("workspace.json")
        )
        let outcome = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(document)
        ))
        XCTAssertEqual(outcome.disposition, .applied)
        return (
            runtime,
            DomainContextIdentity(workspaceID: workspaceID, contextID: contextID),
            DomainContextIdentity(workspaceID: workspaceID, contextID: alternateContextID)
        )
    }

    private func makeSecurityContext(
        identity: DomainRuntimeIdentity,
        toolName: String
    ) -> DomainToolInvocationSecurityContext {
        DomainToolInvocationSecurityContext(
            principal: .init(
                principalID: UUID(),
                stableKey: "oracle-agent",
                displayName: "Oracle Agent",
                kind: .runScoped,
                assurance: .verifiedProcess,
                processID: identity.processID,
                runID: UUID(),
                provider: "fixture",
                verifiedIdentityFingerprint: "fixture"
            ),
            connectionID: UUID(),
            connectionGeneration: 1,
            invocationID: UUID(),
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: [toolName]
        )
    }
}

private func XCTAssertOracleLaunchThrowsErrorAsync<T>(
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

private actor LaunchRecorder {
    private var recorded: [String] = []

    func record(_ value: String) { recorded.append(value) }
    func values() -> [String] { recorded }
}
