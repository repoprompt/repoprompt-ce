import SwiftUI

struct SwitchboardSessionAccountBar: View {
    let viewModel: AgentModeViewModel
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    let tabID: UUID?

    var body: some View {
        if statusPillsUI.snapshot.selectedAgent == .codexExec,
           let tabID, let session = viewModel.sessions[tabID]
        {
            SwitchboardSessionAccountControls(viewModel: viewModel, session: session)
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
                Text(session.requiresSwitchboardPairing ? "Retained conversation requires Switchboard re-pairing." : "Switchboard account switching is off for this session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(session.requiresSwitchboardPairing ? "Re-pair Switchboard…" : "Pair Switchboard…") {
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
            }
            Button("Revoke") { control.revoke() }.disabled(control.state == .revoked)
        }
    }
}
