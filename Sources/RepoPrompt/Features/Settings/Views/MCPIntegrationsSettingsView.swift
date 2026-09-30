import SwiftUI

struct ClaudeCodeFigmaFocusRecheckPolicy {
    private(set) var isAwaitingAuthorizationReturn = false

    mutating func beginAuthorization() {
        isAwaitingAuthorizationReturn = true
    }

    mutating func finishAuthorization() {
        isAwaitingAuthorizationReturn = false
    }

    mutating func consumeAppActivation() -> Bool {
        guard isAwaitingAuthorizationReturn else { return false }
        isAwaitingAuthorizationReturn = false
        return true
    }
}

struct FigmaMCPProviderConfirmationState {
    let showsClaudeCodeLaunchConfirmation: Bool
    let providerDisconnectConfirmation: FigmaMCPProviderDisconnectConfirmation?

    func invalidatingUnavailableActions(
        canPerformProviderAction: (ExternalMCPRuntimeProvider, FigmaMCPProviderRowAction) -> Bool
    ) -> Self {
        .init(
            showsClaudeCodeLaunchConfirmation: showsClaudeCodeLaunchConfirmation
                && canPerformProviderAction(.claudeCode, .connect),
            providerDisconnectConfirmation: providerDisconnectConfirmation.flatMap { confirmation in
                canPerformProviderAction(confirmation.provider, .disconnect) ? confirmation : nil
            }
        )
    }
}

/// Settings for Figma MCP provider routes. Codex retains its existing app-wide lifecycle; non-Codex
/// login attempts are owned by the shared app-lifetime provider connection coordinator.
///
/// The Figma card badge is aggregate presentation. Each provider row capsule is authoritative for
/// that provider alone and reflects only current, provider-owned status supplied by the view model;
/// a Codex-connected card never implies another provider is connected. Non-Codex rows expose no
/// refresh affordance. Claude Code performs one return-to-app recheck only for an authorization
/// started from this view, and Test Connection is offered only after current provider-owned proof.
struct MCPIntegrationsSettingsView: View {
    @StateObject private var model: MCPIntegrationsSettingsViewModel
    @ObservedObject private var apiSettingsViewModel: APISettingsViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var modalPresentation = FigmaMCPSettingsModalPresentation()
    @State private var expandedProviderIDs: Set<ExternalMCPRuntimeProvider> = []
    @State private var showsClaudeCodeLaunchConfirmation = false
    @State private var providerDisconnectConfirmation: FigmaMCPProviderDisconnectConfirmation?
    @State private var claudeCodeFocusRecheckPolicy = ClaudeCodeFigmaFocusRecheckPolicy()

    init(
        settingsManager: WindowSettingsManager,
        coordinator: FigmaMCPIntegrationCoordinator,
        externalMCPComposition: AppExternalMCPComposition,
        apiSettingsViewModel: APISettingsViewModel,
        providerStatusService: (any FigmaMCPProviderStatusChecking)? = nil,
        onNavigate: @escaping (SettingsTab) -> Void
    ) {
        self.apiSettingsViewModel = apiSettingsViewModel
        let cursorFigmaLoginComponents = CursorFigmaMCPLoginFactory.makeComponents(
            sessionController: externalMCPComposition.terminalSessionController
        )
        let cursorFigmaLoginDriver = cursorFigmaLoginComponents.makeLoginDriver()
        _model = StateObject(wrappedValue: MCPIntegrationsSettingsViewModel(
            externalMCPComposition: externalMCPComposition,
            cliAvailability: apiSettingsViewModel.agentModeAvailabilityContext,
            settingsStore: settingsManager.globalSettingsStore,
            windowID: settingsManager.windowID,
            coordinator: coordinator,
            providerConnectionCoordinator: externalMCPComposition.figmaProviderConnectionCoordinator,
            providerStatusService: providerStatusService ?? externalMCPComposition.figmaProviderStatusService,
            cursorFigmaToolSurfaceObserver: externalMCPComposition.cursorToolSurfaceObserver,
            cursorFigmaLoginComponents: cursorFigmaLoginComponents,
            cursorFigmaLoginDriver: cursorFigmaLoginDriver,
            cursorFigmaDisableExecutor: CursorFigmaMCPDisableExecutor(),
            openCLIProviders: { onNavigate(.cliProviders) }
        ))
    }

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var claudeCodeProviderStatus: FigmaMCPProviderRowStatus? {
        model.providerRows.first(where: { $0.id == .claudeCode })?.status
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                figmaConnectionCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear {
            model.updateCLIAvailability(apiSettingsViewModel.agentModeAvailabilityContext)
            model.activateAndLoad()
        }
        .onReceive(apiSettingsViewModel.$agentAvailability.removeDuplicates().dropFirst()) { availability in
            model.updateCLIAvailability(availability)
            collapseUnavailableProviderRows()
            invalidateStaleProviderConfirmations()
        }
        .onChange(of: model.providerRows) { _, _ in
            collapseUnavailableProviderRows()
            invalidateStaleProviderConfirmations()
        }
        .onDisappear {
            modalPresentation.reset()
            showsClaudeCodeLaunchConfirmation = false
            providerDisconnectConfirmation = nil
            claudeCodeFocusRecheckPolicy = ClaudeCodeFigmaFocusRecheckPolicy()
            model.deactivate()
        }
        .onReceive(model.$pendingPresentationEvent.compactMap(\.self)) { event in
            guard model.isCurrentPresentationEvent(event),
                  modalPresentation.receive(event)
            else { return }
            // Copy the event into local modal/queue state before consuming the published event.
            model.consumePresentationEvent(id: event.id)
        }
        .onChange(of: modalPresentation.active) { _, active in
            guard active == nil else { return }
            // Let the current native alert finish dismissing before presenting a queued event.
            DispatchQueue.main.async {
                guard modalPresentation.active == nil else { return }
                modalPresentation.advanceAfterDismissal()
            }
        }
        .alert(item: Binding(
            get: { modalPresentation.active },
            set: { modalPresentation.setActiveModal($0) }
        )) { modal in
            modalAlert(for: modal)
        }
        .confirmationDialog(
            "Authorize Figma in Claude Code",
            isPresented: $showsClaudeCodeLaunchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Authorization") {
                guard model.canPerformProviderAction(provider: .claudeCode, action: .connect) else { return }
                claudeCodeFocusRecheckPolicy.beginAuthorization()
                model.startClaudeCodeFigmaAuthorization()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("RepoPrompt CE will ask Claude Code to start its Figma authorization flow.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard claudeCodeFocusRecheckPolicy.consumeAppActivation() else { return }
            _ = model.recheckProviderStatus(provider: .claudeCode)
        }
        .onChange(of: claudeCodeProviderStatus) { _, status in
            guard status != .authorizing, status != .checking else { return }
            claudeCodeFocusRecheckPolicy.finishAuthorization()
        }
        .confirmationDialog(
            providerDisconnectConfirmation?.title ?? "Figma MCP",
            isPresented: Binding(
                get: { providerDisconnectConfirmation != nil },
                set: { isPresented in
                    if !isPresented { providerDisconnectConfirmation = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation = providerDisconnectConfirmation {
                Button(confirmation.confirmTitle, role: .destructive) {
                    confirmProviderDisconnect(confirmation)
                }
                Button(confirmation.cancelTitle, role: .cancel) {
                    providerDisconnectConfirmation = nil
                }
            }
        } message: {
            if let confirmation = providerDisconnectConfirmation {
                Text(confirmation.message)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MCP Integrations")
                .font(fontPreset.headlineFont)
            Text("Connect external tools and services for RepoPrompt CE to use in Agent Mode.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                "Figma MCP is available on all Figma plans. Dev and Full seats on paid plans have higher MCP usage limits; other seat types may be more limited.",
                systemImage: "info.circle"
            )
            .font(fontPreset.captionFont)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var figmaConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FigmaBrandIcon(visibleHeight: fontPreset.scaledMetric(FigmaBrandIconGeometry.settingsVisibleHeight))
                    .frame(
                        width: fontPreset.scaledMetric(FigmaBrandIconGeometry.settingsIconSlotWidth),
                        height: fontPreset.scaledMetric(FigmaBrandIconGeometry.settingsVisibleHeight),
                        alignment: .center
                    )
                    .offset(y: fontPreset.scaledMetric(FigmaBrandIconGeometry.settingsVerticalAlignmentOffset))
                    .accessibilityHidden(true)
                Text("Figma")
                    .font(.headline)
                Spacer(minLength: 8)
                SettingsConnectionStatusCapsule(
                    status: model.integrationCardStatus,
                    labelOverride: model.integrationCardStatusLabelOverride
                )
            }
            .frame(minHeight: 44)

            Text("Use Figma designs, components, variables, and design context in RepoPrompt CE.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            figmaUsageInfo
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))

            figmaProviderRows
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private var figmaProviderRows: some View {
        let groups = model.providerRowGroups
        return VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.controlSpacing) {
            ForEach(groups.connected) { row in
                providerRow(row)
            }

            providerGroupHeading("NOT CONNECTED")
            ForEach(groups.notConnected) { row in
                providerRow(row)
            }
            HStack(spacing: 8) {
                Button {
                    model.openCLIProviderSettings()
                } label: {
                    Label("Open CLI Providers", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            if !groups.unsupported.isEmpty {
                providerGroupHeading("CURRENTLY UNSUPPORTED")
                ForEach(groups.unsupported) { row in
                    providerRow(row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerGroupHeading(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    private var figmaUsageInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to use Figma MCP")
                .font(fontPreset.subHeadlineBoldFont)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Connect Figma for your CLI provider below.")
                Text("2. Complete the Figma authorization flow.")
                Text("3. Open the Figma Design file you want to work with.")
                Text("4. Copy the link to the relevant file, frame, or layer and give it to the Agent in RepoPrompt CE.")
                Text("5. Ask the Agent to inspect, explain, or implement the referenced design.")
            }
            .font(fontPreset.captionFont)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Requirements")
                .font(fontPreset.subHeadlineBoldFont)
            VStack(alignment: .leading, spacing: 4) {
                Text("• Figma MCP is available on all Figma plans.")
                Text("• Dev and Full seats on paid plans have higher MCP usage limits; other seat types may be more limited.")
                Text("• If the Agent cannot access the Figma tools after connecting, reconnect Figma or restart your CLI provider.")
            }
            .font(fontPreset.captionFont)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerRow(_ row: FigmaMCPProviderRowPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleProviderExpansion(row.id)
            } label: {
                HStack(spacing: 8) {
                    Text(row.displayName)
                        .font(fontPreset.subHeadlineBoldFont)
                    Spacer(minLength: 8)
                    SettingsConnectionStatusCapsule(
                        status: row.status.capsuleStatus,
                        labelOverride: row.status.label
                    )
                    if row.canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                            .rotationEffect(.degrees(expandedProviderIDs.contains(row.id) ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.canExpand)
            .accessibilityLabel("\(row.displayName), \(row.status.label)")
            .accessibilityValue(row.canExpand ? (expandedProviderIDs.contains(row.id) ? "Expanded" : "Collapsed") : "Unavailable")
            .accessibilityHint(
                row.canExpand
                    ? (
                        expandedProviderIDs.contains(row.id)
                            ? "Collapses connection details and actions."
                            : "Expands connection details and actions."
                    )
                    : nonExpandableAccessibilityMessage(for: row)
            )

            if !row.canExpand {
                nonExpandableMessage(for: row)
                    .font(fontPreset.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(nonExpandableAccessibilityMessage(for: row))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if !row.isCLIAvailable, row.canExpand == false,
               let cancellation = row.actions.first(where: { $0.id == .cancelLogin && !$0.isDisabled })
            {
                SettingsProviderConnectionActionButton(
                    title: cancellation.title,
                    systemImage: cancellation.systemImage,
                    isLoading: cancellation.isLoading,
                    isDisabled: cancellation.isDisabled,
                    role: .primary,
                    accessibilityLabel: cancellation.accessibilityLabel,
                    accessibilityHint: cancellation.accessibilityHint,
                    action: { model.performProviderRowAction(provider: row.id, action: .cancelLogin) }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            if expandedProviderIDs.contains(row.id), row.canExpand {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    providerRowDetails(row)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func providerRowDetails(_ row: FigmaMCPProviderRowPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = row.connectionSummary {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(summary.rows.enumerated()), id: \.offset) { _, summaryRow in
                        figmaSummaryRow(summaryRow)
                    }
                }
            }

            Label(
                row.message,
                systemImage: row.isError ? "exclamationmark.circle" : "info.circle"
            )
            .font(fontPreset.captionFont)
            .foregroundColor(row.isError ? .red : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.message)

            if let verifiedAt = row.verifiedAt {
                let timestampLabels = row.timestampPresentation.labels(for: verifiedAt)
                Label(timestampLabels.display, systemImage: "clock")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
                    .opacity(row.isTestingConnection ? 0 : 1)
                    .accessibilityHidden(row.isTestingConnection)
                    .accessibilityLabel(timestampLabels.accessibility)
                    .animation(.easeInOut(duration: 0.2), value: row.isTestingConnection)
            }

            if !row.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(row.actions) { action in
                        SettingsProviderConnectionActionButton(
                            title: action.title,
                            systemImage: action.systemImage,
                            isLoading: action.isLoading,
                            isDisabled: action.isDisabled,
                            role: action.id == .disconnect ? .secondary : .primary,
                            accessibilityLabel: action.accessibilityLabel,
                            accessibilityHint: action.accessibilityHint,
                            action: {
                                if row.id == .claudeCode, action.id == .connect {
                                    showsClaudeCodeLaunchConfirmation = true
                                } else if action.id == .disconnect {
                                    requestProviderDisconnectConfirmation(provider: row.id)
                                } else {
                                    model.performProviderRowAction(provider: row.id, action: action.id)
                                }
                            }
                        )
                    }
                    Spacer(minLength: 8)
                }
            }
        }
    }

    private func nonExpandableMessage(for row: FigmaMCPProviderRowPresentation) -> Text {
        let message = switch row.status {
        case .unsupported, .currentlyUnsupported, .comingSoon:
            Text(row.message)
        default:
            Text(row.cliPrerequisitePrefix)
                + Text(Image(systemName: "terminal"))
                + Text(" CLI Providers")
        }
        return Text(Image(systemName: "info.circle")) + Text(" ") + message
    }

    private func nonExpandableAccessibilityMessage(for row: FigmaMCPProviderRowPresentation) -> String {
        switch row.status {
        case .unsupported, .currentlyUnsupported, .comingSoon:
            row.message
        default:
            row.cliPrerequisiteAccessibilityMessage
        }
    }

    private func toggleProviderExpansion(_ provider: ExternalMCPRuntimeProvider) {
        guard model.providerRows.first(where: { $0.id == provider })?.canExpand == true else { return }
        if accessibilityReduceMotion {
            toggleExpandedProviderID(provider)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                toggleExpandedProviderID(provider)
            }
        }
    }

    private func collapseUnavailableProviderRows() {
        let expandable = Set(model.providerRows.filter(\.canExpand).map(\.id))
        expandedProviderIDs.formIntersection(expandable)
    }

    private func toggleExpandedProviderID(_ provider: ExternalMCPRuntimeProvider) {
        if expandedProviderIDs.contains(provider) {
            expandedProviderIDs.remove(provider)
        } else {
            expandedProviderIDs.insert(provider)
        }
    }

    private func figmaSummaryRow(_ row: FigmaMCPSettingsConnectionSummary.Row) -> some View {
        let label: String
        let value: String
        switch row {
        case let .connection(rowValue):
            label = "Connection"
            value = rowValue
        case let .authentication(rowValue):
            label = "Authentication"
            value = rowValue
        case let .credentialOwner(rowValue):
            label = "Credentials"
            value = rowValue
        }

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(fontPreset.captionFont)
        .accessibilityElement(children: .combine)
    }

    private func connectionMessageView(message: String) -> some View {
        Label(
            message,
            systemImage: model.connectionMessageIsError ? "exclamationmark.circle" : "info.circle"
        )
        .font(fontPreset.captionFont)
        .foregroundColor(model.connectionMessageIsError ? .red : .secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    private func invalidateStaleProviderConfirmations() {
        let valid = FigmaMCPProviderConfirmationState(
            showsClaudeCodeLaunchConfirmation: showsClaudeCodeLaunchConfirmation,
            providerDisconnectConfirmation: providerDisconnectConfirmation
        ).invalidatingUnavailableActions(canPerformProviderAction: model.canPerformProviderAction)
        showsClaudeCodeLaunchConfirmation = valid.showsClaudeCodeLaunchConfirmation
        providerDisconnectConfirmation = valid.providerDisconnectConfirmation
    }

    private func requestProviderDisconnectConfirmation(provider: ExternalMCPRuntimeProvider) {
        guard providerDisconnectConfirmation == nil,
              let row = model.providerRows.first(where: { $0.id == provider }),
              row.actions.contains(where: { $0.id == .disconnect && !$0.isDisabled })
        else { return }
        providerDisconnectConfirmation = .init(provider: provider)
    }

    private func confirmProviderDisconnect(_ confirmation: FigmaMCPProviderDisconnectConfirmation) {
        guard providerDisconnectConfirmation == confirmation else { return }
        providerDisconnectConfirmation = nil
        model.performProviderRowAction(provider: confirmation.provider, action: .disconnect)
    }

    private func confirmLegacySignOut() {
        _ = modalPresentation.confirmSignOut {
            model.signOut()
        }
    }

    private func modalAlert(for modal: FigmaMCPSettingsModalPresentation.ModalState) -> Alert {
        switch modal {
        case .signOutConfirmation:
            return Alert(
                title: Text(FigmaMCPSignOutConfirmation.title),
                message: Text(FigmaMCPSignOutConfirmation.message),
                primaryButton: .destructive(
                    Text(FigmaMCPSignOutConfirmation.confirmTitle),
                    action: confirmLegacySignOut
                ),
                secondaryButton: .cancel(Text(FigmaMCPSignOutConfirmation.cancelTitle))
            )
        case let .acknowledgement(event):
            let kind: FigmaMCPSettingsAcknowledgementSpec.Kind = switch event.kind {
            case .loginCompleted: .loginCompleted
            case .signOutCompleted: .signOutCompleted
            }
            let spec = FigmaMCPSettingsAcknowledgementSpec(kind: kind)
            return Alert(
                title: Text(spec.title),
                message: Text(spec.message),
                dismissButton: .default(Text(spec.dismissTitle), action: dismissAcknowledgement)
            )
        }
    }

    private func dismissAcknowledgement() {
        modalPresentation.clearActiveModal()
    }
}
