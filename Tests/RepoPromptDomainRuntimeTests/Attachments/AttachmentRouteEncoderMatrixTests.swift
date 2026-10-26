import Foundation
import RepoPromptDomainRuntime
import XCTest

/// The compiler cannot check this agreement: a new `AttachmentKind` does not force a route to answer
/// it, and a row may still declare `.unsupported`. A row that promises a part its encoder never
/// emits, or an encoder that emits what its row refuses, fails here. Routes whose encoders live in
/// the app target are covered by `AttachmentRouteEncoderMatrixAppTests` in `RepoPromptTests`.
final class AttachmentRouteEncoderMatrixTests: XCTestCase {
    enum Emitted: Hashable {
        case image
        case document
        case inlineText
    }

    private enum Reach {
        case domainRuntime(Encoder)
        case appTarget
    }

    private typealias Encoder = ([OracleAttachment]) async throws -> Set<Emitted>

    private func reach(of route: AttachmentRoute) -> Reach {
        switch route {
        case .customOpenAI: .domainRuntime(Self.customOpenAI)
        case .claudeCodeStreamJSON: .domainRuntime(Self.claudeStreamJSON)
        case .acp: .domainRuntime(Self.acp)
        case .anthropicMessages, .openAIChat, .openAIResponses, .codexAppServer, .grokBuild: .appTarget
        }
    }

    func testEveryDomainRuntimeEncoderEmitsExactlyWhatItsRowPromisesOrRefusesByName() async throws {
        var exercised = 0
        for route in AttachmentRoute.allCases {
            guard case let .domainRuntime(encode) = reach(of: route) else { continue }
            let row = AttachmentRouteCapability.capability(for: route)
            for (kind, attachment) in Self.samples() {
                let label = "\(route) × \(kind)"
                switch Self.promised(by: row, kind: kind) {
                case let promised?:
                    let emitted = try await encode([attachment])
                    XCTAssertEqual(emitted, [promised], label)
                case nil:
                    do {
                        let emitted = try await encode([attachment])
                        XCTFail("\(label) emitted \(emitted) but its row refuses it")
                    } catch let error as AttachmentAdmissionError {
                        XCTAssertTrue(
                            error.localizedDescription.contains(attachment.fileName),
                            "\(label) refusal must name the file: \(error.localizedDescription)"
                        )
                    }
                }
                exercised += 1
            }
        }
        XCTAssertEqual(exercised, 3 * AttachmentKind.allCases.count)
    }

    func testMixedSetsDeliverWhatTheRowCarriesAndRefuseOnlyTheRest() async throws {
        let csv = Self.sample(.text)
        let png = Self.sample(.image)
        let pdf = Self.sample(.pdf)

        let grok = try await Self.grokBuild([csv])
        XCTAssertEqual(grok, [.inlineText])
        do {
            _ = try await Self.grokBuild([pdf, csv, png])
            XCTFail("Grok Build must refuse the PNG and the PDF")
        } catch let error as AttachmentAdmissionError {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(pdf.fileName), message)
            XCTAssertTrue(message.contains(png.fileName), message)
            XCTAssertFalse(message.contains(csv.fileName), message)
        }

        let custom = try await Self.customOpenAI([csv, png])
        XCTAssertEqual(custom, [.inlineText, .image])
        do {
            _ = try await Self.customOpenAI([pdf, csv, png])
            XCTFail("Custom OpenAI must refuse the PDF")
        } catch let error as AttachmentAdmissionError {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(pdf.fileName), message)
            XCTAssertFalse(message.contains(csv.fileName), message)
            XCTAssertFalse(message.contains(png.fileName), message)
        }
    }

    func testAnEncoderThatReceivesARungItsRowDoesNotDeclareThrowsInsteadOfDropping() throws {
        let pdf = Self.sample(.pdf)
        let planned = try AttachmentEncoding.plan([pdf], route: .anthropicMessages)
        XCTAssertEqual(planned.count, 1)
        let item = try XCTUnwrap(planned.first)
        XCTAssertEqual(
            item.undeclaredRung(on: .acp),
            .rungNotDeclared(fileName: pdf.fileName, kind: .pdf, route: .acp)
        )
        XCTAssertTrue(item.undeclaredRung(on: .acp).localizedDescription.contains(pdf.fileName))
    }

    private static func promised(by row: AttachmentRouteCapability, kind: AttachmentKind) -> Emitted? {
        switch kind {
        case .image: row.image == .nativeImage ? .image : nil
        case .pdf: row.pdf == .nativeDocument ? .document : nil
        case .text: row.text == .inlineText ? .inlineText : nil
        case .binary: nil
        }
    }

    private static func samples() -> [(AttachmentKind, OracleAttachment)] {
        AttachmentKind.allCases.map { ($0, sample($0)) }
    }

    private static func sample(_ kind: AttachmentKind) -> OracleAttachment {
        switch kind {
        case .image:
            AttachmentTestFixtures.attachment(.image(.png, Data([1, 2, 3])), fileName: "diagram.png")
        case .pdf:
            AttachmentTestFixtures.attachment(.pdf(AttachmentTestFixtures.pdfBytes()), fileName: "report.pdf")
        case .text:
            AttachmentTestFixtures.textAttachment("a,b\n1,2\n", fileName: "data.csv")
        case .binary:
            AttachmentTestFixtures.attachment(.binary(Data([0, 1, 2, 3])), fileName: "blob.bin")
        }
    }

    private static func isInlineBlock(_ text: String) -> Bool {
        text.contains("Attached file: data.csv") && text.contains("a,b\n1,2")
    }

    private static func customOpenAI(_ attachments: [OracleAttachment]) async throws -> Set<Emitted> {
        let message = AIMessage(
            systemPrompt: "",
            conversationMessages: [ConversationEntry(role: .user, content: "Question")],
            attachments: attachments,
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
        let data = try JSONEncoder().encode(CustomOpenAIMessageBuilder.messages(for: message))
        let messages = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"])
        return Self.emitted(fromParts: (content as? [[String: Any]]) ?? [["type": "text", "text": content]])
    }

    private static func claudeStreamJSON(_ attachments: [OracleAttachment]) async throws -> Set<Emitted> {
        let line = try ClaudeStreamJSONTransport.input(prompt: "Question", attachments: attachments)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = try XCTUnwrap(payload["message"] as? [String: Any])
        return try Self.emitted(fromParts: XCTUnwrap(message["content"] as? [[String: Any]]))
    }

    private static func acp(_ attachments: [OracleAttachment]) async throws -> Set<Emitted> {
        let blocks = try ACPPromptContentBuilder.blocks(text: "Question", attachments: [], oracleAttachments: attachments)
        return Self.emitted(fromParts: blocks)
    }

    private static func grokBuild(_ attachments: [OracleAttachment]) async throws -> Set<Emitted> {
        let body = try AttachmentEncoding.textOnlyBody(for: attachments, route: .grokBuild, body: "Question")
        return isInlineBlock(body) ? [.inlineText] : []
    }

    private static func emitted(fromParts parts: [[String: Any]]) -> Set<Emitted> {
        var emitted = Set<Emitted>()
        for part in parts {
            switch part["type"] as? String {
            case "image", "image_url": emitted.insert(.image)
            case "document", "file": emitted.insert(.document)
            default:
                if isInlineBlock((part["text"] as? String) ?? "") { emitted.insert(.inlineText) }
            }
        }
        return emitted
    }
}
