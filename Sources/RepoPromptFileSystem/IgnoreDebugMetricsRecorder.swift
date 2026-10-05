#if DEBUG
    import Darwin
    import Foundation

    package struct IgnoreDebugMetrics: Equatable, Codable {
        package var compileCallCount = 0
        package var compileRawLineCount = 0
        package var compilePatternCount = 0
        package var compileNegationPatternCount = 0
        package var compileTraversalExactPrefixCount = 0
        package var compileTraversalPatternHintCount = 0
        package var compileTraversalBroadPatternHintCount = 0
        package var compileBasenameOnlyNegationCount = 0
        package var outcomeEvaluationCount = 0
        package var patternVisitCount = 0
        package var patternMatchAttemptCount = 0
        package var outcomeZeroAttemptCount = 0
        package var outcomeOneAttemptCount = 0
        package var outcomeTwoToFourAttemptCount = 0
        package var outcomeFiveToEightAttemptCount = 0
        package var outcomeNineToSixteenAttemptCount = 0
        package var outcomeSeventeenToThirtyTwoAttemptCount = 0
        package var outcomeThirtyThreeToSixtyFourAttemptCount = 0
        package var outcomeSixtyFivePlusAttemptCount = 0
        package var maxPatternAttemptsPerOutcome = 0
        package var maxPatternVisitsPerOutcome = 0
        package var patternPrefilterCheckCount = 0
        package var patternPrefilterSkipCount = 0
        package var patternPrefilterPassCount = 0
        package var trailingDoubleStarBaseCheckCount = 0
        package var traversalRequiresCheckCount = 0
        package var traversalExactPrefixHitCount = 0
        package var traversalPatternCheckCount = 0
        package var traversalPatternHitCount = 0
        package var prefixCacheHitCount = 0
        package var prefixCacheMissCount = 0
        package var prefixCacheTraversalContinueCount = 0
        package var snapshotIgnoreLocalCacheHitCount = 0
        package var snapshotIgnoreLocalCacheMissCount = 0
        package var snapshotIgnoreReadOnlyBaseHitCount = 0
        package var hierarchicalRulesLookupCount = 0
        package var hierarchicalRulesCacheHitCount = 0
        package var hierarchicalRulesCacheMissCount = 0
        package var hierarchicalComponentEvaluationCount = 0
        package var hierarchicalLockedRulesReuseCount = 0
        package var hierarchicalLockCount = 0
        package var hierarchicalUnlockCount = 0
        package var hierarchicalOutcomeMatchCount = 0
    }

    package enum IgnoreDebugMetricsRecorder {
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
            return FileSystemRuntimeHooks.current.preferenceEnabled(enabledDefaultsKey)
                || FileSystemRuntimeHooks.current.preferenceEnabled(dumpEnabledDefaultsKey)
        }()

        private static var recordingEnabled = defaultRecordingEnabled

        package static var isRecordingEnabled: Bool {
            recordingEnabled
        }

        package static func setRecordingEnabledForTesting(_ enabled: Bool) {
            lock.lock()
            recordingEnabled = enabled
            storage = IgnoreDebugMetrics()
            lock.unlock()
        }

        package static func resetRecordingEnabledForTesting() {
            lock.lock()
            recordingEnabled = defaultRecordingEnabled
            storage = IgnoreDebugMetrics()
            lock.unlock()
        }

        package static func reset() {
            lock.lock()
            storage = IgnoreDebugMetrics()
            lock.unlock()
        }

        package static func snapshot() -> IgnoreDebugMetrics {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        package static func recordCompile(
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

        package static func recordOutcomeEvaluation(
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

        package static func recordTrailingDoubleStarBaseCheck() {
            mutate { $0.trailingDoubleStarBaseCheckCount += 1 }
        }

        package static func recordTraversalRequiresCheck() {
            mutate { $0.traversalRequiresCheckCount += 1 }
        }

        package static func recordTraversalExactPrefixHit() {
            mutate { $0.traversalExactPrefixHitCount += 1 }
        }

        package static func recordTraversalPatternCheck() {
            mutate { $0.traversalPatternCheckCount += 1 }
        }

        package static func recordTraversalPatternHit() {
            mutate { $0.traversalPatternHitCount += 1 }
        }

        package static func recordPrefixCacheHit() {
            mutate { $0.prefixCacheHitCount += 1 }
        }

        package static func recordPrefixCacheMiss() {
            mutate { $0.prefixCacheMissCount += 1 }
        }

        package static func recordPrefixCacheTraversalContinue() {
            mutate { $0.prefixCacheTraversalContinueCount += 1 }
        }

        package static func recordSnapshotIgnoreLocalCacheHit() {
            mutate { $0.snapshotIgnoreLocalCacheHitCount += 1 }
        }

        package static func recordSnapshotIgnoreLocalCacheMiss() {
            mutate { $0.snapshotIgnoreLocalCacheMissCount += 1 }
        }

        package static func recordSnapshotIgnoreReadOnlyBaseHit() {
            mutate { $0.snapshotIgnoreReadOnlyBaseHitCount += 1 }
        }

        package static func recordHierarchicalRulesLookup() {
            mutate { $0.hierarchicalRulesLookupCount += 1 }
        }

        package static func recordHierarchicalRulesCacheHit() {
            mutate { $0.hierarchicalRulesCacheHitCount += 1 }
        }

        package static func recordHierarchicalRulesCacheMiss() {
            mutate { $0.hierarchicalRulesCacheMissCount += 1 }
        }

        package static func recordHierarchicalComponentEvaluation() {
            mutate { $0.hierarchicalComponentEvaluationCount += 1 }
        }

        package static func recordHierarchicalLockedRulesReuse() {
            mutate { $0.hierarchicalLockedRulesReuseCount += 1 }
        }

        package static func recordHierarchicalLock() {
            mutate { $0.hierarchicalLockCount += 1 }
        }

        package static func recordHierarchicalUnlock() {
            mutate { $0.hierarchicalUnlockCount += 1 }
        }

        package static func recordHierarchicalOutcomeMatch() {
            mutate { $0.hierarchicalOutcomeMatchCount += 1 }
        }

        package static func resetAndDumpSnapshotIfEnabled(label: String) {
            guard metricsDumpEnabled else { return }
            reset()
            dumpSnapshotIfEnabled(label: label)
        }

        package static func dumpSnapshotIfEnabled(label: String) {
            guard metricsDumpEnabled else { return }
            let payload = IgnoreDebugMetricsDump(
                label: label,
                timestamp: Date().timeIntervalSince1970,
                metrics: snapshot()
            )
            guard let data = try? JSONEncoder().encode(payload),
                  let outputURL = secureDumpOutputURL()
            else {
                return
            }
            let fd = open(outputURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data([0x0A]))
        }

        private static var metricsDumpEnabled: Bool {
            if isTruthy(ProcessInfo.processInfo.environment[dumpEnabledEnvironmentKey]) {
                return true
            }
            return FileSystemRuntimeHooks.current.preferenceEnabled(dumpEnabledDefaultsKey)
        }

        private static func isTruthy(_ value: String?) -> Bool {
            guard let value = value?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(value)
        }

        private static func secureDumpOutputURL() -> URL? {
            let fileManager = FileManager.default
            let directoryURL = fileManager.temporaryDirectory
                .appendingPathComponent("com.repoprompt.ignore-metrics.\(getuid())", isDirectory: true)
            let directoryPath = directoryURL.path
            if fileManager.fileExists(atPath: directoryPath) {
                guard isDirectoryAndNotSymlink(directoryURL) else { return nil }
            } else {
                do {
                    try fileManager.createDirectory(
                        at: directoryURL,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    return nil
                }
            }

            let outputURL = directoryURL.appendingPathComponent(dumpOutputFileName, isDirectory: false)
            if fileManager.fileExists(atPath: outputURL.path), !isRegularFileAndNotSymlink(outputURL) {
                return nil
            }
            return outputURL
        }

        private static func isDirectoryAndNotSymlink(_ url: URL) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            return (info.st_mode & S_IFMT) == S_IFDIR
        }

        private static func isRegularFileAndNotSymlink(_ url: URL) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            return (info.st_mode & S_IFMT) == S_IFREG
        }

        private struct IgnoreDebugMetricsDump: Codable {
            let label: String
            let timestamp: TimeInterval
            let metrics: IgnoreDebugMetrics
        }

        private static func mutate(_ body: (inout IgnoreDebugMetrics) -> Void) {
            guard isRecordingEnabled else { return }
            lock.lock()
            body(&storage)
            lock.unlock()
        }
    }
#endif
