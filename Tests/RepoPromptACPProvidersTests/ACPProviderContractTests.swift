import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import XCTest

final class ACPProviderContractTests: XCTestCase {
    func testOpenCodeNormalizerUsesInjectedServerProvenance() {
        let names = ACPToolNameResolution(
            isRepoPromptServerIdentifier: { $0 == "trusted" },
            canonicalRepoPromptToolName: { $0 == "alias" ? "read_file" : nil },
            isRepoPromptToolNameWithServerPrefix: { _ in false }
        )
        let trusted = OpenCodeACPEventNormalizer.normalize(
            ["sessionUpdate": "tool_call", "toolCallId": "one", "title": "alias (trusted)"],
            toolProfile: .agentMode, toolNames: names
        )
        let foreign = OpenCodeACPEventNormalizer.normalize(
            ["sessionUpdate": "tool_call", "toolCallId": "two", "title": "alias (foreign)"],
            toolProfile: .agentMode, toolNames: names
        )
        guard case let .stream(trustedResult) = trusted.first else { return XCTFail("Missing trusted tool event") }
        XCTAssertEqual(trustedResult.toolName, "mcp__RepoPromptCE__read_file")
        XCTAssertTrue(foreign.isEmpty, "An unrecognized low-level tool payload is suppressed")
    }

    func testInjectedToolAuthorityControlsParenthesizedProvenance() {
        let names = ACPToolNameResolution(
            isRepoPromptServerIdentifier: { $0 == "trusted" },
            canonicalRepoPromptToolName: { $0 == "alias" ? "read_file" : nil },
            isRepoPromptToolNameWithServerPrefix: { _ in false }
        )
        XCTAssertEqual(ACPRuntimeEventParsing.repoPromptToolName(from: ["title": "alias (trusted)"], toolNames: names), "mcp__RepoPromptCE__read_file")
        XCTAssertNil(ACPRuntimeEventParsing.repoPromptToolName(from: ["title": "alias (foreign)"], toolNames: names))
    }

    func testEmptyTerminalOutputKeepsLifecycleCompletion() {
        let names = ACPToolNameResolution(
            isRepoPromptServerIdentifier: { _ in false },
            canonicalRepoPromptToolName: { _ in nil },
            isRepoPromptToolNameWithServerPrefix: { _ in false }
        )
        let events = ACPDefaultSessionUpdateNormalizer.normalize([
            "sessionUpdate": "tool_call_update", "toolCallId": "call", "status": "completed", "rawOutput": "[]"
        ], providerID: .devin, toolNames: names)
        guard case let .stream(result) = events.first else { return XCTFail("Missing terminal result") }
        XCTAssertEqual(AgentToolResultPayloadRetention.terminalMarkerStatus(result.toolResultJSON), "completed")
    }

    func testSessionContractNormalizesIdentityAndPreservesOpenMetadata() {
        let identity = ACPProviderSessionIdentity(providerID: .openCode, runtimeSessionID: "  runtime  ", loadSessionID: "  ", loadSessionIDConfidence: .verified)
        XCTAssertEqual(identity.runtimeSessionID, "runtime")
        XCTAssertNil(identity.loadSessionID)
        XCTAssertEqual(identity.loadSessionIDConfidence, .unavailable)

        let server = RepoPromptMCPServerConfiguration(command: "/usr/bin/true")
        let notification = ACPSessionConfiguration.PostOpenNotification(method: "ready", params: ["v": .int(1)])
        let session = ACPSessionConfiguration(mode: .load(existingSessionID: "id"), workingDirectory: "/tmp", mcpServers: [server], metadata: ["future": .string("value")], postOpenNotification: notification)
        XCTAssertEqual(session.mode, .load(existingSessionID: "id"))
        XCTAssertEqual(session.mcpServers, [server])
        XCTAssertEqual(session.metadata["future"], .string("value"))
        XCTAssertEqual(session.postOpenNotification, notification)
    }

    func testProviderSessionIdentityNormalizesEmptyIDs() {
        let identity = ACPProviderSessionIdentity(
            providerID: .cursor,
            runtimeSessionID: " cursor-runtime-id ",
            loadSessionID: "  ",
            loadSessionIDConfidence: .verified
        )

        XCTAssertEqual(identity.runtimeSessionID, "cursor-runtime-id")
        XCTAssertNil(identity.loadSessionID)
        XCTAssertEqual(identity.loadSessionIDConfidence, .unavailable)
    }
}
