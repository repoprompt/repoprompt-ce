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

    @State private var showsLegacyPairingCode = true

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
                Toggle("Enable pairing", isOn: Binding(
                    get: { gateway.isEnabled },
                    set: { enabled in
                        Task { await gateway.setEnabled(enabled) }
                    }
                ))
                Toggle("Enable Iroh (requires a newer Remote build)", isOn: Binding(
                    get: { gateway.isIrohEnabled },
                    set: { enabled in
                        Task { await gateway.setIrohEnabled(enabled) }
                    }
                ))
                .disabled(!gateway.isEnabled)

                if gateway.isIrohEnabled {
                    LabeledContent("Iroh") {
                        Text(gateway.irohDiagnostics.state.capitalized)
                            .foregroundStyle(gateway.irohDiagnostics.state == "running" ? .green : .secondary)
                    }
                    if gateway.irohDiagnostics.path != .unknown {
                        LabeledContent("Iroh path") {
                            Text(gateway.irohDiagnostics.path.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        }
                    }
                    if let error = gateway.irohDiagnostics.lastError {
                        Text("Iroh: \(error)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                if gateway.isPaired {
                    LabeledContent("Status") {
                        if gateway.isRunning {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label(gateway.lastError ?? "Paired, but disabled", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    LabeledContent("Paired phone") {
                        Text(gateway.pairedDeviceName ?? "Paired device")
                            .foregroundStyle(.primary)
                    }
                } else if gateway.isRunning {
                    LabeledContent("Status") {
                        Label("Ready for pairing", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    LabeledContent("Status") {
                        Text(gateway.lastError ?? "Disabled")
                            .foregroundStyle(gateway.lastError == nil ? Color.secondary : Color.red)
                    }
                    Text("Allow RepoPrompt Remote to connect to this Mac. Pairing is required before anything can be viewed or controlled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var pairingSection: some View {
        if gateway.isPaired {
            GroupBox("Paired phone") {
                VStack(alignment: .leading, spacing: 14) {
                    Button("Unpair phone", role: .destructive) {
                        gateway.revokePairedDevice()
                    }
                }
                .padding(8)
            }
        } else {
            GroupBox("Pair your phone") {
                VStack(alignment: .leading, spacing: 14) {
                    if let pairingCode = displayedPairingCode {
                        HStack(alignment: .top, spacing: 20) {
                            PairingQRCodeView(payload: pairingCode)
                                .frame(width: 220, height: 220)
                                .padding(10)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Scan this code with RepoPrompt Remote")
                                    .font(.headline)
                                Text("The code expires after five minutes, is single-use, and is invalidated when you generate a replacement.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if gateway.irohPairingCode != nil, gateway.legacyPairingCode != nil {
                                    Picker("Pairing transport", selection: $showsLegacyPairingCode) {
                                        Text("LAN HTTPS").tag(true)
                                        Text("Iroh").tag(false)
                                    }
                                    .pickerStyle(.segmented)
                                }
                                HStack {
                                    Button("Generate new code") {
                                        gateway.refreshPairingAdvertisement()
                                    }
                                    Button("Copy pairing link") {
                                        copyPairingLink()
                                    }
                                    .disabled(displayedPairingCode == nil)
                                }
                            }
                        }
                    } else {
                        Text(gateway.isEnabled ? "Start pairing to generate a code." : "Enable pairing to generate a code.")
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

                Text("Observe is the recommended default. Higher levels control which paired-device commands the Mac will accept.")
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

    private var displayedPairingCode: String? {
        if showsLegacyPairingCode { return gateway.legacyPairingCode }
        return gateway.irohPairingCode ?? gateway.legacyPairingCode
    }

    private func copyPairingLink() {
        guard let pairingCode = displayedPairingCode else { return }
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
