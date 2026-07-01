#if DEBUG
    import Darwin
    import Foundation
    @testable import RepoPrompt

    enum WorkspaceCodeMapPhase3BenchmarkMetric: String, CaseIterable {
        case canonicalKeyPipelineConstruction
        case coldArtifactInsert
        case freshStoreColdDiskLookup
        case residentMemoryLookup
        case concurrentDiskReadFanOut8
        case leaseAcquireRelease
        case reconciliationSmall8Budget1
        case reconciliationRepresentative256Budget3
        case gcSmall8Budget1
        case gcRepresentative256Budget3
        case corruptLookupAndQuarantine

        var definition: String {
            switch self {
            case .canonicalKeyPipelineConstruction:
                "new SyntaxManager pipeline identity plus raw-source envelope, canonical key bytes, and storage digest"
            case .coldArtifactInsert:
                "fresh store insert including container encode/checksum, artifact fsync/publication/verification, and catalog fsync/publication"
            case .freshStoreColdDiskLookup:
                "lookup from a newly constructed actor with empty resident/catalog state; OS filesystem caches are not purged"
            case .residentMemoryLookup:
                "same-store resident lookup including actor hop and buffered access-touch bookkeeping"
            case .concurrentDiskReadFanOut8:
                "timer starts before task creation and includes gate arrival/release, eight independent fresh-store disk lookups, exact outcome comparisons, and result collection"
            case .leaseAcquireRelease:
                "shared disk lease acquisition plus complete explicit close and actor lease-accounting release"
            case .reconciliationSmall8Budget1:
                "complete fresh-store accounting reconciliation of eight live records using step budget one"
            case .reconciliationRepresentative256Budget3:
                "complete fresh-store accounting reconciliation of 256 live records using step budget three"
            case .gcSmall8Budget1:
                "complete quota-forced quarantine GC of eight reconciled records using step budget one; delayed sweep excluded"
            case .gcRepresentative256Budget3:
                "complete quota-forced quarantine GC of 256 reconciled records using step budget three; delayed sweep excluded"
            case .corruptLookupAndQuarantine:
                "fresh-store corrupt payload validation, catalog/artifact quarantine mutation, and terminal miss"
            }
        }
    }

    struct WorkspaceCodeMapPhase3MaintenanceSample {
        let cardinality: Int
        let stepBudget: Int
        let storedContainerBytes: UInt64
        let reconciliationCallCount: Int
        let reconciliationVisitedEntryCount: Int
        let reconciliationReadByteCount: UInt64
        let reconciliationWrittenByteCount: UInt64
        let reconciliationMaximumVisitedPerCall: Int
        let gcCallCount: Int
        let gcVisitedEntryCount: Int
        let gcReadByteCount: UInt64
        let gcWrittenByteCount: UInt64
        let gcMaximumVisitedPerCall: Int
        let quarantinedCount: Int
        let sweptCount: Int
    }

    struct WorkspaceCodeMapPhase3BenchmarkSample {
        static let requiredCorrectnessChecks = [
            "canonical-identity-round-trip",
            "cold-insert",
            "fresh-store-disk-hit",
            "resident-memory-hit",
            "concurrent-disk-fan-out",
            "lease-release",
            "small-maintenance",
            "representative-maintenance",
            "corruption-quarantine"
        ]

        let ordinal: Int
        let phase: String
        let wallValues: [WorkspaceCodeMapPhase3BenchmarkMetric: Double]
        let artifactContainerBytes: UInt64?
        let sourceBytes: Int
        let fanOutReaderCount: Int
        let maintenance: [WorkspaceCodeMapPhase3MaintenanceSample]
        let correctnessChecks: [String: Bool]
        let validityIssues: [WorkspaceBenchmarkValidityIssue]

        var isValid: Bool {
            validityIssues.isEmpty
        }

        var correctnessPassed: Bool {
            Self.requiredCorrectnessChecks.allSatisfy { correctnessChecks[$0] == true }
        }
    }

    struct WorkspaceCodeMapPhase3MetricAggregate {
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

        var coefficientOfVariation: Double? {
            guard retainedSampleCount >= 2,
                  let distribution,
                  distribution.mean != 0
            else { return nil }
            return distribution.sampleStandardDeviation / abs(distribution.mean)
        }

        var reliability: String {
            guard let coefficientOfVariation else { return "unavailable" }
            if coefficientOfVariation <= 0.10 { return "high" }
            if coefficientOfVariation <= 0.20 { return "moderate" }
            return "low"
        }
    }

    struct WorkspaceCodeMapPhase3BenchmarkAggregate {
        static let scenario = "phase3-explicit-cas-infrastructure"

        let warmup: WorkspaceCodeMapPhase3BenchmarkSample
        let measured: [WorkspaceCodeMapPhase3BenchmarkSample]
        let wallStatistics: [WorkspaceCodeMapPhase3BenchmarkMetric: WorkspaceCodeMapPhase3MetricAggregate]
        let artifactContainerByteStatistics: WorkspaceCodeMapPhase3MetricAggregate
        let validityIssues: [WorkspaceBenchmarkValidityIssue]

        init(
            warmup: WorkspaceCodeMapPhase3BenchmarkSample,
            measured: [WorkspaceCodeMapPhase3BenchmarkSample]
        ) {
            self.warmup = warmup
            self.measured = measured
            let attemptedCount = measured.count
            wallStatistics = Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase3BenchmarkMetric.allCases.map { metric in
                (
                    metric,
                    WorkspaceCodeMapPhase3MetricAggregate(
                        attemptedSampleCount: attemptedCount,
                        values: measured.compactMap { $0.wallValues[metric] }
                    )
                )
            })
            artifactContainerByteStatistics = WorkspaceCodeMapPhase3MetricAggregate(
                attemptedSampleCount: attemptedCount,
                values: measured.compactMap { $0.artifactContainerBytes.map(Double.init) }
            )

            var issues: [WorkspaceBenchmarkValidityIssue] = []
            if warmup.phase != "warmup-excluded" || warmup.ordinal != 0 {
                issues.append(.init(
                    code: "phase3-warmup-label",
                    detail: "Phase 3 requires exactly one ordinal-zero excluded warmup."
                ))
            }
            if measured.count != 5 {
                issues.append(.init(
                    code: "phase3-sample-count",
                    detail: "Expected five retained Phase 3 attempts; found \(measured.count)."
                ))
            }
            if measured.enumerated().contains(where: { index, sample in
                sample.phase != "measured" || sample.ordinal != index + 1
            }) {
                issues.append(.init(
                    code: "phase3-measured-labels",
                    detail: "Phase 3 measured attempts must be labeled measured with ordinals one through five."
                ))
            }
            for sample in [warmup] + measured where !sample.isValid {
                issues.append(.init(
                    code: "phase3-sample-invalid",
                    detail: "\(sample.phase) sample \(sample.ordinal) failed correctness or timing validity."
                ))
            }
            validityIssues = issues
        }

        var isValid: Bool {
            validityIssues.isEmpty
        }
    }

    private actor WorkspaceCodeMapPhase3FanOutGate {
        private let target: Int
        private var arrivalCount = 0
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(target: Int) {
            self.target = target
        }

        func arriveAndWait() async {
            if released { return }
            arrivalCount += 1
            if arrivalCount == target {
                released = true
                let continuations = waiters
                waiters.removeAll(keepingCapacity: false)
                continuations.forEach { $0.resume() }
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private struct WorkspaceCodeMapPhase3MaintenanceResult {
        let timings: [WorkspaceCodeMapPhase3BenchmarkMetric: Double]
        let sample: WorkspaceCodeMapPhase3MaintenanceSample
        let passed: Bool
    }

    extension WorkspaceFileSearchIndexTimeToReadyBenchmarkTests {
        func runPhase3StorageScenario() async throws -> WorkspaceCodeMapPhase3BenchmarkAggregate {
            var warmup: WorkspaceCodeMapPhase3BenchmarkSample?
            var measured: [WorkspaceCodeMapPhase3BenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = await runPhase3StorageSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured"
                )
                if isWarmup { warmup = sample }
                else { measured.append(sample) }
            }
            guard let warmup else {
                throw CodeMapArtifactCatalogError.invalidMetadata
            }
            return WorkspaceCodeMapPhase3BenchmarkAggregate(warmup: warmup, measured: measured)
        }

        private func runPhase3StorageSample(
            ordinal: Int,
            phase: String
        ) async -> WorkspaceCodeMapPhase3BenchmarkSample {
            let fanOutReaderCount = 8
            var wallValues: [WorkspaceCodeMapPhase3BenchmarkMetric: Double] = [:]
            var artifactContainerBytes: UInt64?
            var maintenance: [WorkspaceCodeMapPhase3MaintenanceSample] = []
            var correctnessChecks: [String: Bool] = [:]
            var issues: [WorkspaceBenchmarkValidityIssue] = []
            let sourceData = Data(phase3BenchmarkSource(ordinal: ordinal).utf8)

            func recordCheck(_ name: String, _ passed: Bool, _ detail: String) {
                correctnessChecks[name] = passed
                if !passed {
                    issues.append(.init(code: "phase3-\(name)", detail: detail))
                }
            }

            do {
                let keyStart = DispatchTime.now()
                let pipelineIdentity = try SyntaxManager().pipelineIdentity(
                    for: .swift,
                    decoderPolicy: .workspaceAutomaticV1
                )
                let source = phase3SourceSnapshot(data: sourceData, ordinal: ordinal)
                let key = try CodeMapArtifactKey(source: source, pipelineIdentity: pipelineIdentity)
                wallValues[.canonicalKeyPipelineConstruction] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: keyStart,
                    to: DispatchTime.now()
                )
                let decodedIdentity = try CodeMapPipelineIdentity(canonicalBytes: pipelineIdentity.canonicalBytes)
                let decodedKey = try CodeMapArtifactKey(canonicalBytes: key.canonicalBytes)
                recordCheck(
                    "canonical-identity-round-trip",
                    decodedIdentity == pipelineIdentity
                        && decodedKey == key
                        && source.rawByteCount == sourceData.count
                        && key.storageDigestHex.count == 64,
                    "Pipeline/key canonical bytes, raw byte count, or storage digest did not round-trip."
                )

                let root = try phase3SecureRoot(label: "primary-\(ordinal)")
                defer { try? FileManager.default.removeItem(at: root) }
                let outcome = CodeMapSyntaxArtifactOutcome.ready(phase3Artifact(entryCount: 256, prefix: "Primary"))
                let clock = CodeMapArtifactStoreClock(now: { 100 })
                let store = try CodeMapArtifactStore(rootURL: root, clock: clock)

                let insertStart = DispatchTime.now()
                let insertResult = try await store.insert(key: key, deterministicOutcome: outcome)
                wallValues[.coldArtifactInsert] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: insertStart,
                    to: DispatchTime.now()
                )
                recordCheck(
                    "cold-insert",
                    insertResult == .inserted,
                    "Fresh CAS insert did not publish exactly one new artifact."
                )

                let freshStore = try CodeMapArtifactStore(rootURL: root, clock: clock)
                let diskStart = DispatchTime.now()
                let diskLookup = try await freshStore.lookup(key: key)
                wallValues[.freshStoreColdDiskLookup] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: diskStart,
                    to: DispatchTime.now()
                )
                let diskPassed: Bool
                switch diskLookup {
                case let .hit(source: .disk, handle):
                    diskPassed = handle.outcome == outcome
                    artifactContainerBytes = handle.containerByteCount
                case .hit, .miss:
                    diskPassed = false
                }
                recordCheck(
                    "fresh-store-disk-hit",
                    diskPassed,
                    "New store actor did not return the exact deterministic outcome from disk."
                )

                let memoryStart = DispatchTime.now()
                let memoryLookup = try await store.lookup(key: key)
                wallValues[.residentMemoryLookup] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: memoryStart,
                    to: DispatchTime.now()
                )
                let residentHandle: CodeMapArtifactHandle? = switch memoryLookup {
                case let .hit(source: .memory, handle):
                    handle
                case .hit, .miss:
                    nil
                }
                recordCheck(
                    "resident-memory-hit",
                    residentHandle?.outcome == outcome,
                    "Same-store lookup did not return the exact resident outcome."
                )

                let fanOutStores = try (0 ..< fanOutReaderCount).map { _ in
                    try CodeMapArtifactStore(rootURL: root, clock: clock)
                }
                let fanOutGate = WorkspaceCodeMapPhase3FanOutGate(target: fanOutReaderCount)
                let fanOutStart = DispatchTime.now()
                let fanOutResults = try await withThrowingTaskGroup(of: Bool.self) { group in
                    for reader in fanOutStores {
                        group.addTask {
                            await fanOutGate.arriveAndWait()
                            return switch try await reader.lookup(key: key) {
                            case let .hit(source: .disk, handle): handle.outcome == outcome
                            case .hit, .miss: false
                            }
                        }
                    }
                    var results: [Bool] = []
                    for try await result in group {
                        results.append(result)
                    }
                    return results
                }
                wallValues[.concurrentDiskReadFanOut8] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: fanOutStart,
                    to: DispatchTime.now()
                )
                recordCheck(
                    "concurrent-disk-fan-out",
                    fanOutResults.count == fanOutReaderCount && fanOutResults.allSatisfy(\.self),
                    "Barrier-released independent readers did not all complete with exact disk hits."
                )

                var leasePassed = false
                if let residentHandle {
                    let leaseStart = DispatchTime.now()
                    let lease = try await store.lease(handle: residentHandle)
                    await lease.close()
                    wallValues[.leaseAcquireRelease] = workspaceFileSearchIndexElapsedMilliseconds(
                        from: leaseStart,
                        to: DispatchTime.now()
                    )
                    leasePassed = await store.accounting().activeLeaseCount == 0
                }
                recordCheck(
                    "lease-release",
                    leasePassed,
                    "Lease acquire/close did not return active lease accounting to zero."
                )

                let small = try await phase3MaintenanceRun(
                    cardinality: 8,
                    stepBudget: 1,
                    ordinal: ordinal,
                    pipelineIdentity: pipelineIdentity
                )
                wallValues.merge(small.timings) { _, new in new }
                maintenance.append(small.sample)
                recordCheck(
                    "small-maintenance",
                    small.passed,
                    "Eight-record reconciliation/GC did not preserve bounded progress and exact accounting."
                )

                let representative = try await phase3MaintenanceRun(
                    cardinality: 256,
                    stepBudget: 3,
                    ordinal: ordinal,
                    pipelineIdentity: pipelineIdentity
                )
                wallValues.merge(representative.timings) { _, new in new }
                maintenance.append(representative.sample)
                recordCheck(
                    "representative-maintenance",
                    representative.passed,
                    "256-record reconciliation/GC did not preserve bounded progress and exact accounting."
                )

                let corruptRoot = try phase3SecureRoot(label: "corrupt-\(ordinal)")
                defer { try? FileManager.default.removeItem(at: corruptRoot) }
                let corruptWriter = try CodeMapArtifactStore(rootURL: corruptRoot, clock: clock)
                _ = try await corruptWriter.insert(key: key, deterministicOutcome: outcome)
                let corruptArtifact = phase3ArtifactURL(root: corruptRoot, key: key)
                try Data("phase3-corrupt-payload".utf8).write(to: corruptArtifact, options: [])
                guard chmod(corruptArtifact.path, 0o600) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let corruptReader = try CodeMapArtifactStore(rootURL: corruptRoot, clock: clock)
                let corruptStart = DispatchTime.now()
                let corruptLookup = try await corruptReader.lookup(key: key)
                wallValues[.corruptLookupAndQuarantine] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: corruptStart,
                    to: DispatchTime.now()
                )
                let corruptionPassed: Bool = if case .miss = corruptLookup {
                    !FileManager.default.fileExists(atPath: corruptArtifact.path)
                } else {
                    false
                }
                recordCheck(
                    "corruption-quarantine",
                    corruptionPassed,
                    "Corrupt payload lookup did not return miss and move the original artifact out of the live namespace."
                )
            } catch {
                issues.append(.init(code: "phase3-sample-error", detail: "Phase 3 sample failed: \(error)"))
            }

            for metric in WorkspaceCodeMapPhase3BenchmarkMetric.allCases {
                guard let value = wallValues[metric] else {
                    issues.append(.init(code: "phase3-missing-timing", detail: "\(metric.rawValue) is missing."))
                    continue
                }
                if !value.isFinite {
                    issues.append(.init(code: "phase3-nonfinite-timing", detail: "\(metric.rawValue) is nonfinite."))
                }
            }
            if artifactContainerBytes == nil {
                issues.append(.init(code: "phase3-missing-container-size", detail: "Artifact container size is missing."))
            }
            for check in WorkspaceCodeMapPhase3BenchmarkSample.requiredCorrectnessChecks
                where correctnessChecks[check] == nil
            {
                issues.append(.init(code: "phase3-missing-correctness-check", detail: "\(check) did not execute."))
            }

            return WorkspaceCodeMapPhase3BenchmarkSample(
                ordinal: ordinal,
                phase: phase,
                wallValues: wallValues,
                artifactContainerBytes: artifactContainerBytes,
                sourceBytes: sourceData.count,
                fanOutReaderCount: fanOutReaderCount,
                maintenance: maintenance,
                correctnessChecks: correctnessChecks,
                validityIssues: issues
            )
        }

        private func phase3MaintenanceRun(
            cardinality: Int,
            stepBudget: Int,
            ordinal: Int,
            pipelineIdentity: CodeMapPipelineIdentity
        ) async throws -> WorkspaceCodeMapPhase3MaintenanceResult {
            let root = try phase3SecureRoot(label: "maintenance-\(cardinality)-\(ordinal)")
            defer { try? FileManager.default.removeItem(at: root) }
            let clock = CodeMapArtifactStoreClock(now: { 100 })
            let policy = CodeMapArtifactStorePolicy(
                softQuotaBytes: 0,
                hardQuotaBytes: 1,
                unreferencedGraceSeconds: 0,
                quarantineDelaySeconds: .max
            )
            let writer = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock)
            let outcome = CodeMapSyntaxArtifactOutcome.ready(phase3Artifact(entryCount: 1, prefix: "Maintenance"))
            for index in 0 ..< cardinality {
                let data = Data("phase3-maintenance-\(ordinal)-\(cardinality)-\(index)".utf8)
                let key = try CodeMapArtifactKey(
                    source: phase3SourceSnapshot(data: data, ordinal: ordinal * 1000 + index),
                    pipelineIdentity: pipelineIdentity
                )
                guard try await writer.insert(key: key, deterministicOutcome: outcome) == .inserted else {
                    throw CodeMapArtifactCatalogError.invalidMetadata
                }
            }
            let populated = await writer.accounting()
            let restarted = try CodeMapArtifactStore(rootURL: root, policy: policy, clock: clock)

            let reconciliationStart = DispatchTime.now()
            let reconciliation = try await phase3DrainReconciliation(restarted, stepBudget: stepBudget)
            let reconciliationMilliseconds = workspaceFileSearchIndexElapsedMilliseconds(
                from: reconciliationStart,
                to: DispatchTime.now()
            )
            let afterReconciliation = await restarted.accounting()

            let gcStart = DispatchTime.now()
            let gc = try await phase3DrainGC(restarted, stepBudget: stepBudget)
            let gcMilliseconds = workspaceFileSearchIndexElapsedMilliseconds(
                from: gcStart,
                to: DispatchTime.now()
            )
            let afterGC = await restarted.accounting()

            let reconciliationVisited = reconciliation.reduce(0) { $0 + $1.visitedEntryCount }
            let reconciliationRead = reconciliation.reduce(UInt64(0)) { $0 + $1.readByteCount }
            let reconciliationWritten = reconciliation.reduce(UInt64(0)) { $0 + $1.writtenByteCount }
            let reconciliationMaximumVisited = reconciliation.map(\.visitedEntryCount).max() ?? 0
            let gcVisited = gc.reduce(0) { $0 + $1.visitedEntryCount }
            let gcRead = gc.reduce(UInt64(0)) { $0 + $1.readByteCount }
            let gcWritten = gc.reduce(UInt64(0)) { $0 + $1.writtenByteCount }
            let gcMaximumVisited = gc.map(\.visitedEntryCount).max() ?? 0
            let quarantined = gc.reduce(0) { $0 + $1.quarantinedCount }
            let swept = gc.reduce(0) { $0 + $1.sweptCount }
            let passed = reconciliation.last?.isComplete == true
                && gc.last?.isComplete == true
                && reconciliation.count > 1
                && gc.count > 1
                && reconciliationMaximumVisited <= stepBudget
                && gcMaximumVisited <= stepBudget
                && afterReconciliation.livePositiveCount == cardinality
                && afterReconciliation.liveReconciliationComplete
                && afterReconciliation.quarantineInventoryComplete
                && quarantined == cardinality
                && swept == 0
                && afterGC.livePositiveCount == 0
                && afterGC.quarantinedCount == cardinality

            let metrics: [WorkspaceCodeMapPhase3BenchmarkMetric: Double] = if cardinality == 8 {
                [
                    .reconciliationSmall8Budget1: reconciliationMilliseconds,
                    .gcSmall8Budget1: gcMilliseconds
                ]
            } else {
                [
                    .reconciliationRepresentative256Budget3: reconciliationMilliseconds,
                    .gcRepresentative256Budget3: gcMilliseconds
                ]
            }
            return WorkspaceCodeMapPhase3MaintenanceResult(
                timings: metrics,
                sample: WorkspaceCodeMapPhase3MaintenanceSample(
                    cardinality: cardinality,
                    stepBudget: stepBudget,
                    storedContainerBytes: populated.livePositiveBytes,
                    reconciliationCallCount: reconciliation.count,
                    reconciliationVisitedEntryCount: reconciliationVisited,
                    reconciliationReadByteCount: reconciliationRead,
                    reconciliationWrittenByteCount: reconciliationWritten,
                    reconciliationMaximumVisitedPerCall: reconciliationMaximumVisited,
                    gcCallCount: gc.count,
                    gcVisitedEntryCount: gcVisited,
                    gcReadByteCount: gcRead,
                    gcWrittenByteCount: gcWritten,
                    gcMaximumVisitedPerCall: gcMaximumVisited,
                    quarantinedCount: quarantined,
                    sweptCount: swept
                ),
                passed: passed
            )
        }

        private func phase3DrainReconciliation(
            _ store: CodeMapArtifactStore,
            stepBudget: Int
        ) async throws -> [CodeMapArtifactReconciliationProgress] {
            var pages: [CodeMapArtifactReconciliationProgress] = []
            for _ in 0 ..< 100_000 {
                let progress = try await store.refreshAccounting(stepBudget: stepBudget)
                pages.append(progress)
                if progress.isComplete { return pages }
            }
            throw CodeMapArtifactCatalogError.boundedScanExceeded
        }

        private func phase3DrainGC(
            _ store: CodeMapArtifactStore,
            stepBudget: Int
        ) async throws -> [CodeMapArtifactGCProgress] {
            var pages: [CodeMapArtifactGCProgress] = []
            for _ in 0 ..< 100_000 {
                let progress = try await store.runGC(stepBudget: stepBudget)
                pages.append(progress)
                if progress.isComplete { return pages }
            }
            throw CodeMapArtifactCatalogError.boundedScanExceeded
        }

        private func phase3BenchmarkSource(ordinal: Int) -> String {
            var lines = ["import Foundation", "let phase3Ordinal = \(ordinal)"]
            for index in 0 ..< 256 {
                lines.append("struct Phase3Source\(index) { let value = \(index + ordinal) }")
            }
            return lines.joined(separator: "\n") + "\n"
        }

        private func phase3SourceSnapshot(data: Data, ordinal: Int) -> CodeMapSourceSnapshot {
            let fingerprint = FileContentFingerprint(
                deviceID: 1,
                fileNumber: UInt64(max(1, ordinal + 1)),
                byteSize: Int64(data.count),
                modificationSeconds: 100,
                modificationNanoseconds: 0,
                statusChangeSeconds: 100,
                statusChangeNanoseconds: 0
            )
            return CodeMapSourceSnapshot(
                validatedContent: ValidatedRawFileContentSnapshot(
                    data: data,
                    modificationDate: fingerprint.modificationDate,
                    fingerprint: fingerprint
                )
            )
        }

        private func phase3Artifact(entryCount: Int, prefix: String) -> CodeMapSyntaxArtifact {
            CodeMapSyntaxArtifact(
                imports: [],
                classes: (0 ..< entryCount).map { index in
                    ClassInfo(name: "\(prefix)Type\(index)", methods: [], properties: [])
                },
                functions: (0 ..< entryCount).map { index in
                    FunctionInfo(
                        name: "\(prefix.lowercased())Function\(index)",
                        parameters: [
                            ParameterInfo(externalName: nil, localName: "value", typeName: "Int")
                        ],
                        returnType: "Int",
                        definitionLine: "func \(prefix.lowercased())Function\(index)(value: Int) -> Int",
                        lineNumber: index + 1
                    )
                },
                enums: [],
                globalVars: [],
                macros: [],
                referencedTypes: (0 ..< entryCount).map { "\(prefix)Type\($0)" }
            )
        }

        private func phase3SecureRoot(label: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPromptCEPhase3CAS-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(root.path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard let resolvedPath = root.path.withCString({ pointer -> String? in
                guard let resolved = realpath(pointer, nil) else { return nil }
                defer { free(resolved) }
                return String(cString: resolved)
            }) else {
                throw POSIXError(.EIO)
            }
            return URL(fileURLWithPath: resolvedPath, isDirectory: true)
        }

        private func phase3ArtifactURL(root: URL, key: CodeMapArtifactKey) -> URL {
            root.appendingPathComponent("CodeMapArtifacts/v1/artifacts/\(key.shard)/\(key.storageDigestHex)")
        }
    }

    extension WorkspaceFileSearchIndexBenchmarkRun {
        func phase3StorageDictionary() -> [String: Any] {
            [
                "scenario": WorkspaceCodeMapPhase3BenchmarkAggregate.scenario,
                "warmupSampleCount": 1,
                "measuredAttemptCount": phase3Storage.measured.count,
                "valid": phase3Storage.isValid,
                "servingMode": "explicit-benchmark-only; CAS remains inert and non-serving",
                "prospectiveInvalidRunRules": [
                    "build-or-test-failure",
                    "correctness-or-progress-invariant-failure",
                    "missing-or-nonfinite-required-timing",
                    "wrong-sample-count-or-warmup-label",
                    "declared-overlapping-conductor-work",
                    "known-host-disturbance"
                ],
                "metricDefinitions": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase3BenchmarkMetric.allCases.map {
                    ($0.rawValue, $0.definition)
                }),
                "wallStatistics": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase3BenchmarkMetric.allCases.map { metric in
                    (metric.rawValue, phase3MetricDictionary(phase3Storage.wallStatistics[metric]!))
                }),
                "artifactContainerBytes": phase3MetricDictionary(phase3Storage.artifactContainerByteStatistics),
                "warmup": phase3SampleDictionary(phase3Storage.warmup),
                "measured": phase3Storage.measured.map(phase3SampleDictionary),
                "validityIssues": phase3Storage.validityIssues.map { ["code": $0.code, "detail": $0.detail] }
            ]
        }

        func phase3StorageMarkdown() -> [String] {
            var lines = [
                "",
                "## Phase 3 explicit CAS infrastructure",
                "",
                "Phase 3 aggregate validity before top-level environment rules: \(phase3Storage.isValid ? "valid" : "INVALID — diagnostic only")  ",
                "CAS serving remains inert/default-off. These timings call explicit Phase 3 infrastructure APIs only and do not establish end-to-end reuse gains. One warmup is excluded and five measured attempts are retained; valid slow outliers are never removed.",
                "",
                "Prospective invalid-run rules: build/test failure; failed correctness or bounded-progress invariant; missing/nonfinite required timing; wrong sample count or warmup labeling; declared overlapping conductor work; or known host disturbance. Host disturbance and overlap are applied by the top-level invocation validity shown above; the Phase 3 aggregate validity covers its own samples. High CV or a valid slow outlier alone is not invalid.",
                "",
                "Reliability: high when CV <= 10%, moderate when 10% < CV <= 20%, low when CV > 20%.",
                "",
                "| Wall metric | Exact measurement boundary | Attempted | Retained | Excluded | Raw retained ms | Median ms | Nearest-rank p95 ms | CV | Reliability |",
                "| --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |"
            ]
            for metric in WorkspaceCodeMapPhase3BenchmarkMetric.allCases {
                let aggregate = phase3Storage.wallStatistics[metric]!
                let distribution = aggregate.distribution
                lines.append(
                    "| \(metric.rawValue) | \(metric.definition) | \(aggregate.attemptedSampleCount) | \(aggregate.retainedSampleCount) | \(aggregate.excludedSampleCount) | \(distribution.map { phase3Values($0.rawValues) } ?? "unavailable") | \(distribution.map { phase3MS($0.median) } ?? "unavailable") | \(distribution.map { phase3MS($0.nearestRankP95) } ?? "unavailable") | \(aggregate.coefficientOfVariation.map(phase3Percent) ?? "unavailable") | \(aggregate.reliability) |"
                )
            }

            lines.append(contentsOf: [
                "",
                "| Phase | Sample | Source bytes | Container bytes | Readers | Key ms | Insert ms | Disk ms | Memory ms | Fan-out ms | Lease ms | Reconcile 8/256 ms | GC 8/256 ms | Corrupt ms | Correctness | Validity |",
                "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | ---: | --- | --- |"
            ])
            for sample in [phase3Storage.warmup] + phase3Storage.measured {
                func value(_ metric: WorkspaceCodeMapPhase3BenchmarkMetric) -> String {
                    sample.wallValues[metric].map(phase3MS) ?? "unavailable"
                }
                lines.append(
                    "| \(sample.phase) | \(sample.ordinal) | \(sample.sourceBytes) | \(sample.artifactContainerBytes.map(String.init) ?? "unavailable") | \(sample.fanOutReaderCount) | \(value(.canonicalKeyPipelineConstruction)) | \(value(.coldArtifactInsert)) | \(value(.freshStoreColdDiskLookup)) | \(value(.residentMemoryLookup)) | \(value(.concurrentDiskReadFanOut8)) | \(value(.leaseAcquireRelease)) | \(value(.reconciliationSmall8Budget1))/\(value(.reconciliationRepresentative256Budget3)) | \(value(.gcSmall8Budget1))/\(value(.gcRepresentative256Budget3)) | \(value(.corruptLookupAndQuarantine)) | \(sample.correctnessPassed ? "pass" : "FAIL") | \(sample.isValid ? "valid" : "INVALID") |"
                )
            }

            lines.append(contentsOf: [
                "",
                "| Phase | Sample | Cardinality | Step budget | Stored bytes | Reconcile calls/visited/max-per-call/read/write | GC calls/visited/max-per-call/read/write | Quarantined | Swept |",
                "| --- | ---: | ---: | ---: | ---: | --- | --- | ---: | ---: |"
            ])
            for sample in [phase3Storage.warmup] + phase3Storage.measured {
                for progress in sample.maintenance {
                    lines.append(
                        "| \(sample.phase) | \(sample.ordinal) | \(progress.cardinality) | \(progress.stepBudget) | \(progress.storedContainerBytes) | \(progress.reconciliationCallCount)/\(progress.reconciliationVisitedEntryCount)/\(progress.reconciliationMaximumVisitedPerCall)/\(progress.reconciliationReadByteCount)/\(progress.reconciliationWrittenByteCount) | \(progress.gcCallCount)/\(progress.gcVisitedEntryCount)/\(progress.gcMaximumVisitedPerCall)/\(progress.gcReadByteCount)/\(progress.gcWrittenByteCount) | \(progress.quarantinedCount) | \(progress.sweptCount) |"
                    )
                }
            }

            let size = phase3Storage.artifactContainerByteStatistics
            lines.append(contentsOf: [
                "",
                "Primary artifact container size: attempted \(size.attemptedSampleCount), retained \(size.retainedSampleCount), raw bytes \(size.distribution.map { phase3IntegerValues($0.rawValues) } ?? "unavailable"), median \(size.distribution.map { String(format: "%.0f", $0.median) } ?? "unavailable"), p95 \(size.distribution.map { String(format: "%.0f", $0.nearestRankP95) } ?? "unavailable").",
                "",
                "Correctness checks run outside timed spans except the fan-out's per-reader exact outcome comparison, which is included in that end-to-end concurrent span. Checks cover canonical identity round trips, exact deterministic outcomes and hit provenance, eight-reader completion, lease accounting cleanup, bounded reconciliation/GC progress and exact cardinality accounting, and corruption quarantine/miss behavior.",
                "",
                "Limitations: one host and DEBUG SwiftPM; synthetic Swift source/artifacts; fresh-store disk lookup is logically cold only because macOS filesystem caches are not purged; fan-out includes task/gate scheduling; resident lookup includes buffered touch bookkeeping but not durable touch flush; GC measures quarantine selection/publication and excludes delayed sweep; no Git locator, root manifest, single-flight coordinator, workspace publication, production serving, or end-to-end reuse is measured."
            ])
            if !phase3Storage.validityIssues.isEmpty {
                lines.append(contentsOf: ["", "### Phase 3 invalid-run issues"])
                lines.append(contentsOf: phase3Storage.validityIssues.map { "- `\($0.code)`: \($0.detail)" })
                for sample in [phase3Storage.warmup] + phase3Storage.measured where !sample.validityIssues.isEmpty {
                    lines.append("- \(sample.phase) sample \(sample.ordinal):")
                    lines.append(contentsOf: sample.validityIssues.map { "  - `\($0.code)`: \($0.detail)" })
                }
            }
            return lines
        }

        private func phase3SampleDictionary(_ sample: WorkspaceCodeMapPhase3BenchmarkSample) -> [String: Any] {
            [
                "ordinal": sample.ordinal,
                "phase": sample.phase,
                "wallValues": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase3BenchmarkMetric.allCases.map {
                    ($0.rawValue, sample.wallValues[$0].map { $0 as Any } ?? NSNull())
                }),
                "artifactContainerBytes": sample.artifactContainerBytes.map { $0 as Any } ?? NSNull(),
                "sourceBytes": sample.sourceBytes,
                "fanOutReaderCount": sample.fanOutReaderCount,
                "maintenance": sample.maintenance.map(phase3MaintenanceDictionary),
                "correctnessChecks": sample.correctnessChecks,
                "validityIssues": sample.validityIssues.map { ["code": $0.code, "detail": $0.detail] },
                "valid": sample.isValid
            ]
        }

        private func phase3MaintenanceDictionary(
            _ sample: WorkspaceCodeMapPhase3MaintenanceSample
        ) -> [String: Any] {
            [
                "cardinality": sample.cardinality,
                "stepBudget": sample.stepBudget,
                "storedContainerBytes": sample.storedContainerBytes,
                "reconciliationCallCount": sample.reconciliationCallCount,
                "reconciliationVisitedEntryCount": sample.reconciliationVisitedEntryCount,
                "reconciliationReadByteCount": sample.reconciliationReadByteCount,
                "reconciliationWrittenByteCount": sample.reconciliationWrittenByteCount,
                "reconciliationMaximumVisitedPerCall": sample.reconciliationMaximumVisitedPerCall,
                "gcCallCount": sample.gcCallCount,
                "gcVisitedEntryCount": sample.gcVisitedEntryCount,
                "gcReadByteCount": sample.gcReadByteCount,
                "gcWrittenByteCount": sample.gcWrittenByteCount,
                "gcMaximumVisitedPerCall": sample.gcMaximumVisitedPerCall,
                "quarantinedCount": sample.quarantinedCount,
                "sweptCount": sample.sweptCount
            ]
        }

        private func phase3MetricDictionary(_ aggregate: WorkspaceCodeMapPhase3MetricAggregate) -> [String: Any] {
            let distribution: Any = if let value = aggregate.distribution {
                [
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

        private func phase3Values(_ values: [Double]) -> String {
            values.map(phase3MS).joined(separator: ", ")
        }

        private func phase3IntegerValues(_ values: [Double]) -> String {
            values.map { String(format: "%.0f", $0) }.joined(separator: ", ")
        }

        private func phase3MS(_ value: Double) -> String {
            String(format: "%.6f", value)
        }

        private func phase3Percent(_ value: Double) -> String {
            String(format: "%.3f%%", value * 100)
        }
    }
#endif
