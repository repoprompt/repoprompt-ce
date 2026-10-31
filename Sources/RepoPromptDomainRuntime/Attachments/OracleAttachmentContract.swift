import Foundation
import MCP

package enum OracleAttachmentContract {
    package static let argumentName = "attachments"
    package static let pathField = "path"
    package static let titleField = "title"

    /// The argument this contract replaced, shipped in v1.6.0. It stays accepted as a deprecated,
    /// unadvertised alias so released skills and workflows keep working, but it is bounded to its old
    /// meaning: every item must be a PNG, JPEG, GIF or WebP image (`OracleAttachmentRequest.imageOnly`).
    /// It stays in `redactedArgumentKeys` so its filesystem paths are never written to a transcript.
    package static let legacyImagesArgumentName = "images"

    package static let redactedArgumentKeys: Set<String> = [argumentName, legacyImagesArgumentName]

    package static let oracleToolNames = [MCPWindowToolName.askOracle, MCPWindowToolName.oracleSend]

    private static let itemFields: Set = [pathField, titleField]
    private static let bytesPerMiB = 1_048_576

    /// Parses the Oracle file arguments from a tool call: `attachments`, or the deprecated image-only
    /// `images` alias. Passing both is ambiguous and rejected rather than merged.
    package static func parseArguments(
        _ args: [String: Value],
        limits: OracleAttachmentLimits = .production
    ) throws -> [OracleAttachmentRequest] {
        if let legacy = args[legacyImagesArgumentName] {
            guard args[argumentName] == nil else {
                throw MCPError.invalidParams(
                    "Pass `\(argumentName)` or the deprecated `\(legacyImagesArgumentName)`, not both. Prefer `\(argumentName)`."
                )
            }
            return try parse(legacy, limits: limits, label: legacyImagesArgumentName, imageOnly: true)
        }
        return try parse(args[argumentName], limits: limits)
    }

    package static func headlessUnsupportedMessage() -> String {
        "Oracle `\(argumentName)` require the app backend; the direct headless backend cannot attach files."
    }

    package static func parse(
        _ value: Value?,
        limits: OracleAttachmentLimits = .production,
        label argumentLabel: String = argumentName,
        imageOnly: Bool = false
    ) throws -> [OracleAttachmentRequest] {
        guard let value else { return [] }
        guard case let .array(items) = value else {
            throw MCPError.invalidParams("\(argumentLabel) must be an array of objects.")
        }
        guard !items.isEmpty else { return [] }
        guard items.count <= limits.maxCount else {
            throw MCPError.invalidParams("\(argumentLabel) supports at most \(limits.maxCount) items.")
        }
        return try items.enumerated().map { index, item in
            let label = "\(argumentLabel)[\(index)]"
            guard case let .object(object) = item else {
                throw MCPError.invalidParams("\(label) must be an object.")
            }
            let unsupported = object.keys.filter { !itemFields.contains($0) }.sorted()
            guard unsupported.isEmpty else {
                throw MCPError.invalidParams("\(label) unsupported keys: \(unsupported.joined(separator: ", ")).")
            }
            guard let rawPath = object[pathField]?.stringValue else {
                throw MCPError.invalidParams("\(label).\(pathField) must be a string.")
            }
            guard !rawPath.isEmpty else {
                throw MCPError.invalidParams("\(label).\(pathField) must be a non-empty local file path.")
            }
            let title: String?
            if let titleValue = object[titleField] {
                guard let rawTitle = titleValue.stringValue else {
                    throw MCPError.invalidParams("\(label).\(titleField) must be a string.")
                }
                let normalized = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalized.count <= limits.maxTitleLength else {
                    throw MCPError.invalidParams(
                        "\(label).\(titleField) exceeds \(limits.maxTitleLength) characters."
                    )
                }
                title = normalized.isEmpty ? nil : normalized
            } else {
                title = nil
            }
            return OracleAttachmentRequest(index: index, path: rawPath, title: title, imageOnly: imageOnly)
        }
    }

    package static let headlessLimitationNote =
        " Requires the app backend; the direct headless backend rejects `\(argumentName)`."

    package static let pathDescription =
        "Canonical absolute path inside a currently loaded workspace root, or the exact path of a file attached to this agent session"

    package static let titleDescription = "Optional transient attachment title"

    package static func argumentDescription(limits: OracleAttachmentLimits = .production) -> String {
        "Optional workspace-local files attached to the Oracle request: \(acceptedKindsClause()). Each item requires canonical absolute `\(pathField)` inside a loaded workspace root (including screenshots saved under a workspace root) or the exact path of a file the user attached to this agent session, and may include transient `\(titleField)`. \(deliveryClause()) Remote URLs, sibling attachments, and arbitrary paths outside loaded roots are rejected. \(limitsClause(limits)) The selected provider or model may impose additional restrictions; accepted attachments do not guarantee full-request or model-context fit."
    }

    package static func usageDescription(limits: OracleAttachmentLimits = .production) -> String {
        "Optional `\(argumentName)` attaches workspace-local files to the Oracle request: \(acceptedKindsClause()). Each item is `{\(pathField),\(titleField)?}` with a canonical absolute path inside the current loaded roots — a screenshot saved under a workspace root is fine — or the exact path of a file the user attached to this agent session (pasted or dropped into the composer; its path is listed in the user's message). Remote URLs, relative paths, sibling attachments, and arbitrary files outside the loaded roots are rejected before a message is sent. \(deliveryClause()) Attachment content is additional to pre-send text estimates and Context Builder text-selection budgets. Originals, not transcript thumbnails, are sent to each Oracle lane; group fan-out multiplies attachment usage/cost, not any one request's attachment cap. Provider-reported input totals may already include attachment usage. Session attachment files are normally deleted when the agent turn ends; forward them during that turn. Originals are this-turn-only: continuations do not automatically reattach prior attachments or send saved thumbnails. \(limitsClause(limits)) The selected provider or model may impose additional restrictions; accepted attachments do not guarantee full-request or model-context fit."
    }

    package static func schemaProperty(
        limits: OracleAttachmentLimits = .production,
        headlessLimitation: Bool = false
    ) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(argumentDescription(limits: limits) + (headlessLimitation ? headlessLimitationNote : "")),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    pathField: .object([
                        "type": .string("string"),
                        "description": .string(pathDescription)
                    ]),
                    titleField: .object([
                        "type": .string("string"),
                        "description": .string(titleDescription),
                        "maxLength": .int(limits.maxTitleLength)
                    ])
                ]),
                "required": .array([.string(pathField)])
            ]),
            "maxItems": .int(limits.maxCount)
        ])
    }

    /// Drops every key in `redactedArgumentKeys` from serialized Oracle send arguments. Fails closed:
    /// malformed or truncated arguments may hide an unparseable attachment key, so nil is returned
    /// instead.
    package static func redactingArgsJSON(_ argsJSON: String) -> String? {
        guard let data = argsJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var removed = false
        for key in redactedArgumentKeys where object.removeValue(forKey: key) != nil {
            removed = true
        }
        guard removed else { return argsJSON }
        guard JSONSerialization.isValidJSONObject(object),
              let sanitized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: sanitized, encoding: .utf8)
    }

    private enum Coverage {
        case every, some, none

        init(_ supported: [Bool]) {
            if supported.allSatisfy(\.self) {
                self = .every
            } else if supported.contains(true) {
                self = .some
            } else {
                self = .none
            }
        }
    }

    private static func coverage(_ accepts: (AttachmentRouteCapability) -> Bool) -> Coverage {
        Coverage(AttachmentRoute.allCases.map { accepts(AttachmentRouteCapability.capability(for: $0)) })
    }

    private static func acceptedKinds() -> [AttachmentKind] {
        AttachmentKind.allCases.filter { coverage(for: $0) != .none }
    }

    private static func coverage(for kind: AttachmentKind) -> Coverage {
        switch kind {
        case .image: coverage { $0.image != .unsupported }
        case .pdf: coverage { $0.pdf != .unsupported }
        case .text: coverage { $0.text != .unsupported }
        case .binary: coverage { _ in false }
        }
    }

    private static func acceptedKindsClause() -> String {
        let names = acceptedKinds().map { kind -> String in
            switch kind {
            case .image: "images (PNG, JPEG, GIF, WebP)"
            case .pdf: "PDFs"
            case .text: "UTF-8 text files"
            case .binary: "other binary files"
            }
        }
        switch names.count {
        case 0: return "no file kinds"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    private static func deliveryClause() -> String {
        var sentences = ["Delivery depends on the model selected for the request."]
        for kind in acceptedKinds() {
            let coverage = coverage(for: kind)
            switch (kind, coverage) {
            case (.image, .every): sentences.append("Images are sent as images.")
            case (.image, _): sentences.append("Images are sent as images where the model's transport accepts image input.")
            case (.pdf, .every): sentences.append("PDFs are sent as documents.")
            case (.pdf, _): sentences.append("PDFs are sent as documents only where the model's transport accepts native documents.")
            case (.text, .every): sentences.append("Text files are inlined into the request.")
            case (.text, _): sentences.append("Text files are inlined into the request where the model's transport accepts inline text.")
            case (.binary, _): break
            }
        }
        if coverage(for: .binary) == .none {
            sentences.append("Any other file kind is refused.")
        }
        sentences.append("A file the selected model cannot receive is never dropped: the whole request is refused, naming each file and the reason.")
        return sentences.joined(separator: " ")
    }

    private static func limitsClause(_ limits: OracleAttachmentLimits) -> String {
        var clause = "Limits: \(limits.maxCount) files, \(limits.maxBytesPerFile / bytesPerMiB) MiB each, \(limits.maxTotalBytes / bytesPerMiB) MiB total, measured as raw attachment-file bytes before provider encoding"
        if acceptedKinds().contains(.text) {
            clause += "; a text file is refused above \(limits.maxInlineTextBytes / 1024) KiB rather than truncated"
        }
        return clause + "."
    }
}
