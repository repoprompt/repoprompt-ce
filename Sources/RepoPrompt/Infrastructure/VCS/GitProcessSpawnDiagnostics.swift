import OSLog

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
enum GitProcessSpawnDiagnostics {
    private static let signposter = OSSignposter(subsystem: "com.repoprompt.git", category: "process-spawn")
    private static let logger = Logger(subsystem: "com.repoprompt.git", category: "process-spawn")
    private static let slowSpawnThresholdMicroseconds = 100_000

    static func beginSpawnInterval(
        family: GitProcessCommandFamily,
        priority: GitProcessAdmissionPriority
    ) -> OSSignpostIntervalState {
        signposter.beginInterval(
            "git-spawn",
            id: signposter.makeSignpostID(),
            "family=\(family.rawValue, privacy: .public) priority=\(priority.rawValue, privacy: .public)"
        )
    }

    static func endSpawnInterval(
        _ state: OSSignpostIntervalState,
        family: GitProcessCommandFamily,
        priority: GitProcessAdmissionPriority,
        spawnMicroseconds: Int,
        success: Bool
    ) {
        signposter.endInterval("git-spawn", state)
        guard !success || spawnMicroseconds >= slowSpawnThresholdMicroseconds else { return }
        let outcome = success ? "slow" : "failed"
        logger.info(
            "git spawn \(outcome, privacy: .public) family=\(family.rawValue, privacy: .public) priority=\(priority.rawValue, privacy: .public) micros=\(spawnMicroseconds, privacy: .public)"
        )
    }
}
