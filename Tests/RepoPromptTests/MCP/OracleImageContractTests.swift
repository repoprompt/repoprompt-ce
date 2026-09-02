import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class OracleImageContractTests: XCTestCase {
    func testParserAcceptsOnlyBoundedPathAndOptionalTitleObjects() throws {
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(nil), [])
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(.array([])), [])

        let parsed = try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("  /workspace/diagram.png  "),
                "title": .string("  Architecture  "),
                "_meta": .string("ignored")
            ]),
            .object(["path": .string("/workspace/photo.jpg")])
        ]))

        XCTAssertEqual(parsed, [
            .init(index: 0, path: "  /workspace/diagram.png  ", title: "Architecture"),
            .init(index: 1, path: "/workspace/photo.jpg", title: nil)
        ])
    }

    func testParserRejectsOversizedAndExpandedAttachmentShapes() {
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array(
            (0 ... 10).map { .object(["path": .string("/workspace/\($0).png")]) }
        )))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/image.png"),
                "url": .string("https://example.com/image.png")
            ])
        ])))
        XCTAssertThrowsError(try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/image.png"),
                "title": .string(String(repeating: "x", count: 201))
            ])
        ])))
    }

    func testAskOracleImageDocumentationIsProviderNeutralAndMatchesLimits() {
        let documentation = [
            MCPOracleToolProvider.askOracleImageUsageDescription,
            MCPOracleToolProvider.askOracleImagesArgumentDescription
        ].joined(separator: " ")

        XCTAssertFalse(documentation.lowercased().contains("anthropic"))
        XCTAssertTrue(documentation.contains("10 images"))
        XCTAssertTrue(documentation.contains("20 MiB"))
        XCTAssertTrue(documentation.contains("50 MiB"))
        XCTAssertTrue(documentation.contains("PNG"))
        XCTAssertTrue(documentation.lowercased().contains("rejected"))
    }

    func testRawImagesAtOracleDispatchAreAnInternalInvariantFailure() {
        XCTAssertNoThrow(try OracleViewModel.validateRawImageDispatchInvariant([
            "message": .string("inspect")
        ]))
        XCTAssertThrowsError(try OracleViewModel.validateRawImageDispatchInvariant([
            "images": .array([.object(["path": .string("/workspace/image.png")])])
        ])) { error in
            guard let toolError = error as? ChatToolError else {
                return XCTFail("Expected ChatToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, .internalError)
            XCTAssertTrue(toolError.message.contains("must be consumed before Oracle dispatch"))
        }
    }

    func testAskOracleToolArgumentsAreRedactedBeforePersistence() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/secret.png","title":"Secret"}]}"#
        let item = AgentChatItem.toolCall(
            name: "mcp__RepoPromptCE__ask_oracle",
            argsJSON: raw
        )

        let sanitized = try XCTUnwrap(item.toolArgsJSON)
        XCTAssertTrue(sanitized.contains("inspect"))
        XCTAssertFalse(sanitized.contains("images"))
        XCTAssertFalse(sanitized.contains("/Users/secret.png"))
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(item), as: UTF8.self).contains("secret.png"))

        let unrelated = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        XCTAssertEqual(unrelated.toolArgsJSON, raw)
    }

    func testPartialArgumentsFailClosedOnlyWhenImagesKeyIsPossible() {
        let cases: [(String, String?)] = [
            (#"{"message":"partial""#, #"{"message":"partial""#),
            (#"{"message":"say \"images\": hi""#, #"{"message":"say \"images\": hi""#),
            (#"{"message":"\ud83d"#, #"{"message":"\ud83d"#),
            (#"{"message":"x","m"#, #"{"message":"x","m"#),
            (#"{"message":"x",""#, nil),
            (#"{"message":"x","ima"#, nil),
            (#"{"images":[{"path":"/Users/secret.png""#, nil),
            (#"{"\u0069mages":[{"path":"/Users/secret.png""#, nil),
            (#"{"i\u006Dages":[{"path":"/Users/secret.png""#, nil)
        ]

        for (raw, expected) in cases {
            XCTAssertEqual(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
                    toolName: "ask_oracle",
                    argsJSON: raw
                ),
                expected,
                raw
            )
            XCTAssertEqual(
                AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
                    toolName: "read_file",
                    argsJSON: raw
                ),
                raw,
                raw
            )
        }
    }

    func testEscapedImagesKeysAndPersistedItemsAreSanitized() throws {
        let raw = #"{"\u0069mages":[{"path":"/Users/secret.png"}],"message":"inspect"}"#
        let sanitized = try XCTUnwrap(AgentToolArgumentPersistencePolicy.sanitizedArgsJSON(
            toolName: "ask_oracle",
            argsJSON: raw
        ))
        XCTAssertTrue(sanitized.contains("inspect"))
        XCTAssertFalse(sanitized.contains("secret.png"))

        let source = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        var persisted = AgentChatItemPersist(from: source, sanitizeToolResults: false)
        persisted.toolName = "mcp__RepoPromptCE__ask_oracle"
        let encoded = try JSONEncoder().encode(persisted)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret.png"))
        let decoded = try JSONDecoder().decode(AgentChatItemPersist.self, from: encoded)
        XCTAssertFalse(decoded.toolArgsJSON?.contains("secret.png") == true)
    }

    func testLegacyImageArgumentsAreSanitizedOnDecode() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/legacy-secret.png"}]}"#
        let source = AgentChatItem.toolCall(name: "read_file", argsJSON: raw)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any]
        )
        object["toolName"] = "ask_oracle"
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentChatItem.self, from: legacyData)
        XCTAssertFalse(decoded.toolArgsJSON?.contains("legacy-secret") == true)
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(decoded), as: UTF8.self).contains("legacy-secret"))
    }

    func testUnrelatedAndImageFreeArgumentsRoundTripUnchanged() throws {
        let unrelatedRaw = #"{"images":[{"path":"/tmp/not-an-oracle-image.png"}]}"#
        let unrelated = AgentChatItem.toolCall(name: "read_file", argsJSON: unrelatedRaw)
        let unrelatedRoundTrip = try JSONDecoder().decode(
            AgentChatItem.self,
            from: JSONEncoder().encode(unrelated)
        )
        XCTAssertEqual(unrelatedRoundTrip.toolArgsJSON, unrelatedRaw)

        let oracleRaw = #"{"message":"hi","mode":"plan"}"#
        let oracle = AgentChatItem.toolCall(name: "ask_oracle", argsJSON: oracleRaw)
        let oracleRoundTrip = try JSONDecoder().decode(
            AgentChatItem.self,
            from: JSONEncoder().encode(oracle)
        )
        XCTAssertEqual(oracleRoundTrip.toolArgsJSON, oracleRaw)
    }

    func testLateAndPartialToolArgumentsPreserveTextButRedactImages() throws {
        let raw = #"{"message":"inspect","images":[{"path":"/Users/late-secret.png"}]}"#
        var item = AgentChatItem.toolCall(name: "read_file", argsJSON: nil)
        item.toolName = "ask_oracle"
        item.toolArgsJSON = raw

        let sanitized = try XCTUnwrap(item.toolArgsJSON)
        XCTAssertFalse(sanitized.contains("images"))
        XCTAssertFalse(sanitized.contains("late-secret"))

        item.toolArgsJSON = #"{"message":"partial"#
        XCTAssertEqual(item.toolArgsJSON, #"{"message":"partial"#)
        item.toolArgsJSON = #"{"images":[{"path":"/Users/partial-secret.png"#
        XCTAssertNil(item.toolArgsJSON)
    }
}
