import Darwin
import Foundation
import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class PersistentMCPDistinctConnectionConcurrencyTests: XCTestCase {
    func testDistinctConnectionsOverlapWithoutCrossRoutingReadOrSearchResults() async throws {
        #if DEBUG
            let fixture = try await Fixture.make()
            do {
                try await runCheckpoint(fixture: fixture)
                await fixture.cleanup()
                try await fixture.assertCleanedUp()
            } catch {
                await fixture.cleanup()
                throw error
            }
        #else
            throw XCTSkip("Distinct MCP connection socketpair integration requires DEBUG diagnostics helpers.")
        #endif
    }

    func testClearPersistedRoutingSessionHiddenDispatchIsExactAndRestoresState() async throws {
        #if DEBUG
            let networkManager = ServerNetworkManager.shared
            let baseline = await networkManager.debugExactRoutingSessionFixtureState()
            let fixture = await networkManager.debugSeedExactRoutingSessionFixture()
            do {
                try await runExactRoutingSessionCleanupCheckpoint(networkManager: networkManager, fixture: fixture)
                await assertExactRoutingSessionFixtureRestored(networkManager: networkManager, fixture: fixture, baseline: baseline)
            } catch {
                await assertExactRoutingSessionFixtureRestored(networkManager: networkManager, fixture: fixture, baseline: baseline)
                throw error
            }
        #else
            throw XCTSkip("Exact persisted routing session cleanup diagnostics require DEBUG helpers.")
        #endif
    }

    func testRemoveConnectionSourceStillDropsPerConnectionLimiter() throws {
        let sourceURL = try RepoRoot.url()
            .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func removeConnection(_ id: UUID) async {"))
        let end = try XCTUnwrap(source.range(
            of: "/// Reads the cached TCP client name",
            range: start.upperBound ..< source.endIndex
        ))
        let body = String(source[start.lowerBound ..< end.lowerBound])
        XCTAssertTrue(body.contains("callLimiters[id] = nil"), body)
    }
}

#if DEBUG
    private extension PersistentMCPDistinctConnectionConcurrencyTests {
        func runCheckpoint(fixture: Fixture) async throws {
            let endpointA = try fixture.endpointA()
            let endpointB = try fixture.endpointB()

            let directCanonical = try await endpointA.callTool(
                name: MCPWindowToolName.readFile,
                arguments: [
                    "path": fixture.contextA.fileURL.path,
                    "context_id": fixture.contextA.tabID.uuidString
                ]
            )
            try Self.assertReadResult(
                directCanonical,
                contains: fixture.contextA.sentinel,
                excludes: fixture.contextB.sentinel
            )

            let directLegacy = try await endpointB.callTool(
                name: MCPWindowToolName.readFile,
                arguments: [
                    "path": fixture.contextB.fileURL.path,
                    "_tabID": fixture.contextB.tabID.uuidString
                ]
            )
            try Self.assertReadResult(
                directLegacy,
                contains: fixture.contextB.sentinel,
                excludes: fixture.contextA.sentinel
            )

            try await Self.bind(endpointA, to: fixture.contextA.tabID)
            try await Self.bind(endpointB, to: fixture.contextB.tabID)
            fixture.assertStableBindings()

            let baselineA = await fixture.snapshot(endpointA, context: fixture.contextA)
            let baselineB = await fixture.snapshot(endpointB, context: fixture.contextB)
            Self.assertStableSnapshot(baselineA, endpoint: endpointA, context: fixture.contextA)
            Self.assertStableSnapshot(baselineB, endpoint: endpointB, context: fixture.contextB)
            XCTAssertNotEqual(baselineA.connectionID, baselineB.connectionID)

            try await Self.assertPing(endpointA, tag: "before-a")
            try await Self.assertPing(endpointB, tag: "before-b")
            try await Self.assertRoutingSnapshot(endpointA, context: fixture.contextA)
            try await Self.assertRoutingSnapshot(endpointB, context: fixture.contextB)

            var sameConnectionMillis: [Double] = []
            var distinctConnectionMillis: [Double] = []
            for trial in 0 ..< 3 {
                try await sameConnectionMillis.append(Self.measureMilliseconds {
                    async let first = Self.sleep(endpointA, tag: "same-\(trial)-first")
                    async let second = Self.sleep(endpointA, tag: "same-\(trial)-second")
                    let responses = try await (first, second)
                    XCTAssertNotEqual(responses.0, responses.1)
                })
                try await distinctConnectionMillis.append(Self.measureMilliseconds {
                    async let first = Self.sleep(endpointA, tag: "distinct-\(trial)-a")
                    async let second = Self.sleep(endpointB, tag: "distinct-\(trial)-b")
                    _ = try await (first, second)
                })
            }
            let sameMedian = Self.median(sameConnectionMillis)
            let distinctMedian = Self.median(distinctConnectionMillis)
            XCTAssertGreaterThanOrEqual(sameMedian, 700, "same-connection sleeps must serialize: \(sameConnectionMillis)")
            XCTAssertLessThanOrEqual(distinctMedian, 650, "distinct-connection sleeps must overlap: \(distinctConnectionMillis)")
            XCTAssertLessThanOrEqual(distinctMedian, sameMedian * 0.85, "distinct connections must overlap materially")

            async let readA = endpointA.callTool(name: MCPWindowToolName.readFile, arguments: ["path": fixture.contextA.fileURL.path])
            async let readB = endpointB.callTool(name: MCPWindowToolName.readFile, arguments: ["path": fixture.contextB.fileURL.path])
            let parallelReads = try await (readA, readB)
            try Self.assertReadResult(parallelReads.0, contains: fixture.contextA.sentinel, excludes: fixture.contextB.sentinel)
            try Self.assertReadResult(parallelReads.1, contains: fixture.contextB.sentinel, excludes: fixture.contextA.sentinel)

            async let searchA = endpointA.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
            async let searchB = endpointB.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
            let parallelSearches = try await (searchA, searchB)
            try Self.assertSearchResult(parallelSearches.0, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
            try Self.assertSearchResult(parallelSearches.1, contains: fixture.contextB.fileURL.lastPathComponent, excludes: fixture.contextA.fileURL.lastPathComponent)

            async let mixedReadA = endpointA.callTool(name: MCPWindowToolName.readFile, arguments: ["path": fixture.contextA.fileURL.path])
            async let mixedSearchB = endpointB.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
            let firstMixed = try await (mixedReadA, mixedSearchB)
            try Self.assertReadResult(firstMixed.0, contains: fixture.contextA.sentinel, excludes: fixture.contextB.sentinel)
            try Self.assertSearchResult(firstMixed.1, contains: fixture.contextB.fileURL.lastPathComponent, excludes: fixture.contextA.fileURL.lastPathComponent)

            async let mixedSearchA = endpointA.callTool(name: MCPWindowToolName.search, arguments: Self.searchArguments)
            async let mixedReadB = endpointB.callTool(name: MCPWindowToolName.readFile, arguments: ["path": fixture.contextB.fileURL.path])
            let secondMixed = try await (mixedSearchA, mixedReadB)
            try Self.assertSearchResult(secondMixed.0, contains: fixture.contextA.fileURL.lastPathComponent, excludes: fixture.contextB.fileURL.lastPathComponent)
            try Self.assertReadResult(secondMixed.1, contains: fixture.contextB.sentinel, excludes: fixture.contextA.sentinel)

            try await Self.assertPing(endpointA, tag: "after-a")
            try await Self.assertPing(endpointB, tag: "after-b")
            try await Self.assertRoutingSnapshot(endpointA, context: fixture.contextA)
            try await Self.assertRoutingSnapshot(endpointB, context: fixture.contextB)

            let finalA = await fixture.snapshot(endpointA, context: fixture.contextA)
            let finalB = await fixture.snapshot(endpointB, context: fixture.contextB)
            XCTAssertEqual(finalA, baselineA)
            XCTAssertEqual(finalB, baselineB)
            let firstHasInFlightCalls = await fixture.networkManager.hasInFlightCalls(for: endpointA.connectionID)
            let secondHasInFlightCalls = await fixture.networkManager.hasInFlightCalls(for: endpointB.connectionID)
            XCTAssertFalse(firstHasInFlightCalls)
            XCTAssertFalse(secondHasInFlightCalls)
        }

        func runExactRoutingSessionCleanupCheckpoint(
            networkManager: ServerNetworkManager,
            fixture: ServerNetworkManager.DebugExactRoutingSessionFixture
        ) async throws {
            let callerID = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
            let rawSessionTokens = [fixture.sessionA.rawSessionToken, fixture.sessionB.rawSessionToken]
            let seededState = await networkManager.debugExactRoutingSessionFixtureState()
            Self.assertFixtureCounts(seededState, session: fixture.sessionA, expected: 1)
            Self.assertFixtureCounts(seededState, session: fixture.sessionB, expected: 1)

            let missing = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: ["op": .string("clear_persisted_routing_session")],
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(missing, code: "invalid_params")
            var currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            var malformedArguments = Self.exactRoutingSessionClearArguments(for: fixture.sessionA)
            malformedArguments["session_fingerprint"] = .string("sha256:ABCDEF0123456789")
            let malformed = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: malformedArguments,
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(malformed, code: "invalid_params")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            var trailingNewlineArguments = Self.exactRoutingSessionClearArguments(for: fixture.sessionA)
            trailingNewlineArguments["session_fingerprint"] = .string(fixture.sessionA.sessionFingerprint + "\n")
            let trailingNewline = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: trailingNewlineArguments,
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(trailingNewline, code: "invalid_params")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            var trailingWhitespaceArguments = Self.exactRoutingSessionClearArguments(for: fixture.sessionA)
            trailingWhitespaceArguments["session_fingerprint"] = .string(fixture.sessionA.sessionFingerprint + " ")
            let trailingWhitespace = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: trailingWhitespaceArguments,
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(trailingWhitespace, code: "invalid_params")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            var alternateSelectorArguments = Self.exactRoutingSessionClearArguments(for: fixture.sessionA)
            alternateSelectorArguments["client_name"] = .string(AgentProviderKind.codexMCPClientID)
            let alternateSelector = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: alternateSelectorArguments,
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(alternateSelector, code: "invalid_params")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            let mismatch = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(
                    for: fixture.sessionA,
                    expectedLastConnectionID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
                ),
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupError(mismatch, code: "last_connection_id_mismatch")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            await networkManager.debugSetExactRoutingSessionFixtureTargetActive(fixture.sessionA, active: true)
            let activeTarget = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            await networkManager.debugSetExactRoutingSessionFixtureTargetActive(fixture.sessionA, active: false)
            Self.assertCleanupError(activeTarget, code: "target_connection_active_or_pending")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            await networkManager.debugSetExactRoutingSessionFixtureTargetPending(fixture.sessionA, pending: true)
            let pendingTarget = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            await networkManager.debugSetExactRoutingSessionFixtureTargetPending(fixture.sessionA, pending: false)
            Self.assertCleanupError(pendingTarget, code: "target_connection_active_or_pending")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            await networkManager.debugSetExactRoutingSessionFixtureReboundActive(fixture, active: true)
            let rebound = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            await networkManager.debugSetExactRoutingSessionFixtureReboundActive(fixture, active: false)
            Self.assertCleanupError(rebound, code: "session_rebound_active")
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(currentState, seededState)

            let clearedA = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupSuccess(clearedA, session: fixture.sessionA, alreadyAbsent: false, changed: true, expectedCount: 1)
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            Self.assertFixtureCounts(currentState, session: fixture.sessionA, expected: 0)
            Self.assertFixtureCounts(currentState, session: fixture.sessionB, expected: 1)

            let clearedAAgain = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionA),
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupSuccess(clearedAAgain, session: fixture.sessionA, alreadyAbsent: true, changed: false, expectedCount: 0)
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            Self.assertFixtureCounts(currentState, session: fixture.sessionA, expected: 0)
            Self.assertFixtureCounts(currentState, session: fixture.sessionB, expected: 1)

            let clearedB = try await Self.invokeExactRoutingSessionClear(
                networkManager: networkManager,
                callerID: callerID,
                arguments: Self.exactRoutingSessionClearArguments(for: fixture.sessionB),
                rawSessionTokens: rawSessionTokens
            )
            Self.assertCleanupSuccess(clearedB, session: fixture.sessionB, alreadyAbsent: false, changed: true, expectedCount: 1)
            currentState = await networkManager.debugExactRoutingSessionFixtureState()
            Self.assertFixtureCounts(currentState, session: fixture.sessionA, expected: 0)
            Self.assertFixtureCounts(currentState, session: fixture.sessionB, expected: 0)
        }

        func assertExactRoutingSessionFixtureRestored(
            networkManager: ServerNetworkManager,
            fixture: ServerNetworkManager.DebugExactRoutingSessionFixture,
            baseline: ServerNetworkManager.DebugExactRoutingSessionFixtureState
        ) async {
            let restoredExactly = await networkManager.debugRestoreExactRoutingSessionFixture(fixture)
            XCTAssertTrue(restoredExactly)
            let restoredState = await networkManager.debugExactRoutingSessionFixtureState()
            XCTAssertEqual(restoredState, baseline)
        }

        static func exactRoutingSessionClearArguments(
            for session: ServerNetworkManager.DebugExactRoutingSessionFixtureSession,
            expectedLastConnectionID: UUID? = nil
        ) -> [String: Value] {
            [
                "op": .string("clear_persisted_routing_session"),
                "allow_destructive": .bool(true),
                "session_fingerprint": .string(session.sessionFingerprint),
                "expected_last_connection_id": .string((expectedLastConnectionID ?? session.expectedLastConnectionID).uuidString)
            ]
        }

        static func invokeExactRoutingSessionClear(
            networkManager: ServerNetworkManager,
            callerID: UUID,
            arguments: [String: Value],
            rawSessionTokens: [String]
        ) async throws -> DebugToolInvocation {
            let result = await networkManager.handleDebugDiagnosticsTool(connectionID: callerID, arguments: arguments)
            let serializedText = result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined()
            for rawSessionToken in rawSessionTokens {
                XCTAssertFalse(serializedText.contains(rawSessionToken), serializedText)
            }
            let data = try XCTUnwrap(serializedText.data(using: .utf8))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return DebugToolInvocation(payload: payload, serializedText: serializedText)
        }

        static func assertCleanupError(_ invocation: DebugToolInvocation, code: String) {
            XCTAssertEqual(invocation.payload["ok"] as? Bool, false, invocation.serializedText)
            XCTAssertEqual(invocation.payload["code"] as? String, code, invocation.serializedText)
        }

        static func assertCleanupSuccess(
            _ invocation: DebugToolInvocation,
            session: ServerNetworkManager.DebugExactRoutingSessionFixtureSession,
            alreadyAbsent: Bool,
            changed: Bool,
            expectedCount: Int
        ) {
            XCTAssertEqual(invocation.payload["ok"] as? Bool, true, invocation.serializedText)
            XCTAssertEqual(invocation.payload["op"] as? String, "clear_persisted_routing_session", invocation.serializedText)
            XCTAssertEqual(invocation.payload["session_fingerprint"] as? String, session.sessionFingerprint, invocation.serializedText)
            XCTAssertEqual(invocation.payload["expected_last_connection_id"] as? String, session.expectedLastConnectionID.uuidString, invocation.serializedText)
            XCTAssertEqual(invocation.payload["already_absent"] as? Bool, alreadyAbsent, invocation.serializedText)
            XCTAssertEqual(invocation.payload["changed"] as? Bool, changed, invocation.serializedText)
            XCTAssertEqual((invocation.payload["removed_persisted_record_count"] as? NSNumber)?.intValue, expectedCount, invocation.serializedText)
            XCTAssertEqual((invocation.payload["removed_last_window_entry_count"] as? NSNumber)?.intValue, expectedCount, invocation.serializedText)
            XCTAssertEqual((invocation.payload["removed_live_run_affinity_entry_count"] as? NSNumber)?.intValue, expectedCount, invocation.serializedText)
            XCTAssertEqual((invocation.payload["removed_total_count"] as? NSNumber)?.intValue, expectedCount * 3, invocation.serializedText)
        }

        static func assertFixtureCounts(
            _ state: ServerNetworkManager.DebugExactRoutingSessionFixtureState,
            session: ServerNetworkManager.DebugExactRoutingSessionFixtureSession,
            expected: Int
        ) {
            XCTAssertEqual(state.persistedRecordCountByFingerprint[session.sessionFingerprint] ?? 0, expected)
            XCTAssertEqual(state.lastWindowEntryCountByFingerprint[session.sessionFingerprint] ?? 0, expected)
            XCTAssertEqual(state.liveRunAffinityEntryCountByFingerprint[session.sessionFingerprint] ?? 0, expected)
        }

        struct DebugToolInvocation {
            let payload: [String: Any]
            let serializedText: String
        }

        static let searchArguments: [String: Any] = [
            "pattern": Fixture.sharedSearchToken,
            "mode": "content",
            "regex": false,
            "max_results": 10,
            "count_only": false,
            "context_lines": 0
        ]

        static func bind(_ endpoint: Endpoint, to tabID: UUID) async throws {
            let response = try await endpoint.callTool(
                name: "bind_context",
                arguments: [
                    "op": "bind",
                    "context_id": tabID.uuidString
                ]
            )
            _ = try toolText(from: response)
        }

        static func sleep(_ endpoint: Endpoint, tag: String) async throws -> Int {
            let response = try await endpoint.callTool(
                name: ServerNetworkManager.debugDiagnosticsToolName,
                arguments: [
                    "op": "sleep",
                    "milliseconds": 400,
                    "tag": tag
                ]
            )
            let payload = try debugPayload(from: response)
            XCTAssertEqual(payload["op"] as? String, "sleep")
            XCTAssertEqual((payload["slept_milliseconds"] as? NSNumber)?.intValue, 400)
            XCTAssertEqual(payload["tag"] as? String, tag)
            return response.id
        }

        static func assertPing(_ endpoint: Endpoint, tag: String) async throws {
            let response = try await endpoint.callTool(
                name: ServerNetworkManager.debugDiagnosticsToolName,
                arguments: ["op": "ping", "tag": tag]
            )
            let payload = try debugPayload(from: response)
            XCTAssertEqual(payload["op"] as? String, "ping")
            XCTAssertEqual(payload["connection_id"] as? String, endpoint.connectionID.uuidString)
            XCTAssertEqual(payload["tag"] as? String, tag)
        }

        static func assertRoutingSnapshot(_ endpoint: Endpoint, context: ContextFixture) async throws {
            let response = try await endpoint.callTool(
                name: ServerNetworkManager.debugDiagnosticsToolName,
                arguments: ["op": "routing_snapshot"]
            )
            let payload = try debugPayload(from: response)
            XCTAssertEqual(payload["op"] as? String, "routing_snapshot")
            XCTAssertEqual(payload["current_connection_id"] as? String, endpoint.connectionID.uuidString)
            let binding = try XCTUnwrap(payload["binding"] as? [String: Any])
            XCTAssertEqual(binding["binding_kind"] as? String, "tab_context")
            XCTAssertEqual(binding["window_id"] as? Int, context.window.windowID)
            XCTAssertEqual(binding["context_id"] as? String, context.tabID.uuidString)
            XCTAssertEqual(binding["workspace_id"] as? String, context.workspaceID.uuidString)
            XCTAssertEqual(binding["explicit"] as? Bool, true)
            XCTAssertEqual(binding["run_scoped"] as? Bool, false)
        }

        static func assertStableSnapshot(_ snapshot: EndpointSnapshot, endpoint: Endpoint, context: ContextFixture) {
            XCTAssertEqual(snapshot.connectionID, endpoint.connectionID)
            XCTAssertEqual(snapshot.capabilityToken, endpoint.sessionToken)
            XCTAssertTrue(snapshot.ready)
            XCTAssertTrue(snapshot.viable)
            XCTAssertEqual(snapshot.peerPID, Int(getpid()))
            XCTAssertEqual(snapshot.selectedWindowID, context.window.windowID)
            XCTAssertEqual(snapshot.policyPurpose, .unknown)
            XCTAssertTrue(snapshot.restrictedTools.isEmpty)
            XCTAssertTrue(snapshot.additionalTools.isEmpty)
            XCTAssertEqual(snapshot.binding.bindingKind, .tabContext)
            XCTAssertEqual(snapshot.binding.windowID, context.window.windowID)
            XCTAssertEqual(snapshot.binding.tabID, context.tabID)
            XCTAssertEqual(snapshot.binding.workspaceID, context.workspaceID)
            XCTAssertEqual(snapshot.binding.repoPaths, [context.rootURL.path])
            XCTAssertTrue(snapshot.binding.explicitlyBound)
            XCTAssertNil(snapshot.binding.runID)
        }

        static func assertReadResult(_ response: RPCResponse, contains expected: String, excludes peer: String) throws {
            let text = try toolText(from: response)
            XCTAssertTrue(text.contains(expected), text)
            XCTAssertFalse(text.contains(peer), text)
        }

        static func assertSearchResult(_ response: RPCResponse, contains expected: String, excludes peer: String) throws {
            let text = try toolText(from: response)
            XCTAssertTrue(text.contains(expected), text)
            XCTAssertFalse(text.contains(peer), text)
        }

        static func debugPayload(from response: RPCResponse) throws -> [String: Any] {
            let text = try toolText(from: response)
            let data = try XCTUnwrap(text.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        static func toolText(from response: RPCResponse) throws -> String {
            let object = try responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = content.compactMap { $0["text"] as? String }.joined()
            guard result["isError"] as? Bool != true else {
                throw ClientFixtureError.toolReturnedError(text)
            }
            return text
        }

        nonisolated static func responseObject(from response: RPCResponse) throws -> [String: Any] {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, response.id)
            XCTAssertNil(object["error"])
            return object
        }

        static func measureMilliseconds(_ operation: () async throws -> Void) async rethrows -> Double {
            let clock = ContinuousClock()
            let start = clock.now
            try await operation()
            let components = start.duration(to: clock.now).components
            return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
        }

        static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let midpoint = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[midpoint - 1] + sorted[midpoint]) / 2
            }
            return sorted[midpoint]
        }
    }

    @MainActor
    private final class Fixture {
        static let sharedSearchToken = "distinct_mcp_connection_shared_search_token"

        let networkManager = ServerNetworkManager.shared
        let rootURL: URL
        let contextA: ContextFixture
        let contextB: ContextFixture
        let ownedRoutingService: WindowRoutingService?
        private var firstEndpoint: Endpoint?
        private var secondEndpoint: Endpoint?
        private var cleanedUp = false

        private init(
            rootURL: URL,
            contextA: ContextFixture,
            contextB: ContextFixture,
            ownedRoutingService: WindowRoutingService?
        ) {
            self.rootURL = rootURL
            self.contextA = contextA
            self.contextB = contextB
            self.ownedRoutingService = ownedRoutingService
        }

        static func make() async throws -> Fixture {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersistentMCPDistinctConnectionConcurrencyTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let windowA = WindowState()
            let windowB = WindowState()
            WindowStatesManager.shared.registerWindowState(windowA)
            WindowStatesManager.shared.registerWindowState(windowB)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            await windowA.workspaceManager.awaitInitialized()
            await windowB.workspaceManager.awaitInitialized()

            var contextA: ContextFixture?
            var contextB: ContextFixture?
            var ownedRoutingService: WindowRoutingService?
            var constructedFixture: Fixture?
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
                let routing = try await ensureRoutingService()
                ownedRoutingService = routing.owned ? routing.service : nil
                let fixture = try Fixture(
                    rootURL: rootURL,
                    contextA: XCTUnwrap(contextA),
                    contextB: XCTUnwrap(contextB),
                    ownedRoutingService: ownedRoutingService
                )
                constructedFixture = fixture
                fixture.firstEndpoint = try await Endpoint.make(label: "a", networkManager: fixture.networkManager)
                fixture.secondEndpoint = try await Endpoint.make(label: "b", networkManager: fixture.networkManager)
                return fixture
            } catch {
                if let constructedFixture {
                    await constructedFixture.cleanup()
                } else {
                    if let contextB { await cleanupContext(contextB) }
                    if let contextA { await cleanupContext(contextA) }
                    if let ownedRoutingService { ServiceRegistry.unregister(ownedRoutingService) }
                    WindowStatesManager.shared.unregisterWindowState(windowB)
                    WindowStatesManager.shared.unregisterWindowState(windowA)
                    try? FileManager.default.removeItem(at: rootURL)
                }
                throw error
            }
        }

        func endpointA() throws -> Endpoint {
            try XCTUnwrap(firstEndpoint)
        }

        func endpointB() throws -> Endpoint {
            try XCTUnwrap(secondEndpoint)
        }

        func snapshot(_ endpoint: Endpoint, context: ContextFixture) async -> EndpointSnapshot {
            let policy = await networkManager.debugConnectionPolicyState(for: endpoint.connectionID)
            return await EndpointSnapshot(
                connectionID: endpoint.connectionID,
                capabilityToken: endpoint.connectionManager.capabilityToken,
                ready: endpoint.connectionManager.connectionState() == .ready,
                viable: endpoint.connectionManager.isViableForRetention(),
                peerPID: endpoint.connectionManager.peerPID(),
                selectedWindowID: networkManager.selectedWindow(for: endpoint.connectionID),
                restrictedTools: policy.restrictedTools,
                additionalTools: policy.additionalTools,
                policyPurpose: policy.purpose,
                binding: context.window.mcpServer.connectionBindingSnapshot(forConnection: endpoint.connectionID)
            )
        }

        func assertStableBindings() {
            let first = try? endpointA()
            let second = try? endpointB()
            XCTAssertEqual(first.map { contextA.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID }, contextA.tabID)
            XCTAssertEqual(second.map { contextB.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID }, contextB.tabID)
            XCTAssertNil(first.flatMap { contextB.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID })
            XCTAssertNil(second.flatMap { contextA.window.mcpServer.connectionBindingSnapshot(forConnection: $0.connectionID).tabID })
        }

        func cleanup() async {
            guard !cleanedUp else { return }
            cleanedUp = true
            for endpoint in [firstEndpoint, secondEndpoint].compactMap(\.self) {
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
            ServiceRegistry.unregister(contextB.catalogService)
            ServiceRegistry.unregister(contextA.catalogService)
            await contextB.window.workspaceFileContextStore.unloadRoot(id: contextB.rootID)
            await contextA.window.workspaceFileContextStore.unloadRoot(id: contextA.rootID)
            contextB.window.workspaceManager.workspaces.removeAll { $0.id == contextB.workspaceID }
            contextA.window.workspaceManager.workspaces.removeAll { $0.id == contextA.workspaceID }
            WindowStatesManager.shared.unregisterWindowState(contextB.window)
            WindowStatesManager.shared.unregisterWindowState(contextA.window)
            if let ownedRoutingService { ServiceRegistry.unregister(ownedRoutingService) }
            try? FileManager.default.removeItem(at: rootURL)
        }

        func assertCleanedUp() async throws {
            for endpoint in try [endpointA(), endpointB()] {
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
                } catch MultiplexedSocketPairJSONRPCClient.ClientError.closed {
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
        ) async throws -> ContextFixture {
            let fileURL = rootURL.appendingPathComponent("Sources/\(fileName)")
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(sentinel)\n// \(sharedSearchToken)\n".write(to: fileURL, atomically: true, encoding: .utf8)
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
            let rootRecord = try await window.workspaceFileContextStore.loadRoot(path: rootURL.path)
            let exactHit = await WorkspaceReadableFileService(store: window.workspaceFileContextStore)
                .resolveExactAbsoluteWorkspaceCatalogHit(fileURL.path, rootScope: .visibleWorkspace)
            guard exactHit?.standardizedFullPath == fileURL.path else {
                throw ClientFixtureError.exactAbsoluteCatalogMiss
            }
            let catalogService = window.mcpServer.windowMCPToolCatalogService
            ServiceRegistry.register(catalogService)
            return ContextFixture(
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

        private static func ensureRoutingService() async throws -> (service: WindowRoutingService, owned: Bool) {
            if let existing = ServiceRegistry.services.first(where: { $0 is WindowRoutingService }) as? WindowRoutingService {
                return (existing, false)
            }
            let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)
            for _ in 0 ..< 100 {
                let registered = ServiceRegistry.services.contains { $0 as AnyObject === service as AnyObject }
                let names = await service.tools.map(\.name)
                if registered, names.contains("bind_context") {
                    return (service, true)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            ServiceRegistry.unregister(service)
            throw ClientFixtureError.routingServiceUnavailable
        }

        private static func cleanupContext(_ context: ContextFixture) async {
            ServiceRegistry.unregister(context.catalogService)
            await context.window.workspaceFileContextStore.unloadRoot(id: context.rootID)
            context.window.workspaceManager.workspaces.removeAll { $0.id == context.workspaceID }
            try? FileManager.default.removeItem(at: context.rootURL)
        }
    }

    @MainActor
    private final class ContextFixture {
        let rootURL: URL
        let fileURL: URL
        let rootID: UUID
        let window: WindowState
        let workspaceID: UUID
        let tabID: UUID
        let sentinel: String
        let catalogService: MCPWindowToolCatalogService

        init(
            rootURL: URL,
            fileURL: URL,
            rootID: UUID,
            window: WindowState,
            workspaceID: UUID,
            tabID: UUID,
            sentinel: String,
            catalogService: MCPWindowToolCatalogService
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

    private struct EndpointSnapshot: Equatable {
        let connectionID: UUID
        let capabilityToken: String?
        let ready: Bool
        let viable: Bool
        let peerPID: Int
        let selectedWindowID: Int?
        let restrictedTools: Set<String>
        let additionalTools: Set<String>
        let policyPurpose: MCPRunPurpose
        let binding: MCPServerViewModel.ConnectionBindingSnapshot
    }

    private final class Endpoint: @unchecked Sendable {
        let connectionID: UUID
        let sessionToken: String
        let clientName: String
        let client: MultiplexedSocketPairJSONRPCClient
        let connectionManager: BootstrapSocketConnectionManager

        private init(
            connectionID: UUID,
            sessionToken: String,
            clientName: String,
            client: MultiplexedSocketPairJSONRPCClient,
            connectionManager: BootstrapSocketConnectionManager
        ) {
            self.connectionID = connectionID
            self.sessionToken = sessionToken
            self.clientName = clientName
            self.client = client
            self.connectionManager = connectionManager
        }

        static func make(label: String, networkManager: ServerNetworkManager) async throws -> Endpoint {
            let connectionID = UUID()
            let sessionToken = "persistent-mcp-distinct-\(label)-\(UUID().uuidString)"
            let clientName = "persistent-mcp-distinct-\(label)-\(UUID().uuidString)"
            await networkManager.debugClearPersistedRoutingState(for: clientName)
            var socketFDs = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
                throw MultiplexedSocketPairJSONRPCClient.ClientError.posix(operation: "socketpair", code: errno)
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
                throw MultiplexedSocketPairJSONRPCClient.ClientError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: code)
            }
            let client = MultiplexedSocketPairJSONRPCClient(fd: socketFDs[0])
            let manager = BootstrapSocketConnectionManager(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: false,
                connectedFD: socketFDs[1],
                parentManager: networkManager
            )
            let endpoint = Endpoint(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientName: clientName,
                client: client,
                connectionManager: manager
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
                _ = try PersistentMCPDistinctConnectionConcurrencyTests.responseObject(from: initialize)
                try await startTask.value
                try client.sendNotification(method: "notifications/initialized", params: [:])
                let tools = try await client.request(method: "tools/list", params: [:])
                let names = try Self.toolNames(from: tools)
                XCTAssertTrue(names.contains(MCPWindowToolName.readFile))
                XCTAssertTrue(names.contains(MCPWindowToolName.search))
                XCTAssertTrue(names.contains("bind_context"))
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

        func callTool(name: String, arguments: [String: Any]) async throws -> RPCResponse {
            try await client.request(
                method: "tools/call",
                params: [
                    "name": name,
                    "arguments": arguments
                ]
            )
        }

        private static func toolNames(from response: RPCResponse) throws -> [String] {
            let object = try PersistentMCPDistinctConnectionConcurrencyTests.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.compactMap { $0["name"] as? String }
        }
    }

    private struct RPCResponse {
        let id: Int
        let rawJSON: String
    }

    private final class MultiplexedSocketPairJSONRPCClient: @unchecked Sendable {
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
        private var pending: [Int: CheckedContinuation<String, Error>] = [:]
        private var notifications: [String] = []
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

        func sendNotification(method: String, params: [String: Any]) throws {
            try sendJSON([
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ])
        }

        func request(method: String, params: [String: Any], timeoutSeconds: Int = 10) async throws -> RPCResponse {
            let id = allocateRequestID()
            let rawJSON = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    do {
                        try register(continuation, for: id)
                        try sendJSON([
                            "jsonrpc": "2.0",
                            "id": id,
                            "method": method,
                            "params": params
                        ])
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(timeoutSeconds))
                            self?.failPending(id: id, error: ClientError.timedOut(id))
                        }
                    } catch {
                        if !failPending(id: id, error: error) {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                self.failPending(id: id, error: CancellationError())
            }
            return RPCResponse(id: id, rawJSON: rawJSON)
        }

        private func allocateRequestID() -> Int {
            withStateLock {
                defer { nextRequestID += 1 }
                return nextRequestID
            }
        }

        private func register(_ continuation: CheckedContinuation<String, Error>, for id: Int) throws {
            try withStateLock {
                guard !isClosed, fd >= 0 else { throw ClientError.closed }
                guard pending[id] == nil else { throw ClientError.duplicateRequestID(id) }
                pending[id] = continuation
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
                if pollResult == 0 { continue }
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
                    guard let continuation = takePending(id: id) else { throw ClientError.unexpectedResponseID(id) }
                    guard let rawJSON = String(data: line, encoding: .utf8) else { throw ClientError.invalidResponse }
                    continuation.resume(returning: rawJSON)
                    return true
                }
                guard object["method"] as? String != nil,
                      let rawJSON = String(data: line, encoding: .utf8)
                else {
                    throw ClientError.invalidResponse
                }
                withStateLock { notifications.append(rawJSON) }
                return true
            } catch {
                close(with: error)
                return false
            }
        }

        private func takePending(id: Int) -> CheckedContinuation<String, Error>? {
            withStateLock { pending.removeValue(forKey: id) }
        }

        @discardableResult
        private func failPending(id: Int, error: Error) -> Bool {
            guard let continuation = takePending(id: id) else { return false }
            continuation.resume(throwing: error)
            return true
        }

        private func close(with error: Error) {
            let snapshot: (Int32, [CheckedContinuation<String, Error>]) = withStateLock {
                guard !isClosed else { return (-1, []) }
                isClosed = true
                let activeFD = fd
                fd = -1
                let continuations = Array(pending.values)
                pending.removeAll()
                return (activeFD, continuations)
            }
            if snapshot.0 >= 0 { Darwin.close(snapshot.0) }
            for continuation in snapshot.1 {
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
        case routingServiceUnavailable
        case toolReturnedError(String)
    }
#endif
