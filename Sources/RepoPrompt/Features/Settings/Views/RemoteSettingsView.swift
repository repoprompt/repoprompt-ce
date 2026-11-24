import AppKit
import CoreImage
import RepoPromptRemoteProtocol
import SwiftUI

struct RemoteSettingsView: View {
    @ObservedObject private var gateway: RemoteGatewayController
    @ObservedObject private var availability: RemoteAvailabilityController

    init(gateway: RemoteGatewayController) {
        _gateway = ObservedObject(wrappedValue: gateway)
        _availability = ObservedObject(wrappedValue: gateway.availabilityController)
    }

    private static let authorityLevels: [RemoteAuthorityLevel] = [
        .observe, .respond, .control, .danger
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                gatewaySection
                pairingSection
                authorizationSection
                availabilitySection
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            gateway.configure(windowStatesManager: WindowStatesManager.shared)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your phone")
                .font(.largeTitle.weight(.semibold))
            Text("Connect RepoPrompt Remote to this Mac. Your Mac remains in control of its projects and agents.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gatewaySection: some View {
        GroupBox("Remote access") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enable Remote", isOn: Binding(
                    get: { gateway.isEnabled },
                    set: { enabled in
                        Task { await gateway.setEnabled(enabled) }
                    }
                ))
                if gateway.isEnabled {
                    LabeledContent("Listener", value: listenerStatus)
                }
                if gateway.isPhoneConnected, gateway.irohDiagnostics.path != .unknown {
                    LabeledContent("Iroh path") {
                        Text(gateway.irohDiagnostics.path.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                }

                LabeledContent("Status") {
                    Text(gatewayStatus)
                        .foregroundStyle(gateway.isPhoneConnected ? Color.green : Color.secondary)
                }
                if case let .paired(expiresAt) = gateway.pairingStatus {
                    LabeledContent("Paired phone", value: gateway.pairedDeviceName ?? "Paired device")
                    LabeledContent("Credential expires") {
                        Text(expiresAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if gateway.isEnabled, !gateway.isRunning {
                    Button("Retry starting Remote") {
                        Task { await gateway.setEnabled(true) }
                    }
                }

                if let error = gateway.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        }
    }

    private var listenerStatus: String {
        switch gateway.irohDiagnostics.state {
        case "starting": "Starting…"
        case "degraded": "Degraded · Retrying"
        default: gateway.isRunning ? "Ready" : "Unavailable"
        }
    }

    private var gatewayStatus: String {
        switch gateway.pairingStatus {
        case .storageUnavailable: "Pairing storage unavailable"
        case .attemptExpired: "Pairing attempt expired"
        case .codeExpired: "Pairing code expired"
        case .credentialExpired: "Paired credential expired"
        case .pending: "Pairing pending"
        case .paired: gateway.isPhoneConnected ? "Paired · Connected" : "Paired · Offline"
        case .idle, .codeReady:
            if gateway.isRunning {
                "Ready for pairing"
            } else if gateway.isEnabled {
                "Waiting for listener"
            } else {
                "Disabled"
            }
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        if gateway.isPaired {
            GroupBox("Paired phone") {
                VStack(alignment: .leading, spacing: 14) {
                    if gateway.isRunning, !gateway.isPhoneConnected {
                        Text("Open RepoPrompt Remote on your phone to reconnect and finish syncing.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Unpair phone", role: .destructive) {
                        gateway.revokePairedDevice()
                    }
                }
                .padding(8)
            }
        } else {
            GroupBox("Pair your phone") {
                VStack(alignment: .leading, spacing: 14) {
                    if case .storageUnavailable = gateway.pairingStatus {
                        Text("Unlock this Mac’s Keychain and retry loading pairing.")
                            .foregroundStyle(.secondary)
                        Button("Retry Keychain") { gateway.retryPairingStorage() }
                    } else if case let .pending(deviceName, expiresAt) = gateway.pairingStatus {
                        Text("Waiting for \(deviceName) to save and confirm pairing. Reopen RepoPrompt Remote on that phone to resume.")
                            .foregroundStyle(.secondary)
                        LabeledContent("Attempt expires") { Text(expiresAt, style: .timer).monospacedDigit() }
                        Button("Cancel attempt and generate new code") {
                            gateway.refreshPairingAdvertisement()
                        }
                        .disabled(!gateway.isRunning)
                    } else if let pairingCode = gateway.pairingCode {
                        HStack(alignment: .top, spacing: 20) {
                            PairingQRCodeView(payload: pairingCode)
                                .frame(width: 220, height: 220)
                                .padding(10)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Scan this code with RepoPrompt Remote")
                                    .font(.headline)
                                Text("Use the current RepoPrompt Remote app to scan this single-use code.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if case let .codeReady(expiresAt) = gateway.pairingStatus {
                                    LabeledContent("Code expires") { Text(expiresAt, style: .timer).monospacedDigit() }
                                }
                                HStack {
                                    Button("Generate new code") {
                                        gateway.refreshPairingAdvertisement()
                                    }
                                    Button("Copy pairing link") {
                                        copyPairingLink()
                                    }
                                    .disabled(gateway.pairingCode == nil)
                                }
                            }
                        }
                    } else {
                        Text(gateway.isEnabled ? "Start pairing to generate a code." : "Enable Remote to generate a code.")
                            .foregroundStyle(.secondary)
                        Button("Generate pairing code") {
                            gateway.refreshPairingAdvertisement()
                        }
                        .disabled(!gateway.isRunning)
                    }
                }
                .padding(8)
            }
        }
    }

    private var authorizationSection: some View {
        GroupBox("Default authorization") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Default authority", selection: Binding(
                    get: { gateway.defaultAuthority },
                    set: { gateway.defaultAuthority = $0 }
                )) {
                    ForEach(Self.authorityLevels, id: \.rawValue) { level in
                        Text(authorityTitle(level)).tag(level)
                    }
                }
                .pickerStyle(.menu)

                Text("Observe is read-only. Respond adds answers and one-time approvals, and Control adds run commands. Danger also permits changes to Codex tool settings for the entire Mac. Worktree merges, permission grants, and persistent approvals stay on the Mac. Push notifications are currently unavailable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var availabilitySection: some View {
        GroupBox("Desktop availability") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch RepoPrompt at login", isOn: Binding(
                    get: { availability.launchAtLoginEnabled },
                    set: { availability.setLaunchAtLogin($0) }
                ))

                LabeledContent("Active-run sleep policy") {
                    Text(availability.preventsIdleSleepForActiveRun ? "Keeping Mac awake" : "Not asserted")
                        .foregroundStyle(availability.preventsIdleSleepForActiveRun ? .green : .secondary)
                }

                Text("The Mac stays awake only while an agent is opening, working, blocked, or waiting for input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = availability.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        }
    }

    private func copyPairingLink() {
        guard let pairingCode = gateway.pairingCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
    }

    private func authorityTitle(_ level: RemoteAuthorityLevel) -> String {
        switch level {
        case .observe: "Observe (read-only)"
        case .respond: "Respond"
        case .control: "Control"
        case .danger: "Danger"
        }
    }
}

private struct PairingQRCodeView: NSViewRepresentable {
    let payload: String

    private static let imageCache = NSCache<NSString, NSImage>()
    private static let imageContext = CIContext()

    func makeCoordinator() -> Coordinator {
        Coordinator(payload: payload)
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = Self.image(for: payload)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        guard context.coordinator.payload != payload else { return }
        context.coordinator.payload = payload
        imageView.image = Self.image(for: payload)
    }

    final class Coordinator {
        var payload: String

        init(payload: String) {
            self.payload = payload
        }
    }

    private static func image(for payload: String) -> NSImage? {
        let cacheKey = payload as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter?.setValue("Q", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = imageContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }
}
