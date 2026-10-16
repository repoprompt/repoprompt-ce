import AppKit
import ImageIO
@testable import RepoPromptApp
import RepoPromptDomainRuntime
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
        let attachmentObject = try XCTUnwrap((JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["imageAttachments"] as? [[String: Any]])
        XCTAssertEqual(Set(attachmentObject[0].keys), ["id", "thumbnailData"])
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

    func testTransientImageThumbnailsProduceBoundedOpaqueJPEGPreviews() async throws {
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
            title: "/workspace/private-image.png"
        )
        let attachments = try await AIChatImageAttachment.thumbnails(from: [transient])

        XCTAssertEqual(attachments.count, 1)
        guard let attachment = attachments.first else { return }
        let persistedPreview = try JSONEncoder().encode(attachment)
        XCTAssertFalse(String(decoding: persistedPreview, as: UTF8.self).contains("/workspace/private-image.png"))

        guard let thumb = NSBitmapImageRep(data: attachment.thumbnailData) else {
            XCTFail("Thumbnail did not decode")
            return
        }
        XCTAssertEqual(max(thumb.pixelsWide, thumb.pixelsHigh), AIChatImageAttachment.thumbnailMaxPixelSize)
        let center = thumb.colorAt(x: thumb.pixelsWide / 2, y: thumb.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(center?.brightnessComponent ?? 0, 0.95)

        // Corrupt bytes retain an indicator without retaining the original payload.
        let corrupt = AITransientImage(bytes: Data([0x00, 0x01]), mediaType: .png, title: nil)
        let corruptAttachments = try await AIChatImageAttachment.thumbnails(from: [corrupt])
        XCTAssertEqual(corruptAttachments.count, 1)
        XCTAssertTrue(corruptAttachments[0].thumbnailData.isEmpty)
        let second = AITransientImage(bytes: png, mediaType: .png, title: "second")
        let mixed = try await AIChatImageAttachment.thumbnails(from: [transient, corrupt, second])
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(mixed[0].thumbnailData, mixed[2].thumbnailData)
        XCTAssertTrue(mixed[1].thumbnailData.isEmpty)
        XCTAssertEqual(transient.bytes, png)

        let stored = StoredMessage(isUser: true, rawText: "preview", sequenceIndex: 0, imageAttachments: attachments)
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: JSONEncoder().encode(stored))
        let restored = await OracleViewModel.parseSingleRawMessage(decoded)
        XCTAssertEqual(restored.imageAttachments, attachments)
        XCTAssertNotEqual(attachment.thumbnailData, png)
    }

    func testThumbnailSourceBoundsAndCancelledParent() async throws {
        func image(_ width: Int, _ height: Int) throws -> AITransientImage {
            try autoreleasepool {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ))
                let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                return AITransientImage(bytes: bytes, mediaType: .png, title: nil)
            }
        }
        // Valid encoded fixtures distinguish preflight omission from a corrupt-file fallback.
        for (width, height, expectedCount) in [(8193, 1, 0), (4097, 4096, 0), (8192, 1, 1), (4096, 4096, 1)] {
            let source = try image(width, height)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(source.bytes as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
            XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, width)
            XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, height)
            let previews = try await AIChatImageAttachment.thumbnails(from: [source])
            XCTAssertEqual(previews.count, 1, "\(width)x\(height)")
            XCTAssertEqual(previews[0].thumbnailData.isEmpty, expectedCount == 0)
        }
        let entered = expectation(description: "parent cancelled")
        let task = Task {
            await fulfillment(of: [entered], timeout: 5)
            return try await AIChatImageAttachment.thumbnails(from: [image(1, 1)])
        }
        task.cancel()
        entered.fulfill()
        do {
            _ = try await task.value
            XCTFail("Cancelled preparation must throw")
        } catch is CancellationError {}
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
