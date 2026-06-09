#if DEBUG
    import Foundation

    struct IgnoreDebugMetrics: Equatable, Codable {
        var compileCallCount = 0
        var compileRawLineCount = 0
        var compilePatternCount = 0
        var compileNegationPatternCount = 0
        var compileTraversalExactPrefixCount = 0
        var compileTraversalPatternHintCount = 0
        var compileTraversalBroadPatternHintCount = 0
        var compileBasenameOnlyNegationCount = 0
        var outcomeEvaluationCount = 0
        var patternVisitCount = 0
        var patternMatchAttemptCount = 0
        var outcomeZeroAttemptCount = 0
        var outcomeOneAttemptCount = 0
        var outcomeTwoToFourAttemptCount = 0
        var outcomeFiveToEightAttemptCount = 0
        var outcomeNineToSixteenAttemptCount = 0
        var outcomeSeventeenToThirtyTwoAttemptCount = 0
        var outcomeThirtyThreeToSixtyFourAttemptCount = 0
        var outcomeSixtyFivePlusAttemptCount = 0
        var maxPatternAttemptsPerOutcome = 0
        var maxPatternVisitsPerOutcome = 0
        var patternPrefilterCheckCount = 0
        var patternPrefilterSkipCount = 0
        var patternPrefilterPassCount = 0
        var trailingDoubleStarBaseCheckCount = 0
        var traversalRequiresCheckCount = 0
        var traversalExactPrefixHitCount = 0
        var traversalPatternCheckCount = 0
        var traversalPatternHitCount = 0
        var prefixCacheHitCount = 0
        var prefixCacheMissCount = 0
        var prefixCacheTraversalContinueCount = 0
        var snapshotIgnoreLocalCacheHitCount = 0
        var snapshotIgnoreLocalCacheMissCount = 0
        var snapshotIgnoreReadOnlyBaseHitCount = 0
        var hierarchicalRulesLookupCount = 0
        var hierarchicalRulesCacheHitCount = 0
        var hierarchicalRulesCacheMissCount = 0
        var hierarchicalComponentEvaluationCount = 0
        var hierarchicalLockedRulesReuseCount = 0
        var hierarchicalLockCount = 0
        var hierarchicalUnlockCount = 0
        var hierarchicalOutcomeMatchCount = 0
    }

    enum IgnoreDebugMetricsRecorder {
        private static let lock = NSLock()
        private static var storage = IgnoreDebugMetrics()
        private static let enabledEnvironmentKey = "REPOPROMPT_IGNORE_METRICS_ENABLED"
        private static let replayBenchmarkVerboseEnvironmentKey = "REPOPROMPT_REPLAY_BENCHMARK_VERBOSE_TELEMETRY"
        private static let enabledDefaultsKey = "RepoPromptIgnoreMetricsEnabled"
        private static let dumpEnabledEnvironmentKey = "REPOPROMPT_IGNORE_METRICS_DUMP"
        private static let dumpEnabledDefaultsKey = "RepoPromptIgnoreMetricsDumpEnabled"
        private static let dumpOutputFileName = "ignore-metrics.jsonl"

        private static let defaultRecordingEnabled: Bool = {
            let environment = ProcessInfo.processInfo.environment
            if isTruthy(environment[enabledEnvironmentKey])
                || isTruthy(environment[replayBenchmarkVerboseEnvironmentKey])
                || isTruthy(environment[dumpEnabledEnvironmentKey])
            {
                return true
            }
            return false
        }()

        private static var recordingEnabled = defaultRecordingEnabled

        static var isRecordingEnabled: Bool {
            recordingEnabled
        }

        static func setRecordingEnabledForTesting(_ enabled: Bool) {
            lock.lock()
            recordingEnabled = enabled
            storage = IgnoreDebugMetrics()
            lock.unlock()
        }

        static func resetRecordingEnabledForTesting() {
            lock.lock()
            recordingEnabled = defaultRecordingEnabled
            storage = IgnoreDebugMetrics()
            lock.unlock()
        }

        static func reset() {
            lock.lock()
            storage = IgnoreDebugMetrics()
            lock.unlock()
        }

        static func snapshot() -> IgnoreDebugMetrics {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        static func recordCompile(
            rawLineCount: Int,
            patternCount: Int,
            negationPatternCount: Int,
            diagnostics: NegationTraversalDiagnostics
        ) {
            mutate {
                $0.compileCallCount += 1
                $0.compileRawLineCount += rawLineCount
                $0.compilePatternCount += patternCount
                $0.compileNegationPatternCount += negationPatternCount
                $0.compileTraversalExactPrefixCount += diagnostics.exactPrefixCount
                $0.compileTraversalPatternHintCount += diagnostics.patternHintCount
                $0.compileTraversalBroadPatternHintCount += diagnostics.broadPatternHintCount
                $0.compileBasenameOnlyNegationCount += diagnostics.basenameOnlyNegationCount
            }
        }

        static func recordOutcomeEvaluation(
            patternVisits: Int,
            patternAttempts: Int,
            prefilterChecks: Int = 0,
            prefilterSkips: Int = 0
        ) {
            mutate {
                $0.outcomeEvaluationCount += 1
                $0.patternVisitCount += patternVisits
                $0.patternMatchAttemptCount += patternAttempts
                $0.patternPrefilterCheckCount += prefilterChecks
                $0.patternPrefilterSkipCount += prefilterSkips
                $0.patternPrefilterPassCount += max(0, prefilterChecks - prefilterSkips)
                $0.maxPatternAttemptsPerOutcome = max($0.maxPatternAttemptsPerOutcome, patternAttempts)
                $0.maxPatternVisitsPerOutcome = max($0.maxPatternVisitsPerOutcome, patternVisits)
                switch patternAttempts {
                case 0:
                    $0.outcomeZeroAttemptCount += 1
                case 1:
                    $0.outcomeOneAttemptCount += 1
                case 2 ... 4:
                    $0.outcomeTwoToFourAttemptCount += 1
                case 5 ... 8:
                    $0.outcomeFiveToEightAttemptCount += 1
                case 9 ... 16:
                    $0.outcomeNineToSixteenAttemptCount += 1
                case 17 ... 32:
                    $0.outcomeSeventeenToThirtyTwoAttemptCount += 1
                case 33 ... 64:
                    $0.outcomeThirtyThreeToSixtyFourAttemptCount += 1
                default:
                    $0.outcomeSixtyFivePlusAttemptCount += 1
                }
            }
        }

        static func recordTrailingDoubleStarBaseCheck() {
            mutate { $0.trailingDoubleStarBaseCheckCount += 1 }
        }

        static func recordTraversalRequiresCheck() {
            mutate { $0.traversalRequiresCheckCount += 1 }
        }

        static func recordTraversalExactPrefixHit() {
            mutate { $0.traversalExactPrefixHitCount += 1 }
        }

        static func recordTraversalPatternCheck() {
            mutate { $0.traversalPatternCheckCount += 1 }
        }

        static func recordTraversalPatternHit() {
            mutate { $0.traversalPatternHitCount += 1 }
        }

        static func recordPrefixCacheHit() {
            mutate { $0.prefixCacheHitCount += 1 }
        }

        static func recordPrefixCacheMiss() {
            mutate { $0.prefixCacheMissCount += 1 }
        }

        static func recordPrefixCacheTraversalContinue() {
            mutate { $0.prefixCacheTraversalContinueCount += 1 }
        }

        static func recordSnapshotIgnoreLocalCacheHit() {
            mutate { $0.snapshotIgnoreLocalCacheHitCount += 1 }
        }

        static func recordSnapshotIgnoreLocalCacheMiss() {
            mutate { $0.snapshotIgnoreLocalCacheMissCount += 1 }
        }

        static func recordSnapshotIgnoreReadOnlyBaseHit() {
            mutate { $0.snapshotIgnoreReadOnlyBaseHitCount += 1 }
        }

        static func recordHierarchicalRulesLookup() {
            mutate { $0.hierarchicalRulesLookupCount += 1 }
        }

        static func recordHierarchicalRulesCacheHit() {
            mutate { $0.hierarchicalRulesCacheHitCount += 1 }
        }

        static func recordHierarchicalRulesCacheMiss() {
            mutate { $0.hierarchicalRulesCacheMissCount += 1 }
        }

        static func recordHierarchicalComponentEvaluation() {
            mutate { $0.hierarchicalComponentEvaluationCount += 1 }
        }

        static func recordHierarchicalLockedRulesReuse() {
            mutate { $0.hierarchicalLockedRulesReuseCount += 1 }
        }

        static func recordHierarchicalLock() {
            mutate { $0.hierarchicalLockCount += 1 }
        }

        static func recordHierarchicalUnlock() {
            mutate { $0.hierarchicalUnlockCount += 1 }
        }

        static func recordHierarchicalOutcomeMatch() {
            mutate { $0.hierarchicalOutcomeMatchCount += 1 }
        }

        static func resetAndDumpSnapshotIfEnabled(label _: String) {
            reset()
        }

        static func dumpSnapshotIfEnabled(label _: String) {}

        private static func isTruthy(_ value: String?) -> Bool {
            guard let value = value?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(value)
        }

        private static func mutate(_ body: (inout IgnoreDebugMetrics) -> Void) {
            guard isRecordingEnabled else { return }
            lock.lock()
            body(&storage)
            lock.unlock()
        }
    }
#endif
