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
            if output.isMarkdown, output.text.utf8.count <= 16384 {
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
    }

    private static let emitResourceContentKey = "mcp.emitResourceContent"

    static func render(toolName: String?, argsJSON: String?, resultPayload: String?) -> Output? {
        guard let payload = resultPayload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return nil
        }

        if let transportText = mcpTransportMarkdown(from: payload) {
            if let fields = structuredFields(from: transportText) {
                return Output(text: fields, isMarkdown: false)
            }
            return Output(text: transportText, isMarkdown: MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(toolName))
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

    static func readablePayload(_ text: String) -> String {
        if let body = mcpTransportMarkdown(from: text) {
            return structuredFields(from: body) ?? body
        }
        return structuredFields(from: text) ?? text
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

    private static func mcpTransportMarkdown(from payload: String) -> String? {
        // Decode the transport itself; ToolJSON.rawObject already unwraps Ok/Err.
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        let envelope = (object["Ok"] as? [String: Any])
            ?? (object["ok"] as? [String: Any])
            ?? (object["Err"] as? [String: Any])
            ?? (object["err"] as? [String: Any])
        guard let content = (envelope ?? object)["content"] as? [Any], !content.isEmpty else { return nil }
        let textParts = content.compactMap { element -> String? in
            guard let block = element as? [String: Any] else { return nil }
            if let type = block["type"] as? String,
               type.lowercased() != "text"
            {
                return nil
            }
            return block["text"] as? String
        }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !textParts.isEmpty else { return nil }
        return textParts.joined(separator: "\n\n")
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
