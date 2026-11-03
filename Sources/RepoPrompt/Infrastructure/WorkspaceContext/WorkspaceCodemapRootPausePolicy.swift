import Foundation

/// The path preference is restored once per loaded-root epoch. Live pause/resume remains
/// window-local, as before; another window picks up the last saved choice on its next load.
/// Removing a root or clearing Code Map caches preserves the choice; explicit Resume clears it.
/// Separate defaults keys avoid lost updates between different roots/windows.
final class WorkspaceCodemapRootPausePolicy: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isPaused(rootPath: String) -> Bool {
        defaults.bool(forKey: Self.key(rootPath))
    }

    func setPaused(_ paused: Bool, rootPath: String) {
        if paused {
            defaults.set(true, forKey: Self.key(rootPath))
        } else {
            defaults.removeObject(forKey: Self.key(rootPath))
        }
    }

    private static func key(_ path: String) -> String {
        "codemap.pausedRoot.v1." + (path as NSString).standardizingPath
    }
}
