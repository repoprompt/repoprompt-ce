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

    var customResource: (name: String, extension: String)? {
        switch self {
        case .light:
            ("AppIconLight", "png")
        case .dark, .system:
            nil
        }
    }
}

@MainActor
final class AppIconController {
    static let shared = AppIconController()

    private let application: NSApplication
    private let defaultApplicationIcon: NSImage?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastAppliedMode: AppIconMode?

    private init(application: NSApplication = .shared) {
        self.application = application
        defaultApplicationIcon = application.applicationIconImage.copy() as? NSImage
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

        guard let resource = resolvedMode.customResource else {
            application.applicationIconImage = defaultApplicationIcon
            lastAppliedMode = resolvedMode
            return
        }

        guard let resourceURL = Bundle.main.url(forResource: resource.name, withExtension: resource.extension),
              let image = NSImage(contentsOf: resourceURL)
        else {
            return
        }

        application.applicationIconImage = image
        lastAppliedMode = resolvedMode
    }
}
