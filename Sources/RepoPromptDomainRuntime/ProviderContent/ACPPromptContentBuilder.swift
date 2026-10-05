import Foundation
import RepoPromptWorkspaceCore
import UniformTypeIdentifiers

package enum ACPPromptContentBuilder {
    package enum Error: LocalizedError, Equatable {
        case unreadableLocalImage(String)

        package var errorDescription: String? {
            switch self {
            case let .unreadableLocalImage(path):
                "Unable to read image attachment at \(path)."
            }
        }
    }

    package static func blocks(
        text: String,
        attachments: [AgentImageAttachment],
        transientImages: [AITransientImage] = []
    ) throws -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !text.isEmpty || (attachments.isEmpty && transientImages.isEmpty) {
            blocks.append([
                "type": "text",
                "text": text
            ])
        }

        for attachment in attachments {
            if let block = try imageBlock(for: attachment) {
                blocks.append(block)
            }
        }
        for image in transientImages {
            if let annotation = image.titleAnnotation {
                blocks.append([
                    "type": "text",
                    "text": annotation
                ])
            }
            blocks.append([
                "type": "image",
                "mimeType": image.mediaType.rawValue,
                "data": image.base64Payload
            ])
        }

        return blocks
    }

    private static func imageBlock(for attachment: AgentImageAttachment) throws -> [String: Any]? {
        switch attachment.source {
        case let .localFile(rawPath):
            let url: URL
            let data: Data
            do {
                url = try localImageFileURL(exactPath: rawPath)
                data = try Data(contentsOf: url)
            } catch {
                throw Error.unreadableLocalImage(rawPath)
            }
            return [
                "type": "image",
                "mimeType": mimeType(forPathExtension: url.pathExtension, fallbackTitle: attachment.title),
                "data": data.base64EncodedString(),
                "uri": url.absoluteString
            ]
        case let .url(rawURL):
            let urlString = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty else { return nil }
            let extensionCandidate = URL(string: urlString)?.pathExtension
            return [
                "type": "image",
                "mimeType": mimeType(forPathExtension: extensionCandidate, fallbackTitle: attachment.title),
                "uri": urlString
            ]
        }
    }

    /// The Codable attachment format also permits legacy CWD-relative native paths.
    /// This platform bridge validates native text without trimming, URL decoding,
    /// home expansion or lexical dot/symlink resolution.
    private static func localImageFileURL(exactPath: String) throws -> URL {
        let platformPath: String = if exactPath.hasPrefix("/") {
            try WorkspaceAbsolutePath.nativeText(exactPath).utf8ForPlatform()
        } else {
            try WorkspaceRelativePath.nativeText(exactPath).utf8ForPlatform()
        }
        return URL(fileURLWithPath: platformPath)
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
