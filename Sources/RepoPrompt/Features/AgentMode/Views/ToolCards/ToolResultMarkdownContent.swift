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

    private var markdown: String? {
        ToolResultMarkdownRenderer.renderMarkdown(
            toolName: item.toolName,
            argsJSON: item.toolArgsJSON,
            resultPayload: item.toolResultJSON
        )
    }

    var body: some View {
        if let markdown = markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !markdown.isEmpty {
            ToolScrollableMarkdownTextView(
                text: markdown,
                maxHeight: maxHeight
            )
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
            wrapLines: false,
            autohidesScrollers: true,
            scrollerStyle: .overlay
        )
    }

    var body: some View {
        textKitView
            .frame(height: maxHeight, alignment: .topLeading)
    }
}

private enum ToolResultMarkdownRenderer {
    private static let emitResourceContentKey = "mcp.emitResourceContent"

    static func renderMarkdown(toolName: String?, argsJSON: String?, resultPayload: String?) -> String? {
        guard let payload = resultPayload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return nil
        }

        if let transportMarkdown = mcpTransportMarkdown(from: payload) {
            return transportMarkdown
        }

        let preferredPayload = ToolJSON.preferredStructuredResultJSON(from: payload) ?? payload
        guard looksLikeJSONObjectOrArray(preferredPayload),
              let value = Value.fromJSONString(preferredPayload)
        else {
            return preferredPayload
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
        if !joinedText.isEmpty {
            return joinedText
        }
        return preferredPayload
    }

    private static func mcpTransportMarkdown(from payload: String) -> String? {
        guard let object = ToolRawJSON.object(from: payload) else { return nil }
        let envelope = (object["Ok"] as? [String: Any])
            ?? (object["ok"] as? [String: Any])
            ?? (object["Err"] as? [String: Any])
            ?? (object["err"] as? [String: Any])
        guard let content = envelope?["content"] as? [Any], !content.isEmpty else { return nil }
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
