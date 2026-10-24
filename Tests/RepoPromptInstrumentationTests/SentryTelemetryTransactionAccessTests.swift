import RepoPromptInstrumentation
import XCTest

final class SentryTelemetryTransactionAccessTests: XCTestCase {
    func testAppConsumedTransactionFieldsArePackageVisible() {
        let transaction = SentryTelemetryModel.Transaction.agentRun
        XCTAssertEqual(transaction.name, "agent.run")
        XCTAssertEqual(transaction.operation, "agent.run")
    }
}
