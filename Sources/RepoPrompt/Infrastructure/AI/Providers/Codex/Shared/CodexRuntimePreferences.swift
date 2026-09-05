import Foundation

/// Persists the Codex runtime source explicitly selected in Settings.
///
/// An absent selection preserves the existing environment-override behavior. The runtime authority
/// owns executable validation; this type only normalizes and stores the user's choice.
enum CodexRuntimePreferences {
    enum Selection: Equatable {
        case inherited
        case bundled
        case external(path: String)
    }

    /// Capture before the first runtime resolution or Settings write. Pending choices only
    /// become active in the next process, including when Settings opens before any client.
    static let activeSelection = selection()

    private static let selectionModeKey = "codexRuntimeSelectionMode"
    private static let executablePathKey = "codexRuntimeExecutablePath"

    static func selection(defaults: UserDefaults = .standard) -> Selection {
        switch defaults.string(forKey: selectionModeKey) {
        case "bundled":
            .bundled
        case "external":
            normalizedPath(defaults.string(forKey: executablePathKey)).map { .external(path: $0) }
                ?? .inherited
        default:
            .inherited
        }
    }

    static func setSelection(_ selection: Selection, defaults: UserDefaults = .standard) {
        _ = activeSelection
        switch selection {
        case .inherited:
            defaults.removeObject(forKey: selectionModeKey)
            defaults.removeObject(forKey: executablePathKey)
        case .bundled:
            defaults.set("bundled", forKey: selectionModeKey)
            defaults.removeObject(forKey: executablePathKey)
        case let .external(path):
            guard let path = normalizedPath(path) else {
                setSelection(.inherited, defaults: defaults)
                return
            }
            defaults.set("external", forKey: selectionModeKey)
            defaults.set(path, forKey: executablePathKey)
        }
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }
}
