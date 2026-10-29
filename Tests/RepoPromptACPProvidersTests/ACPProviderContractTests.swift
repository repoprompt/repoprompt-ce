import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import XCTest

final class ACPProviderContractTests: XCTestCase {
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
