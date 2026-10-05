import Foundation
import RepoPromptFileSystem
import RepoPromptSettingsCore
import RepoPromptVCS

#if DEBUG
    private struct AppFileSystemReadAttribution: FileSystemReadAttribution {
        let benchmarkMetricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?

        func withAttribution<Value: Sendable>(
            _ operation: @Sendable () async throws -> Value
        ) async throws -> Value {
            try await WorktreeStartupInstrumentation.$currentBenchmarkMetricTag.withValue(
                benchmarkMetricTag,
                operation: operation
            )
        }
    }
#endif

/// App-owned process composition. Headless/module clients provide their own
/// settings and repository adapters when constructing IgnoreRulesManager.
enum FileSystemAppIntegration {
    static func makeIgnoreRulesManager() -> IgnoreRulesManager {
        installHooks()
        return IgnoreRulesManager(
            globalIgnoreProvider: {
                #if DEBUG
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                        return IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
                    }
                #endif
                return IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: .standard)
            },
            ignorePolicyResolver: { try IgnoreRulePolicy.resolvingLoadedRoot($0) },
            repositoryRootValidator: { root in
                guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: root) else { return false }
                return layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL == root
            }
        )
    }

    private static let hookInstallation: Void = {
        FileSystemRuntimeHooks.install(FileSystemRuntimeHooks(
            preferenceEnabled: { UserDefaults.standard.bool(forKey: $0) },
            servicePublication: { rootToken, source, deltas in
                #if DEBUG
                    MCPApplyEditsRebaseProbeRecorder.recordServicePublication(rootToken: rootToken, source: source, deltas: deltas)
                #endif
            },
            readFileDiskReadRecorder: {
                #if DEBUG
                    return MCPToolWorkCountDiagnostics.readFileDiskReadRecorder()
                #else
                    return { bytes, decodeMicroseconds in
                        MCPToolWorkCountDiagnostics.recordReadFileDiskRead(bytes: bytes, decodeMicroseconds: decodeMicroseconds)
                    }
                #endif
            },
            captureReadMetrics: {
                #if DEBUG
                    let collector = WorkspaceFileSearchDebugContext.coldStartCollector
                    let tag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
                    return FileSystemReadMetrics.Context(
                        attribution: AppFileSystemReadAttribution(benchmarkMetricTag: tag),
                        recordSchedulerRequest: { collector?.recordSchedulerRequest(workload: $0) },
                        recordSchedulerEnqueue: { collector?.recordSchedulerEnqueue(workload: $0) },
                        recordSchedulerGrant: { collector?.recordSchedulerGrant(workload: $0, waitNanoseconds: $1) },
                        recordSchedulerCompletion: {
                            collector?.recordSchedulerCompletion(workload: $0, executionNanoseconds: $1, cancelled: $2, failed: $3)
                        },
                        recordBenchmarkContentReadWork: {
                            WorktreeStartupInstrumentation.recordBenchmarkContentReadWork(tag: tag, waitMicroseconds: $0, executionMicroseconds: $1, overloaded: $2)
                        }
                    )
                #else
                    return nil
                #endif
            }
        ))
    }()

    static func installHooks() {
        _ = hookInstallation
    }
}
