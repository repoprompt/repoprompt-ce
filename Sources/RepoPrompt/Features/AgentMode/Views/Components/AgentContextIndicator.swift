import SwiftUI

struct AgentContextIndicator: View {
    enum Style {
        case compact
        case labeled
    }

    let contextWindowTokens: Int?
    let usedTokens: Int?
    let sourceLabel: String?
    let style: Style
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    init(contextUsage: AgentContextUsage?, style: Style = .compact) {
        contextWindowTokens = contextUsage?.modelContextWindow
        let last = contextUsage?.lastTotalTokens ?? 0
        let total = contextUsage?.totalTotalTokens ?? 0
        let used = last > 0 ? last : total
        usedTokens = used > 0 ? used : nil
        sourceLabel = nil
        self.style = style
    }

    init(
        contextWindowTokens: Int?,
        usedTokens: Int?,
        sourceLabel: String? = nil,
        style: Style = .compact
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.usedTokens = usedTokens
        self.sourceLabel = sourceLabel
        self.style = style
    }

    private var contextUsedPercent: Double? {
        guard let contextWindowTokens, contextWindowTokens > 0, let usedTokens else {
            return nil
        }
        return min(max((Double(usedTokens) / Double(contextWindowTokens)) * 100, 0), 100)
    }

    private var warningColor: Color {
        guard let used = contextUsedPercent else { return .secondary }
        if used > 90 {
            return .red
        }
        if used > 75 {
            return .orange
        }
        return .secondary
    }

    private var tooltipText: String {
        guard let used = contextUsedPercent else {
            if let usedTokens {
                return "Used tokens: \(Self.formatTokens(usedTokens))"
            }
            return "Context usage unavailable"
        }

        var text = "Context used: \(Int(used.rounded()))%"
        if let usedTokens, let contextWindowTokens {
            text += "\n\(Self.formatTokens(usedTokens)) / \(Self.formatTokens(contextWindowTokens)) tokens"
        }
        return text
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        if usedTokens != nil || contextWindowTokens != nil {
            switch style {
            case .compact:
                contextRing(size: 18, lineWidth: 2.5)
            case .labeled:
                HStack(spacing: 8) {
                    contextRing(size: 24, lineWidth: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        if let usedTokens, let contextWindowTokens {
                            Text("\(Self.formatTokens(usedTokens)) / \(Self.formatTokens(contextWindowTokens))")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        } else if let usedTokens {
                            Text("\(Self.formatTokens(usedTokens)) used")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        } else if let contextWindowTokens {
                            Text("\(Self.formatTokens(contextWindowTokens)) window")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        }

                        Text(sourceLabel ?? "Context usage")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextRing(size: CGFloat, lineWidth: CGFloat) -> some View {
        let used = contextUsedPercent ?? 0
        let progress = min(max(used / 100, 0), 1)
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    warningColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(used.rounded()))")
                .font(fontPreset.swiftUIFont(sizeAtNormal: size * 0.36, weight: .medium))
                .foregroundStyle(warningColor)
        }
        .frame(width: size, height: size)
    }
}
