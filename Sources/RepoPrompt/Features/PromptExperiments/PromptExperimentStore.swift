#if DEBUG
    import Foundation

    struct PromptExperimentProjectionReport: Equatable {
        let failures: [String]

        static let success = Self(failures: [])

        var isDegraded: Bool {
            !failures.isEmpty
        }

        var message: String? {
            guard isDegraded else { return nil }
            return "Canonical experiment state is saved, but readable views need rebuilding: \(failures.joined(separator: "; "))"
        }
    }

    /// Canonical local persistence for the single-writer pilot.
    ///
    /// There is no general SQLite wrapper in the current application target. This bounded
    /// implementation therefore uses one versioned, atomically replaced JSON document as
    /// canonical authority. Result payloads are installed content-addressably before records
    /// reference them, and Markdown/JSON/CSV files are regenerated views, never authorities.
    actor PromptExperimentStore {
        enum StoreError: LocalizedError {
            case unsupportedSchema(Int)
            case corruptCanonicalDocument(String)
            case artifactDigestCollision
            case invalidArtifactReference
            case canonicalDocumentTooLarge(Int)

            var errorDescription: String? {
                switch self {
                case let .unsupportedSchema(version):
                    "Prompt Experiment storage schema \(version) is newer than this build supports. The store was not changed."
                case let .corruptCanonicalDocument(message):
                    "Prompt Experiment canonical storage is corrupt or unreadable: \(message)"
                case .artifactDigestCollision:
                    "A content-addressed artifact did not match its expected digest."
                case .invalidArtifactReference:
                    "The experiment evidence reference is outside the Prompt Experiment store."
                case let .canonicalDocumentTooLarge(bytes):
                    "Prompt Experiment canonical storage would exceed the 32 MiB limit (\(bytes) bytes); no state was committed."
                }
            }
        }

        private let fileManager: FileManager
        let rootURL: URL
        private let canonicalURL: URL
        private let artifactsURL: URL
        private let environmentsURL: URL
        private let recordsURL: URL
        private let beforeLoad: @Sendable () async -> Void
        private let beforeReadSyntheticFixture: @Sendable () async -> Void

        init(
            rootURL: URL,
            fileManager: FileManager = .default,
            beforeLoad: @escaping @Sendable () async -> Void = {},
            beforeReadSyntheticFixture: @escaping @Sendable () async -> Void = {}
        ) {
            self.rootURL = rootURL
            self.fileManager = fileManager
            self.beforeLoad = beforeLoad
            self.beforeReadSyntheticFixture = beforeReadSyntheticFixture
            canonicalURL = rootURL.appendingPathComponent("experiments.json", isDirectory: false)
            artifactsURL = rootURL.appendingPathComponent("artifacts/sha256", isDirectory: true)
            environmentsURL = rootURL.appendingPathComponent("environments", isDirectory: true)
            recordsURL = rootURL.appendingPathComponent("records", isDirectory: true)
        }

        static func liveRootURL() -> URL {
            MCPFilesystemConstants.identity.applicationSupportRootURL()
                .appendingPathComponent("Experiments/v1", isDirectory: true)
        }

        func loadRecords() async throws -> [PromptExperimentRecord] {
            await beforeLoad()
            try ensureDirectory(rootURL)
            guard fileManager.fileExists(atPath: canonicalURL.path) else { return [] }
            do {
                let data = try Data(contentsOf: canonicalURL, options: [.mappedIfSafe])
                guard data.count <= 32 * 1024 * 1024 else {
                    throw StoreError.corruptCanonicalDocument("the document exceeds the 32 MiB pilot limit")
                }
                let decoder = Self.makeDecoder()
                let document = try decoder.decode(PromptExperimentDocument.self, from: data)
                guard document.schemaVersion == PromptExperimentDocument.schemaVersion else {
                    throw StoreError.unsupportedSchema(document.schemaVersion)
                }
                return document.records
            } catch let error as StoreError {
                throw error
            } catch {
                throw StoreError.corruptCanonicalDocument(error.localizedDescription)
            }
        }

        /// Commits canonical authority first. Projection failures are returned separately and
        /// never make callers misclassify an already-committed approval or submission.
        func saveRecords(_ records: [PromptExperimentRecord]) throws -> PromptExperimentProjectionReport {
            try ensureDirectory(rootURL)
            let document = PromptExperimentDocument(records: records.sorted { $0.createdAt < $1.createdAt })
            let encoder = Self.makeEncoder(pretty: true)
            let data = try encoder.encode(document)
            guard data.count <= 32 * 1024 * 1024 else {
                throw StoreError.canonicalDocumentTooLarge(data.count)
            }
            try writeAtomically(data, to: canonicalURL)
            return rebuildReadableViews(records)
        }

        func rebuildReadableViews(_ records: [PromptExperimentRecord]) -> PromptExperimentProjectionReport {
            do {
                try ensureDirectory(recordsURL)
            } catch {
                return PromptExperimentProjectionReport(failures: [error.localizedDescription])
            }
            var failures: [String] = []
            for record in records {
                do {
                    try writeReadableViews(for: record)
                } catch {
                    failures.append("\(record.id.uuidString.lowercased()): \(error.localizedDescription)")
                }
            }
            return PromptExperimentProjectionReport(failures: failures)
        }

        /// Materializes a reviewed synthetic fixture under app support. Loaded-workspace
        /// sources are intentionally unsupported in the first pilot.
        func materializeSyntheticEnvironment(
            experimentID: UUID,
            planRevision: Int,
            fixtureText: String
        ) throws -> (rootURL: URL, fixture: PromptExperimentFixtureFile, digest: String) {
            try ensureDirectory(rootURL)
            try ensureDirectory(environmentsURL)
            let environmentRoot = environmentsURL
                .appendingPathComponent(experimentID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("revision-\(planRevision)", isDirectory: true)
            if fileManager.fileExists(atPath: environmentRoot.path) {
                try fileManager.removeItem(at: environmentRoot)
            }
            try ensureDirectory(environmentRoot)
            let fixtureURL = environmentRoot.appendingPathComponent("fixture.md", isDirectory: false)
            let data = Data(fixtureText.utf8)
            try writeAtomically(data, to: fixtureURL)
            let digest = PromptExperimentDigest.sha256(data)
            let fixture = PromptExperimentFixtureFile(
                path: fixtureURL.path,
                byteCount: data.count,
                sha256: digest
            )
            return (environmentRoot, fixture, digest)
        }

        /// Copies only explicitly reviewed regular files from a trusted loaded root into an
        /// app-owned immutable snapshot. The source root is never used as an execution cwd.
        func materializeOptimizationEnvironment(
            experimentID: UUID,
            planRevision: Int,
            project: PromptExperimentProjectSnapshotSpecification?,
            authorizedSourceRoots: [String]
        ) throws -> (rootURL: URL, files: [PromptExperimentFixtureFile], digest: String) {
            try ensureDirectory(rootURL)
            try ensureDirectory(environmentsURL)
            let environmentRoot = environmentsURL
                .appendingPathComponent(experimentID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("revision-\(planRevision)", isDirectory: true)
            if fileManager.fileExists(atPath: environmentRoot.path) {
                try fileManager.removeItem(at: environmentRoot)
            }
            try ensureDirectory(environmentRoot)

            var files: [PromptExperimentFixtureFile] = []
            let scopeData = Data("Inputs are supplied one at a time by the app. Expected outputs, reviewer notes, and held-out grading data are not stored in this runtime root.\n".utf8)
            let scopeURL = environmentRoot.appendingPathComponent("input-scope.md")
            try writeAtomically(scopeData, to: scopeURL)
            files.append(PromptExperimentFixtureFile(
                path: scopeURL.path,
                byteCount: scopeData.count,
                sha256: PromptExperimentDigest.sha256(scopeData)
            ))

            if let project {
                let sourceRoot = URL(fileURLWithPath: project.sourceRootPath).standardizedFileURL
                let resolvedSourceRoot = sourceRoot.resolvingSymlinksInPath()
                let authorized = authorizedSourceRoots.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                }
                guard authorized.contains(resolvedSourceRoot.path),
                      try sourceRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                      try sourceRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true
                else {
                    throw PromptExperimentAuthorityError.environmentUnavailable(
                        "The proposed project source root is not the Agent session's currently authorized loaded root."
                    )
                }
                var totalBytes = scopeData.count
                for relativePath in project.includedPaths.sorted() {
                    guard !relativePath.hasPrefix("/"),
                          !relativePath.split(separator: "/").contains(".."),
                          relativePath != "."
                    else { throw StoreError.invalidArtifactReference }
                    let source = sourceRoot.appendingPathComponent(relativePath).standardizedFileURL
                    let resolved = source.resolvingSymlinksInPath()
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard resolved.path.hasPrefix(resolvedSourceRoot.path + "/"),
                          values.isRegularFile == true,
                          values.isSymbolicLink != true
                    else {
                        throw PromptExperimentAuthorityError.environmentUnavailable(
                            "Reviewed project path ‘\(relativePath)’ is missing, non-regular, symbolic, or outside the authorized root."
                        )
                    }
                    let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                    totalBytes += data.count
                    guard data.count <= 2 * 1024 * 1024, totalBytes <= 8 * 1024 * 1024 else {
                        throw PromptExperimentAuthorityError.environmentUnavailable(
                            "Reviewed project snapshots are limited to 2 MiB per file and 8 MiB total."
                        )
                    }
                    let destination = environmentRoot
                        .appendingPathComponent("project", isDirectory: true)
                        .appendingPathComponent(relativePath, isDirectory: false)
                    try writeAtomically(data, to: destination)
                    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
                    files.append(PromptExperimentFixtureFile(
                        path: destination.path,
                        byteCount: data.count,
                        sha256: PromptExperimentDigest.sha256(data)
                    ))
                }
            }
            let digest = PromptExperimentDigest.environmentInventorySHA256(
                rootPath: environmentRoot.path,
                files: files
            )
            return (environmentRoot, files, digest)
        }

        func installArtifact(_ data: Data, fileExtension: String = "txt") throws -> PromptExperimentArtifactReference {
            try ensureDirectory(rootURL)
            try ensureDirectory(artifactsURL)
            let digest = PromptExperimentDigest.sha256(data)
            let shard = String(digest.prefix(2))
            let shardURL = artifactsURL.appendingPathComponent(shard, isDirectory: true)
            try ensureDirectory(shardURL)
            let filename = "\(digest).\(fileExtension)"
            let destination = shardURL.appendingPathComponent(filename, isDirectory: false)
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try Data(contentsOf: destination)
                guard PromptExperimentDigest.sha256(existing) == digest else {
                    throw StoreError.artifactDigestCollision
                }
            } else {
                try writeAtomically(data, to: destination)
            }
            return PromptExperimentArtifactReference(
                sha256: digest,
                relativePath: "artifacts/sha256/\(shard)/\(filename)",
                byteCount: data.count
            )
        }

        func readArtifact(_ reference: PromptExperimentArtifactReference) throws -> Data {
            guard !reference.relativePath.hasPrefix("/"),
                  !reference.relativePath.split(separator: "/").contains("..")
            else {
                throw StoreError.invalidArtifactReference
            }
            let url = rootURL.appendingPathComponent(reference.relativePath)
            let data = try Data(contentsOf: url)
            guard data.count == reference.byteCount,
                  PromptExperimentDigest.sha256(data) == reference.sha256
            else {
                throw StoreError.artifactDigestCollision
            }
            return data
        }

        func readSyntheticFixture(environment: PromptExperimentEnvironment) async throws -> String {
            await beforeReadSyntheticFixture()
            let rootPath = rootURL.standardizedFileURL.path
            let fixtureURL = URL(fileURLWithPath: environment.fixtureFiles.first?.path ?? "").standardizedFileURL
            guard fixtureURL.path.hasPrefix(rootPath + "/"),
                  fixtureURL.path.hasPrefix(URL(fileURLWithPath: environment.isolatedRootPath).standardizedFileURL.path + "/")
            else {
                throw StoreError.invalidArtifactReference
            }
            let data = try Data(contentsOf: fixtureURL)
            guard PromptExperimentDigest.sha256(data) == environment.fixtureDigest,
                  environment.fixtureFiles.first?.sha256 == environment.fixtureDigest
            else {
                throw StoreError.artifactDigestCollision
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw StoreError.corruptCanonicalDocument("the synthetic fixture is not UTF-8")
            }
            return text
        }

        func recordDirectoryURL(experimentID: UUID) throws -> URL {
            try ensureDirectory(rootURL)
            try ensureDirectory(recordsURL)
            return recordsURL.appendingPathComponent(experimentID.uuidString.lowercased(), isDirectory: true)
        }

        private func ensureDirectory(_ url: URL) throws {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        private func writeAtomically(_ data: Data, to url: URL) throws {
            try ensureDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        private func writeReadableViews(for record: PromptExperimentRecord) throws {
            let directory = recordsURL.appendingPathComponent(record.id.uuidString.lowercased(), isDirectory: true)
            try ensureDirectory(directory)
            try writeAtomically(Data(overviewMarkdown(record).utf8), to: directory.appendingPathComponent("overview.md"))
            if let plan = record.currentPlan {
                let data = try Self.makeEncoder(pretty: true).encode(plan)
                try writeAtomically(data, to: directory.appendingPathComponent("plan.json"))
            }
            for plan in record.plans {
                let data = try Self.makeEncoder(pretty: true).encode(plan)
                try writeAtomically(
                    data,
                    to: directory.appendingPathComponent("plan-revision-\(plan.revision).json")
                )
            }
            try writeAtomically(Data(resultsCSV(record).utf8), to: directory.appendingPathComponent("results.csv"))
        }

        private func overviewMarkdown(_ record: PromptExperimentRecord) -> String {
            var lines = [
                "# \(record.title)",
                "",
                "- Experiment: `\(record.id.uuidString.lowercased())`",
                "- Controller Agent session: `\(record.controllerSessionID.uuidString.lowercased())`",
                "- Phase: `\(record.phase.rawValue)`",
                "- Updated: \(Self.iso8601.string(from: record.updatedAt))",
                "- Status: \(record.statusMessage)"
            ]
            if let plan = record.currentPlan {
                lines += [
                    "- Current plan revision: \(plan.revision)",
                    "- Current plan digest: `\(plan.digest)`",
                    "- Runtime target: \(plan.resolvedTarget.displayName)",
                    "- Adapter: `\(plan.executionAdapter)`",
                    "- Comparison: `\(plan.comparisonMode)`",
                    "- Engine: `\(plan.optimization?.gepa.engine ?? "legacy-fixed")`",
                    "- GEPA upstream revision: `\(plan.optimization.map { _ in PromptExperimentGEPAConfiguration.pinnedRevision } ?? "not applicable")`",
                    "- Preserved plan revisions: \(record.plans.map { String($0.revision) }.joined(separator: ", "))",
                    "",
                    "## Pilot limitations"
                ]
                lines += plan.limitations.map { "- \($0)" }
                if let optimization = plan.optimization {
                    lines += [
                        "",
                        "## Sealed optimization authority",
                        "- Objective: \(Self.markdownInline(optimization.objective))",
                        "- Background: \(Self.markdownInline(optimization.background))",
                        "- Stage: \(optimization.isPreparation ? "Preparation (development evidence only)" : "GEPA search")",
                        "- Preparation candidates: \(optimization.preparationCandidates?.count ?? 0)",
                        "- Seed candidate: \(Self.markdownInline(optimization.seedCandidate ?? "GEPA bootstrap"))",
                        "- Reflection: \(plan.optimizationTargets?.reflection.displayName ?? "unavailable")",
                        "- Execution: `\(optimization.execution.adapter.rawValue)` / \(plan.optimizationTargets?.execution?.displayName ?? "no model target")",
                        "- Judge: \(plan.optimizationTargets?.judge?.displayName ?? "not used")",
                        "- Evaluator: `\(optimization.evaluator.kind.rawValue)` / \(optimization.evaluator.minimumScore)...\(optimization.evaluator.maximumScore)",
                        "- Rubric: \(Self.markdownInline(optimization.evaluator.rubric))",
                        "- Command: \(Self.markdownInline(optimization.evaluator.command ?? "not used"))",
                        "- Reviewed project root: `\(optimization.projectSnapshot?.sourceRootPath ?? "none")`",
                        "- Reviewed project paths: \(optimization.projectSnapshot?.includedPaths.joined(separator: ", ") ?? "none")",
                        "- Data splits: \(optimization.examples.map { "\($0.id)=\($0.split.rawValue)" }.joined(separator: ", "))",
                        "- Evaluation budget: \(optimization.gepa.maxEvaluations)",
                        "- Experiment wall-clock deadline: \(optimization.gepa.maxWallClockSeconds.map { "historic sealed limit of \($0) seconds" } ?? "none")",
                        "- GEPA options: minibatch \(optimization.gepa.reflectionMinibatchSize ?? 1), merge \((optimization.gepa.useMerge ?? false) ? "on" : "off"), max merge \(optimization.gepa.maxMergeInvocations ?? 0), skip perfect \((optimization.gepa.skipPerfectScore ?? true) ? "yes" : "no"), seed \(optimization.gepa.randomSeed)",
                        "- Python: `\(optimization.gepa.pythonExecutablePath)`",
                        "- Permissions: model callbacks are prompt-only; command evaluation reads only the immutable project copy and writes only app-owned scratch; hidden expected outputs remain native-host-private."
                    ]
                }
            }
            lines += ["", "## Attempts by immutable plan revision"]
            if record.attempts.isEmpty {
                lines.append("No attempts have been admitted.")
            } else {
                for attempt in record.attempts.sorted(by: {
                    ($0.planRevision ?? 0, $0.ordinal) < ($1.planRevision ?? 0, $1.ordinal)
                }) {
                    lines.append("- revision \(attempt.planRevision.map(String.init) ?? "legacy") / \(attempt.ordinal). \(attempt.condition.displayName) r\(attempt.repetition): `\(attempt.status.rawValue)` — \(attempt.statusText)")
                    if let handoff = attempt.committedHandoff {
                        lines.append("  - Committed prompt: `../../\(handoff.promptEvidence.relativePath)`")
                        lines.append("  - Prompt preview: \(Self.markdownInline(handoff.promptPreview))")
                        lines.append("  - Final selection revision: \(handoff.selectionRevision)")
                        lines.append("  - Final selected paths: \(handoff.selection.selectedPaths.isEmpty ? "none" : handoff.selection.selectedPaths.joined(separator: ", "))")
                        lines.append("  - Final slices: \(Self.selectionSlicesSummary(handoff.selection))")
                        lines.append("  - Agent output copied as prompt: \(handoff.usedAgentOutputAsPrompt ? "yes" : "no")")
                    } else if let reason = attempt.handoffUnavailableReason {
                        lines.append("  - Committed handoff: unavailable/inconclusive — \(reason)")
                    } else {
                        lines.append("  - Committed handoff: unavailable (legacy or unsettled attempt)")
                    }
                    if let assistantEvidence = attempt.assistantOutputEvidence {
                        lines.append("  - Assistant runtime output: `../../\(assistantEvidence.relativePath)`")
                        if let preview = attempt.assistantOutputPreview {
                            lines.append("  - Assistant output preview: \(Self.markdownInline(preview))")
                        }
                    }
                    if let legacyEvidence = attempt.evidence {
                        lines.append("  - Legacy unclassified evidence: `../../\(legacyEvidence.relativePath)`")
                    }
                    if let result = attempt.optimizationResult {
                        lines.append("  - GEPA upstream revision: `\(result.upstreamRevision)`")
                        lines.append("  - Assessment: \(Self.markdownInline(result.assessment))")
                        lines.append("  - Baseline score: \(result.baselineScore.map { String($0) } ?? "unavailable")")
                        lines.append("  - Best score: \(result.bestScore.map { String($0) } ?? "unavailable")")
                        lines.append("  - Evaluations: \(result.totalEvaluations)")
                        let wallTime = result.wallTimeSeconds.map { String(format: "%.3f", $0) } ?? "unavailable"
                        lines.append("  - GEPA wall time: \(wallTime) seconds")
                        lines.append("  - Proposer usage: \(result.proposerUsage)")
                        if let runDirectory = result.runDirectoryRelativePath {
                            lines.append("  - Worker artifacts and log: `../../\(runDirectory)`")
                        } else {
                            lines.append("  - Worker artifacts and log: unavailable")
                        }
                        if let rawResult = result.rawResultEvidence {
                            lines.append("  - Raw versioned result: `../../\(rawResult.relativePath)`")
                        }
                        lines.append("  - Candidates:")
                        for candidate in result.candidates {
                            let labels = [candidate.isBaseline ? "baseline" : nil, candidate.isBest ? "best" : nil]
                                .compactMap(\.self).joined(separator: ", ")
                            lines.append("    - #\(candidate.index) \(labels) score \(candidate.aggregateScore.map { String($0) } ?? "unavailable"): `../../\(candidate.candidateEvidence.relativePath)`")
                        }
                        lines.append("  - Evaluation feedback:")
                        for evaluation in result.evaluations {
                            let score = evaluation.score.map { String($0) } ?? "unavailable"
                            let failure = evaluation.failureKind.map { " / \($0.rawValue) failure" } ?? ""
                            lines.append("    - candidate #\(evaluation.candidateIndex), \(evaluation.exampleID) [\(evaluation.split.rawValue)]: \(score)\(failure) — \(Self.markdownInline(evaluation.feedback))")
                        }
                    }
                    if let diagnostics = attempt.diagnostics {
                        lines.append("  - Worker process observation: `\(diagnostics.processObservation.rawValue)` (persisted PID is historical evidence, not a liveness assertion)")
                        lines.append("  - Worker PID / identity: \(diagnostics.workerPID.map(String.init) ?? "unavailable") / \(Self.markdownInline(diagnostics.workerProcessIdentity ?? "unavailable"))")
                        lines.append("  - Worker start / exit / status: \(diagnostics.processStartedAt.map(Self.iso8601.string) ?? "unavailable") / \(diagnostics.processExitedAt.map(Self.iso8601.string) ?? "unavailable") / \(diagnostics.processExitStatus.map(String.init) ?? "unavailable")")
                        lines.append("  - Last observed event: `\(diagnostics.lastObservedEvent)` at \(Self.iso8601.string(from: diagnostics.lastObservedAt))")
                        lines.append("  - Active callback: \(diagnostics.activeCallbackID ?? "none") / \(diagnostics.activeCallbackOperation ?? "none")")
                        if let runtime = diagnostics.linkedCallbackRuntime {
                            lines.append("  - Linked callback runtime: `\(runtime.adapter)` / tab \(runtime.tabID?.uuidString ?? "unavailable") / run \(runtime.runID?.uuidString ?? "unavailable") / \(runtime.provider ?? "unavailable") / \(runtime.model ?? "unavailable")")
                        }
                        lines.append("  - Redacted stderr log: \(diagnostics.stderrLogRelativePath.map { "`../../\($0)`" } ?? "unavailable")")
                        lines.append("  - Payload-excluding protocol log: \(diagnostics.stdoutProtocolLogRelativePath.map { "`../../\($0)`" } ?? "unavailable")")
                        lines.append("  - Diagnostic log bytes: stderr \(diagnostics.stderrLogByteCount.map(String.init) ?? "unavailable") / stderr truncated \(diagnostics.stderrLogTruncated ? "yes" : "no") / protocol \(diagnostics.protocolLogByteCount.map(String.init) ?? "unavailable") / protocol truncated \(diagnostics.protocolLogTruncated ? "yes" : "no")")
                        lines.append("  - Recent diagnostic events:")
                        for event in diagnostics.eventTail {
                            lines.append("    - \(Self.iso8601.string(from: event.observedAt)) `\(event.channel)/\(event.event)` \(Self.markdownInline(event.detail ?? ""))")
                        }
                    }
                    if let elapsed = Self.elapsedSeconds(attempt) {
                        lines.append("  - Elapsed: \(String(format: "%.3f", elapsed)) seconds")
                    } else {
                        lines.append("  - Elapsed: unavailable")
                    }
                    lines.append("  - Provider token usage: unavailable from the Context Builder completion contract")
                }
            }
            lines += [
                "",
                "> Generated view. `experiments.json` and referenced content-addressed artifacts are canonical. Editing this file does not change experiment state.",
                ""
            ]
            return lines.joined(separator: "\n")
        }

        private func resultsCSV(_ record: PromptExperimentRecord) -> String {
            var rows = ["plan_revision,plan_id,plan_digest,ordinal,condition,repetition,status,tab_id,run_id,committed_prompt_sha256,assistant_output_sha256,selection_revision,selected_paths,slices,elapsed_seconds,usage,error"]
            let attempts = record.attempts.sorted {
                ($0.planRevision ?? 0, $0.ordinal) < ($1.planRevision ?? 0, $1.ordinal)
            }
            for attempt in attempts {
                let selectionRevision = attempt.committedHandoff.map { String($0.selectionRevision) } ?? ""
                let selectedPaths = attempt.committedHandoff?.selection.selectedPaths.joined(separator: "\n") ?? ""
                let slices = attempt.committedHandoff.map { Self.selectionSlicesSummary($0.selection) } ?? ""
                let elapsed = Self.elapsedSeconds(attempt).map { String(format: "%.3f", $0) } ?? ""
                let fields: [String] = [
                    attempt.planRevision.map(String.init) ?? "",
                    attempt.planID?.uuidString ?? "",
                    attempt.planDigest ?? "",
                    String(attempt.ordinal),
                    attempt.condition.rawValue,
                    String(attempt.repetition),
                    attempt.status.rawValue,
                    attempt.runtimeLink?.tabID?.uuidString ?? "",
                    attempt.runtimeLink?.runID?.uuidString ?? "",
                    attempt.committedHandoff?.promptEvidence.sha256 ?? "",
                    attempt.assistantOutputEvidence?.sha256 ?? "",
                    selectionRevision,
                    selectedPaths,
                    slices,
                    elapsed,
                    "unavailable_from_context_builder_completion_contract",
                    attempt.error ?? ""
                ]
                rows.append(fields.map(Self.csvField).joined(separator: ","))
            }
            rows.append("")
            return rows.joined(separator: "\n")
        }

        private static func elapsedSeconds(_ attempt: PromptExperimentAttempt) -> TimeInterval? {
            guard let submittedAt = attempt.submittedAt,
                  let settledAt = attempt.settledAt else { return nil }
            return max(0, settledAt.timeIntervalSince(submittedAt))
        }

        private static func selectionSlicesSummary(_ selection: StoredSelection) -> String {
            guard !selection.slices.isEmpty else { return "none" }
            return selection.slices.keys.sorted().map { path in
                let ranges = selection.slices[path, default: []].map { range in
                    var value = "\(range.start)-\(range.end)"
                    if let description = range.description, !description.isEmpty {
                        value += " (\(description))"
                    }
                    return value
                }.joined(separator: ", ")
                return "\(path): \(ranges)"
            }.joined(separator: "; ")
        }

        private static func markdownInline(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\n", with: " ↩ ")
                .replacingOccurrences(of: "`", with: "\\`")
        }

        private static func csvField(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        private static func makeEncoder(pretty: Bool) -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = pretty
                ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                : [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }

        private static func makeDecoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return decoder
        }

        private static let iso8601 = ISO8601DateFormatter()
    }
#endif
