import Foundation

/// Persists the Codex runtime source explicitly selected in Settings.
///
/// An absent selection is retained as `.inherited` only so Settings can explain that a legacy
/// environment override was ignored. Runtime resolution treats absence as bundled; the runtime
/// authority owns executable validation, while this type only normalizes and stores user choice.
enum CodexRuntimePreferences {
    enum Selection: Equatable {
        case inherited
        case bundled
        case external(path: String)
        case invalidExternalPreference
    }

    struct RuntimeSelectionProjection: Equatable {
        let active: Selection
        let pending: Selection

        var changesAfterRelaunch: Bool {
            !CodexRuntimePreferences.areSemanticallyEquivalent(active, pending)
        }
    }

    /// Returns the process-active choice from the single runtime authority. Pending choices only
    /// become active in the next process, including when Settings opens before any client.
    static var activeSelection: Selection {
        CodexRuntimeAuthority.currentLaunchSnapshot().selection
    }

    private static let selectionModeKey = "codexRuntimeSelectionMode"
    private static let executablePathKey = "codexRuntimeExecutablePath"

    static func selection(defaults: UserDefaults = .standard) -> Selection {
        switch defaults.string(forKey: selectionModeKey) {
        case "bundled":
            .bundled
        case "external":
            normalizedPath(defaults.string(forKey: executablePathKey)).map { .external(path: $0) }
                ?? .invalidExternalPreference
        default:
            .inherited
        }
    }

    static func runtimeSelectionProjection(
        active: Selection = activeSelection,
        pending: Selection = selection()
    ) -> RuntimeSelectionProjection {
        RuntimeSelectionProjection(active: active, pending: pending)
    }

    static func areSemanticallyEquivalent(_ lhs: Selection, _ rhs: Selection) -> Bool {
        switch (lhs, rhs) {
        case (.inherited, .bundled), (.bundled, .inherited):
            true
        default:
            lhs == rhs
        }
    }

    static func setSelection(_ selection: Selection, defaults: UserDefaults = .standard) {
        switch selection {
        case .inherited:
            defaults.removeObject(forKey: selectionModeKey)
            defaults.removeObject(forKey: executablePathKey)
        case .bundled:
            defaults.set("bundled", forKey: selectionModeKey)
            defaults.removeObject(forKey: executablePathKey)
        case let .external(path):
            guard let path = normalizedPath(path) else {
                defaults.set("external", forKey: selectionModeKey)
                defaults.removeObject(forKey: executablePathKey)
                return
            }
            defaults.set("external", forKey: selectionModeKey)
            defaults.set(path, forKey: executablePathKey)
        case .invalidExternalPreference:
            defaults.set("external", forKey: selectionModeKey)
            defaults.removeObject(forKey: executablePathKey)
        }
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }
}
