import AppKit
import ImageIO
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
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

        XCTAssertTrue(fileURL.path.contains("/Application Support/\(MCPFilesystemIdentity.current.applicationStateDirectoryName)/Workspaces/"), fileURL.path)
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

    func testStoredMessageFileAttachmentsRoundTripAndRemainOptionalForLegacy() throws {
        let attachment = AIChatFileAttachment(
            thumbnailData: Data([0xFF, 0xD8, 0xFF, 0xE0])
        )
        let original = StoredMessage(
            isUser: true,
            rawText: "look at this",
            sequenceIndex: 3,
            fileAttachments: [attachment]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: encoded)
        XCTAssertEqual(decoded.fileAttachments?.count, 1)
        let attachmentObject = try XCTUnwrap((JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["imageAttachments"] as? [[String: Any]])
        XCTAssertEqual(Set(attachmentObject[0].keys), ["id", "thumbnailData", "kind", "fileName", "byteCount"])
        XCTAssertEqual(decoded.fileAttachments?.first?.thumbnailData, attachment.thumbnailData)

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
        XCTAssertNil(legacyDecoded.fileAttachments)
    }

    func testStoredMessageDecodesPreRenameImageAttachmentsKey() throws {
        let messageID = "5B1D3C52-0E5C-4B53-9F0C-2D4A6E8F1A01"
        let attachmentID = "9C0E7A44-3B1F-4D7A-8E55-6A2F1B7C9D02"
        let json = """
        {
          "id": "\(messageID)",
          "isUser": true,
          "rawText": "look at this",
          "timestamp": 0,
          "sequenceIndex": 3,
          "allowedFilePaths": null,
          "imageAttachments": [
            { "id": "\(attachmentID)", "thumbnailData": "/9j/4A==" }
          ],
          "promptTokens": null,
          "completionTokens": null,
          "cost": null,
          "modelName": null
        }
        """
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: Data(json.utf8))
        let attachment = try XCTUnwrap(decoded.fileAttachments?.first)
        XCTAssertEqual(decoded.fileAttachments?.count, 1)
        XCTAssertEqual(attachment.id, UUID(uuidString: attachmentID))
        XCTAssertEqual(attachment.thumbnailData, Data([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.fileName, "")
        XCTAssertEqual(attachment.byteCount, 0)
        let presentation = AttachmentPresentation.make(facts: attachment.facts, preview: .available)
        XCTAssertEqual(presentation.face, .preview)
        XCTAssertFalse(presentation.title.isEmpty)
        let withoutPreview = AttachmentPresentation.make(facts: attachment.facts, preview: .unavailable)
        XCTAssertEqual(withoutPreview.face, .glyph(.photo))
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

        let transient = OracleAttachment(
            payload: .image(.png, png),
            fileName: "private-image.png",
            title: "/workspace/private-image.png"
        )
        let attachments = try await AIChatFileAttachment.thumbnails(from: [transient])

        XCTAssertEqual(attachments.count, 1)
        guard let attachment = attachments.first else { return }
        let persistedPreview = try JSONEncoder().encode(attachment)
        XCTAssertFalse(String(decoding: persistedPreview, as: UTF8.self).contains("/workspace/private-image.png"))

        guard let thumb = NSBitmapImageRep(data: attachment.thumbnailData) else {
            XCTFail("Thumbnail did not decode")
            return
        }
        XCTAssertEqual(max(thumb.pixelsWide, thumb.pixelsHigh), AIChatFileAttachment.thumbnailMaxPixelSize)
        let center = thumb.colorAt(x: thumb.pixelsWide / 2, y: thumb.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(center?.brightnessComponent ?? 0, 0.95)

        // Corrupt bytes retain an indicator without retaining the original payload.
        let corrupt = OracleAttachment(payload: .image(.png, Data([0x00, 0x01])), fileName: "image.png", title: nil)
        let corruptAttachments = try await AIChatFileAttachment.thumbnails(from: [corrupt])
        XCTAssertEqual(corruptAttachments.count, 1)
        XCTAssertTrue(corruptAttachments[0].thumbnailData.isEmpty)
        let second = OracleAttachment(payload: .image(.png, png), fileName: "image.png", title: "second")
        let mixed = try await AIChatFileAttachment.thumbnails(from: [transient, corrupt, second])
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(mixed[0].thumbnailData, mixed[2].thumbnailData)
        XCTAssertTrue(mixed[1].thumbnailData.isEmpty)
        XCTAssertEqual(transient.bytes, png)

        let stored = StoredMessage(isUser: true, rawText: "preview", sequenceIndex: 0, fileAttachments: attachments)
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: JSONEncoder().encode(stored))
        let restored = await OracleViewModel.parseSingleRawMessage(decoded)
        XCTAssertEqual(restored.fileAttachments, attachments)
        XCTAssertNotEqual(attachment.thumbnailData, png)
    }

    func testThumbnailSourceBoundsAndCancelledParent() async throws {
        func image(_ width: Int, _ height: Int) throws -> OracleAttachment {
            try autoreleasepool {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ))
                let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                return OracleAttachment(payload: .image(.png, bytes), fileName: "image.png", title: nil)
            }
        }
        // Valid encoded fixtures distinguish preflight omission from a corrupt-file fallback.
        for (width, height, expectedCount) in [(8193, 1, 0), (4097, 4096, 0), (8192, 1, 1), (4096, 4096, 1)] {
            let source = try image(width, height)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(source.bytes as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
            XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, width)
            XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, height)
            let previews = try await AIChatFileAttachment.thumbnails(from: [source])
            XCTAssertEqual(previews.count, 1, "\(width)x\(height)")
            XCTAssertEqual(previews[0].thumbnailData.isEmpty, expectedCount == 0)
        }
        let entered = expectation(description: "parent cancelled")
        let task = Task {
            await fulfillment(of: [entered], timeout: 5)
            return try await AIChatFileAttachment.thumbnails(from: [image(1, 1)])
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
