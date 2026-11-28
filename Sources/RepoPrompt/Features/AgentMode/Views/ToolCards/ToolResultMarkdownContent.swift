import CoreFoundation
import Foundation
import MCP
import SwiftUI

struct ToolMarkdownExpandedContent: View {
    let item: AgentChatItem
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var maxHeight: CGFloat {
        fontPreset.scaledClamped(200, max: 320)
    }

    private var output: ToolResultMarkdownRenderer.Output? {
        ToolResultMarkdownRenderer.render(
            toolName: item.toolName,
            argsJSON: item.toolArgsJSON,
            resultPayload: item.toolResultJSON ?? item.text
        )
    }

    var body: some View {
        if let output {
            if output.usesMarkdownView {
                MarkdownTextView(text: output.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ToolScrollableMarkdownTextView(text: output.text, maxHeight: maxHeight)
            }
        } else {
            Text("No result")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

struct ToolScrollableMarkdownTextView: View {
    let text: String
    let maxHeight: CGFloat
    @ObservedObject private var fontScale = FontScaleManager.shared

    /// Use the codeFont size (rawValue - 2) for a tighter fit in tool cards
    private var fontSize: Double {
        max(Double(fontScale.preset.rawValue) - 2, 9)
    }

    var textKitView: TextKitView {
        TextKitView(
            text: .constant(text),
            isEditable: false,
            isSpellCheckEnabled: false,
            fontSize: fontSize,
            useMonospacedFont: true,
            wrapLines: true,
            autohidesScrollers: true,
            scrollerStyle: .overlay
        )
    }

    var body: some View {
        textKitView
            .frame(height: maxHeight, alignment: .topLeading)
    }
}

enum ToolResultMarkdownRenderer {
    struct Output: Equatable {
        let text: String
        let isMarkdown: Bool

        var usesMarkdownView: Bool {
            isMarkdown && text.utf8.count <= 16384
        }
    }

    private enum ResultProjection {
        case transportText(String)
        case fields(String)
        case empty
    }

    private static let resultKeys: Set<String> = ["content", "structuredContent", "isError", "_meta"]
    private static let wrapperKeys = ["Ok", "ok", "Err", "err"]
    /// Follow the DTO fallback's envelope paths only to detect lossy normalization.
    /// These additional keys never authorize treating the result as MCP transport.
    private static let fallbackEnvelopeKeys = wrapperKeys + [
        "structuredContent", "structured_content", "structuredResult", "structured_result", "toolResult", "tool_result"
    ]
    private static let fallbackSingleKeyEnvelopes = ["result", "output", "response", "payload", "data", "value"]

    private static let emitResourceContentKey = "mcp.emitResourceContent"

    static func render(toolName: String?, argsJSON: String?, resultPayload: String?) -> Output? {
        guard let payload = resultPayload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return nil
        }

        if let projection = resultProjection(from: payload) {
            switch projection {
            case let .transportText(text):
                return Output(text: text, isMarkdown: MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName))
            case let .fields(text):
                return Output(text: text, isMarkdown: false)
            case .empty:
                return nil
            }
        }

        let preferredPayload = ToolJSON.preferredStructuredResultJSON(from: payload) ?? payload
        guard looksLikeJSONObjectOrArray(preferredPayload),
              let value = Value.fromJSONString(preferredPayload)
        else {
            return Output(text: preferredPayload, isMarkdown: false)
        }

        let args = argsJSON.flatMap(Value.objectFromJSONString) ?? [:]
        let normalizedToolName = normalizedToolCardName(toolName) ?? ""
        let emitResources = UserDefaults.standard.bool(forKey: emitResourceContentKey)

        let blocks = ToolOutputFormatter.buildContentBlocks(
            toolName: normalizedToolName,
            args: args,
            result: value,
            emitResources: emitResources
        )

        let joinedText = extractText(from: blocks)
        if !joinedText.isEmpty, structuredFields(from: joinedText) == nil {
            return Output(text: joinedText, isMarkdown: MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName))
        }
        return Output(text: structuredFields(from: preferredPayload) ?? "Structured result", isMarkdown: false)
    }

    static func readableResult(_ text: String) -> String {
        switch resultProjection(from: text) {
        case let .transportText(body), let .fields(body):
            body
        case .empty:
            "No result"
        case nil:
            readableStructuredPayload(text)
        }
    }

    static func readableStructuredPayload(_ text: String) -> String {
        structuredFields(from: text) ?? text
    }

    private static func structuredFields(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeJSONObjectOrArray(text),
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        else { return nil }
        return fieldText(value, indent: "")
    }

    private static func fieldText(_ value: Any, indent: String) -> String {
        if let object = value as? [String: Any], !object.isEmpty {
            return object.keys.sorted().compactMap { key in
                object[key].map { fieldLine(key, value: $0, indent: indent) }
            }.joined(separator: "\n")
        }
        if let array = value as? [Any], !array.isEmpty {
            return array.enumerated().map { fieldLine("\($0.offset + 1)", value: $0.element, indent: indent) }.joined(separator: "\n")
        }
        if value is [String: Any] { return indent + "Empty object" }
        if value is [Any] { return indent + "Empty list" }
        if value is NSNull { return indent + "null" }
        if let string = value as? String {
            return indent + string.replacingOccurrences(of: "\n", with: "\n" + indent)
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return indent + (number.boolValue ? "true" : "false")
        }
        return indent + String(describing: value)
    }

    private static func fieldLine(_ key: String, value: Any, indent: String) -> String {
        if value is [String: Any] || value is [Any] || (value as? String)?.contains("\n") == true {
            return "\(indent)\(key):\n" + fieldText(value, indent: indent + "  ")
        }
        return "\(indent)\(key): " + fieldText(value, indent: "")
    }

    private static func resultProjection(from payload: String) -> ResultProjection? {
        guard ToolJSON.looksLikeJSON(payload),
              let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
        else { return nil }
        if let root = root as? [String: Any] {
            let wrapper = root.count == 1 ? wrapperKeys.first { root[$0] != nil } : nil
            if let result = (wrapper.flatMap { root[$0] } ?? root) as? [String: Any],
               result.keys.allSatisfy(resultKeys.contains),
               let blocks = result["content"] as? [[String: Any]], blocks.allSatisfy(isMCPContentBlock),
               isOptionalObject(result["_meta"]), isOptionalBoolean(result["isError"])
            {
                return transportProjection(result, blocks: blocks, isErrorWrapper: wrapper?.lowercased() == "err")
            }
        }
        // Do not send a rejected content shape through ToolJSON: its DTO-oriented
        // fallback can choose a nested text value and lose the original fields.
        return containsContentCandidate(root) ? .fields(fieldText(root, indent: "")) : nil
    }

    private static func transportProjection(
        _ result: [String: Any], blocks: [[String: Any]], isErrorWrapper: Bool
    ) -> ResultProjection {
        if let structured = result["structuredContent"], !(structured is NSNull) {
            return .fields(fieldText(structured, indent: ""))
        }
        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !text.isEmpty {
            return structuredFields(from: text).map(ResultProjection.fields) ?? .transportText(text)
        }
        if isErrorWrapper || result["isError"] as? Bool == true {
            return .fields("Tool reported an error without text.")
        }
        return blocks.contains { $0["type"] as? String != "text" } ? .fields("No text result") : .empty
    }

    private static func containsContentCandidate(_ value: Any, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        if let object = value as? [String: Any] {
            if object["content"] is [Any] { return true }
            if fallbackEnvelopeKeys.contains(where: { key in
                object[key].map { containsContentCandidate($0, depth: depth + 1) } == true
            }) {
                return true
            }
            if object.count == 1, let (key, nested) = object.first, fallbackSingleKeyEnvelopes.contains(key) {
                return containsContentCandidate(nested, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            return array.contains { containsContentCandidate($0, depth: depth + 1) }
        }
        return false
    }

    private static func isMCPContentBlock(_ block: [String: Any]) -> Bool {
        let commonKeys: Set = ["type", "annotations", "_meta"]
        guard isMCPAnnotations(block["annotations"]), isOptionalObject(block["_meta"]) else { return false }
        switch block["type"] as? String {
        case "text":
            return block["text"] is String && block.keys.allSatisfy(commonKeys.union(["text"]).contains)
        case "image", "audio":
            return block["data"] is String && block["mimeType"] is String
                && block.keys.allSatisfy(commonKeys.union(["data", "mimeType"]).contains)
        case "resource":
            guard let resource = block["resource"] as? [String: Any] else { return false }
            let resourceKeys: Set = ["uri", "mimeType", "text", "blob", "_meta"]
            return block.keys.allSatisfy(commonKeys.union(["resource"]).contains)
                && resource.keys.allSatisfy(resourceKeys.contains) && resource["uri"] is String
                && isOptionalObject(resource["_meta"]) && isOptionalString(resource["mimeType"])
                && isOptionalString(resource["text"]) && isOptionalString(resource["blob"])
                && ((resource["text"] is String) != (resource["blob"] is String))
        case "resource_link":
            return block["uri"] is String && block["name"] is String
                && ["title", "description", "mimeType"].allSatisfy { isOptionalString(block[$0]) }
                && block.keys.allSatisfy(commonKeys.union(["uri", "name", "title", "description", "mimeType"]).contains)
        default:
            return false
        }
    }

    private static func isMCPAnnotations(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        let annotationKeys: Set = ["audience", "priority", "lastModified"]
        guard let object = value as? [String: Any], object.keys.allSatisfy(annotationKeys.contains),
              isOptionalString(object["lastModified"])
        else { return false }
        if let audience = object["audience"], !(audience is NSNull) {
            guard let roles = audience as? [String], roles.allSatisfy({ $0 == "user" || $0 == "assistant" }) else { return false }
        }
        if let priority = object["priority"], !(priority is NSNull) {
            guard let number = priority as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  (0 ... 1).contains(number.doubleValue)
            else { return false }
        }
        return true
    }

    private static func isOptionalObject(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is [String: Any]
    }

    private static func isOptionalString(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is String
    }

    private static func isOptionalBoolean(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func looksLikeJSONObjectOrArray(_ payload: String) -> Bool {
        guard let first = payload.first, let last = payload.last else {
            return false
        }
        return (first == "{" && last == "}") || (first == "[" && last == "]")
    }

    private static func extractText(from blocks: [MCP.Tool.Content]) -> String {
        let textParts = blocks.compactMap { block -> String? in
            if case let .text(text: text, annotations: _, _meta: _) = block {
                return text
            }
            return nil
        }
        return textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
