import AppKit
import RepoPromptDomainRuntime
import SwiftUI

/// Result of a Session-ID sheet submission. `.cancelled` means the confirmation dialog was
/// dismissed or declined: the sheet stays open without treating it as a failure.
enum AgentOversightSessionIDSubmitOutcome {
    case succeeded
    case cancelled
    case failed(String)
}

/// Small sheet reached from a sidebar row's `Session ID…` menu item, in either direction:
/// choosing a session for this row to oversee, or choosing an existing overseer for this row.
///
/// All wording comes from `AgentOversightUICopy`; the directional caller supplies the title,
/// field label, resolver, and submit action. Submitting goes through the shared confirmation
/// gate in the caller before any link is created — this view performs no authority work itself.
struct AgentOversightSessionIDSheet: View {
    /// One resolved pasted ID, carrying the exact endpoint so a rebind between resolution and
    /// acceptance cannot silently retarget the request.
    struct ResolvedPeer: Equatable {
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        let sessionID: UUID
        let displayName: String
        let providerDisplayName: String?
        let locationLabel: String?

        init(candidate: AgentSessionLinkEndpointCandidate) {
            endpoint = candidate.domainEndpoint
            sessionID = candidate.sessionID
            displayName = candidate.resolvedDisplayName
            providerDisplayName = candidate.providerDisplayName
            locationLabel = candidate.locationLabel
        }

        var shortID: String {
            AgentMonitorSessionIDFormatter.short(sessionID)
        }

        var detailLine: String {
            AgentMonitorDetailLineFormatter.line(
                location: locationLabel,
                provider: providerDisplayName,
                status: nil
            )
        }

        /// VoiceOver label for the combined preview element; reads the full canonical UUID
        /// because the visible short form is ambiguous by construction.
        var accessibilityLabel: String {
            let location = AgentMonitorAccessibilityLocationPhrase.clause(locationLabel)
            return "Resolved \(displayName)\(location), session \(sessionID.uuidString)"
        }
    }

    let title: String
    let fieldAccessibilityLabel: String
    let submitLabel: String
    /// Pure, read-only resolution of the pasted text; never focuses or activates anything.
    /// `.alreadyLinked` is a successful silent no-op, not an error.
    let resolve: @MainActor (String) async -> Result<
        AgentOversightSessionIDResolution,
        AgentOversightResolutionMessage
    >
    /// Confirms and creates the link.
    let submit: @MainActor (ResolvedPeer) async -> AgentOversightSessionIDSubmitOutcome
    let onDismiss: () -> Void

    @State private var identifierText = ""
    @State private var resolvedPeer: ResolvedPeer?
    /// Persistent validation text. Errors are never conveyed by transient colour alone.
    @State private var validationMessage: String?
    @State private var isWorking = false
    /// Fences a slower earlier resolution from overwriting a newer edit's result.
    @State private var resolutionGeneration: UInt64 = 0
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            TextField(AgentOversightUICopy.sessionIDFieldPlaceholder, text: $identifierText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .accessibilityLabel(fieldAccessibilityLabel)
                .focused($isFieldFocused)
                .onChange(of: identifierText) { _, _ in refreshResolution() }
                .onSubmit { submitTapped() }

            HStack(spacing: 6) {
                Button(AgentOversightUICopy.pasteFromClipboard) { pasteFromClipboard() }
                    .font(.system(size: 11))
                    .accessibilityHint(AgentOversightUICopy.pasteFromClipboardHint)

                Spacer(minLength: 0)

                Button(AgentOversightUICopy.cancelButton) { onDismiss() }
                    .font(.system(size: 11))
                    .keyboardShortcut(.cancelAction)

                Button(submitLabel) { submitTapped() }
                    .font(.system(size: 11, weight: .medium))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || identifierText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let resolvedPeer {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(resolvedPeer.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(resolvedPeer.shortID)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    Text(resolvedPeer.detailLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(resolvedPeer.accessibilityLabel)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { isFieldFocused = true }
    }

    private func pasteFromClipboard() {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        identifierText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshResolution() {
        let trimmed = identifierText.trimmingCharacters(in: .whitespacesAndNewlines)
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        guard !trimmed.isEmpty else {
            resolvedPeer = nil
            validationMessage = nil
            return
        }
        Task { @MainActor in
            let result = await resolve(trimmed)
            guard resolutionGeneration == generation else { return }
            switch result {
            case let .success(.candidate(candidate)):
                resolvedPeer = ResolvedPeer(candidate: candidate)
                validationMessage = nil
            case .success(.alreadyLinked):
                // Already linked in this direction: no preview and no message — submitting (or
                // nothing) just completes the pair silently.
                resolvedPeer = nil
                validationMessage = nil
            case let .failure(error):
                resolvedPeer = nil
                validationMessage = error.message
            }
        }
    }

    private func submitTapped() {
        let trimmed = identifierText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, !trimmed.isEmpty else { return }
        isWorking = true
        // Invalidate any in-flight text-resolution so it cannot clobber the submit outcome.
        resolutionGeneration &+= 1
        Task { @MainActor in
            // Re-resolve at submit time so the accepted dialog and the Add both see the same
            // exact endpoint; the peer captured earlier may have been superseded while open.
            let resolved = await resolve(trimmed)
            switch resolved {
            case let .success(.candidate(candidate)):
                switch await submit(ResolvedPeer(candidate: candidate)) {
                case .succeeded:
                    isWorking = false
                    onDismiss()
                    return
                case .cancelled:
                    break
                case let .failed(message):
                    validationMessage = message
                    resolvedPeer = nil
                }
            case .success(.alreadyLinked):
                // Approved behavior: already linked in this direction is done — close silently.
                isWorking = false
                onDismiss()
                return
            case let .failure(error):
                resolvedPeer = nil
                validationMessage = error.message
            }
            isWorking = false
        }
    }
}
