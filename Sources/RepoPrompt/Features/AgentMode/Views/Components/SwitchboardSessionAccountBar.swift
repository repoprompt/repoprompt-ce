import SwiftUI

/// Presentation only. These labels never grant pairing or dispatch authority.
struct SwitchboardSessionPairingCopy {
    let status: String
    let action: String

    @MainActor init(session: AgentTabSession) {
        let hasRetainedManagedHistory = session.requiresSwitchboardPairing
            && (
                session.codexConversationID != nil || session.codexRolloutPath != nil
                    || !session.items.isEmpty || !session.transcript.turns.isEmpty
            )
        if hasRetainedManagedHistory {
            status = "Retained conversation requires Switchboard re-pairing."
        } else if session.requiresSwitchboardPairing {
            status = "New Codex session requires Switchboard pairing."
        } else {
            status = "Switchboard account switching is off for this session."
        }
        action = hasRetainedManagedHistory ? "Re-pair Switchboard…" : "Pair Switchboard…"
    }
}

struct SwitchboardSessionAccountBar: View {
    let viewModel: AgentModeViewModel
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    let tabID: UUID?
    @State private var creatingSession = false
    @State private var creationFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("New Switchboard Codex session…") {
                    creatingSession = true
                    creationFailed = false
                    Task { @MainActor in
                        defer { creatingSession = false }
                        creationFailed = await viewModel.createAndActivateSwitchboardSessionTab() == nil
                    }
                }
                .disabled(creatingSession)
                .accessibilityIdentifier("new-switchboard-codex-session")
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                if creationFailed { Text("A new session could not be created. Try again after the workspace is ready.").font(.caption) }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            if statusPillsUI.snapshot.selectedAgent == .codexExec,
               let tabID, let session = viewModel.sessions[tabID]
            {
                SwitchboardSessionAccountControls(viewModel: viewModel, session: session)
            }
        }
    }
}

private struct SwitchboardSessionAccountControls: View {
    let viewModel: AgentModeViewModel
    @ObservedObject var session: AgentTabSession
    @State private var showingPairing = false
    @State private var envelope = ""
    @State private var consent = false
    @State private var pairing = false
    @State private var pairingSucceeded = false
    @State private var pairingTask: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        HStack(spacing: 10) {
            if let control = session.switchboardAccountControl {
                SwitchboardAccountStatus(control: control)
            } else {
                Text(SwitchboardSessionPairingCopy(session: session).status)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(SwitchboardSessionPairingCopy(session: session).action) {
                envelope = ""
                consent = false
                errorText = nil
                pairingSucceeded = false
                showingPairing = true
            }
            .disabled(session.parentSessionID != nil || session.runState.isActive || pairing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .sheet(isPresented: $showingPairing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pair this Codex session with Switchboard").font(.headline)
                Text("Paste the private pairing envelope issued for this RepoPrompt app. It stays in memory and authorizes only this root session. Do not paste account tokens or place pairing material in a chat.")
                Text("This uses separate account authority: the session can work even when the ordinary Codex login in Settings is disconnected.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("This pilot disables autonomous Codex goals. Switching waits for idle tools, queued work and child agents, and refuses additional loaded native threads. Ordinary backends cannot be converted. Re-pairing managed history retains its exact conversation.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Some native image-generation or subagent history cannot yet be verified for switching; it is retained unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                SwitchboardPairingInput(text: $envelope)
                Toggle("Allow Switchboard account changes for this session when idle", isOn: $consent)
                if let errorText { Text(errorText).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") {
                        pairingTask?.cancel()
                        if pairing { session.switchboardAccountControl?.revoke() }
                        envelope = ""
                        showingPairing = false
                    }
                    Spacer()
                    Button(pairing ? "Verifying…" : "Pair this session") {
                        let data = Data(envelope.utf8)
                        envelope = ""
                        pairing = true
                        pairingTask = Task {
                            defer { pairing = false }
                            do {
                                try await viewModel.pairSwitchboardSession(tabID: session.tabID, envelopeData: data)
                                pairingSucceeded = true
                                showingPairing = false
                            } catch let failure as AgentModeViewModel.SwitchboardPairingFailure {
                                errorText = failure.errorDescription
                            } catch {
                                errorText = "Pairing could not be verified. Request a fresh envelope from Switchboard and try again."
                            }
                        }
                    }
                    .disabled(!consent || envelope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairing)
                }
            }
            .padding(20).frame(width: 560)
            .onDisappear { envelope = ""
                consent = false
                if pairing, !pairingSucceeded {
                    pairingTask?.cancel()
                    session.switchboardAccountControl?.revoke()
                }
            }
        }
    }
}

struct SwitchboardPairingInput: View {
    @Binding var text: String

    var body: some View {
        SecureField("Paste private session pairing", text: $text)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
    }
}

private struct SwitchboardAccountStatus: View {
    @ObservedObject var control: CodexSwitchboardSessionControl

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let account = control.accountSummary, !account.isEmpty { Text(account).font(.caption).lineLimit(1).hoverTooltip(account) }
                Text(control.statusText).font(.caption).foregroundStyle(.secondary)
                if let automatic = control.automatic { SwitchboardAutomaticAccountStatus(control: automatic) }
            }
            Button("Revoke") { control.revoke() }.disabled(control.state == .revoked)
        }
    }
}

private struct SwitchboardAutomaticAccountStatus: View {
    @ObservedObject var control: CodexSwitchboardAutomaticControl
    @State private var reviewedOffer: SwitchboardAutomaticOffer?
    @State private var approves = false
    @State private var submitting = false
    @State private var failure = false

    var body: some View {
        HStack {
            Text(control.statusText).font(.caption).foregroundStyle(.secondary)
            if let offer = control.offer, control.enrollment == nil {
                Button("Review automatic rule…") { reviewedOffer = offer
                    approves = false
                    failure = false
                }
            }
            if control.enrollment != nil { Button("Revoke automatic approval") { control.stop() } }
        }
        .sheet(isPresented: Binding(get: { reviewedOffer != nil }, set: { if !$0 { reviewedOffer = nil } })) {
            if let offer = reviewedOffer {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Approve automatic rotation for this root").font(.headline)
                    Text(offer.name)
                    Text("Approved accounts: " + offer.accounts.joined(separator: ", "))
                    Text("Rotate at \(offer.triggerUsedPercent)% used; destination must have at least \(offer.destinationRemainingPercent)% remaining. Cooldown: \(offer.cooldownMinutes) minutes. Quota freshness: \(offer.freshnessSeconds) seconds.")
                    Text("Switchboard coordinates one destination across explicitly enrolled capable sessions. This root waits for idle; other sessions may still be waiting or unknown. Pause stops new automatic changes and remains Pausing until in-flight installs settle. Manual changes and same-account refresh remain separate.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Approve this exact rule for this paired root only", isOn: $approves)
                    if failure { Text("Approval changed or is unavailable. Review a fresh offer.").font(.caption) }
                    HStack {
                        Button("Cancel") { reviewedOffer = nil }.disabled(submitting)
                        Spacer()
                        Button("Approve rule") {
                            submitting = true
                            Task {
                                defer { submitting = false }
                                do { try await control.accept(offerID: offer.id)
                                    reviewedOffer = nil
                                } catch { failure = true }
                            }
                        }.disabled(!approves || submitting)
                    }
                }.padding(20).frame(width: 560).interactiveDismissDisabled(submitting)
            }
        }
    }
}
