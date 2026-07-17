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
            let standardConnection = ProgressRecordingMCPConnection()
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
                await ServerNetworkManager.withConnectionID(standardConnectionID) {
                    await manager.sendProgress(
                        for: standardConnectionID,
                        tool: "context_builder",
                        kind: .heartbeat,
                        stage: "discovering",
                        message: "Still building context..."
                    )
                }
            }

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

        func testStandardMCPProgressSerializesWireOrderAndStopsAfterRequestInvalidation() async {
            let manager = ServerNetworkManager()
            let connectionID = UUID()
            let deliveryGate = ProgressDeliveryGate()
            let connection = ProgressRecordingMCPConnection(deliveryGate: deliveryGate)
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: connection,
                pendingClientID: "Generic MCP host"
            )

            let progressState = MCPRequestProgressState(token: .string("serialized-request"))
            let emissions = Task {
                await ServerNetworkManager.withConnectionID(
                    connectionID,
                    progressState: progressState
                ) {
                    async let first: Void = manager.sendProgress(
                        for: connectionID,
                        tool: "context_builder",
                        kind: .stage,
                        stage: "discovering",
                        message: "first"
                    )
                    async let second: Void = manager.sendProgress(
                        for: connectionID,
                        tool: "context_builder",
                        kind: .heartbeat,
                        stage: "discovering",
                        message: "second"
                    )
                    await first
                    await second
                }
            }

            await deliveryGate.waitUntilFirstDeliveryBlocked()
            let invalidation = Task {
                await progressState.invalidateAndDrain()
            }
            await deliveryGate.releaseFirstDelivery()
            await emissions.value
            await invalidation.value

            await ServerNetworkManager.withConnectionID(
                connectionID,
                progressState: progressState
            ) {
                await manager.sendProgress(
                    for: connectionID,
                    tool: "context_builder",
                    kind: .stage,
                    stage: "complete",
                    message: "must not be delivered"
                )
            }

            let events = await connection.standardEvents()
            XCTAssertEqual(events.map(\.token), [
                .string("serialized-request"),
                .string("serialized-request")
            ])
            XCTAssertEqual(events.map(\.progress), [1, 2])
            XCTAssertFalse(events.contains { $0.message?.contains("must not be delivered") == true })
            await manager.debugRemoveConnection(connectionID)
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

        init(deliveryGate: ProgressDeliveryGate? = nil) {
            self.deliveryGate = deliveryGate
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
            if progress == 1 {
                await deliveryGate?.blockFirstDelivery()
            }
            recordedStandardEvents.append(StandardEvent(
                token: token,
                progress: progress,
                message: message
            ))
        }

        func standardEvents() -> [StandardEvent] {
            recordedStandardEvents
        }

        func controlEvents() -> [ControlEvent] {
            recordedControlEvents
        }
    }

    private actor ProgressDeliveryGate {
        private var blocked = false
        private var released = false
        private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func blockFirstDelivery() async {
            guard !released else { return }
            blocked = true
            let waiters = blockedWaiters
            blockedWaiters = []
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }

        func waitUntilFirstDeliveryBlocked() async {
            guard !blocked else { return }
            await withCheckedContinuation { continuation in
                blockedWaiters.append(continuation)
            }
        }

        func releaseFirstDelivery() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
#endif
