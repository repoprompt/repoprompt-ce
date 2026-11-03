#if DEBUG
    import Foundation

    struct PromptExperimentProjectionReport: Equatable {
        let failures: [String]

        static let success = Self(failures: [])

        var message: String? {
            guard !failures.isEmpty else { return nil }
            return "Canonical experiment state is saved, but readable views need rebuilding: \(failures.joined(separator: "; "))"
        }
    }

    struct PromptExperimentStoreLoadResult: Equatable {
        let experiments: [PromptExperiment]
        /// An earlier lab schema was found and discarded (records, runs, and artifacts).
        let discardedLegacyLabData: Bool
    }

    /// Canonical persistence for the lab. The service is its single writer.
    ///
    /// One versioned, atomically replaced JSON document is canonical authority. Result payloads
    /// are installed content-addressably before records reference them; Markdown views are
    /// regenerated projections, never authorities. Documents from earlier lab schemas are
    /// discarded deterministically rather than decoded or migrated.
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

        private struct SchemaHeader: Decodable {
            let schemaVersion: Int?
        }

        static let maximumDocumentBytes = 32 * 1024 * 1024

        private let fileManager: FileManager
        let rootURL: URL
        private let canonicalURL: URL
        private let artifactsURL: URL
        private let recordsURL: URL

        init(rootURL: URL, fileManager: FileManager = .default) {
            self.rootURL = rootURL
            self.fileManager = fileManager
            canonicalURL = rootURL.appendingPathComponent("experiments.json", isDirectory: false)
            artifactsURL = rootURL.appendingPathComponent("artifacts/sha256", isDirectory: true)
            recordsURL = rootURL.appendingPathComponent("records", isDirectory: true)
        }

        static func liveRootURL() -> URL {
            MCPFilesystemConstants.identity.applicationSupportRootURL()
                .appendingPathComponent("Experiments/v1", isDirectory: true)
        }

        func load() throws -> PromptExperimentStoreLoadResult {
            try ensureDirectory(rootURL)
            guard fileManager.fileExists(atPath: canonicalURL.path) else {
                return PromptExperimentStoreLoadResult(experiments: [], discardedLegacyLabData: false)
            }
            let data: Data
            do {
                data = try Data(contentsOf: canonicalURL, options: [.mappedIfSafe])
            } catch {
                throw StoreError.corruptCanonicalDocument(error.localizedDescription)
            }
            guard data.count <= Self.maximumDocumentBytes else {
                throw StoreError.corruptCanonicalDocument("the document exceeds the 32 MiB limit")
            }
            let decoder = Self.makeDecoder()
            guard let header = try? decoder.decode(SchemaHeader.self, from: data) else {
                throw StoreError.corruptCanonicalDocument("the document is not a JSON object")
            }
            let version = header.schemaVersion ?? 0
            guard version <= PromptExperimentDocument.schemaVersion else {
                throw StoreError.unsupportedSchema(version)
            }
            guard version == PromptExperimentDocument.schemaVersion else {
                try discardLegacyLabData()
                return PromptExperimentStoreLoadResult(experiments: [], discardedLegacyLabData: true)
            }
            do {
                let document = try decoder.decode(PromptExperimentDocument.self, from: data)
                return PromptExperimentStoreLoadResult(experiments: document.experiments, discardedLegacyLabData: false)
            } catch {
                throw StoreError.corruptCanonicalDocument(error.localizedDescription)
            }
        }

        /// Commits canonical authority first; projection failures are reported separately and
        /// never undo an already committed approval, admission, or evidence write.
        func save(_ experiments: [PromptExperiment], projecting projected: Set<UUID> = []) throws -> PromptExperimentProjectionReport {
            try ensureDirectory(rootURL)
            let document = PromptExperimentDocument(experiments: experiments.sorted { $0.createdAt < $1.createdAt })
            let data = try Self.makeEncoder(pretty: true).encode(document)
            guard data.count <= Self.maximumDocumentBytes else {
                throw StoreError.canonicalDocumentTooLarge(data.count)
            }
            try writeAtomically(data, to: canonicalURL)
            return rebuildReadableViews(experiments.filter { projected.contains($0.id) })
        }

        func rebuildReadableViews(_ experiments: [PromptExperiment]) -> PromptExperimentProjectionReport {
            var failures: [String] = []
            for experiment in experiments {
                do {
                    let directory = recordsURL.appendingPathComponent(experiment.id.uuidString.lowercased(), isDirectory: true)
                    try writeAtomically(Data(Self.overviewMarkdown(experiment).utf8), to: directory.appendingPathComponent("overview.md"))
                } catch {
                    failures.append("\(experiment.id.uuidString.lowercased()): \(error.localizedDescription)")
                }
            }
            return PromptExperimentProjectionReport(failures: failures)
        }

        func installArtifact(_ data: Data, fileExtension: String = "txt") throws -> PromptExperimentArtifactReference {
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
            let data = try Data(contentsOf: rootURL.appendingPathComponent(reference.relativePath))
            guard data.count == reference.byteCount,
                  PromptExperimentDigest.sha256(data) == reference.sha256
            else {
                throw StoreError.artifactDigestCollision
            }
            return data
        }

        func recordDirectoryURL(experimentID: UUID) -> URL {
            recordsURL.appendingPathComponent(experimentID.uuidString.lowercased(), isDirectory: true)
        }

        /// Removes every lab record, run directory, projection, and artifact under the store
        /// root, then commits an empty current-schema document.
        private func discardLegacyLabData() throws {
            for child in try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
                try fileManager.removeItem(at: child)
            }
            let data = try Self.makeEncoder(pretty: true).encode(PromptExperimentDocument(experiments: []))
            try writeAtomically(data, to: canonicalURL)
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

        static func overviewMarkdown(_ experiment: PromptExperiment) -> String {
            let authority = experiment.authority
            var lines = [
                "# \(experiment.title)",
                "",
                "- Experiment: `\(experiment.id.uuidString.lowercased())`",
                "- Status: `\(experiment.status.rawValue)`",
                "- Built-in prompt: `\(authority.promptIdentifier)` (resource `\(authority.promptResourceSHA256)`)",
                "- Suite: `\(authority.suiteID)` (`\(authority.suiteSHA256)`)",
                "- Targets: execution \(authority.targets.execution.displayName); reflection \(authority.targets.reflection.displayName); judge \(authority.targets.judge?.displayName ?? "not used")",
                "- Approved cap: \(authority.maxEvaluations) evaluations; used \(experiment.admissionsUsed); remaining \(experiment.remainingEvaluations)",
                "- Baseline calibration line: up to \(authority.calibrationEvaluations) evaluations; used \(experiment.calibrationAdmissionsUsed)",
                "- Authority digest: `\(experiment.authorityDigest)`",
                "- Approval: \(experiment.approval.map { "native, \(iso8601.string(from: $0.approvedAt))" } ?? "not approved")",
                "",
                "## Runs"
            ]
            if experiment.runs.isEmpty { lines.append("No runs yet.") }
            for run in experiment.runs {
                lines.append("- Run \(run.ordinal): `\(run.state.rawValue)` — \(markdownInline(run.statusText))")
                lines.append("  - Admissions: \(run.admissionsBefore) → \(run.admissionsAfter.map(String.init) ?? "unknown"); interrupted settled as spent: \(run.interruptedAdmissionsSettled)")
                lines.append("  - Scored evaluations: \(run.evaluations.count); model calls: \(run.modelCalls.count); gradings: \(run.gradings.count)")
                if run.uncertainRemoteSettlement {
                    lines.append("  - The app restarted during this run; provider-side settlement is unknown.")
                }
                if let result = run.result {
                    lines.append("  - Assessment: \(markdownInline(result.assessment))")
                    lines.append("  - Baseline \(result.baselineScore.map { String($0) } ?? "unavailable"); best \(result.bestScore.map { String($0) } ?? "unavailable") (candidate #\(result.bestCandidateIndex.map(String.init) ?? "none"))")
                    for candidate in result.candidates {
                        lines.append("    - #\(candidate.index)\(candidate.isBaseline ? " baseline" : "")\(candidate.isBest ? " best" : ""): score \(candidate.aggregateScore.map { String($0) } ?? "unavailable"), parents \(candidate.parentIndices), `../../\(candidate.candidateEvidence.relativePath)`")
                    }
                }
            }
            lines += ["", "## Proposals"]
            lines.append(experiment.proposals.isEmpty ? "None." : experiment.proposals.map { "- \($0.id.uuidString.lowercased()): candidate #\($0.candidateIndex) `\($0.state.rawValue)`" }.joined(separator: "\n"))
            lines += ["", "> Generated view. `experiments.json` and content-addressed artifacts are canonical.", ""]
            return lines.joined(separator: "\n")
        }

        private static func markdownInline(_ value: String) -> String {
            value.replacingOccurrences(of: "\n", with: " ↩ ").replacingOccurrences(of: "`", with: "\\`")
        }

        static func makeEncoder(pretty: Bool) -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = pretty
                ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                : [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }

        static func makeDecoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return decoder
        }

        private static let iso8601 = ISO8601DateFormatter()
    }
#endif
