import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorProductionFactoryTests: XCTestCase {
    func testProductionFactoriesUseAutomaticCommandSelection() async throws {
        let interactiveProvider = try await ACPAgentProviderFactory.makeProvider(
            for: .cursor,
            modelString: "cursor-model"
        )
        let interactiveCursorProvider = try XCTUnwrap(
            interactiveProvider as? CursorACPAgentProvider
        )
        let headlessProvider = AgentRuntimeProviderService.shared.makeProvider(
            for: .cursor,
            modelString: "cursor-model"
        )
        let headlessCursorProvider = try XCTUnwrap(
            headlessProvider as? CursorACPHeadlessAgentProvider
        )
        let chatConfig = CursorCLIProvider.test_makeHeadlessConfig(modelName: "cursor-model")
        let pollingProvider = CursorACPControllerModelDiscoveryClient.test_makeCursorProvider(
            modelString: "cursor-model"
        )

        XCTAssertEqual(interactiveCursorProvider.test_config.commandSelection, .automatic)
        XCTAssertEqual(headlessCursorProvider.test_config.commandSelection, .automatic)
        XCTAssertEqual(chatConfig.commandSelection, .automatic)
        XCTAssertEqual(pollingProvider.test_config.commandSelection, .automatic)
    }
}
