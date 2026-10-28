import Foundation

package enum ClaudeStreamJSONTransport {
    package struct EncodingError: Error {}

    package static func input(prompt: String, attachments: [OracleAttachment]) throws -> String {
        let planned = try AttachmentEncoding.plan(attachments, route: .claudeCodeStreamJSON)
        let text = AttachmentEncoding.prependingInlineText(of: planned, to: prompt)
        var content: [[String: Any]] = []
        if !text.isEmpty {
            content.append(["type": "text", "text": text])
        }
        for item in planned {
            switch item.delivery {
            case let .nativeImage(mediaType, data):
                if let annotation = item.titleAnnotation {
                    content.append(["type": "text", "text": annotation])
                }
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType.rawValue,
                        "data": data.base64EncodedString()
                    ]
                ])
            case .inlineText:
                break
            case .nativeDocument:
                throw item.undeclaredRung(on: .claudeCodeStreamJSON)
            }
        }
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else { throw EncodingError() }
        return line + "\n"
    }

    package static func terminalEvent(in data: Data) -> (type: String, payload: [String: Any])? {
        for line in lines(of: data).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = (json["type"] as? String)?.lowercased(),
                  type == "result" || type == "error"
            else { continue }
            return (type: type, payload: json)
        }
        return nil
    }

    package static func indicatesError(_ dict: [String: Any]) -> Bool {
        let type = (dict["type"] as? String)?.lowercased()
        let subtype = (dict["subtype"] as? String)?.lowercased()
        let isError = (dict["is_error"] as? Bool) == true
        let hasErrors = (dict["errors"] as? [Any])?.isEmpty == false
        return type == "error" || isError || subtype?.contains("error") == true || hasErrors
    }

    package static func errorMessage(from dict: [String: Any]) -> String? {
        guard indicatesError(dict) else { return nil }
        for error in dict["errors"] as? [Any] ?? [] {
            let text = (error as? String)
                ?? ((error as? [String: Any]).flatMap { ($0["message"] as? String) ?? ($0["error"] as? String) })
            if let text = nonEmpty(text) { return text }
        }
        for key in ["error", "message", "result"] {
            if let text = nonEmpty(dict[key] as? String) { return text }
        }
        return nil
    }

    /// The terminal event's error, or the last plain-text line when the CLI failed before
    /// emitting stream JSON.
    package static func errorDetail(in data: Data) -> String? {
        if let terminal = terminalEvent(in: data) {
            return errorMessage(from: terminal.payload)
        }
        return lines(of: data).last { !$0.hasPrefix("{") && !$0.hasPrefix("[") }
    }

    private static func lines(of data: Data) -> [String] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            nonEmpty(String(data: Data($0), encoding: .utf8))
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Writes request-scoped images into a private (0700) temporary directory for transports that
/// only accept local file paths. Call `cleanup()` once the request finishes.
package struct OracleTransientImageStaging {
    package struct File {
        package let path: String
        package let title: String?
    }

    package let directory: URL
    package let files: [File]

    package static func stage(_ planned: [PlannedAttachment], route: AttachmentRoute) async throws -> Self? {
        var images: [(mediaType: ImageMediaType, data: Data, title: String?)] = []
        for item in planned {
            switch item.delivery {
            case let .nativeImage(mediaType, data):
                images.append((mediaType, data, item.attachment.normalizedTitle))
            case .inlineText:
                break
            case .nativeDocument:
                throw item.undeclaredRung(on: route)
            }
        }
        guard !images.isEmpty else { return nil }
        try Task.checkCancellation()
        let staged = images
        let task = Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPromptOracleImages-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                var files: [File] = []
                for (index, image) in staged.enumerated() {
                    try Task.checkCancellation()
                    let url = directory.appendingPathComponent(
                        "image-\(index).\(image.mediaType.preferredFileExtension)",
                        isDirectory: false
                    )
                    try image.data.write(to: url, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    files.append(File(path: url.path, title: image.title))
                }
                return Self(directory: directory, files: files)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    package func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
