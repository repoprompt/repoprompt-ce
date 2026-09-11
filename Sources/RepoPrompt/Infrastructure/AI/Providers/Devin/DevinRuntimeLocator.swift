import Foundation

/// Synchronous "is the Devin CLI installed" probe for availability/status surfaces.
///
/// Devin has no credential or setup step RepoPrompt owns — Devin manages its own auth — so
/// the installed executable IS the connection, exactly like `AntigravityRuntimeManager`'s
/// installed-runtime check. This deliberately never spawns a shell, runs the CLI, or hits
/// the network: it is called from view/view-model computed properties.
///
/// The launch path does NOT go through here. `DevinACPLaunchResolver` re-resolves and
/// validates executable identity for every launch; this probe only answers "offer Devin in
/// the picker / show it as connected".
enum DevinRuntimeLocator {
    /// Bounds repeated PATH scans from SwiftUI re-evaluation. Short enough that installing
    /// or removing the CLI is reflected without an app restart.
    private static let cacheLifetime: TimeInterval = 3

    private static let lock = NSLock()
    private static var cachedCommand: String?
    private static var cachedAt: Date?

    /// Resolved absolute path to an executable `devin`, or `nil` when it is not installed.
    ///
    /// Pure and injectable: no cache, no process environment capture.
    static func installedCommand(
        environment: [String: String],
        additionalPathHints: [String] = CLILaunchProfiles.devin.supplementalSearchPaths
    ) -> String? {
        let resolved = CommandPathResolver.resolve(
            CLILaunchProfiles.devin.commandName,
            environment: environment,
            additionalPaths: additionalPathHints,
            preferredBasenames: CLILaunchProfiles.devin.preferredBasenames,
            // Never query the user's shell here; a subprocess is far too expensive for a
            // property that UI reads during layout.
            shellLookupMode: .disabled
        )
        // `resolve` echoes the bare command back when the search misses.
        guard resolved.hasPrefix("/"),
              (resolved as NSString).lastPathComponent
              .caseInsensitiveCompare(CLILaunchProfiles.devin.commandName) == .orderedSame,
              CommandPathResolver.launchability(of: resolved) == .launchable
        else {
            return nil
        }
        return resolved
    }

    /// Cached process-environment probe used by availability and connection surfaces.
    static func isInstalledSync(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cachedAt, now.timeIntervalSince(cachedAt) < cacheLifetime {
            return cachedCommand != nil
        }
        let resolved = installedCommand(environment: ProcessInfo.processInfo.environment)
        cachedCommand = resolved
        cachedAt = now
        return resolved != nil
    }

    #if DEBUG
        static func test_resetCache() {
            lock.lock()
            cachedCommand = nil
            cachedAt = nil
            lock.unlock()
        }
    #endif
}
