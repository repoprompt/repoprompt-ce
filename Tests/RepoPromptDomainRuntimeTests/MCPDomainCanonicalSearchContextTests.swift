import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainCanonicalSearchContextTests: XCTestCase {
    func testContextLinesAreReturnedWithSourceLineNumbersAndExplicitTruncation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("example.txt")
        let snapshot = DomainCanonicalWorkspaceSnapshot(identity: .init(workspaceID: UUID(), contextID: UUID()), roots: [root], prompt: "", selection: [])
        let service = MCPDomainCanonicalWorkspaceService(adapter: .init(
            toolSnapshot: { _ in snapshot }, readSnapshot: { _ in snapshot }, mutate: { _, _ in snapshot },
            resolvePath: { raw, _, _ in root.appendingPathComponent(raw) }
        ))
        func search(_ context: Int) async throws -> [String: Value] {
            let request = try DomainPhysicalToolRequest(arguments: ["pattern": .string("needle"), "context_lines": .int(context)])
            let result = try await service.searchFiles(.init(request: request, context: .init(handle: nil, connectionID: nil), sideEffects: .init(submit: { _, _, _, _, _ in })))
            return try XCTUnwrap(result.mcpValue().objectValue)
        }
        try "before\nneedle\nafter".write(to: file, atomically: true, encoding: .utf8)
        let response = try await search(30)
        XCTAssertEqual(response["count"], .int(1))
        XCTAssertEqual(response["context_truncated"], .bool(false))
        let match = try XCTUnwrap(response["matches"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(match["line"], .int(2))
        XCTAssertEqual(match["context"]?.arrayValue, [.object(["line": .int(1), "text": .string("before")]), .object(["line": .int(3), "text": .string("after")])])
        try (String(repeating: "x", count: 50001) + "\nneedle").write(to: file, atomically: true, encoding: .utf8)
        let limited = try await search(30)
        XCTAssertEqual(limited["context_truncated"], .bool(true))
        let plain = try await search(0)
        XCTAssertNil(plain["context_truncated"])
        XCTAssertNil(plain["matches"]?.arrayValue?.first?.objectValue?["context"])
    }
}
