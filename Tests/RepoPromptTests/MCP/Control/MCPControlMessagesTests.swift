import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

final class MCPControlMessagesTests: XCTestCase {
    func testControlNotificationsRoundTripWireFormats() throws {
        do {
            let caseLabel = "testTerminateNotificationJSONLineRoundTrips"
            let requestedAt = Date(timeIntervalSince1970: 0)
            let notification = RepoPromptControlNotification(
                method: RepoPromptControlMethod.terminate,
                params: RepoPromptTerminateParams(
                    reason: .userBootFromDashboard,
                    message: "Booted from dashboard",
                    requestedAt: requestedAt
                )
            )

            let data = try XCTUnwrap(notification.encodedJSONLine(), caseLabel)
            XCTAssertEqual(data.last, 10, caseLabel + ": encodedJSONLine() must preserve the trailing newline transport delimiter")
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("repoprompt/control/terminate"), caseLabel)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("repoprompt\\/control\\/terminate"), caseLabel)

            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], caseLabel)
            XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0", caseLabel)
            XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.terminate, caseLabel)
            XCTAssertNil(envelope["id"], caseLabel + ": Control messages are JSON-RPC notifications, not requests")

            let parsed = try XCTUnwrap(RepoPromptControlDetection.parseTerminateParams(from: data), caseLabel)
            XCTAssertEqual(parsed.reason, .userBootFromDashboard, caseLabel)
            XCTAssertEqual(parsed.message, "Booted from dashboard", caseLabel)
            XCTAssertEqual(parsed.requestedAt, requestedAt, caseLabel)
        }

        do {
            let caseLabel = "testRunCompletedNotificationJSONLineRoundTrips"
            let completedAt = Date(timeIntervalSince1970: 0)
            let notification = RepoPromptControlNotification(
                method: RepoPromptControlMethod.runCompleted,
                params: RepoPromptRunCompletedParams(
                    runType: "context_builder",
                    success: true,
                    summary: "Done",
                    completedAt: completedAt
                )
            )

            let data = try XCTUnwrap(notification.encodedJSONLine(), caseLabel)
            XCTAssertEqual(data.last, 10, caseLabel)

            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], caseLabel)
            XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0", caseLabel)
            XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.runCompleted, caseLabel)
            XCTAssertNil(envelope["id"], caseLabel)

            let parsed = try XCTUnwrap(RepoPromptControlDetection.parseRunCompletedParams(from: data), caseLabel)
            XCTAssertEqual(parsed.runType, "context_builder", caseLabel)
            XCTAssertTrue(parsed.success, caseLabel)
            XCTAssertEqual(parsed.summary, "Done", caseLabel)
            XCTAssertEqual(parsed.completedAt, completedAt, caseLabel)
        }

        do {
            let caseLabel = "testProgressNotificationJSONLineRoundTripsWithStringDate"
            let emittedAt = Date(timeIntervalSince1970: 0)
            let notification = RepoPromptControlNotification(
                method: RepoPromptControlMethod.progress,
                params: RepoPromptProgressParams(
                    tool: "context_builder",
                    kind: .stage,
                    stage: "planning",
                    message: "Planning response",
                    emittedAt: emittedAt
                )
            )

            let data = try XCTUnwrap(notification.encodedJSONLine(), caseLabel)
            XCTAssertEqual(data.last, 10, caseLabel)

            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], caseLabel)
            XCTAssertEqual(envelope["jsonrpc"] as? String, "2.0", caseLabel)
            XCTAssertEqual(envelope["method"] as? String, RepoPromptControlMethod.progress, caseLabel)
            XCTAssertNil(envelope["id"], caseLabel)
            let params = try XCTUnwrap(envelope["params"] as? [String: Any], caseLabel)
            XCTAssertEqual(params["emittedAt"] as? String, "1970-01-01T00:00:00Z", caseLabel)

            let parsed = try XCTUnwrap(RepoPromptControlDetection.parseProgressParams(from: data), caseLabel)
            XCTAssertEqual(parsed.tool, "context_builder", caseLabel)
            XCTAssertEqual(parsed.kind, .stage, caseLabel)
            XCTAssertEqual(parsed.stage, "planning", caseLabel)
            XCTAssertEqual(parsed.message, "Planning response", caseLabel)
            XCTAssertEqual(parsed.emittedAt, "1970-01-01T00:00:00Z", caseLabel)
        }
    }

    func testKillSignalPayloadPathAndJSONRoundTrip() throws {
        let directory = URL(fileURLWithPath: "/tmp/MCPKillSignals-CE-D-7", isDirectory: true)
        let url = MCPKillSignal.signalFileURL(forSessionToken: "session-token", directory: directory)
        XCTAssertEqual(url.path, "/tmp/MCPKillSignals-CE-D-7/session-token.kill")

        let killedAt = Date(timeIntervalSince1970: 0)
        let content = MCPKillSignal.SignalContent(
            reason: .runCancelled,
            message: "Cancelled by user",
            killedAt: killedAt
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(content)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["reason"] as? String, TerminationReason.runCancelled.rawValue)
        XCTAssertEqual(object["message"] as? String, "Cancelled by user")
        XCTAssertEqual(object["killedAt"] as? String, "1970-01-01T00:00:00Z")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MCPKillSignal.SignalContent.self, from: data)
        XCTAssertEqual(decoded.reason, .runCancelled)
        XCTAssertEqual(decoded.message, "Cancelled by user")
        XCTAssertEqual(decoded.killedAt, killedAt)
    }

    #if DEBUG
        func testSDKProgressTokensRoundTripThroughCallAndNotificationParameters() throws {
            for token in [ProgressToken.string("request-token"), .integer(42)] {
                let call = CallTool.Parameters(
                    name: "context_builder",
                    arguments: ["instructions": .string("inspect")],
                    meta: Metadata(progressToken: token)
                )
                let callData = try JSONEncoder().encode(call)
                let decodedCall = try JSONDecoder().decode(CallTool.Parameters.self, from: callData)
                XCTAssertEqual(decodedCall._meta?.progressToken, token)

                let notification = ProgressNotification.Parameters(
                    progressToken: decodedCall._meta?.progressToken ?? token,
                    progress: 1,
                    message: "starting"
                )
                let notificationData = try JSONEncoder().encode(notification)
                let decodedNotification = try JSONDecoder().decode(
                    ProgressNotification.Parameters.self,
                    from: notificationData
                )
                XCTAssertEqual(decodedNotification.progressToken, token)
                XCTAssertEqual(decodedNotification.progress, 1)
                XCTAssertNil(decodedNotification.total)
            }
        }

        func testStandardMCPProgressUsesRequestTokenWithoutDuplicatingCLIControlFallback() async {
            let manager = ServerNetworkManager()
            let standardConnectionID = UUID()
            let standardDeliveryGate = ProgressDeliveryGate(blockedDeliveries: [1])
            let standardConnection = ProgressRecordingMCPConnection(deliveryGate: standardDeliveryGate)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: standardConnectionID,
                connection: standardConnection,
                pendingClientID: "Generic MCP host"
            )

            let progressState = MCPRequestProgressState(token: .string("context-builder-request"))
            await ServerNetworkManager.withConnectionID(
                standardConnectionID,
                progressState: progressState
            ) {
                await manager.sendProgress(
                    for: standardConnectionID,
                    tool: "context_builder",
                    kind: .stage,
                    stage: "discovering",
                    message: "Running Context Builder agent..."
                )
                await standardDeliveryGate.waitUntilDeliveryStarts(1)
                await ServerNetworkManager.withConnectionID(standardConnectionID) {
                    await manager.sendProgress(
                        for: standardConnectionID,
                        tool: "context_builder",
                        kind: .heartbeat,
                        stage: "discovering",
                        message: "Still building context..."
                    )
                }
                await standardDeliveryGate.releaseDelivery(1)
            }

            await progressState.waitUntilQuiescent()
            let standardEvents = await standardConnection.standardEvents()
            XCTAssertEqual(standardEvents.map(\.token), [
                .string("context-builder-request"),
                .string("context-builder-request")
            ])
            XCTAssertEqual(standardEvents.map(\.progress), [1, 2])
            XCTAssertTrue(standardEvents[0].message?.contains("context_builder [discovering]") == true)
            let standardControlEvents = await standardConnection.controlEvents()
            XCTAssertTrue(standardControlEvents.isEmpty)
            await manager.debugRemoveConnection(standardConnectionID)

            let tokenBearingCLIConnectionID = UUID()
            let tokenBearingCLIConnection = ProgressRecordingMCPConnection()
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: tokenBearingCLIConnectionID,
                connection: tokenBearingCLIConnection,
                pendingClientID: "RepoPrompt CLI (standard progress test)"
            )

            let cliProgressState = MCPRequestProgressState(token: .integer(510))
            await ServerNetworkManager.withConnectionID(
                tokenBearingCLIConnectionID,
                progressState: cliProgressState
            ) {
                await manager.sendProgress(
                    for: tokenBearingCLIConnectionID,
                    tool: "context_builder",
                    kind: .stage,
                    stage: "discovering",
                    message: "Waiting for child MCP routing"
                )
            }

            await cliProgressState.waitUntilQuiescent()
            let cliStandardEvents = await tokenBearingCLIConnection.standardEvents()
            XCTAssertEqual(cliStandardEvents.map(\.token), [.integer(510)])
            XCTAssertEqual(cliStandardEvents.map(\.progress), [1])
            let cliControlEvents = await tokenBearingCLIConnection.controlEvents()
            XCTAssertTrue(cliControlEvents.isEmpty, "standard progress must not duplicate legacy CLI control progress")
            await manager.debugRemoveConnection(tokenBearingCLIConnectionID)

            let compatibilityConnectionID = UUID()
            let compatibilityConnection = ProgressRecordingMCPConnection()
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: compatibilityConnectionID,
                connection: compatibilityConnection,
                pendingClientID: "RepoPrompt CLI (compatibility test)"
            )

            await ServerNetworkManager.withConnectionID(compatibilityConnectionID) {
                await manager.sendProgress(
                    for: compatibilityConnectionID,
                    tool: "context_builder",
                    kind: .stage,
                    stage: "starting",
                    message: "Starting context builder..."
                )
            }

            let compatibilityStandardEvents = await compatibilityConnection.standardEvents()
            XCTAssertTrue(compatibilityStandardEvents.isEmpty)
            let controlEvents = await compatibilityConnection.controlEvents()
            XCTAssertEqual(controlEvents.count, 1)
            XCTAssertEqual(controlEvents.first?.tool, "context_builder")
            XCTAssertEqual(controlEvents.first?.stage, "starting")
            await manager.debugRemoveConnection(compatibilityConnectionID)
        }

        func testStandardMCPProgressCoalescesOnePendingUpdateInWireOrder() async {
            let deliveryGate = ProgressDeliveryGate(blockedDeliveries: [1])
            let connection = ProgressRecordingMCPConnection(deliveryGate: deliveryGate)
            let progressState = MCPRequestProgressState(token: .string("coalesced-request"))

            await progressState.send(through: connection, message: "first")
            await deliveryGate.waitUntilDeliveryStarts(1)
            for index in 2 ... 10 {
                await progressState.send(through: connection, message: "update-\(index)")
            }

            let blockedSnapshot = await progressState.snapshot()
            XCTAssertEqual(blockedSnapshot.pendingDeliveryCount, 1)
            XCTAssertTrue(blockedSnapshot.workerActive)
            XCTAssertEqual(blockedSnapshot.assignedSequence, 1)

            await deliveryGate.releaseDelivery(1)
            await progressState.waitUntilQuiescent()

            let events = await connection.standardEvents()
            XCTAssertEqual(events.map(\.token), [.string("coalesced-request"), .string("coalesced-request")])
            XCTAssertEqual(events.map(\.progress), [1, 2])
            XCTAssertEqual(events.compactMap(\.message), ["first", "update-10"])
            let lifecycle = await deliveryGate.lifecycle()
            XCTAssertEqual(lifecycle, [.started(1), .completed(1), .started(2), .completed(2)])
        }

        func testStandardMCPProgressFinalizationDropsPendingWithoutWaitingForInFlightDelivery() async {
            let deliveryGate = ProgressDeliveryGate(blockedDeliveries: [1])
            let connection = ProgressRecordingMCPConnection(deliveryGate: deliveryGate)
            let progressState = MCPRequestProgressState(token: .string("finalized-request"))

            await progressState.send(through: connection, message: "in-flight")
            await deliveryGate.waitUntilDeliveryStarts(1)
            for index in 2 ... 20 {
                await progressState.send(through: connection, message: "pending-\(index)")
            }
            let pendingSnapshot = await progressState.snapshot()
            XCTAssertEqual(pendingSnapshot.pendingDeliveryCount, 1)

            // This call must return while delivery 1 remains blocked. Finalization
            // cooperatively drops the pending update without cancelling the write.
            await progressState.invalidate()
            let finalizedSnapshot = await progressState.snapshot()
            XCTAssertFalse(finalizedSnapshot.acceptsProgress)
            XCTAssertEqual(finalizedSnapshot.pendingDeliveryCount, 0)
            XCTAssertTrue(finalizedSnapshot.workerActive)

            await progressState.send(through: connection, message: "after-finalization")
            await deliveryGate.releaseDelivery(1)
            await progressState.waitUntilQuiescent()

            let events = await connection.standardEvents()
            XCTAssertEqual(events.map(\.progress), [1])
            XCTAssertEqual(events.compactMap(\.message), ["in-flight"])
        }

        func testStandardMCPProgressConnectionTerminalFailureDropsPendingAndStopsWorker() async {
            let deliveryGate = ProgressDeliveryGate(blockedDeliveries: [1])
            let connection = ProgressRecordingMCPConnection(
                deliveryGate: deliveryGate,
                deliveryResults: [.connectionTerminal]
            )
            let progressState = MCPRequestProgressState(token: .string("closed-connection"))

            await progressState.send(through: connection, message: "terminal-attempt")
            await deliveryGate.waitUntilDeliveryStarts(1)
            await progressState.send(through: connection, message: "must-be-dropped")
            let pendingSnapshot = await progressState.snapshot()
            XCTAssertEqual(pendingSnapshot.pendingDeliveryCount, 1)

            await deliveryGate.releaseDelivery(1)
            await progressState.waitUntilQuiescent()
            let terminalSnapshot = await progressState.snapshot()
            XCTAssertFalse(terminalSnapshot.acceptsProgress)
            XCTAssertEqual(terminalSnapshot.pendingDeliveryCount, 0)
            XCTAssertFalse(terminalSnapshot.workerActive)

            await progressState.send(through: connection, message: "after-close")
            let events = await connection.standardEvents()
            XCTAssertEqual(events.map(\.progress), [1])
        }
    #endif
}

#if DEBUG
    private actor ProgressRecordingMCPConnection: MCPServerConnection {
        struct StandardEvent {
            let token: ProgressToken
            let progress: Double
            let message: String?
        }

        struct ControlEvent {
            let tool: String
            let kind: RepoPromptProgressKind
            let stage: String
            let message: String
        }

        private var recordedStandardEvents: [StandardEvent] = []
        private var recordedControlEvents: [ControlEvent] = []
        private let deliveryGate: ProgressDeliveryGate?
        private var deliveryResults: [MCPProgressDeliveryResult]

        init(
            deliveryGate: ProgressDeliveryGate? = nil,
            deliveryResults: [MCPProgressDeliveryResult] = []
        ) {
            self.deliveryGate = deliveryGate
            self.deliveryResults = deliveryResults
        }

        nonisolated var isFilesystemBacked: Bool {
            false
        }

        nonisolated var connectionFolderURL: URL? {
            nil
        }

        nonisolated var capabilityToken: String? {
            nil
        }

        func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
        func stop() async {}
        func abortForExecutionWatchdog() async {}
        func notifyToolListChanged() async {}
        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            0
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}

        func sendProgress(
            tool: String,
            kind: RepoPromptProgressKind,
            stage: String,
            message: String
        ) async {
            recordedControlEvents.append(ControlEvent(
                tool: tool,
                kind: kind,
                stage: stage,
                message: message
            ))
        }

        func sendMCPProgress(
            token: ProgressToken,
            progress: Double,
            message: String?
        ) async {
            _ = await deliverMCPProgress(token: token, progress: progress, message: message)
        }

        func deliverMCPProgress(
            token: ProgressToken,
            progress: Double,
            message: String?
        ) async -> MCPProgressDeliveryResult {
            await deliveryGate?.beginDelivery(progress)
            recordedStandardEvents.append(StandardEvent(
                token: token,
                progress: progress,
                message: message
            ))
            return deliveryResults.isEmpty ? .delivered : deliveryResults.removeFirst()
        }

        func standardEvents() -> [StandardEvent] {
            recordedStandardEvents
        }

        func controlEvents() -> [ControlEvent] {
            recordedControlEvents
        }
    }

    private actor ProgressDeliveryGate {
        enum Lifecycle: Equatable {
            case started(Double)
            case completed(Double)
        }

        private let blockedDeliveries: Set<Double>
        private var startedDeliveries: Set<Double> = []
        private var releasedDeliveries: Set<Double> = []
        private var startWaiters: [Double: [CheckedContinuation<Void, Never>]] = [:]
        private var releaseWaiters: [Double: CheckedContinuation<Void, Never>] = [:]
        private var recordedLifecycle: [Lifecycle] = []

        init(blockedDeliveries: Set<Double> = []) {
            self.blockedDeliveries = blockedDeliveries
        }

        func beginDelivery(_ progress: Double) async {
            startedDeliveries.insert(progress)
            recordedLifecycle.append(.started(progress))
            let waiters = startWaiters.removeValue(forKey: progress) ?? []
            waiters.forEach { $0.resume() }

            if blockedDeliveries.contains(progress), !releasedDeliveries.contains(progress) {
                await withCheckedContinuation { continuation in
                    releaseWaiters[progress] = continuation
                }
            }
            recordedLifecycle.append(.completed(progress))
        }

        func waitUntilDeliveryStarts(_ progress: Double) async {
            guard !startedDeliveries.contains(progress) else { return }
            await withCheckedContinuation { continuation in
                startWaiters[progress, default: []].append(continuation)
            }
        }

        func releaseDelivery(_ progress: Double) {
            releasedDeliveries.insert(progress)
            releaseWaiters.removeValue(forKey: progress)?.resume()
        }

        func lifecycle() -> [Lifecycle] {
            recordedLifecycle
        }
    }
#endif
