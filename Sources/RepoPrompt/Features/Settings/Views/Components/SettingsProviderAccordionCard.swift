import SwiftUI

/// Shared accessible accordion shell for settings provider cards.
/// Expansion is owned by the parent; provider state changes never toggle it.
struct SettingsProviderAccordionCard<ExpandedContent: View>: View {
    let title: String
    let subtitle: String
    let leadingSystemImage: String?
    let leadingImageFont: Font?
    let leadingContent: AnyView?
    let status: SettingsConnectionStatus
    let statusLabelOverride: String?
    let connectedLabel: String
    let disconnectedLabel: String
    let titleFont: Font
    let subtitleFont: Font
    @Binding var isExpanded: Bool
    let infoAction: (() -> Void)?
    let infoAccessibilityLabel: String?
    let expandedContent: ExpandedContent

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(
        title: String,
        subtitle: String,
        leadingSystemImage: String? = nil,
        leadingImageFont: Font? = nil,
        leadingContent: AnyView? = nil,
        status: SettingsConnectionStatus,
        statusLabelOverride: String? = nil,
        connectedLabel: String = "Connected",
        disconnectedLabel: String = "Not Connected",
        titleFont: Font = .headline,
        subtitleFont: Font = .caption,
        isExpanded: Binding<Bool>,
        infoAction: (() -> Void)? = nil,
        infoAccessibilityLabel: String? = nil,
        @ViewBuilder expandedContent: () -> ExpandedContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leadingSystemImage = leadingSystemImage
        self.leadingImageFont = leadingImageFont
        self.leadingContent = leadingContent
        self.status = status
        self.statusLabelOverride = statusLabelOverride
        self.connectedLabel = connectedLabel
        self.disconnectedLabel = disconnectedLabel
        self.titleFont = titleFont
        self.subtitleFont = subtitleFont
        _isExpanded = isExpanded
        self.infoAction = infoAction
        self.infoAccessibilityLabel = infoAccessibilityLabel
        self.expandedContent = expandedContent()
    }

    private var displayedStatus: String {
        if let statusLabelOverride { return statusLabelOverride }
        return switch status {
        case .connected: connectedLabel
        case .notConnected: disconnectedLabel
        case .connecting, .unavailable, .error: status.label
        }
    }

    private var disclosureAccessibilityLabel: String {
        "\(title), \(displayedStatus), \(isExpanded ? "expanded" : "collapsed")"
    }

    private var disclosureAccessibilityHint: String {
        isExpanded ? "Collapses connection details and actions." : "Expands connection details and actions."
    }

    private func toggleExpansion() {
        if accessibilityReduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        if let leadingContent {
            leadingContent
                .accessibilityHidden(true)
        } else if let leadingSystemImage {
            Image(systemName: leadingSystemImage)
                .font(leadingImageFont ?? titleFont)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }

        Text(title)
            .font(titleFont)
            .foregroundColor(.primary)
            .accessibilityHidden(true)
    }

    private var disclosureLabel: some View {
        HStack(spacing: 10) {
            SettingsConnectionStatusCapsule(
                status: status,
                connectedLabel: connectedLabel,
                disconnectedLabel: disconnectedLabel,
                labelOverride: statusLabelOverride
            )
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let infoAction {
                HStack(spacing: 10) {
                    titleContent

                    Button(action: infoAction) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(infoAccessibilityLabel ?? "More information about \(title)")
                    .accessibilityHint("Opens provider information.")

                    Spacer(minLength: 8)

                    Button(action: toggleExpansion) {
                        disclosureLabel
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(disclosureAccessibilityLabel)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(disclosureAccessibilityHint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            } else {
                Button(action: toggleExpansion) {
                    HStack(spacing: 10) {
                        titleContent
                        Spacer(minLength: 8)
                        disclosureLabel
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(disclosureAccessibilityLabel)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(disclosureAccessibilityHint)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.horizontal, 12)

                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)

                    expandedContent
                        .padding(.horizontal, 12)
                }
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }
}
