#if DEBUG
    import CryptoKit
    import Darwin
    import Foundation
    @testable import RepoPrompt

    enum WorkspaceCodeMapPhase4BenchmarkMetric: String, CaseIterable {
        case canonicalBatchClassification
        case linkedBatchClassification
        case eligibleRawReadAndShadowValidation
        case locatorColdMiss
        case locatorWrite
        case locatorWarmCrossWorktreeHit
        case deterministicInstabilityRetry

        var definition: String {
            switch self {
            case .canonicalBatchClassification:
                "fresh-service classification of one 256-path canonical-root batch through all Git subprocesses and validation tokens"
            case .linkedBatchClassification:
                "fresh-service classification of one 256-path linked-worktree batch through all Git subprocesses and validation tokens"
            case .eligibleRawReadAndShadowValidation:
                "secure descriptor reads, pre/post fingerprint checks, expected-byte comparisons, and exact Git blob digest validation for every OID-eligible result"
            case .locatorColdMiss:
                "first read of one canonical locator identity from a fresh empty temporary locator store"
            case .locatorWrite:
                "canonical locator association encode, atomic publication, fsync, and verification in the temporary store"
            case .locatorWarmCrossWorktreeHit:
                "fresh-store read using the independently derived linked-worktree identity after canonical publication; OS filesystem caches are not purged"
            case .deterministicInstabilityRetry:
                "single-path classification with atomic worktree mutation after both Git collection attempts, including the built-in retry"
            }
        }
    }

    enum WorkspaceCodeMapPhase4ThroughputMetric: String, CaseIterable {
        case canonicalFilesPerSecond
        case linkedFilesPerSecond
        case combinedClassificationFilesPerSecond
        case shadowValidatedBytesPerSecond

        var definition: String {
            switch self {
            case .canonicalFilesPerSecond:
                "256 canonical classifications divided by canonical batch latency"
            case .linkedFilesPerSecond:
                "256 linked-worktree classifications divided by linked batch latency"
            case .combinedClassificationFilesPerSecond:
                "512 classifications divided by the sum of canonical and linked batch latency"
            case .shadowValidatedBytesPerSecond:
                "securely read and digest-matched raw bytes divided by the shadow-validation span"
            }
        }
    }

    struct WorkspaceCodeMapPhase4IdentityOutcomeCounts: Equatable {
        let total: Int
        let oidEligible: Int
        let validatedWorktreeByReason: [String: Int]
        let unavailableByReason: [String: Int]
        let securityExcludedByReason: [String: Int]
        let unsupportedByReason: [String: Int]
        let batchFailure: String?

        init(batch: GitBlobIdentityBatch) {
            var oidEligible = 0
            var validated = Self.zeroValidatedWorktreeReasons
            var unavailable = Self.zeroUnavailableReasons
            var security = Self.zeroSecurityReasons
            var unsupported = Self.zeroUnsupportedReasons
            for classification in batch.classifications {
                switch classification.outcome {
                case .oidEligible:
                    oidEligible += 1
                case let .requiresValidatedWorktreeBytes(reason):
                    validated[reason.rawValue, default: 0] += 1
                case let .unavailable(reason):
                    unavailable[reason.rawValue, default: 0] += 1
                case let .securityExcluded(reason):
                    security[reason.rawValue, default: 0] += 1
                case let .unsupported(reason):
                    unsupported[reason.rawValue, default: 0] += 1
                }
            }
            total = batch.classifications.count
            self.oidEligible = oidEligible
            validatedWorktreeByReason = validated
            unavailableByReason = unavailable
            securityExcludedByReason = security
            unsupportedByReason = unsupported
            batchFailure = batch.failure?.localizedDescription
        }

        var validatedWorktreeTotal: Int {
            validatedWorktreeByReason.values.reduce(0, +)
        }

        var unavailableTotal: Int {
            unavailableByReason.values.reduce(0, +)
        }

        var securityExcludedTotal: Int {
            securityExcludedByReason.values.reduce(0, +)
        }

        var unsupportedTotal: Int {
            unsupportedByReason.values.reduce(0, +)
        }

        private static let zeroValidatedWorktreeReasons: [String: Int] = [
            GitBlobValidatedWorktreeReason.nonGit.rawValue: 0,
            GitBlobValidatedWorktreeReason.dirty.rawValue: 0,
            GitBlobValidatedWorktreeReason.stagedAndUnstaged.rawValue: 0,
            GitBlobValidatedWorktreeReason.untracked.rawValue: 0,
            GitBlobValidatedWorktreeReason.ignored.rawValue: 0,
            GitBlobValidatedWorktreeReason.intentToAdd.rawValue: 0,
            GitBlobValidatedWorktreeReason.unmerged.rawValue: 0,
            GitBlobValidatedWorktreeReason.indexFlag.rawValue: 0,
            GitBlobValidatedWorktreeReason.checkoutTransformation.rawValue: 0,
            GitBlobValidatedWorktreeReason.changedDuringClassification.rawValue: 0,
            GitBlobValidatedWorktreeReason.generatedOrExplicit.rawValue: 0
        ]

        private static let zeroUnavailableReasons: [String: Int] = [
            GitBlobUnavailableReason.missing.rawValue: 0,
            GitBlobUnavailableReason.sparseAbsent.rawValue: 0,
            GitBlobUnavailableReason.repositoryUnavailable.rawValue: 0
        ]

        private static let zeroSecurityReasons: [String: Int] = [
            GitBlobSecurityExclusionReason.symlinkLeaf.rawValue: 0,
            GitBlobSecurityExclusionReason.symlinkPathComponent.rawValue: 0
        ]

        private static let zeroUnsupportedReasons: [String: Int] = [
            GitBlobUnsupportedReason.gitlink.rawValue: 0,
            GitBlobUnsupportedReason.nonRegularFile.rawValue: 0,
            GitBlobUnsupportedReason.unsupportedGit.rawValue: 0,
            GitBlobUnsupportedReason.invalidPath.rawValue: 0,
            GitBlobUnsupportedReason.unknownIndexMode.rawValue: 0
        ]
    }

    struct WorkspaceCodeMapPhase4BenchmarkSample {
        static let requiredCorrectnessChecks = [
            "fixture-identity",
            "canonical-outcomes",
            "linked-outcomes",
            "shared-blob-opportunities",
            "raw-shadow-validation",
            "namespace-reuse",
            "locator-round-trip",
            "deterministic-retry"
        ]

        let ordinal: Int
        let phase: String
        let wallValues: [WorkspaceCodeMapPhase4BenchmarkMetric: Double]
        let throughputValues: [WorkspaceCodeMapPhase4ThroughputMetric: Double]
        let canonicalOutcomes: WorkspaceCodeMapPhase4IdentityOutcomeCounts
        let linkedOutcomes: WorkspaceCodeMapPhase4IdentityOutcomeCounts
        let oidEligibleOpportunityCount: Int
        let sameBlobOpportunityCount: Int
        let sameBlobOpportunityDenominator: Int
        let validatedRawFileCount: Int
        let validatedRawByteCount: UInt64
        let digestMatchCount: UInt64
        let digestMismatchCount: UInt64
        let canonicalLinkedNamespacesMatch: Bool
        let canonicalLinkedLocatorIdentitiesMatch: Bool
        let locatorColdMissPassed: Bool
        let locatorWritePassed: Bool
        let locatorWarmLinkedHitPassed: Bool
        let instabilityHookCallCount: Int
        let instabilityRetried: Bool
        let instabilityOutcome: String?
        let correctnessChecks: [String: Bool]
        let validityIssues: [WorkspaceBenchmarkValidityIssue]

        var isValid: Bool {
            validityIssues.isEmpty
        }

        var correctnessPassed: Bool {
            Self.requiredCorrectnessChecks.allSatisfy { correctnessChecks[$0] == true }
        }
    }

    struct WorkspaceCodeMapPhase4MetricAggregate {
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

    struct WorkspaceCodeMapPhase4BenchmarkAggregate {
        static let scenario = "phase4-explicit-git-identity-and-locator"

        let warmup: WorkspaceCodeMapPhase4BenchmarkSample
        let measured: [WorkspaceCodeMapPhase4BenchmarkSample]
        let wallStatistics: [WorkspaceCodeMapPhase4BenchmarkMetric: WorkspaceCodeMapPhase4MetricAggregate]
        let throughputStatistics: [WorkspaceCodeMapPhase4ThroughputMetric: WorkspaceCodeMapPhase4MetricAggregate]
        let validityIssues: [WorkspaceBenchmarkValidityIssue]

        init(
            warmup: WorkspaceCodeMapPhase4BenchmarkSample,
            measured: [WorkspaceCodeMapPhase4BenchmarkSample]
        ) {
            self.warmup = warmup
            self.measured = measured
            let attemptedCount = measured.count
            wallStatistics = Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase4BenchmarkMetric.allCases.map { metric in
                (
                    metric,
                    WorkspaceCodeMapPhase4MetricAggregate(
                        attemptedSampleCount: attemptedCount,
                        values: measured.compactMap { $0.wallValues[metric] }
                    )
                )
            })
            throughputStatistics = Dictionary(
                uniqueKeysWithValues: WorkspaceCodeMapPhase4ThroughputMetric.allCases.map { metric in
                    (
                        metric,
                        WorkspaceCodeMapPhase4MetricAggregate(
                            attemptedSampleCount: attemptedCount,
                            values: measured.compactMap { $0.throughputValues[metric] }
                        )
                    )
                }
            )

            var issues: [WorkspaceBenchmarkValidityIssue] = []
            if warmup.phase != "warmup-excluded" || warmup.ordinal != 0 {
                issues.append(.init(
                    code: "phase4-warmup-label",
                    detail: "Phase 4 requires exactly one ordinal-zero excluded warmup."
                ))
            }
            if measured.count != 5 {
                issues.append(.init(
                    code: "phase4-sample-count",
                    detail: "Expected five retained Phase 4 attempts; found \(measured.count)."
                ))
            }
            if measured.enumerated().contains(where: { index, sample in
                sample.phase != "measured" || sample.ordinal != index + 1
            }) {
                issues.append(.init(
                    code: "phase4-measured-labels",
                    detail: "Phase 4 measured attempts must be labeled measured with ordinals one through five."
                ))
            }
            for sample in [warmup] + measured where !sample.isValid {
                issues.append(.init(
                    code: "phase4-sample-invalid",
                    detail: "\(sample.phase) sample \(sample.ordinal) failed correctness or timing validity."
                ))
            }
            validityIssues = issues
        }

        var isValid: Bool {
            validityIssues.isEmpty
        }
    }

    private struct WorkspaceCodeMapPhase4ShadowResult {
        let fileCount: Int
        let byteCount: UInt64
        let matchCount: UInt64
        let mismatchCount: UInt64
        let expectedBytesMatched: Bool
        let fingerprintsStable: Bool
        let retainedBytes: Data?
    }

    private enum WorkspaceCodeMapPhase4BenchmarkError: Error {
        case invalidFixture(String)
    }

    private final class WorkspaceCodeMapPhase4BenchmarkFixture {
        static let cleanTrackedFileCount = 252
        static let stagedPath = "Controls/Staged.swift"
        static let dirtyPath = "Controls/Dirty.swift"
        static let untrackedPath = "Controls/Untracked.swift"
        static let ignoredPath = "Generated/Ignored.swift"
        static let instabilityPath = "Controls/Instability.swift"

        let repositoryFixture: ReviewGitRepositoryFixture
        let canonicalRoot: URL
        let linkedRoot: URL
        let classificationPaths: [String]
        let cleanPaths: [String]
        let canonicalExpectedBytes: [String: Data]
        let linkedExpectedBytes: [String: Data]
        let canonicalHead: String
        let linkedHead: String

        init(ordinal: Int) throws {
            let fixture = try ReviewGitRepositoryFixture(name: "WorkspaceCodeMapPhase4Benchmark-\(ordinal)")
            let clean = (0 ..< Self.cleanTrackedFileCount).map {
                String(format: "Sources/Tracked-%03d.swift", $0)
            }
            var files: [String: String] = [
                ".gitignore": "Generated/Ignored.swift\n",
                Self.stagedPath: "let staged = \(ordinal)\n",
                Self.dirtyPath: "let dirty = \(ordinal)\n",
                Self.instabilityPath: "let instability = \(ordinal)\n"
            ]
            for (index, path) in clean.enumerated() {
                files[path] = "let tracked\(index) = \(ordinal + index)\n"
            }
            let canonical = try fixture.makeRepository(named: "canonical", files: files)
            let linked = try fixture.makeLinkedWorktree(
                from: canonical,
                named: "linked",
                branch: "phase4-benchmark-\(ordinal)-\(UUID().uuidString)"
            )
            let stagedContents = "let staged = linked\(ordinal)\n"
            try fixture.write(stagedContents, to: Self.stagedPath, at: linked)
            try fixture.stage(Self.stagedPath, at: linked)
            try fixture.write("let dirty = linked\(ordinal)\n", to: Self.dirtyPath, at: linked)
            _ = try fixture.createUntrackedFile(
                "let untracked = \(ordinal)\n",
                at: Self.untrackedPath,
                root: linked
            )
            try fixture.write("let ignored = \(ordinal)\n", to: Self.ignoredPath, at: linked)

            repositoryFixture = fixture
            canonicalRoot = canonical
            linkedRoot = linked
            cleanPaths = clean
            classificationPaths = clean + [
                Self.stagedPath,
                Self.dirtyPath,
                Self.untrackedPath,
                Self.ignoredPath
            ]
            canonicalExpectedBytes = Dictionary(uniqueKeysWithValues: (clean + [
                Self.stagedPath,
                Self.dirtyPath
            ]).compactMap { path in
                files[path].map { (path, Data($0.utf8)) }
            })
            var linkedBytes = Dictionary(uniqueKeysWithValues: clean.compactMap { path in
                files[path].map { (path, Data($0.utf8)) }
            })
            linkedBytes[Self.stagedPath] = Data(stagedContents.utf8)
            linkedExpectedBytes = linkedBytes
            canonicalHead = try fixture.head(at: canonical)
            linkedHead = try fixture.head(at: linked)
        }
    }

    private actor WorkspaceCodeMapPhase4InstabilityMutator {
        private let fileURL: URL
        private var generation = 0
        private(set) var failed = false

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func mutate() {
            generation += 1
            do {
                try Data("let instability = mutation\(generation)\n".utf8).write(to: fileURL, options: .atomic)
            } catch {
                failed = true
            }
        }

        func snapshot() -> (callCount: Int, failed: Bool) {
            (generation, failed)
        }
    }

    extension WorkspaceFileSearchIndexTimeToReadyBenchmarkTests {
        func runPhase4GitIdentityLocatorScenario() async throws -> WorkspaceCodeMapPhase4BenchmarkAggregate {
            var warmup: WorkspaceCodeMapPhase4BenchmarkSample?
            var measured: [WorkspaceCodeMapPhase4BenchmarkSample] = []
            for sampleIndex in 0 ... 5 {
                let isWarmup = sampleIndex == 0
                let sample = await runPhase4GitIdentityLocatorSample(
                    ordinal: isWarmup ? 0 : sampleIndex,
                    phase: isWarmup ? "warmup-excluded" : "measured"
                )
                if isWarmup { warmup = sample }
                else { measured.append(sample) }
            }
            guard let warmup else {
                throw WorkspaceCodeMapPhase4BenchmarkError.invalidFixture("missing warmup")
            }
            return WorkspaceCodeMapPhase4BenchmarkAggregate(warmup: warmup, measured: measured)
        }

        private func runPhase4GitIdentityLocatorSample(
            ordinal: Int,
            phase: String
        ) async -> WorkspaceCodeMapPhase4BenchmarkSample {
            var wallValues: [WorkspaceCodeMapPhase4BenchmarkMetric: Double] = [:]
            var throughputValues: [WorkspaceCodeMapPhase4ThroughputMetric: Double] = [:]
            var canonicalOutcomes = WorkspaceCodeMapPhase4IdentityOutcomeCounts(
                batch: GitBlobIdentityBatch(objectFormat: nil, classifications: [], retriedAfterInstability: false)
            )
            var linkedOutcomes = canonicalOutcomes
            var oidEligibleOpportunityCount = 0
            var sameBlobOpportunityCount = 0
            var sameBlobOpportunityDenominator = 0
            var validatedRawFileCount = 0
            var validatedRawByteCount: UInt64 = 0
            var digestMatchCount: UInt64 = 0
            var digestMismatchCount: UInt64 = 0
            var canonicalLinkedNamespacesMatch = false
            var canonicalLinkedLocatorIdentitiesMatch = false
            var locatorColdMissPassed = false
            var locatorWritePassed = false
            var locatorWarmLinkedHitPassed = false
            var instabilityHookCallCount = 0
            var instabilityRetried = false
            var instabilityOutcome: String?
            var correctnessChecks: [String: Bool] = [:]
            var issues: [WorkspaceBenchmarkValidityIssue] = []

            func recordCheck(_ name: String, _ passed: Bool, _ detail: String) {
                correctnessChecks[name] = passed
                if !passed {
                    issues.append(.init(code: "phase4-\(name)", detail: detail))
                }
            }

            do {
                let fixture = try WorkspaceCodeMapPhase4BenchmarkFixture(ordinal: ordinal)
                let fixturePassed = fixture.canonicalHead == fixture.linkedHead
                    && fixture.classificationPaths.count == 256
                    && Set(fixture.classificationPaths).count == 256
                recordCheck(
                    "fixture-identity",
                    fixturePassed,
                    "Canonical/linked HEAD identity or the unique 256-path batch contract differed."
                )

                let canonicalService = GitBlobIdentityService()
                let linkedService = GitBlobIdentityService()
                let canonicalBatch: GitBlobIdentityBatch
                let linkedBatch: GitBlobIdentityBatch
                if ordinal.isMultiple(of: 2) {
                    (canonicalBatch, wallValues[.canonicalBatchClassification]) = await phase4Classify(
                        service: canonicalService,
                        root: fixture.canonicalRoot,
                        paths: fixture.classificationPaths
                    )
                    (linkedBatch, wallValues[.linkedBatchClassification]) = await phase4Classify(
                        service: linkedService,
                        root: fixture.linkedRoot,
                        paths: fixture.classificationPaths
                    )
                } else {
                    (linkedBatch, wallValues[.linkedBatchClassification]) = await phase4Classify(
                        service: linkedService,
                        root: fixture.linkedRoot,
                        paths: fixture.classificationPaths
                    )
                    (canonicalBatch, wallValues[.canonicalBatchClassification]) = await phase4Classify(
                        service: canonicalService,
                        root: fixture.canonicalRoot,
                        paths: fixture.classificationPaths
                    )
                }

                canonicalOutcomes = WorkspaceCodeMapPhase4IdentityOutcomeCounts(batch: canonicalBatch)
                linkedOutcomes = WorkspaceCodeMapPhase4IdentityOutcomeCounts(batch: linkedBatch)
                let commonBatchContract = canonicalBatch.objectFormat == .sha1
                    && linkedBatch.objectFormat == .sha1
                    && canonicalBatch.failure == nil
                    && linkedBatch.failure == nil
                    && !canonicalBatch.retriedAfterInstability
                    && !linkedBatch.retriedAfterInstability
                    && canonicalBatch.classifications.map(\.relativePath) == fixture.classificationPaths
                    && linkedBatch.classifications.map(\.relativePath) == fixture.classificationPaths
                let canonicalPassed = commonBatchContract
                    && canonicalOutcomes.total == 256
                    && canonicalOutcomes.oidEligible == 254
                    && canonicalOutcomes.validatedWorktreeTotal == 0
                    && canonicalOutcomes.unavailableByReason[GitBlobUnavailableReason.missing.rawValue] == 2
                    && canonicalOutcomes.unavailableTotal == 2
                    && canonicalOutcomes.securityExcludedTotal == 0
                    && canonicalOutcomes.unsupportedTotal == 0
                recordCheck(
                    "canonical-outcomes",
                    canonicalPassed,
                    "Canonical classification did not produce 254 OID-eligible and two missing outcomes."
                )
                let linkedPassed = commonBatchContract
                    && linkedOutcomes.total == 256
                    && linkedOutcomes.oidEligible == 253
                    && linkedOutcomes.validatedWorktreeByReason[GitBlobValidatedWorktreeReason.dirty.rawValue] == 1
                    && linkedOutcomes.validatedWorktreeByReason[GitBlobValidatedWorktreeReason.untracked.rawValue] == 1
                    && linkedOutcomes.validatedWorktreeByReason[GitBlobValidatedWorktreeReason.ignored.rawValue] == 1
                    && linkedOutcomes.validatedWorktreeTotal == 3
                    && linkedOutcomes.unavailableTotal == 0
                    && linkedOutcomes.securityExcludedTotal == 0
                    && linkedOutcomes.unsupportedTotal == 0
                recordCheck(
                    "linked-outcomes",
                    linkedPassed,
                    "Linked classification did not produce 253 OID-eligible plus dirty/untracked/ignored outcomes."
                )

                let canonicalByPath = Dictionary(
                    uniqueKeysWithValues: canonicalBatch.classifications.map { ($0.relativePath, $0) }
                )
                let linkedByPath = Dictionary(
                    uniqueKeysWithValues: linkedBatch.classifications.map { ($0.relativePath, $0) }
                )
                sameBlobOpportunityDenominator = fixture.cleanPaths.count
                sameBlobOpportunityCount = fixture.cleanPaths.reduce(into: 0) { count, path in
                    if phase4EligibleOID(canonicalByPath[path]) == phase4EligibleOID(linkedByPath[path]),
                       phase4EligibleOID(canonicalByPath[path]) != nil
                    {
                        count += 1
                    }
                }
                let stagedOIDsDiffer = phase4EligibleOID(canonicalByPath[WorkspaceCodeMapPhase4BenchmarkFixture.stagedPath]) != nil
                    && phase4EligibleOID(linkedByPath[WorkspaceCodeMapPhase4BenchmarkFixture.stagedPath]) != nil
                    && phase4EligibleOID(canonicalByPath[WorkspaceCodeMapPhase4BenchmarkFixture.stagedPath])
                    != phase4EligibleOID(linkedByPath[WorkspaceCodeMapPhase4BenchmarkFixture.stagedPath])
                recordCheck(
                    "shared-blob-opportunities",
                    sameBlobOpportunityCount == fixture.cleanPaths.count && stagedOIDsDiffer,
                    "Clean shared OIDs did not all match or the staged control did not diverge."
                )

                let shadowStart = DispatchTime.now()
                let canonicalShadow = try await phase4ShadowValidate(
                    service: canonicalService,
                    classifications: canonicalBatch.classifications,
                    root: fixture.canonicalRoot,
                    expectedBytes: fixture.canonicalExpectedBytes,
                    retaining: fixture.cleanPaths[0]
                )
                let linkedShadow = try await phase4ShadowValidate(
                    service: linkedService,
                    classifications: linkedBatch.classifications,
                    root: fixture.linkedRoot,
                    expectedBytes: fixture.linkedExpectedBytes,
                    retaining: nil
                )
                wallValues[.eligibleRawReadAndShadowValidation] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: shadowStart,
                    to: DispatchTime.now()
                )
                let canonicalDiagnostics = await canonicalService.shadowDiagnostics()
                let linkedDiagnostics = await linkedService.shadowDiagnostics()
                oidEligibleOpportunityCount = canonicalOutcomes.oidEligible + linkedOutcomes.oidEligible
                validatedRawFileCount = canonicalShadow.fileCount + linkedShadow.fileCount
                validatedRawByteCount = canonicalShadow.byteCount + linkedShadow.byteCount
                digestMatchCount = canonicalDiagnostics.digestMatchCount + linkedDiagnostics.digestMatchCount
                digestMismatchCount = canonicalDiagnostics.digestMismatchCount + linkedDiagnostics.digestMismatchCount
                let diagnosticsOpportunityCount = canonicalDiagnostics.eligibleOpportunityCount
                    + linkedDiagnostics.eligibleOpportunityCount
                recordCheck(
                    "raw-shadow-validation",
                    oidEligibleOpportunityCount == 507
                        && validatedRawFileCount == 507
                        && diagnosticsOpportunityCount == 507
                        && canonicalShadow.matchCount + linkedShadow.matchCount == 507
                        && canonicalShadow.mismatchCount + linkedShadow.mismatchCount == 0
                        && digestMatchCount == 507
                        && digestMismatchCount == 0
                        && canonicalShadow.expectedBytesMatched
                        && linkedShadow.expectedBytesMatched
                        && canonicalShadow.fingerprintsStable
                        && linkedShadow.fingerprintsStable,
                    "Secure raw-byte comparison or exact Git blob digest shadow validation differed."
                )

                guard let canonicalLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.canonicalRoot),
                      let linkedLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.linkedRoot),
                      let locatorBytes = canonicalShadow.retainedBytes,
                      let canonicalOID = phase4EligibleOID(canonicalByPath[fixture.cleanPaths[0]]),
                      let linkedOID = phase4EligibleOID(linkedByPath[fixture.cleanPaths[0]])
                else {
                    throw WorkspaceCodeMapPhase4BenchmarkError.invalidFixture("missing locator inputs")
                }
                let salt = Data(repeating: 0x44, count: GitBlobRepositoryNamespace.saltByteCount)
                let canonicalNamespace = try GitBlobRepositoryNamespace(
                    repositoryLayout: canonicalLayout,
                    salt: salt
                )
                let linkedNamespace = try GitBlobRepositoryNamespace(repositoryLayout: linkedLayout, salt: salt)
                canonicalLinkedNamespacesMatch = canonicalLayout.commonDir.standardizedFileURL
                    == linkedLayout.commonDir.standardizedFileURL
                    && canonicalNamespace == linkedNamespace
                let pipeline = try SyntaxManager().pipelineIdentity(
                    for: .swift,
                    decoderPolicy: .workspaceAutomaticV1
                )
                let canonicalLocatorIdentity = GitBlobCodeMapLocatorIdentity(
                    repositoryNamespace: canonicalNamespace,
                    blobOID: canonicalOID,
                    pipelineIdentity: pipeline
                )
                let linkedLocatorIdentity = GitBlobCodeMapLocatorIdentity(
                    repositoryNamespace: linkedNamespace,
                    blobOID: linkedOID,
                    pipelineIdentity: pipeline
                )
                canonicalLinkedLocatorIdentitiesMatch = canonicalLocatorIdentity == linkedLocatorIdentity
                recordCheck(
                    "namespace-reuse",
                    canonicalLinkedNamespacesMatch && canonicalLinkedLocatorIdentitiesMatch,
                    "Canonical and linked layouts did not derive the same namespace and locator identity."
                )

                let artifactKey = CodeMapArtifactKey(
                    rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: locatorBytes))),
                    rawByteCount: UInt64(locatorBytes.count),
                    pipelineIdentity: pipeline
                )
                let locatorRoot = try phase4SecureRoot(ordinal: ordinal)
                defer { try? FileManager.default.removeItem(at: locatorRoot) }
                let artifactStore = try CodeMapArtifactStore(rootURL: locatorRoot)
                _ = try await artifactStore.insert(
                    key: artifactKey,
                    deterministicOutcome: .readyNoSymbols
                )
                let verifiedHandle: CodeMapArtifactHandle
                switch try await artifactStore.lookup(key: artifactKey) {
                case let .hit(_, handle): verifiedHandle = handle
                case .miss:
                    throw WorkspaceCodeMapPhase4BenchmarkError.invalidFixture(
                        "CAS verification failed before locator publication."
                    )
                }
                let capabilityService = WorkspaceCodemapGitCapabilityService(
                    namespaceSalt: salt
                )
                let capabilityState = await capabilityService.resolve(
                    root: WorkspaceCodemapGitCapabilityRequest(
                        rootID: UUID(),
                        rootLifetimeID: UUID(),
                        loadedRootURL: fixture.canonicalRoot
                    )
                )
                guard case let .eligible(locatorCapability) = capabilityState else {
                    throw WorkspaceCodeMapPhase4BenchmarkError.invalidFixture(
                        "locator capability unavailable"
                    )
                }
                let validatedLocatorSource = try await GitBlobSourceMaterializationService(
                    client: GitBlobSourceMaterializationClient(
                        size: { _, _ in UInt64(locatorBytes.count) },
                        bytes: { _, _, _ in locatorBytes }
                    )
                ).materialize(
                    capability: locatorCapability,
                    blobOID: canonicalOID
                )
                let locatorSource = CodeMapSourceSnapshot(
                    validatedGitBlob: validatedLocatorSource
                )
                let verifiedAssociation = try VerifiedGitBlobCodeMapLocatorAssociation.verify(
                    source: locatorSource,
                    identity: canonicalLocatorIdentity,
                    artifactKey: artifactKey,
                    casHandle: verifiedHandle
                )
                let locatorStore = try GitBlobCodeMapLocatorStore(rootURL: locatorRoot)
                let coldStart = DispatchTime.now()
                let coldRead = try await locatorStore.read(identity: canonicalLocatorIdentity)
                wallValues[.locatorColdMiss] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: coldStart,
                    to: DispatchTime.now()
                )
                locatorColdMissPassed = coldRead == .miss
                let writeStart = DispatchTime.now()
                let write = try await locatorStore.write(association: verifiedAssociation)
                wallValues[.locatorWrite] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: writeStart,
                    to: DispatchTime.now()
                )
                locatorWritePassed = write == .inserted
                let linkedReader = try GitBlobCodeMapLocatorStore(rootURL: locatorRoot)
                let hitStart = DispatchTime.now()
                let linkedRead = try await linkedReader.read(identity: linkedLocatorIdentity)
                wallValues[.locatorWarmCrossWorktreeHit] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: hitStart,
                    to: DispatchTime.now()
                )
                locatorWarmLinkedHitPassed = linkedRead == .hit(artifactKey)
                recordCheck(
                    "locator-round-trip",
                    locatorColdMissPassed && locatorWritePassed && locatorWarmLinkedHitPassed,
                    "Locator did not complete cold miss, inserted write, and fresh-store linked-worktree hit."
                )

                let mutator = WorkspaceCodeMapPhase4InstabilityMutator(
                    fileURL: fixture.linkedRoot.appendingPathComponent(
                        WorkspaceCodeMapPhase4BenchmarkFixture.instabilityPath
                    )
                )
                let retryService = GitBlobIdentityService(hooks: GitBlobIdentityServiceHooks(
                    afterGitCollection: { await mutator.mutate() }
                ))
                let retryStart = DispatchTime.now()
                let retryBatch = await retryService.classify(
                    workspaceRoot: fixture.linkedRoot,
                    relativePaths: [WorkspaceCodeMapPhase4BenchmarkFixture.instabilityPath]
                )
                wallValues[.deterministicInstabilityRetry] = workspaceFileSearchIndexElapsedMilliseconds(
                    from: retryStart,
                    to: DispatchTime.now()
                )
                let mutatorSnapshot = await mutator.snapshot()
                instabilityHookCallCount = mutatorSnapshot.callCount
                instabilityRetried = retryBatch.retriedAfterInstability
                instabilityOutcome = retryBatch.classifications.first.map { phase4OutcomeLabel($0.outcome) }
                let retryPassed = !mutatorSnapshot.failed
                    && instabilityHookCallCount == 2
                    && instabilityRetried
                    && retryBatch.classifications.count == 1
                    && retryBatch.classifications.first?.outcome
                    == .requiresValidatedWorktreeBytes(.changedDuringClassification)
                    && retryBatch.classifications.first?.validationTokens.isStable == false
                recordCheck(
                    "deterministic-retry",
                    retryPassed,
                    "Deterministic two-attempt mutation did not retry and fail closed as changed-during-classification."
                )

                if let canonicalMS = wallValues[.canonicalBatchClassification], canonicalMS > 0 {
                    throughputValues[.canonicalFilesPerSecond] = Double(canonicalBatch.classifications.count)
                        * 1000 / canonicalMS
                }
                if let linkedMS = wallValues[.linkedBatchClassification], linkedMS > 0 {
                    throughputValues[.linkedFilesPerSecond] = Double(linkedBatch.classifications.count)
                        * 1000 / linkedMS
                }
                if let canonicalMS = wallValues[.canonicalBatchClassification],
                   let linkedMS = wallValues[.linkedBatchClassification],
                   canonicalMS + linkedMS > 0
                {
                    throughputValues[.combinedClassificationFilesPerSecond] = 512_000
                        / (canonicalMS + linkedMS)
                }
                if let shadowMS = wallValues[.eligibleRawReadAndShadowValidation], shadowMS > 0 {
                    throughputValues[.shadowValidatedBytesPerSecond] = Double(validatedRawByteCount)
                        * 1000 / shadowMS
                }
            } catch {
                issues.append(.init(code: "phase4-sample-error", detail: "Phase 4 sample failed: \(error)"))
            }

            for metric in WorkspaceCodeMapPhase4BenchmarkMetric.allCases {
                guard let value = wallValues[metric] else {
                    issues.append(.init(code: "phase4-missing-timing", detail: "\(metric.rawValue) is missing."))
                    continue
                }
                if !value.isFinite || value <= 0 {
                    issues.append(.init(code: "phase4-invalid-timing", detail: "\(metric.rawValue) is nonpositive or nonfinite."))
                }
            }
            for metric in WorkspaceCodeMapPhase4ThroughputMetric.allCases {
                guard let value = throughputValues[metric] else {
                    issues.append(.init(code: "phase4-missing-throughput", detail: "\(metric.rawValue) is missing."))
                    continue
                }
                if !value.isFinite || value <= 0 {
                    issues.append(.init(code: "phase4-invalid-throughput", detail: "\(metric.rawValue) is nonpositive or nonfinite."))
                }
            }
            for check in WorkspaceCodeMapPhase4BenchmarkSample.requiredCorrectnessChecks
                where correctnessChecks[check] == nil
            {
                issues.append(.init(code: "phase4-missing-correctness-check", detail: "\(check) did not execute."))
            }

            return WorkspaceCodeMapPhase4BenchmarkSample(
                ordinal: ordinal,
                phase: phase,
                wallValues: wallValues,
                throughputValues: throughputValues,
                canonicalOutcomes: canonicalOutcomes,
                linkedOutcomes: linkedOutcomes,
                oidEligibleOpportunityCount: oidEligibleOpportunityCount,
                sameBlobOpportunityCount: sameBlobOpportunityCount,
                sameBlobOpportunityDenominator: sameBlobOpportunityDenominator,
                validatedRawFileCount: validatedRawFileCount,
                validatedRawByteCount: validatedRawByteCount,
                digestMatchCount: digestMatchCount,
                digestMismatchCount: digestMismatchCount,
                canonicalLinkedNamespacesMatch: canonicalLinkedNamespacesMatch,
                canonicalLinkedLocatorIdentitiesMatch: canonicalLinkedLocatorIdentitiesMatch,
                locatorColdMissPassed: locatorColdMissPassed,
                locatorWritePassed: locatorWritePassed,
                locatorWarmLinkedHitPassed: locatorWarmLinkedHitPassed,
                instabilityHookCallCount: instabilityHookCallCount,
                instabilityRetried: instabilityRetried,
                instabilityOutcome: instabilityOutcome,
                correctnessChecks: correctnessChecks,
                validityIssues: issues
            )
        }

        private func phase4Classify(
            service: GitBlobIdentityService,
            root: URL,
            paths: [String]
        ) async -> (GitBlobIdentityBatch, Double) {
            let start = DispatchTime.now()
            let batch = await service.classify(workspaceRoot: root, relativePaths: paths)
            return (
                batch,
                workspaceFileSearchIndexElapsedMilliseconds(from: start, to: DispatchTime.now())
            )
        }

        private func phase4ShadowValidate(
            service: GitBlobIdentityService,
            classifications: [GitBlobIdentityClassification],
            root: URL,
            expectedBytes: [String: Data],
            retaining retainedPath: String?
        ) async throws -> WorkspaceCodeMapPhase4ShadowResult {
            var fileCount = 0
            var byteCount: UInt64 = 0
            var matchCount: UInt64 = 0
            var mismatchCount: UInt64 = 0
            var expectedBytesMatched = true
            var fingerprintsStable = true
            var retainedBytes: Data?
            for classification in classifications {
                guard case .oidEligible = classification.outcome else { continue }
                let path = root.appendingPathComponent(classification.relativePath).path
                let handle = try FileContentFingerprintReader.openReadOnlyFileHandle(atPath: path)
                defer { try? handle.close() }
                let before = try FileContentFingerprintReader.fingerprint(fileDescriptor: handle.fileDescriptor)
                let data = try handle.readToEnd() ?? Data()
                let after = try FileContentFingerprintReader.fingerprint(fileDescriptor: handle.fileDescriptor)
                fingerprintsStable = fingerprintsStable && before == after
                expectedBytesMatched = expectedBytesMatched && expectedBytes[classification.relativePath] == data
                fileCount += 1
                byteCount += UInt64(data.count)
                switch await service.shadowValidate(
                    classification: classification,
                    validatedWorktreeBytes: data
                ) {
                case .match:
                    matchCount += 1
                case .mismatch:
                    mismatchCount += 1
                case .notEligible:
                    expectedBytesMatched = false
                }
                if classification.relativePath == retainedPath {
                    retainedBytes = data
                }
            }
            return WorkspaceCodeMapPhase4ShadowResult(
                fileCount: fileCount,
                byteCount: byteCount,
                matchCount: matchCount,
                mismatchCount: mismatchCount,
                expectedBytesMatched: expectedBytesMatched,
                fingerprintsStable: fingerprintsStable,
                retainedBytes: retainedBytes
            )
        }

        private func phase4EligibleOID(_ classification: GitBlobIdentityClassification?) -> GitBlobOID? {
            guard case let .oidEligible(oid)? = classification?.outcome else { return nil }
            return oid
        }

        private func phase4OutcomeLabel(_ outcome: GitBlobIdentityOutcome) -> String {
            switch outcome {
            case let .oidEligible(oid): "oidEligible:\(oid.objectFormat.rawValue)"
            case let .requiresValidatedWorktreeBytes(reason): "validatedWorktree:\(reason.rawValue)"
            case let .unavailable(reason): "unavailable:\(reason.rawValue)"
            case let .securityExcluded(reason): "securityExcluded:\(reason.rawValue)"
            case let .unsupported(reason): "unsupported:\(reason.rawValue)"
            }
        }

        private func phase4SecureRoot(ordinal: Int) throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt-Phase4-Locator-\(ordinal)-\(UUID().uuidString)", isDirectory: true)
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
                throw WorkspaceCodeMapPhase4BenchmarkError.invalidFixture("locator realpath")
            }
            return URL(fileURLWithPath: resolvedPath, isDirectory: true)
        }
    }

    extension WorkspaceFileSearchIndexBenchmarkRun {
        func phase4GitIdentityLocatorDictionary() -> [String: Any] {
            [
                "scenario": WorkspaceCodeMapPhase4BenchmarkAggregate.scenario,
                "warmupSampleCount": 1,
                "measuredAttemptCount": phase4GitIdentityLocator.measured.count,
                "valid": phase4GitIdentityLocator.isValid,
                "servingMode": "explicit-benchmark-only; identity and locator remain inert and non-serving",
                "fixture": [
                    "pathsPerRoot": 256,
                    "cleanTrackedPaths": 252,
                    "expectedCanonicalOIDEligible": 254,
                    "expectedLinkedOIDEligible": 253,
                    "expectedCombinedOIDOpportunities": 507,
                    "expectedSameBlobOpportunities": 252
                ],
                "prospectiveInvalidRunRules": [
                    "build-or-test-failure",
                    "fixture-or-outcome-count-failure",
                    "raw-byte-or-digest-mismatch",
                    "namespace-or-locator-reuse-failure",
                    "deterministic-retry-failure",
                    "missing-or-nonfinite-required-metric",
                    "wrong-sample-count-or-warmup-label",
                    "declared-overlapping-conductor-work",
                    "known-host-disturbance"
                ],
                "wallMetricDefinitions": Dictionary(
                    uniqueKeysWithValues: WorkspaceCodeMapPhase4BenchmarkMetric.allCases.map {
                        ($0.rawValue, $0.definition)
                    }
                ),
                "throughputMetricDefinitions": Dictionary(
                    uniqueKeysWithValues: WorkspaceCodeMapPhase4ThroughputMetric.allCases.map {
                        ($0.rawValue, $0.definition)
                    }
                ),
                "wallStatistics": Dictionary(
                    uniqueKeysWithValues: WorkspaceCodeMapPhase4BenchmarkMetric.allCases.map { metric in
                        (metric.rawValue, phase4MetricDictionary(phase4GitIdentityLocator.wallStatistics[metric]!))
                    }
                ),
                "throughputStatistics": Dictionary(
                    uniqueKeysWithValues: WorkspaceCodeMapPhase4ThroughputMetric.allCases.map { metric in
                        (
                            metric.rawValue,
                            phase4MetricDictionary(phase4GitIdentityLocator.throughputStatistics[metric]!)
                        )
                    }
                ),
                "measuredTotals": phase4MeasuredTotals(),
                "warmup": phase4SampleDictionary(phase4GitIdentityLocator.warmup),
                "measured": phase4GitIdentityLocator.measured.map(phase4SampleDictionary),
                "validityIssues": phase4GitIdentityLocator.validityIssues.map {
                    ["code": $0.code, "detail": $0.detail]
                }
            ]
        }

        func phase4GitIdentityLocatorMarkdown() -> [String] {
            var lines = [
                "",
                "## Phase 4 inert Git blob identity and locator",
                "",
                "Phase 4 aggregate validity before top-level environment rules: \(phase4GitIdentityLocator.isValid ? "valid" : "INVALID — diagnostic only")  ",
                "Production serving remains unchanged. These timings call the inert identity/shadow-validation and locator APIs only, using fresh temporary repositories, linked worktrees, services, and locator roots. One warmup is excluded and five measured attempts are retained; valid slow outliers are never removed.",
                "",
                "Prospective invalid-run rules: build/test failure; wrong fixture identity or outcome counts; any raw-byte/digest mismatch; namespace/locator reuse failure; deterministic retry failure; missing/nonfinite required metric; wrong sample count or warmup labeling; declared overlapping conductor work; or known host disturbance. High CV alone is not invalid.",
                "",
                "Reliability: high when CV <= 10%, moderate when 10% < CV <= 20%, low when CV > 20%.",
                "",
                "| Wall metric | Exact measurement boundary | Attempted | Retained | Excluded | Raw retained ms | Median ms | Nearest-rank p95 ms | CV | Reliability |",
                "| --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |"
            ]
            for metric in WorkspaceCodeMapPhase4BenchmarkMetric.allCases {
                let aggregate = phase4GitIdentityLocator.wallStatistics[metric]!
                let distribution = aggregate.distribution
                lines.append(
                    "| \(metric.rawValue) | \(metric.definition) | \(aggregate.attemptedSampleCount) | \(aggregate.retainedSampleCount) | \(aggregate.excludedSampleCount) | \(distribution.map { phase4Values($0.rawValues) } ?? "unavailable") | \(distribution.map { phase4Number($0.median) } ?? "unavailable") | \(distribution.map { phase4Number($0.nearestRankP95) } ?? "unavailable") | \(aggregate.coefficientOfVariation.map(phase4Percent) ?? "unavailable") | \(aggregate.reliability) |"
                )
            }
            lines.append(contentsOf: [
                "",
                "| Throughput metric | Definition | N | Raw retained /s | Median /s | Nearest-rank p95 /s | CV | Reliability |",
                "| --- | --- | ---: | --- | ---: | ---: | ---: | --- |"
            ])
            for metric in WorkspaceCodeMapPhase4ThroughputMetric.allCases {
                let aggregate = phase4GitIdentityLocator.throughputStatistics[metric]!
                let distribution = aggregate.distribution
                lines.append(
                    "| \(metric.rawValue) | \(metric.definition) | \(aggregate.retainedSampleCount) | \(distribution.map { phase4Values($0.rawValues) } ?? "unavailable") | \(distribution.map { phase4Number($0.median) } ?? "unavailable") | \(distribution.map { phase4Number($0.nearestRankP95) } ?? "unavailable") | \(aggregate.coefficientOfVariation.map(phase4Percent) ?? "unavailable") | \(aggregate.reliability) |"
                )
            }
            lines.append(contentsOf: [
                "",
                "| Phase | Sample | Canonical OID/total | Linked OID/total | Combined eligibility | Same-blob opportunity | Raw files | Raw bytes | Digest match/mismatch | Namespace/identity reuse | Locator miss/write/hit | Retry calls/retried/outcome | Correctness | Validity |",
                "| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- | --- |"
            ])
            for sample in [phase4GitIdentityLocator.warmup] + phase4GitIdentityLocator.measured {
                let eligibilityRate = Double(sample.oidEligibleOpportunityCount) / 512
                let opportunityRate = sample.sameBlobOpportunityDenominator == 0
                    ? 0
                    : Double(sample.sameBlobOpportunityCount) / Double(sample.sameBlobOpportunityDenominator)
                lines.append(
                    "| \(sample.phase) | \(sample.ordinal) | \(sample.canonicalOutcomes.oidEligible)/\(sample.canonicalOutcomes.total) | \(sample.linkedOutcomes.oidEligible)/\(sample.linkedOutcomes.total) | \(sample.oidEligibleOpportunityCount)/512 (\(phase4Percent(eligibilityRate))) | \(sample.sameBlobOpportunityCount)/\(sample.sameBlobOpportunityDenominator) (\(phase4Percent(opportunityRate))) | \(sample.validatedRawFileCount) | \(sample.validatedRawByteCount) | \(sample.digestMatchCount)/\(sample.digestMismatchCount) | \(sample.canonicalLinkedNamespacesMatch ? "yes" : "NO")/\(sample.canonicalLinkedLocatorIdentitiesMatch ? "yes" : "NO") | \(sample.locatorColdMissPassed ? "pass" : "FAIL")/\(sample.locatorWritePassed ? "pass" : "FAIL")/\(sample.locatorWarmLinkedHitPassed ? "pass" : "FAIL") | \(sample.instabilityHookCallCount)/\(sample.instabilityRetried ? "yes" : "NO")/\(sample.instabilityOutcome ?? "unavailable") | \(sample.correctnessPassed ? "pass" : "FAIL") | \(sample.isValid ? "valid" : "INVALID") |"
                )
            }
            let totals = phase4MeasuredTotals()
            lines.append(contentsOf: [
                "",
                "Measured totals across this invocation's five retained attempts: \(totals["classifiedPathCount"] ?? 0) classifications; \(totals["oidEligibleOpportunityCount"] ?? 0) OID-eligible opportunities; \(totals["sameBlobOpportunityCount"] ?? 0) canonical/linked same-blob opportunities; \(totals["validatedRawFileCount"] ?? 0) raw files and \(totals["validatedRawByteCount"] ?? 0) bytes compared; \(totals["digestMatchCount"] ?? 0) digest matches and \(totals["digestMismatchCount"] ?? 0) mismatches; \(totals["locatorWarmLinkedHitCount"] ?? 0) linked-worktree locator hits; \(totals["retriedSampleCount"] ?? 0) deterministic retry samples.",
                "",
                "Outcome controls per measured sample: canonical 254 OID eligible plus two missing; linked 253 OID eligible plus one dirty, one untracked, and one ignored. The 252 clean tracked paths share exact OIDs across canonical and linked roots; a staged-only control remains eligible but uses a different index OID in the linked worktree.",
                "",
                "Limitations: one host and DEBUG SwiftPM; synthetic maximum-size 256-path SHA-1 batches; Git subprocess and actor-hop costs are included; service and repository fixtures are fresh but OS/Git caches are not purged; shadow timing includes secure reads and hashing; locator warm hit uses a fresh actor after publication but likely warm filesystem cache; the deterministic retry span includes two benchmark-controlled atomic writes; SHA-256 remains correctness-tested outside this timing fixture; no blob materialization, parsing, coordinator, manifest, workspace publication, production serving, or Phase 5 behavior is measured."
            ])
            if !phase4GitIdentityLocator.validityIssues.isEmpty {
                lines.append(contentsOf: ["", "### Phase 4 invalid-run issues"])
                lines.append(contentsOf: phase4GitIdentityLocator.validityIssues.map {
                    "- `\($0.code)`: \($0.detail)"
                })
                for sample in [phase4GitIdentityLocator.warmup] + phase4GitIdentityLocator.measured
                    where !sample.validityIssues.isEmpty
                {
                    lines.append("- \(sample.phase) sample \(sample.ordinal):")
                    lines.append(contentsOf: sample.validityIssues.map { "  - `\($0.code)`: \($0.detail)" })
                }
            }
            return lines
        }

        private func phase4SampleDictionary(_ sample: WorkspaceCodeMapPhase4BenchmarkSample) -> [String: Any] {
            [
                "ordinal": sample.ordinal,
                "phase": sample.phase,
                "wallValues": Dictionary(uniqueKeysWithValues: WorkspaceCodeMapPhase4BenchmarkMetric.allCases.map {
                    ($0.rawValue, sample.wallValues[$0].map { $0 as Any } ?? NSNull())
                }),
                "throughputValues": Dictionary(
                    uniqueKeysWithValues: WorkspaceCodeMapPhase4ThroughputMetric.allCases.map {
                        ($0.rawValue, sample.throughputValues[$0].map { $0 as Any } ?? NSNull())
                    }
                ),
                "canonicalOutcomes": phase4OutcomeDictionary(sample.canonicalOutcomes),
                "linkedOutcomes": phase4OutcomeDictionary(sample.linkedOutcomes),
                "oidEligibleOpportunityCount": sample.oidEligibleOpportunityCount,
                "sameBlobOpportunityCount": sample.sameBlobOpportunityCount,
                "sameBlobOpportunityDenominator": sample.sameBlobOpportunityDenominator,
                "validatedRawFileCount": sample.validatedRawFileCount,
                "validatedRawByteCount": sample.validatedRawByteCount,
                "digestMatchCount": sample.digestMatchCount,
                "digestMismatchCount": sample.digestMismatchCount,
                "canonicalLinkedNamespacesMatch": sample.canonicalLinkedNamespacesMatch,
                "canonicalLinkedLocatorIdentitiesMatch": sample.canonicalLinkedLocatorIdentitiesMatch,
                "locatorColdMissPassed": sample.locatorColdMissPassed,
                "locatorWritePassed": sample.locatorWritePassed,
                "locatorWarmLinkedHitPassed": sample.locatorWarmLinkedHitPassed,
                "instabilityHookCallCount": sample.instabilityHookCallCount,
                "instabilityRetried": sample.instabilityRetried,
                "instabilityOutcome": sample.instabilityOutcome.map { $0 as Any } ?? NSNull(),
                "correctnessChecks": sample.correctnessChecks,
                "validityIssues": sample.validityIssues.map { ["code": $0.code, "detail": $0.detail] },
                "valid": sample.isValid
            ]
        }

        private func phase4OutcomeDictionary(
            _ counts: WorkspaceCodeMapPhase4IdentityOutcomeCounts
        ) -> [String: Any] {
            [
                "total": counts.total,
                "oidEligible": counts.oidEligible,
                "validatedWorktreeByReason": counts.validatedWorktreeByReason,
                "unavailableByReason": counts.unavailableByReason,
                "securityExcludedByReason": counts.securityExcludedByReason,
                "unsupportedByReason": counts.unsupportedByReason,
                "batchFailure": counts.batchFailure.map { $0 as Any } ?? NSNull()
            ]
        }

        private func phase4MetricDictionary(_ aggregate: WorkspaceCodeMapPhase4MetricAggregate) -> [String: Any] {
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

        private func phase4MeasuredTotals() -> [String: UInt64] {
            let samples = phase4GitIdentityLocator.measured
            return [
                "classifiedPathCount": UInt64(samples.reduce(0) {
                    $0 + $1.canonicalOutcomes.total + $1.linkedOutcomes.total
                }),
                "oidEligibleOpportunityCount": UInt64(samples.reduce(0) { $0 + $1.oidEligibleOpportunityCount }),
                "sameBlobOpportunityCount": UInt64(samples.reduce(0) { $0 + $1.sameBlobOpportunityCount }),
                "validatedRawFileCount": UInt64(samples.reduce(0) { $0 + $1.validatedRawFileCount }),
                "validatedRawByteCount": samples.reduce(0) { $0 + $1.validatedRawByteCount },
                "digestMatchCount": samples.reduce(0) { $0 + $1.digestMatchCount },
                "digestMismatchCount": samples.reduce(0) { $0 + $1.digestMismatchCount },
                "locatorWarmLinkedHitCount": UInt64(samples.filter(\.locatorWarmLinkedHitPassed).count),
                "retriedSampleCount": UInt64(samples.filter(\.instabilityRetried).count)
            ]
        }

        private func phase4Values(_ values: [Double]) -> String {
            values.map(phase4Number).joined(separator: ", ")
        }

        private func phase4Number(_ value: Double) -> String {
            String(format: "%.6f", value)
        }

        private func phase4Percent(_ value: Double) -> String {
            String(format: "%.3f%%", value * 100)
        }
    }
#endif
