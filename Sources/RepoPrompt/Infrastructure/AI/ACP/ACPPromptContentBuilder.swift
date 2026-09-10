import Foundation
import UniformTypeIdentifiers

enum ACPPromptContentBuilder {
    enum Error: LocalizedError, Equatable {
        case unreadableLocalImage(String)
        case unsupportedRemoteImage(String)

        var errorDescription: String? {
            switch self {
            case let .unreadableLocalImage(path):
                "Unable to read image attachment at \(path)."
            case let .unsupportedRemoteImage(url):
                "Unable to send remote image attachment at \(url) because ACP requires inline image data."
            }
        }
    }

    static func blocks(
        text: String,
        attachments: [AgentImageAttachment]
    ) throws -> [[String: Any]] {
        try blocks(content: [.text(text)], attachments: attachments)
    }

    static func blocks(
        content: [AgentPromptContentPart],
        attachments: [AgentImageAttachment]
    ) throws -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for part in content {
            switch part {
            case let .text(text):
                guard !text.isEmpty else { continue }
                blocks.append([
                    "type": "text",
                    "text": text
                ])
            case let .image(image):
                if let title = image.normalizedTitle {
                    blocks.append([
                        "type": "text",
                        "text": "Image title: \(title)"
                    ])
                }
                blocks.append([
                    "type": "image",
                    "mimeType": image.mediaType.rawValue,
                    "data": image.base64Payload
                ])
            }
        }

        for attachment in attachments {
            if let block = try imageBlock(for: attachment) {
                blocks.append(block)
            }
        }

        if blocks.isEmpty {
            blocks.append([
                "type": "text",
                "text": ""
            ])
        }

        return blocks
    }

    private static func imageBlock(for attachment: AgentImageAttachment) throws -> [String: Any]? {
        switch attachment.source {
        case let .localFile(rawPath):
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw Error.unreadableLocalImage(path)
            }
            return [
                "type": "image",
                "mimeType": mimeType(forPathExtension: url.pathExtension, fallbackTitle: attachment.title),
                "data": data.base64EncodedString(),
                "uri": url.absoluteString
            ]
        case let .url(rawURL):
            throw Error.unsupportedRemoteImage(rawURL.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func mimeType(forPathExtension pathExtension: String?, fallbackTitle: String?) -> String {
        let candidates = [pathExtension, fallbackTitle.flatMap { URL(fileURLWithPath: $0).pathExtension }]
        for candidate in candidates {
            let ext = candidate?.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) ?? ""
            guard !ext.isEmpty else { continue }
            if let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType,
               mimeType.lowercased().hasPrefix("image/")
            {
                return mimeType
            }
        }
        return "image/png"
    }
}
