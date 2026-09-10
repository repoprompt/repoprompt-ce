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
