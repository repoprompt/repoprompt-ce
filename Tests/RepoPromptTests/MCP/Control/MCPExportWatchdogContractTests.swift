import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

#if DEBUG
    final class MCPExportWatchdogContractTests: XCTestCase {
        func testExportTimeoutPolicyMatchesBoundedEnvelopeContract() {
            XCTAssertEqual(MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds, 25)
            XCTAssertEqual(MCPTimeoutPolicy.promptExportExecutionDeadlineSeconds, 240)
            XCTAssertEqual(MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds, 5)
            XCTAssertEqual(MCPTimeoutPolicy.promptExportResponseDeliveryAllowanceSeconds, 30)
            XCTAssertEqual(MCPTimeoutPolicy.promptExportTotalEnvelopeSeconds, 300)
            XCTAssertEqual(MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds, 300)
            XCTAssertEqual(
                MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds
                    + MCPTimeoutPolicy.promptExportExecutionDeadlineSeconds
                    + MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds
                    + MCPTimeoutPolicy.promptExportResponseDeliveryAllowanceSeconds,
                MCPTimeoutPolicy.promptExportTotalEnvelopeSeconds
            )
        }

        func testToolCallDeadlineEnvelopeJSONCodablePreservesWireSchema() throws {
            let envelope = MCPToolCallDeadlineEnvelope(
                kind: .ordinaryPromptExportV1,
                expiresAtUnixMilliseconds: 1_800_000_000_123
            )

            let data = try JSONEncoder().encode(envelope)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["kind"] as? String, "ordinary_prompt_export_v1")
            XCTAssertEqual(object["timeout_mode"] as? String, "default")
            XCTAssertEqual(
                (object["expires_at_unix_milliseconds"] as? NSNumber)?.int64Value,
                1_800_000_000_123
            )
            XCTAssertNil(object["expiresAtUnixMilliseconds"])
            XCTAssertEqual(
                try JSONDecoder().decode(MCPToolCallDeadlineEnvelope.self, from: data),
                envelope
            )
        }

        func testToolCallDeadlineEnvelopeValueCodecPreservesWireSchema() {
            let envelope = MCPToolCallDeadlineEnvelope(
                kind: .ordinaryPromptExportV1,
                expiresAtUnixMilliseconds: 1_800_000_000_123
            )
            let encoded = MCPToolCallDeadlineEnvelopeValueCodec.encode(envelope)

            XCTAssertEqual(encoded, .object([
                "kind": .string("ordinary_prompt_export_v1"),
                "timeout_mode": .string("default"),
                "expires_at_unix_milliseconds": .int(1_800_000_000_123)
            ]))
            XCTAssertEqual(MCPToolCallDeadlineEnvelopeValueCodec.decode(encoded), envelope)

            for mode in [
                MCPToolCallDeadlineEnvelope.TimeoutMode.explicitFinite,
                .explicitUnbounded
            ] {
                let marker = MCPToolCallDeadlineEnvelope(
                    kind: .ordinaryPromptExportV1,
                    timeoutMode: mode
                )
                let markerValue = MCPToolCallDeadlineEnvelopeValueCodec.encode(marker)
                XCTAssertEqual(markerValue, .object([
                    "kind": .string("ordinary_prompt_export_v1"),
                    "timeout_mode": .string(mode.rawValue)
                ]))
                XCTAssertEqual(MCPToolCallDeadlineEnvelopeValueCodec.decode(markerValue), marker)
            }
        }

        func testPromptContextExportUsesExtendedBoundedForceDisconnectContract() {
            let cases: [(label: String, toolName: String, arguments: [String: Value])] = [
                ("prompt", MCPWindowToolName.prompt, ["op": .string("export")]),
                ("normalized prompt", MCPWindowToolName.prompt, ["op": .string("  ExPoRt  ")]),
                ("workspace context", MCPWindowToolName.workspaceContext, ["op": .string("export")]),
                ("normalized workspace context", MCPWindowToolName.workspaceContext, ["op": .string("  ExPoRt  ")])
            ]

            for testCase in cases {
                guard case let .bounded(deadline, cancellationGrace, cleanupDisposition) = MCPToolExecutionContractCatalog.contract(
                    for: testCase.toolName,
                    arguments: testCase.arguments
                ) else {
                    XCTFail("Expected bounded export contract for \(testCase.label)")
                    continue
                }
                XCTAssertEqual(deadline, MCPTimeoutPolicy.promptExportExecutionDeadline, testCase.label)
                XCTAssertEqual(cancellationGrace, MCPTimeoutPolicy.boundedToolCancellationCleanupGrace, testCase.label)
                XCTAssertEqual(cleanupDisposition, .forceDisconnect, testCase.label)

                XCTAssertEqual(
                    MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds
                        + MCPTimeoutPolicy.promptExportExecutionDeadlineSeconds
                        + MCPTimeoutPolicy.boundedToolCancellationCleanupGraceSeconds
                        + MCPTimeoutPolicy.promptExportResponseDeliveryAllowanceSeconds,
                    Int(MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds),
                    testCase.label
                )
            }
        }

        func testConnectionPermitReleasedWhenDeadlineExpiresImmediatelyAfterHandoff() async throws {
            let limiter = MCPDomainAsyncLimiter(limit: 1)
            let holderGate = AdmissionDeadlineGate()
            let bodyRan = AdmissionDeadlineFlag()
            let holder = Task {
                try await limiter.withPermit {
                    await holderGate.wait()
                }
            }
            _ = try await waitForAdmissionState(
                expected: "limiter activePermitCount == 1",
                snapshot: { await limiter.debugSnapshot() },
                matches: { $0.activePermitCount == 1 }
            )

            let now = AdmissionDeadlineNowSequence(beforeExpiryCalls: 2, expiry: .seconds(10))
            let deadline = MCPDomainAdmissionDeadline(
                instant: .seconds(10),
                now: now.value,
                sleep: { duration in try await Task.sleep(for: duration) }
            )
            let waiter = Task {
                try await limiter.withPermit(admissionDeadline: deadline) {
                    await bodyRan.mark()
                }
            }
            _ = try await waitForAdmissionState(
                expected: "limiter waiterCount == 1",
                snapshot: { await limiter.debugSnapshot() },
                matches: { $0.waiterCount == 1 }
            )
            await holderGate.release()
            try await holder.value

            do {
                try await waiter.value
                XCTFail("Expected the post-handoff deadline check to reject the permit")
            } catch is MCPDomainAdmissionDeadline.Expired {
                // Expected.
            }
            let didRunBody = await bodyRan.value()
            XCTAssertFalse(didRunBody)
            let settled = await limiter.debugSnapshot()
            XCTAssertEqual(settled.activePermitCount, 0)
            XCTAssertEqual(settled.permits, settled.limit)
            XCTAssertEqual(settled.waiterCount, 0)
            XCTAssertTrue(settled.isIdle)
        }

        func testConnectionPermitReleasedWhenDeadlineWinsAfterImmediateAcquisition() async throws {
            let limiter = MCPDomainAsyncLimiter(limit: 1)
            let permitAcquired = AdmissionDeadlineFlag()
            await limiter.setDebugImmediatePermitAcquiredHandler {
                await permitAcquired.mark()
                while !Task.isCancelled {
                    await Task.yield()
                }
            }
            let deadline = MCPDomainAdmissionDeadline(
                instant: .seconds(10),
                now: { .zero },
                sleep: { _ in
                    while await !permitAcquired.value() {
                        await Task.yield()
                    }
                }
            )

            do {
                try await limiter.withPermit(admissionDeadline: deadline) {}
                XCTFail("Expected the deadline child to win after permit acquisition")
            } catch is MCPDomainAdmissionDeadline.Expired {
                // Expected.
            }
            await limiter.setDebugImmediatePermitAcquiredHandler(nil)

            let capacityProbeRan = AdmissionDeadlineFlag()
            let capacityProbeDeadline = MCPDomainAdmissionDeadline(
                instant: .seconds(10),
                now: { .zero },
                sleep: { _ in try await Task.sleep(for: .milliseconds(50)) }
            )
            try await limiter.withPermit(admissionDeadline: capacityProbeDeadline) {
                await capacityProbeRan.mark()
            }

            let didRunCapacityProbe = await capacityProbeRan.value()
            XCTAssertTrue(didRunCapacityProbe)
            let settled = await limiter.debugSnapshot()
            XCTAssertEqual(settled.activePermitCount, 0)
            XCTAssertEqual(settled.permits, settled.limit)
            XCTAssertEqual(settled.waiterCount, 0)
            XCTAssertTrue(settled.isIdle)
        }

        func testResourceLeaseReleasedWhenDeadlineExpiresImmediatelyAfterHandoff() async throws {
            let controller = MCPDomainToolResourceAdmissionController(limit: 1)
            let resource = MCPDomainToolResourceAdmissionController.Resource.window(42)
            let firstLease = try await controller.acquire(resource)
            let now = AdmissionDeadlineNowSequence(beforeExpiryCalls: 2, expiry: .seconds(10))
            let deadline = MCPDomainAdmissionDeadline(
                instant: .seconds(10),
                now: now.value,
                sleep: { duration in try await Task.sleep(for: duration) }
            )
            let waiter = Task {
                try await controller.acquire(resource, admissionDeadline: deadline)
            }
            _ = try await waitForAdmissionState(
                expected: "resource waiterCount == 1",
                snapshot: {
                    (
                        activeCountForResource: controller.activeCount(for: resource),
                        waiterCountForResource: controller.waiterCount(for: resource),
                        controller: controller.snapshot()
                    )
                },
                matches: { $0.waiterCountForResource == 1 }
            )
            firstLease.release()

            do {
                _ = try await waiter.value
                XCTFail("Expected the post-handoff deadline check to reject the lease")
            } catch is MCPDomainAdmissionDeadline.Expired {
                // Expected.
            }
            XCTAssertEqual(controller.activeCount(for: resource), 0)
            XCTAssertEqual(controller.waiterCount(for: resource), 0)
            XCTAssertEqual(controller.snapshot().activeLeaseCount, 0)
        }

        func testTentativeConnectionLimiterRetryExpiresAndRemovesWaiter() async throws {
            let limiters = MCPDomainConnectionCallLimiters(
                limit: 1,
                controlLimit: 1,
                smallReadLimit: 1,
                fileReadLimit: 1,
                gitReadLimit: 1,
                fileSearchLimit: 1
            )
            let closeGate = AdmissionDeadlineGate()
            let closeTask = Task {
                await limiters.closeIfIdle {
                    await closeGate.wait()
                }
            }
            await closeGate.waitUntilEntered()

            let clock = MCPExportWatchdogManualClock()
            let deadline = MCPDomainAdmissionDeadline(
                instant: .seconds(MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds),
                now: clock.currentTime,
                sleep: { try await clock.sleep(for: $0) }
            )
            let retryTask = Task {
                try await limiters.admissionRetryReplacement(admissionDeadline: deadline)
            }
            try await clock.waitForSleeperCount(1)
            let queuedRetryWaiterCount = await limiters.admissionRetryWaiterCountForTesting()
            XCTAssertEqual(queuedRetryWaiterCount, 1)
            try await clock.advanceNext(expected: .seconds(
                MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds
            ))

            do {
                _ = try await retryTask.value
                XCTFail("Expected tentative limiter replacement retry to expire")
            } catch is MCPDomainAdmissionDeadline.Expired {
                // Expected.
            }
            let expiredRetryWaiterCount = await limiters.admissionRetryWaiterCountForTesting()
            XCTAssertEqual(expiredRetryWaiterCount, 0)

            await closeGate.release()
            let didClose = await closeTask.value
            XCTAssertTrue(didClose)
            await limiters.markTentativeCloseCommitted()
            let finalRetryWaiterCount = await limiters.admissionRetryWaiterCountForTesting()
            XCTAssertEqual(finalRetryWaiterCount, 0)
        }

        func testExecutionEnvelopeIsExtractedAndNeverReachesDomainArguments() {
            let envelopeValue: Value = .object([
                "kind": .string(MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue),
                "timeout_mode": .string(MCPToolCallDeadlineEnvelope.TimeoutMode.ordinaryDefault.rawValue),
                "expires_at_unix_milliseconds": .int(1_800_000_000_123)
            ])
            let direct = MCPToolArgsNormalizer.normalize(
                params: [
                    "op": .string("export"),
                    MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: envelopeValue
                ],
                originalToolName: "prompt",
                canonicalToolName: "prompt"
            )
            XCTAssertEqual(
                direct.executionEnvelopeState,
                .valid(MCPToolCallDeadlineEnvelope(
                    kind: .ordinaryPromptExportV1,
                    expiresAtUnixMilliseconds: 1_800_000_000_123
                ))
            )
            XCTAssertNil(direct.payload[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey])
            XCTAssertEqual(direct.payload["op"]?.stringValue, "export")

            let nested = MCPToolArgsNormalizer.normalize(
                params: [
                    "args": .object([
                        "op": .string("snapshot"),
                        MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: envelopeValue
                    ])
                ],
                originalToolName: "workspace_context",
                canonicalToolName: "workspace_context"
            )
            XCTAssertEqual(nested.executionEnvelopeState, .absent)
            XCTAssertNil(nested.payload[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey])
            XCTAssertNil(
                nested.payload["args"]?.objectValue?[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]
            )
            XCTAssertEqual(nested.payload["op"]?.stringValue, "snapshot")

            let objectWrapperConflict = MCPToolArgsNormalizer.normalize(
                params: [
                    MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: envelopeValue,
                    "prompt": .object([
                        "op": .string("export"),
                        MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: .object([
                            "kind": .string(MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue),
                            "timeout_mode": .string(MCPToolCallDeadlineEnvelope.TimeoutMode.ordinaryDefault.rawValue),
                            "expires_at_unix_milliseconds": .int(1)
                        ])
                    ])
                ],
                originalToolName: "prompt",
                canonicalToolName: "prompt"
            )
            XCTAssertEqual(
                objectWrapperConflict.executionEnvelopeState,
                .valid(MCPToolCallDeadlineEnvelope(
                    kind: .ordinaryPromptExportV1,
                    expiresAtUnixMilliseconds: 1_800_000_000_123
                ))
            )
            XCTAssertNil(objectWrapperConflict.payload[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey])
            XCTAssertEqual(objectWrapperConflict.payload["op"]?.stringValue, "export")

            let stringWrapperConflict = MCPToolArgsNormalizer.normalize(
                params: [
                    MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: envelopeValue,
                    "prompt": .string(
                        #"{"op":"export","_repoprompt_execution_envelope":{"kind":"ordinary_prompt_export_v1","timeout_mode":"explicit_unbounded"}}"#
                    )
                ],
                originalToolName: "prompt",
                canonicalToolName: "prompt"
            )
            XCTAssertEqual(
                stringWrapperConflict.executionEnvelopeState,
                .valid(MCPToolCallDeadlineEnvelope(
                    kind: .ordinaryPromptExportV1,
                    expiresAtUnixMilliseconds: 1_800_000_000_123
                ))
            )
            XCTAssertNil(stringWrapperConflict.payload[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey])
            XCTAssertEqual(stringWrapperConflict.payload["op"]?.stringValue, "export")

            let malformedDirectConflict = MCPToolArgsNormalizer.normalize(
                params: [
                    MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: .object([
                        "kind": .string("future_version"),
                        "expires_at_unix_milliseconds": .int(1_800_000_000_123)
                    ]),
                    "prompt": .object([
                        "op": .string("get"),
                        MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: envelopeValue
                    ])
                ],
                originalToolName: "prompt",
                canonicalToolName: "prompt"
            )
            XCTAssertEqual(malformedDirectConflict.executionEnvelopeState, .invalid)
            XCTAssertNil(malformedDirectConflict.payload[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey])
            XCTAssertEqual(malformedDirectConflict.payload["op"]?.stringValue, "get")
        }

        func testCleanupGraceIsCappedByOuterEnvelopeWithoutDetaching() async throws {
            let clock = MCPExportWatchdogManualClock()
            let events = ExportContractEventRecorder()
            let operationGate = ExportContractUncooperativeGate()
            let task = Task<Int, Error> {
                try await MCPToolExecutionWatchdog.execute(
                    deadline: .seconds(30),
                    cancellationGrace: .seconds(5),
                    cleanupNotAfter: .seconds(32),
                    cleanupDisposition: .forceDisconnect,
                    environment: clock.environment,
                    onEvent: { await events.append($0) }
                ) {
                    await operationGate.wait()
                    return 42
                }
            }

            try await clock.waitForSleeperCount(1)
            try await clock.advanceNext(expected: .seconds(30))
            try await clock.waitForSleeperCount(1)
            try await clock.advanceNext(expected: .seconds(2))

            do {
                _ = try await task.value
                XCTFail("Expected force-disconnect cleanup escalation")
            } catch let error as MCPToolExecutionWatchdogError {
                XCTAssertEqual(error, .cleanupUnresponsive)
            }
            let recordedEvents = await events.snapshot()
            XCTAssertEqual(recordedEvents, [
                .deadlineExpired,
                .cancellationRequested(origin: .watchdogDeadline),
                .cleanupGraceCappedByOuterEnvelope,
                .cleanupGraceExpired(resolvedDisposition: .forceDisconnect)
            ])
            await operationGate.release()
        }

        func testExhaustedOuterEnvelopeSkipsGraceAndDiagnosesBeforeForceDisconnect() async throws {
            let clock = MCPExportWatchdogManualClock()
            let events = ExportContractEventRecorder()
            let operationGate = ExportContractUncooperativeGate()
            let task = Task<Int, Error> {
                try await MCPToolExecutionWatchdog.execute(
                    deadline: .seconds(30),
                    cancellationGrace: .seconds(5),
                    cleanupNotAfter: .seconds(30),
                    cleanupDisposition: .forceDisconnect,
                    environment: clock.environment,
                    onEvent: { await events.append($0) }
                ) {
                    await operationGate.wait()
                    return 42
                }
            }

            try await clock.waitForSleeperCount(1)
            try await clock.advanceNext(expected: .seconds(30))

            do {
                _ = try await task.value
                XCTFail("Expected immediate force-disconnect cleanup escalation")
            } catch let error as MCPToolExecutionWatchdogError {
                XCTAssertEqual(error, .cleanupUnresponsive)
            }

            let sleeperCount = await clock.sleeperCount()
            let recordedEvents = await events.snapshot()
            XCTAssertEqual(sleeperCount, 0)
            XCTAssertEqual(recordedEvents, [
                .deadlineExpired,
                .cancellationRequested(origin: .watchdogDeadline),
                .cleanupGraceCappedByOuterEnvelope,
                .cleanupGraceExpired(resolvedDisposition: .forceDisconnect)
            ])
            await operationGate.release()
        }

        func testPromptContextExportsCompleteJustBeforeExtendedDeadlineWithoutTimeoutOrDetach() async throws {
            for scenario in promptContextExportWatchdogScenarios() {
                let operationGate = ExportContractUncooperativeGate()
                let task = scenario.start {
                    await operationGate.wait()
                    return 42
                }

                try await scenario.clock.waitForSleeperCount(1)
                try await scenario.clock.advanceWithoutWakingSleepers(
                    by: scenario.deadline - .nanoseconds(1)
                )
                await operationGate.release()

                let value = try await task.value
                let recordedEvents = await scenario.events.snapshot()
                XCTAssertEqual(value, 42, scenario.toolName)
                XCTAssertEqual(recordedEvents, [], scenario.toolName)
            }
        }

        func testPromptContextExportsAtExtendedDeadlineCancelCooperativelyWithoutDetach() async throws {
            for scenario in promptContextExportWatchdogScenarios() {
                let operationGate = ExportContractCancellationGate()
                let task = scenario.start {
                    try await operationGate.waitUntilCancelled()
                    return 42
                }

                try await scenario.clock.waitForSleeperCount(1)
                try await scenario.clock.advanceNext(expected: scenario.deadline)

                do {
                    _ = try await task.value
                    XCTFail("Expected execution timeout for \(scenario.toolName)")
                } catch let error as MCPToolExecutionWatchdogError {
                    XCTAssertEqual(error, .executionTimedOut(settlement: .cancellation), scenario.toolName)
                }
                let recordedEvents = await scenario.events.snapshot()
                XCTAssertEqual(recordedEvents, [
                    .deadlineExpired,
                    .cancellationRequested(origin: .watchdogDeadline),
                    .settledDuringGrace(.cancellation, cancellationRequested: true)
                ], scenario.toolName)
            }
        }

        func testPromptContextExportsAfterCleanupGraceForceDisconnectWithoutDetach() async throws {
            for scenario in promptContextExportWatchdogScenarios() {
                let operationGate = ExportContractUncooperativeGate()
                let task = scenario.start {
                    await operationGate.wait()
                    return 42
                }

                try await scenario.clock.waitForSleeperCount(1)
                try await scenario.clock.advanceNext(expected: scenario.deadline)
                try await scenario.clock.waitForSleeperCount(1)
                try await scenario.clock.advanceNext(expected: scenario.cancellationGrace)

                do {
                    _ = try await task.value
                    XCTFail("Expected cleanup escalation for \(scenario.toolName)")
                } catch let error as MCPToolExecutionWatchdogError {
                    XCTAssertEqual(error, .cleanupUnresponsive, scenario.toolName)
                }
                let recordedEvents = await scenario.events.snapshot()
                XCTAssertEqual(recordedEvents, [
                    .deadlineExpired,
                    .cancellationRequested(origin: .watchdogDeadline),
                    .cleanupGraceExpired(resolvedDisposition: .forceDisconnect)
                ], scenario.toolName)

                await operationGate.release()
            }
        }

        func testPromptContextExportsRetain300SecondClientDeadline() async {
            let session = makeUnconnectedSession()
            let cases: [(toolName: String, operation: String)] = [
                ("prompt", "export"),
                ("prompt", "  EXPORT\n"),
                ("workspace_context", "export"),
                ("workspace_context", "\tExPoRt ")
            ]

            for testCase in cases {
                let timeout = await session.test_resolvedToolCallTimeout(
                    toolName: testCase.toolName,
                    arguments: ["op": .string(testCase.operation)]
                )

                XCTAssertEqual(
                    timeout,
                    MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds,
                    "Unexpected export timeout for \(testCase.toolName) op=\(testCase.operation.debugDescription)"
                )
            }
        }

        func testPromptContextExportAliasesResolveToCanonicalDeadlineEnvelopeAndSettlementPath() async {
            let session = makeUnconnectedSession()
            let startedAtNanoseconds: UInt64 = 10000
            let wallNowUnixMilliseconds: Int64 = 1000
            let pairs = [
                (canonical: "prompt", alias: "discover_prompt"),
                (canonical: "workspace_context", alias: "discover_workspace_context")
            ]

            for pair in pairs {
                let canonical = await session.test_resolvedToolCallDeadline(
                    toolName: pair.canonical,
                    arguments: ["op": .string("export")],
                    startedAtNanoseconds: startedAtNanoseconds,
                    wallNowUnixMilliseconds: wallNowUnixMilliseconds
                )
                let alias = await session.test_resolvedToolCallDeadline(
                    toolName: pair.alias,
                    arguments: ["op": .string("export")],
                    startedAtNanoseconds: startedAtNanoseconds,
                    wallNowUnixMilliseconds: wallNowUnixMilliseconds
                )

                XCTAssertEqual(alias.timeoutSeconds, canonical.timeoutSeconds, pair.alias)
                XCTAssertEqual(alias.expiresAtNanoseconds, canonical.expiresAtNanoseconds, pair.alias)
                XCTAssertEqual(alias.wireEnvelope, canonical.wireEnvelope, pair.alias)
                XCTAssertEqual(alias.requestToolName, pair.canonical, pair.alias)
                XCTAssertEqual(alias.requestToolName, canonical.requestToolName, pair.alias)
                XCTAssertEqual(
                    alias.isSharedOrdinaryExportEnvelope,
                    canonical.isSharedOrdinaryExportEnvelope,
                    pair.alias
                )
                XCTAssertEqual(
                    alias.timeoutSeconds,
                    TimeInterval(MCPTimeoutPolicy.promptExportTotalEnvelopeSeconds),
                    pair.alias
                )
                XCTAssertEqual(alias.expiresAtNanoseconds, 300_000_010_000, pair.alias)
                XCTAssertEqual(alias.wireEnvelope?.timeoutMode, .ordinaryDefault, pair.alias)
                XCTAssertEqual(alias.wireEnvelope?.expiresAtUnixMilliseconds, 301_000, pair.alias)
                XCTAssertTrue(alias.isSharedOrdinaryExportEnvelope, pair.alias)
            }

            for control in [
                (toolName: "discover_prompt", operation: "get"),
                (toolName: "unknown_prompt_tool", operation: "export")
            ] {
                let resolved = await session.test_resolvedToolCallDeadline(
                    toolName: control.toolName,
                    arguments: ["op": .string(control.operation)],
                    startedAtNanoseconds: startedAtNanoseconds,
                    wallNowUnixMilliseconds: wallNowUnixMilliseconds
                )
                XCTAssertNil(resolved.wireEnvelope, control.toolName)
                XCTAssertEqual(resolved.requestToolName, control.toolName)
                XCTAssertFalse(resolved.isSharedOrdinaryExportEnvelope, control.toolName)
            }

            let malformedWrapper = await session.test_resolvedToolCallDeadline(
                toolName: "discover_prompt",
                arguments: ["discover_prompt": .string("{not-json")],
                startedAtNanoseconds: startedAtNanoseconds,
                wallNowUnixMilliseconds: wallNowUnixMilliseconds
            )
            XCTAssertEqual(malformedWrapper.requestToolName, "discover_prompt")
            XCTAssertNil(malformedWrapper.wireEnvelope)
            XCTAssertFalse(malformedWrapper.isSharedOrdinaryExportEnvelope)
        }

        func testOrdinaryDefaultExportOverwritesAndTransmitsVersionedEnvelope() async throws {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = ExportCLIToolArgumentsRecorder()
            let server = Server(
                name: "CLI envelope test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.record(name: params.name, arguments: params.arguments ?? [:])
                return .init(
                    content: [.text(text: "ok", annotations: nil, _meta: nil)],
                    isError: false
                )
            }
            try await server.start(transport: transports.server)
            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI envelope test client", version: "1.0")
            do {
                _ = try await client.connect(transport: clientTransport)
                let session = InteractiveMCPClientSession(
                    connectedClientForTesting: client,
                    requestSendBarrier: requestSendBarrier,
                    timeoutNowNanoseconds: { 10000 },
                    wallNowUnixMilliseconds: { 1000 }
                )
                _ = try await session.callTool(
                    name: "prompt",
                    arguments: [
                        "op": .string("export"),
                        "operation_id": .string("canonical-prompt"),
                        MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: .string("caller-value")
                    ]
                )
                _ = try await session.callTool(
                    name: "discover_prompt",
                    arguments: [
                        "op": .string("export"),
                        "operation_id": .string("alias-prompt")
                    ]
                )
                _ = try await session.callTool(
                    name: "workspace_context",
                    arguments: [
                        "op": .string("export"),
                        "operation_id": .string("canonical-workspace-context")
                    ]
                )
                _ = try await session.callTool(
                    name: "discover_workspace_context",
                    arguments: [
                        "op": .string("export"),
                        "operation_id": .string("alias-workspace-context")
                    ]
                )
                _ = try await session.callTool(
                    name: "discover_prompt",
                    arguments: [
                        "discover_prompt": .object([
                            "op": .string("export"),
                            "operation_id": .string("alias-prompt-object-wrapper")
                        ])
                    ]
                )
                _ = try await session.callTool(
                    name: "discover_workspace_context",
                    arguments: [
                        "discover_workspace_context": .object([
                            "op": .string("export"),
                            "operation_id": .string("alias-workspace-context-object-wrapper")
                        ])
                    ]
                )
                _ = try await session.callTool(
                    name: "discover_prompt",
                    arguments: [
                        "discover_prompt": .string(
                            #"{"op":"export","operation_id":"alias-prompt-json-wrapper","_tabID":"55555555-5555-5555-5555-555555555555","_windowID":43,"context_id":"66666666-6666-6666-6666-666666666666","_rawJSON":false,"working_dirs":["/tmp/prompt-json-wrapper"]}"#
                        )
                    ]
                )
                _ = try await session.callTool(
                    name: "discover_workspace_context",
                    arguments: [
                        "discover_workspace_context": .string(
                            #"{"op":"export","operation_id":"alias-workspace-context-json-wrapper","_tabID":"77777777-7777-7777-7777-777777777777","_windowID":44,"context_id":"88888888-8888-8888-8888-888888888888","_rawJSON":false,"working_dirs":["/tmp/workspace-json-wrapper"]}"#
                        )
                    ]
                )
                await session.setSelectedWindowID(900)
                await session.setSelectedContextID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
                await session.setRawJSONEnabled(true)
                _ = try await session.callTool(
                    name: "discover_prompt",
                    arguments: [
                        "op": .string("export"),
                        "operation_id": .string("alias-prompt-direct-controls"),
                        "_tabID": .string("11111111-1111-1111-1111-111111111111"),
                        "_windowID": .int(41),
                        "context_id": .string("22222222-2222-2222-2222-222222222222"),
                        "_rawJSON": .bool(false),
                        "working_dirs": .array([.string("/tmp/prompt-direct")])
                    ]
                )
                _ = try await session.callTool(
                    name: "discover_workspace_context",
                    arguments: [
                        "discover_workspace_context": .object([
                            "op": .string("export"),
                            "operation_id": .string("alias-workspace-wrapped-controls"),
                            "_tabID": .string("33333333-3333-3333-3333-333333333333"),
                            "_windowID": .int(42),
                            "context_id": .string("44444444-4444-4444-4444-444444444444"),
                            "_rawJSON": .bool(false),
                            "working_dirs": .array([.string("/tmp/workspace-wrapped")])
                        ])
                    ]
                )
                _ = try await session.callTool(
                    name: "discover_prompt",
                    arguments: [
                        "args": .object([
                            "op": .string("export"),
                            "operation_id": .string("alias-prompt-args-session-default-controls")
                        ])
                    ]
                )
                await session.setSelectedWindowID(nil)
                await session.setSelectedContextID(nil)
                await session.setRawJSONEnabled(false)
                _ = try await session.callTool(
                    name: "discover_prompt",
                    arguments: [
                        "op": .string("get"),
                        MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: .string("caller-value")
                    ]
                )
                _ = try await session.callTool(
                    name: "unknown_prompt_tool",
                    arguments: ["op": .string("export")]
                )
                _ = try await session.callTool(
                    name: "workspace_context",
                    arguments: ["op": .string("export")],
                    timeout: .seconds(300)
                )
                _ = try await session.callTool(
                    name: "prompt",
                    arguments: ["op": .string("export")],
                    timeout: .none
                )
                _ = try await session.callTool(
                    name: "prompt",
                    arguments: [
                        "args": .object([
                            "op": .string("export"),
                            MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: .object([
                                "kind": .string(MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue),
                                "expires_at_unix_milliseconds": .int(999_999)
                            ])
                        ])
                    ]
                )

                let calls = await recorder.snapshot()
                XCTAssertEqual(calls.count, 16)
                XCTAssertEqual(
                    calls.map(\.name),
                    [
                        "prompt",
                        "prompt",
                        "workspace_context",
                        "workspace_context",
                        "prompt",
                        "workspace_context",
                        "prompt",
                        "workspace_context",
                        "prompt",
                        "workspace_context",
                        "prompt",
                        "discover_prompt",
                        "unknown_prompt_tool",
                        "workspace_context",
                        "prompt",
                        "prompt"
                    ]
                )
                for index in 0 ... 10 {
                    let envelope = calls[index].arguments[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]?
                        .objectValue
                    XCTAssertEqual(
                        envelope?["kind"]?.stringValue,
                        MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue
                    )
                    XCTAssertEqual(envelope?["timeout_mode"]?.stringValue, "default")
                    XCTAssertEqual(envelope?["expires_at_unix_milliseconds"]?.intValue, 301_000)
                }
                XCTAssertEqual(calls[0].arguments["operation_id"]?.stringValue, "canonical-prompt")
                XCTAssertEqual(calls[1].arguments["operation_id"]?.stringValue, "alias-prompt")
                XCTAssertEqual(calls[2].arguments["operation_id"]?.stringValue, "canonical-workspace-context")
                XCTAssertEqual(calls[3].arguments["operation_id"]?.stringValue, "alias-workspace-context")
                XCTAssertEqual(calls[4].arguments["operation_id"]?.stringValue, "alias-prompt-object-wrapper")
                XCTAssertNil(calls[4].arguments["discover_prompt"])
                XCTAssertEqual(
                    calls[5].arguments["operation_id"]?.stringValue,
                    "alias-workspace-context-object-wrapper"
                )
                XCTAssertNil(calls[5].arguments["discover_workspace_context"])
                XCTAssertEqual(calls[6].arguments["operation_id"]?.stringValue, "alias-prompt-json-wrapper")
                XCTAssertNil(calls[6].arguments["discover_prompt"])
                XCTAssertEqual(calls[6].arguments["_tabID"]?.stringValue, "55555555-5555-5555-5555-555555555555")
                XCTAssertEqual(calls[6].arguments["_windowID"]?.intValue, 43)
                XCTAssertEqual(
                    calls[6].arguments["context_id"]?.stringValue,
                    "66666666-6666-6666-6666-666666666666"
                )
                XCTAssertEqual(calls[6].arguments["_rawJSON"]?.boolValue, false)
                XCTAssertEqual(
                    calls[6].arguments["working_dirs"]?.arrayValue?.first?.stringValue,
                    "/tmp/prompt-json-wrapper"
                )
                XCTAssertEqual(
                    calls[7].arguments["operation_id"]?.stringValue,
                    "alias-workspace-context-json-wrapper"
                )
                XCTAssertNil(calls[7].arguments["discover_workspace_context"])
                XCTAssertEqual(calls[7].arguments["_tabID"]?.stringValue, "77777777-7777-7777-7777-777777777777")
                XCTAssertEqual(calls[7].arguments["_windowID"]?.intValue, 44)
                XCTAssertEqual(
                    calls[7].arguments["context_id"]?.stringValue,
                    "88888888-8888-8888-8888-888888888888"
                )
                XCTAssertEqual(calls[7].arguments["_rawJSON"]?.boolValue, false)
                XCTAssertEqual(
                    calls[7].arguments["working_dirs"]?.arrayValue?.first?.stringValue,
                    "/tmp/workspace-json-wrapper"
                )
                for index in 4 ... 7 {
                    XCTAssertEqual(calls[index].arguments["op"]?.stringValue, "export")
                }
                XCTAssertEqual(calls[8].arguments["operation_id"]?.stringValue, "alias-prompt-direct-controls")
                XCTAssertEqual(calls[8].arguments["_tabID"]?.stringValue, "11111111-1111-1111-1111-111111111111")
                XCTAssertEqual(calls[8].arguments["_windowID"]?.intValue, 900)
                XCTAssertEqual(
                    calls[8].arguments["context_id"]?.stringValue,
                    "22222222-2222-2222-2222-222222222222"
                )
                XCTAssertEqual(calls[8].arguments["_rawJSON"]?.boolValue, false)
                XCTAssertEqual(calls[8].arguments["working_dirs"]?.arrayValue?.first?.stringValue, "/tmp/prompt-direct")
                XCTAssertEqual(
                    calls[9].arguments["operation_id"]?.stringValue,
                    "alias-workspace-wrapped-controls"
                )
                XCTAssertEqual(calls[9].arguments["_tabID"]?.stringValue, "33333333-3333-3333-3333-333333333333")
                XCTAssertEqual(calls[9].arguments["_windowID"]?.intValue, 900)
                XCTAssertEqual(
                    calls[9].arguments["context_id"]?.stringValue,
                    "44444444-4444-4444-4444-444444444444"
                )
                XCTAssertEqual(calls[9].arguments["_rawJSON"]?.boolValue, false)
                XCTAssertEqual(
                    calls[9].arguments["working_dirs"]?.arrayValue?.first?.stringValue,
                    "/tmp/workspace-wrapped"
                )
                XCTAssertEqual(
                    calls[10].arguments["operation_id"]?.stringValue,
                    "alias-prompt-args-session-default-controls"
                )
                XCTAssertNil(calls[10].arguments["args"])
                XCTAssertEqual(calls[10].arguments["op"]?.stringValue, "export")
                XCTAssertEqual(calls[10].arguments["_windowID"]?.intValue, 900)
                XCTAssertEqual(
                    calls[10].arguments["context_id"]?.stringValue,
                    "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
                )
                XCTAssertEqual(calls[10].arguments["_rawJSON"]?.boolValue, true)
                XCTAssertNil(calls[11].arguments[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey])
                XCTAssertNil(calls[12].arguments[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey])
                let finiteMarker = calls[13].arguments[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]?
                    .objectValue
                XCTAssertEqual(finiteMarker?["timeout_mode"]?.stringValue, "explicit_finite")
                XCTAssertNil(finiteMarker?["expires_at_unix_milliseconds"])
                let unboundedMarker = calls[14].arguments[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]?
                    .objectValue
                XCTAssertEqual(unboundedMarker?["timeout_mode"]?.stringValue, "explicit_unbounded")
                XCTAssertNil(unboundedMarker?["expires_at_unix_milliseconds"])
                XCTAssertEqual(
                    calls[15].arguments[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey]?
                        .objectValue?["expires_at_unix_milliseconds"]?.intValue,
                    301_000
                )
                await client.disconnect()
                await server.stop()
            } catch {
                await client.disconnect()
                await server.stop()
                throw error
            }
        }

        func testTimeoutWinsSettlementAndCancelsAndDrainsExactlyOnce() async throws {
            let timeoutGate = ExportCLIAsyncGate()
            let cancellationDeliveryGate = ExportCLIAsyncGate()
            let cancellationDrainStarted = ExportCLIAsyncSignal()
            let recorder = ExportCLICancellationSettlementRecorder()
            let monotonicClock = ExportCLIMonotonicClock()
            let fixture = try await makeFixture(
                cancellationBehavior: .ignoreUntilReleased,
                cancellationDeliveryOverride: { _, _, reason in
                    await recorder.recordDelivery(reason: reason)
                    await cancellationDeliveryGate.arriveAndWait()
                },
                timeoutNowNanoseconds: { monotonicClock.value() },
                timeoutSleep: { nanoseconds in
                    monotonicClock.advance(by: nanoseconds)
                    await timeoutGate.arriveAndWait()
                },
                cancellationDeliveryDrainSleep: { nanoseconds in
                    await recorder.recordDrain(timeoutNanoseconds: nanoseconds)
                    await cancellationDrainStarted.signal()
                    try await Task.sleep(for: .seconds(60))
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "prompt",
                        arguments: ["op": Value.string("export")]
                    )
                }
                await fixture.handlerStarted.wait()
                await timeoutGate.waitUntilArrived()
                await timeoutGate.release()
                await cancellationDeliveryGate.waitUntilArrived()
                call.cancel()
                await cancellationDrainStarted.wait()
                await cancellationDeliveryGate.release()

                do {
                    _ = try await call.value
                    XCTFail("Expected tool timeout")
                } catch let error as InteractiveSessionError {
                    guard case let .toolCallTimeout(toolName, seconds) = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await fixture.cleanup()
                        return
                    }
                    XCTAssertEqual(toolName, "prompt")
                    XCTAssertEqual(seconds, MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds)
                }

                let recorded = await recorder.snapshot()
                XCTAssertEqual(monotonicClock.value(), 300_000_000_000)
                XCTAssertEqual(recorded.deliveryReasons, ["CLI tool call timed out after 300.0 seconds"])
                XCTAssertEqual(recorded.drainTimeoutNanoseconds, [2_000_000_000])
                await fixture.cleanup()
            } catch {
                await timeoutGate.release()
                await cancellationDeliveryGate.release()
                await fixture.cleanup()
                throw error
            }
        }

        func testCallerCancellationWinsSettlementAndCancelsAndDrainsExactlyOnce() async throws {
            let timeoutGate = ExportCLIAsyncGate()
            let cancellationDeliveryGate = ExportCLIAsyncGate()
            let cancellationDrainStarted = ExportCLIAsyncSignal()
            let recorder = ExportCLICancellationSettlementRecorder()
            let fixture = try await makeFixture(
                cancellationBehavior: .ignoreUntilReleased,
                cancellationDeliveryOverride: { _, _, reason in
                    await recorder.recordDelivery(reason: reason)
                    await cancellationDeliveryGate.arriveAndWait()
                },
                timeoutSleep: { _ in await timeoutGate.arriveAndWait() },
                cancellationDeliveryDrainSleep: { nanoseconds in
                    await recorder.recordDrain(timeoutNanoseconds: nanoseconds)
                    await cancellationDrainStarted.signal()
                    try await Task.sleep(for: .seconds(60))
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "prompt",
                        arguments: ["op": .string("export")]
                    )
                }
                await fixture.handlerStarted.wait()
                await timeoutGate.waitUntilArrived()
                call.cancel()
                await cancellationDeliveryGate.waitUntilArrived()
                await timeoutGate.release()
                await cancellationDrainStarted.wait()
                await cancellationDeliveryGate.release()

                do {
                    _ = try await call.value
                    XCTFail("Expected caller cancellation")
                } catch is CancellationError {
                    // Expected.
                }

                let recorded = await recorder.snapshot()
                XCTAssertEqual(recorded.deliveryReasons, ["CLI caller cancelled tool request"])
                XCTAssertEqual(recorded.drainTimeoutNanoseconds, [2_000_000_000])
                await fixture.cleanup()
            } catch {
                await timeoutGate.release()
                await cancellationDeliveryGate.release()
                await fixture.cleanup()
                throw error
            }
        }

        func testSimultaneousCancellationDrainExpiryAndSendCompletionPreventsLateDelivery() async throws {
            let timeoutGate = ExportCLIAsyncGate()
            let requestSendCompletionGate = ExportCLIAsyncGate()
            let timeoutResolutionGate = ExportCLIAsyncGate()
            let sendCompletionWaitStarted = ExportCLIAsyncSignal()
            let authorizationRevoked = ExportCLIAsyncSignal()
            let cancellationDeliveryFinished = ExportCLIAsyncSignal()
            let recorder = ExportCLICancellationSettlementRecorder()
            let fixture = try await makeFixture(
                cancellationBehavior: .ignoreUntilReleased,
                requestSendDidRegister: {
                    await requestSendCompletionGate.arriveAndWait()
                },
                requestSendCompletionWaitDidStart: {
                    Task { await sendCompletionWaitStarted.signal() }
                },
                cancellationDeliveryAuthorizationDidRevoke: {
                    await authorizationRevoked.signal()
                    await timeoutResolutionGate.arriveAndWait()
                },
                cancellationDeliveryDidFinish: {
                    Task { await cancellationDeliveryFinished.signal() }
                },
                cancellationDeliveryOverride: { _, _, reason in
                    await recorder.recordDelivery(reason: reason)
                },
                timeoutSleep: { _ in await timeoutGate.arriveAndWait() },
                cancellationDeliveryDrainSleep: { nanoseconds in
                    await sendCompletionWaitStarted.wait()
                    await recorder.recordDrain(timeoutNanoseconds: nanoseconds)
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "prompt",
                        arguments: ["op": .string("export")]
                    )
                }
                await requestSendCompletionGate.waitUntilArrived()
                await timeoutGate.waitUntilArrived()
                await timeoutGate.release()
                await sendCompletionWaitStarted.wait()
                await authorizationRevoked.wait()
                await timeoutResolutionGate.waitUntilArrived()

                // Send completion becomes runnable while expiry owns authorization but has not
                // yet resumed the caller, forcing the disputed boundary ordering deterministically.
                await requestSendCompletionGate.release()
                await cancellationDeliveryFinished.wait()
                var recorded = await recorder.snapshot()
                XCTAssertEqual(recorded.deliveryReasons, [])

                await timeoutResolutionGate.release()
                do {
                    _ = try await call.value
                    XCTFail("Expected tool timeout")
                } catch let error as InteractiveSessionError {
                    guard case .toolCallTimeout = error else {
                        XCTFail("Expected tool timeout, got \(error)")
                        await fixture.cleanup()
                        return
                    }
                }

                recorded = await recorder.snapshot()
                XCTAssertEqual(recorded.deliveryReasons, [])
                XCTAssertEqual(recorded.drainTimeoutNanoseconds, [2_000_000_000])
                await fixture.cleanup()
            } catch {
                await timeoutGate.release()
                await requestSendCompletionGate.release()
                await timeoutResolutionGate.release()
                await fixture.cleanup()
                throw error
            }
        }

        func testCallerCancellationWhilePromptExportIsQueuedDoesNotSend() async throws {
            let requestStartGate = ExportCLIAsyncGate()
            let fixture = try await makeFixture(
                requestSendWillStart: {
                    await requestStartGate.arriveAndWait()
                }
            )
            do {
                let call = Task {
                    try await fixture.session.callTool(
                        name: "prompt",
                        arguments: ["op": .string("export")]
                    )
                }
                await requestStartGate.waitUntilArrived()
                call.cancel()
                await requestStartGate.release()

                do {
                    _ = try await call.value
                    XCTFail("Expected caller cancellation")
                } catch is CancellationError {
                    // Expected.
                }

                let handlerStarted = await fixture.handlerStarted.isSignalled()
                XCTAssertFalse(handlerStarted)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        private func waitForAdmissionState<State>(
            expected: String,
            timeout: Duration = .seconds(1),
            snapshot: () async -> State,
            matches: (State) -> Bool,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws -> State {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while true {
                let actual = await snapshot()
                if matches(actual) {
                    return actual
                }
                guard clock.now < deadline else {
                    XCTFail(
                        "Timed out waiting for admission state. Expected: \(expected). Actual: \(String(describing: actual))",
                        file: file,
                        line: line
                    )
                    throw AdmissionStateWaitError.timedOut
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }

        private func exportContract(for toolName: String) -> (
            deadline: Duration,
            cancellationGrace: Duration,
            cleanupDisposition: MCPToolExecutionCleanupDisposition
        )? {
            guard case let .bounded(deadline, cancellationGrace, cleanupDisposition) = MCPToolExecutionContractCatalog.contract(
                for: toolName,
                arguments: ["op": .string("export")]
            ) else {
                XCTFail("Expected bounded export contract for \(toolName)")
                return nil
            }
            XCTAssertEqual(deadline, MCPTimeoutPolicy.promptExportExecutionDeadline, toolName)
            XCTAssertEqual(cleanupDisposition, .forceDisconnect, toolName)
            return (deadline, cancellationGrace, cleanupDisposition)
        }

        private func promptContextExportWatchdogScenarios() -> [PromptContextExportWatchdogScenario] {
            [MCPWindowToolName.prompt, MCPWindowToolName.workspaceContext].compactMap { toolName in
                guard let contract = exportContract(for: toolName) else { return nil }
                return PromptContextExportWatchdogScenario(
                    toolName: toolName,
                    deadline: contract.deadline,
                    cancellationGrace: contract.cancellationGrace,
                    cleanupDisposition: contract.cleanupDisposition
                )
            }
        }

        private struct PromptContextExportWatchdogScenario {
            let toolName: String
            let deadline: Duration
            let cancellationGrace: Duration
            let cleanupDisposition: MCPToolExecutionCleanupDisposition
            let clock = MCPExportWatchdogManualClock()
            let events = ExportContractEventRecorder()

            func start(
                operation: @escaping @Sendable () async throws -> Int
            ) -> Task<Int, Error> {
                Task {
                    try await MCPToolExecutionWatchdog.execute(
                        deadline: deadline,
                        cancellationGrace: cancellationGrace,
                        cleanupDisposition: cleanupDisposition,
                        environment: clock.environment,
                        onEvent: { await events.append($0) },
                        operation: operation
                    )
                }
            }
        }

        private func makeUnconnectedSession() -> InteractiveMCPClientSession {
            InteractiveMCPClientSession(
                sessionToken: "timeout-contract-test",
                clientName: "timeout-contract-test"
            )
        }

        private func makeFixture(
            cancellationBehavior: ExportCLICancellationBehavior = .cooperative,
            requestSendWillStart: (@Sendable () async -> Void)? = nil,
            requestSendDidRegister: (@Sendable () async -> Void)? = nil,
            requestSendCompletionWaitDidStart: (@Sendable () -> Void)? = nil,
            cancellationDeliveryAuthorizationDidRevoke: (@Sendable () async -> Void)? = nil,
            cancellationDeliveryDidFinish: (@Sendable () -> Void)? = nil,
            cancellationDeliveryOverride: InteractiveMCPClientSession.CancellationDeliveryOverride? = nil,
            timeoutNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            timeoutSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            },
            cancellationDeliveryDrainTimeoutNanoseconds: UInt64 = 2_000_000_000,
            cancellationDeliveryDrainSleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        ) async throws -> ExportCLISessionCancellationFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let handlerStarted = ExportCLIAsyncSignal()
            let handlerCancelled = ExportCLIAsyncSignal()
            let ignoredCancellationRelease = ExportCLIAsyncSignal()
            let cancellationSuspension = ExportCLICancellationSuspension()
            let server = Server(
                name: "CLI cancellation test server",
                version: "1.0",
                capabilities: .init(tools: .init())
            )
            await server.withMethodHandler(CallTool.self) { _ in
                await handlerStarted.signal()
                do {
                    try await cancellationSuspension.wait()
                    return .init(
                        content: [.text(text: "unexpected", annotations: nil, _meta: nil)],
                        isError: false
                    )
                } catch is CancellationError {
                    await handlerCancelled.signal()
                    switch cancellationBehavior {
                    case .cooperative:
                        throw CancellationError()
                    case .ignoreUntilReleased:
                        await ignoredCancellationRelease.wait()
                        return .init(
                            content: [.text(text: "late result", annotations: nil, _meta: nil)],
                            isError: false
                        )
                    }
                }
            }
            try await server.start(transport: transports.server)

            let requestSendBarrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(
                underlying: transports.client,
                requestSendBarrier: requestSendBarrier,
                logger: transports.client.logger
            )
            let client = Client(name: "CLI cancellation test client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(
                connectedClientForTesting: client,
                requestSendBarrier: requestSendBarrier,
                requestSendWillStart: requestSendWillStart,
                requestSendDidRegister: requestSendDidRegister,
                requestSendCompletionWaitDidStart: requestSendCompletionWaitDidStart,
                cancellationDeliveryAuthorizationDidRevoke: cancellationDeliveryAuthorizationDidRevoke,
                cancellationDeliveryDidFinish: cancellationDeliveryDidFinish,
                cancellationDeliveryOverride: cancellationDeliveryOverride,
                timeoutSleep: timeoutSleep,
                timeoutNowNanoseconds: timeoutNowNanoseconds,
                cancellationDeliveryDrainTimeoutNanoseconds: cancellationDeliveryDrainTimeoutNanoseconds,
                cancellationDeliveryDrainSleep: cancellationDeliveryDrainSleep
            )
            return ExportCLISessionCancellationFixture(
                client: client,
                server: server,
                session: session,
                handlerStarted: handlerStarted,
                handlerCancelled: handlerCancelled,
                ignoredCancellationRelease: ignoredCancellationRelease
            )
        }
    }

    private enum AdmissionStateWaitError: Error {
        case timedOut
    }

    private final class AdmissionDeadlineNowSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingBeforeExpiryCalls: Int
        private let expiry: Duration

        init(beforeExpiryCalls: Int, expiry: Duration) {
            remainingBeforeExpiryCalls = beforeExpiryCalls
            self.expiry = expiry
        }

        func value() -> Duration {
            lock.withLock {
                guard remainingBeforeExpiryCalls > 0 else { return expiry }
                remainingBeforeExpiryCalls -= 1
                return .zero
            }
        }
    }

    private actor AdmissionDeadlineGate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = waiters
            self.waiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private actor AdmissionDeadlineFlag {
        private var marked = false

        func mark() {
            marked = true
        }

        func value() -> Bool {
            marked
        }
    }

    private actor ExportContractEventRecorder {
        private static let synchronizationTimeout: Duration = .seconds(10)
        private var events: [MCPToolExecutionWatchdogEvent] = []

        func append(_ event: MCPToolExecutionWatchdogEvent) {
            events.append(event)
        }

        func snapshot() -> [MCPToolExecutionWatchdogEvent] {
            events
        }

        func waitForCount(
            _ expected: Int,
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while events.count < expected {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw ExportContractEventRecorderError.eventDidNotArrive(
                        expected: expected,
                        actual: events.count
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private enum ExportContractEventRecorderError: Error {
        case eventDidNotArrive(expected: Int, actual: Int)
    }

    actor ExportContractUncooperativeGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class ExportContractCancellationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellationWasRequested = false
        private var continuation: CheckedContinuation<Void, Error>?

        func waitUntilCancelled() async throws {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if cancellationWasRequested || Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.continuation = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                lock.lock()
                cancellationWasRequested = true
                let continuation = continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume(throwing: CancellationError())
            }
        }
    }

    private enum ExportCLICancellationBehavior {
        case cooperative
        case ignoreUntilReleased
    }

    private struct ExportCLISessionCancellationFixture {
        let client: Client
        let server: Server
        let session: InteractiveMCPClientSession
        let handlerStarted: ExportCLIAsyncSignal
        let handlerCancelled: ExportCLIAsyncSignal
        let ignoredCancellationRelease: ExportCLIAsyncSignal

        func cleanup() async {
            await ignoredCancellationRelease.signal()
            await client.disconnect()
            await server.stop()
        }
    }

    private actor ExportCLIAsyncGate {
        private var arrived = false
        private var released = false
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            arrived = true
            let arrivalWaiters = arrivalWaiters
            self.arrivalWaiters.removeAll()
            for waiter in arrivalWaiters {
                waiter.resume()
            }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilArrived() async {
            guard !arrived else { return }
            await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }

        func release() {
            guard !released else { return }
            released = true
            let releaseWaiters = releaseWaiters
            self.releaseWaiters.removeAll()
            for waiter in releaseWaiters {
                waiter.resume()
            }
        }
    }

    private actor ExportCLIAsyncSignal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            guard !signalled else { return }
            signalled = true
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func wait() async {
            guard !signalled else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func isSignalled() -> Bool {
            signalled
        }
    }

    private final class ExportCLIMonotonicClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: UInt64 = 0

        func value() -> UInt64 {
            lock.withLock { now }
        }

        func advance(by nanoseconds: UInt64) {
            lock.withLock { now &+= nanoseconds }
        }
    }

    private actor ExportCLICancellationSettlementRecorder {
        private var deliveryReasons: [String] = []
        private var drainTimeoutNanoseconds: [UInt64] = []

        func recordDelivery(reason: String) {
            deliveryReasons.append(reason)
        }

        func recordDrain(timeoutNanoseconds: UInt64) {
            drainTimeoutNanoseconds.append(timeoutNanoseconds)
        }

        func snapshot() -> (deliveryReasons: [String], drainTimeoutNanoseconds: [UInt64]) {
            (deliveryReasons, drainTimeoutNanoseconds)
        }
    }

    private actor ExportCLIToolArgumentsRecorder {
        struct Call {
            let name: String
            let arguments: [String: Value]
        }

        private var calls: [Call] = []

        func record(name: String, arguments: [String: Value]) {
            calls.append(Call(name: name, arguments: arguments))
        }

        func snapshot() -> [Call] {
            calls
        }
    }

    private actor ExportCLICancellationSuspension {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, Error>
        }

        private var waiter: Waiter?
        private var cancelledWaiterIDs: Set<UUID> = []

        func wait() async throws {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled || cancelledWaiterIDs.remove(waiterID) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiter = Waiter(id: waiterID, continuation: continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancel(waiterID) }
            }
        }

        private func cancel(_ waiterID: UUID) {
            guard let waiter, waiter.id == waiterID else {
                cancelledWaiterIDs.insert(waiterID)
                return
            }
            self.waiter = nil
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

#endif
