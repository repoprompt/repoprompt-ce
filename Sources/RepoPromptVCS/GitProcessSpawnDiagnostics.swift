import Foundation
#if canImport(OSLog)
    import OSLog

    package typealias GitProcessSpawnInterval = OSSignpostIntervalState
#else
    package struct GitProcessSpawnInterval {
        let startedAt: ContinuousClock.Instant
    }
#endif
import RepoPromptInstrumentation

/// Privacy-safe spawn-attempt diagnostics for git children.
///
/// `posix_spawn` is synchronous and was historically invisible: nothing was
/// recorded until the launch call returned, so a stalled spawn left no local
/// evidence. The signpost interval opens *before* the spawn call and closes
/// after it returns; a stall is visible as an unclosed `git-spawn` interval in
/// any Instruments or log capture. Slow or failed spawns additionally emit one
/// bounded log line.
///
/// Deliberately low-cardinality: only the command family, admission priority,
/// spawn duration, and outcome are recorded. Never includes command arguments,
/// paths, repository identifiers, environment, or stdin.
package enum GitProcessSpawnDiagnostics {
    #if canImport(OSLog)
        private static let signposter = OSSignposter(subsystem: "com.repoprompt.git", category: "process-spawn")
        private static let logger = Logger(subsystem: "com.repoprompt.git", category: "process-spawn")
    #endif
    private static let slowSpawnThresholdMicroseconds = 100_000

    package static func beginSpawnInterval(
        family: GitProcessCommandFamily,
        priority: GitProcessAdmissionPriority
    ) -> GitProcessSpawnInterval {
        #if canImport(OSLog)
            signposter.beginInterval(
                "git-spawn",
                id: signposter.makeSignpostID(),
                "family=\(family.rawValue, privacy: .public) priority=\(priority.rawValue, privacy: .public)"
            )
        #else
            GitProcessSpawnInterval(startedAt: ContinuousClock.now)
        #endif
    }

    package static func endSpawnInterval(
        _ state: GitProcessSpawnInterval,
        family: GitProcessCommandFamily,
        priority: GitProcessAdmissionPriority,
        spawnMicroseconds: Int,
        success: Bool
    ) {
        #if canImport(OSLog)
            signposter.endInterval("git-spawn", state)
        #endif
        guard !success || spawnMicroseconds >= slowSpawnThresholdMicroseconds else { return }
        let outcome = success ? "slow" : "failed"
        #if canImport(OSLog)
            logger.info(
                "git spawn \(outcome, privacy: .public) family=\(family.rawValue, privacy: .public) priority=\(priority.rawValue, privacy: .public) micros=\(spawnMicroseconds, privacy: .public)"
            )
        #else
            let message = "git spawn \(outcome) family=\(family.rawValue) priority=\(priority.rawValue) micros=\(spawnMicroseconds) elapsed=\(state.startedAt.duration(to: ContinuousClock.now))\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        #endif
    }
}
