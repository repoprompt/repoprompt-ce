import Foundation

/// The path preference is restored once per loaded-root epoch. Live pause/resume remains
/// window-local, as before; another window picks up the last saved choice on its next load.
/// Removing a root or clearing Code Map caches preserves the choice; explicit Resume clears it.
/// Separate defaults keys avoid lost updates between different roots/windows.
///
/// The saved preference is keyed only by the standardized root path. Runtime root identity also
/// involves the per-load root ID/lifetime and filesystem authority (device/inode checks), but
/// none of that is used to migrate this preference:
/// - Changing a root's display name keeps the preference, because the path is unchanged.
/// - Renaming or moving the directory changes the path. The new path uses its own saved
///   preference (unpaused unless that path was itself paused), and the old path's entry is
///   retained so re-adding that path restores it.
/// - A different folder later placed at a saved path inherits that path's pause. Status and MCP
///   report it as paused, and Resume clears it.
/// Entries are never pruned: a missing path is indistinguishable from an unmounted or
/// temporarily unavailable volume, and each entry is a single boolean.
package final class WorkspaceCodemapRootPausePolicy: @unchecked Sendable {
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func isPaused(rootPath: String) -> Bool {
        defaults.bool(forKey: Self.key(rootPath))
    }

    package func setPaused(_ paused: Bool, rootPath: String) {
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
