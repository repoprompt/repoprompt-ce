@testable import RepoPrompt
import XCTest

final class AgentOnboardingWizardExitActionTests: XCTestCase {
    func testExitPolicyMarksSeenBeforeContinuingToMain() {
        var events: [String] = []

        AgentOnboardingWizardExitPolicy.perform(
            markOnboardingSeen: { events.append("seen") },
            onContinueToMain: { events.append("continue") },
            onDismiss: { events.append("dismiss") }
        )

        XCTAssertEqual(events, ["seen", "continue"])
    }

    func testExitPolicyMarksSeenBeforeFallingBackToDismiss() {
        var events: [String] = []

        AgentOnboardingWizardExitPolicy.perform(
            markOnboardingSeen: { events.append("seen") },
            onContinueToMain: nil,
            onDismiss: { events.append("dismiss") }
        )

        XCTAssertEqual(events, ["seen", "dismiss"])
    }
}
