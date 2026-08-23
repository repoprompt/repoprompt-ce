import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class ProtocolAndLifecycleTests: XCTestCase {
    func testCanonicalRequestSigningMatchesGoldenVector() throws {
        let key = Data("test-key".utf8)
        let timestamp = "2026-08-10T12:34:56.789Z"
        let nonce = "YWJjZGVmZ2hpamtsbW5vcA"
        let bodyDigest = CanonicalSigning.bodyDigest(Data("{}".utf8))
        let decisionDigest = CanonicalSigning.bodyDigest(Data())
        let canonical = CanonicalSigning.requestString(method: "post", pathAndQuery: "/internal/v1/sessions?x=1", timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: "key-1")
        let signature = CanonicalSigning.hmacSHA256(message: canonical, key: key)
        XCTAssertEqual(signature, "8e595f118f914ac3f931c4a90c0bd6ebc53ef6a7e7588be0a71bd6d1419674b4")
        XCTAssertEqual(signature.count, 64)
        let parsedTimestamp = try XCTUnwrap(CanonicalSigning.parseISO8601(timestamp))
        XCTAssertEqual(parsedTimestamp.timeIntervalSince1970, 1_786_365_296.789, accuracy: 0.001)
        XCTAssertEqual(CanonicalSigning.base64URLDecode(CanonicalSigning.base64URLEncode(Data("decision".utf8))), Data("decision".utf8))
        XCTAssertNotEqual(signature, CanonicalSigning.hmacSHA256(message: canonical + "x", key: key))
    }

    func testExternalActorEncodesUserIdAndRejectsThirdPartyKeys() throws {
        let actor = ExternalActor(userID: "user-1", username: "alice", displayName: "Alice")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(actor)) as? [String: Any]
        XCTAssertEqual(encoded?["userId"] as? String, "user-1")
        XCTAssertThrowsError(try JSONDecoder().decode(ExternalActor.self, from: Data(#"{"username":"alice","displayName":"Alice"}"#.utf8)))
    }

    func testV1DTOsUseLowerCamelKeysAndLogicalOnlyProjections() throws {
        let storeID = UUID()
        let cursor = ServiceCursor(storeID: storeID, globalSequence: 7)
        let rootID = UUID()
        let actor = ExternalActor(userID: "user-1", username: "alice", displayName: "Alice")
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: rootID, logicalName: "source", canonicalPath: "/private/source", writable: true)], revision: 1, cursor: cursor)
        let projectJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectWireSnapshot(project))) as? [String: Any])
        XCTAssertNotNil(projectJSON["projectId"])
        XCTAssertNil(projectJSON["projectID"])
        let roots = try XCTUnwrap(projectJSON["roots"] as? [[String: Any]])
        XCTAssertNotNil(roots.first?["rootId"])
        XCTAssertNil(roots.first?["canonicalPath"])

        let worktree = WorktreeBindingSnapshot(bindingID: UUID(), projectID: project.projectID, rootID: rootID, sessionID: UUID(), baseRef: "main", branch: "audit", physicalPath: "/private/worktree", ownershipState: .active, mergeState: .clean, revision: 1)
        let worktreeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorktreeWireSnapshot(worktree))) as? [String: Any])
        XCTAssertNotNil(worktreeJSON["bindingId"])
        XCTAssertNil(worktreeJSON["bindingID"])
        XCTAssertNil(worktreeJSON["physicalPath"])

        let commandData = try JSONEncoder().encode(SessionCommand.cancelSession(expectedRunID: UUID(), expectedGeneration: 3))
        let commandJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: commandData) as? [String: Any])
        XCTAssertEqual(commandJSON["operation"] as? String, "cancelSession")
        XCTAssertNotNil(commandJSON["expectedRunId"])
        XCTAssertNil(commandJSON["cancelSession"])

        let pageData = try JSONEncoder().encode(Page(items: [ProjectWireSnapshot(project)], nextPageToken: "opaque", cursor: cursor))
        let pageJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: pageData) as? [String: Any])
        XCTAssertNotNil(pageJSON["nextPageToken"])
        XCTAssertNotNil(pageJSON["cursor"])
    }

    func testLifecycleGateAcceptsOneTerminalResult() {
        let binding = RunBindingIdentity(runID: UUID(), generation: 7, turnEpoch: 3, connectionGeneration: 2)
        var gate = AgentRunLifecycleGate(binding: binding)
        XCTAssertEqual(gate.accept(binding: binding), .accepted)
        XCTAssertEqual(gate.accept(binding: binding, terminal: .sessionCompleted), .accepted)
        XCTAssertEqual(gate.accept(binding: binding, terminal: .sessionFailed), .terminalAlreadySettled)
        XCTAssertEqual(gate.terminalEvent, .sessionCompleted)
    }

    func testLifecycleGateFencesStaleGenerationEpochAndConnection() {
        let binding = RunBindingIdentity(runID: UUID(), generation: 2, turnEpoch: 4, connectionGeneration: 6)
        var gate = AgentRunLifecycleGate(binding: binding)
        XCTAssertEqual(gate.accept(binding: .init(runID: binding.runID, generation: 1, turnEpoch: 4, connectionGeneration: 6)), .staleGeneration)
        XCTAssertEqual(gate.accept(binding: .init(runID: binding.runID, generation: 2, turnEpoch: 3, connectionGeneration: 6)), .staleTurnEpoch)
        XCTAssertEqual(gate.accept(binding: .init(runID: binding.runID, generation: 2, turnEpoch: 4, connectionGeneration: 5)), .staleConnection)
    }

    func testSessionCommandFixtureDecodesEveryClosedV1Variant() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/session-commands-v1.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        XCTAssertEqual(fixture["schemaVersion"] as? Int, 1)
        let vectors = try XCTUnwrap(fixture["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 17)
        for vector in vectors {
            let body = try XCTUnwrap(vector["internalBody"] as? [String: Any])
            let command = try JSONDecoder.serviceDecoder.decode(SessionCommand.self, from: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            XCTAssertEqual(command.operation, body["operation"] as? String)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.serviceEncoder.encode(command)) as? [String: Any])
            XCTAssertEqual(encoded["operation"] as? String, body["operation"] as? String)
        }
    }

    func testSelectedMessageContextAcceptsCanonicalExplicitSelection() throws {
        let data = Data("""
        {"projectId":"11111111-1111-4111-8111-111111111111","provider":"codex","visibility":"private","initialPrompt":"Investigate the regression","startImmediately":true,"selectedMessageContext":{"schemaVersion":1,"source":"explicit-selection","messages":[{"roomId":"room-1","messageId":"message-1","text":"Exact selected chat text","senderId":"user-1","timestamp":"2026-08-10T12:00:00.000Z","revision":"2026-08-10T12:00:01.000Z","threadId":"thread-1"}]}}
        """.utf8)
        let decoded = try JSONDecoder.serviceDecoder.decode(CreateSessionInput.self, from: data)
        let frozen = try decoded.frozenForExecution()
        XCTAssertTrue(frozen.hasInitialProviderIntent)
        XCTAssertNil(frozen.selectedMessageContext)
        XCTAssertTrue(try XCTUnwrap(frozen.initialPrompt).contains("Exact selected chat text"))
        XCTAssertTrue(try XCTUnwrap(frozen.initialPrompt).contains("Investigate the regression"))
        XCTAssertTrue(try XCTUnwrap(frozen.initialPrompt).contains("source=\"explicit-selection\""))
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(CreateSessionInput.self, from: Data("""
        {"projectId":"11111111-1111-4111-8111-111111111111","provider":"codex","visibility":"private","selectedMessageContext":{"schemaVersion":1,"source":"unknown-selection","messages":[{"roomId":"room-1","messageId":"message-1","text":"x","senderId":"user-1","timestamp":"2026-08-10T12:00:00.000Z","revision":"1"}]}}
        """.utf8)).frozenForExecution())
    }
}
