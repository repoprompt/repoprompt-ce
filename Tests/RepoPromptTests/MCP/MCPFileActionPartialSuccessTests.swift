import MCP
@testable import RepoPrompt
import XCTest

final class MCPFileActionPartialSuccessTests: XCTestCase {
    func testCreateSelectionPersistenceWarningPreservesSuccessfulFileAction() throws {
        let warning = "The file was created, but its selection was not confirmed. Retry manage_selection."
        let dto = ToolResultDTOs.FileActionReply(
            status: "ok",
            action: "create",
            path: "/tmp/Created.swift",
            newPath: nil,
            warning: warning
        )
        let value = try Self.value(dto)

        let decoded = try XCTUnwrap(value.decode(ToolResultDTOs.FileActionReply.self))
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.warning, warning)

        let text = try Self.onlyText(ToolOutputFormatter.formatFileAction(value: value))
        XCTAssertTrue(text.contains("## File Action ✅"), text)
        XCTAssertTrue(text.contains("- Warning: \(warning)"), text)
    }

    private static func value(_ value: some Encodable) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
