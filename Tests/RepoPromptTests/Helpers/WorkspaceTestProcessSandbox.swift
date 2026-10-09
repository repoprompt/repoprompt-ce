import Foundation
import XCTest

#if DEBUG
    /// Stateless, fail-closed validation of the checked-in CI runner process sandbox
    /// (`Scripts/ci_app_test_runner.py`). Call before any shared settings, sidecar, key, store,
    /// or singleton access; a failure aborts setup and never falls back to the user's storage.
    enum WorkspaceTestProcessSandbox {
        enum IsolationFailure: Error {
            case invalidEnvironment, foundationOutsideSandbox
        }

        static func validate() throws -> URL {
            let env = ProcessInfo.processInfo.environment
            let raw = try XCTUnwrap(
                env["REPOPROMPT_TEST_SANDBOX_ROOT"],
                "Run this suite with Scripts/ci_app_test_runner.py"
            )
            let sandbox = normalizedDirectoryURL(raw)
            guard (raw as NSString).isAbsolutePath, sandbox.path != "/" else {
                throw IsolationFailure.invalidEnvironment
            }

            let expectedHome = normalizedDirectoryURL(sandbox.appendingPathComponent("home", isDirectory: true).path)
            guard expectedHome.deletingLastPathComponent().path == sandbox.path,
                  try normalizedEnvironmentDirectory("HOME", in: env) == expectedHome,
                  try normalizedEnvironmentDirectory("CFFIXED_USER_HOME", in: env) == expectedHome
            else { throw IsolationFailure.invalidEnvironment }

            let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            ).resolvingSymlinksInPath()
            guard home == expectedHome,
                  support.path.hasPrefix(home.path + "/"),
                  FileManager.default.fileExists(atPath: sandbox.appendingPathComponent(".issue944-test-sandbox").path)
            else { throw IsolationFailure.foundationOutsideSandbox }

            for (key, suffix) in [
                ("TMPDIR", "tmp"), ("TMP", "tmp"), ("TEMP", "tmp"),
                ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data")
            ] {
                let expected = normalizedDirectoryURL(sandbox.appendingPathComponent(suffix, isDirectory: true).path)
                guard expected.deletingLastPathComponent().path == sandbox.path,
                      try normalizedEnvironmentDirectory(key, in: env) == expected
                else {
                    throw IsolationFailure.invalidEnvironment
                }
            }
            print("ISSUE944 isolation=verified foundationHome=true applicationSupport=true")
            return sandbox
        }

        private static func normalizedEnvironmentDirectory(
            _ key: String,
            in environment: [String: String]
        ) throws -> URL {
            let path = try XCTUnwrap(environment[key], "Missing \(key) in CI test sandbox")
            guard (path as NSString).isAbsolutePath else { throw IsolationFailure.invalidEnvironment }
            return normalizedDirectoryURL(path)
        }

        private static func normalizedDirectoryURL(_ path: String) -> URL {
            URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }
    }
#endif
