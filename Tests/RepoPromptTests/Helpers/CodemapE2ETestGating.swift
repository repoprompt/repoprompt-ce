import Foundation

enum CodemapE2ETestGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["RPCE_RUN_CODEMAP_E2E"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/RepoPromptCE-codemap-e2e-opt-in")
    }
}
