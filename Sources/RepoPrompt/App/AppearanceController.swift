import AppKit
import Foundation

@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()

    private var lastAppliedMode: AppearanceMode?

    func applyFromGlobalSettings() {
        apply(modeRawValue: GlobalSettingsStore.shared.appearanceModeRaw())
    }

    func apply(modeRawValue: AppearanceMode.RawValue) {
        let mode = AppearanceMode(rawValue: modeRawValue) ?? .system
        apply(mode: mode)
    }

    func apply(mode: AppearanceMode) {
        let desiredAppearance = appearance(for: mode)
        if lastAppliedMode == mode, isAppearanceApplied(desiredAppearance) {
            return
        }

        lastAppliedMode = mode
        if !isAppearanceApplied(desiredAppearance) {
            NSApplication.shared.appearance = desiredAppearance
        }
        AppIconController.shared.applyFromGlobalSettings()
    }

    private func appearance(for mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        case .system:
            nil
        }
    }

    private func isAppearanceApplied(_ desiredAppearance: NSAppearance?) -> Bool {
        let currentAppearance = NSApplication.shared.appearance
        switch (desiredAppearance, currentAppearance) {
        case (nil, nil):
            return true
        case let (desired?, current?):
            return desired.name == current.name
        default:
            return false
        }
    }
}
