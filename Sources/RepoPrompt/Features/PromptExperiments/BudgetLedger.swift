#if DEBUG
    import Foundation

    /// Durable, file-backed evaluation-admission ledger for one approved experiment authority
    /// (experiment ID + sealed plan digest). It is the only hard evaluator-admission authority:
    ///
    /// - An admission is written to disk before any target or judge spend and is never refunded.
    /// - A repeated logical evaluation (same candidate text, split, and example) replays its
    ///   recorded outcome instead of spending again; GEPA re-evaluates the seed on every resume.
    /// - Search and held-out admissions draw from separate pools so neither can starve the other.
    /// - Opening a ledger that still holds unsettled admissions (an interrupted run) settles them
    ///   as `interrupted`: they count as spent and are never refunded, and the count is reported
    ///   so the resuming run records it. A new admission is needed to evaluate them again.
    @MainActor
    final class PromptExperimentBudgetLedger {
        enum Pool: String, Codable {
            case search
            case heldOut = "held_out"
        }

        enum EntryState: String, Codable {
            case admitted
            case completed
            case failed
            /// Admitted by a run that ended without settling it; provider spend is unknown.
            case interrupted
        }

        /// Proposer-safe replay payload. Full outputs remain in the attempt's evidence store.
        struct Outcome: Codable, Equatable {
            let score: Double
            let proposerFeedback: String
            let outputExcerpt: String?
            let failureKind: PromptExperimentOptimizationFailureKind?
        }

        struct Entry: Codable, Equatable {
            let evaluationID: UUID
            let logicalKey: String
            let pool: Pool
            let exampleID: String
            let split: PromptExperimentDatasetSplit
            let candidateSHA256: String
            let admittedAt: Date
            var state: EntryState
            var outcome: Outcome?
        }

        struct Document: Codable, Equatable {
            static let currentSchemaVersion = 1
            let schemaVersion: Int
            let authorityDigest: String
            let totalCap: Int
            let heldOutReserve: Int
            var entries: [Entry]
        }

        enum Admission: Equatable {
            /// A completed outcome for the same logical evaluation; no new spend.
            case recorded(Entry)
            /// Durably admitted; the caller may now spend and must settle it.
            case admitted(Entry)
            case exhausted(Pool)
        }

        enum LedgerError: LocalizedError, Equatable {
            case authorityMismatch
            case unreadable(String)
            case checkpointWithoutLedger
            case duplicateInFlight
            case unknownEvaluation
            case persistenceFailed(String)

            var errorDescription: String? {
                switch self {
                case .authorityMismatch:
                    "The run directory's evaluation ledger belongs to a different approved authority or cap."
                case let .unreadable(detail):
                    "The evaluation ledger could not be read: \(detail)"
                case .checkpointWithoutLedger:
                    "A GEPA checkpoint exists without its evaluation ledger; spend cannot be reconciled, so resume is refused."
                case .duplicateInFlight:
                    "GEPA requested an evaluation that is already in flight."
                case .unknownEvaluation:
                    "The settled evaluation was never admitted by this ledger."
                case let .persistenceFailed(detail):
                    "The evaluation ledger could not be saved: \(detail)"
                }
            }
        }

        nonisolated static let fileName = "ledger.json"

        let fileURL: URL
        private(set) var document: Document
        /// Unsettled admissions from an interrupted run that `open` settled as spent.
        private(set) var interruptedSettledOnOpen = 0
        private let now: () -> Date

        private init(fileURL: URL, document: Document, now: @escaping () -> Date) {
            self.fileURL = fileURL
            self.document = document
            self.now = now
        }

        /// Opens (resumes) or creates the ledger in `directory`. `gepaStateURL` is the GEPA
        /// checkpoint that must never exist without a ledger to reconcile its spend against.
        static func open(
            directory: URL,
            authorityDigest: String,
            totalCap: Int,
            heldOutReserve: Int,
            gepaStateURL: URL,
            now: @escaping () -> Date = Date.init
        ) throws -> PromptExperimentBudgetLedger {
            let fileURL = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let document: Document
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .millisecondsSince1970
                    document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
                } catch {
                    throw LedgerError.unreadable(error.localizedDescription)
                }
                guard document.schemaVersion == Document.currentSchemaVersion,
                      document.authorityDigest == authorityDigest,
                      document.totalCap == totalCap,
                      document.heldOutReserve == heldOutReserve
                else { throw LedgerError.authorityMismatch }
                let ledger = PromptExperimentBudgetLedger(fileURL: fileURL, document: document, now: now)
                let unsettled = document.entries.indices.filter { document.entries[$0].state == .admitted }
                if !unsettled.isEmpty {
                    var staged = document
                    for index in unsettled {
                        staged.entries[index].state = .interrupted
                    }
                    try ledger.persist(staged)
                    ledger.interruptedSettledOnOpen = unsettled.count
                }
                return ledger
            }
            guard !FileManager.default.fileExists(atPath: gepaStateURL.path) else {
                throw LedgerError.checkpointWithoutLedger
            }
            let ledger = PromptExperimentBudgetLedger(
                fileURL: fileURL,
                document: Document(
                    schemaVersion: Document.currentSchemaVersion,
                    authorityDigest: authorityDigest,
                    totalCap: totalCap,
                    heldOutReserve: heldOutReserve,
                    entries: []
                ),
                now: now
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ledger.save()
            return ledger
        }

        var searchCap: Int {
            document.totalCap - document.heldOutReserve
        }

        /// Admissions ever consumed from `pool`, including failed ones (never refunded).
        func admittedCount(in pool: Pool) -> Int {
            document.entries.count(where: { $0.pool == pool })
        }

        var totalAdmitted: Int {
            document.entries.count
        }

        func admit(candidateSHA256: String, exampleID: String, split: PromptExperimentDatasetSplit) throws -> Admission {
            let key = Self.logicalKey(candidateSHA256: candidateSHA256, split: split, exampleID: exampleID)
            if let recorded = document.entries.last(where: { $0.logicalKey == key && $0.state == .completed }) {
                return .recorded(recorded)
            }
            guard !document.entries.contains(where: { $0.logicalKey == key && $0.state == .admitted }) else {
                throw LedgerError.duplicateInFlight
            }
            let pool: Pool = split == .hiddenTest ? .heldOut : .search
            let cap = pool == .heldOut ? document.heldOutReserve : searchCap
            guard admittedCount(in: pool) < cap else { return .exhausted(pool) }
            let ordinal = document.entries.count(where: { $0.logicalKey == key })
            let entry = Entry(
                evaluationID: PromptExperimentDigest.deterministicUUID(
                    namespace: "gepa-evaluation",
                    value: "\(document.authorityDigest):\(key):\(ordinal)"
                ),
                logicalKey: key,
                pool: pool,
                exampleID: exampleID,
                split: split,
                candidateSHA256: candidateSHA256,
                admittedAt: now(),
                state: .admitted,
                outcome: nil
            )
            var staged = document
            staged.entries.append(entry)
            try persist(staged)
            return .admitted(entry)
        }

        /// Settles an admission. A nil outcome records a failed (spent, unscored) evaluation.
        func settle(_ evaluationID: UUID, outcome: Outcome?) throws {
            guard let index = document.entries.firstIndex(where: { $0.evaluationID == evaluationID }),
                  document.entries[index].state == .admitted
            else { throw LedgerError.unknownEvaluation }
            var staged = document
            staged.entries[index].state = outcome == nil ? .failed : .completed
            staged.entries[index].outcome = outcome
            try persist(staged)
        }

        private func persist(_ staged: Document) throws {
            let previous = document
            document = staged
            do {
                try save()
            } catch {
                document = previous
                throw LedgerError.persistenceFailed(error.localizedDescription)
            }
        }

        private func save() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(document).write(to: fileURL, options: [.atomic])
        }

        /// Cumulative admissions recorded in `directory` without opening (or settling) the ledger.
        nonisolated static func peekTotalAdmitted(directory: URL) -> Int {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
                  let document = try? decoder.decode(Document.self, from: data)
            else { return 0 }
            return document.entries.count
        }

        nonisolated static func logicalKey(candidateSHA256: String, split: PromptExperimentDatasetSplit, exampleID: String) -> String {
            PromptExperimentDigest.sha256(Data("\(candidateSHA256)\u{0}\(split.rawValue)\u{0}\(exampleID)".utf8))
        }

        /// Held-out passes score the seed and the incumbent once each per hidden example.
        nonisolated static func heldOutReserve(for cases: [PromptSuiteCase]) -> Int {
            2 * cases.count(where: { $0.split == .hiddenTest })
        }

        /// Smallest cap that admits the seed's full validation pass plus one complete
        /// mutation cycle (parent minibatch, child minibatch, accepted child's validation
        /// pass) and the held-out reserve. Smaller caps can only end before any mutation
        /// is validated, so they are rejected before approval.
        nonisolated static func minimumApprovableEvaluations(
            cases: [PromptSuiteCase],
            reflectionMinibatchSize: Int
        ) -> Int {
            let training = cases.count(where: { $0.split == .training })
            let validation = cases.count(where: { $0.split == .validation })
            // The worker promotes validation to training when no training examples exist,
            // and upstream GEPA validates on the training set when there is no valset.
            let train = training > 0 ? training : validation
            let validationPass = training > 0 && validation > 0 ? validation : train
            let minibatch = min(max(1, reflectionMinibatchSize), max(1, train))
            return 2 * validationPass + 2 * minibatch + heldOutReserve(for: cases)
        }
    }
#endif
