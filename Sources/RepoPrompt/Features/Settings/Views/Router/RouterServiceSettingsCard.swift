import SwiftUI

struct OpenAIDecisionsRouterServiceSettingsCard: View {
    @ObservedObject var expansionState: RouterOpenAIServiceExpansionState
    let viewModel: RouterSettingsViewModel
    let viewState: RouterSettingsViewState
    @ObservedObject var secretDraftState: RouterSecretDraftState
    let row: RouterSettingsViewModel.ServiceRow
    let usageLabels: [String]
    let configurationInputAnchorID: String
    let serviceHeaderFocus: FocusState<DecisionServiceID?>.Binding
    let serviceHeaderAccessibilityFocus: AccessibilityFocusState<DecisionServiceID?>.Binding
    let configurationInputFocus: FocusState<DecisionServiceID?>.Binding
    let configurationInputAccessibilityFocus: AccessibilityFocusState<DecisionServiceID?>.Binding

    var body: some View {
        RouterServiceSettingsCard(
            viewModel: viewModel,
            viewState: viewState,
            secretDraftState: secretDraftState,
            isExpanded: expansionState.isExpanded,
            row: row,
            usageLabels: usageLabels,
            configurationInputAnchorID: configurationInputAnchorID,
            serviceHeaderFocus: serviceHeaderFocus,
            serviceHeaderAccessibilityFocus: serviceHeaderAccessibilityFocus,
            configurationInputFocus: configurationInputFocus,
            configurationInputAccessibilityFocus: configurationInputAccessibilityFocus
        )
    }
}

struct RouterServiceSettingsCard: View {
    @ObservedObject var viewModel: RouterSettingsViewModel
    @ObservedObject var viewState: RouterSettingsViewState
    @ObservedObject var secretDraftState: RouterSecretDraftState
    let isExpanded: Bool
    let row: RouterSettingsViewModel.ServiceRow
    let usageLabels: [String]
    let configurationInputAnchorID: String
    let serviceHeaderFocus: FocusState<DecisionServiceID?>.Binding
    let serviceHeaderAccessibilityFocus: AccessibilityFocusState<DecisionServiceID?>.Binding
    let configurationInputFocus: FocusState<DecisionServiceID?>.Binding
    let configurationInputAccessibilityFocus: AccessibilityFocusState<DecisionServiceID?>.Binding

    @Environment(\.repoPromptFontScalePreset) private var fontPreset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            serviceHeader
            RouterSettingsAccordionContent(isExpanded: isExpanded) {
                serviceContent
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var serviceContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.bottom, 12)
            expandedContent
        }
    }

    private var serviceHeader: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                viewState.setServiceExpanded(!isExpanded, backendID: row.id)
            }
        } label: {
            serviceHeaderLabel
                .padding(14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused(serviceHeaderFocus, equals: row.id)
        .accessibilityFocused(serviceHeaderAccessibilityFocus, equals: row.id)
        .accessibilityIdentifier("router-service-\(row.id.rawValue)-header")
        .accessibilityLabel("\(displayTitle) routing service")
        .accessibilityValue("\(isExpanded ? "Expanded" : "Collapsed"). \(accessibilityValue)")
        .accessibilityHint(isExpanded ? "Collapse service configuration" : "Expand service configuration")
    }

    private var serviceHeaderLabel: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                serviceIdentityAndCapabilities
                usageBadgeRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            HStack(alignment: .center, spacing: 8) {
                readiness
                disclosureChevron
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var displayTitle: String {
        row.presentation?.title ?? row.displayName
    }

    private var state: RouterSettingsViewModel.ServiceState? {
        viewModel.serviceState(for: row.id)
    }

    private var serviceIdentity: some View {
        HStack(spacing: 7) {
            Text(displayTitle)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let productStatus = row.presentation?.productStatus {
                badge(productStatus.title, emphasis: true)
            }
        }
    }

    private var serviceIdentityAndCapabilities: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                serviceIdentity
                ForEach(capabilityBadges) { item in
                    badge(item.title, emphasis: item.isUsage)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                serviceIdentity
                ForEach(capabilityBadges) { item in
                    badge(item.title, emphasis: item.isUsage)
                }
            }
        }
    }

    @ViewBuilder
    private var usageBadgeRow: some View {
        if !usageBadges.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(usageBadges) { item in
                        badge(item.title, emphasis: item.isUsage)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(usageBadges) { item in
                        badge(item.title, emphasis: item.isUsage)
                    }
                }
            }
        }
    }

    private var readiness: some View {
        Label(readinessLabel, systemImage: readinessIcon)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
            .foregroundStyle(readinessColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var disclosureChevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let presentation = row.presentation {
            VStack(alignment: .leading, spacing: 12) {
                Text(presentation.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(presentation.notices) { notice in
                    noticeView(notice)
                }

                if let label = presentation.secretFieldLabel,
                   presentation.supportedCredentialActions.contains(.validateAndSaveSecret)
                {
                    SecureField(label, text: secretDraftBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isPerformingBackendOperation)
                        .id(configurationInputAnchorID)
                        .focused(configurationInputFocus, equals: row.id)
                        .accessibilityFocused(configurationInputAccessibilityFocus, equals: row.id)
                        .accessibilityLabel("\(displayTitle), \(label)")
                }

                if !presentation.supportedCredentialActions.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { credentialActions(presentation) }
                        VStack(alignment: .leading, spacing: 10) { credentialActions(presentation) }
                    }
                }

                if let message = state?.feedback.message {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        operationFeedbackIcon
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(operationFeedbackColor)
                    .accessibilityElement(children: .combine)
                }

                ForEach(presentation.disclosures.indices, id: \.self) { index in
                    let disclosure = presentation.disclosures[index]
                    disclosureSection(
                        disclosure,
                        links: presentation.links(
                            for: disclosure,
                            isLastDisclosure: index == presentation.disclosures.count - 1
                        )
                    )
                }

                if presentation.disclosures.isEmpty, !presentation.links.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(presentation.links) { link in
                            Link(link.title, destination: link.url)
                        }
                    }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
            }
        } else {
            Text("Configuration is unavailable for this routing service in this build.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func credentialActions(
        _ presentation: DecisionServiceSettingsPresentation
    ) -> some View {
        if presentation.supportedCredentialActions.contains(.validateAndSaveSecret) {
            Button("Validate & Save") {
                let draft = viewState.secretDraftSnapshot(for: row.id)
                Task {
                    if await viewModel.performBackendAction(
                        .validateAndSaveSecret(draft.value),
                        backendID: row.id
                    ) {
                        viewState.clearSecretDraft(for: row.id, ifRevision: draft.revision)
                    }
                }
            }
            .disabled(
                secretDraftState.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.isPerformingBackendOperation
            )
            .accessibilityLabel("\(displayTitle), validate and save key")
        }
        if presentation.supportedCredentialActions.contains(.revalidateStoredSecret) {
            Button("Verify Saved Key") {
                Task {
                    await viewModel.performBackendAction(.revalidateStoredSecret, backendID: row.id)
                }
            }
            .disabled(viewModel.isPerformingBackendOperation)
            .accessibilityLabel("\(displayTitle), verify saved key")
        }
        if presentation.supportedCredentialActions.contains(.removeStoredSecret) {
            Button("Remove Key", role: .destructive) {
                let draft = viewState.secretDraftSnapshot(for: row.id)
                Task {
                    if await viewModel.performBackendAction(.removeStoredSecret, backendID: row.id) {
                        viewState.clearSecretDraft(for: row.id, ifRevision: draft.revision)
                    }
                }
            }
            .disabled(viewModel.isPerformingBackendOperation)
            .accessibilityLabel("\(displayTitle), remove saved key")
        }
        if state?.operationToken != nil {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("\(displayTitle) credential operation in progress")
        }
    }

    private func noticeView(
        _ notice: DecisionServiceSettingsPresentation.Notice
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.emphasis == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.emphasis == .warning ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(notice.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }

    private func disclosureSection(
        _ disclosure: DecisionServiceSettingsPresentation.DisclosureSection,
        links: [DecisionServiceSettingsPresentation.Link]
    ) -> some View {
        let disclosureID = "\(row.id.rawValue):\(disclosure.id)"
        let isExpanded = viewState.isDisclosureExpanded(disclosureID)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    viewState.setDisclosureExpanded(!isExpanded, disclosureID: disclosureID)
                }
            } label: {
                HStack(spacing: 8) {
                    Label(disclosure.title, systemImage: disclosure.category.icon)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayTitle), \(disclosure.title)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")

            RouterSettingsAccordionContent(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(disclosure.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(links) { link in
                        Link(link.title, destination: link.url)
                    }
                }
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var secretDraftBinding: Binding<String> {
        Binding(
            get: { secretDraftState.value },
            set: { viewState.setSecretDraft($0, for: row.id) }
        )
    }

    private var readinessLabel: String {
        guard let readiness = state?.readiness else { return "Checking…" }
        return switch readiness {
        case .ready: "Ready"
        case .validating: "Checking…"
        case .needsConfiguration: "Configuration required"
        case .policyUnavailable, .temporarilyUnavailable: "Unavailable"
        }
    }

    private var readinessIcon: String {
        guard let readiness = state?.readiness else { return "hourglass" }
        return switch readiness {
        case .ready: "checkmark.circle.fill"
        case .validating: "hourglass"
        case .needsConfiguration: "key.fill"
        case .policyUnavailable: "info.circle"
        case .temporarilyUnavailable: "exclamationmark.triangle.fill"
        }
    }

    private var readinessColor: Color {
        guard let readiness = state?.readiness else { return .secondary }
        return switch readiness {
        case .ready: Color.green
        case .validating: Color.secondary
        case .needsConfiguration, .policyUnavailable: Color.orange
        case .temporarilyUnavailable: Color.red
        }
    }

    @ViewBuilder
    private var operationFeedbackIcon: some View {
        switch state?.feedback ?? .idle {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var operationFeedbackColor: Color {
        switch state?.feedback ?? .idle {
        case .idle, .running: .secondary
        case .succeeded: .green
        case .failed: .red
        }
    }

    private var capabilityBadges: [BadgeItem] {
        row.presentation?.capabilities.map {
            BadgeItem(id: "capability:\($0.id)", title: $0.title, isUsage: false)
        } ?? []
    }

    private var usageBadges: [BadgeItem] {
        usageLabels.map {
            BadgeItem(id: "usage:\($0)", title: $0, isUsage: true)
        }
    }

    private var accessibilityValue: String {
        let badges = (capabilityBadges + usageBadges).map(\.title).joined(separator: ", ")
        return badges.isEmpty ? readinessLabel : "\(readinessLabel). \(badges)"
    }

    private func badge(_ title: String, emphasis: Bool) -> some View {
        HStack(spacing: 4) {
            if emphasis {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            }
            Text(title)
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
        .foregroundStyle(emphasis ? Color.green : Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            emphasis ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1),
            in: Capsule()
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct BadgeItem: Identifiable {
        let id: String
        let title: String
        let isUsage: Bool
    }
}

private extension DecisionServiceSettingsPresentation.ProductStatus {
    var title: String {
        switch self {
        case .beta: "Beta"
        case .preview: "Preview"
        case .deprecated: "Deprecated"
        }
    }
}

private extension DecisionServiceSettingsPresentation.DisclosureCategory {
    var icon: String {
        switch self {
        case .privacy: "hand.raised"
        case .pricing: "dollarsign.circle"
        case .technical: "gearshape"
        }
    }
}
