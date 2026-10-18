import Foundation

/// The user's custom workspace storage location (`GlobalCustomStorageURL`), read through one seam.
///
/// A test fixture killed before restoring this key leaves it pinned in the xctest tool's defaults,
/// which cfprefsd keeps outside the runner's sandboxed HOME, so every later test process would adopt
/// that long-gone run's ever-growing workspace store. The checked-in runner reads the pre-run value
/// (read-only) and passes it as `REPOPROMPT_TEST_INHERITED_STORAGE_PREFERENCE`; this seam then ignores
/// exactly that inherited value process-locally (unless it lies inside this run's sandbox). Values a
/// test's own fixtures set are always honored. Nothing is written or deleted. Without the runner's
/// variables (every product launch) the stored value is used as is.
enum WorkspaceStoragePreference {
    static let key = "GlobalCustomStorageURL"
    static let testSandboxEnvironmentKey = "REPOPROMPT_TEST_SANDBOX_ROOT"
    static let inheritedPreferenceEnvironmentKey = "REPOPROMPT_TEST_INHERITED_STORAGE_PREFERENCE"

    static func customStoragePath(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let path = defaults.string(forKey: key) else { return nil }
        guard let sandbox = environment[testSandboxEnvironmentKey], !sandbox.isEmpty,
              let inherited = environment[inheritedPreferenceEnvironmentKey], !inherited.isEmpty,
              canonicalPath(path) == canonicalPath(inherited)
        else { return path }
        let root = canonicalPath(sandbox)
        let candidate = canonicalPath(path)
        return candidate == root || candidate.hasPrefix(root + "/") ? path : nil
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
