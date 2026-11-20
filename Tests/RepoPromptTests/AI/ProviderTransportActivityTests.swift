import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFoundation
import XCTest

/// #803: providers report transport liveness so silent-but-alive Oracle lanes renew
/// the Context Builder inactivity budget, and stop once the transport has settled.
@MainActor
final class ProviderTransportActivityTests: XCTestCase {
    func testPendingCompletionHeartbeatFeedsExistingAppLifecycleMapping() throws {
        let event: AIStreamResult? = ProviderTransportActivity.result()
        let output = try XCTUnwrap(event.flatMap { AIQueriesService.transportActivityOutput(for: $0) })
        XCTAssertEqual(OracleViewModel.lifecycleActivityKind(for: output), .streamActivity)
    }

    // The custom provider drops keepalive comments and content-less deltas; their
    // arrival must still be reported as liveness ahead of the answer.
}
