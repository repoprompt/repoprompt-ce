import Foundation
import MCP
@testable import RepoPromptMCPCore
import XCTest

#if DEBUG
    final class ExecStartupBindingStatusTests: XCTestCase {
        private static let requestedContextID = "C72119FC-64CD-42E4-B14A-0E6A28DD4DC1"
        private static let serverContextID = "EC558D4B-0292-4935-AD42-CEFC6121A31A"
        private static let rejection = "Managed binding rejected: no active grant."

        func testSemanticBindingRejectionWarnsForEveryStartupSelectorWithoutClaimingSuccess() async throws {
            for selector in StartupSelector.allCases {
                let fixture = try await makeFixture(reply: .rejected)
                addTeardownBlock { await fixture.cleanup() }
                var options = options(for: selector)
                options.quiet = false
                let service = ExecMCPService(options: options)
                try await service.test_runConnectedSession(fixture.session) { text in
                    await fixture.recorder.recordDiagnostic(text)
                }
                let snapshot = await fixture.recorder.snapshot()

                XCTAssertEqual(snapshot.diagnostics.count, 1, selector.rawValue)
                XCTAssertTrue(snapshot.diagnostics.first?.hasPrefix("Warning: Failed to bind ") == true, selector.rawValue)
                XCTAssertTrue(snapshot.diagnostics.first?.contains(Self.rejection) == true, selector.rawValue)
                XCTAssertFalse(snapshot.diagnostics.joined().contains("Bound context"), selector.rawValue)
                XCTAssertFalse(snapshot.diagnostics.joined().contains("Bound tab"), selector.rawValue)
                XCTAssertFalse(snapshot.diagnostics.joined().contains("Bound working_dirs"), selector.rawValue)
                XCTAssertFalse(snapshot.diagnostics.joined().contains("Selected window"), selector.rawValue)
                let expectedCalls = selector == .namedTab
                    ? ["bind_context", "bind_context", "workspace_context"]
                    : ["bind_context", "workspace_context"]
                XCTAssertEqual(snapshot.calls.map(\.name), expectedCalls, selector.rawValue)
                let bindingCall = try XCTUnwrap(snapshot.calls.last { $0.name == "bind_context" })
                XCTAssertEqual(bindingCall.arguments?["op"], .string("bind"), selector.rawValue)
                switch selector {
                case .window:
                    XCTAssertEqual(bindingCall.arguments?["window_id"], .int(7))
                case .context, .uuidTab:
                    XCTAssertEqual(bindingCall.arguments?["context_id"], .string(Self.requestedContextID))
                case .namedTab:
                    XCTAssertEqual(bindingCall.arguments?["context_id"], .string(Self.serverContextID))
                case .workingDirs:
                    XCTAssertEqual(bindingCall.arguments?["working_dirs"], .array([.string("/test/workspace")]))
                }
                XCTAssertEqual(snapshot.calls.last?.arguments?["_windowID"], .int(7), selector.rawValue)
                let expectedContext: Value? = [.context, .uuidTab].contains(selector) ? .string(Self.requestedContextID) : nil
                XCTAssertEqual(snapshot.calls.last?.arguments?["context_id"], expectedContext, selector.rawValue)
            }
        }

        func testSemanticBindingRejectionStillWarnsInQuietMode() async throws {
            let fixture = try await makeFixture(reply: .rejected)
            addTeardownBlock { await fixture.cleanup() }
            let service = ExecMCPService(options: options(for: .window))
            try await service.test_runConnectedSession(fixture.session) { text in
                await fixture.recorder.recordDiagnostic(text)
            }
            let snapshot = await fixture.recorder.snapshot()
            XCTAssertEqual(snapshot.diagnostics, ["Warning: Failed to bind 7: \(Self.rejection)\n"])
            XCTAssertEqual(snapshot.calls.map(\.name), ["bind_context", "workspace_context"])
        }

        func testSuccessfulBindingReportsServerResultAndUsesConfirmedRouting() async throws {
            for selector in StartupSelector.allCases {
                let fixture = try await makeFixture(reply: .bound)
                addTeardownBlock { await fixture.cleanup() }
                var options = options(for: selector)
                options.quiet = false
                let service = ExecMCPService(options: options)
                try await service.test_runConnectedSession(fixture.session) { text in
                    await fixture.recorder.recordDiagnostic(text)
                }
                let snapshot = await fixture.recorder.snapshot()
                XCTAssertEqual(snapshot.calls.last?.name, "workspace_context", selector.rawValue)
                let expectedWindow = selector == .window ? 7 : 9
                XCTAssertEqual(snapshot.calls.last?.arguments?["_windowID"], .int(expectedWindow), selector.rawValue)
                let expectedContext: Value? = switch selector {
                case .window: nil
                case .context, .uuidTab: .string(Self.requestedContextID)
                case .namedTab, .workingDirs: .string(Self.serverContextID)
                }
                XCTAssertEqual(snapshot.calls.last?.arguments?["context_id"], expectedContext, selector.rawValue)
                let expectedPayload = Self.bindingPayload(windowID: expectedWindow, contextID: expectedContext?.stringValue)
                XCTAssertEqual(snapshot.diagnostics, [expectedPayload + "\n"], selector.rawValue)
            }
        }

        func testSuccessfulBindingIsSilentInQuietMode() async throws {
            let fixture = try await makeFixture(reply: .bound)
            addTeardownBlock { await fixture.cleanup() }
            let service = ExecMCPService(options: options(for: .workingDirs))
            try await service.test_runConnectedSession(fixture.session) { text in
                await fixture.recorder.recordDiagnostic(text)
            }
            let snapshot = await fixture.recorder.snapshot()
            XCTAssertEqual(snapshot.diagnostics, [])
            XCTAssertEqual(snapshot.calls.last?.arguments?["context_id"], .string(Self.serverContextID))
        }

        func testMissingBindToolReportsLocalWindowHintRatherThanServerBinding() async throws {
            let fixture = try await makeFixture(reply: .missingTool)
            addTeardownBlock { await fixture.cleanup() }
            var options = options(for: .window)
            options.quiet = false
            let service = ExecMCPService(options: options)
            try await service.test_runConnectedSession(fixture.session) { text in
                await fixture.recorder.recordDiagnostic(text)
            }
            let snapshot = await fixture.recorder.snapshot()
            XCTAssertEqual(snapshot.diagnostics, ["Selected window 7 locally; subsequent tool calls will include _windowID=7.\n"])
            XCTAssertEqual(snapshot.calls.map(\.name), ["bind_context", "workspace_context"])
            XCTAssertEqual(snapshot.calls.last?.arguments?["_windowID"], .int(7))
            XCTAssertNil(snapshot.calls.last?.arguments?["context_id"])
        }

        func testThrownBindingFailureWarnsAndKeepsExplicitLocalRouting() async throws {
            let fixture = try await makeFixture(reply: .thrownFailure)
            addTeardownBlock { await fixture.cleanup() }
            let service = ExecMCPService(options: options(for: .context))
            try await service.test_runConnectedSession(fixture.session) { text in
                await fixture.recorder.recordDiagnostic(text)
            }
            let snapshot = await fixture.recorder.snapshot()
            XCTAssertEqual(snapshot.diagnostics.count, 1)
            XCTAssertTrue(snapshot.diagnostics.first?.hasPrefix("Warning: Failed to bind \(Self.requestedContextID): ") == true)
            XCTAssertTrue(snapshot.diagnostics.first?.contains("binding fixture failure") == true)
            XCTAssertEqual(snapshot.calls.last?.arguments?["context_id"], .string(Self.requestedContextID))
            XCTAssertEqual(snapshot.calls.last?.arguments?["_windowID"], .int(7))
        }

        private enum StartupSelector: String, CaseIterable {
            case window, context, uuidTab, namedTab, workingDirs
        }

        private enum BindingReply {
            case rejected, bound, missingTool, thrownFailure
        }

        private static func bindingPayload(windowID: Int, contextID: String?) -> String {
            let contextJSON = contextID.map { "\"\($0)\"" } ?? "null"
            let kind = contextID == nil ? "window" : "tab"
            return """
            {"binding":{"binding_kind":"\(kind)","window_id":\(windowID),"context_id":\(contextJSON),"workspace_name":"Test Workspace"}}
            """
        }

        private func options(for selector: StartupSelector) -> ExecOptions {
            var options = ExecOptions()
            options.windowID = 7
            options.commands = ["call workspace_context"]
            switch selector {
            case .window: break
            case .context: options.contextID = Self.requestedContextID
            case .uuidTab: options.tabID = Self.requestedContextID
            case .namedTab: options.tabID = "Review Tab"
            case .workingDirs: options.workingDirs = ["/test/workspace"]
            }
            return options
        }

        private func makeFixture(reply: BindingReply) async throws -> Fixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let recorder = Recorder()
            let server = Server(name: "EXEC startup binding fixture", version: "1.0", capabilities: .init(tools: .init()))
            await server.withMethodHandler(CallTool.self) { params in
                await recorder.recordCall(params)
                guard params.name == "bind_context" else {
                    return .init(content: [.text(text: "command executed", annotations: nil, _meta: nil)], isError: false)
                }
                if params.arguments?["op"] == .string("list") {
                    let text = """
                    {"windows":[{"window_id":7,"workspace":null,"tabs":[{"context_id":"\(Self.serverContextID)","name":"Review Tab"}]}],"binding":{"binding_kind":"unbound","window_id":null,"context_id":null,"workspace_name":null}}
                    """
                    return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
                }
                switch reply {
                case .rejected:
                    return .init(
                        content: [.text(text: Self.rejection, annotations: nil, _meta: nil), .text(text: Self.bindingPayload(windowID: 9, contextID: Self.serverContextID), annotations: nil, _meta: nil)],
                        isError: true
                    )
                case .bound:
                    let isWindowOnly = params.arguments?["context_id"] == nil && params.arguments?["working_dirs"] == nil
                    let contextID = isWindowOnly ? nil : (params.arguments?["context_id"]?.stringValue ?? Self.serverContextID)
                    let payload = Self.bindingPayload(windowID: isWindowOnly ? 7 : 9, contextID: contextID)
                    return .init(content: [.text(text: payload, annotations: nil, _meta: nil)], isError: false)
                case .missingTool:
                    return .init(content: [.text(text: "Tool not found: bind_context", annotations: nil, _meta: nil)], isError: true)
                case .thrownFailure:
                    throw MCPError.internalError("binding fixture failure")
                }
            }
            try await server.start(transport: transports.server)
            let barrier = MCPRequestSendBarrier()
            let clientTransport = OrderedMCPTransport(underlying: transports.client, requestSendBarrier: barrier, logger: transports.client.logger)
            let client = Client(name: "EXEC startup binding client", version: "1.0")
            _ = try await client.connect(transport: clientTransport)
            let session = InteractiveMCPClientSession(connectedClientForTesting: client, requestSendBarrier: barrier)
            return Fixture(client: client, server: server, session: session, recorder: recorder)
        }

        private struct RecordedCall {
            let name: String
            let arguments: [String: Value]?
        }

        private actor Recorder {
            private var calls: [RecordedCall] = []
            private var diagnostics: [String] = []

            func recordCall(_ params: CallTool.Parameters) {
                calls.append(.init(name: params.name, arguments: params.arguments))
            }

            func recordDiagnostic(_ text: String) {
                diagnostics.append(text)
            }

            func snapshot() -> (calls: [RecordedCall], diagnostics: [String]) {
                (calls, diagnostics)
            }
        }

        private struct Fixture {
            let client: Client
            let server: Server
            let session: InteractiveMCPClientSession
            let recorder: Recorder

            func cleanup() async {
                await client.disconnect()
                await server.stop()
            }
        }
    }
#endif
