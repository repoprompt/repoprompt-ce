import Foundation

/// The user's custom workspace storage location (`GlobalCustomStorageURL`), read through one seam.
///
/// Under the checked-in test runner (`REPOPROMPT_TEST_SANDBOX_ROOT` is set), a persisted value that
/// points outside this run's sandbox can only be a leftover from another, crashed run (cfprefsd keeps
/// the xctest tool's defaults outside the sandboxed HOME). It is ignored process-locally, so the run
/// uses its own sandboxed default storage instead of adopting another run's ever-growing store. Nothing
/// is written or deleted. Without the variable (every product launch) the stored value is used as is.
enum WorkspaceStoragePreference {
    static let key = "GlobalCustomStorageURL"
    static let testSandboxEnvironmentKey = "REPOPROMPT_TEST_SANDBOX_ROOT"

    static func customStoragePath(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let path = defaults.string(forKey: key) else { return nil }
        guard let sandbox = environment[testSandboxEnvironmentKey], !sandbox.isEmpty else { return path }
        let root = canonicalPath(sandbox)
        let candidate = canonicalPath(path)
        return candidate == root || candidate.hasPrefix(root + "/") ? path : nil
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
