@testable import RepoPromptMCP
import XCTest

#if DEBUG
    final class CLIFormElicitationTests: XCTestCase {
        func testAcceptDecodesTypedContent() throws {
            let result = try CLIFormElicitation.parseResponse(#"{"approve":true}"#)

            XCTAssertEqual(result.action, .accept)
            XCTAssertEqual(result.content?["approve"]?.boolValue, true)
        }

        func testDeclineAndCancelRemainDistinct() throws {
            XCTAssertEqual(try CLIFormElicitation.parseResponse("decline").action, .decline)
            XCTAssertEqual(try CLIFormElicitation.parseResponse("cancel").action, .cancel)
        }

        func testNonObjectResponseIsRejected() {
            XCTAssertThrowsError(try CLIFormElicitation.parseResponse("true")) { error in
                XCTAssertEqual(error as? CLIFormElicitationError, .invalidResponse)
            }
        }
    }
#endif
