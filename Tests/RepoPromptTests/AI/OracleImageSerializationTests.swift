import Foundation
@testable import RepoPromptApp
import SwiftAnthropic
import XCTest

final class OracleImageSerializationTests: XCTestCase {
    func testAnthropicAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(AnthropicProvider.makeMessages(for: makeMessage()))
        let text = try jsonText(json)

        XCTAssertEqual(countObjects(type: "image", in: json), 1)
        XCTAssertTrue(text.contains("Image title: Diagram"))
        XCTAssertTrue(text.contains("AQID"))
        XCTAssertFalse(text.contains("/Users/secret.png"))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertFalse(try jsonText(messages[0]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testRouteAdmissionAllowsOnlyDirectBuiltInAnthropicRoutes() {
        XCTAssertTrue(OracleImageRouteAdmission.supports(.claude4Sonnet))
        XCTAssertTrue(OracleImageRouteAdmission.supports(.claude4Opus))

        XCTAssertFalse(OracleImageRouteAdmission.supports(.gpt5))
        XCTAssertFalse(OracleImageRouteAdmission.supports(
            .openAIServiceTierVariant(base: .gpt5, tier: "flex")
        ))
        XCTAssertFalse(OracleImageRouteAdmission.supports(.openaiCustom(name: "custom")))
        XCTAssertFalse(OracleImageRouteAdmission.supports(.anthropicCustom(name: "custom")))
        XCTAssertFalse(OracleImageRouteAdmission.supports(.codexCustom(name: "codex")))
        XCTAssertFalse(OracleImageRouteAdmission.supports(.ollama))
    }

    private func makeMessage() -> AIMessage {
        AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                .init(role: .user, content: "first"),
                .init(role: .assistant, content: "answer"),
                .init(role: .user, content: "final")
            ],
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
    }

    private func jsonObject(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func countObjects(type: String, in value: Any) -> Int {
        if let object = value as? [String: Any] {
            return (object["type"] as? String == type ? 1 : 0)
                + object.values.reduce(0) { $0 + countObjects(type: type, in: $1) }
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + countObjects(type: type, in: $1) }
        }
        return 0
    }
}
