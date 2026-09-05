import Darwin
import Foundation
import JSONSchema
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

#if DEBUG
    @MainActor
    final class MCPExportWatchdogIntegrationTests: XCTestCase {
        func testExpiredClientEnvelopeRejectsBeforeProviderAndJournalForBothPublicTools() async throws {
            for toolName in ["prompt", "workspace_context"] {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let operationID = "expired-envelope-\(toolName)-\(UUID().uuidString)"
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                    let phaseProbe = MCPPromptExportPhaseProbe()

                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { _ in
                        await phaseProbe.recordEntry()
                    }
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        let response = try await endpoint.callTool(
                            name: toolName,
                            arguments: [
                                "op": "export",
                                "path": exportURL.path,
                                "operation_id": operationID,
                                "_rawJSON": true,
                                MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: [
                                    "kind": MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue,
                                    "expires_at_unix_milliseconds": 0
                                ]
                            ]
                        )
                        let payload = try Self.toolResultObject(response)
                        XCTAssertEqual(payload["code"] as? String, "tool_execution_admission_timeout")
                        XCTAssertEqual(payload["retryable"] as? Bool, true)
                        XCTAssertEqual(payload["mutation_state"] as? String, "not_applied")
                        XCTAssertEqual(payload["operation_id"] as? String, operationID)
                        XCTAssertEqual(payload["tool"] as? String, toolName)
                        XCTAssertEqual(payload["cancellation_origin"] as? String, "client_deadline")
                        XCTAssertEqual(payload["settlement"] as? String, "admission_timeout")
                        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
                        let providerEntryCount = await phaseProbe.entryCount()
                        XCTAssertEqual(providerEntryCount, 0)
                        let journal = try await AppDomainRuntimeComposition.shared.runtime.mutationJournal.snapshot()
                        XCTAssertFalse(journal.recordSnapshots.contains { $0.operationID == operationID })

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    } catch {
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testInvalidDirectEnvelopeRejectsBeforeProviderAndJournalForBothPublicTools() async throws {
            for toolName in ["prompt", "workspace_context"] {
                for invalidCase in ["malformed", "unknown"] {
                    try await MCPSharedServerTestLease.shared.withLease { lease in
                        let fixture = try await PersistentMCPTestFixture.make(
                            lease: lease,
                            domainRuntime: AppDomainRuntimeComposition.shared.runtime
                        )
                        let manager = fixture.networkManager
                        let endpoint = try fixture.endpointA()
                        let operationID = "invalid-envelope-\(invalidCase)-\(toolName)-\(UUID().uuidString)"
                        let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                        let phaseProbe = MCPPromptExportPhaseProbe()
                        let invalidEnvelope: Any = if invalidCase == "malformed" {
                            "malformed"
                        } else {
                            [
                                "kind": "future_prompt_export_v2",
                                "expires_at_unix_milliseconds": 1_800_000_000_123
                            ]
                        }

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { _ in
                            await phaseProbe.recordEntry()
                        }
                        do {
                            try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                            let response = try await endpoint.callTool(
                                name: toolName,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true,
                                    MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: invalidEnvelope
                                ]
                            )
                            let payload = try Self.toolResultObject(response)
                            XCTAssertEqual(payload["code"] as? String, "tool_execution_invalid_envelope")
                            XCTAssertEqual(payload["retryable"] as? Bool, false)
                            XCTAssertEqual(payload["mutation_state"] as? String, "not_applied")
                            XCTAssertEqual(payload["operation_id"] as? String, operationID)
                            XCTAssertEqual(payload["tool"] as? String, toolName)
                            XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
                            let providerEntryCount = await phaseProbe.entryCount()
                            XCTAssertEqual(providerEntryCount, 0)
                            let journal = try await AppDomainRuntimeComposition.shared.runtime.mutationJournal.snapshot()
                            XCTAssertFalse(journal.recordSnapshots.contains { $0.operationID == operationID })

                            MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                            await manager.debugSetDomainPeerIdentityForTesting(
                                connectionID: endpoint.connectionID,
                                identity: nil
                            )
                            await fixture.cleanup()
                            try await fixture.assertCleanedUp()
                        } catch {
                            MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                            await manager.debugSetDomainPeerIdentityForTesting(
                                connectionID: endpoint.connectionID,
                                identity: nil
                            )
                            await fixture.cleanup()
                            throw error
                        }
                    }
                }
            }
        }

        func testPromptExportDeadlineRemainsProviderEntryBasedAcrossDelayedWatchdogInstallationForAllTimeoutModes() async throws {
            let timeoutModes: [String?] = [nil, "explicit_finite", "explicit_unbounded"]
            for toolName in ["prompt", "workspace_context"] {
                for timeoutMode in timeoutModes {
                    try await MCPSharedServerTestLease.shared.withLease { lease in
                        let fixture = try await PersistentMCPTestFixture.make(
                            lease: lease,
                            domainRuntime: AppDomainRuntimeComposition.shared.runtime
                        )
                        let manager = fixture.networkManager
                        let endpoint = try fixture.endpointA()
                        let connectionID = endpoint.connectionID
                        let domainHost = AppDomainRuntimeComposition.shared.runtime.domainHost
                        let clock = MCPExportWatchdogManualClock()
                        let hostGate = MCPExecutionIgnoringCancellationGate()
                        let watchdogInstallationGate = MCPExecutionIgnoringCancellationGate()
                        let providerGate = MCPExecutionIgnoringCancellationGate()
                        let recorder = MCPExecutionTraceRecorder()
                        let watchdogInstallationDelay: Duration = .seconds(7)
                        let timeoutModeLabel = timeoutMode ?? "ordinary"
                        let operationID = "provider-entry-origin-\(timeoutModeLabel)-\(toolName)-\(UUID().uuidString)"
                        let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                        var responseTask: Task<PersistentMCPTestRPCResponse, Error>?
                        var pendingError: Error?

                        @MainActor
                        func cleanup() async throws {
                            await hostGate.release()
                            await watchdogInstallationGate.release()
                            await providerGate.release()
                            if let responseTask {
                                responseTask.cancel()
                                _ = try? await responseTask.value
                            }
                            await domainHost.debugSetBeforeProviderActivationForTesting(nil)
                            await manager.debugSetAfterPromptExportProviderEntryForTesting(nil)
                            MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                            MCPToolExecutionTracer.setTestSink(nil)
                            await manager.debugSetDomainPeerIdentityForTesting(
                                connectionID: connectionID,
                                identity: nil
                            )
                            await manager.debugResetToolExecutionWatchdogEnvironment()
                            await fixture.cleanup()
                            try await fixture.assertCleanedUp()
                        }

                        do {
                            try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                            await domainHost.debugSetBeforeProviderActivationForTesting {
                                hookedConnectionID,
                                hookedToolName,
                                _ in
                                guard hookedConnectionID == connectionID,
                                      hookedToolName == toolName
                                else { return }
                                await hostGate.enterAndWait()
                            }
                            await manager.debugSetAfterPromptExportProviderEntryForTesting {
                                hookedConnectionID,
                                hookedToolName in
                                guard hookedConnectionID == connectionID,
                                      hookedToolName == toolName
                                else { return }
                                await watchdogInstallationGate.enterAndWait()
                            }
                            MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                                guard phase == .beforeDurableWrite else { return }
                                await providerGate.enterAndWait()
                            }
                            MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                            await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)

                            var callArguments: [String: Any] = [
                                "op": "export",
                                "path": exportURL.path,
                                "operation_id": operationID,
                                "_rawJSON": true
                            ]
                            if let timeoutMode {
                                callArguments[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey] = [
                                    "kind": MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue,
                                    "timeout_mode": timeoutMode
                                ]
                            }
                            let activeResponseTask = Task {
                                try await endpoint.callTool(
                                    name: toolName,
                                    arguments: callArguments
                                )
                            }
                            responseTask = activeResponseTask
                            try await hostGate.waitUntilEntered(count: 1)
                            let preEntrySleeperCount = await clock.sleeperCount()
                            XCTAssertEqual(preEntrySleeperCount, 0)

                            try await clock.advanceWithoutSleepers(
                                by: .seconds(MCPTimeoutPolicy.promptExportAdmissionHeadroomSeconds)
                                    - .nanoseconds(1)
                            )
                            await hostGate.release()
                            try await providerGate.waitUntilEntered(count: 1)
                            try await watchdogInstallationGate.waitUntilEntered(count: 1)
                            let preWatchdogSleeperCount = await clock.sleeperCount()
                            XCTAssertEqual(preWatchdogSleeperCount, 0)
                            try await clock.advanceWithoutSleepers(by: watchdogInstallationDelay)
                            await watchdogInstallationGate.release()
                            try await clock.waitForSleeperCount(1)
                            XCTAssertFalse(recorder.snapshot().contains {
                                $0.toolName == toolName && $0.phase == .deadlineExpired
                            })

                            let rebasedDeadlineSleep = MCPTimeoutPolicy.promptExportExecutionDeadline
                                - watchdogInstallationDelay
                            try await clock.advanceWithoutWakingSleepers(
                                by: rebasedDeadlineSleep - .seconds(1)
                            )
                            XCTAssertFalse(recorder.snapshot().contains {
                                $0.toolName == toolName && $0.phase == .deadlineExpired
                            })
                            try await clock.advanceNext(expected: rebasedDeadlineSleep)
                            let deadlineExpired = await Self.waitUntil {
                                recorder.snapshot().contains {
                                    $0.toolName == toolName && $0.phase == .deadlineExpired
                                }
                            }
                            XCTAssertTrue(deadlineExpired)
                            await providerGate.release()

                            let payload = try await Self.toolResultObject(activeResponseTask.value)
                            responseTask = nil
                            XCTAssertEqual(payload["code"] as? String, "tool_execution_timeout")
                            XCTAssertEqual(payload["settlement"] as? String, "cancellation")
                            XCTAssertEqual(payload["mutation_state"] as? String, "not_applied")
                            XCTAssertEqual(payload["retryable"] as? Bool, true)
                            XCTAssertEqual(payload["operation_id"] as? String, operationID)
                            XCTAssertEqual(payload["tool"] as? String, toolName)
                            XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
                            let record = try await Self.journalRecord(operationID: operationID)
                            XCTAssertEqual(
                                record.status.rawValue,
                                DomainMutationJournalStatus.cancelledBeforeCommit.rawValue
                            )
                        } catch {
                            pendingError = error
                        }
                        do {
                            try await cleanup()
                        } catch {
                            if pendingError == nil {
                                pendingError = error
                            }
                        }
                        if let pendingError {
                            throw pendingError
                        }
                    }
                }
            }
        }

        func testPromptExportPreDeadlineCompletionWinsAfterDelayedWatchdogInstallationForBothPublicTools() async throws {
            for toolName in ["prompt", "workspace_context"] {
                try await Self.assertPromptExportDelayedWatchdogCompletion(
                    toolName: toolName,
                    completionInstant: MCPTimeoutPolicy.promptExportExecutionDeadline - .nanoseconds(1),
                    expectsTimeout: false
                )
            }
        }

        func testPromptExportPostDeadlineCompletionTimesOutAfterDelayedWatchdogInstallationForBothPublicTools() async throws {
            for toolName in ["prompt", "workspace_context"] {
                try await Self.assertPromptExportDelayedWatchdogCompletion(
                    toolName: toolName,
                    completionInstant: MCPTimeoutPolicy.promptExportExecutionDeadline + .nanoseconds(1),
                    expectsTimeout: true
                )
            }
        }

        func testExplicitTimeoutModesUseAuthoritativeHostCompletionAcrossDelayedObservationForBothPublicTools() async throws {
            for toolName in ["prompt", "workspace_context"] {
                for timeoutMode in ["explicit_finite", "explicit_unbounded"] {
                    for expectsTimeout in [false, true] {
                        try await Self.assertPromptExportDelayedWatchdogCompletion(
                            toolName: toolName,
                            timeoutMode: timeoutMode,
                            completionInstant: MCPTimeoutPolicy.promptExportExecutionDeadline
                                + (expectsTimeout ? .nanoseconds(1) : .nanoseconds(-1)),
                            expectsTimeout: expectsTimeout
                        )
                    }
                }
            }
        }

        func testPromptExportCancellationAfterProviderEntryRetainsWatchdogSettlementOwnershipForBothPublicTools() async throws {
            for toolName in ["prompt", "workspace_context"] {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let connectionID = endpoint.connectionID
                    let context = fixture.contextA
                    let domainHost = AppDomainRuntimeComposition.shared.runtime.domainHost
                    let clock = MCPExportWatchdogManualClock()
                    let watchdogInstallationGate = MCPExecutionIgnoringCancellationGate()
                    let providerGate = MCPExecutionIgnoringCancellationGate()
                    let cancellationProbe = MCPPromptExportPhaseProbe()
                    let observerProbe = MCPToolEventObserverProbe()
                    let recorder = MCPExecutionTraceRecorder()
                    let operationID = "provider-entry-cancellation-\(toolName)-\(UUID().uuidString)"
                    let exportURL = context.rootURL.appendingPathComponent("\(operationID).md")
                    let runID = UUID()
                    let initialHostActiveInvocationCount = await domainHost.snapshot().activeInvocationCount
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?
                    var observerToken: UUID?
                    var pendingError: Error?

                    @MainActor
                    func cleanup() async throws {
                        await watchdogInstallationGate.release()
                        await providerGate.release()
                        if let responseTask {
                            responseTask.cancel()
                            _ = try? await responseTask.value
                        }
                        await manager.debugSetAfterPromptExportProviderEntryForTesting(nil)
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        MCPToolExecutionTracer.setTestSink(nil)
                        if let observerToken {
                            await manager.unregisterToolEventObserver(for: runID, token: observerToken)
                        }
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    }

                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        await manager.debugSeedConnectionRunRouting(
                            connectionID: connectionID,
                            runID: runID,
                            windowID: context.window.windowID
                        )
                        observerToken = await manager.registerToolEventObserver(
                            for: runID,
                            observer: ServerNetworkManager.ToolEventObserver(
                                onCalled: { _, observedToolName, _ in
                                    guard observedToolName == toolName else { return }
                                    await observerProbe.recordCalled()
                                },
                                onCompleted: { _, observedToolName, _, _, _ in
                                    guard observedToolName == toolName else { return }
                                    await observerProbe.recordCompleted()
                                }
                            )
                        )
                        await manager.debugSetAfterPromptExportProviderEntryForTesting {
                            hookedConnectionID,
                            hookedToolName in
                            guard hookedConnectionID == connectionID,
                                  hookedToolName == toolName
                            else { return }
                            await watchdogInstallationGate.enterAndWait()
                            // This hook runs inline on the server handler, placing cancellation
                            // after provider entry and before watchdog construction.
                            withUnsafeCurrentTask { $0?.cancel() }
                            await cancellationProbe.recordEntry()
                        }
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                            guard phase == .beforeDurableWrite else { return }
                            await providerGate.enterAndWait()
                        }
                        MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                        await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)

                        let activeResponseTask = Task {
                            try await endpoint.callTool(
                                name: toolName,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true
                                ]
                            )
                        }
                        responseTask = activeResponseTask
                        try await watchdogInstallationGate.waitUntilEntered(count: 1)
                        try await providerGate.waitUntilEntered(count: 1)
                        let preWatchdogSleeperCount = await clock.sleeperCount()
                        XCTAssertEqual(preWatchdogSleeperCount, 0)

                        await watchdogInstallationGate.release()
                        let cancellationReachedInstallationGap = await Self.waitUntil {
                            await cancellationProbe.entryCount() == 1
                        }
                        XCTAssertTrue(cancellationReachedInstallationGap)

                        let watchdogOwnedCancellation = await Self.waitUntil {
                            recorder.snapshot().contains {
                                $0.connectionID == connectionID
                                    && $0.toolName == toolName
                                    && $0.phase == .cancellationRequested
                                    && $0.cancellationOrigin == .requestCancellation
                            }
                        }
                        XCTAssertTrue(watchdogOwnedCancellation)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
                        _ = try? await activeResponseTask.value
                        responseTask = nil
                        let cancellationCompletionCount = await observerProbe.completedCount()
                        XCTAssertEqual(cancellationCompletionCount, 1)

                        await providerGate.release()

                        let hostDrained = await Self.waitUntil {
                            await domainHost.snapshot().activeInvocationCount == initialHostActiveInvocationCount
                        }
                        XCTAssertTrue(hostDrained)
                        let settlementPublished = await Self.waitUntil {
                            recorder.snapshot().contains {
                                $0.connectionID == connectionID
                                    && $0.toolName == toolName
                                    && $0.phase == .handlerCompleted
                                    && $0.cancellationOrigin == .requestCancellation
                                    && $0.cancellationOutcome == MCPToolExecutionSettlement.cancellation.rawValue
                            }
                        }
                        XCTAssertTrue(settlementPublished)
                        let completionPublished = await Self.waitUntil {
                            await observerProbe.completedCount() == 1
                        }
                        XCTAssertTrue(completionPublished)
                        let calledCount = await observerProbe.calledCount()
                        let completedCount = await observerProbe.completedCount()
                        XCTAssertEqual(calledCount, 1)
                        XCTAssertEqual(completedCount, 1)
                        let requestCancellationEvents = recorder.snapshot().count {
                            $0.connectionID == connectionID
                                && $0.toolName == toolName
                                && $0.phase == .cancellationRequested
                                && $0.cancellationOrigin == .requestCancellation
                        }
                        let settlementEvents = recorder.snapshot().count {
                            $0.connectionID == connectionID
                                && $0.toolName == toolName
                                && $0.phase == .handlerCompleted
                                && $0.cancellationOrigin == .requestCancellation
                        }
                        XCTAssertEqual(requestCancellationEvents, 1)
                        XCTAssertEqual(settlementEvents, 1)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
                        let record = try await Self.journalRecord(operationID: operationID)
                        XCTAssertEqual(
                            record.status.rawValue,
                            DomainMutationJournalStatus.cancelledBeforeCommit.rawValue
                        )
                        let sleepersDrained = await Self.waitUntil {
                            await clock.sleeperCount() == 0
                        }
                        XCTAssertTrue(sleepersDrained)
                    } catch {
                        pendingError = error
                    }
                    do {
                        try await cleanup()
                    } catch {
                        if pendingError == nil {
                            pendingError = error
                        }
                    }
                    if let pendingError {
                        throw pendingError
                    }
                }
            }
        }

        func testPromptExportDeadlineEqualityPreservesAppliedAuthorityForBothPublicTools() async throws {
            for toolName in ["prompt", "workspace_context"] {
                let operationID = "applied-equality-\(toolName)-\(UUID().uuidString)"
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let clock = MCPExportWatchdogManualClock()
                    let preWriteGate = MCPExecutionIgnoringCancellationGate()
                    let schedulingGate = ExecutionWatchdogSchedulingGate(blocking: .operationCompleted)
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(toolName)-\(operationID).md")
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment(
                        eventDidProduce: { await schedulingGate.eventDidProduce($0) },
                        beforeEventConsumption: { await schedulingGate.beforeEventConsumption($0) }
                    ))
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                        guard phase == .beforeDurableWrite else { return }
                        await preWriteGate.enterAndWait()
                    }
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        let activeResponseTask = Task {
                            try await endpoint.callTool(
                                name: toolName,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true
                                ]
                            )
                        }
                        responseTask = activeResponseTask
                        try await clock.waitForSleeperCount(1)
                        try await preWriteGate.waitUntilEntered(count: 1)
                        try await clock.advanceWithoutWakingSleepers(
                            by: MCPTimeoutPolicy.promptExportExecutionDeadline
                        )
                        await preWriteGate.release()
                        await schedulingGate.waitUntilConsumptionPaused()
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.promptExportExecutionDeadline)
                        await schedulingGate.waitUntilProduced(.deadlineExpired)
                        await schedulingGate.open()

                        let response = try await activeResponseTask.value
                        let payload = try Self.toolResultObject(response)
                        responseTask = nil
                        XCTAssertEqual(payload["code"] as? String, "tool_execution_timeout")
                        XCTAssertEqual(payload["settlement"] as? String, "success")
                        XCTAssertEqual(payload["mutation_state"] as? String, "applied")
                        XCTAssertEqual(payload["retryable"] as? Bool, false)
                        XCTAssertEqual(payload["operation_id"] as? String, operationID)
                        XCTAssertEqual(payload["tool"] as? String, toolName)
                        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
                        let record = try await Self.journalRecord(operationID: operationID)
                        XCTAssertEqual(record.toolName, toolName)
                        XCTAssertEqual(record.status.rawValue, DomainMutationJournalStatus.applied.rawValue)

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    } catch {
                        await preWriteGate.release()
                        await schedulingGate.open()
                        responseTask?.cancel()
                        if let responseTask { _ = try? await responseTask.value }
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testPromptExportWatchdogPreservesPreAndPostCommitTruth() async throws {
            for (toolName, postCommit) in ["prompt", "workspace_context"].flatMap({ toolName in
                [false, true].map { (toolName, $0) }
            }) {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let clock = MCPExportWatchdogManualClock()
                    let phaseGate = MCPExecutionIgnoringCancellationGate()
                    let label = "\(toolName)-\(postCommit ? "post-commit" : "pre-commit")"
                    let operationID = "\(label)-\(UUID().uuidString)"
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                        guard phase == (postCommit ? .afterDurableWrite : .beforeDurableWrite) else { return }
                        await phaseGate.enterAndWait()
                    }
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        let activeResponseTask = Task {
                            try await endpoint.callTool(
                                name: toolName,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true
                                ]
                            )
                        }
                        responseTask = activeResponseTask
                        try await clock.waitForSleeperCount(1)
                        try await phaseGate.waitUntilEntered(count: 1)
                        XCTAssertEqual(FileManager.default.fileExists(atPath: exportURL.path), postCommit)
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.promptExportExecutionDeadline)
                        await phaseGate.release()

                        let response = try await activeResponseTask.value
                        let payload = try Self.toolResultObject(response)
                        responseTask = nil
                        XCTAssertEqual(payload["code"] as? String, "tool_execution_timeout")
                        XCTAssertEqual(payload["settlement"] as? String, postCommit ? "error" : "cancellation")
                        XCTAssertEqual(
                            payload["mutation_state"] as? String,
                            postCommit ? "indeterminate_after_commit" : "not_applied"
                        )
                        XCTAssertEqual(payload["retryable"] as? Bool, !postCommit)
                        XCTAssertEqual(payload["operation_id"] as? String, operationID)
                        XCTAssertEqual(payload["tool"] as? String, toolName)
                        XCTAssertEqual(FileManager.default.fileExists(atPath: exportURL.path), postCommit)
                        let record = try await Self.journalRecord(operationID: operationID)
                        XCTAssertEqual(
                            record.status.rawValue,
                            postCommit
                                ? DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                                : DomainMutationJournalStatus.cancelledBeforeCommit.rawValue
                        )

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    } catch {
                        await phaseGate.release()
                        responseTask?.cancel()
                        if let responseTask { _ = try? await responseTask.value }
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testPromptExportCleanupUnresponsiveRetainsEventualJournalTruth() async throws {
            for toolName in ["prompt", "workspace_context"] {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let clock = MCPExportWatchdogManualClock()
                    let afterWriteGate = MCPExecutionIgnoringCancellationGate()
                    let operationID = "cleanup-unresponsive-\(toolName)-\(UUID().uuidString)"
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                        guard phase == .afterDurableWrite else { return }
                        await afterWriteGate.enterAndWait()
                    }
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        let activeResponseTask = Task {
                            try await endpoint.callTool(
                                name: toolName,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true
                                ]
                            )
                        }
                        responseTask = activeResponseTask
                        try await clock.waitForSleeperCount(1)
                        try await afterWriteGate.waitUntilEntered(count: 1)
                        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.promptExportExecutionDeadline)
                        try await clock.waitForSleeperCount(1)
                        try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
                        await Self.assertSocketClosed(activeResponseTask)
                        responseTask = nil
                        let isTerminal = await manager.debugIsExecutionWatchdogTerminal(
                            connectionID: endpoint.connectionID
                        )
                        XCTAssertTrue(isTerminal)

                        await afterWriteGate.release()
                        let settled = await Self.waitUntil {
                            guard let record = try? await Self.journalRecord(operationID: operationID) else { return false }
                            return record.status.rawValue == DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                        }
                        XCTAssertTrue(settled)
                        let record = try await Self.journalRecord(operationID: operationID)
                        XCTAssertEqual(
                            record.status.rawValue,
                            DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                        )
                        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                    } catch {
                        await afterWriteGate.release()
                        responseTask?.cancel()
                        if let responseTask { _ = try? await responseTask.value }
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testRealManageSelectionDrainTimeoutSettlesDuringGraceAndKeepsQueuedCallUsable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let clock = MCPExportWatchdogManualClock()
                let gate = MCPExecutionIgnoringCancellationGate()
                let recorder = MCPExecutionTraceRecorder()
                let manager = fixture.networkManager
                let server = fixture.contextA.window.mcpServer
                var endpoint: PersistentMCPTestEndpoint?
                var manageTask: Task<PersistentMCPTestRPCResponse, Error>?
                var queuedReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                MCPToolExecutionTracer.setTestSink { recorder.append($0) }
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                    await gate.enterAndWait()
                }
                do {
                    let clientName = "real-manage-selection-watchdog-\(UUID().uuidString)"
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: fixture.contextA.window.windowID,
                        restrictedTools: [],
                        tabID: fixture.contextA.tabID,
                        runID: UUID(),
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "real-manage-selection-watchdog",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [
                            MCPWindowToolName.readFile,
                            MCPWindowToolName.manageSelection
                        ]
                    )
                    endpoint = createdEndpoint
                    let readTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    try await gate.waitUntilEntered(count: 1)
                    _ = try await readTask.value

                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)
                    let activeManageTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: ["op": "get"]
                        )
                    }
                    manageTask = activeManageTask
                    try await clock.waitForSleeperCount(1)
                    let waiterRegistered = await Self.waitUntil {
                        server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount == 1
                    }
                    XCTAssertTrue(waiterRegistered)

                    let activeQueuedReadTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    queuedReadTask = activeQueuedReadTask
                    let queuedReadResponse = try await activeQueuedReadTask.value
                    queuedReadTask = nil
                    let queuedReadText = try Self.toolResultText(queuedReadResponse)
                    XCTAssertTrue(queuedReadText.contains(fixture.contextA.sentinel), queuedReadText)

                    try await clock.advanceNext(expected: MCPTimeoutPolicy.boundedToolExecutionDeadline)
                    let timeoutResponse = try await activeManageTask.value
                    manageTask = nil
                    let timeoutText = try Self.toolResultText(timeoutResponse)
                    XCTAssertEqual(timeoutText.components(separatedBy: "tool_execution_timeout").count - 1, 1, timeoutText)
                    XCTAssertEqual(server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount, 0)
                    XCTAssertEqual(server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWorkerCount, 1)

                    let isTerminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: createdEndpoint.connectionID)
                    XCTAssertFalse(isTerminal)
                    let events = recorder.snapshot().filter {
                        $0.connectionID == createdEndpoint.connectionID
                            && $0.toolName == MCPWindowToolName.manageSelection
                    }
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                    XCTAssertFalse(events.contains { $0.phase == .cleanupGraceExpired })
                    XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })

                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    _ = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "get"]
                    )
                    _ = try await createdEndpoint.client.request(method: "tools/list", params: [:])

                    MCPToolExecutionTracer.setTestSink(nil)
                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    manageTask?.cancel()
                    queuedReadTask?.cancel()
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    if let manageTask { _ = try? await manageTask.value }
                    if let queuedReadTask { _ = try? await queuedReadTask.value }
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testReadAutoSelectionThenImmediateManageSelectionAddAndGetPreservesCanonicalOwnership() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gate = MCPExecutionIgnoringCancellationGate()
                let server = fixture.contextA.window.mcpServer
                let store = fixture.contextA.window.workspaceFileContextStore
                let manager = fixture.networkManager
                let secondRelativePath = "Sources/ImmediateOwnership.swift"
                let secondURL = fixture.contextA.rootURL.appendingPathComponent(secondRelativePath)
                var endpoint: PersistentMCPTestEndpoint?
                _ = try await store.createFile(
                    rootID: fixture.contextA.rootID,
                    relativePath: secondRelativePath,
                    content: SwiftFixtureSource.emptyStruct("ImmediateOwnership")
                )
                server.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                    await gate.enterAndWait()
                }
                do {
                    let clientName = "selection-ownership-\(UUID().uuidString)"
                    let runID = UUID()
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: fixture.contextA.window.windowID,
                        restrictedTools: [],
                        tabID: fixture.contextA.tabID,
                        runID: runID,
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let createdEndpoint = try await PersistentMCPTestEndpoint.make(
                        label: "selection-ownership",
                        networkManager: manager,
                        clientName: clientName,
                        requiredToolNames: [
                            MCPWindowToolName.readFile,
                            MCPWindowToolName.manageSelection
                        ]
                    )
                    endpoint = createdEndpoint
                    try await fixture.registerDomainWorkspace(fixture.contextA)
                    try await Self.activateWorkspace(for: fixture.contextA)
                    let bindResponse = try await createdEndpoint.callTool(
                        name: "bind_context",
                        arguments: ["op": "bind", "context_id": fixture.contextA.tabID.uuidString]
                    )
                    XCTAssertFalse(bindResponse.rawJSON.contains("\"isError\":true"), bindResponse.rawJSON)
                    await manager.setRunPurpose(.agentModeRun, for: createdEndpoint.connectionID)
                    await manager.debugSeedConnectionRunRouting(
                        connectionID: createdEndpoint.connectionID,
                        runID: runID,
                        purpose: .agentModeRun,
                        windowID: fixture.contextA.window.windowID
                    )
                    let registration = try await AppDomainRuntimeComposition.shared.runtime
                        .routingCoordinator.currentRegistration(connectionID: createdEndpoint.connectionID)
                    let routingOutcome = await AppDomainRuntimeComposition.shared.runtime.routingCoordinator.bind(
                        connection: registration,
                        binding: .runScoped(
                            runID: runID,
                            context: .init(
                                workspaceID: fixture.contextA.workspaceID,
                                contextID: fixture.contextA.tabID
                            )
                        ),
                        operationID: UUID()
                    )
                    XCTAssertTrue(
                        routingOutcome.disposition == .applied || routingOutcome.disposition == .unchanged,
                        routingOutcome.diagnostic ?? "Domain run routing was not established"
                    )
                    let clearResponse = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "clear"]
                    )
                    XCTAssertFalse(clearResponse.rawJSON.contains("\"isError\":true"), clearResponse.rawJSON)
                    let readTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    try await gate.waitUntilEntered(count: 1)
                    let readResponse = try await readTask.value
                    XCTAssertFalse(readResponse.rawJSON.contains("\"isError\":true"), readResponse.rawJSON)

                    let addTask = Task {
                        try await createdEndpoint.callTool(
                            name: MCPWindowToolName.manageSelection,
                            arguments: [
                                "op": "add",
                                "paths": [secondURL.path],
                                "view": "files"
                            ]
                        )
                    }
                    let waiterRegistered = await Self.waitUntil {
                        server.readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount == 1
                    }
                    XCTAssertTrue(waiterRegistered)
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    let addResponse = try await addTask.value
                    XCTAssertFalse(addResponse.rawJSON.contains("\"isError\":true"), addResponse.rawJSON)

                    let getResponse = try await createdEndpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "get",
                            "view": "files"
                        ]
                    )
                    let getText = try Self.toolResultText(getResponse)
                    XCTAssertTrue(getText.contains(fixture.contextA.fileURL.lastPathComponent), getText)
                    XCTAssertTrue(getText.contains(secondURL.lastPathComponent), getText)

                    let canonical = try XCTUnwrap(
                        server.tabContextByConnectionID[createdEndpoint.connectionID]?.selection
                    )
                    XCTAssertEqual(
                        Set(canonical.selectedPaths),
                        Set([fixture.contextA.fileURL.path, secondURL.path])
                    )
                    let mirrored = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)?.selection
                    )
                    XCTAssertEqual(Set(mirrored.selectedPaths), Set(canonical.selectedPaths))

                    await Self.cleanupEndpoint(createdEndpoint, manager: manager)
                    endpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await gate.release()
                    server.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    if let endpoint { await Self.cleanupEndpoint(endpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testPromptExportPhaseAndDeliveryTracesShareCanonicalIdentity() async throws {
            #if DEBUG
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let manager = fixture.networkManager
                    let endpoint = try fixture.endpointA()
                    let traceDefaults = UserDefaults.standard
                    let traceKey = "enableMCPResponseDeliveryTrace"
                    let priorTraceValue = traceDefaults.object(forKey: traceKey)
                    let clock = MCPExportWatchdogManualClock()
                    let cases = [
                        (requestedName: "prompt", wireName: MCPWindowToolName.prompt),
                        (requestedName: "workspace_context", wireName: MCPWindowToolName.workspaceContext)
                    ]
                    var formattingGate: MCPExecutionIgnoringCancellationGate?
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?
                    try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                    traceDefaults.set(true, forKey: traceKey)
                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)

                    do {
                        for testCase in cases {
                            let executionRecorder = MCPExecutionTraceRecorder()
                            let pathSentinel = "export-trace-content-sentinel-\(testCase.requestedName)"
                            let requestID = endpoint.client.nextRequestIDForTesting()
                            let activeFormattingGate = MCPExecutionIgnoringCancellationGate()
                            formattingGate = activeFormattingGate
                            MCPResponseDeliveryTracer.resetDebugEvents()
                            MCPToolExecutionTracer.setTestSink { executionRecorder.append($0) }
                            await manager.debugSetResolvedToolOperationOverride(toolName: testCase.wireName) {
                                .object(["ok": .bool(true)])
                            }
                            await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                                guard connectionID == endpoint.connectionID,
                                      toolName == testCase.wireName
                                else { return }
                                await activeFormattingGate.enterAndWait()
                            }

                            let activeResponseTask = Task {
                                try await endpoint.callTool(
                                    name: testCase.wireName,
                                    arguments: [
                                        "op": "export",
                                        "path": fixture.contextA.rootURL.appendingPathComponent(pathSentinel).path,
                                        "operation_id": "export-trace-correlation-\(UUID().uuidString)",
                                        "_rawJSON": true
                                    ]
                                )
                            }
                            responseTask = activeResponseTask
                            try await activeFormattingGate.waitUntilEntered(count: 1)
                            let responseDeliveryDeadline = try XCTUnwrap(
                                MCPExportResponseDeliveryDeadlineRegistry.shared.deadlineForTesting(
                                    connectionID: endpoint.connectionID.uuidString,
                                    connectionGeneration: 1,
                                    requestID: .number(Int64(requestID))
                                ),
                                testCase.requestedName
                            )
                            XCTAssertEqual(
                                responseDeliveryDeadline.instant,
                                .seconds(MCPTimeoutPolicy.promptExportTotalEnvelopeSeconds),
                                testCase.requestedName
                            )
                            XCTAssertFalse(responseDeliveryDeadline.hasExpired, testCase.requestedName)
                            await activeFormattingGate.release()
                            _ = try await activeResponseTask.value
                            responseTask = nil
                            formattingGate = nil
                            await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                            XCTAssertNil(
                                MCPExportResponseDeliveryDeadlineRegistry.shared.deadlineForTesting(
                                    connectionID: endpoint.connectionID.uuidString,
                                    connectionGeneration: 1,
                                    requestID: .number(Int64(requestID))
                                ),
                                testCase.requestedName
                            )

                            let executionEvents = executionRecorder.snapshot().filter {
                                $0.toolName == testCase.wireName
                            }
                            let provider = try XCTUnwrap(
                                executionEvents.first { $0.phase == .handlerCompleted },
                                testCase.requestedName
                            )
                            let requestIdentity = try XCTUnwrap(provider.requestIdentity, testCase.requestedName)
                            XCTAssertEqual(
                                requestIdentity.appInvocationID.flatMap(UUID.init(uuidString:)),
                                provider.invocationID,
                                testCase.requestedName
                            )
                            XCTAssertEqual(requestIdentity.jsonRPCRequestID, .number(Int64(requestID)))
                            XCTAssertNotNil(requestIdentity.connectionID, testCase.requestedName)

                            let phaseEvents = executionEvents.filter { $0.phase == .handlerPhaseTransition }
                            XCTAssertEqual(
                                phaseEvents.map { $0.handlerPhase?.phase },
                                [
                                    .promptExportFormatting,
                                    .promptExportFormatting,
                                    .promptExportPublication,
                                    .promptExportPublication
                                ],
                                testCase.requestedName
                            )
                            XCTAssertEqual(
                                phaseEvents.map { $0.handlerPhase?.transition },
                                [.started, .completed, .started, .completed],
                                testCase.requestedName
                            )
                            XCTAssertTrue(phaseEvents.allSatisfy {
                                $0.invocationID == provider.invocationID
                                    && $0.requestIdentity == requestIdentity
                                    && $0.toolName == testCase.wireName
                            }, testCase.requestedName)
                            XCTAssertFalse(phaseEvents.contains {
                                $0.description.contains(pathSentinel)
                            }, testCase.requestedName)

                            let deliveryEvents = MCPResponseDeliveryTracer.debugEventSnapshot()
                            for phase in [
                                "handler_result_ready",
                                "sdk_encode_completed",
                                "transport_write_started",
                                "transport_write_completed"
                            ] {
                                let phaseEvents = deliveryEvents.filter { $0.phase == phase }
                                let event = try XCTUnwrap(deliveryEvents.first {
                                    $0.phase == phase
                                        && $0.requestIdentity?.jsonRPCRequestID == requestIdentity.jsonRPCRequestID
                                        && $0.requestIdentity?.connectionID == requestIdentity.connectionID
                                        && $0.requestIdentity?.requestOrdinal == requestIdentity.requestOrdinal
                                }, "\(testCase.requestedName): \(phase); candidates=\(phaseEvents)")
                                XCTAssertEqual(
                                    event.requestIdentity?.appInvocationID.flatMap(UUID.init(uuidString:)),
                                    provider.invocationID,
                                    testCase.requestedName
                                )
                                if phase == "handler_result_ready" {
                                    XCTAssertEqual(event.tool, testCase.wireName, testCase.requestedName)
                                }
                            }

                            MCPToolExecutionTracer.setTestSink(nil)
                            MCPResponseDeliveryTracer.resetDebugEvents()
                            await manager.debugSetResolvedToolOperationOverride(
                                toolName: testCase.wireName,
                                operation: nil
                            )
                        }

                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        if let priorTraceValue {
                            traceDefaults.set(priorTraceValue, forKey: traceKey)
                        } else {
                            traceDefaults.removeObject(forKey: traceKey)
                        }
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    } catch {
                        await formattingGate?.release()
                        responseTask?.cancel()
                        if let responseTask { _ = try? await responseTask.value }
                        MCPToolExecutionTracer.setTestSink(nil)
                        MCPResponseDeliveryTracer.resetDebugEvents()
                        await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                        for canonicalName in [MCPWindowToolName.prompt, MCPWindowToolName.workspaceContext] {
                            await manager.debugSetResolvedToolOperationOverride(
                                toolName: canonicalName,
                                operation: nil
                            )
                        }
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        if let priorTraceValue {
                            traceDefaults.set(priorTraceValue, forKey: traceKey)
                        } else {
                            traceDefaults.removeObject(forKey: traceKey)
                        }
                        await fixture.cleanup()
                        throw error
                    }
                }
            #else
                throw XCTSkip("Correlated tracer capture requires a DEBUG build")
            #endif
        }

        func testEarlyProtectedExportFailuresRetainDerivedOperationIDAsNotApplied() async throws {
            let runtime = AppDomainRuntimeComposition.shared.runtime
            let bindingInvoked = ProtectedMutationBindingInvocationProbe()
            let binding = MCPDomainToolBinding(
                definition: MCPDomainToolDefinition(
                    name: "prompt",
                    description: "test",
                    inputSchema: .object([:])
                )
            ) { _ in
                bindingInvoked.recordInvocation()
                return .object(["ok": .bool(true)])
            }
            let protectedBinding = runtime.protectedMutationProvider.protectedBinding(binding)
            let principal = DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "test:early-export",
                displayName: "Early export test",
                kind: .appProxy,
                assurance: .verifiedProcess,
                processID: Int32(getpid()),
                runID: nil,
                provider: nil,
                verifiedIdentityFingerprint: "test:early-export"
            )

            for failure in ["authorization", "cancellation"] {
                let operationID = "early-\(failure)-\(UUID().uuidString)"
                let settlementProbe = ProtectedMutationSettlementProbe()
                let context = DomainToolInvocationSecurityContext(
                    principal: principal,
                    connectionID: UUID(),
                    connectionGeneration: 1,
                    invocationID: UUID(),
                    runtimeID: failure == "authorization" ? UUID() : runtime.identity.runtimeID,
                    runtimeGeneration: runtime.identity.lifecycleGeneration,
                    ephemeralGrantedToolNames: ["prompt"]
                )
                let task = Task {
                    try await MCPDomainProtectedMutationSettlementContext.$observer.withValue(
                        { settlementProbe.record($0) }
                    ) {
                        try await MCPDomainInvocationSecurityContext.$current.withValue(context) {
                            try await protectedBinding([
                                "op": .string("export"),
                                "operation_id": .string(operationID)
                            ])
                        }
                    }
                }
                if failure == "cancellation" {
                    task.cancel()
                }
                do {
                    _ = try await task.value
                    XCTFail("Expected early \(failure) failure")
                } catch is DomainMutationPolicyError where failure == "authorization" {
                    // Expected.
                } catch is CancellationError where failure == "cancellation" {
                    // Expected.
                }

                let settlement = try XCTUnwrap(settlementProbe.snapshot().last)
                XCTAssertEqual(settlement.operationID, operationID)
                XCTAssertEqual(settlement.state, .notApplied)
                let journal = try await runtime.mutationJournal.snapshot()
                XCTAssertFalse(journal.recordSnapshots.contains { $0.operationID == operationID })
            }
            XCTAssertFalse(bindingInvoked.wasInvoked)
        }

        func testPostCommitCancellationReturnsIndeterminateProtectedMutationMetadata() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                let operationID = "post-commit-cancellation-\(UUID().uuidString)"
                let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                do {
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                        guard phase == .afterDurableWrite else { return }
                        withUnsafeCurrentTask { task in
                            task?.cancel()
                        }
                    }
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(
                            processID: Int(getpid()),
                            fingerprint: "test:verified:post-commit-cancellation"
                        )
                    )
                    try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                    let response = try await endpoint.callTool(
                        name: "workspace_context",
                        arguments: [
                            "op": "export",
                            "path": exportURL.path,
                            "operation_id": operationID,
                            "_rawJSON": true
                        ]
                    )
                    let payload = try Self.toolResultObject(response)
                    XCTAssertEqual(
                        payload["code"] as? String,
                        "protected_mutation_indeterminate_after_commit"
                    )
                    XCTAssertEqual(payload["settlement"] as? String, "error")
                    XCTAssertEqual(payload["mutation_state"] as? String, "indeterminate_after_commit")
                    XCTAssertEqual(payload["retryable"] as? Bool, false)
                    XCTAssertEqual(payload["operation_id"] as? String, operationID)
                    XCTAssertEqual(payload["tool"] as? String, "workspace_context")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
                    let record = try await Self.journalRecord(operationID: operationID)
                    XCTAssertEqual(
                        record.status.rawValue,
                        DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                    )

                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testPreWriteCancellationNeverWritesAndLeavesConnectionUsable() async throws {
            for toolName in [MCPWindowToolName.prompt, MCPWindowToolName.workspaceContext] {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let endpoint = try fixture.endpointA()
                    let manager = fixture.networkManager
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("prewrite-\(toolName).txt")
                    let afterWrite = ExportPhaseSignal()
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                            if phase == .beforeDurableWrite {
                                withUnsafeCurrentTask { $0?.cancel() }
                            } else if phase == .afterDurableWrite {
                                await afterWrite.mark()
                            }
                        }
                        let response = try await endpoint.callTool(
                            name: toolName,
                            arguments: [
                                "op": "export",
                                "path": exportURL.path,
                                "operation_id": "prewrite-\(toolName)-\(UUID().uuidString)",
                                "_rawJSON": true
                            ]
                        )
                        let payload = try Self.toolResultObject(response)
                        XCTAssertEqual(payload["is_error"] as? Bool, true)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
                        let didWrite = await afterWrite.isMarked()
                        XCTAssertFalse(didWrite)
                        let probe = try await endpoint.callTool(name: MCPWindowToolName.prompt, arguments: ["op": "get"])
                        XCTAssertFalse(probe.rawJSON.contains("\"isError\":true"), probe.rawJSON)

                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    } catch {
                        MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testLargeExportsPublishDeterministicPhaseOrderAndLeaveConnectionUsable() async throws {
            for toolName in [MCPWindowToolName.prompt, MCPWindowToolName.workspaceContext] {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let endpoint = try fixture.endpointA()
                    let manager = fixture.networkManager
                    let marker = "RPCE_LARGE_EXPORT_\(toolName)"
                    let content = marker + "\n" + String(repeating: "0123456789abcdef\n", count: 32000)
                    let phases = ExportHandlerPhaseRecorder()
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("large-\(toolName).txt")
                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        let set = try await endpoint.callTool(
                            name: MCPWindowToolName.prompt,
                            arguments: ["op": "set", "text": content]
                        )
                        XCTAssertFalse(set.rawJSON.contains("\"isError\":true"), set.rawJSON)
                        MCPToolExecutionHandlerPhaseContext.setTestSink { phases.append($0) }
                        let response = try await endpoint.callTool(
                            name: toolName,
                            arguments: [
                                "op": "export",
                                "path": exportURL.path,
                                "operation_id": "large-\(toolName)-\(UUID().uuidString)",
                                "_rawJSON": true
                            ]
                        )
                        let payload = try Self.toolResultObject(response)
                        XCTAssertNotEqual(payload["is_error"] as? Bool, true)
                        let exported = try String(contentsOf: exportURL, encoding: .utf8)
                        XCTAssertTrue(exported.contains(marker))
                        XCTAssertGreaterThanOrEqual(exported.lengthOfBytes(using: .utf8), 500_000)
                        XCTAssertEqual(phases.trace(), Self.expectedExportPhaseTrace)
                        let probe = try await endpoint.callTool(name: MCPWindowToolName.prompt, arguments: ["op": "get"])
                        XCTAssertFalse(probe.rawJSON.contains("\"isError\":true"), probe.rawJSON)

                        MCPToolExecutionHandlerPhaseContext.setTestSink(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    } catch {
                        MCPToolExecutionHandlerPhaseContext.setTestSink(nil)
                        await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        func testPipelinedSameToolDeadlinesFollowExactRequestIdentityWhenAdmissionReverses() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                let firstAdmissionGate = MCPExecutionIgnoringCancellationGate()
                let secondFormattingGate = MCPExecutionIgnoringCancellationGate()
                let firstFormattingGate = MCPExecutionIgnoringCancellationGate()
                let formattingProbe = MCPPromptExportPhaseProbe()
                var firstTask: Task<PersistentMCPTestRPCResponse, Error>?
                var secondTask: Task<PersistentMCPTestRPCResponse, Error>?

                do {
                    try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                    let firstRequestID = endpoint.client.nextRequestIDForTesting()
                    let secondRequestID = firstRequestID + 1
                    let wallNowMilliseconds = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
                    await manager.debugSetBeforeToolRequestIdentityClaimForTesting { connectionID, requestID in
                        guard connectionID == endpoint.connectionID,
                              requestID == .number(Int64(firstRequestID))
                        else { return }
                        await firstAdmissionGate.enterAndWait()
                    }
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.prompt) {
                        .object(["ok": .bool(true)])
                    }
                    await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                        guard connectionID == endpoint.connectionID,
                              toolName == MCPWindowToolName.prompt
                        else { return }
                        switch await formattingProbe.recordEntryAndReturnCount() {
                        case 1:
                            await secondFormattingGate.enterAndWait()
                        case 2:
                            await firstFormattingGate.enterAndWait()
                        default:
                            XCTFail("Unexpected additional formatting entry")
                        }
                    }
                    let activeFirstTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.prompt,
                            arguments: [
                                "op": "export",
                                "_rawJSON": true,
                                MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: [
                                    "kind": MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue,
                                    "expires_at_unix_milliseconds": wallNowMilliseconds + 300_000
                                ]
                            ]
                        )
                    }
                    firstTask = activeFirstTask
                    try await firstAdmissionGate.waitUntilEntered(count: 1)

                    let activeSecondTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.prompt,
                            arguments: [
                                "op": "export",
                                "_rawJSON": true,
                                MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: [
                                    "kind": MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue,
                                    "expires_at_unix_milliseconds": wallNowMilliseconds + 290_000
                                ]
                            ]
                        )
                    }
                    secondTask = activeSecondTask
                    try await secondFormattingGate.waitUntilEntered(count: 1)

                    XCTAssertNil(
                        MCPExportResponseDeliveryDeadlineRegistry.shared.deadlineForTesting(
                            connectionID: endpoint.connectionID.uuidString,
                            connectionGeneration: 1,
                            requestID: .number(Int64(firstRequestID))
                        )
                    )
                    let secondDeadline = try XCTUnwrap(
                        MCPExportResponseDeliveryDeadlineRegistry.shared.deadlineForTesting(
                            connectionID: endpoint.connectionID.uuidString,
                            connectionGeneration: 1,
                            requestID: .number(Int64(secondRequestID))
                        )
                    )
                    await secondFormattingGate.release()
                    _ = try await activeSecondTask.value
                    secondTask = nil

                    await firstAdmissionGate.release()
                    try await firstFormattingGate.waitUntilEntered(count: 1)
                    let firstDeadline = try XCTUnwrap(
                        MCPExportResponseDeliveryDeadlineRegistry.shared.deadlineForTesting(
                            connectionID: endpoint.connectionID.uuidString,
                            connectionGeneration: 1,
                            requestID: .number(Int64(firstRequestID))
                        )
                    )
                    XCTAssertGreaterThan(firstDeadline.instant, secondDeadline.instant)
                    XCTAssertNil(
                        MCPExportResponseDeliveryDeadlineRegistry.shared.deadlineForTesting(
                            connectionID: endpoint.connectionID.uuidString,
                            connectionGeneration: 1,
                            requestID: .number(Int64(secondRequestID))
                        )
                    )

                    await firstFormattingGate.release()
                    _ = try await activeFirstTask.value
                    firstTask = nil
                    await manager.debugSetBeforeToolRequestIdentityClaimForTesting(nil)
                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.prompt,
                        operation: nil
                    )
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await firstAdmissionGate.release()
                    await secondFormattingGate.release()
                    await firstFormattingGate.release()
                    firstTask?.cancel()
                    secondTask?.cancel()
                    if let firstTask { _ = try? await firstTask.value }
                    if let secondTask { _ = try? await secondTask.value }
                    await manager.debugSetBeforeToolRequestIdentityClaimForTesting(nil)
                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.prompt,
                        operation: nil
                    )
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testOuterDeadlineSuppressesFormattingAndObserverPublication() async throws {
            for boundary in ["formatting", "observer"] {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(
                        lease: lease,
                        domainRuntime: AppDomainRuntimeComposition.shared.runtime
                    )
                    let endpoint = try fixture.endpointA()
                    let connectionID = endpoint.connectionID
                    let manager = fixture.networkManager
                    let clock = MCPExportWatchdogManualClock()
                    let observerProbe = MCPToolEventObserverProbe()
                    let runID = UUID()
                    let operationID = "delivery-authority-\(boundary)-\(UUID().uuidString)"
                    let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                    var observerToken: UUID?
                    var responseTask: Task<PersistentMCPTestRPCResponse, Error>?
                    var pendingError: Error?

                    @MainActor
                    func cleanup() async throws {
                        if let responseTask {
                            responseTask.cancel()
                            _ = try? await responseTask.value
                        }
                        await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                        await manager.debugSetBeforeToolCompletionObserversForTesting(nil)
                        await manager.debugSetResolvedToolOperationOverride(
                            toolName: MCPWindowToolName.prompt,
                            operation: nil
                        )
                        if let observerToken {
                            await manager.unregisterToolEventObserver(for: runID, token: observerToken)
                        }
                        await manager.debugSetDomainPeerIdentityForTesting(
                            connectionID: endpoint.connectionID,
                            identity: nil
                        )
                        await manager.debugResetToolExecutionWatchdogEnvironment()
                        await fixture.cleanup()
                        try await fixture.assertCleanedUp()
                    }

                    do {
                        try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                        await manager.debugSeedConnectionRunRouting(
                            connectionID: endpoint.connectionID,
                            runID: runID,
                            windowID: fixture.contextA.window.windowID
                        )
                        observerToken = await manager.registerToolEventObserver(
                            for: runID,
                            observer: ServerNetworkManager.ToolEventObserver(
                                onCalled: { _, observedToolName, _ in
                                    guard observedToolName == MCPWindowToolName.prompt else { return }
                                    await observerProbe.recordCalled()
                                },
                                onCompleted: { _, observedToolName, _, _, _ in
                                    guard observedToolName == MCPWindowToolName.prompt else { return }
                                    await observerProbe.recordCompleted()
                                }
                            )
                        )
                        await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.prompt) {
                            .object(["ok": .bool(true)])
                        }
                        let expireDeliveryAuthority: @Sendable (UUID, String) async -> Void = {
                            hookedConnectionID,
                            hookedToolName in
                            guard hookedConnectionID == connectionID,
                                  hookedToolName == MCPWindowToolName.prompt
                            else { return }
                            try? await clock.advanceWithoutSleepers(
                                by: .seconds(MCPTimeoutPolicy.promptExportTotalEnvelopeSeconds)
                            )
                        }
                        if boundary == "formatting" {
                            await manager.debugSetBeforeToolResultFormattingForTesting(expireDeliveryAuthority)
                        } else {
                            await manager.debugSetBeforeToolCompletionObserversForTesting(expireDeliveryAuthority)
                        }
                        await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)

                        let activeResponseTask = Task {
                            try await endpoint.callTool(
                                name: MCPWindowToolName.prompt,
                                arguments: [
                                    "op": "export",
                                    "path": exportURL.path,
                                    "operation_id": operationID,
                                    "_rawJSON": true
                                ]
                            )
                        }
                        responseTask = activeResponseTask
                        await Self.assertSocketClosed(activeResponseTask, request: boundary)
                        responseTask = nil
                        let calledCount = await observerProbe.calledCount()
                        let completedCount = await observerProbe.completedCount()
                        XCTAssertEqual(calledCount, 1, boundary)
                        XCTAssertEqual(completedCount, 0, boundary)
                    } catch {
                        pendingError = error
                    }
                    do {
                        try await cleanup()
                    } catch {
                        if pendingError == nil {
                            pendingError = error
                        }
                    }
                    if let pendingError {
                        throw pendingError
                    }
                }
            }
        }

        func testServerBoundaryPreservesExportEnvelopeCompatibilityModes() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                do {
                    try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                    let exportCases: [(label: String, arguments: [String: Any])] = [
                        (
                            "malformed-wrapper",
                            [
                                "args": [
                                    "op": "export",
                                    "path": fixture.contextA.rootURL.appendingPathComponent("malformed-wrapper.md").path,
                                    "operation_id": "malformed-wrapper-\(UUID().uuidString)",
                                    MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: "malformed"
                                ],
                                "_rawJSON": true
                            ]
                        ),
                        (
                            "explicit-finite",
                            [
                                "op": "export",
                                "path": fixture.contextA.rootURL.appendingPathComponent("explicit-finite.md").path,
                                "operation_id": "explicit-finite-\(UUID().uuidString)",
                                "_rawJSON": true,
                                MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: [
                                    "kind": MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue,
                                    "timeout_mode": "explicit_finite"
                                ]
                            ]
                        ),
                        (
                            "explicit-unbounded",
                            [
                                "op": "export",
                                "path": fixture.contextA.rootURL.appendingPathComponent("explicit-unbounded.md").path,
                                "operation_id": "explicit-unbounded-\(UUID().uuidString)",
                                "_rawJSON": true,
                                MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: [
                                    "kind": MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue,
                                    "timeout_mode": "explicit_unbounded"
                                ]
                            ]
                        )
                    ]

                    for exportCase in exportCases {
                        let response = try await endpoint.callTool(
                            name: MCPWindowToolName.prompt,
                            arguments: exportCase.arguments
                        )
                        XCTAssertFalse(
                            response.rawJSON.contains("\"isError\":true"),
                            "\(exportCase.label): \(response.rawJSON)"
                        )
                        let payloadArguments = exportCase.arguments["args"] as? [String: Any]
                            ?? exportCase.arguments
                        let path = try XCTUnwrap(payloadArguments["path"] as? String)
                        let operationID = try XCTUnwrap(payloadArguments["operation_id"] as? String)
                        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
                        let record = try await Self.journalRecord(operationID: operationID)
                        XCTAssertEqual(record.status.rawValue, DomainMutationJournalStatus.applied.rawValue)
                    }

                    let nonExport = try await endpoint.callTool(
                        name: MCPWindowToolName.prompt,
                        arguments: [
                            "op": "get",
                            MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey: "malformed"
                        ]
                    )
                    XCTAssertFalse(nonExport.rawJSON.contains("\"isError\":true"), nonExport.rawJSON)
                    let probe = try await endpoint.callTool(
                        name: MCPWindowToolName.prompt,
                        arguments: ["op": "get"]
                    )
                    XCTAssertFalse(probe.rawJSON.contains("\"isError\":true"), probe.rawJSON)

                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testUnixSocketPublishesDistinctCorrelationIdentityBeforeImmediateDispatch() async throws {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            let transportFD = descriptors[0]
            let peerFD = descriptors[1]
            defer { Darwin.close(peerFD) }

            let rawConnectionID = UUID()
            let correlationConnectionID = "correlation-\(UUID().uuidString)"
            XCTAssertNotEqual(rawConnectionID.uuidString, correlationConnectionID)
            let beforeOffer = MCPExecutionOneShotSignal<Void>()
            let transport = try UnixSocketMCPTransport(
                connectedFD: transportFD,
                connectionID: rawConnectionID,
                correlationConnectionID: correlationConnectionID,
                connectionGeneration: 1
            )
            await transport.debugSetBeforeInboundFrameOfferForTesting {
                beforeOffer.signal(())
            }
            try await transport.connect()
            let receiveTask = Task {
                var iterator = await transport.receive().makeAsyncIterator()
                return try await iterator.next()
            }
            let requestFrame = Data(
                "{\"jsonrpc\":\"2.0\",\"id\":79,\"method\":\"tools/call\",\"params\":{\"name\":\"prompt\",\"arguments\":{\"op\":\"get\"}}}\n".utf8
            )
            let written = requestFrame.withUnsafeBytes { bytes in
                Darwin.write(peerFD, bytes.baseAddress, bytes.count)
            }
            XCTAssertEqual(written, requestFrame.count)
            await beforeOffer.wait()

            let identity = try XCTUnwrap(
                MCPRequestTimelineRegistry.shared.claimToolRequest(
                    connectionID: rawConnectionID.uuidString,
                    originalToolName: MCPWindowToolName.prompt
                )
            )
            XCTAssertEqual(identity.connectionID, correlationConnectionID)
            XCTAssertNotEqual(identity.connectionID, rawConnectionID.uuidString)
            XCTAssertEqual(identity.jsonRPCRequestID, .number(79))
            _ = try await receiveTask.value
            await transport.disconnect()
        }

        func testUnixSocketResponseDeliveryDeadlineStopsProgressingWriteAtAbsoluteDeadline() async throws {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            let transportFD = descriptors[0]
            let peerFD = descriptors[1]
            defer { Darwin.close(peerFD) }

            var sendBufferBytes: Int32 = 1024
            guard Darwin.setsockopt(
                transportFD,
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                Darwin.close(transportFD)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }

            let connectionID = UUID()
            let clock = MCPResponseDeliveryManualClock()
            let transport = try UnixSocketMCPTransport(
                connectedFD: transportFD,
                connectionID: connectionID,
                connectionGeneration: 1,
                writeStallTimeout: 60,
                writePollIntervalMilliseconds: 1
            )
            try await transport.connect()
            await transport.debugSetAfterWriteProgressForTesting { bytesWritten in
                clock.recordProgress(bytesWritten: bytesWritten, advancingTo: .seconds(10))
            }

            let requestFrame = Data(
                "{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"tools/call\",\"params\":{\"name\":\"prompt\",\"arguments\":{\"op\":\"export\"}}}\n".utf8
            )
            MCPExportResponseDeliveryDeadlineRegistry.shared.recordAcceptedClientFrame(
                requestFrame,
                connectionID: connectionID.uuidString,
                connectionGeneration: 1
            )
            let token = try XCTUnwrap(
                MCPExportResponseDeliveryDeadlineRegistry.shared.claimToolRequest(
                    connectionID: connectionID.uuidString,
                    connectionGeneration: 1,
                    requestID: .number(77)
                )
            )
            MCPExportResponseDeliveryDeadlineRegistry.shared.install(
                .init(instant: .seconds(10), now: { clock.value() }),
                for: token
            )
            let payload = String(repeating: "x", count: 8 * 1024 * 1024)
            let response = Data(
                "{\"jsonrpc\":\"2.0\",\"id\":77,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"\(payload)\"}]}}".utf8
            )

            do {
                try await transport.send(response)
                XCTFail("Expected the absolute response-delivery deadline to close the transport")
            } catch {
                XCTAssertTrue(String(describing: error).contains("absolute deadline"), String(describing: error))
            }
            XCTAssertGreaterThan(clock.progressBytes(), 0)
            let closeCause = await transport.closeSnapshot()?.cause
            XCTAssertEqual(closeCause, .writeFailure)
            await transport.disconnect()
        }

        func testUnixSocketResponseDeliveryDeadlineRejectsFinalChunkAtExactExpiry() async throws {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            let transportFD = descriptors[0]
            let peerFD = descriptors[1]
            defer { Darwin.close(peerFD) }

            let connectionID = UUID()
            let clock = MCPResponseDeliveryManualClock()
            let transport = try UnixSocketMCPTransport(
                connectedFD: transportFD,
                connectionID: connectionID,
                connectionGeneration: 1
            )
            try await transport.connect()

            let requestFrame = Data(
                "{\"jsonrpc\":\"2.0\",\"id\":78,\"method\":\"tools/call\",\"params\":{\"name\":\"prompt\",\"arguments\":{\"op\":\"export\"}}}\n".utf8
            )
            MCPExportResponseDeliveryDeadlineRegistry.shared.recordAcceptedClientFrame(
                requestFrame,
                connectionID: connectionID.uuidString,
                connectionGeneration: 1
            )
            let token = try XCTUnwrap(
                MCPExportResponseDeliveryDeadlineRegistry.shared.claimToolRequest(
                    connectionID: connectionID.uuidString,
                    connectionGeneration: 1,
                    requestID: .number(78)
                )
            )
            MCPExportResponseDeliveryDeadlineRegistry.shared.install(
                .init(instant: .seconds(10), now: { clock.value() }),
                for: token
            )
            let response = Data(
                "{\"jsonrpc\":\"2.0\",\"id\":78,\"result\":{\"content\":[]}}".utf8
            )
            let framedByteCount = response.count + 1
            await transport.debugSetAfterWriteProgressForTesting { bytesWritten in
                clock.recordProgress(bytesWritten: bytesWritten, advancingTo: .zero)
                if clock.progressBytes() == framedByteCount {
                    clock.advance(to: .seconds(10))
                }
            }

            do {
                try await transport.send(response)
                XCTFail("Expected exact-expiry final chunk to fail delivery")
            } catch {
                XCTAssertTrue(String(describing: error).contains("absolute deadline"), String(describing: error))
            }
            XCTAssertEqual(clock.progressBytes(), framedByteCount)
            let closeCause = await transport.closeSnapshot()?.cause
            XCTAssertEqual(closeCause, .writeFailure)
            await transport.disconnect()
        }

        func testSocketTransportRejectsMalformedToolArgumentsAndAnnotatesOmittedArguments() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                let recorder = MCPExecutionTraceRecorder()
                MCPToolExecutionTracer.setTestSink { recorder.append($0) }

                do {
                    for toolName in ["prompt", "workspace_context"] {
                        for malformedArguments: Any in ["get", ["op", "get"]] {
                            let response = try await endpoint.client.request(
                                method: "tools/call",
                                params: [
                                    "name": toolName,
                                    "arguments": malformedArguments
                                ]
                            )
                            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
                            let object = try XCTUnwrap(
                                JSONSerialization.jsonObject(with: data) as? [String: Any]
                            )
                            let error = try XCTUnwrap(object["error"] as? [String: Any])
                            XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32603, toolName)
                            XCTAssertNil(object["result"], toolName)
                        }
                        XCTAssertFalse(recorder.snapshot().contains {
                            $0.toolName == toolName && $0.phase == .started
                        }, toolName)

                        // Omitted arguments still need an injected transport identity so dispatch can
                        // correlate the SDK-decoded request with its originating socket frame.
                        let requestID = endpoint.client.nextRequestIDForTesting()
                        let identityClaim = MCPExecutionOneShotSignal<JSONRPCBridgeID>()
                        await manager.debugSetBeforeToolRequestIdentityClaimForTesting { connectionID, requestID in
                            guard connectionID == endpoint.connectionID else { return }
                            identityClaim.signal(requestID)
                        }
                        let response = try await endpoint.client.request(
                            method: "tools/call",
                            params: ["name": toolName]
                        )
                        let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
                        let object = try XCTUnwrap(
                            JSONSerialization.jsonObject(with: data) as? [String: Any]
                        )
                        XCTAssertNotNil(object["result"], toolName)
                        XCTAssertNil(object["error"], toolName)
                        let claimedRequestID = await identityClaim.wait()
                        XCTAssertEqual(
                            claimedRequestID,
                            .number(Int64(requestID)),
                            toolName
                        )
                        await manager.debugSetBeforeToolRequestIdentityClaimForTesting(nil)
                    }

                    MCPToolExecutionTracer.setTestSink(nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    MCPToolExecutionTracer.setTestSink(nil)
                    await manager.debugSetBeforeToolRequestIdentityClaimForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private static let expectedExportPhaseTrace = [
            "prompt_export.selection_drain:started",
            "prompt_export.selection_drain:completed",
            "prompt_export.preset_resolution:started",
            "prompt_export.preset_resolution:completed",
            "prompt_export.content_assembly:started",
            "prompt_export.content_assembly:completed",
            "prompt_export.metadata_assembly:started",
            "prompt_export.metadata_assembly:completed",
            "prompt_export.destination_authorization:started",
            "prompt_export.destination_authorization:completed",
            "prompt_export.durable_write:started",
            "prompt_export.durable_write:completed",
            "prompt_export.ingress_wait:started",
            "prompt_export.ingress_wait:completed",
            "prompt_export.reply_assembly:started",
            "prompt_export.reply_assembly:completed",
            "prompt_export.formatting:started",
            "prompt_export.formatting:completed",
            "prompt_export.publication:started",
            "prompt_export.publication:completed"
        ]

        private static func prepareProtectedExportFixture(
            _ fixture: PersistentMCPTestFixture,
            endpoint: PersistentMCPTestEndpoint
        ) async throws {
            let context = fixture.contextA
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            let client = DomainWorkspaceAuthorityClient(
                store: AppDomainRuntimeComposition.shared.runtime.workspaceStore,
                windowID: context.window.windowID
            )
            _ = try await client.registerForRead(
                workspace,
                fileURL: context.rootURL.appendingPathComponent("fixture.repoprompt-workspace")
            )
            await fixture.networkManager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: .verified(
                    processID: Int(getpid()),
                    fingerprint: "test:verified:prompt-export-watchdog"
                )
            )
            try await activateWorkspace(for: context)
            let bindResponse = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": context.tabID.uuidString]
            )
            let bindText = try toolResultText(bindResponse)
            XCTAssertFalse(bindText.contains("Error:"), bindText)
            await context.window.mcpServer.domainRoutingPublishTask?.value
        }

        private static func assertPromptExportDelayedWatchdogCompletion(
            toolName: String,
            timeoutMode: String? = nil,
            completionInstant: Duration,
            expectsTimeout: Bool
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let manager = fixture.networkManager
                let endpoint = try fixture.endpointA()
                let connectionID = endpoint.connectionID
                let domainHost = AppDomainRuntimeComposition.shared.runtime.domainHost
                let clock = MCPExportWatchdogManualClock()
                let watchdogInstallationGate = MCPExecutionIgnoringCancellationGate()
                let providerGate = MCPExecutionIgnoringCancellationGate()
                let watchdogInstallationEntered = MCPExecutionOneShotSignal<Void>()
                let providerEntered = MCPExecutionOneShotSignal<Void>()
                let hostCompleted = MCPExecutionOneShotSignal<Duration>()
                let scenario = expectsTimeout ? "post-deadline" : "pre-deadline"
                let timeoutModeLabel = timeoutMode ?? "ordinary"
                let operationID = "delayed-watchdog-\(timeoutModeLabel)-\(scenario)-\(toolName)-\(UUID().uuidString)"
                let exportURL = fixture.contextA.rootURL.appendingPathComponent("\(operationID).md")
                let initialHostActiveInvocationCount = await domainHost.snapshot().activeInvocationCount
                var responseTask: Task<PersistentMCPTestRPCResponse, Error>?
                var pendingError: Error?

                @MainActor
                func cleanup() async throws {
                    await providerGate.release()
                    await watchdogInstallationGate.release()
                    if let responseTask {
                        responseTask.cancel()
                        _ = try? await responseTask.value
                    }
                    await manager.debugSetAfterPromptExportProviderEntryForTesting(nil)
                    await manager.debugSetAfterPromptExportHostCompletionForTesting(nil)
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting(nil)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: connectionID,
                        identity: nil
                    )
                    await manager.debugResetToolExecutionWatchdogEnvironment()
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                }

                do {
                    try await Self.prepareProtectedExportFixture(fixture, endpoint: endpoint)
                    await manager.debugSetAfterPromptExportProviderEntryForTesting {
                        hookedConnectionID,
                        hookedToolName in
                        guard hookedConnectionID == connectionID,
                              hookedToolName == toolName
                        else { return }
                        watchdogInstallationEntered.signal(())
                        await watchdogInstallationGate.enterAndWait()
                    }
                    await manager.debugSetAfterPromptExportHostCompletionForTesting {
                        hookedConnectionID,
                        hookedToolName,
                        instant in
                        guard hookedConnectionID == connectionID,
                              hookedToolName == toolName
                        else { return }
                        hostCompleted.signal(instant)
                    }
                    MCPAppPhysicalCapabilityAdapters.setPromptExportPhaseHookForTesting { phase in
                        guard phase == .beforeDurableWrite else { return }
                        providerEntered.signal(())
                        await providerGate.enterAndWait()
                    }
                    await manager.debugSetToolExecutionWatchdogEnvironment(clock.environment)

                    var callArguments: [String: Any] = [
                        "op": "export",
                        "path": exportURL.path,
                        "operation_id": operationID,
                        "_rawJSON": true
                    ]
                    if let timeoutMode {
                        callArguments[MCPTimeoutPolicy.promptExportReservedEnvelopeArgumentKey] = [
                            "kind": MCPToolCallDeadlineEnvelope.Kind.ordinaryPromptExportV1.rawValue,
                            "timeout_mode": timeoutMode
                        ]
                    }
                    let activeResponseTask = Task {
                        try await endpoint.callTool(
                            name: toolName,
                            arguments: callArguments
                        )
                    }
                    responseTask = activeResponseTask
                    await watchdogInstallationEntered.wait()
                    await providerEntered.wait()
                    let preCompletionSleeperCount = await clock.sleeperCount()
                    XCTAssertEqual(preCompletionSleeperCount, 0)

                    try await clock.advanceWithoutSleepers(by: completionInstant)
                    await providerGate.release()
                    let recordedCompletionInstant = await hostCompleted.wait()
                    XCTAssertEqual(recordedCompletionInstant, completionInstant)

                    let watchdogInstallationInstant = MCPTimeoutPolicy.promptExportExecutionDeadline
                        + .nanoseconds(1)
                    if completionInstant < watchdogInstallationInstant {
                        try await clock.advanceWithoutSleepers(
                            by: watchdogInstallationInstant - completionInstant
                        )
                    }
                    XCTAssertEqual(clock.currentTime(), watchdogInstallationInstant)
                    await watchdogInstallationGate.release()

                    let response = try await activeResponseTask.value
                    responseTask = nil
                    if expectsTimeout {
                        let payload = try Self.toolResultObject(response)
                        XCTAssertEqual(payload["code"] as? String, "tool_execution_timeout")
                        XCTAssertEqual(payload["settlement"] as? String, "success")
                        XCTAssertEqual(payload["mutation_state"] as? String, "applied")
                        XCTAssertEqual(payload["retryable"] as? Bool, false)
                        XCTAssertEqual(payload["operation_id"] as? String, operationID)
                        XCTAssertEqual(payload["tool"] as? String, toolName)
                    } else {
                        XCTAssertFalse(response.rawJSON.contains("\"isError\":true"), response.rawJSON)
                        XCTAssertFalse(response.rawJSON.contains("tool_execution_timeout"), response.rawJSON)
                    }
                    XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
                    let record = try await Self.journalRecord(operationID: operationID)
                    XCTAssertEqual(record.toolName, toolName)
                    XCTAssertEqual(record.status.rawValue, DomainMutationJournalStatus.applied.rawValue)
                    let hostActiveInvocationCount = await domainHost.snapshot().activeInvocationCount
                    XCTAssertEqual(hostActiveInvocationCount, initialHostActiveInvocationCount)
                    let finalSleeperCount = await clock.sleeperCount()
                    XCTAssertEqual(finalSleeperCount, 0)
                } catch {
                    pendingError = error
                }
                do {
                    try await cleanup()
                } catch {
                    if pendingError == nil {
                        pendingError = error
                    }
                }
                if let pendingError {
                    throw pendingError
                }
            }
        }

        private static func journalRecord(operationID: String) async throws -> DomainMutationJournalRecord {
            let snapshot = try await AppDomainRuntimeComposition.shared.runtime.mutationJournal.snapshot()
            return try XCTUnwrap(
                snapshot.recordSnapshots.last { $0.operationID == operationID },
                "Missing mutation journal record for \(operationID)"
            )
        }

        private static func activateWorkspace(for context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPToolExecutionWatchdogIntegrationTests"
            )
            context.window.promptManager.loadComposeTabsFromWorkspace(
                workspace,
                syncPromptText: true
            )
        }

        private static func waitUntil(
            timeout: Duration = .seconds(10),
            condition: () async -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await condition()
        }

        private static func cleanupEndpoint(
            _ endpoint: PersistentMCPTestEndpoint,
            manager: ServerNetworkManager
        ) async {
            endpoint.client.close()
            await endpoint.connectionManager.stop()
            await manager.debugRemoveConnection(endpoint.connectionID)
            await manager.debugClearPersistedRoutingState(for: endpoint.clientName)
        }

        private static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }

        private static func toolResultObject(_ response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let text = try toolResultText(response)
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        private static func assertSocketClosed(
            _ task: Task<PersistentMCPTestRPCResponse, Error>,
            request: String = "request"
        ) async {
            do {
                _ = try await task.value
                XCTFail("Expected socket closure for \(request)")
            } catch PersistentMCPTestSocketClient.ClientError.closed {
                // Expected.
            } catch {
                XCTFail("Expected socket closure for \(request), got \(error)")
            }
        }

        nonisolated static func responseObject(from response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, response.id)
            XCTAssertNil(object["error"])
            return object
        }
    }

    private final class MCPResponseDeliveryManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Duration = .zero
        private var writtenByteCount = 0

        func value() -> Duration {
            lock.withLock { now }
        }

        func recordProgress(bytesWritten: Int, advancingTo instant: Duration) {
            lock.withLock {
                writtenByteCount += bytesWritten
                now = max(now, instant)
            }
        }

        func progressBytes() -> Int {
            lock.withLock { writtenByteCount }
        }

        func advance(to instant: Duration) {
            lock.withLock { now = max(now, instant) }
        }
    }

    private final class MCPExecutionTraceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [MCPToolExecutionTraceEvent] = []

        func append(_ event: MCPToolExecutionTraceEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [MCPToolExecutionTraceEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private actor MCPPromptExportPhaseProbe {
        private var count = 0

        func recordEntry() {
            count += 1
        }

        func entryCount() -> Int {
            count
        }

        func recordEntryAndReturnCount() -> Int {
            count += 1
            return count
        }
    }

    private final class MCPExecutionOneShotSignal<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        private var waiter: CheckedContinuation<Value, Never>?

        func signal(_ value: Value) {
            lock.lock()
            precondition(self.value == nil, "Execution signal fired more than once")
            self.value = value
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: value)
        }

        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let value {
                    lock.unlock()
                    continuation.resume(returning: value)
                    return
                }
                precondition(waiter == nil, "Execution signal has multiple waiters")
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private actor MCPToolEventObserverProbe {
        private var called = 0
        private var completed = 0

        func recordCalled() {
            called += 1
        }

        func recordCompleted() {
            completed += 1
        }

        func calledCount() -> Int {
            called
        }

        func completedCount() -> Int {
            completed
        }
    }

    actor MCPExecutionIgnoringCancellationGate {
        private static let synchronizationTimeout: Duration = .seconds(10)

        private var count = 0
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            count += 1
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered(
            count expected: Int,
            timeout: Duration = synchronizationTimeout
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while count < expected {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw MCPExecutionWatchdogIntegrationFixtureError.gateDidNotEnter(
                        expected: expected,
                        actual: count
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func enteredCount() -> Int {
            count
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private enum MCPExecutionWatchdogIntegrationFixtureError: Error {
        case cooperativeGateCancellationNotObserved
        case cooperativeGateDidNotEnter
        case gateDidNotEnter(expected: Int, actual: Int)
    }

    actor ExecutionWatchdogSchedulingGate {
        private let blockedPoint: MCPToolExecutionWatchdogSchedulingPoint
        private var isOpen = false
        private var producedPoints: [MCPToolExecutionWatchdogSchedulingPoint] = []
        private var productionWaiters: [(
            MCPToolExecutionWatchdogSchedulingPoint,
            CheckedContinuation<Void, Never>
        )] = []
        private var consumptionPauseWaiters: [CheckedContinuation<Void, Never>] = []
        private var blockedContinuations: [CheckedContinuation<Void, Never>] = []

        init(blocking blockedPoint: MCPToolExecutionWatchdogSchedulingPoint) {
            self.blockedPoint = blockedPoint
        }

        func eventDidProduce(_ point: MCPToolExecutionWatchdogSchedulingPoint) {
            producedPoints.append(point)
            let ready = productionWaiters.filter { $0.0 == point }
            productionWaiters.removeAll { $0.0 == point }
            ready.forEach { $0.1.resume() }
        }

        func waitUntilProduced(_ point: MCPToolExecutionWatchdogSchedulingPoint) async {
            if producedPoints.contains(point) { return }
            await withCheckedContinuation { continuation in
                productionWaiters.append((point, continuation))
            }
        }

        func beforeEventConsumption(_ point: MCPToolExecutionWatchdogSchedulingPoint) async {
            guard point == blockedPoint, !isOpen else { return }
            let waiters = consumptionPauseWaiters
            consumptionPauseWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                blockedContinuations.append(continuation)
            }
        }

        func waitUntilConsumptionPaused() async {
            if !blockedContinuations.isEmpty { return }
            await withCheckedContinuation { continuation in
                consumptionPauseWaiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let continuations = blockedContinuations
            blockedContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }

        func pendingTaskCount() -> Int {
            blockedContinuations.count + productionWaiters.count + consumptionPauseWaiters.count
        }
    }

    private final class ProtectedMutationSettlementProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var settlements: [DomainProtectedMutationSettlement] = []

        func record(_ settlement: DomainProtectedMutationSettlement) {
            lock.lock()
            settlements.append(settlement)
            lock.unlock()
        }

        func snapshot() -> [DomainProtectedMutationSettlement] {
            lock.lock()
            defer { lock.unlock() }
            return settlements
        }
    }

    private final class ProtectedMutationBindingInvocationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var invoked = false

        var wasInvoked: Bool {
            lock.lock()
            defer { lock.unlock() }
            return invoked
        }

        func recordInvocation() {
            lock.lock()
            invoked = true
            lock.unlock()
        }
    }

    private actor ExportPhaseSignal {
        private var marked = false
        func mark() {
            marked = true
        }

        func isMarked() -> Bool {
            marked
        }
    }

    private final class ExportHandlerPhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [MCPToolExecutionHandlerPhaseSnapshot] = []
        func append(_ snapshot: MCPToolExecutionHandlerPhaseSnapshot) {
            lock.withLock { snapshots.append(snapshot) }
        }

        func trace() -> [String] {
            lock.withLock { snapshots.map { "\($0.phase.rawValue):\($0.transition.rawValue)" } }
        }
    }

    actor MCPSharedServerTestLease {
        struct Ownership {}
        static let shared = MCPSharedServerTestLease()
        private var occupied = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func withLease<T>(_ operation: (Ownership) async throws -> T) async throws -> T {
            if occupied { await withCheckedContinuation { waiters.append($0) } }
            occupied = true
            let baseline = await ServerNetworkManager.shared.debugTransportState()
            defer {
                if let next = waiters.first { waiters.removeFirst()
                    next.resume()
                } else { occupied = false }
            }
            let result: Result<T, Error>
            do { result = try await .success(operation(Ownership())) } catch { result = .failure(error) }
            let manager = ServerNetworkManager.shared
            let observed = await manager.debugTransportState()
            if baseline.isRunning {
                if !observed.isRunning { await manager.start() }
                await manager.setEnabled(baseline.isEnabled)
            } else {
                if observed.isRunning { await manager.stop() }
                await manager.setEnabled(baseline.isEnabled)
            }
            return try result.get()
        }
    }

    @MainActor
    final class PersistentMCPTestFixture {
        let networkManager = ServerNetworkManager.shared
        let rootURL: URL
        let contextA: PersistentMCPTestContext
        let contextB: PersistentMCPTestContext
        private var primaryPersistentMCPTestEndpoint: PersistentMCPTestEndpoint?
        private var cleanedUp = false

        private init(
            rootURL: URL,
            contextA: PersistentMCPTestContext,
            contextB: PersistentMCPTestContext
        ) {
            self.rootURL = rootURL
            self.contextA = contextA
            self.contextB = contextB
        }

        static func make(
            lease: MCPSharedServerTestLease.Ownership,
            domainRuntime: MCPDomainRuntime? = nil
        ) async throws -> PersistentMCPTestFixture {
            _ = lease
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()

            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentMCPDistinctConnectionConcurrencyTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let windowA = if let domainRuntime {
                WindowState(domainRuntime: domainRuntime)
            } else {
                WindowState()
            }
            let windowB = if let domainRuntime {
                WindowState(domainRuntime: domainRuntime)
            } else {
                WindowState()
            }
            WindowStatesManager.shared.registerWindowState(windowA)
            WindowStatesManager.shared.registerWindowState(windowB)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await windowA.workspaceManager.awaitInitialized()
            await windowB.workspaceManager.awaitInitialized()

            var contextA: PersistentMCPTestContext?
            var contextB: PersistentMCPTestContext?
            var constructedFixture: PersistentMCPTestFixture?
            do {
                contextA = try await makeContext(
                    rootURL: rootURL.appendingPathComponent("context-a", isDirectory: true),
                    fileName: "DistinctConnectionA.swift",
                    sentinel: "let distinctMCPConnectionSentinelA = \"sentinel-a\"",
                    tabID: UUID(),
                    window: windowA,
                    label: "A"
                )
                contextB = try await makeContext(
                    rootURL: rootURL.appendingPathComponent("context-b", isDirectory: true),
                    fileName: "DistinctConnectionB.swift",
                    sentinel: "let distinctMCPConnectionSentinelB = \"sentinel-b\"",
                    tabID: UUID(),
                    window: windowB,
                    label: "B"
                )
                try await ensureRequiredCatalogAndEnableTransport(
                    contexts: [XCTUnwrap(contextA), XCTUnwrap(contextB)]
                )
                let fixture = try PersistentMCPTestFixture(
                    rootURL: rootURL,
                    contextA: XCTUnwrap(contextA),
                    contextB: XCTUnwrap(contextB)
                )
                constructedFixture = fixture
                fixture.primaryPersistentMCPTestEndpoint = try await PersistentMCPTestEndpoint.make(
                    label: "a",
                    networkManager: fixture.networkManager
                )
                return fixture
            } catch {
                if let constructedFixture {
                    await constructedFixture.cleanup()
                } else {
                    if let contextB { await cleanupContext(contextB) }
                    if let contextA { await cleanupContext(contextA) }
                    WindowStatesManager.shared.unregisterWindowState(windowB)
                    WindowStatesManager.shared.unregisterWindowState(windowA)
                    try? FileManager.default.removeItem(at: rootURL)
                }
                throw error
            }
        }

        func endpointA() throws -> PersistentMCPTestEndpoint {
            try XCTUnwrap(primaryPersistentMCPTestEndpoint)
        }

        func cleanup() async {
            guard !cleanedUp else { return }
            cleanedUp = true
            for endpoint in [primaryPersistentMCPTestEndpoint].compactMap(\.self) {
                endpoint.client.close()
                await endpoint.connectionManager.stop()
                await networkManager.debugRemoveConnection(endpoint.connectionID)
                await networkManager.clearClientConnectionPolicy(for: endpoint.clientName)
                await networkManager.debugClearPersistedRoutingState(for: endpoint.clientName)
                contextA.window.mcpServer.removeTabContext(
                    forConnectionID: endpoint.connectionID,
                    clientName: endpoint.clientName,
                    windowID: nil,
                    runID: nil
                )
                contextB.window.mcpServer.removeTabContext(
                    forConnectionID: endpoint.connectionID,
                    clientName: endpoint.clientName,
                    windowID: nil,
                    runID: nil
                )
            }
            await contextB.window.tearDown()
            await contextA.window.tearDown()
            await contextA.window.mcpServer.shutdownListener()
            await AppDomainRuntimeComposition.shared.unregister(contextB.catalogService)
            await AppDomainRuntimeComposition.shared.unregister(contextA.catalogService)
            await contextB.window.workspaceFileContextStore.unloadRoot(id: contextB.rootID)
            await contextA.window.workspaceFileContextStore.unloadRoot(id: contextA.rootID)
            contextB.window.workspaceManager.workspaces.removeAll { $0.id == contextB.workspaceID }
            contextA.window.workspaceManager.workspaces.removeAll { $0.id == contextA.workspaceID }
            WindowStatesManager.shared.unregisterWindowState(contextB.window)
            WindowStatesManager.shared.unregisterWindowState(contextA.window)
            try? FileManager.default.removeItem(at: rootURL)
        }

        func assertCleanedUp() async throws {
            for endpoint in try [endpointA()] {
                let hasInFlightCalls = await networkManager.hasInFlightCalls(for: endpoint.connectionID)
                let selectedWindow = await networkManager.selectedWindow(for: endpoint.connectionID)
                XCTAssertFalse(hasInFlightCalls)
                XCTAssertNil(selectedWindow)
                let policy = await networkManager.debugConnectionPolicyState(for: endpoint.connectionID)
                XCTAssertTrue(policy.restrictedTools.isEmpty)
                XCTAssertTrue(policy.additionalTools.isEmpty)
                XCTAssertEqual(policy.purpose, .unknown)
                XCTAssertNil(policy.windowID)
                let pendingPolicies = await networkManager.debugPendingPolicySnapshot(for: endpoint.clientName)
                XCTAssertTrue(pendingPolicies.isEmpty)
                XCTAssertEqual(contextA.window.mcpServer.connectionBindingSnapshot(forConnection: endpoint.connectionID).bindingKind, .unbound)
                XCTAssertEqual(contextB.window.mcpServer.connectionBindingSnapshot(forConnection: endpoint.connectionID).bindingKind, .unbound)
                do {
                    _ = try await endpoint.client.request(method: "tools/list", params: [:])
                    XCTFail("closed socket unexpectedly accepted a request")
                } catch PersistentMCPTestSocketClient.ClientError.closed {
                    // Expected.
                } catch {
                    XCTFail("closed socket failed with unexpected error: \(error)")
                }
            }
        }

        private static func makeContext(
            rootURL: URL,
            fileName: String,
            sentinel: String,
            tabID: UUID,
            window: WindowState,
            label: String
        ) async throws -> PersistentMCPTestContext {
            let sourceDirectory = rootURL.appendingPathComponent("Sources", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let fileURL = sourceDirectory.appendingPathComponent(fileName)
            try "\(sentinel)\n".write(to: fileURL, atomically: true, encoding: .utf8)
            var configuredWorkspace = WorkspaceModel(
                name: "Distinct MCP Connection \(label)",
                repoPaths: [rootURL.path]
            )
            configuredWorkspace.isEphemeral = true
            configuredWorkspace.composeTabs = [
                ComposeTabState(id: tabID, name: "Distinct MCP Connection \(label)")
            ]
            configuredWorkspace.activeComposeTabID = tabID
            window.workspaceManager.workspaces.append(configuredWorkspace)
            let rootRecord = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: rootURL.path
            )
            let exactHit = await WorkspaceReadableFileService(store: window.workspaceFileContextStore)
                .resolveExactAbsoluteWorkspaceCatalogHit(fileURL.path, rootScope: .visibleWorkspace)
            guard exactHit?.standardizedFullPath == fileURL.path else {
                throw ClientFixtureError.exactAbsoluteCatalogMiss
            }
            let catalogService = window.mcpServer.windowMCPToolCatalogService
            try await AppDomainRuntimeComposition.shared.register(catalogService)
            return PersistentMCPTestContext(
                rootURL: rootURL,
                fileURL: fileURL,
                rootID: rootRecord.id,
                window: window,
                workspaceID: configuredWorkspace.id,
                tabID: tabID,
                sentinel: sentinel,
                catalogService: catalogService
            )
        }

        private static func ensureRequiredCatalogAndEnableTransport(
            contexts: [PersistentMCPTestContext]
        ) async throws {
            let snapshot = await AppDomainRuntimeComposition.shared.catalogSnapshot()
            let globalsReady = MCPGlobalToolName.orderedToolNames.allSatisfy { toolName in
                snapshot.activeScopesByToolName[toolName]?.contains(.application) == true
            }
            let windowsReady = contexts.allSatisfy { context in
                let scope = MCPDomainToolRegistrationScope.window(id: context.window.windowID)
                return MCPAppToolGroup.orderedToolNames.allSatisfy { toolName in
                    snapshot.activeScopesByToolName[toolName]?.contains(scope) == true
                }
            }
            guard globalsReady, windowsReady else {
                throw ClientFixtureError.routingServiceUnavailable
            }

            // Direct socketpair requests require advertisement even after an earlier
            // fixture performed full shutdown. The enclosing shared-server lease records
            // and restores the inherited transport state; this fixture never owns global
            // registration handles.
            await ServerNetworkManager.shared.setEnabled(true)
        }

        func registerDomainWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            try await registerDomainWorkspace(
                workspace,
                rootURL: context.rootURL,
                windowID: context.window.windowID
            )
        }

        func registerDomainWorkspace(
            _ workspace: WorkspaceModel,
            rootURL: URL,
            windowID: Int
        ) async throws {
            let client = DomainWorkspaceAuthorityClient(
                store: AppDomainRuntimeComposition.shared.runtime.workspaceStore,
                windowID: windowID
            )
            _ = try await client.registerForRead(
                workspace,
                fileURL: rootURL.appendingPathComponent("fixture.repoprompt-workspace")
            )
        }

        private static func cleanupContext(_ context: PersistentMCPTestContext) async {
            await AppDomainRuntimeComposition.shared.unregister(context.catalogService)
            await context.window.workspaceFileContextStore.unloadRoot(id: context.rootID)
            context.window.workspaceManager.workspaces.removeAll { $0.id == context.workspaceID }
            try? FileManager.default.removeItem(at: context.rootURL)
        }
    }

    @MainActor
    final class PersistentMCPTestContext {
        let rootURL: URL
        let fileURL: URL
        let rootID: UUID
        let window: WindowState
        let workspaceID: UUID
        let tabID: UUID
        let sentinel: String
        let catalogService: MCPAppToolCatalogRegistration

        init(
            rootURL: URL,
            fileURL: URL,
            rootID: UUID,
            window: WindowState,
            workspaceID: UUID,
            tabID: UUID,
            sentinel: String,
            catalogService: MCPAppToolCatalogRegistration
        ) {
            self.rootURL = rootURL
            self.fileURL = fileURL
            self.rootID = rootID
            self.window = window
            self.workspaceID = workspaceID
            self.tabID = tabID
            self.sentinel = sentinel
            self.catalogService = catalogService
        }
    }

    final class PersistentMCPTestEndpoint: @unchecked Sendable {
        let connectionID: UUID
        let clientName: String
        let client: PersistentMCPTestSocketClient
        let connectionManager: BootstrapSocketConnectionManager

        private init(
            connectionID: UUID,
            clientName: String,
            client: PersistentMCPTestSocketClient,
            connectionManager: BootstrapSocketConnectionManager
        ) {
            self.connectionID = connectionID
            self.clientName = clientName
            self.client = client
            self.connectionManager = connectionManager
        }

        static func make(
            label: String,
            networkManager: ServerNetworkManager,
            clientName overrideClientName: String? = nil,
            requiredToolNames: Set<String> = [
                MCPWindowToolName.readFile,
                MCPWindowToolName.search,
                "bind_context"
            ]
        ) async throws -> PersistentMCPTestEndpoint {
            let connectionID = UUID()
            let sessionToken = "persistent-mcp-distinct-\(label)-\(UUID().uuidString)"
            let clientName = overrideClientName ?? "persistent-mcp-distinct-\(label)-\(UUID().uuidString)"
            await networkManager.debugClearPersistedRoutingState(for: clientName)
            var socketFDs = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
                throw PersistentMCPTestSocketClient.ClientError.posix(operation: "socketpair", code: errno)
            }
            var noSigPipe: Int32 = 1
            guard Darwin.setsockopt(
                socketFDs[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            ) == 0 else {
                let code = errno
                Darwin.close(socketFDs[0])
                Darwin.close(socketFDs[1])
                throw PersistentMCPTestSocketClient.ClientError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
            }
            let client = PersistentMCPTestSocketClient(fd: socketFDs[0])
            let manager = try BootstrapSocketConnectionManager(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                observedKernelPeerPID: Int(getpid()),
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: false,
                connectedFD: socketFDs[1],
                parentManager: networkManager
            )
            let endpoint = PersistentMCPTestEndpoint(
                connectionID: connectionID,
                clientName: clientName,
                client: client,
                connectionManager: manager
            )
            await networkManager.debugRegisterConnectionForSocketFixture(
                connectionID: connectionID,
                connection: manager,
                clientName: clientName,
                sessionToken: sessionToken,
                bootstrapPeerPID: Int(getpid())
            )
            let startTask = Task {
                try await manager.start { clientInfo in
                    guard clientInfo.name == clientName else { return false }
                    _ = await networkManager.debugApplyPendingPolicy(
                        clientName: clientName,
                        connectionID: connectionID,
                        clientPid: Int(getpid()),
                        bootstrapClientName: clientInfo.name
                    )
                    return true
                }
            }
            do {
                let initialize = try await client.request(
                    method: "initialize",
                    params: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": clientName,
                            "version": "persistent-mcp-distinct-connection-concurrency-test"
                        ]
                    ]
                )
                _ = try MCPExportWatchdogIntegrationTests.responseObject(from: initialize)
                try await startTask.value
                try client.sendNotification(method: "notifications/initialized", params: [:])
                let tools = try await client.request(method: "tools/list", params: [:])
                let names = try Set(Self.toolNames(from: tools))
                let missing = requiredToolNames.subtracting(names)
                guard missing.isEmpty else {
                    throw ClientFixtureError.requiredToolsMissing(missing.sorted())
                }
                return endpoint
            } catch {
                startTask.cancel()
                client.close()
                await manager.stop()
                await networkManager.debugRemoveConnection(connectionID)
                await networkManager.debugClearPersistedRoutingState(for: clientName)
                _ = try? await startTask.value
                throw error
            }
        }

        func callTool(
            name: String,
            arguments: [String: Any],
            timeoutSeconds: Int = 10
        ) async throws -> PersistentMCPTestRPCResponse {
            try await client.request(
                method: "tools/call",
                params: [
                    "name": name,
                    "arguments": arguments
                ],
                timeoutSeconds: timeoutSeconds
            )
        }

        private static func toolNames(from response: PersistentMCPTestRPCResponse) throws -> [String] {
            let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.compactMap { $0["name"] as? String }
        }
    }

    struct PersistentMCPTestRPCResponse {
        let id: Int
        let rawJSON: String
    }

    final class PersistentMCPTestSocketClient: @unchecked Sendable {
        enum ClientError: Error {
            case closed
            case duplicateRequestID(Int)
            case invalidResponse
            case posix(operation: String, code: Int32)
            case timedOut(Int)
            case unexpectedResponseID(Int)
        }

        private let writeQueue = DispatchQueue(label: "PersistentMCPDistinctConnectionConcurrencyTests.write")
        private let readQueue = DispatchQueue(label: "PersistentMCPDistinctConnectionConcurrencyTests.read")
        private let stateLock = NSLock()
        private var fd: Int32
        private var nextRequestID = 1
        private struct InterceptingResponse {
            let continuation: CheckedContinuation<String, Error>
            var task: Task<Void, Never>?
        }

        private var pending: [Int: CheckedContinuation<String, Error>] = [:]
        private var timeoutTasks: [Int: Task<Void, Never>] = [:]
        private var responseInterceptors: [Int: @Sendable (String) async throws -> String] = [:]
        private var interceptingResponses: [Int: InterceptingResponse] = [:]
        private var isClosed = false

        init(fd: Int32) {
            self.fd = fd
            readQueue.async { [weak self] in
                self?.readerLoop()
            }
        }

        deinit {
            close()
        }

        func close() {
            close(with: ClientError.closed)
        }

        func nextRequestIDForTesting() -> Int {
            withStateLock { nextRequestID }
        }

        func installResponseInterceptor(
            for requestID: Int,
            interceptor: @escaping @Sendable (String) async throws -> String
        ) {
            withStateLock {
                responseInterceptors[requestID] = interceptor
            }
        }

        func sendNotification(method: String, params: [String: Any]) throws {
            try sendJSON([
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ])
        }

        func request(method: String, params: [String: Any], timeoutSeconds: Int = 10) async throws -> PersistentMCPTestRPCResponse {
            let id = allocateRequestID()
            let rawJSON = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    var registered = false
                    do {
                        let timeoutTask = Task { [weak self] in
                            do {
                                try await Task.sleep(for: .seconds(timeoutSeconds))
                                guard !Task.isCancelled else { return }
                                self?.failRequest(id: id, error: ClientError.timedOut(id))
                            } catch is CancellationError {
                                return
                            } catch {
                                return
                            }
                        }
                        do {
                            try register(continuation, timeoutTask: timeoutTask, for: id)
                            registered = true
                            try Task.checkCancellation()
                            try sendJSON([
                                "jsonrpc": "2.0",
                                "id": id,
                                "method": method,
                                "params": params
                            ])
                        } catch {
                            timeoutTask.cancel()
                            throw error
                        }
                    } catch {
                        if registered {
                            // Once registered, only the pending map owns the resume; if
                            // failPending finds nothing, close() already resumed it.
                            failPending(id: id, error: error)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                self.failRequest(id: id, error: CancellationError())
            }
            return PersistentMCPTestRPCResponse(id: id, rawJSON: rawJSON)
        }

        private func allocateRequestID() -> Int {
            withStateLock {
                defer { nextRequestID += 1 }
                return nextRequestID
            }
        }

        private func register(
            _ continuation: CheckedContinuation<String, Error>,
            timeoutTask: Task<Void, Never>,
            for id: Int
        ) throws {
            try withStateLock {
                guard !isClosed, fd >= 0 else { throw ClientError.closed }
                guard pending[id] == nil else { throw ClientError.duplicateRequestID(id) }
                pending[id] = continuation
                timeoutTasks[id] = timeoutTask
            }
        }

        private func sendJSON(_ object: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            line.append(0x0A)
            try writeQueue.sync {
                var written = 0
                while written < line.count {
                    let activeFD = withStateLock { isClosed ? -1 : fd }
                    guard activeFD >= 0 else { throw ClientError.closed }
                    let result = line.withUnsafeBytes { bytes in
                        Darwin.write(activeFD, bytes.baseAddress?.advanced(by: written), line.count - written)
                    }
                    if result > 0 {
                        written += result
                        continue
                    }
                    if result < 0, errno == EINTR { continue }
                    throw ClientError.posix(operation: "write", code: errno)
                }
            }
        }

        private func readerLoop() {
            var buffer = Data()
            while true {
                let activeFD = withStateLock { isClosed ? -1 : fd }
                guard activeFD >= 0 else { return }
                var descriptor = pollfd(fd: activeFD, events: Int16(POLLIN), revents: 0)
                let pollResult = Darwin.poll(&descriptor, 1, 100)
                if pollResult == 0 {
                    if withStateLock({ isClosed }) { return }
                    continue
                }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    if withStateLock({ isClosed }) { return }
                    close(with: ClientError.posix(operation: "poll", code: errno))
                    return
                }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0,
                   descriptor.revents & Int16(POLLIN) == 0
                {
                    close(with: ClientError.closed)
                    return
                }
                if withStateLock({ isClosed }) { return }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let readCount = bytes.withUnsafeMutableBytes { storage in
                    Darwin.read(activeFD, storage.baseAddress, storage.count)
                }
                if readCount > 0 {
                    buffer.append(contentsOf: bytes.prefix(readCount))
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(buffer.startIndex ... newline)
                        guard handle(line) else { return }
                    }
                    continue
                }
                if readCount == 0 {
                    close(with: ClientError.closed)
                    return
                }
                if errno == EINTR { continue }
                if withStateLock({ isClosed }) { return }
                close(with: ClientError.posix(operation: "read", code: errno))
                return
            }
        }

        private func handle(_ line: Data) -> Bool {
            do {
                let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                guard let object else { throw ClientError.invalidResponse }
                if let rawID = object["id"] {
                    guard let id = (rawID as? NSNumber)?.intValue else { throw ClientError.invalidResponse }
                    let pendingResponse = takePendingResponse(id: id)
                    guard let continuation = pendingResponse.continuation else {
                        throw ClientError.unexpectedResponseID(id)
                    }
                    guard let rawJSON = String(data: line, encoding: .utf8) else { throw ClientError.invalidResponse }
                    guard let interceptor = pendingResponse.interceptor else {
                        continuation.resume(returning: rawJSON)
                        return true
                    }
                    guard pendingResponse.isIntercepting else {
                        continuation.resume(throwing: ClientError.closed)
                        return false
                    }
                    let task = Task { [weak self] in
                        do {
                            let intercepted = try await interceptor(rawJSON)
                            _ = self?.completeIntercepting(id: id, returning: intercepted)
                        } catch {
                            if self?.failIntercepting(id: id, error: error) == true {
                                self?.close(with: error)
                            }
                        }
                    }
                    installInterceptingTask(id: id, task: task)
                    return true
                }
                guard object["method"] as? String != nil else {
                    throw ClientError.invalidResponse
                }
                return true
            } catch {
                close(with: error)
                return false
            }
        }

        private func takePending(id: Int) -> CheckedContinuation<String, Error>? {
            let snapshot = withStateLock {
                let continuation = pending.removeValue(forKey: id)
                responseInterceptors.removeValue(forKey: id)
                let timeoutTask = continuation == nil ? nil : timeoutTasks.removeValue(forKey: id)
                return (continuation, timeoutTask)
            }
            snapshot.1?.cancel()
            return snapshot.0
        }

        private func installInterceptingTask(id: Int, task: Task<Void, Never>) {
            let shouldCancelTask = withStateLock {
                guard var response = interceptingResponses[id] else { return true }
                response.task = task
                interceptingResponses[id] = response
                return false
            }
            if shouldCancelTask { task.cancel() }
        }

        private func takeIntercepting(
            id: Int,
            cancelInterceptorTask: Bool
        ) -> InterceptingResponse? {
            let snapshot = withStateLock {
                let response = interceptingResponses.removeValue(forKey: id)
                let timeoutTask = response == nil ? nil : timeoutTasks.removeValue(forKey: id)
                let interceptorTask = cancelInterceptorTask ? response?.task : nil
                return (response, timeoutTask, interceptorTask)
            }
            snapshot.1?.cancel()
            snapshot.2?.cancel()
            return snapshot.0
        }

        private func takePendingResponse(
            id: Int
        ) -> (
            continuation: CheckedContinuation<String, Error>?,
            interceptor: (@Sendable (String) async throws -> String)?,
            isIntercepting: Bool
        ) {
            let snapshot = withStateLock {
                let continuation = pending.removeValue(forKey: id)
                let interceptor = responseInterceptors.removeValue(forKey: id)
                let isIntercepting = continuation != nil && interceptor != nil && !isClosed
                if isIntercepting, let continuation {
                    interceptingResponses[id] = InterceptingResponse(continuation: continuation)
                }
                let timeoutTask = isIntercepting ? nil : timeoutTasks.removeValue(forKey: id)
                return (continuation, interceptor, isIntercepting, timeoutTask)
            }
            snapshot.3?.cancel()
            return (snapshot.0, snapshot.1, snapshot.2)
        }

        @discardableResult
        private func failPending(id: Int, error: Error) -> Bool {
            guard let continuation = takePending(id: id) else { return false }
            continuation.resume(throwing: error)
            return true
        }

        @discardableResult
        private func completeIntercepting(id: Int, returning rawJSON: String) -> Bool {
            guard let response = takeIntercepting(id: id, cancelInterceptorTask: false) else { return false }
            response.continuation.resume(returning: rawJSON)
            return true
        }

        @discardableResult
        private func failIntercepting(id: Int, error: Error) -> Bool {
            guard let response = takeIntercepting(id: id, cancelInterceptorTask: true) else { return false }
            response.continuation.resume(throwing: error)
            return true
        }

        @discardableResult
        private func failRequest(id: Int, error: Error) -> Bool {
            if failPending(id: id, error: error) { return true }
            return failIntercepting(id: id, error: error)
        }

        private func close(with error: Error) {
            let snapshot: (
                activeFD: Int32,
                pendingContinuations: [CheckedContinuation<String, Error>],
                interceptingContinuations: [CheckedContinuation<String, Error>],
                tasks: [Task<Void, Never>]
            ) = withStateLock {
                guard !isClosed else { return (-1, [], [], []) }
                isClosed = true
                let activeFD = fd
                fd = -1
                let pendingContinuations = Array(pending.values)
                let intercepting = Array(interceptingResponses.values)
                let interceptorTasks = intercepting.compactMap { response -> Task<Void, Never>? in
                    response.task
                }
                let tasks = Array(timeoutTasks.values) + interceptorTasks
                pending.removeAll()
                timeoutTasks.removeAll()
                responseInterceptors.removeAll()
                interceptingResponses.removeAll()
                let interceptingContinuations = intercepting.map { response -> CheckedContinuation<String, Error> in
                    response.continuation
                }
                return (activeFD, pendingContinuations, interceptingContinuations, tasks)
            }
            if snapshot.activeFD >= 0 { Darwin.close(snapshot.activeFD) }
            snapshot.tasks.forEach { $0.cancel() }
            for continuation in snapshot.pendingContinuations + snapshot.interceptingContinuations {
                continuation.resume(throwing: error)
            }
        }

        private func withStateLock<T>(_ operation: () throws -> T) rethrows -> T {
            stateLock.lock()
            defer { stateLock.unlock() }
            return try operation()
        }
    }

    private enum ClientFixtureError: Error {
        case exactAbsoluteCatalogMiss
        case requiredToolsMissing([String])
        case routingServiceUnavailable
    }

#endif
