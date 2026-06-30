#if DEBUG
    import Darwin
    import Foundation
    @testable import RepoPrompt

    enum WorkspaceCodeMapPhase5BenchmarkMetric: String, CaseIterable {
        case runtimeConstruction
        case coldSourceBuildPersistAndLocator
        case buildQueueWait
        case buildPermitWait
        case deterministicBuild
        case casPersistAndVerify
        case locatorPublication
        case residentDirectHit
        case freshStoreDiskHit
        case warmLocatorToCASHit
        case sameKeyFanOutEight
        case boundedBusyThenRetry
        case transientFailureThenRetry
        case waiterCancellationIsolation
        case foregroundSuppressedAdmission

        var definition: String {
            switch self {
            case .runtimeConstruction:
                "isolated CodeMapArtifactRuntime construction over a fresh secure temporary root; never initializes the process-wide singleton"
            case .coldSourceBuildPersistAndLocator:
                "cold source request through CAS miss, real deterministic Swift build, verified CAS persistence, and locator publication"
            case .buildQueueWait:
                "coordinator-reported queue wait for the cold source build"
            case .buildPermitWait:
                "builder-reported content-limiter permit wait for the cold source build"
            case .deterministicBuild:
                "coordinator-reported real deterministic CodeMapSyntaxArtifactBuilder execution"
            case .casPersistAndVerify:
                "coordinator-reported atomic CAS persistence followed by verified lookup"
            case .locatorPublication:
                "coordinator-reported verified locator publication after CAS success"
            case .residentDirectHit:
                "direct artifact-key lookup from the original runtime's resident CAS cache"
            case .freshStoreDiskHit:
                "direct artifact-key lookup from a newly constructed store over the persisted root"
            case .warmLocatorToCASHit:
                "locator lookup followed by CAS disk hit using newly constructed locator and artifact stores"
            case .sameKeyFanOutEight:
                "eight concurrent same-key source requests through one gated build and insert"
            case .boundedBusyThenRetry:
                "bounded one-active/one-queued build scenario through busy rejection, drain, and clean retry"
            case .transientFailureThenRetry:
                "injected first build failure followed by a clean successful retry"
            case .waiterCancellationIsolation:
                "one joined waiter cancellation while the owning waiter and shared build complete"
            case .foregroundSuppressedAdmission:
                "real foreground token hold through queued codemap permit observation, release, and successful real build"
            }
        }
    }

    enum WorkspaceCodeMapPhase5ThroughputMetric: String, CaseIterable {
        case fanOutWaitersPerSecond
        case distinctKeyBuildsPerSecond

        var definition: String {
            switch self {
            case .fanOutWaitersPerSecond:
                "eight delivered same-key waiters divided by the fan-out wall span"
            case .distinctKeyBuildsPerSecond:
                "eight distinct synthetic deterministic outcomes persisted within a two-build coordinator bound divided by wall span"
            }
        }
    }

    struct WorkspaceCodeMapPhase5AccountingSummary {
        var requests: UInt64 = 0
        var readyResults: UInt64 = 0
        var busyRejections: UInt64 = 0
        var joins: UInt64 = 0
        var waiterCancellations: UInt64 = 0
        var sharedTaskCancellations: UInt64 = 0
        var casMemoryHits: UInt64 = 0
        var casDiskHits: UInt64 = 0
        var locatorHits: UInt64 = 0
        var buildsStarted: UInt64 = 0
        var buildsSucceeded: UInt64 = 0
        var buildsFailed: UInt64 = 0
        var casInserted: UInt64 = 0
        var locatorInserted: UInt64 = 0
        var duplicateBuilds: UInt64 = 0
        var failures: UInt64 = 0
        var droppedHookEvents: UInt64 = 0
        var terminalActiveFlights: Int = 0
        var terminalQueuedBuilds: Int = 0
        var terminalActiveBuilds: Int = 0
        var terminalWaiters: Int = 0
        var terminalRetainedInputBytes: Int = 0
        var terminalPendingHookEvents: Int = 0
        var terminalHookDispatcherDraining = false
        var livePositiveCount: Int = 0
        var liveNegativeCount: Int = 0
        var residentPositiveCount: Int = 0
        var residentNegativeCount: Int = 0
        var residentPositiveBytes: UInt64 = 0
        var residentNegativeBytes: UInt64 = 0

        mutating func add(_ value: CodeMapArtifactBuildCoordinatorAccounting) {
            let counters = value.counters
            requests += counters.requests
            readyResults += counters.readyResults
            busyRejections += counters.busyRejections
            joins += counters.joins
            waiterCancellations += counters.waiterCancellations
            sharedTaskCancellations += counters.sharedTaskCancellations
            casMemoryHits += counters.casMemoryHits
            casDiskHits += counters.casDiskHits
            locatorHits += counters.locatorHits
            buildsStarted += counters.buildsStarted
            buildsSucceeded += counters.buildsSucceeded
            buildsFailed += counters.buildsFailed
            casInserted += counters.casInserted
            locatorInserted += counters.locatorInserted
            duplicateBuilds += counters.duplicateBuilds
            failures += counters.failures
            droppedHookEvents += counters.droppedHookEvents
            terminalActiveFlights += value.activeFlightCount
            terminalQueuedBuilds += value.queuedBuildCount
            terminalActiveBuilds += value.activeBuildCount
            terminalWaiters += value.waiterCount
            terminalRetainedInputBytes += value.retainedInputByteCount
            terminalPendingHookEvents += value.pendingHookEventCount
            terminalHookDispatcherDraining = terminalHookDispatcherDraining || value.hookDispatcherIsDraining
            livePositiveCount += value.artifactStore.livePositiveCount
            liveNegativeCount += value.artifactStore.liveNegativeCount
            residentPositiveCount += value.artifactStore.residentPositiveCount
            residentNegativeCount += value.artifactStore.residentNegativeCount
            residentPositiveBytes += value.artifactStore.residentPositiveBytes
            residentNegativeBytes += value.artifactStore.residentNegativeBytes
        }

        var terminalGaugesAreZero: Bool {
            terminalActiveFlights == 0
                && terminalQueuedBuilds == 0
                && terminalActiveBuilds == 0
                && terminalWaiters == 0
                && terminalRetainedInputBytes == 0
                && terminalPendingHookEvents == 0
                && !terminalHookDispatcherDraining
        }
    }

    struct WorkspaceCodeMapPhase5BenchmarkSample {
        static let requiredCorrectnessChecks = [
            "cold-build-publication",
            "lookup-provenance",
            "same-key-single-flight",
            "distinct-key-bounds",
            "busy-retry",
            "transient-failure-retry",
            "waiter-cancellation-isolation",
            "retained-input-release",
            "foreground-suppression",
            "terminal-accounting"
        ]

        let ordinal: Int
        let phase: String
        let wallValues: [WorkspaceCodeMapPhase5BenchmarkMetric: Double]
        let throughputValues: [WorkspaceCodeMapPhase5ThroughputMetric: Double]
        let accounting: WorkspaceCodeMapPhase5AccountingSummary
        let maximumObservedFlightCount: Int
        let maximumObservedWaiterCount: Int
        let maximumObservedConcurrentBuildCount: Int
        let peakRetainedSourceByteCount: Int
        let foregroundQueuedCodemapWaiterCount: Int
        let foregroundIllegalGrantCount: Int
        let correctnessChecks: [String: Bool]
        let validityIssues: [WorkspaceBenchmarkValidityIssue]

        var isValid: Bool {
            validityIssues.isEmpty
        }

        var correctnessPassed: Bool {
            Self.requiredCorrectnessChecks.allSatisfy { correctnessChecks[$0] == true }
        }
    }

    struct WorkspaceCodeMapPhase5MetricAggregate {
        let attemptedSampleCount: Int
        let retainedSampleCount: Int
        let excludedSampleCount: Int
        let distribution: WorkspaceBenchmarkDistribution?
        let outliers: [Double]

        init(attemptedSampleCount: Int, values: [Double]) {
            self.attemptedSampleCount = attemptedSampleCount
            let retained = values.filter(\.isFinite)
            retainedSampleCount = retained.count
            excludedSampleCount = attemptedSampleCount - retained.count
            distribution = retained.isEmpty ? nil : WorkspaceBenchmarkDistribution(retained)
            outliers = Self.tukeyOutliers(retained)
        }

        var coefficientOfVariation: Double? {
            distribution?.coefficientOfVariation
        }

        var reliability: String {
            guard let coefficientOfVariation else { return "unavailable" }
            if coefficientOfVariation <= 0.10 { return "high" }
            if coefficientOfVariation <= 0.20 { return "moderate" }
            return "low"
        }

        private static func tukeyOutliers(_ values: [Double]) -> [Double] {
            guard values.count >= 4 else { return [] }
            let sorted = values.sorted()
            let lower = Swift.Array(sorted.prefix(sorted.count / 2))
            let upper = Swift.Array(sorted.suffix(sorted.count / 2))
            guard let q1 = median(lower), let q3 = median(upper) else { return [] }
            let spread = q3 - q1
            return sorted.filter { $0 < q1 - 1.5 * spread || $0 > q3 + 1.5 * spread }
        }

        private static func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let middle = values.count / 2
            return values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
        }
    }

    struct WorkspaceCodeMapPhase5BenchmarkAggregate {
        static let scenario = "phase5-inert-artifact-build-coordinator"

        let warmup: WorkspaceCodeMapPhase5BenchmarkSample
        let measured: [WorkspaceCodeMapPhase5BenchmarkSample]
        let wallStatistics: [WorkspaceCodeMapPhase5BenchmarkMetric: WorkspaceCodeMapPhase5MetricAggregate]
        let throughputStatistics: [WorkspaceCodeMapPhase5ThroughputMetric: WorkspaceCodeMapPhase5MetricAggregate]
        let validityIssues: [WorkspaceBenchmarkValidityIssue]

        init(warmup: WorkspaceCodeMapPhase5BenchmarkSample, measured: [WorkspaceCodeMapPhase5BenchmarkSample]) {
            self.warmup = warmup
            self.measured = measured
            let attemptedCount = measured.count
            wallStatistics = Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase5BenchmarkMetric.allCases.map { metric in
                (
                    metric,
                    WorkspaceCodeMapPhase5MetricAggregate(
                        attemptedSampleCount: attemptedCount,
                        values: measured.compactMap { $0.wallValues[metric] }
                    )
                )
            })
            throughputStatistics = Dictionary(
                uniqueKeysWithValues: WorkspaceCodeMapPhase5ThroughputMetric.allCases.map { metric in
                    (
                        metric,
                        WorkspaceCodeMapPhase5MetricAggregate(
                            attemptedSampleCount: attemptedCount,
                            values: measured.compactMap { $0.throughputValues[metric] }
                        )
                    )
                }
            )

            var issues: [WorkspaceBenchmarkValidityIssue] = []
            if warmup.phase != "warmup-excluded" || warmup.ordinal != 0 {
                issues.append(.init(
                    code: "phase5-warmup-label",
                    detail: "Phase 5 requires exactly one ordinal-zero excluded warmup."
                ))
            }
            if measured.count != 5 {
                issues.append(.init(
                    code: "phase5-sample-count",
                    detail: "Expected five retained Phase 5 attempts; found \(measured.count)."
                ))
            }
            if measured.enumerated().contains(where: { index, sample in
                sample.phase != "measured" || sample.ordinal != index + 1
            }) {
                issues.append(.init(
                    code: "phase5-measured-labels",
                    detail: "Phase 5 measured attempts must use ordinals one through five."
                ))
            }
            for sample in [warmup] + measured where !sample.isValid {
                issues.append(.init(
                    code: "phase5-sample-invalid",
                    detail: "\(sample.phase) sample \(sample.ordinal) failed a prospective validity rule."
                ))
            }
            validityIssues = issues
        }

        var isValid: Bool {
            validityIssues.isEmpty
        }
    }

    private struct WorkspaceCodeMapPhase5ScenarioResult {
        var accounting = WorkspaceCodeMapPhase5AccountingSummary()
        var maximumObservedFlightCount = 0
        var maximumObservedWaiterCount = 0
        var maximumObservedConcurrentBuildCount = 0
        var peakRetainedSourceByteCount = 0
        var foregroundQueuedCodemapWaiterCount = 0
        var foregroundIllegalGrantCount = 0
        var checks: [String: Bool] = [:]
    }

    private enum WorkspaceCodeMapPhase5BenchmarkError: Error {
        case invalid(String)
        case transient
    }

    extension WorkspaceFileSearchIndexTimeToReadyBenchmarkTests {
        func runPhase5CoordinatorScenario() async throws -> WorkspaceCodeMapPhase5BenchmarkAggregate {
            var warmup: WorkspaceCodeMapPhase5BenchmarkSample?
            var measured: [WorkspaceCodeMapPhase5BenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = await runPhase5CoordinatorSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured"
                )
                if isWarmup { warmup = sample }
                else { measured.append(sample) }
            }
            guard let warmup else { throw WorkspaceCodeMapPhase5BenchmarkError.invalid("missing warmup") }
            return WorkspaceCodeMapPhase5BenchmarkAggregate(warmup: warmup, measured: measured)
        }

        private func runPhase5CoordinatorSample(
            ordinal: Int,
            phase: String
        ) async -> WorkspaceCodeMapPhase5BenchmarkSample {
            var wallValues: [WorkspaceCodeMapPhase5BenchmarkMetric: Double] = [:]
            var throughputValues: [WorkspaceCodeMapPhase5ThroughputMetric: Double] = [:]
            var result = WorkspaceCodeMapPhase5ScenarioResult()
            var issues: [WorkspaceBenchmarkValidityIssue] = []

            do {
                let cold = try await phase5ColdAndLookupMeasurements(ordinal: ordinal, wallValues: &wallValues)
                result.merge(cold)
                let fanOut = try await phase5SameKeyFanOut(
                    ordinal: ordinal,
                    wallValues: &wallValues,
                    throughputValues: &throughputValues
                )
                result.merge(fanOut)
                let distinct = try await phase5DistinctKeyThroughput(
                    ordinal: ordinal,
                    throughputValues: &throughputValues
                )
                result.merge(distinct)
                let busy = try await phase5BusyThenRetry(ordinal: ordinal, wallValues: &wallValues)
                result.merge(busy)
                let failure = try await phase5TransientFailureThenRetry(ordinal: ordinal, wallValues: &wallValues)
                result.merge(failure)
                let cancellation = try await phase5CancellationIsolation(ordinal: ordinal, wallValues: &wallValues)
                result.merge(cancellation)
                let foreground = try await phase5ForegroundSuppression(ordinal: ordinal, wallValues: &wallValues)
                result.merge(foreground)
            } catch {
                issues.append(.init(code: "phase5-execution", detail: String(describing: error)))
            }
            result.checks["terminal-accounting"] = result.accounting.terminalGaugesAreZero
                && result.accounting.duplicateBuilds == 0
                && result.accounting.droppedHookEvents == 0

            for metric in WorkspaceCodeMapPhase5BenchmarkMetric.allCases {
                guard let value = wallValues[metric], value.isFinite, value >= 0 else {
                    issues.append(.init(
                        code: "phase5-missing-wall-metric",
                        detail: "Missing or nonfinite \(metric.rawValue) in \(phase) sample \(ordinal)."
                    ))
                    continue
                }
            }
            for metric in WorkspaceCodeMapPhase5ThroughputMetric.allCases {
                guard let value = throughputValues[metric], value.isFinite, value > 0 else {
                    issues.append(.init(
                        code: "phase5-missing-throughput-metric",
                        detail: "Missing or nonfinite \(metric.rawValue) in \(phase) sample \(ordinal)."
                    ))
                    continue
                }
            }
            for check in WorkspaceCodeMapPhase5BenchmarkSample.requiredCorrectnessChecks
                where result.checks[check] != true
            {
                issues.append(.init(
                    code: "phase5-\(check)",
                    detail: "Required Phase 5 correctness check failed."
                ))
            }
            if result.accounting.duplicateBuilds != 0 {
                issues.append(.init(code: "phase5-duplicate-build", detail: "Observed duplicate build accounting."))
            }
            if result.accounting.droppedHookEvents != 0 {
                issues.append(.init(code: "phase5-hook-drop", detail: "Observed dropped coordinator hook events."))
            }
            if !result.accounting.terminalGaugesAreZero {
                issues.append(.init(code: "phase5-terminal-leak", detail: "A terminal flight/waiter/byte/hook gauge leaked."))
            }

            return WorkspaceCodeMapPhase5BenchmarkSample(
                ordinal: ordinal,
                phase: phase,
                wallValues: wallValues,
                throughputValues: throughputValues,
                accounting: result.accounting,
                maximumObservedFlightCount: result.maximumObservedFlightCount,
                maximumObservedWaiterCount: result.maximumObservedWaiterCount,
                maximumObservedConcurrentBuildCount: result.maximumObservedConcurrentBuildCount,
                peakRetainedSourceByteCount: result.peakRetainedSourceByteCount,
                foregroundQueuedCodemapWaiterCount: result.foregroundQueuedCodemapWaiterCount,
                foregroundIllegalGrantCount: result.foregroundIllegalGrantCount,
                correctnessChecks: result.checks,
                validityIssues: issues
            )
        }

        private func phase5ColdAndLookupMeasurements(
            ordinal: Int,
            wallValues: inout [WorkspaceCodeMapPhase5BenchmarkMetric: Double]
        ) async throws -> WorkspaceCodeMapPhase5ScenarioResult {
            let root = try phase5SecureRoot(label: "cold-\(ordinal)")
            defer { try? FileManager.default.removeItem(at: root) }
            let hooks = CodeMapArtifactBuildCoordinatorHooks { _ in }
            let constructionStart = DispatchTime.now()
            let runtime = try CodeMapArtifactRuntime(rootURL: root, coordinatorHooks: hooks)
            wallValues[.runtimeConstruction] = phase5ElapsedMS(constructionStart)
            let input = try phase5Input(phase5RealSwiftSource(ordinal), root: root, discriminator: ordinal, locator: true)

            let coldStart = DispatchTime.now()
            let cold = try await phase5Ready(runtime.coordinator.resolve(phase5Request(input)))
            wallValues[.coldSourceBuildPersistAndLocator] = phase5ElapsedMS(coldStart)
            wallValues[.buildQueueWait] = phase5Milliseconds(cold.durations.buildQueueNanoseconds)
            wallValues[.buildPermitWait] = phase5Milliseconds(cold.durations.buildPermitNanoseconds)
            wallValues[.deterministicBuild] = phase5Milliseconds(cold.durations.deterministicBuildNanoseconds)
            wallValues[.casPersistAndVerify] = phase5Milliseconds(
                cold.durations.casPersistenceAndVerificationNanoseconds
            )
            wallValues[.locatorPublication] = phase5Milliseconds(cold.durations.locatorPublicationNanoseconds)

            let residentStart = DispatchTime.now()
            let resident = try await phase5Ready(runtime.coordinator.resolve(.init(
                ownerID: UUID(),
                priority: .demand,
                target: .artifactKey(input.artifactKey)
            )))
            wallValues[.residentDirectHit] = phase5ElapsedMS(residentStart)

            let diskStore = try CodeMapArtifactStore(rootURL: root)
            let diskCoordinator = CodeMapArtifactBuildCoordinator(
                artifactStore: CodeMapArtifactStoreClient(store: diskStore),
                locatorStore: GitBlobCodeMapLocatorStoreClient(store: runtime.locatorStore)
            )
            let diskStart = DispatchTime.now()
            let disk = try await phase5Ready(diskCoordinator.resolve(.init(
                ownerID: UUID(),
                priority: .demand,
                target: .artifactKey(input.artifactKey)
            )))
            wallValues[.freshStoreDiskHit] = phase5ElapsedMS(diskStart)

            let locatorStore = try GitBlobCodeMapLocatorStore(rootURL: root)
            let locatorCAS = try CodeMapArtifactStore(rootURL: root)
            let locatorCoordinator = CodeMapArtifactBuildCoordinator(
                artifactStore: CodeMapArtifactStoreClient(store: locatorCAS),
                locatorStore: GitBlobCodeMapLocatorStoreClient(store: locatorStore)
            )
            let locatorStart = DispatchTime.now()
            let located = try await phase5Ready(locatorCoordinator.resolve(.init(
                ownerID: UUID(),
                priority: .demand,
                target: .locator(phase5Unwrap(input.locatorIdentity, "missing locator"))
            )))
            wallValues[.warmLocatorToCASHit] = phase5ElapsedMS(locatorStart)

            let coldAccounting = try await phase5DrainedAccounting(runtime.coordinator)
            let diskAccounting = try await phase5DrainedAccounting(diskCoordinator)
            let locatorAccounting = try await phase5DrainedAccounting(locatorCoordinator)
            var result = WorkspaceCodeMapPhase5ScenarioResult()
            result.accounting.add(coldAccounting)
            result.accounting.add(diskAccounting)
            result.accounting.add(locatorAccounting)
            result.checks["cold-build-publication"] = cold.casProvenance == .missBuilt
                && cold.buildProvenance == .performed
                && cold.casPublication == .inserted
                && cold.locatorLookup == .miss
                && cold.locatorPublication == .inserted
                && cold.handle.key == input.artifactKey
            result.checks["lookup-provenance"] = resident.casProvenance == .memoryHit
                && resident.buildProvenance == .notNeeded
                && disk.casProvenance == .diskHit
                && disk.locatorLookup == .notRequested
                && located.casProvenance == .diskHit
                && located.locatorLookup == .hit
                && located.buildProvenance == .notNeeded
            return result
        }

        private func phase5SameKeyFanOut(
            ordinal: Int,
            wallValues: inout [WorkspaceCodeMapPhase5BenchmarkMetric: Double],
            throughputValues: inout [WorkspaceCodeMapPhase5ThroughputMetric: Double]
        ) async throws -> WorkspaceCodeMapPhase5ScenarioResult {
            let root = try phase5SecureRoot(label: "fanout-\(ordinal)")
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = WorkspaceCodeMapPhase5Gate()
            let builds = WorkspaceCodeMapPhase5Counter()
            let runtime = try CodeMapArtifactRuntime(
                rootURL: root,
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                    await builds.increment()
                    await gate.enter()
                    return .readyNoSymbols
                }),
                coordinatorPolicy: phase5Policy(maximumConcurrentBuildCount: 1, maximumQueuedBuildCount: 8),
                coordinatorHooks: .init { _ in }
            )
            let input = try phase5Input("let fanOut\(ordinal) = \(ordinal)", root: root, discriminator: 1000 + ordinal)
            let start = DispatchTime.now()
            let first = Task { try await runtime.coordinator.resolve(phase5Request(input)) }
            await gate.waitUntilEntered()
            let joined = (0 ..< 7).map { _ in Task { try await runtime.coordinator.resolve(phase5Request(input)) } }
            try await phase5WaitUntil { await runtime.coordinator.accounting().waiterCount == 8 }
            let peak = await runtime.coordinator.accounting()
            await gate.release()
            var values = try await [first.value]
            for task in joined {
                try await values.append(task.value)
            }
            let elapsed = phase5ElapsedMS(start)
            wallValues[.sameKeyFanOutEight] = elapsed
            throughputValues[.fanOutWaitersPerSecond] = 8000 / max(elapsed, Double.leastNonzeroMagnitude)
            let resolutions = try values.map(phase5Ready)
            let accounting = try await phase5DrainedAccounting(runtime.coordinator)
            var result = WorkspaceCodeMapPhase5ScenarioResult()
            result.accounting.add(accounting)
            result.maximumObservedFlightCount = peak.activeFlightCount
            result.maximumObservedWaiterCount = peak.waiterCount
            result.peakRetainedSourceByteCount = peak.retainedInputByteCount
            result.checks["same-key-single-flight"] = await builds.value == 1
                && accounting.counters.buildsStarted == 1
                && accounting.counters.casInserted == 1
                && accounting.counters.joins == 7
                && resolutions.count(where: { $0.buildProvenance == .performed }) == 1
                && resolutions.count(where: { $0.buildProvenance == .joinedSharedBuild }) == 7
                && resolutions.count(where: \.joinedExistingFlight) == 7
            result.checks["retained-input-release"] = peak.retainedInputByteCount == input.source.rawByteCount
                && accounting.retainedInputByteCount == 0
                && accounting.counters.retainedInputReservations == 1
                && accounting.counters.retainedInputReleases == 1
            return result
        }

        private func phase5DistinctKeyThroughput(
            ordinal: Int,
            throughputValues: inout [WorkspaceCodeMapPhase5ThroughputMetric: Double]
        ) async throws -> WorkspaceCodeMapPhase5ScenarioResult {
            let root = try phase5SecureRoot(label: "distinct-\(ordinal)")
            defer { try? FileManager.default.removeItem(at: root) }
            let tracker = WorkspaceCodeMapPhase5ConcurrencyTracker()
            let runtime = try CodeMapArtifactRuntime(
                rootURL: root,
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                    await tracker.begin()
                    for _ in 0 ..< 100 {
                        await Task.yield()
                    }
                    await tracker.end()
                    return .readyNoSymbols
                }),
                coordinatorPolicy: phase5Policy(maximumConcurrentBuildCount: 2, maximumQueuedBuildCount: 8),
                coordinatorHooks: .init { _ in }
            )
            let inputs = try (0 ..< 8).map { index in
                try phase5Input(
                    "let distinct\(ordinal)_\(index) = \(index)",
                    root: root,
                    discriminator: 2000 + ordinal * 10 + index
                )
            }
            let start = DispatchTime.now()
            let tasks = inputs.map { input in Task { try await runtime.coordinator.resolve(phase5Request(input)) } }
            var resolutions: [CodeMapArtifactCoordinatorResolution] = []
            for task in tasks {
                try await resolutions.append(phase5Ready(task.value))
            }
            let elapsed = phase5ElapsedMS(start)
            throughputValues[.distinctKeyBuildsPerSecond] = 8000 / max(elapsed, Double.leastNonzeroMagnitude)
            let maximum = await tracker.maximum
            let accounting = try await phase5DrainedAccounting(runtime.coordinator)
            var result = WorkspaceCodeMapPhase5ScenarioResult()
            result.accounting.add(accounting)
            result.maximumObservedConcurrentBuildCount = maximum
            result.checks["distinct-key-bounds"] = resolutions.count == 8
                && resolutions.allSatisfy { $0.buildProvenance == .performed }
                && accounting.counters.buildsStarted == 8
                && accounting.counters.casInserted == 8
                && accounting.counters.duplicateBuilds == 0
                && maximum > 0
                && maximum <= 2
            return result
        }

        private func phase5BusyThenRetry(
            ordinal: Int,
            wallValues: inout [WorkspaceCodeMapPhase5BenchmarkMetric: Double]
        ) async throws -> WorkspaceCodeMapPhase5ScenarioResult {
            let root = try phase5SecureRoot(label: "busy-\(ordinal)")
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = WorkspaceCodeMapPhase5Gate()
            let runtime = try CodeMapArtifactRuntime(
                rootURL: root,
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                    await gate.enter()
                    return .readyNoSymbols
                }),
                coordinatorPolicy: phase5Policy(maximumConcurrentBuildCount: 1, maximumQueuedBuildCount: 1),
                coordinatorHooks: .init { _ in }
            )
            let inputs = try (0 ..< 3).map { index in
                try phase5Input(
                    "let busy\(ordinal)_\(index) = \(index)",
                    root: root,
                    discriminator: 3000 + ordinal * 10 + index
                )
            }
            let start = DispatchTime.now()
            let first = Task { try await runtime.coordinator.resolve(phase5Request(inputs[0])) }
            await gate.waitUntilEntered()
            let queued = Task { try await runtime.coordinator.resolve(phase5Request(inputs[1])) }
            try await phase5WaitUntil { await runtime.coordinator.accounting().queuedBuildCount == 1 }
            var busyPassed = false
            do {
                _ = try await runtime.coordinator.resolve(phase5Request(inputs[2]))
            } catch CodeMapArtifactBuildCoordinatorError.busy(retryAfterMilliseconds: 23) {
                busyPassed = true
            }
            await gate.release()
            _ = try await phase5Ready(first.value)
            _ = try await phase5Ready(queued.value)
            let retry = try await phase5Ready(runtime.coordinator.resolve(phase5Request(inputs[2])))
            wallValues[.boundedBusyThenRetry] = phase5ElapsedMS(start)
            let accounting = try await phase5DrainedAccounting(runtime.coordinator)
            var result = WorkspaceCodeMapPhase5ScenarioResult()
            result.accounting.add(accounting)
            result.checks["busy-retry"] = busyPassed
                && retry.buildProvenance == .performed
                && accounting.counters.busyRejections == 1
                && accounting.counters.buildsStarted == 3
                && accounting.counters.casInserted == 3
            return result
        }

        private func phase5TransientFailureThenRetry(
            ordinal: Int,
            wallValues: inout [WorkspaceCodeMapPhase5BenchmarkMetric: Double]
        ) async throws -> WorkspaceCodeMapPhase5ScenarioResult {
            let root = try phase5SecureRoot(label: "failure-\(ordinal)")
            defer { try? FileManager.default.removeItem(at: root) }
            let failure = WorkspaceCodeMapPhase5FailOnce()
            let runtime = try CodeMapArtifactRuntime(
                rootURL: root,
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                    if await failure.take() { throw WorkspaceCodeMapPhase5BenchmarkError.transient }
                    return .readyNoSymbols
                }),
                coordinatorHooks: .init { _ in }
            )
            let input = try phase5Input(
                "let failure\(ordinal) = \(ordinal)",
                root: root,
                discriminator: 4000 + ordinal
            )
            let start = DispatchTime.now()
            var firstFailed = false
            do {
                _ = try await runtime.coordinator.resolve(phase5Request(input))
            } catch WorkspaceCodeMapPhase5BenchmarkError.transient {
                firstFailed = true
            }
            let retry = try await phase5Ready(runtime.coordinator.resolve(phase5Request(input)))
            wallValues[.transientFailureThenRetry] = phase5ElapsedMS(start)
            let accounting = try await phase5DrainedAccounting(runtime.coordinator)
            var result = WorkspaceCodeMapPhase5ScenarioResult()
            result.accounting.add(accounting)
            result.checks["transient-failure-retry"] = firstFailed
                && retry.buildProvenance == .performed
                && accounting.counters.buildsStarted == 2
                && accounting.counters.buildsFailed == 1
                && accounting.counters.buildsSucceeded == 1
                && accounting.counters.casInserted == 1
            return result
        }

        private func phase5CancellationIsolation(
            ordinal: Int,
            wallValues: inout [WorkspaceCodeMapPhase5BenchmarkMetric: Double]
        ) async throws -> WorkspaceCodeMapPhase5ScenarioResult {
            let root = try phase5SecureRoot(label: "cancel-\(ordinal)")
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = WorkspaceCodeMapPhase5Gate()
            let runtime = try CodeMapArtifactRuntime(
                rootURL: root,
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                    await gate.enter()
                    return .readyNoSymbols
                }),
                coordinatorHooks: .init { _ in }
            )
            let input = try phase5Input(
                "let cancellation\(ordinal) = \(ordinal)",
                root: root,
                discriminator: 5000 + ordinal
            )
            let start = DispatchTime.now()
            let owner = Task { try await runtime.coordinator.resolve(phase5Request(input)) }
            await gate.waitUntilEntered()
            let cancelled = Task { try await runtime.coordinator.resolve(phase5Request(input)) }
            try await phase5WaitUntil { await runtime.coordinator.accounting().waiterCount == 2 }
            cancelled.cancel()
            var cancellationPassed = false
            do {
                _ = try await cancelled.value
            } catch is CancellationError {
                cancellationPassed = true
            }
            await gate.release()
            let ownerResolution = try await phase5Ready(owner.value)
            wallValues[.waiterCancellationIsolation] = phase5ElapsedMS(start)
            let accounting = try await phase5DrainedAccounting(runtime.coordinator)
            var result = WorkspaceCodeMapPhase5ScenarioResult()
            result.accounting.add(accounting)
            result.checks["waiter-cancellation-isolation"] = cancellationPassed
                && ownerResolution.buildProvenance == .performed
                && accounting.counters.waiterCancellations == 1
                && accounting.counters.lastWaiterCancellations == 0
                && accounting.counters.sharedTaskCancellations == 0
                && accounting.counters.buildsStarted == 1
                && accounting.counters.casInserted == 1
            return result
        }

        private func phase5ForegroundSuppression(
            ordinal: Int,
            wallValues: inout [WorkspaceCodeMapPhase5BenchmarkMetric: Double]
        ) async throws -> WorkspaceCodeMapPhase5ScenarioResult {
            let root = try phase5SecureRoot(label: "foreground-\(ordinal)")
            defer { try? FileManager.default.removeItem(at: root) }
            let limiter = ContentReadAsyncLimiter(capacity: 2, maxQueuedWaiterCount: 8)
            let builder = CodeMapArtifactBuilderClient(withPermit: { ownerID, priority, operation in
                try await limiter.withCodeMapArtifactBuildPermit(
                    ownerID: ownerID,
                    priority: priority,
                    operation: operation
                )
            })
            let runtime = try CodeMapArtifactRuntime(
                rootURL: root,
                builder: builder,
                coordinatorHooks: .init { _ in }
            )
            let input = try phase5Input(
                phase5RealSwiftSource(ordinal + 100),
                root: root,
                discriminator: 6000 + ordinal
            )
            let token = await limiter.beginForegroundActivity(kind: .rootLoad)
            let start = DispatchTime.now()
            let task = Task { try await runtime.coordinator.resolve(phase5Request(input)) }
            do {
                try await phase5WaitUntil {
                    let snapshot = await limiter.snapshotForTesting()
                    return snapshot.queuedCodemapWaiterCount == 1
                }
            } catch {
                await limiter.endForegroundActivity(token)
                task.cancel()
                throw error
            }
            let heldSnapshot = await limiter.snapshotForTesting()
            for _ in 0 ..< 100 {
                await Task.yield()
            }
            let heldAccounting = await runtime.coordinator.accounting()
            let stillHeldSnapshot = await limiter.snapshotForTesting()
            await limiter.endForegroundActivity(token)
            let resolution = try await phase5Ready(task.value)
            wallValues[.foregroundSuppressedAdmission] = phase5ElapsedMS(start)
            let releasedSnapshot = await limiter.snapshotForTesting()
            let accounting = try await phase5DrainedAccounting(runtime.coordinator)
            var result = WorkspaceCodeMapPhase5ScenarioResult()
            result.accounting.add(accounting)
            result.foregroundQueuedCodemapWaiterCount = heldSnapshot.queuedCodemapWaiterCount
            result.foregroundIllegalGrantCount = stillHeldSnapshot.codemapGrantWhileForegroundCount
            result.checks["foreground-suppression"] = heldSnapshot.foregroundActivityCount == 1
                && heldSnapshot.queuedCodemapWaiterCount == 1
                && heldSnapshot.activeCodemapPermitCount == 0
                && stillHeldSnapshot.codemapGrantWhileForegroundCount == 0
                && heldAccounting.counters.buildsSucceeded == 0
                && resolution.buildProvenance == .performed
                && releasedSnapshot.foregroundActivityCount == 0
                && releasedSnapshot.queuedCodemapWaiterCount == 0
                && releasedSnapshot.activeCodemapPermitCount == 0
            return result
        }

        private func phase5Policy(
            maximumConcurrentBuildCount: Int,
            maximumQueuedBuildCount: Int
        ) -> CodeMapArtifactBuildCoordinatorPolicy {
            CodeMapArtifactBuildCoordinatorPolicy(
                maximumFlightCount: 16,
                maximumTotalWaiterCount: 32,
                maximumWaitersPerFlight: 8,
                maximumQueuedBuildCount: maximumQueuedBuildCount,
                maximumConcurrentBuildCount: maximumConcurrentBuildCount,
                maximumLocatorIdentitiesPerFlight: 4,
                maximumRetainedInputByteCount: 8 * 1024 * 1024,
                maximumPendingHookEventCount: 1024,
                maximumConsecutiveDemandAdmissions: 2,
                agePromotionNanoseconds: 1_000_000_000,
                retryAfterMilliseconds: 23
            )
        }

        private func phase5Request(_ input: CodeMapArtifactBuildInput) -> CodeMapArtifactBuildRequest {
            CodeMapArtifactBuildRequest(ownerID: UUID(), priority: .demand, target: .source(input))
        }

        private func phase5Input(
            _ text: String,
            root: URL,
            discriminator: Int,
            locator: Bool = false
        ) throws -> CodeMapArtifactBuildInput {
            let bytes = Data(text.utf8)
            let fingerprint = FileContentFingerprint(
                deviceID: 5,
                fileNumber: UInt64(discriminator + 1),
                byteSize: Int64(bytes.count),
                modificationSeconds: 7,
                modificationNanoseconds: 0,
                statusChangeSeconds: 8,
                statusChangeNanoseconds: 0
            )
            let source = if locator {
                try WorkspaceCodemapValidatedSnapshotTestSupport.cleanSource(
                    bytes: bytes,
                    objectFormat: .sha1,
                    namespaceScope: root.path
                )
            } else {
                CodeMapSourceSnapshot(validatedContent: .init(
                    data: bytes,
                    modificationDate: fingerprint.modificationDate,
                    fingerprint: fingerprint
                ))
            }
            guard locator else { return try CodeMapArtifactBuildInput(source: source, language: .swift) }
            let pipeline = try SyntaxManager.shared.pipelineIdentity(for: .swift, decoderPolicy: source.decoderPolicy)
            guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
                throw WorkspaceCodeMapPhase5BenchmarkError.invalid("expected clean Git blob provenance")
            }
            let identity = GitBlobCodeMapLocatorIdentity(
                repositoryNamespace: repositoryNamespace,
                blobOID: blobOID,
                pipelineIdentity: pipeline
            )
            return try CodeMapArtifactBuildInput(
                source: source,
                language: .swift,
                locatorIdentity: identity
            )
        }

        private func phase5RealSwiftSource(_ ordinal: Int) -> String {
            (0 ..< 64).map { index in
                "struct Phase5_\(ordinal)_\(index) { let value: Int; func doubled() -> Int { value * 2 } }"
            }.joined(separator: "\n")
        }

        private func phase5Ready(
            _ result: CodeMapArtifactBuildCoordinatorResult
        ) throws -> CodeMapArtifactCoordinatorResolution {
            guard case let .ready(resolution) = result else {
                throw WorkspaceCodeMapPhase5BenchmarkError.invalid("expected ready result")
            }
            return resolution
        }

        private func phase5Unwrap<T>(_ value: T?, _ message: String) throws -> T {
            guard let value else { throw WorkspaceCodeMapPhase5BenchmarkError.invalid(message) }
            return value
        }

        private func phase5DrainedAccounting(
            _ coordinator: CodeMapArtifactBuildCoordinator
        ) async throws -> CodeMapArtifactBuildCoordinatorAccounting {
            for _ in 0 ..< 10000 {
                let accounting = await coordinator.accounting()
                if accounting.activeFlightCount == 0,
                   accounting.queuedBuildCount == 0,
                   accounting.activeBuildCount == 0,
                   accounting.waiterCount == 0,
                   accounting.retainedInputByteCount == 0,
                   accounting.pendingHookEventCount == 0,
                   !accounting.hookDispatcherIsDraining
                {
                    return accounting
                }
                await Task.yield()
            }
            throw WorkspaceCodeMapPhase5BenchmarkError.invalid("coordinator did not quiesce")
        }

        private func phase5WaitUntil(
            _ predicate: @escaping @Sendable () async -> Bool
        ) async throws {
            for _ in 0 ..< 10000 {
                if await predicate() { return }
                await Task.yield()
            }
            throw WorkspaceCodeMapPhase5BenchmarkError.invalid("condition not reached")
        }

        private func phase5SecureRoot(label: String) throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "RepoPrompt-Phase5-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directory.path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard let resolvedPath = directory.path.withCString({ pointer -> String? in
                guard let resolved = realpath(pointer, nil) else { return nil }
                defer { free(resolved) }
                return String(cString: resolved)
            }) else {
                throw WorkspaceCodeMapPhase5BenchmarkError.invalid("temporary root realpath failed")
            }
            return URL(fileURLWithPath: resolvedPath, isDirectory: true)
        }

        private func phase5ElapsedMS(_ start: DispatchTime) -> Double {
            workspaceFileSearchIndexElapsedMilliseconds(from: start, to: DispatchTime.now())
        }

        private func phase5Milliseconds(_ nanoseconds: UInt64) -> Double {
            Double(nanoseconds) / 1_000_000
        }
    }

    private extension WorkspaceCodeMapPhase5ScenarioResult {
        mutating func merge(_ other: Self) {
            accounting.requests += other.accounting.requests
            accounting.readyResults += other.accounting.readyResults
            accounting.busyRejections += other.accounting.busyRejections
            accounting.joins += other.accounting.joins
            accounting.waiterCancellations += other.accounting.waiterCancellations
            accounting.sharedTaskCancellations += other.accounting.sharedTaskCancellations
            accounting.casMemoryHits += other.accounting.casMemoryHits
            accounting.casDiskHits += other.accounting.casDiskHits
            accounting.locatorHits += other.accounting.locatorHits
            accounting.buildsStarted += other.accounting.buildsStarted
            accounting.buildsSucceeded += other.accounting.buildsSucceeded
            accounting.buildsFailed += other.accounting.buildsFailed
            accounting.casInserted += other.accounting.casInserted
            accounting.locatorInserted += other.accounting.locatorInserted
            accounting.duplicateBuilds += other.accounting.duplicateBuilds
            accounting.failures += other.accounting.failures
            accounting.droppedHookEvents += other.accounting.droppedHookEvents
            accounting.terminalActiveFlights += other.accounting.terminalActiveFlights
            accounting.terminalQueuedBuilds += other.accounting.terminalQueuedBuilds
            accounting.terminalActiveBuilds += other.accounting.terminalActiveBuilds
            accounting.terminalWaiters += other.accounting.terminalWaiters
            accounting.terminalRetainedInputBytes += other.accounting.terminalRetainedInputBytes
            accounting.terminalPendingHookEvents += other.accounting.terminalPendingHookEvents
            accounting.terminalHookDispatcherDraining = accounting.terminalHookDispatcherDraining
                || other.accounting.terminalHookDispatcherDraining
            accounting.livePositiveCount += other.accounting.livePositiveCount
            accounting.liveNegativeCount += other.accounting.liveNegativeCount
            accounting.residentPositiveCount += other.accounting.residentPositiveCount
            accounting.residentNegativeCount += other.accounting.residentNegativeCount
            accounting.residentPositiveBytes += other.accounting.residentPositiveBytes
            accounting.residentNegativeBytes += other.accounting.residentNegativeBytes
            maximumObservedFlightCount = max(maximumObservedFlightCount, other.maximumObservedFlightCount)
            maximumObservedWaiterCount = max(maximumObservedWaiterCount, other.maximumObservedWaiterCount)
            maximumObservedConcurrentBuildCount = max(
                maximumObservedConcurrentBuildCount,
                other.maximumObservedConcurrentBuildCount
            )
            peakRetainedSourceByteCount = max(peakRetainedSourceByteCount, other.peakRetainedSourceByteCount)
            foregroundQueuedCodemapWaiterCount = max(
                foregroundQueuedCodemapWaiterCount,
                other.foregroundQueuedCodemapWaiterCount
            )
            foregroundIllegalGrantCount += other.foregroundIllegalGrantCount
            checks.merge(other.checks) { _, new in new }
        }
    }

    private actor WorkspaceCodeMapPhase5Gate {
        private var enteredCount = 0
        private var released = false
        private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            enteredCount += 1
            let ready = entryWaiters.filter { $0.0 <= enteredCount }
            entryWaiters.removeAll { $0.0 <= enteredCount }
            ready.forEach { $0.1.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered(_ count: Int = 1) async {
            guard enteredCount < count else { return }
            await withCheckedContinuation { entryWaiters.append((count, $0)) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private actor WorkspaceCodeMapPhase5Counter {
        private(set) var value = 0
        func increment() {
            value += 1
        }
    }

    private actor WorkspaceCodeMapPhase5FailOnce {
        private var remaining = 1
        func take() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    private actor WorkspaceCodeMapPhase5ConcurrencyTracker {
        private var active = 0
        private(set) var maximum = 0
        func begin() {
            active += 1
            maximum = max(maximum, active)
        }

        func end() {
            active -= 1
        }
    }

    extension WorkspaceFileSearchIndexBenchmarkRun {
        func phase5CoordinatorDictionary() -> [String: Any] {
            [
                "scenario": WorkspaceCodeMapPhase5BenchmarkAggregate.scenario,
                "warmupSampleCount": 1,
                "measuredAttemptCount": phase5Coordinator.measured.count,
                "valid": phase5Coordinator.isValid,
                "servingMode": "explicit-benchmark-only; production coordinator remains inert and Phase 6 is not implemented",
                "prospectiveInvalidRunRules": [
                    "duplicate-build-or-wrong-provenance",
                    "leaked-flight-waiter-retained-byte-or-hook-task",
                    "failed-busy-retry-failure-retry-or-cancellation-isolation",
                    "build-admission-during-held-foreground-token",
                    "locator-or-CAS-validation-failure",
                    "missing-or-nonfinite-required-metric",
                    "wrong-sample-count-or-warmup-label",
                    "declared-overlapping-conductor-work",
                    "known-host-disturbance"
                ],
                "highCVInvalidatesRun": false,
                "wallMetricDefinitions": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase5BenchmarkMetric.allCases.map {
                    ($0.rawValue, $0.definition)
                }),
                "throughputMetricDefinitions": Dictionary(
                    uniqueKeysWithValues: WorkspaceCodeMapPhase5ThroughputMetric.allCases.map {
                        ($0.rawValue, $0.definition)
                    }
                ),
                "wallStatistics": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase5BenchmarkMetric.allCases.map {
                    ($0.rawValue, phase5MetricDictionary(phase5Coordinator.wallStatistics[$0]!))
                }),
                "throughputStatistics": Dictionary(
                    uniqueKeysWithValues: WorkspaceCodeMapPhase5ThroughputMetric.allCases.map {
                        ($0.rawValue, phase5MetricDictionary(phase5Coordinator.throughputStatistics[$0]!))
                    }
                ),
                "warmup": phase5SampleDictionary(phase5Coordinator.warmup),
                "measured": phase5Coordinator.measured.map(phase5SampleDictionary),
                "validityIssues": phase5Coordinator.validityIssues.map { ["code": $0.code, "detail": $0.detail] }
            ]
        }

        func phase5CoordinatorMarkdown() -> [String] {
            let aggregateValidity = phase5Coordinator.isValid ? "valid" : "INVALID — diagnostic only"
            var lines = [
                "",
                "## Phase 5 inert artifact build coordinator",
                "",
                "Phase 5 aggregate validity before top-level environment rules: \(aggregateValidity)  ",
                "Production serving remains unchanged. Every attempt uses fresh secure temporary roots and isolated runtimes/coordinators; runtime construction never calls the real process-wide singleton. One warmup is excluded and five measured attempts are retained.",
                "",
                "Prospective invalid-run rules: any duplicate build; wrong provenance; leaked flights, waiters, retained bytes, or hook tasks; failed busy/retry/cancellation behavior; build admission during a held foreground token; locator/CAS validation failure; missing/nonfinite data; wrong sample labels/counts; declared host overlap; or known disturbance. High CV and valid slow outliers are diagnostic and never automatically invalidate or remove a sample.",
                "",
                "Reliability: high when CV <= 10%, moderate when 10% < CV <= 20%, low when CV > 20%.",
                "",
                "| Wall metric | Boundary | N | Raw retained ms | Median ms | Nearest-rank p95 ms | CV | Outliers (Tukey) | Reliability |",
                "| --- | --- | ---: | --- | ---: | ---: | ---: | --- | --- |"
            ]
            for metric in WorkspaceCodeMapPhase5BenchmarkMetric.allCases {
                let aggregate = phase5Coordinator.wallStatistics[metric]!
                let distribution = aggregate.distribution
                let raw = distribution.map { phase5Values($0.rawValues) } ?? "unavailable"
                let median = distribution.map { phase5Number($0.median) } ?? "unavailable"
                let p95 = distribution.map { phase5Number($0.nearestRankP95) } ?? "unavailable"
                let cv = aggregate.coefficientOfVariation.map(phase5Percent) ?? "unavailable"
                let outliers = aggregate.outliers.isEmpty ? "none" : phase5Values(aggregate.outliers)
                lines.append(
                    "| \(metric.rawValue) | \(metric.definition) | \(aggregate.retainedSampleCount) | \(raw) | \(median) | \(p95) | \(cv) | \(outliers) | \(aggregate.reliability) |"
                )
            }
            lines.append(contentsOf: [
                "",
                "| Throughput metric | Definition | N | Raw retained /s | Median /s | Nearest-rank p95 /s | CV | Outliers (Tukey) | Reliability |",
                "| --- | --- | ---: | --- | ---: | ---: | ---: | --- | --- |"
            ])
            for metric in WorkspaceCodeMapPhase5ThroughputMetric.allCases {
                let aggregate = phase5Coordinator.throughputStatistics[metric]!
                let distribution = aggregate.distribution
                let raw = distribution.map { phase5Values($0.rawValues) } ?? "unavailable"
                let median = distribution.map { phase5Number($0.median) } ?? "unavailable"
                let p95 = distribution.map { phase5Number($0.nearestRankP95) } ?? "unavailable"
                let cv = aggregate.coefficientOfVariation.map(phase5Percent) ?? "unavailable"
                let outliers = aggregate.outliers.isEmpty ? "none" : phase5Values(aggregate.outliers)
                lines.append(
                    "| \(metric.rawValue) | \(metric.definition) | \(aggregate.retainedSampleCount) | \(raw) | \(median) | \(p95) | \(cv) | \(outliers) | \(aggregate.reliability) |"
                )
            }
            lines.append(contentsOf: [
                "",
                "| Phase | Sample | Joins | Busy | Cancels/shared cancels | Memory/disk/locator hits | Builds ok/failed/duplicate | CAS/locator inserts | Peak flights/waiters/builds | Peak/released source bytes | Hook drops | Resident +/- count/bytes | Foreground queued/illegal grants | Correctness | Validity |",
                "| --- | ---: | ---: | ---: | --- | --- | --- | --- | --- | --- | ---: | --- | --- | --- | --- |"
            ])
            for sample in [phase5Coordinator.warmup] + phase5Coordinator.measured {
                let a = sample.accounting
                let correctness = sample.correctnessPassed ? "pass" : "FAIL"
                let validity = sample.isValid ? "valid" : "INVALID"
                lines.append(
                    "| \(sample.phase) | \(sample.ordinal) | \(a.joins) | \(a.busyRejections) | \(a.waiterCancellations)/\(a.sharedTaskCancellations) | \(a.casMemoryHits)/\(a.casDiskHits)/\(a.locatorHits) | \(a.buildsSucceeded)/\(a.buildsFailed)/\(a.duplicateBuilds) | \(a.casInserted)/\(a.locatorInserted) | \(sample.maximumObservedFlightCount)/\(sample.maximumObservedWaiterCount)/\(sample.maximumObservedConcurrentBuildCount) | \(sample.peakRetainedSourceByteCount)/\(a.terminalRetainedInputBytes) | \(a.droppedHookEvents) | \(a.residentPositiveCount)/\(a.residentNegativeCount), \(a.residentPositiveBytes)/\(a.residentNegativeBytes) | \(sample.foregroundQueuedCodemapWaiterCount)/\(sample.foregroundIllegalGrantCount) | \(correctness) | \(validity) |"
                )
            }
            lines.append(contentsOf: [
                "",
                "Limitations: one host and DEBUG SwiftPM; real parsing is used for cold and foreground paths, while bounded concurrency/failure/cancellation controls use injected deterministic outcomes; OS filesystem caches are not purged; throughput is coordinator diagnostic throughput, not Phase 6 consumer throughput; no workspace consumer, manifest, watcher, checkout publication, fallback, dual write, production singleton initialization, or Phase 6 behavior is exercised."
            ])
            if !phase5Coordinator.validityIssues.isEmpty {
                lines.append(contentsOf: ["", "### Phase 5 invalid-run issues"])
                lines.append(contentsOf: phase5Coordinator.validityIssues.map { "- `\($0.code)`: \($0.detail)" })
            }
            return lines
        }

        private func phase5SampleDictionary(_ sample: WorkspaceCodeMapPhase5BenchmarkSample) -> [String: Any] {
            let a = sample.accounting
            return [
                "ordinal": sample.ordinal,
                "phase": sample.phase,
                "wallValues": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase5BenchmarkMetric.allCases.map {
                    ($0.rawValue, sample.wallValues[$0].map { $0 as Any } ?? NSNull())
                }),
                "throughputValues": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase5ThroughputMetric.allCases.map {
                    ($0.rawValue, sample.throughputValues[$0].map { $0 as Any } ?? NSNull())
                }),
                "accounting": [
                    "requests": a.requests,
                    "readyResults": a.readyResults,
                    "busyRejections": a.busyRejections,
                    "joins": a.joins,
                    "waiterCancellations": a.waiterCancellations,
                    "sharedTaskCancellations": a.sharedTaskCancellations,
                    "casMemoryHits": a.casMemoryHits,
                    "casDiskHits": a.casDiskHits,
                    "locatorHits": a.locatorHits,
                    "buildsStarted": a.buildsStarted,
                    "buildsSucceeded": a.buildsSucceeded,
                    "buildsFailed": a.buildsFailed,
                    "casInserted": a.casInserted,
                    "locatorInserted": a.locatorInserted,
                    "duplicateBuilds": a.duplicateBuilds,
                    "failures": a.failures,
                    "droppedHookEvents": a.droppedHookEvents,
                    "terminalActiveFlights": a.terminalActiveFlights,
                    "terminalQueuedBuilds": a.terminalQueuedBuilds,
                    "terminalActiveBuilds": a.terminalActiveBuilds,
                    "terminalWaiters": a.terminalWaiters,
                    "terminalRetainedInputBytes": a.terminalRetainedInputBytes,
                    "terminalPendingHookEvents": a.terminalPendingHookEvents,
                    "terminalHookDispatcherDraining": a.terminalHookDispatcherDraining,
                    "livePositiveCount": a.livePositiveCount,
                    "liveNegativeCount": a.liveNegativeCount,
                    "residentPositiveCount": a.residentPositiveCount,
                    "residentNegativeCount": a.residentNegativeCount,
                    "residentPositiveBytes": a.residentPositiveBytes,
                    "residentNegativeBytes": a.residentNegativeBytes
                ],
                "maximumObservedFlightCount": sample.maximumObservedFlightCount,
                "maximumObservedWaiterCount": sample.maximumObservedWaiterCount,
                "maximumObservedConcurrentBuildCount": sample.maximumObservedConcurrentBuildCount,
                "peakRetainedSourceByteCount": sample.peakRetainedSourceByteCount,
                "foregroundQueuedCodemapWaiterCount": sample.foregroundQueuedCodemapWaiterCount,
                "foregroundIllegalGrantCount": sample.foregroundIllegalGrantCount,
                "correctnessChecks": sample.correctnessChecks,
                "validityIssues": sample.validityIssues.map { ["code": $0.code, "detail": $0.detail] },
                "valid": sample.isValid
            ]
        }

        private func phase5MetricDictionary(_ aggregate: WorkspaceCodeMapPhase5MetricAggregate) -> [String: Any] {
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
                    "maximum": value.maximum,
                    "tukeyOutliers": aggregate.outliers
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

        private func phase5Values(_ values: [Double]) -> String {
            values.map(phase5Number).joined(separator: ", ")
        }

        private func phase5Number(_ value: Double) -> String {
            String(format: "%.6f", value)
        }

        private func phase5Percent(_ value: Double) -> String {
            String(format: "%.3f%%", value * 100)
        }
    }
#endif
