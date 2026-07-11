import Foundation
import SwiftUI

struct BashResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    @Environment(\.agentLiveBashExecutionByItemID) private var liveBashExecutionByItemID

    private func status(for parsedResult: BashToolResultParser.ParsedResult) -> ToolCardStatus {
        if parsedResult.isRunning {
            return .running
        }
        return ToolResultStatusResolver.resolve(
            toolIsError: item.toolIsError,
            raw: item.toolResultJSON,
            fallback: .neutral
        )
    }

    private func subtitle(for parsedResult: BashToolResultParser.ParsedResult) -> String? {
        if let command = parsedResult.command,
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return command
        }
        if let processID = parsedResult.processID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processID.isEmpty
        {
            if processID.lowercased().hasPrefix("session:") {
                return processID
            }
            return "pid \(processID)"
        }
        return nil
    }

    private func isExpandable(for parsedResult: BashToolResultParser.ParsedResult) -> Bool {
        let output = parsedResult.output?.trimmingCharacters(in: .whitespacesAndNewlines)
        if parsedResult.isSummaryOnly, output?.isEmpty != false {
            return false
        }
        if parsedResult.isRunning {
            return true
        }
        return output?.isEmpty == false
    }

    var body: some View {
        let liveExecution = liveBashExecutionByItemID[item.id]
        let parsedResult = liveExecution?.parsedResult ?? BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON)
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Bash",
            subtitle: subtitle(for: parsedResult) ?? storageStatusSubtitle(for: item),
            status: status(for: parsedResult),
            timestamp: item.timestamp,
            isExpandable: isExpandable(for: parsedResult),
            debugItemID: item.id,
            debugToolName: normalizedToolCardName(item.toolName) ?? "bash",
            debugBashPhase: parsedResult.isRunning ? .live : .completed,
            isExpanded: $isExpanded
        ) {
            BashTerminalOutputView(
                output: parsedResult.output,
                isRunning: parsedResult.isRunning
            )
        }
    }
}

private struct BashTerminalOutputView: View {
    let output: String?
    let isRunning: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.agentApprovalVisible) private var isApprovalVisible

    private let bottomID = "bash-output-bottom"

    private static let lineHeight: CGFloat = 15 // ~11pt monospaced + leading
    private static let verticalPadding: CGFloat = 16 // 8pt top + 8pt bottom
    private static let tiers: [Int] = [1, 5, 14]

    private var terminalBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.08)
            : Color.primary.opacity(0.05)
    }

    private func terminalText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(colorScheme == .dark ? Color(white: 0.85) : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    private func outputHeight(for text: String) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CGFloat(Self.tiers[0]) * Self.lineHeight + Self.verticalPadding
        }
        let lineCount = trimmed.utf8.lazy.count(where: { $0 == UInt8(ascii: "\n") }) + 1
        let tier = Self.tiers.first { lineCount <= $0 } ?? Self.tiers.last!
        return CGFloat(tier) * Self.lineHeight + Self.verticalPadding
    }

    var body: some View {
        let text = output ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !isRunning {
                Text("No output")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .frame(height: outputHeight(for: ""), alignment: .topLeading)
                    .background(terminalBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            let height = outputHeight(for: text)
            let isLarge = height >= CGFloat(Self.tiers.last!) * Self.lineHeight + Self.verticalPadding
            if isLarge {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        terminalText(text)
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: height)
                    .background(terminalBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onAppear {
                        guard !isApprovalVisible else { return }
                        DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .onChange(of: text) { _, _ in
                        guard isRunning, !isApprovalVisible else { return }
                        DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                }
            } else {
                terminalText(text)
                    .frame(height: height, alignment: .topLeading)
                    .background(terminalBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
