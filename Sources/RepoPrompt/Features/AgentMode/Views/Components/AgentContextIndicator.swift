import SwiftUI

enum AgentContextRatioDisplay {
    static let unknownPlaceholder = "\u{2014}"

    static func displayedPercent(used: Int?, window: Int, isKnown: Bool) -> Int? {
        guard isKnown, window > 0, let used else { return nil }
        let percent = min(max((Double(used) / Double(window)) * 100, 0), 100)
        return Int(percent.rounded())
    }

    static func denominatorText(window: Int, isKnown: Bool) -> String {
        isKnown ? AgentContextIndicator.formatTokens(window) : unknownPlaceholder
    }
}

struct AgentContextIndicator: View {
    enum Style {
        case compact
        case labeled
    }

    let contextWindowTokens: Int?
    let usedTokens: Int?
    let sourceLabel: String?
    let style: Style
    /// Gates standalone `.labeled` "{tokens} window" facts and ratio displays
    /// on knownness. When false (denominator unknown, e.g. Codex/GPT pre-usage), standalone
    /// window text and ratio denominators render the shared em-dash placeholder instead of
    /// the fabricated fallback, and percent/ring displays are suppressed. Defaulted so existing
    /// callers compile unchanged; the ratio/math `contextWindowTokens` param stays non-optional-typed.
    let isContextWindowKnown: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    init(
        contextWindowTokens: Int?,
        usedTokens: Int?,
        sourceLabel: String? = nil,
        isContextWindowKnown: Bool = true,
        style: Style = .compact
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.usedTokens = usedTokens
        self.sourceLabel = sourceLabel
        self.isContextWindowKnown = isContextWindowKnown
        self.style = style
    }

    private var contextUsedPercent: Int? {
        guard let contextWindowTokens else { return nil }
        return AgentContextRatioDisplay.displayedPercent(
            used: usedTokens,
            window: contextWindowTokens,
            isKnown: isContextWindowKnown
        )
    }

    private var warningColor: Color {
        guard let used = contextUsedPercent else { return .secondary }
        if used > 90 { return .red }
        if used > 75 { return .orange }
        return .secondary
    }

    private var tooltipText: String {
        guard let usedTokens else { return "Context usage unavailable" }
        guard let contextWindowTokens else {
            return "Used tokens: \(Self.formatTokens(usedTokens))"
        }

        let denominator = AgentContextRatioDisplay.denominatorText(
            window: contextWindowTokens,
            isKnown: isContextWindowKnown
        )
        guard let used = contextUsedPercent else {
            return "\(Self.formatTokens(usedTokens)) / \(denominator) tokens"
        }
        return "Context used: \(used)%\n\(Self.formatTokens(usedTokens)) / \(denominator) tokens"
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
                            Text("\(Self.formatTokens(usedTokens)) / \(AgentContextRatioDisplay.denominatorText(window: contextWindowTokens, isKnown: isContextWindowKnown))")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        } else if let usedTokens {
                            Text("\(Self.formatTokens(usedTokens)) used")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        } else if let contextWindowTokens {
                            // Gate the standalone window fact; render an em-dash placeholder
                            // (persistent row, never removed) rather than the fabricated fallback.
                            if isContextWindowKnown {
                                Text("\(Self.formatTokens(contextWindowTokens)) window")
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                            } else {
                                Text(AgentContextRatioDisplay.unknownPlaceholder)
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                            }
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
        let used = contextUsedPercent
        let progress = used.map { min(max(Double($0) / 100, 0), 1) } ?? 0
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
            if let used {
                Text("\(used)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: size * 0.36, weight: .medium))
                    .foregroundStyle(warningColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(used == nil ? "Context usage ratio unavailable" : "Context used \(used ?? 0) percent")
    }
}
