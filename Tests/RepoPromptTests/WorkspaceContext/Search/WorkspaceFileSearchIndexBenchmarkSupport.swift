#if DEBUG
    import Darwin
    import Foundation
    @testable import RepoPrompt

    enum WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration {
        static let fileURL = URL(fileURLWithPath: "/tmp/RepoPromptCE-file-search-index-run-config.json")

        static func values() -> [String: String] {
            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return [:] }
            return object
        }

        static func isEnabled(environmentKey: String, configurationKey: String) -> Bool {
            ProcessInfo.processInfo.environment[environmentKey] == "1"
                || values()[configurationKey] == "1"
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkFixture {
        static let moduleCount = 64
        static let layerCount = 4
        static let filesPerLayer = 64
        static let seedFileCount = moduleCount * layerCount * filesPerLayer
        static let folderCount = 1 + moduleCount + moduleCount + moduleCount * layerCount
        static let firstScopedNeedleRelativePath = "Module-00/Sources/Layer-00/FirstScopedNeedle.swift"

        let containerURL: URL
        let visibleRootURL: URL
        let worktreeRootURL: URL

        var firstScopedNeedleURL: URL {
            worktreeRootURL.appendingPathComponent(Self.firstScopedNeedleRelativePath)
        }

        static func make() throws -> Self {
            let containerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt-FileSearchIndexBenchmark-\(UUID().uuidString)", isDirectory: true)
            let visibleRootURL = containerURL.appendingPathComponent("VisibleRoot", isDirectory: true)
            let worktreeRootURL = containerURL.appendingPathComponent("SessionWorktree", isDirectory: true)
            try FileManager.default.createDirectory(at: visibleRootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: worktreeRootURL, withIntermediateDirectories: true)
            try fixtureContents.write(
                to: visibleRootURL.appendingPathComponent("VisibleNonMatching.swift"),
                options: []
            )

            for moduleIndex in 0 ..< moduleCount {
                for layerIndex in 0 ..< layerCount {
                    let layerURL = worktreeRootURL
                        .appendingPathComponent(String(format: "Module-%02d", moduleIndex), isDirectory: true)
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(String(format: "Layer-%02d", layerIndex), isDirectory: true)
                    try FileManager.default.createDirectory(at: layerURL, withIntermediateDirectories: true)
                    for fileIndex in 0 ..< filesPerLayer {
                        let fileName = if moduleIndex == 0, layerIndex == 0, fileIndex == 0 {
                            "FirstScopedNeedle.swift"
                        } else {
                            String(format: "File-%02d.swift", fileIndex)
                        }
                        try fixtureContents.write(to: layerURL.appendingPathComponent(fileName), options: [])
                    }
                }
            }

            return Self(
                containerURL: containerURL,
                visibleRootURL: visibleRootURL,
                worktreeRootURL: worktreeRootURL
            )
        }

        func writeMutationFile(relativePath: String) throws -> URL {
            let url = worktreeRootURL.appendingPathComponent(relativePath)
            try Self.fixtureContents.write(to: url, options: [])
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: containerURL)
        }

        private static let fixtureContents = Data(
            "// RepoPrompt CE file-search benchmark fixture\nlet benchmarkValue = 1234567890\n".utf8
        )
    }

    struct WorkspaceFileSearchIndexBenchmarkCounters: Equatable {
        typealias FallbackReason = WorkspaceFileContextStore.RootCatalogShardFallbackReason

        let rootID: UUID?
        let lifetimeID: UUID?
        let topologyGeneration: UInt64?
        let crawl: Int
        let appliedGeneration: Int
        let shardBuild: Int
        let patch: Int
        let authoritative: Int
        let pathIndexBuild: Int
        let overlayPathIndexBuild: Int
        let fallback: Int
        let fallbackReasonDeltas: [FallbackReason: Int]
        let catalogRebuild: Int
        let catalogInvalidation: Int

        var fallbackReasonDeltaSum: Int {
            fallbackReasonDeltas.values.reduce(0, +)
        }

        var fallbackReasonDeltasAreNonnegative: Bool {
            fallbackReasonDeltas.values.allSatisfy { $0 >= 0 }
        }

        func fallbackDiagnosticDescription() -> String {
            let reasons = FallbackReason.allCases.compactMap { reason -> String? in
                guard let count = fallbackReasonDeltas[reason], count != 0 else { return nil }
                return "\(reason.rawValue)=\(count)"
            }.joined(separator: ", ")
            let renderedTopologyGeneration = topologyGeneration.map(String.init) ?? "none"
            return "rootID=\(rootID?.uuidString ?? "none"), lifetimeID=\(lifetimeID?.uuidString ?? "none"), "
                + "topology generation=\(renderedTopologyGeneration); fallback Δ=\(fallback); reasons=[\(reasons)]; "
                + "crawl=\(crawl) shard=\(shardBuild) patch=\(patch) authoritative=\(authoritative) "
                + "full=\(pathIndexBuild) overlay=\(overlayPathIndexBuild)"
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkCounterMark {
        typealias FallbackReason = WorkspaceFileContextStore.RootCatalogShardFallbackReason

        let rootID: UUID?
        let lifetimeID: UUID?
        let topologyGeneration: UInt64?
        let crawl: Int
        let appliedGeneration: UInt64
        let shardBuild: Int
        let patch: Int
        let authoritative: Int
        let pathIndexBuild: Int
        let overlayPathIndexBuild: Int
        let fallback: Int
        let fallbackReasonCounts: [FallbackReason: Int]
        let catalogRebuild: Int
        let catalogInvalidation: Int

        static func capture(store: WorkspaceFileContextStore, rootID: UUID? = nil) async -> Self {
            let rootSnapshots = await store.readSearchRootDiagnosticsSnapshot()
            let work = await store.storeWorkDiagnosticsSnapshot()
            let rootSnapshot = rootID.flatMap { id in rootSnapshots.first { $0.rootID == id } }
            let shardSnapshot = rootID.flatMap { id in
                work.rootCatalogShards.roots.first { $0.rootID == id }
            }
            return Self(
                rootID: shardSnapshot?.rootID ?? rootID,
                lifetimeID: shardSnapshot?.lifetimeID,
                topologyGeneration: shardSnapshot?.publishedTopologyGeneration,
                crawl: rootSnapshot?.crawlCount ?? 0,
                appliedGeneration: rootSnapshot?.producedAppliedIndexGeneration ?? 0,
                shardBuild: shardSnapshot?.buildCount ?? 0,
                patch: shardSnapshot?.patchCount ?? 0,
                authoritative: shardSnapshot?.authoritativeRebuildCount ?? 0,
                pathIndexBuild: shardSnapshot?.pathIndexBuildCount ?? 0,
                overlayPathIndexBuild: shardSnapshot?.overlayPathIndexBuildCount ?? 0,
                fallback: shardSnapshot?.fallbackCount ?? 0,
                fallbackReasonCounts: shardSnapshot?.fallbackReasonCounts ?? [:],
                catalogRebuild: work.catalogRebuild.rebuildCount,
                catalogInvalidation: work.invalidations.count
            )
        }

        func delta(from before: Self) -> WorkspaceFileSearchIndexBenchmarkCounters {
            let fallbackReasonDeltas = Dictionary(uniqueKeysWithValues: FallbackReason.allCases.map { reason in
                (reason, (fallbackReasonCounts[reason] ?? 0) - (before.fallbackReasonCounts[reason] ?? 0))
            })
            return WorkspaceFileSearchIndexBenchmarkCounters(
                rootID: rootID ?? before.rootID,
                lifetimeID: lifetimeID ?? before.lifetimeID,
                topologyGeneration: topologyGeneration ?? before.topologyGeneration,
                crawl: crawl - before.crawl,
                appliedGeneration: Int(appliedGeneration) - Int(before.appliedGeneration),
                shardBuild: shardBuild - before.shardBuild,
                patch: patch - before.patch,
                authoritative: authoritative - before.authoritative,
                pathIndexBuild: pathIndexBuild - before.pathIndexBuild,
                overlayPathIndexBuild: overlayPathIndexBuild - before.overlayPathIndexBuild,
                fallback: fallback - before.fallback,
                fallbackReasonDeltas: fallbackReasonDeltas,
                catalogRebuild: catalogRebuild - before.catalogRebuild,
                catalogInvalidation: catalogInvalidation - before.catalogInvalidation
            )
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkSample {
        let ordinal: Int
        let phase: String
        let totalWallMilliseconds: Double
        let preSearchMilliseconds: Double
        let searchMilliseconds: Double
        let counters: WorkspaceFileSearchIndexBenchmarkCounters
        let phases: WorkspaceFileSearchPhaseSnapshot
    }

    struct WorkspaceFileSearchIndexBenchmarkAggregate {
        let scenario: String
        let warmup: WorkspaceFileSearchIndexBenchmarkSample
        let measured: [WorkspaceFileSearchIndexBenchmarkSample]
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let stabilityRatio: Double
        let isStable: Bool

        init(
            scenario: String,
            warmup: WorkspaceFileSearchIndexBenchmarkSample,
            measured: [WorkspaceFileSearchIndexBenchmarkSample]
        ) {
            precondition(measured.count == 5)
            self.scenario = scenario
            self.warmup = warmup
            self.measured = measured
            let values = measured.map(\.totalWallMilliseconds)
            medianMilliseconds = Self.median(values)
            p95Milliseconds = Self.nearestRankP95(values)
            stabilityRatio = medianMilliseconds > 0
                ? (p95Milliseconds - medianMilliseconds) / medianMilliseconds
                : .infinity
            isStable = stabilityRatio <= 0.20
        }

        var rawMilliseconds: [Double] {
            measured.map(\.totalWallMilliseconds)
        }

        private static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let midpoint = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[midpoint - 1] + sorted[midpoint]) / 2
            }
            return sorted[midpoint]
        }

        private static func nearestRankP95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
            return sorted[min(sorted.count - 1, rank - 1)]
        }
    }

    struct WorkspaceFileSearchIndexBenchmarkEnvironment {
        let runLabel: String
        let attribution: String
        let commit: String
        let recordedAt: String
        let macOS: String
        let hardware: String
        let logicalCores: Int
        let memoryBytes: UInt64
        let swiftVersion: String
        let buildConfiguration: String
        let conductorState: String

        static func capture() -> Self {
            let environment = ProcessInfo.processInfo.environment
            let configuration = WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration.values()
            return Self(
                runLabel: environment["RP_CE_FILE_SEARCH_INDEX_RUN_LABEL"] ?? configuration["runLabel"] ?? "manual",
                attribution: environment["RP_CE_FILE_SEARCH_INDEX_ATTRIBUTION"] ?? configuration["attribution"] ?? "unspecified",
                commit: environment["RP_CE_FILE_SEARCH_INDEX_COMMIT"] ?? configuration["commit"] ?? "unspecified",
                recordedAt: ISO8601DateFormatter().string(from: Date()),
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                hardware: sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "unknown",
                logicalCores: ProcessInfo.processInfo.activeProcessorCount,
                memoryBytes: ProcessInfo.processInfo.physicalMemory,
                swiftVersion: environment["RP_CE_FILE_SEARCH_INDEX_SWIFT_VERSION"] ?? configuration["swiftVersion"] ?? "unspecified",
                buildConfiguration: "DEBUG SwiftPM",
                conductorState: environment["RP_CE_FILE_SEARCH_INDEX_CONDUCTOR_STATE"] ?? configuration["conductorState"] ?? "coordinated daemon"
            )
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return String(cString: value)
        }
    }

    struct WorkspaceFileSearchIndexSortDiagnostic {
        let probe: WorkspaceCatalogSortAttributionProbe
        let storeStateUnchanged: Bool
    }

    struct WorkspaceFileSearchIndexSortDecisionCriterion {
        let name: String
        let passed: Bool
        let detail: String
    }

    struct WorkspaceFileSearchIndexSortDecision {
        let status: String
        let criteria: [WorkspaceFileSearchIndexSortDecisionCriterion]
    }

    struct WorkspaceFileSearchIndexBenchmarkRun {
        let environment: WorkspaceFileSearchIndexBenchmarkEnvironment
        let coldWorktree: WorkspaceFileSearchIndexBenchmarkAggregate
        let incrementalRebuild: WorkspaceFileSearchIndexBenchmarkAggregate
        let sortDiagnostic: WorkspaceFileSearchIndexSortDiagnostic?

        static var reportURLFromEnvironment: URL? {
            let configuration = WorkspaceFileSearchIndexBenchmarkRuntimeConfiguration.values()
            let path = ProcessInfo.processInfo.environment["RP_CE_FILE_SEARCH_INDEX_REPORT_PATH"]
                ?? configuration["reportPath"]
            guard let path, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }

        func consoleReport() throws -> String {
            let json = try jsonString()
            return [
                "REPOPROMPT_CE_FILE_SEARCH_INDEX_BENCHMARK_BEGIN",
                markdownBlock(),
                "REPOPROMPT_CE_FILE_SEARCH_INDEX_BENCHMARK_JSON=\(json)",
                "REPOPROMPT_CE_FILE_SEARCH_INDEX_BENCHMARK_END"
            ].joined(separator: "\n")
        }

        func appendMarkdown(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n\n" + markdownBlock() + "\n").utf8))
            try handle.synchronize()
        }

        private func markdownBlock() -> String {
            var lines: [String] = [
                "## Run `\(environment.runLabel)`",
                "",
                "Recorded: \(environment.recordedAt)  ",
                "Commit: `\(environment.commit)`  ",
                "Attribution: \(environment.attribution)",
                "",
                "| Environment | macOS | Hardware/CPU | Logical cores | Memory GiB | Swift | Build configuration | Conductor state |",
                "| --- | --- | --- | ---: | ---: | --- | --- | --- |",
                "| env-001 | \(environment.macOS) | \(environment.hardware) | \(environment.logicalCores) | \(formatGiB(environment.memoryBytes)) | \(environment.swiftVersion) | \(environment.buildConfiguration) | \(environment.conductorState) |",
                "",
                "| Scenario | Raw measured samples ms | Median ms | Nearest-rank p95 ms | Stability |",
                "| --- | --- | ---: | ---: | --- |",
                aggregateRow(coldWorktree),
                aggregateRow(incrementalRebuild),
                "",
                "| Scenario | Crawl Δ | Applied generation Δ | Shard build Δ | Patch Δ | Authoritative Δ | Full path-index build Δ | Overlay build Δ | Fallback Δ | Catalog rebuild Δ | Catalog invalidation Δ |",
                "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
                counterRow(scenario: coldWorktree.scenario, counters: coldWorktree.measured.map(\.counters)),
                counterRow(scenario: incrementalRebuild.scenario, counters: incrementalRebuild.measured.map(\.counters)),
                "",
                "| Scenario | Phase | Sample | Total ms | Materialize/publish ms | Ready search ms |",
                "| --- | --- | ---: | ---: | ---: | ---: |",
                sampleRows(coldWorktree).joined(separator: "\n"),
                sampleRows(incrementalRebuild).joined(separator: "\n")
            ]
            lines.append(contentsOf: [
                "",
                "| Scenario | Phase | Sample | Ready ms | Readiness/freshness preamble ms | First catalog access ms | FileSearchActor ms | Orchestration residual ms | Reconciliation Δ ms |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                topLevelPhaseRows(coldWorktree).joined(separator: "\n"),
                topLevelPhaseRows(incrementalRebuild).joined(separator: "\n"),
                "",
                "| Scenario | Phase | Sample | Catalog total ms | Filter ms | Sort ms | File sort ms | Folder sort ms | Sort residual ms | Sort reconciliation Δ ms | Sort invocations | File inputs | Folder inputs | Entry materialization ms | Path-index key ms | Path-index construction ms | Composition/cache residual ms | Rebuilds | Files | Roots |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                catalogPhaseRows(coldWorktree).joined(separator: "\n"),
                catalogPhaseRows(incrementalRebuild).joined(separator: "\n")
            ])
            lines.append(contentsOf: [
                "",
                "| Scenario | Phase | Sample | Descriptor ms | Filter ms | Sort/input ms | Batch/enqueue ms | Drain-to-hit ms | Post-hit ms | Actor residual ms |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                actorPhaseRows(coldWorktree).joined(separator: "\n"),
                actorPhaseRows(incrementalRebuild).joined(separator: "\n"),
                "",
                "| Scenario | Phase | Sample | Source | Descriptors | Admitted | Sort input | Batches | Initially enqueued | Drained to hit | Entries examined | Returned hit ordinal | Returned prefix |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                actorCountRows(coldWorktree).joined(separator: "\n"),
                actorCountRows(incrementalRebuild).joined(separator: "\n")
            ])
            if let sortDiagnostic {
                lines.append(contentsOf: sortDiagnosticMarkdown(sortDiagnostic))
            }
            lines.append(contentsOf: [
                "",
                "<details><summary>Machine-readable paired result</summary>",
                "",
                "```json",
                (try? jsonString()) ?? "{}",
                "```",
                "</details>"
            ])
            if sortDiagnostic != nil {
                lines.append(contentsOf: sortDecisionMarkdown(sortAttributionDecision()))
            }
            return lines.joined(separator: "\n")
        }

        private func jsonString() throws -> String {
            var payload: [String: Any] = [
                "runLabel": environment.runLabel,
                "attribution": environment.attribution,
                "commit": environment.commit,
                "recordedAt": environment.recordedAt,
                "environment": [
                    "macOS": environment.macOS,
                    "hardware": environment.hardware,
                    "logicalCores": environment.logicalCores,
                    "memoryBytes": environment.memoryBytes,
                    "swiftVersion": environment.swiftVersion,
                    "buildConfiguration": environment.buildConfiguration,
                    "conductorState": environment.conductorState
                ],
                "scenarios": [aggregateDictionary(coldWorktree), aggregateDictionary(incrementalRebuild)],
                "correctnessStatus": "passed"
            ]
            if let sortDiagnostic {
                payload["sortDiagnostic"] = sortDiagnosticDictionary(sortDiagnostic)
                payload["sortAttributionDecision"] = sortDecisionDictionary(sortAttributionDecision())
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        private func aggregateDictionary(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String: Any] {
            [
                "scenario": aggregate.scenario,
                "warmupSampleCount": 1,
                "measuredSampleCount": aggregate.measured.count,
                "rawMeasuredMilliseconds": aggregate.rawMilliseconds,
                "medianMilliseconds": aggregate.medianMilliseconds,
                "nearestRankP95Milliseconds": aggregate.p95Milliseconds,
                "stabilityRatio": aggregate.stabilityRatio,
                "stable": aggregate.isStable,
                "warmup": sampleDictionary(aggregate.warmup),
                "measured": aggregate.measured.map(sampleDictionary)
            ]
        }

        private func sampleDictionary(_ sample: WorkspaceFileSearchIndexBenchmarkSample) -> [String: Any] {
            [
                "ordinal": sample.ordinal,
                "phase": sample.phase,
                "totalWallMilliseconds": sample.totalWallMilliseconds,
                "materializeOrPublishMilliseconds": sample.preSearchMilliseconds,
                "readySearchMilliseconds": sample.searchMilliseconds,
                "counters": counterDictionary(sample.counters),
                "phaseAccounting": phaseDictionary(sample.phases)
            ]
        }

        private func phaseDictionary(_ phases: WorkspaceFileSearchPhaseSnapshot) -> [String: Any] {
            [
                "status": phases.status.rawValue,
                "topLevel": [
                    "readySearchMicroseconds": phases.topLevel.readySearchMicroseconds,
                    "readinessFreshnessPreambleMicroseconds": phases.topLevel.readinessFreshnessPreambleMicroseconds,
                    "firstCatalogAccessMicroseconds": phases.topLevel.firstCatalogAccessMicroseconds,
                    "fileSearchActorMicroseconds": phases.topLevel.fileSearchActorMicroseconds,
                    "residualOrchestrationMicroseconds": phases.topLevel.residualOrchestrationMicroseconds,
                    "reconciliationDeltaMicroseconds": phases.topLevel.reconciliationDeltaMicroseconds
                ],
                "catalog": [
                    "rebuildCount": phases.catalog.rebuildCount,
                    "filterMicroseconds": phases.catalog.filterMicroseconds,
                    "sortMicroseconds": phases.catalog.sortMicroseconds,
                    "fileSortMicroseconds": phases.catalog.fileSortMicroseconds,
                    "folderSortMicroseconds": phases.catalog.folderSortMicroseconds,
                    "sortResidualMicroseconds": phases.catalog.sortResidualMicroseconds,
                    "sortReconciliationDeltaMicroseconds": phases.catalog.sortReconciliationDeltaMicroseconds,
                    "sortInvocationCount": phases.catalog.sortInvocationCount,
                    "sortFileInputCount": phases.catalog.sortFileInputCount,
                    "sortFolderInputCount": phases.catalog.sortFolderInputCount,
                    "materializationMicroseconds": phases.catalog.materializationMicroseconds,
                    "pathIndexKeyMicroseconds": phases.catalog.pathIndexKeyMicroseconds,
                    "pathIndexConstructionMicroseconds": phases.catalog.pathIndexConstructionMicroseconds,
                    "compositionCacheResidualMicroseconds": phases.catalog.compositionCacheResidualMicroseconds,
                    "totalMicroseconds": phases.catalog.totalMicroseconds,
                    "fileCount": phases.catalog.fileCount,
                    "rootCount": phases.catalog.rootCount
                ],
                "fileSearchActor": [
                    "descriptorMicroseconds": phases.fileActor.descriptorMicroseconds,
                    "filterMicroseconds": phases.fileActor.filterMicroseconds,
                    "sortAndInputMicroseconds": phases.fileActor.sortAndInputMicroseconds,
                    "batchConstructionAndInitialEnqueueMicroseconds": phases.fileActor.batchConstructionAndInitialEnqueueMicroseconds,
                    "deterministicDrainToHitMicroseconds": phases.fileActor.deterministicDrainToHitMicroseconds,
                    "postHitResidualMicroseconds": phases.fileActor.postHitResidualMicroseconds,
                    "residualMicroseconds": phases.fileActor.residualMicroseconds
                ],
                "deterministicCounts": [
                    "sourceFileCount": phases.counts.sourceFileCount,
                    "descriptorsBuilt": phases.counts.descriptorsBuilt,
                    "admittedFileCount": phases.counts.admittedFileCount,
                    "sortInputCount": phases.counts.sortInputCount,
                    "totalBatchCount": phases.counts.totalBatchCount,
                    "initiallyEnqueuedBatchCount": phases.counts.initiallyEnqueuedBatchCount,
                    "deterministicallyDrainedBatchCount": phases.counts.deterministicallyDrainedBatchCount,
                    "entriesExaminedByDrainedBatches": phases.counts.entriesExaminedByDrainedBatches,
                    "returnedHitOrdinal": phases.counts.returnedHitOrdinal,
                    "returnedHitPrefixLength": phases.counts.returnedHitPrefixLength
                ]
            ]
        }

        private func sortDiagnosticDictionary(
            _ diagnostic: WorkspaceFileSearchIndexSortDiagnostic
        ) -> [String: Any] {
            let probe = diagnostic.probe
            return [
                "status": probe.status.rawValue,
                "sourceFileCount": probe.sourceFileCount,
                "sourceFolderCount": probe.sourceFolderCount,
                "measuredSampleCount": probe.samples.count,
                "storeStateUnchanged": diagnostic.storeStateUnchanged,
                "directAndProjectedOrdersMatch": probe.directAndProjectedOrdersMatch,
                "firstMismatchIndex": probe.firstMismatchIndex.map { $0 as Any } ?? NSNull(),
                "samples": probe.samples.enumerated().map { index, sample in
                    [
                        "ordinal": index + 1,
                        "directFileSortNanoseconds": sample.directFileSortNanoseconds,
                        "directFolderSortNanoseconds": sample.directFolderSortNanoseconds,
                        "keyDerivationNanoseconds": sample.keyDerivationNanoseconds,
                        "projectionAssemblyNanoseconds": sample.projectionAssemblyNanoseconds,
                        "projectedFileSortNanoseconds": sample.projectedFileSortNanoseconds,
                        "projectionMappingNanoseconds": sample.projectionMappingNanoseconds,
                        "directFileComparatorCalls": sample.directFileComparatorCalls,
                        "projectedFileComparatorCalls": sample.projectedFileComparatorCalls,
                        "folderComparatorCalls": sample.folderComparatorCalls,
                        "directAndProjectedOrdersMatch": sample.directAndProjectedOrdersMatch,
                        "firstMismatchIndex": sample.firstMismatchIndex.map { $0 as Any } ?? NSNull()
                    ] as [String: Any]
                },
                "medians": [
                    "directFileSortNanoseconds": median(probe.samples.map(\.directFileSortNanoseconds)),
                    "directFolderSortNanoseconds": median(probe.samples.map(\.directFolderSortNanoseconds)),
                    "keyDerivationNanoseconds": median(probe.samples.map(\.keyDerivationNanoseconds)),
                    "projectionAssemblyNanoseconds": median(probe.samples.map(\.projectionAssemblyNanoseconds)),
                    "projectedFileSortNanoseconds": median(probe.samples.map(\.projectedFileSortNanoseconds)),
                    "projectionMappingNanoseconds": median(probe.samples.map(\.projectionMappingNanoseconds)),
                    "directFileComparatorCalls": median(probe.samples.map(\.directFileComparatorCalls)),
                    "projectedFileComparatorCalls": median(probe.samples.map(\.projectedFileComparatorCalls)),
                    "folderComparatorCalls": median(probe.samples.map(\.folderComparatorCalls))
                ]
            ]
        }

        private func sortDecisionDictionary(_ decision: WorkspaceFileSearchIndexSortDecision) -> [String: Any] {
            [
                "status": decision.status,
                "criteria": decision.criteria.map {
                    [
                        "name": $0.name,
                        "passed": $0.passed,
                        "detail": $0.detail
                    ]
                }
            ]
        }

        private func sortAttributionDecision() -> WorkspaceFileSearchIndexSortDecision {
            guard let sortDiagnostic else {
                return WorkspaceFileSearchIndexSortDecision(status: "attribution unresolved", criteria: [])
            }
            let probe = sortDiagnostic.probe
            let coldSamples = coldWorktree.measured
            let incrementalSamples = incrementalRebuild.measured

            let oneInvocation = coldSamples.allSatisfy { $0.phases.catalog.sortInvocationCount == 1 }
            let exactInputs = coldSamples.allSatisfy {
                $0.phases.catalog.sortFileInputCount == WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount
                    && $0.phases.catalog.sortFolderInputCount == WorkspaceFileSearchIndexBenchmarkFixture.folderCount
            }
            let nestedReconciliation = coldSamples.allSatisfy { sample in
                let phase = sample.phases.catalog
                let outer = Int64(phase.sortMicroseconds)
                let children = Int64(phase.fileSortMicroseconds)
                    + Int64(phase.folderSortMicroseconds)
                    + Int64(phase.sortResidualMicroseconds)
                let tolerance = max(1000, outer / 100)
                return abs(outer - children) <= tolerance
                    && abs(phase.sortReconciliationDeltaMicroseconds) <= tolerance
            }
            let parentReconciliation = (coldSamples + incrementalSamples).allSatisfy { sample in
                let phase = sample.phases.catalog
                let catalogChildren = phase.filterMicroseconds
                    + phase.sortMicroseconds
                    + phase.materializationMicroseconds
                    + phase.pathIndexKeyMicroseconds
                    + phase.pathIndexConstructionMicroseconds
                    + phase.compositionCacheResidualMicroseconds
                let catalogTolerance = max(1000, phase.totalMicroseconds / 100)
                return catalogChildren <= phase.totalMicroseconds + catalogTolerance
                    && abs(sample.phases.topLevel.reconciliationDeltaMicroseconds) <= 1000
            }
            let parity = probe.status == .completed
                && probe.samples.count == 3
                && probe.directAndProjectedOrdersMatch
                && probe.samples.allSatisfy(\.directAndProjectedOrdersMatch)
            let deterministicComparatorCounts = probe.samples.count == 3
                && Set(probe.samples.map(\.directFileComparatorCalls)).count == 1
                && Set(probe.samples.map(\.projectedFileComparatorCalls)).count == 1
                && Set(probe.samples.map(\.folderComparatorCalls)).count == 1
                && probe.samples.allSatisfy {
                    $0.directFileComparatorCalls > 0
                        && $0.projectedFileComparatorCalls > 0
                        && $0.folderComparatorCalls > 0
                }
            let productionFileMedian = median(coldSamples.map(\.phases.catalog.fileSortMicroseconds))
            let productionFolderMedian = median(coldSamples.map(\.phases.catalog.folderSortMicroseconds))
            let probeFileMedian = median(probe.samples.map(\.directFileSortNanoseconds))
            let probeFolderMedian = median(probe.samples.map(\.directFolderSortNanoseconds))
            let sameDominantComponent = (productionFileMedian >= productionFolderMedian)
                == (probeFileMedian >= probeFolderMedian)
            let fileStability = stabilityRatio(probe.samples.map(\.directFileSortNanoseconds))
            let folderStability = stabilityRatio(probe.samples.map(\.directFolderSortNanoseconds))
            let stableProbeSorts = fileStability <= 0.20 && folderStability <= 0.20
            let exactWorkCounters = coldSamples.allSatisfy {
                counterVector($0.counters) == [1, 0, 1, 0, 1, 1, 0, 0, 1, 1]
            } && incrementalSamples.allSatisfy {
                counterVector($0.counters) == [0, 1, 1, 1, 0, 0, 1, 0, 1, 1]
            }
            let overheadGuards = coldWorktree.p95Milliseconds <= 4223.831
                && incrementalRebuild.p95Milliseconds <= 257.452
                && coldWorktree.stabilityRatio <= 0.20
                && incrementalRebuild.stabilityRatio <= 0.20

            let criteria = [
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "one authoritative sort invocation per cold sample",
                    passed: oneInvocation,
                    detail: coldSamples.map { String($0.phases.catalog.sortInvocationCount) }.joined(separator: "/")
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "exact production sort input counts",
                    passed: exactInputs,
                    detail: "expected \(WorkspaceFileSearchIndexBenchmarkFixture.seedFileCount) files and \(WorkspaceFileSearchIndexBenchmarkFixture.folderCount) folders"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "nested sort reconciliation",
                    passed: nestedReconciliation,
                    detail: "tolerance max(1 ms, 1% of aggregate sort)"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "catalog-parent and ready-search reconciliation",
                    passed: parentReconciliation,
                    detail: "existing parent and top-level guards"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "direct/projected order parity",
                    passed: parity,
                    detail: "first mismatch \(probe.firstMismatchIndex.map(String.init) ?? "none")"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "deterministic comparator counts",
                    passed: deterministicComparatorCounts,
                    detail: "direct/projected/folder counts stable across three samples"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "production/probe dominant component agreement",
                    passed: sameDominantComponent,
                    detail: "production medians file/folder \(productionFileMedian)/\(productionFolderMedian) µs; probe \(probeFileMedian)/\(probeFolderMedian) ns"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "direct sort probe stability",
                    passed: stableProbeSorts,
                    detail: "file \(formatPercent(fileStability)); folder \(formatPercent(folderStability))"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "probe store state unchanged",
                    passed: sortDiagnostic.storeStateUnchanged,
                    detail: "no shard, generation, cache, invalidation, or rebuild mutation"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "exact primary work counters",
                    passed: exactWorkCounters,
                    detail: "cold and incremental vectors preserved"
                ),
                WorkspaceFileSearchIndexSortDecisionCriterion(
                    name: "primary overhead guards",
                    passed: overheadGuards,
                    detail: "cold p95 \(formatMS(coldWorktree.p95Milliseconds)) ms; incremental p95 \(formatMS(incrementalRebuild.p95Milliseconds)) ms"
                )
            ]
            let status = criteria.allSatisfy(\.passed)
                ? "attribution trustworthy"
                : "attribution unresolved"
            return WorkspaceFileSearchIndexSortDecision(status: status, criteria: criteria)
        }

        private func counterVector(_ counters: WorkspaceFileSearchIndexBenchmarkCounters) -> [Int] {
            [
                counters.crawl,
                counters.appliedGeneration,
                counters.shardBuild,
                counters.patch,
                counters.authoritative,
                counters.pathIndexBuild,
                counters.overlayPathIndexBuild,
                counters.fallback,
                counters.catalogRebuild,
                counters.catalogInvalidation
            ]
        }

        private func counterDictionary(_ counters: WorkspaceFileSearchIndexBenchmarkCounters) -> [String: Any] {
            [
                "crawlDelta": counters.crawl,
                "appliedGenerationDelta": counters.appliedGeneration,
                "shardBuildDelta": counters.shardBuild,
                "patchDelta": counters.patch,
                "authoritativeDelta": counters.authoritative,
                "fullPathIndexBuildDelta": counters.pathIndexBuild,
                "overlayPathIndexBuildDelta": counters.overlayPathIndexBuild,
                "fallbackDelta": counters.fallback,
                "catalogRebuildDelta": counters.catalogRebuild,
                "catalogInvalidationDelta": counters.catalogInvalidation
            ]
        }

        private func sortDiagnosticMarkdown(
            _ diagnostic: WorkspaceFileSearchIndexSortDiagnostic
        ) -> [String] {
            let probe = diagnostic.probe
            var lines = [
                "",
                "## Sort attribution diagnostic probe",
                "",
                "Status: \(probe.status.rawValue)  ",
                "Source files/folders: \(probe.sourceFileCount)/\(probe.sourceFolderCount)  ",
                "Store state unchanged: \(diagnostic.storeStateUnchanged ? "yes" : "no")  ",
                "Direct/projected parity: \(probe.directAndProjectedOrdersMatch ? "match" : "mismatch")  ",
                "First mismatch index: \(probe.firstMismatchIndex.map(String.init) ?? "none")",
                "",
                "| Sample | Direct file sort ms | Direct folder sort ms | Key derivation ms | Projection assembly ms | Projected file sort ms | Projection mapping ms | Direct comparator calls | Projected comparator calls | Folder comparator calls | Parity | First mismatch |",
                "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |"
            ]
            lines.append(contentsOf: probe.samples.enumerated().map { index, sample in
                "| \(index + 1) | \(formatNanoseconds(sample.directFileSortNanoseconds)) | \(formatNanoseconds(sample.directFolderSortNanoseconds)) | \(formatNanoseconds(sample.keyDerivationNanoseconds)) | \(formatNanoseconds(sample.projectionAssemblyNanoseconds)) | \(formatNanoseconds(sample.projectedFileSortNanoseconds)) | \(formatNanoseconds(sample.projectionMappingNanoseconds)) | \(sample.directFileComparatorCalls) | \(sample.projectedFileComparatorCalls) | \(sample.folderComparatorCalls) | \(sample.directAndProjectedOrdersMatch ? "match" : "mismatch") | \(sample.firstMismatchIndex.map(String.init) ?? "none") |"
            })
            lines.append(
                "| median | \(formatNanoseconds(median(probe.samples.map(\.directFileSortNanoseconds)))) | \(formatNanoseconds(median(probe.samples.map(\.directFolderSortNanoseconds)))) | \(formatNanoseconds(median(probe.samples.map(\.keyDerivationNanoseconds)))) | \(formatNanoseconds(median(probe.samples.map(\.projectionAssemblyNanoseconds)))) | \(formatNanoseconds(median(probe.samples.map(\.projectedFileSortNanoseconds)))) | \(formatNanoseconds(median(probe.samples.map(\.projectionMappingNanoseconds)))) | \(median(probe.samples.map(\.directFileComparatorCalls))) | \(median(probe.samples.map(\.projectedFileComparatorCalls))) | \(median(probe.samples.map(\.folderComparatorCalls))) | \(probe.directAndProjectedOrdersMatch ? "match" : "mismatch") | \(probe.firstMismatchIndex.map(String.init) ?? "none") |"
            )
            return lines
        }

        private func sortDecisionMarkdown(_ decision: WorkspaceFileSearchIndexSortDecision) -> [String] {
            var lines = [
                "",
                "## Sort attribution decision — \(decision.status)",
                "",
                "| Criterion | Result | Detail |",
                "| --- | --- | --- |"
            ]
            lines.append(contentsOf: decision.criteria.map {
                let detail = $0.detail.replacingOccurrences(of: "|", with: "\\|")
                return "| \($0.name) | \($0.passed ? "pass" : "fail") | \(detail) |"
            })
            return lines
        }

        private func aggregateRow(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> String {
            let stability = aggregate.isStable ? "stable" : "unstable"
            return "| \(aggregate.scenario) | \(formatValues(aggregate.rawMilliseconds)) | \(formatMS(aggregate.medianMilliseconds)) | \(formatMS(aggregate.p95Milliseconds)) | \(stability) (\(formatPercent(aggregate.stabilityRatio))) |"
        }

        private func counterRow(
            scenario: String,
            counters: [WorkspaceFileSearchIndexBenchmarkCounters]
        ) -> String {
            "| \(scenario) | \(counterValues(counters, \.crawl)) | \(counterValues(counters, \.appliedGeneration)) | \(counterValues(counters, \.shardBuild)) | \(counterValues(counters, \.patch)) | \(counterValues(counters, \.authoritative)) | \(counterValues(counters, \.pathIndexBuild)) | \(counterValues(counters, \.overlayPathIndexBuild)) | \(counterValues(counters, \.fallback)) | \(counterValues(counters, \.catalogRebuild)) | \(counterValues(counters, \.catalogInvalidation)) |"
        }

        private func counterValues(
            _ counters: [WorkspaceFileSearchIndexBenchmarkCounters],
            _ keyPath: KeyPath<WorkspaceFileSearchIndexBenchmarkCounters, Int>
        ) -> String {
            counters.map { String($0[keyPath: keyPath]) }.joined(separator: "/")
        }

        private func sampleRows(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String] {
            ([aggregate.warmup] + aggregate.measured).map { sample in
                "| \(aggregate.scenario) | \(sample.phase) | \(sample.ordinal) | \(formatMS(sample.totalWallMilliseconds)) | \(formatMS(sample.preSearchMilliseconds)) | \(formatMS(sample.searchMilliseconds)) |"
            }
        }

        private func topLevelPhaseRows(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String] {
            allSamples(aggregate).map { sample in
                let phase = sample.phases.topLevel
                return "| \(aggregate.scenario) | \(sample.phase) | \(sample.ordinal) | \(formatMicroseconds(phase.readySearchMicroseconds)) | \(formatMicroseconds(phase.readinessFreshnessPreambleMicroseconds)) | \(formatMicroseconds(phase.firstCatalogAccessMicroseconds)) | \(formatMicroseconds(phase.fileSearchActorMicroseconds)) | \(formatSignedMicroseconds(phase.residualOrchestrationMicroseconds)) | \(formatSignedMicroseconds(phase.reconciliationDeltaMicroseconds)) |"
            }
        }

        private func catalogPhaseRows(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String] {
            allSamples(aggregate).map { sample in
                let phase = sample.phases.catalog
                return "| \(aggregate.scenario) | \(sample.phase) | \(sample.ordinal) | \(formatMicroseconds(phase.totalMicroseconds)) | \(formatMicroseconds(phase.filterMicroseconds)) | \(formatMicroseconds(phase.sortMicroseconds)) | \(formatMicroseconds(phase.fileSortMicroseconds)) | \(formatMicroseconds(phase.folderSortMicroseconds)) | \(formatMicroseconds(phase.sortResidualMicroseconds)) | \(formatSignedMicroseconds(phase.sortReconciliationDeltaMicroseconds)) | \(phase.sortInvocationCount) | \(phase.sortFileInputCount) | \(phase.sortFolderInputCount) | \(formatMicroseconds(phase.materializationMicroseconds)) | \(formatMicroseconds(phase.pathIndexKeyMicroseconds)) | \(formatMicroseconds(phase.pathIndexConstructionMicroseconds)) | \(formatMicroseconds(phase.compositionCacheResidualMicroseconds)) | \(phase.rebuildCount) | \(phase.fileCount) | \(phase.rootCount) |"
            }
        }

        private func actorPhaseRows(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String] {
            allSamples(aggregate).map { sample in
                let phase = sample.phases.fileActor
                return "| \(aggregate.scenario) | \(sample.phase) | \(sample.ordinal) | \(formatMicroseconds(phase.descriptorMicroseconds)) | \(formatMicroseconds(phase.filterMicroseconds)) | \(formatMicroseconds(phase.sortAndInputMicroseconds)) | \(formatMicroseconds(phase.batchConstructionAndInitialEnqueueMicroseconds)) | \(formatMicroseconds(phase.deterministicDrainToHitMicroseconds)) | \(formatMicroseconds(phase.postHitResidualMicroseconds)) | \(formatSignedMicroseconds(phase.residualMicroseconds)) |"
            }
        }

        private func actorCountRows(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String] {
            allSamples(aggregate).map { sample in
                let counts = sample.phases.counts
                return "| \(aggregate.scenario) | \(sample.phase) | \(sample.ordinal) | \(counts.sourceFileCount) | \(counts.descriptorsBuilt) | \(counts.admittedFileCount) | \(counts.sortInputCount) | \(counts.totalBatchCount) | \(counts.initiallyEnqueuedBatchCount) | \(counts.deterministicallyDrainedBatchCount) | \(counts.entriesExaminedByDrainedBatches) | \(counts.returnedHitOrdinal) | \(counts.returnedHitPrefixLength) |"
            }
        }

        private func allSamples(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [WorkspaceFileSearchIndexBenchmarkSample] {
            [aggregate.warmup] + aggregate.measured
        }

        private func median(_ values: [UInt64]) -> UInt64 {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[sorted.count / 2]
        }

        private func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[sorted.count / 2]
        }

        private func stabilityRatio(_ values: [UInt64]) -> Double {
            let medianValue = median(values)
            guard medianValue > 0 else {
                return values.allSatisfy { $0 == 0 } ? 0 : .infinity
            }
            let maximum = values.max() ?? medianValue
            return Double(maximum - medianValue) / Double(medianValue)
        }

        private func formatNanoseconds(_ value: UInt64) -> String {
            formatMS(Double(value) / 1_000_000)
        }

        private func formatMicroseconds(_ value: UInt64) -> String {
            formatMS(Double(value) / 1000)
        }

        private func formatSignedMicroseconds(_ value: Int64) -> String {
            formatMS(Double(value) / 1000)
        }

        private func formatValues(_ values: [Double]) -> String {
            values.map(formatMS).joined(separator: ", ")
        }

        private func formatMS(_ value: Double) -> String {
            String(format: "%.3f", value)
        }

        private func formatPercent(_ ratio: Double) -> String {
            String(format: "%.1f%%", ratio * 100)
        }

        private func formatGiB(_ bytes: UInt64) -> String {
            String(format: "%.1f", Double(bytes) / 1_073_741_824)
        }
    }

    func workspaceFileSearchIndexElapsedMilliseconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
#endif
