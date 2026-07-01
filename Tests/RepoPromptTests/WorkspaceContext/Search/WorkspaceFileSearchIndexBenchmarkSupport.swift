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
        static let firstScopedContentNeedle = "FirstScopedContentNeedle"
        static let firstScopedNeedleContents = "// RepoPrompt CE file-search benchmark fixture\nlet FirstScopedContentNeedle = \"worktree-only\"\n"

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
            try Data(
                "// Scope decoy\nlet FirstScopedContentNeedle = \"visible-root-decoy\"\n".utf8
            ).write(
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
                        let contents = if moduleIndex == 0, layerIndex == 0, fileIndex == 0 {
                            Data(firstScopedNeedleContents.utf8)
                        } else {
                            fixtureContents
                        }
                        try contents.write(to: layerURL.appendingPathComponent(fileName), options: [])
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
        let cumulativeSearchMilliseconds: Double
        let readMilliseconds: Double
        let counters: WorkspaceFileSearchIndexBenchmarkCounters
        let phases: WorkspaceFileSearchPhaseSnapshot
        let coldStart: WorkspaceFileSearchColdStartSnapshot?
    }

    struct WorkspaceFileSearchIndexBenchmarkAggregate {
        let scenario: String
        let warmup: WorkspaceFileSearchIndexBenchmarkSample
        let measured: [WorkspaceFileSearchIndexBenchmarkSample]
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let stabilityRatio: Double
        let isStable: Bool
        let medianPreSearchMilliseconds: Double
        let p95PreSearchMilliseconds: Double
        let medianSearchMilliseconds: Double
        let p95SearchMilliseconds: Double
        let medianCumulativeSearchMilliseconds: Double
        let p95CumulativeSearchMilliseconds: Double
        let medianReadMilliseconds: Double
        let p95ReadMilliseconds: Double

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
            medianPreSearchMilliseconds = Self.median(measured.map(\.preSearchMilliseconds))
            p95PreSearchMilliseconds = Self.nearestRankP95(measured.map(\.preSearchMilliseconds))
            medianSearchMilliseconds = Self.median(measured.map(\.searchMilliseconds))
            p95SearchMilliseconds = Self.nearestRankP95(measured.map(\.searchMilliseconds))
            medianCumulativeSearchMilliseconds = Self.median(measured.map(\.cumulativeSearchMilliseconds))
            p95CumulativeSearchMilliseconds = Self.nearestRankP95(measured.map(\.cumulativeSearchMilliseconds))
            medianReadMilliseconds = Self.median(measured.map(\.readMilliseconds))
            p95ReadMilliseconds = Self.nearestRankP95(measured.map(\.readMilliseconds))
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

    struct WorkspaceBenchmarkValidityIssue: Equatable {
        let code: String
        let detail: String
    }

    struct WorkspaceBenchmarkDistribution: Equatable {
        let rawValues: [Double]
        let mean: Double
        let median: Double
        let nearestRankP95: Double
        let sampleVariance: Double
        let sampleStandardDeviation: Double
        let coefficientOfVariation: Double?
        let minimum: Double
        let maximum: Double

        init(_ values: [Double]) {
            rawValues = values
            guard !values.isEmpty else {
                mean = 0
                median = 0
                nearestRankP95 = 0
                sampleVariance = 0
                sampleStandardDeviation = 0
                coefficientOfVariation = nil
                minimum = 0
                maximum = 0
                return
            }
            let sorted = values.sorted()
            let meanValue = values.reduce(0, +) / Double(values.count)
            mean = meanValue
            let midpoint = sorted.count / 2
            median = sorted.count.isMultiple(of: 2)
                ? (sorted[midpoint - 1] + sorted[midpoint]) / 2
                : sorted[midpoint]
            let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
            nearestRankP95 = sorted[min(sorted.count - 1, rank - 1)]
            if values.count > 1 {
                sampleVariance = values.reduce(0) { partial, value in
                    let delta = value - meanValue
                    return partial + delta * delta
                } / Double(values.count - 1)
            } else {
                sampleVariance = 0
            }
            sampleStandardDeviation = sqrt(sampleVariance)
            coefficientOfVariation = meanValue == 0 ? nil : sampleStandardDeviation / meanValue
            minimum = sorted[0]
            maximum = sorted[sorted.count - 1]
        }
    }

    enum WorkspaceCodeMapPhase2BenchmarkMetric: String, CaseIterable {
        case validatedRawRead
        case envelopeHashAndDecode
        case explicitLanguageQueryParse
        case pathFreeArtifactGeneration
        case modernEnvelopeToReadyArtifact

        var unit: String {
            "milliseconds"
        }

        var supportsThreadCPU: Bool {
            self != .validatedRawRead
        }
    }

    struct WorkspaceCodeMapPhase2BenchmarkSample {
        static let requiredCorrectnessChecks = [
            "raw-bytes-and-count",
            "digest-stability",
            "ready-and-expected-symbol",
            "serialization-path-free",
            "serialization-round-trip",
            "rendering-parity",
            "binding-fencing"
        ]

        let ordinal: Int
        let phase: String
        let wallValues: [WorkspaceCodeMapPhase2BenchmarkMetric: Double]
        let threadCPUValues: [WorkspaceCodeMapPhase2BenchmarkMetric: Double]
        let serializedArtifactBytes: Int?
        let correctnessChecks: [String: Bool]
        let validityIssues: [WorkspaceBenchmarkValidityIssue]

        var isValid: Bool {
            validityIssues.isEmpty
        }

        var correctnessPassed: Bool {
            Self.requiredCorrectnessChecks.allSatisfy { correctnessChecks[$0] == true }
        }
    }

    struct WorkspaceCodeMapPhase2MetricAggregate {
        let attemptedSampleCount: Int
        let retainedSampleCount: Int
        let excludedSampleCount: Int
        let distribution: WorkspaceBenchmarkDistribution?

        init(attemptedSampleCount: Int, values: [Double]) {
            self.attemptedSampleCount = attemptedSampleCount
            let retained = values.filter(\.isFinite)
            retainedSampleCount = retained.count
            excludedSampleCount = attemptedSampleCount - retained.count
            distribution = retained.isEmpty ? nil : WorkspaceBenchmarkDistribution(retained)
        }

        var reliability: String {
            guard let coefficient = coefficientOfVariation else { return "unavailable" }
            return coefficient <= 0.10 ? "high" : "low"
        }

        var coefficientOfVariation: Double? {
            guard retainedSampleCount >= 2,
                  let distribution,
                  distribution.mean != 0
            else { return nil }
            return distribution.sampleStandardDeviation / abs(distribution.mean)
        }
    }

    struct WorkspaceCodeMapPhase2BenchmarkAggregate {
        static let scenario = "phase2-explicit-path-free-model"

        let warmup: WorkspaceCodeMapPhase2BenchmarkSample
        let measured: [WorkspaceCodeMapPhase2BenchmarkSample]
        let wallStatistics: [WorkspaceCodeMapPhase2BenchmarkMetric: WorkspaceCodeMapPhase2MetricAggregate]
        let threadCPUStatistics: [WorkspaceCodeMapPhase2BenchmarkMetric: WorkspaceCodeMapPhase2MetricAggregate]
        let serializedArtifactByteStatistics: WorkspaceCodeMapPhase2MetricAggregate
        let validityIssues: [WorkspaceBenchmarkValidityIssue]

        init(
            warmup: WorkspaceCodeMapPhase2BenchmarkSample,
            measured: [WorkspaceCodeMapPhase2BenchmarkSample]
        ) {
            self.warmup = warmup
            self.measured = measured

            let attemptedCount = measured.count
            wallStatistics = Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase2BenchmarkMetric.allCases.map { metric in
                (
                    metric,
                    WorkspaceCodeMapPhase2MetricAggregate(
                        attemptedSampleCount: attemptedCount,
                        values: measured.compactMap { $0.wallValues[metric] }
                    )
                )
            })
            threadCPUStatistics = Dictionary(
                uniqueKeysWithValues: WorkspaceCodeMapPhase2BenchmarkMetric.allCases
                    .filter(\.supportsThreadCPU)
                    .map { metric in
                        (
                            metric,
                            WorkspaceCodeMapPhase2MetricAggregate(
                                attemptedSampleCount: attemptedCount,
                                values: measured.compactMap { $0.threadCPUValues[metric] }
                            )
                        )
                    }
            )
            serializedArtifactByteStatistics = WorkspaceCodeMapPhase2MetricAggregate(
                attemptedSampleCount: attemptedCount,
                values: measured.compactMap { $0.serializedArtifactBytes.map(Double.init) }
            )

            var issues: [WorkspaceBenchmarkValidityIssue] = []
            if warmup.phase != "warmup-excluded" || warmup.ordinal != 0 {
                issues.append(.init(
                    code: "phase2-warmup-label",
                    detail: "Phase 2 requires exactly one ordinal-zero excluded warmup."
                ))
            }
            if measured.count != 5 {
                issues.append(.init(
                    code: "phase2-sample-count",
                    detail: "Expected five retained Phase 2 attempts; found \(measured.count)."
                ))
            }
            if measured.enumerated().contains(where: { index, sample in
                sample.phase != "measured" || sample.ordinal != index + 1
            }) {
                issues.append(.init(
                    code: "phase2-measured-labels",
                    detail: "Phase 2 measured attempts must be labeled measured with ordinals one through five."
                ))
            }
            for sample in [warmup] + measured where !sample.isValid {
                issues.append(.init(
                    code: "phase2-sample-invalid",
                    detail: "\(sample.phase) sample \(sample.ordinal) failed correctness or timing validity."
                ))
            }
            validityIssues = issues
        }

        var isValid: Bool {
            validityIssues.isEmpty
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
        let knownHostDisturbance: String?
        let overlappingConductorWorkDeclared: Bool

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
                conductorState: environment["RP_CE_FILE_SEARCH_INDEX_CONDUCTOR_STATE"] ?? configuration["conductorState"] ?? "coordinated daemon",
                knownHostDisturbance: environment["RP_CE_FILE_SEARCH_INDEX_KNOWN_HOST_DISTURBANCE"]
                    ?? configuration["knownHostDisturbance"],
                overlappingConductorWorkDeclared: environment["RP_CE_FILE_SEARCH_INDEX_OVERLAPPING_CONDUCTOR_WORK"] == "1"
                    || configuration["overlappingConductorWork"] == "1"
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
        let productionEquivalent: WorkspaceFileSearchIndexBenchmarkAggregate
        let incrementalRebuild: WorkspaceFileSearchIndexBenchmarkAggregate
        let phase2Model: WorkspaceCodeMapPhase2BenchmarkAggregate
        let phase3Storage: WorkspaceCodeMapPhase3BenchmarkAggregate
        let phase4GitIdentityLocator: WorkspaceCodeMapPhase4BenchmarkAggregate
        let phase5Coordinator: WorkspaceCodeMapPhase5BenchmarkAggregate
        let sortDiagnostic: WorkspaceFileSearchIndexSortDiagnostic?

        var validityIssues: [WorkspaceBenchmarkValidityIssue] {
            var issues = phase2Model.validityIssues
                + phase3Storage.validityIssues
                + phase4GitIdentityLocator.validityIssues
                + phase5Coordinator.validityIssues
            if let disturbance = environment.knownHostDisturbance, !disturbance.isEmpty {
                issues.append(.init(code: "known-host-disturbance", detail: disturbance))
            }
            if environment.overlappingConductorWorkDeclared {
                issues.append(.init(
                    code: "overlapping-conductor-work",
                    detail: "Runtime configuration declared overlapping conductor work."
                ))
            }
            return issues
        }

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

        func writeMarkdownExclusively(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: Data((markdownBlock() + "\n").utf8))
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }

        private func markdownBlock() -> String {
            var lines: [String] = [
                "## Run `\(environment.runLabel)`",
                "",
                "Recorded: \(environment.recordedAt)  ",
                "Commit: `\(environment.commit)`  ",
                "Attribution: \(environment.attribution)  ",
                "Invocation validity: \(validityIssues.isEmpty ? "valid" : "INVALID — diagnostic only")  ",
                "Known host disturbance: \(environment.knownHostDisturbance ?? "none declared")  ",
                "Overlapping conductor work declared: \(environment.overlappingConductorWorkDeclared ? "yes" : "no")",
                "",
                "| Environment | macOS | Hardware/CPU | Logical cores | Memory GiB | Swift | Build configuration | Conductor state |",
                "| --- | --- | --- | ---: | ---: | --- | --- | --- |",
                "| env-001 | \(environment.macOS) | \(environment.hardware) | \(environment.logicalCores) | \(formatGiB(environment.memoryBytes)) | \(environment.swiftVersion) | \(environment.buildConfiguration) | \(environment.conductorState) |",
                "",
                "| Scenario | Raw measured samples ms | Median ms | Nearest-rank p95 ms | Stability |",
                "| --- | --- | ---: | ---: | --- |",
                aggregateRow(coldWorktree),
                aggregateRow(productionEquivalent),
                aggregateRow(incrementalRebuild),
                "",
                "| Scenario | Materialize/publish median/p95 ms | Cumulative through search median/p95 ms | Search median/p95 ms | Read median/p95 ms |",
                "| --- | ---: | ---: | ---: | ---: |",
                phaseAggregateRow(coldWorktree),
                phaseAggregateRow(productionEquivalent),
                phaseAggregateRow(incrementalRebuild),
                "",
                "| Scenario | Crawl Δ | Applied generation Δ | Shard build Δ | Patch Δ | Authoritative Δ | Full path-index build Δ | Overlay build Δ | Fallback Δ | Catalog rebuild Δ | Catalog invalidation Δ |",
                "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
                counterRow(scenario: coldWorktree.scenario, counters: coldWorktree.measured.map(\.counters)),
                counterRow(scenario: productionEquivalent.scenario, counters: productionEquivalent.measured.map(\.counters)),
                counterRow(scenario: incrementalRebuild.scenario, counters: incrementalRebuild.measured.map(\.counters)),
                "",
                "| Scenario | Phase | Sample | Total through read ms | Materialize/publish ms | Cumulative through search ms | Search ms | Read ms |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
                sampleRows(coldWorktree).joined(separator: "\n"),
                sampleRows(productionEquivalent).joined(separator: "\n"),
                sampleRows(incrementalRebuild).joined(separator: "\n")
            ]
            lines.append(contentsOf: [
                "",
                "| Scenario | Phase | Sample | Ready ms | Readiness/freshness preamble ms | First catalog access ms | FileSearchActor ms | Orchestration residual ms | Reconciliation Δ ms |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                topLevelPhaseRows(coldWorktree).joined(separator: "\n"),
                topLevelPhaseRows(productionEquivalent).joined(separator: "\n"),
                topLevelPhaseRows(incrementalRebuild).joined(separator: "\n"),
                "",
                "| Scenario | Phase | Sample | Catalog total ms | Filter ms | Sort ms | File sort ms | Folder sort ms | Sort residual ms | Sort reconciliation Δ ms | Sort invocations | File inputs | Folder inputs | Entry materialization ms | Path-index key ms | Path-index construction ms | Composition/cache residual ms | Rebuilds | Files | Roots |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                catalogPhaseRows(coldWorktree).joined(separator: "\n"),
                catalogPhaseRows(productionEquivalent).joined(separator: "\n"),
                catalogPhaseRows(incrementalRebuild).joined(separator: "\n")
            ])
            lines.append(contentsOf: [
                "",
                "| Scenario | Phase | Sample | Descriptor ms | Filter ms | Sort/input ms | Batch/enqueue ms | Drain-to-hit ms | Post-hit ms | Actor residual ms |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                actorPhaseRows(coldWorktree).joined(separator: "\n"),
                actorPhaseRows(productionEquivalent).joined(separator: "\n"),
                actorPhaseRows(incrementalRebuild).joined(separator: "\n"),
                "",
                "| Scenario | Phase | Sample | Source | Descriptors | Admitted | Sort input | Batches | Initially enqueued | Drained to hit | Entries examined | Returned hit ordinal | Returned prefix |",
                "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
                actorCountRows(coldWorktree).joined(separator: "\n"),
                actorCountRows(productionEquivalent).joined(separator: "\n"),
                actorCountRows(incrementalRebuild).joined(separator: "\n")
            ])
            lines.append(contentsOf: coldStartRows(productionEquivalent))
            if let sortDiagnostic {
                lines.append(contentsOf: sortDiagnosticMarkdown(sortDiagnostic))
            }
            lines.append(contentsOf: phase2ModelMarkdown())
            lines.append(contentsOf: phase3StorageMarkdown())
            lines.append(contentsOf: phase4GitIdentityLocatorMarkdown())
            lines.append(contentsOf: phase5CoordinatorMarkdown())
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
                    "conductorState": environment.conductorState,
                    "knownHostDisturbance": environment.knownHostDisturbance.map { $0 as Any } ?? NSNull(),
                    "overlappingConductorWorkDeclared": environment.overlappingConductorWorkDeclared
                ],
                "scenarios": [
                    aggregateDictionary(coldWorktree),
                    aggregateDictionary(productionEquivalent),
                    aggregateDictionary(incrementalRebuild)
                ],
                "phase2Model": phase2ModelDictionary(),
                "phase3Storage": phase3StorageDictionary(),
                "phase4GitIdentityLocator": phase4GitIdentityLocatorDictionary(),
                "phase5Coordinator": phase5CoordinatorDictionary(),
                "validityIssues": validityIssues.map(validityIssueDictionary),
                "correctnessStatus": validityIssues.isEmpty ? "passed" : "invalid-diagnostic-only"
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
                "phaseMediansMilliseconds": [
                    "materializeOrPublish": aggregate.medianPreSearchMilliseconds,
                    "cumulativeThroughSearch": aggregate.medianCumulativeSearchMilliseconds,
                    "search": aggregate.medianSearchMilliseconds,
                    "read": aggregate.medianReadMilliseconds
                ],
                "phaseNearestRankP95Milliseconds": [
                    "materializeOrPublish": aggregate.p95PreSearchMilliseconds,
                    "cumulativeThroughSearch": aggregate.p95CumulativeSearchMilliseconds,
                    "search": aggregate.p95SearchMilliseconds,
                    "read": aggregate.p95ReadMilliseconds
                ],
                "warmup": sampleDictionary(aggregate.warmup),
                "measured": aggregate.measured.map(sampleDictionary)
            ]
        }

        private func sampleDictionary(_ sample: WorkspaceFileSearchIndexBenchmarkSample) -> [String: Any] {
            var dictionary: [String: Any] = [
                "ordinal": sample.ordinal,
                "phase": sample.phase,
                "totalWallMilliseconds": sample.totalWallMilliseconds,
                "materializeOrPublishMilliseconds": sample.preSearchMilliseconds,
                "readySearchMilliseconds": sample.searchMilliseconds,
                "cumulativeThroughSearchMilliseconds": sample.cumulativeSearchMilliseconds,
                "readMilliseconds": sample.readMilliseconds,
                "counters": counterDictionary(sample.counters),
                "phaseAccounting": phaseDictionary(sample.phases)
            ]
            if let coldStart = sample.coldStart {
                dictionary["coldStartAttribution"] = coldStartDictionary(coldStart)
            }
            return dictionary
        }

        private func coldStartDictionary(_ snapshot: WorkspaceFileSearchColdStartSnapshot) -> [String: Any] {
            [
                "materialization": [
                    "totalMicroseconds": snapshot.materialization.totalMicroseconds,
                    "prepareMicroseconds": snapshot.materialization.prepareMicroseconds,
                    "commitMicroseconds": snapshot.materialization.commitMicroseconds
                ],
                "rootCrawl": [
                    "count": snapshot.rootCrawl.count,
                    "totalMicroseconds": snapshot.rootCrawl.totalMicroseconds,
                    "maximumMicroseconds": snapshot.rootCrawl.maximumMicroseconds,
                    "filesDiscovered": snapshot.rootCrawl.filesDiscovered,
                    "foldersDiscovered": snapshot.rootCrawl.foldersDiscovered
                ],
                "schedulerByWorkload": snapshot.schedulerByWorkload.mapValues { workload in
                    [
                        "requestCount": workload.requestCount,
                        "enqueueCount": workload.enqueueCount,
                        "grantCount": workload.grantCount,
                        "completionCount": workload.completionCount,
                        "cancellationCount": workload.cancellationCount,
                        "failureCount": workload.failureCount,
                        "totalWaitMicroseconds": workload.totalWaitMicroseconds,
                        "maximumWaitMicroseconds": workload.maximumWaitMicroseconds,
                        "totalExecutionMicroseconds": workload.totalExecutionMicroseconds
                    ]
                },
                "codemap": [
                    "collectionPassCount": snapshot.codemap.collectionPassCount,
                    "filesCollected": snapshot.codemap.filesCollected,
                    "collectionMicroseconds": snapshot.codemap.collectionMicroseconds,
                    "requestBuildPassCount": snapshot.codemap.requestBuildPassCount,
                    "requestsBuilt": snapshot.codemap.requestsBuilt,
                    "requestBuildMicroseconds": snapshot.codemap.requestBuildMicroseconds,
                    "submissionPassCount": snapshot.codemap.submissionPassCount,
                    "requestsSubmitted": snapshot.codemap.requestsSubmitted,
                    "submissionMicroseconds": snapshot.codemap.submissionMicroseconds,
                    "scansStarted": snapshot.codemap.scansStarted,
                    "scansCompleted": snapshot.codemap.scansCompleted,
                    "scansCancelled": snapshot.codemap.scansCancelled,
                    "scanMicroseconds": snapshot.codemap.scanMicroseconds
                ]
            ]
        }

        private func phase2ModelDictionary() -> [String: Any] {
            [
                "scenario": WorkspaceCodeMapPhase2BenchmarkAggregate.scenario,
                "warmupSampleCount": 1,
                "measuredAttemptCount": phase2Model.measured.count,
                "valid": phase2Model.isValid,
                "prospectiveInvalidRunRules": [
                    "build-or-test-failure",
                    "correctness-parity-or-serialization-failure",
                    "missing-or-nonfinite-required-timing",
                    "wrong-sample-count-or-warmup-label",
                    "declared-overlapping-conductor-work",
                    "known-host-disturbance"
                ],
                "wallStatistics": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase2BenchmarkMetric.allCases.map { metric in
                    (metric.rawValue, phase2MetricAggregateDictionary(phase2Model.wallStatistics[metric]!))
                }),
                "threadCPUStatistics": Dictionary(uniqueKeysWithValues: phase2Model.threadCPUStatistics.map { metric, aggregate in
                    (metric.rawValue, phase2MetricAggregateDictionary(aggregate))
                }),
                "serializedArtifactBytes": phase2MetricAggregateDictionary(
                    phase2Model.serializedArtifactByteStatistics
                ),
                "warmup": phase2SampleDictionary(phase2Model.warmup),
                "measured": phase2Model.measured.map(phase2SampleDictionary),
                "validityIssues": phase2Model.validityIssues.map(validityIssueDictionary)
            ]
        }

        private func phase2SampleDictionary(_ sample: WorkspaceCodeMapPhase2BenchmarkSample) -> [String: Any] {
            [
                "ordinal": sample.ordinal,
                "phase": sample.phase,
                "wallValues": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase2BenchmarkMetric.allCases.map { metric in
                    (metric.rawValue, phase2JSONNumber(sample.wallValues[metric]))
                }),
                "threadCPUValues": Dictionary(
                    uniqueKeysWithValues: WorkspaceCodeMapPhase2BenchmarkMetric.allCases
                        .filter(\.supportsThreadCPU)
                        .map { metric in
                            (metric.rawValue, phase2JSONNumber(sample.threadCPUValues[metric]))
                        }
                ),
                "serializedArtifactBytes": sample.serializedArtifactBytes.map { $0 as Any } ?? NSNull(),
                "correctnessChecks": sample.correctnessChecks,
                "validityIssues": sample.validityIssues.map(validityIssueDictionary),
                "valid": sample.isValid
            ]
        }

        private func phase2MetricAggregateDictionary(
            _ aggregate: WorkspaceCodeMapPhase2MetricAggregate
        ) -> [String: Any] {
            let distribution: Any = if let value = aggregate.distribution {
                [
                    "retainedSampleCount": value.rawValues.count,
                    "rawValues": value.rawValues,
                    "mean": value.mean,
                    "median": value.median,
                    "nearestRankP95": value.nearestRankP95,
                    "sampleVariance": value.sampleVariance,
                    "sampleStandardDeviation": value.sampleStandardDeviation,
                    "coefficientOfVariation": aggregate.coefficientOfVariation.map { $0 as Any } ?? NSNull(),
                    "minimum": value.minimum,
                    "maximum": value.maximum
                ] as [String: Any]
            } else {
                NSNull()
            }
            return [
                "attemptedSampleCount": aggregate.attemptedSampleCount,
                "retainedSampleCount": aggregate.retainedSampleCount,
                "excludedSampleCount": aggregate.excludedSampleCount,
                "reliability": aggregate.reliability,
                "distribution": distribution
            ]
        }

        private func phase2JSONNumber(_ value: Double?) -> Any {
            guard let value, value.isFinite else { return NSNull() }
            return value
        }

        private func distributionDictionary(_ distribution: WorkspaceBenchmarkDistribution) -> [String: Any] {
            [
                "retainedSampleCount": distribution.rawValues.count,
                "rawValues": distribution.rawValues,
                "mean": distribution.mean,
                "median": distribution.median,
                "nearestRankP95": distribution.nearestRankP95,
                "sampleVariance": distribution.sampleVariance,
                "sampleStandardDeviation": distribution.sampleStandardDeviation,
                "coefficientOfVariation": distribution.coefficientOfVariation.map { $0 as Any } ?? NSNull(),
                "minimum": distribution.minimum,
                "maximum": distribution.maximum
            ]
        }

        private func validityIssueDictionary(_ issue: WorkspaceBenchmarkValidityIssue) -> [String: Any] {
            ["code": issue.code, "detail": issue.detail]
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
                let vector = counterVector($0.counters)
                return vector == [1, 0, 1, 0, 1, 0, 0, 0, 1, 1]
                    || vector == [1, 1, 1, 0, 1, 0, 0, 0, 1, 1]
            } && incrementalSamples.allSatisfy {
                counterVector($0.counters) == [0, 1, 1, 1, 0, 0, 0, 0, 1, 1]
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

        private func phaseAggregateRow(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> String {
            "| \(aggregate.scenario) | \(formatMS(aggregate.medianPreSearchMilliseconds))/\(formatMS(aggregate.p95PreSearchMilliseconds)) | \(formatMS(aggregate.medianCumulativeSearchMilliseconds))/\(formatMS(aggregate.p95CumulativeSearchMilliseconds)) | \(formatMS(aggregate.medianSearchMilliseconds))/\(formatMS(aggregate.p95SearchMilliseconds)) | \(formatMS(aggregate.medianReadMilliseconds))/\(formatMS(aggregate.p95ReadMilliseconds)) |"
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
                "| \(aggregate.scenario) | \(sample.phase) | \(sample.ordinal) | \(formatMS(sample.totalWallMilliseconds)) | \(formatMS(sample.preSearchMilliseconds)) | \(formatMS(sample.cumulativeSearchMilliseconds)) | \(formatMS(sample.searchMilliseconds)) | \(formatMS(sample.readMilliseconds)) |"
            }
        }

        private func phase2ModelMarkdown() -> [String] {
            var lines = [
                "",
                "## Phase 2 explicit path-free model",
                "",
                "Scenario validity: \(phase2Model.isValid ? "valid" : "INVALID — diagnostic only")  ",
                "This filesystem-only explicit-test aggregate executes after every unchanged Phase 1 scenario. One warmup is excluded and five measured attempts are retained; valid slow outliers are never removed. Reliability is high when CV <= 10% and low otherwise.",
                "",
                "Prospective invalid-run rules: build/test failure; failed correctness, parity, or serialization invariant; missing/nonfinite required timing; wrong sample count or warmup labeling; declared overlapping conductor work; or known host disturbance. A slow outlier or high CV alone is not invalid.",
                "",
                "| Wall metric | Unit | Attempted | Retained | Excluded | Raw retained values | Median | Nearest-rank p95 | CV | Reliability |",
                "| --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |"
            ]
            for metric in WorkspaceCodeMapPhase2BenchmarkMetric.allCases {
                guard let aggregate = phase2Model.wallStatistics[metric] else { continue }
                let distribution = aggregate.distribution
                lines.append(
                    "| \(metric.rawValue) | \(metric.unit) | \(aggregate.attemptedSampleCount) | \(aggregate.retainedSampleCount) | \(aggregate.excludedSampleCount) | \(distribution.map { formatPhase2Values($0.rawValues, unit: metric.unit) } ?? "unavailable") | \(distribution.map { formatPhase2Value($0.median, unit: metric.unit) } ?? "unavailable") | \(distribution.map { formatPhase2Value($0.nearestRankP95, unit: metric.unit) } ?? "unavailable") | \(aggregate.coefficientOfVariation.map(formatPercent) ?? "unavailable") | \(aggregate.reliability) |"
                )
            }

            lines.append(contentsOf: [
                "",
                "| Thread CPU metric | Attempted | Retained | Excluded | Raw retained ms | Median ms | Nearest-rank p95 ms | CV | Reliability |",
                "| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |"
            ])
            for metric in WorkspaceCodeMapPhase2BenchmarkMetric.allCases where metric.supportsThreadCPU {
                guard let aggregate = phase2Model.threadCPUStatistics[metric] else { continue }
                let distribution = aggregate.distribution
                lines.append(
                    "| \(metric.rawValue) | \(aggregate.attemptedSampleCount) | \(aggregate.retainedSampleCount) | \(aggregate.excludedSampleCount) | \(distribution.map { formatValues($0.rawValues) } ?? "unavailable") | \(distribution.map { formatMS($0.median) } ?? "unavailable") | \(distribution.map { formatMS($0.nearestRankP95) } ?? "unavailable") | \(aggregate.coefficientOfVariation.map(formatPercent) ?? "unavailable") | \(aggregate.reliability) |"
                )
            }

            lines.append(contentsOf: [
                "",
                "Validated raw reads use detached/asynchronous filesystem work, so thread CPU is intentionally unavailable for that span. CPU values are best-effort current-thread measurements for synchronous hash/decode, parse, and terminal spans; scheduler/process CPU is not captured.",
                "",
                "| Phase | Sample | Raw read ms | Envelope ms | Explicit parse ms | Path-free artifact ms | Envelope-to-ready ms | Serialized bytes | Correctness | Validity |",
                "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"
            ])
            for sample in [phase2Model.warmup] + phase2Model.measured {
                func value(_ metric: WorkspaceCodeMapPhase2BenchmarkMetric) -> String {
                    sample.wallValues[metric].map { formatPhase2Value($0, unit: metric.unit) } ?? "unavailable"
                }
                lines.append(
                    "| \(sample.phase) | \(sample.ordinal) | \(value(.validatedRawRead)) | \(value(.envelopeHashAndDecode)) | \(value(.explicitLanguageQueryParse)) | \(value(.pathFreeArtifactGeneration)) | \(value(.modernEnvelopeToReadyArtifact)) | \(sample.serializedArtifactBytes.map(String.init) ?? "unavailable") | \(sample.correctnessPassed ? "pass" : "FAIL") | \(sample.isValid ? "valid" : "INVALID") |"
                )
            }

            let size = phase2Model.serializedArtifactByteStatistics
            lines.append(contentsOf: [
                "",
                "Serialized artifact size is diagnostic only: attempted \(size.attemptedSampleCount), retained \(size.retainedSampleCount), excluded \(size.excludedSampleCount), raw bytes \(size.distribution.map { formatPhase2Values($0.rawValues, unit: "bytes") } ?? "unavailable"), median \(size.distribution.map { formatPhase2Value($0.median, unit: "bytes") } ?? "unavailable"), nearest-rank p95 \(size.distribution.map { formatPhase2Value($0.nearestRankP95, unit: "bytes") } ?? "unavailable"), CV \(size.coefficientOfVariation.map(formatPercent) ?? "unavailable"), reliability \(size.reliability).",
                "",
                "Correctness checks are outside timed spans and cover exact raw bytes/count, stable digest, ready artifact and expected symbol, path/identity-free serialization, round-trip rendering parity, and binding acceptance/duplicate/stale fencing.",
                "",
                "Limitations: single DEBUG SwiftPM process and synthetic Swift fixture; this aggregate is diagnostics rather than a pass/fail latency threshold; measurements do not include CAS, Git identity, persistence, coordinator, publication, production serving, or idle scheduling; sub-millisecond spans are sensitive to host noise; raw-read thread CPU is unavailable and synchronous thread CPU excludes detached/scheduler work."
            ])
            if !phase2Model.validityIssues.isEmpty {
                lines.append(contentsOf: ["", "### Phase 2 invalid-run issues"])
                lines.append(contentsOf: phase2Model.validityIssues.map { "- `\($0.code)`: \($0.detail)" })
                for sample in [phase2Model.warmup] + phase2Model.measured where !sample.validityIssues.isEmpty {
                    lines.append("- \(sample.phase) sample \(sample.ordinal):")
                    lines.append(contentsOf: sample.validityIssues.map { "  - `\($0.code)`: \($0.detail)" })
                }
            }
            return lines
        }

        private func markdownEscaped(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|")
        }

        private func coldStartRows(_ aggregate: WorkspaceFileSearchIndexBenchmarkAggregate) -> [String] {
            var lines = [
                "",
                "| Scenario | Phase | Sample | Materialize ms | Crawl ms/count | Catalog/path-index ms | Content scheduler wait ms (requests/enqueued) | Interactive scheduler wait ms (requests/enqueued) | Codemap scheduler wait ms (requests/enqueued) | Codemap collect/build/submit ms | Codemap files/requests/submitted | Scans started/completed/cancelled |",
                "| --- | --- | ---: | ---: | --- | ---: | --- | --- | --- | --- | --- | --- |"
            ]
            lines.append(contentsOf: allSamples(aggregate).compactMap { sample in
                guard let snapshot = sample.coldStart else { return nil }
                let content = snapshot.schedulerByWorkload[ContentReadWorkloadClass.contentSearch.rawValue]
                let interactive = snapshot.schedulerByWorkload[ContentReadWorkloadClass.interactiveRead.rawValue]
                let codemap = snapshot.schedulerByWorkload[ContentReadWorkloadClass.codemap.rawValue]
                let codemapPhases = snapshot.codemap
                let catalogAndPathIndex = sample.phases.catalog.totalMicroseconds
                return "| \(aggregate.scenario) | \(sample.phase) | \(sample.ordinal) | \(formatMicroseconds(snapshot.materialization.totalMicroseconds)) | \(formatMicroseconds(snapshot.rootCrawl.totalMicroseconds))/\(snapshot.rootCrawl.count) | \(formatMicroseconds(catalogAndPathIndex)) | \(schedulerSummary(content)) | \(schedulerSummary(interactive)) | \(schedulerSummary(codemap)) | \(formatMicroseconds(codemapPhases.collectionMicroseconds))/\(formatMicroseconds(codemapPhases.requestBuildMicroseconds))/\(formatMicroseconds(codemapPhases.submissionMicroseconds)) | \(codemapPhases.filesCollected)/\(codemapPhases.requestsBuilt)/\(codemapPhases.requestsSubmitted) | \(codemapPhases.scansStarted)/\(codemapPhases.scansCompleted)/\(codemapPhases.scansCancelled) |"
            })
            return lines
        }

        private func schedulerSummary(
            _ workload: WorkspaceFileSearchColdStartSnapshot.SchedulerWorkload?
        ) -> String {
            guard let workload else { return "0.000 (0/0)" }
            return "\(formatMicroseconds(workload.totalWaitMicroseconds)) (\(workload.requestCount)/\(workload.enqueueCount))"
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

        private func formatPhase2Values(_ values: [Double], unit: String) -> String {
            values.map { formatPhase2Value($0, unit: unit) }.joined(separator: ", ")
        }

        private func formatPhase2Value(_ value: Double, unit: String) -> String {
            guard value.isFinite else { return "unavailable" }
            return switch unit {
            case "ratio": String(format: "%.6f", value)
            case "bytes": String(format: "%.0f", value)
            default: formatMS(value)
            }
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
