import AppKit
@testable import RepoPromptApp
import XCTest

final class ChatHistoryJSONOnlyTests: XCTestCase {
    func testCurrentChatSessionSaveLoadUsesCEWorkspaceRoot() async throws {
        let message = StoredMessage(
            isUser: false,
            rawText: "assistant reply",
            sequenceIndex: 0
        )
        let workspace = WorkspaceModel(name: "Chat JSON Only", repoPaths: ["/tmp/root"])
        let session = ChatSession(name: "Current Session", messages: [message])
        let service = ChatDataService()

        let fileURL = try await service.saveChatSession(session, for: workspace)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().deletingLastPathComponent()) }

        XCTAssertTrue(fileURL.path.contains("/Application Support/RepoPrompt CE/Workspaces/"), fileURL.path)
        XCTAssertFalse(fileURL.path.contains("/Application Support/RepoPrompt/Workspaces/"), fileURL.path)

        let loaded = try await service.loadChatSession(from: fileURL)
        XCTAssertEqual(loaded.name, "Current Session")
        XCTAssertEqual(loaded.messages.count, 1)
        XCTAssertEqual(loaded.messages[0].rawText, "assistant reply")
    }

    func testOracleGroupProjectionMetadataRoundTripsAndRemainsOptionalForLegacySessions() throws {
        let groupID = UUID()
        let projection = ChatSession(
            oracleGroupID: groupID,
            oracleLaneIndex: 2,
            oracleGroupSize: 4,
            oracleModelRaw: "model-c",
            name: "Grouped Oracle",
            oracleExecutionAuthority: .frozen
        )

        let decoded = try JSONDecoder().decode(
            ChatSession.self,
            from: JSONEncoder().encode(projection)
        )
        XCTAssertEqual(decoded.oracleGroupID, groupID)
        XCTAssertEqual(decoded.oracleLaneIndex, 2)
        XCTAssertEqual(decoded.oracleGroupSize, 4)
        XCTAssertEqual(decoded.oracleModelRaw, "model-c")
        XCTAssertEqual(decoded.oracleExecutionAuthority, .frozen)

        let legacy = try JSONDecoder().decode(
            ChatSession.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","savedAt":0,"messages":[]}"#.utf8)
        )
        XCTAssertNil(legacy.oracleGroupID)
        XCTAssertNil(legacy.oracleLaneIndex)
        XCTAssertNil(legacy.oracleGroupSize)
        XCTAssertNil(legacy.oracleExecutionAuthority)
    }

    func testStoredMessageImageAttachmentsRoundTripAndRemainOptionalForLegacy() throws {
        let attachment = AIChatImageAttachment(
            mediaType: "image/png",
            title: "screenshot",
            thumbnailData: Data([0xFF, 0xD8, 0xFF, 0xE0])
        )
        let original = StoredMessage(
            isUser: true,
            rawText: "look at this",
            sequenceIndex: 3,
            imageAttachments: [attachment]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: encoded)
        XCTAssertEqual(decoded.imageAttachments?.count, 1)
        XCTAssertEqual(decoded.imageAttachments?.first?.mediaType, "image/png")
        XCTAssertEqual(decoded.imageAttachments?.first?.title, "screenshot")
        XCTAssertEqual(decoded.imageAttachments?.first?.thumbnailData, attachment.thumbnailData)

        // Legacy payloads without the field must still decode.
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "isUser": true,
          "rawText": "base",
          "timestamp": 0,
          "sequenceIndex": 0
        }
        """
        let legacyDecoded = try JSONDecoder().decode(StoredMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(legacyDecoded.imageAttachments)
    }

    func testTransientImageThumbnailsProduceBoundedOpaqueJPEGPreviews() async {
        // 1200x800 fully transparent PNG: the thumbnail must be bounded and matted
        // onto white, since JPEG drops alpha and would otherwise render black.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1200,
            pixelsHigh: 800,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let png = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("Failed to construct PNG fixture")
            return
        }

        let transient = AITransientImage(
            bytes: png,
            mediaType: .png,
            title: "big screenshot"
        )
        let attachments = await AIChatImageAttachment.thumbnails(from: [transient])

        XCTAssertEqual(attachments.count, 1)
        guard let attachment = attachments.first else { return }
        XCTAssertEqual(attachment.mediaType, "image/png")
        XCTAssertEqual(attachment.title, "big screenshot")

        guard let thumb = NSBitmapImageRep(data: attachment.thumbnailData) else {
            XCTFail("Thumbnail did not decode")
            return
        }
        XCTAssertEqual(max(thumb.pixelsWide, thumb.pixelsHigh), AIChatImageAttachment.thumbnailMaxPixelSize)
        let center = thumb.colorAt(x: thumb.pixelsWide / 2, y: thumb.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(center?.brightnessComponent ?? 0, 0.95)

        // Corrupt bytes must be skipped rather than crashing.
        let corrupt = AITransientImage(bytes: Data([0x00, 0x01]), mediaType: .png, title: nil)
        let corruptAttachments = await AIChatImageAttachment.thumbnails(from: [corrupt])
        XCTAssertTrue(corruptAttachments.isEmpty)
    }

    func testStoredMessageOmitsLegacyDelegateAndCombinedTextFields() throws {
        let original = StoredMessage(
            isUser: false,
            rawText: "base",
            sequenceIndex: 2
        )

        let encoded = try JSONEncoder().encode(original)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("delegateResults"), encodedString)
        XCTAssertFalse(encodedString.contains("combinedRawText"), encodedString)

        let decoded = try JSONDecoder().decode(StoredMessage.self, from: encoded)
        XCTAssertEqual(decoded.rawText, "base")
    }

    func testLegacyDelegateResultPayloadIsIgnoredInsteadOfFlattened() throws {
        let delegateID = UUID()
        let messageID = UUID()
        let payload = """
        {
          "id": "\(messageID.uuidString)",
          "isUser": false,
          "rawText": "base",
          "combinedRawText": "stale combined should not persist",
          "timestamp": 0,
          "sequenceIndex": 0,
          "delegateResults": [
            { "id": "\(delegateID.uuidString)", "text": "legacy delegate" }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(StoredMessage.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.rawText, "base")

        let encoded = try JSONEncoder().encode(decoded)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("legacy delegate"), encodedString)
        XCTAssertFalse(encodedString.contains("combinedRawText"), encodedString)
        XCTAssertFalse(encodedString.contains("delegateResults"), encodedString)
    }

    func testLegacyChatSessionEditPayloadsAreIgnoredOnDecodeAndOmittedOnEncode() throws {
        let sessionID = UUID()
        let messageID = UUID()
        let payload = """
        {
          "id": "\(sessionID.uuidString)",
          "name": "Legacy Edit Session",
          "savedAt": 0,
          "messages": [
            {
              "id": "\(messageID.uuidString)",
              "isUser": false,
              "rawText": "assistant text",
              "timestamp": 0,
              "sequenceIndex": 0
            }
          ],
          "changedFilesByMessage": {
            "\(messageID.uuidString)": []
          },
          "delegateEditItemsByMessage": {
            "\(messageID.uuidString)": []
          }
        }
        """

        let decoded = try JSONDecoder().decode(ChatSession.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.messages.first?.rawText, "assistant text")

        let encoded = try JSONEncoder().encode(decoded)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("changedFilesByMessage"), encodedString)
        XCTAssertFalse(encodedString.contains("delegateEditItemsByMessage"), encodedString)
    }
}
