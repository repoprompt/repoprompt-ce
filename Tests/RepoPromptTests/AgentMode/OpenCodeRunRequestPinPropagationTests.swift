@testable import RepoPromptApp
import XCTest

/// Guards the ACP run-request builder against being re-narrowed to Cursor.
///
/// `makeACPRunRequest` resolves pins for whichever ACP provider is selected. An earlier form
/// resolved them only when `selectedAgent == .cursor`, which silently dropped OpenCode effort
/// pins: the run started fine, the pin simply never reached `session/set_config_option`. Nothing
/// failed loudly, so only a test at this boundary catches a regression.
final class OpenCodeRunRequestPinPropagationTests: XCTestCase {
    @MainActor
    func testRunRequestCarriesEffortPinForNonCursorACPProvider() throws {
        let modelRaw = "ollama-cloud/glm-5.3"
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .openCode
        session.selectedModelRaw = modelRaw
        session.acpModelParameterSelections = try XCTUnwrap(
            ACPModelParameterSelection.thinkingPin(
                configID: "effort",
                valueRaw: "max",
                providerID: .openCode,
                modelRaw: modelRaw
            )
        )

        let request = try XCTUnwrap(AgentModeRunService.makeACPRunRequest(
            session: session,
            workspacePath: "/tmp/workspace",
            attachments: [],
            runtimePermission: AgentProviderRuntimePermissionBinding()
        ))

        let thinking = request.modelParameterSelections.filter { $0.kind == .thinking }
        XCTAssertEqual(
            thinking.count,
            1,
            "OpenCode effort pins must reach the run request; resolving pins only for Cursor drops them silently."
        )
        XCTAssertEqual(thinking.first?.valueRaw, "max")
        XCTAssertEqual(thinking.first?.providerID, .openCode)
    }

    /// The companion half: a pin persisted for a different model must not leak onto this run.
    @MainActor
    func testRunRequestDropsPinBelongingToAnotherModel() throws {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/glm-5.3"
        session.acpModelParameterSelections = try XCTUnwrap(
            ACPModelParameterSelection.thinkingPin(
                configID: "effort",
                valueRaw: "max",
                providerID: .openCode,
                modelRaw: "ollama-cloud/deepseek-4.1-flash"
            )
        )

        let request = try XCTUnwrap(AgentModeRunService.makeACPRunRequest(
            session: session,
            workspacePath: "/tmp/workspace",
            attachments: [],
            runtimePermission: AgentProviderRuntimePermissionBinding()
        ))

        XCTAssertTrue(
            request.modelParameterSelections.isEmpty,
            "A pin persisted for another model must not ride along with this run."
        )
    }
}
