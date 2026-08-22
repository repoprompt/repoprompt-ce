import AppKit

enum AppIconMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String {
        rawValue
    }

    func resolved(for appearance: NSAppearance) -> AppIconMode {
        guard self == .system else { return self }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    fileprivate var resource: (name: String, extension: String) {
        switch self {
        case .light:
            ("AppIconLight", "png")
        case .dark, .system:
            ("AppIcon", "icns")
        }
    }
}

@MainActor
final class AppIconController {
    static let shared = AppIconController()

    private let application: NSApplication
    private var appearanceObservation: NSKeyValueObservation?
    private var lastAppliedMode: AppIconMode?

    private init(application: NSApplication = .shared) {
        self.application = application
        appearanceObservation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyFromGlobalSettings()
            }
        }
    }

    func applyFromGlobalSettings() {
        apply(modeRawValue: GlobalSettingsStore.shared.appIconModeRaw())
    }

    func apply(modeRawValue: AppIconMode.RawValue) {
        let mode = AppIconMode(rawValue: modeRawValue) ?? .system
        let resolvedMode = mode.resolved(for: application.effectiveAppearance)
        guard resolvedMode != lastAppliedMode else { return }

        let resource = resolvedMode.resource
        guard let resourceURL = Bundle.main.url(forResource: resource.name, withExtension: resource.extension),
              let image = NSImage(contentsOf: resourceURL)
        else {
            return
        }

        application.applicationIconImage = image
        lastAppliedMode = resolvedMode
    }
}
