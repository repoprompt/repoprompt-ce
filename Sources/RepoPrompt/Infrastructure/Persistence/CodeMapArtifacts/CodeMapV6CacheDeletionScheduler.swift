#if !DEBUG
    import Foundation
    import OSLog
    import RepoPromptShared

    enum CodeMapV6CacheDeletionProductionTargetResolver {
        static func resolve() -> CodeMapV6CacheDeletionTarget {
            CodeMapV6CacheDeletionTarget(
                applicationSupportRootURL: MCPFilesystemConstants.identity.applicationSupportRootURL()
            )
        }
    }

    enum CodeMapV6CacheDeletionScheduler {
        private static let logger = Logger(
            subsystem: "com.repoprompt.codemap",
            category: "legacy-v6-cache-deletion"
        )

        static func schedule() {
            Task.detached(priority: .utility) {
                let target = CodeMapV6CacheDeletionProductionTargetResolver.resolve()
                let executor = CodeMapV6CacheDeletionExecutor()
                let retryDelaysMilliseconds: [UInt64] = [250, 1000]
                var aggregate = CodeMapV6CacheDeletionReport()

                for attempt in 0 ..< 3 {
                    let report = executor.execute(target: target)
                    aggregate.attemptCount = attempt + 1
                    aggregate.examinedCount += report.examinedCount
                    aggregate.eligibleV6Count += report.eligibleV6Count
                    aggregate.deletedCount += report.deletedCount
                    aggregate.missingOrRacedCount += report.missingOrRacedCount
                    aggregate.retainedUnrecognizedCount += report.retainedUnrecognizedCount
                    aggregate.retryableFailureCount += report.retryableFailureCount
                    aggregate.lockContentionCount += report.lockContentionCount
                    aggregate.completionWrittenCount += report.completionWrittenCount
                    aggregate.durationMilliseconds += report.durationMilliseconds

                    if report.retryableFailureCount == 0 {
                        record(aggregate)
                        return
                    }
                    if attempt < retryDelaysMilliseconds.count {
                        try? await Task.sleep(
                            nanoseconds: retryDelaysMilliseconds[attempt] * 1_000_000
                        )
                    }
                }
                record(aggregate)
            }
        }

        private static func record(_ report: CodeMapV6CacheDeletionReport) {
            logger.info(
                "legacy_v6_cache_deletion attempt_count=\(report.attemptCount, privacy: .public) examined_count=\(report.examinedCount, privacy: .public) eligible_v6_count=\(report.eligibleV6Count, privacy: .public) deleted_count=\(report.deletedCount, privacy: .public) missing_or_raced_count=\(report.missingOrRacedCount, privacy: .public) retained_unrecognized_count=\(report.retainedUnrecognizedCount, privacy: .public) retryable_failure_count=\(report.retryableFailureCount, privacy: .public) lock_contention_count=\(report.lockContentionCount, privacy: .public) completion_written_count=\(report.completionWrittenCount, privacy: .public) duration_milliseconds=\(report.durationMilliseconds, privacy: .public)"
            )
        }
    }
#endif
