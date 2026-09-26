#if DEBUG
    import Foundation

    /// Durable, file-backed evaluation-admission ledger for one approved experiment authority
    /// (experiment ID + sealed plan digest). It is the only hard evaluator-admission authority:
    ///
    /// - An admission is written to disk before any target or judge spend and is never refunded.
    /// - A repeated logical evaluation (same candidate text, split, example, and replicate)
    ///   replays its recorded outcome instead of spending again; GEPA re-evaluates the seed on
    ///   every resume. Deliberate noise-floor replicates carry a replicate ordinal so they are
    ///   distinct logical evaluations.
    /// - Search, held-out, and baseline-calibration admissions draw from separate pools so none
    ///   can starve another. Calibration is its own approved line outside the search cap.
    /// - Opening a ledger that still holds unsettled admissions (an interrupted run) settles them
    ///   as `interrupted`: they count as spent and are never refunded, and the count is reported
    ///   so the resuming run records it. A new admission is needed to evaluate them again.
    @MainActor
    final class PromptExperimentBudgetLedger {
        enum Pool: String, Codable {
            case search
            case heldOut = "held_out"
            /// Pre-search baseline calibration of the seed (held-out baseline, noise replicates).
            case calibration
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
            var usage: PromptExperimentEvaluationUsage?
        }

        struct Entry: Codable, Equatable {
            let evaluationID: UUID
            let logicalKey: String
            let pool: Pool
            let exampleID: String
            let split: PromptExperimentDatasetSplit
            let candidateSHA256: String
            /// 0 for ordinary evaluations; 1... for deliberate noise-floor replicates.
            let replicate: Int
            let admittedAt: Date
            var state: EntryState
            var outcome: Outcome?
        }

        struct Document: Codable, Equatable {
            static let currentSchemaVersion = 2
            let schemaVersion: Int
            let authorityDigest: String
            /// The approved search cap, including the held-out reserve.
            let totalCap: Int
            let heldOutReserve: Int
            /// The separately approved baseline-calibration line.
            let calibrationReserve: Int
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
            calibrationReserve: Int,
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
                      document.heldOutReserve == heldOutReserve,
                      document.calibrationReserve == calibrationReserve
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
                    calibrationReserve: calibrationReserve,
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

        func cap(of pool: Pool) -> Int {
            switch pool {
            case .search: searchCap
            case .heldOut: document.heldOutReserve
            case .calibration: document.calibrationReserve
            }
        }

        func remaining(in pool: Pool) -> Int {
            max(0, cap(of: pool) - admittedCount(in: pool))
        }

        /// Every admission, including baseline calibration.
        var totalAdmitted: Int {
            document.entries.count
        }

        /// Admissions charged against the approved search cap (search + held-out reserve).
        var cappedAdmitted: Int {
            document.entries.count(where: { $0.pool != .calibration })
        }

        /// Admissions charged against the separately approved calibration line.
        var calibrationAdmitted: Int {
            admittedCount(in: .calibration)
        }

        /// `pool` defaults to the split's pool (held-out for `hidden_test`, else search);
        /// calibration passes name it explicitly. The same logical evaluation replays across
        /// pools, so a calibrated seed held-out score is never re-spent by the search.
        func admit(
            candidateSHA256: String,
            exampleID: String,
            split: PromptExperimentDatasetSplit,
            replicate: Int = 0,
            pool requestedPool: Pool? = nil
        ) throws -> Admission {
            let key = Self.logicalKey(candidateSHA256: candidateSHA256, split: split, exampleID: exampleID, replicate: replicate)
            if let recorded = document.entries.last(where: { $0.logicalKey == key && $0.state == .completed }) {
                return .recorded(recorded)
            }
            guard !document.entries.contains(where: { $0.logicalKey == key && $0.state == .admitted }) else {
                throw LedgerError.duplicateInFlight
            }
            let pool: Pool = requestedPool ?? (split == .hiddenTest ? .heldOut : .search)
            guard admittedCount(in: pool) < cap(of: pool) else { return .exhausted(pool) }
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
                replicate: replicate,
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

        /// Cumulative admissions against the approved search cap (search + held-out reserve)
        /// recorded in `directory`, without opening (or settling) the ledger.
        nonisolated static func peekCappedAdmitted(directory: URL) -> Int {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
                  let document = try? decoder.decode(Document.self, from: data)
            else { return 0 }
            return document.entries.count(where: { $0.pool != .calibration })
        }

        nonisolated static func logicalKey(
            candidateSHA256: String,
            split: PromptExperimentDatasetSplit,
            exampleID: String,
            replicate: Int = 0
        ) -> String {
            let suffix = replicate == 0 ? "" : "\u{0}replicate-\(replicate)"
            return PromptExperimentDigest.sha256(Data("\(candidateSHA256)\u{0}\(split.rawValue)\u{0}\(exampleID)\(suffix)".utf8))
        }

        /// The held-out reserve scores only the incumbent: the seed's held-out baseline comes
        /// from baseline calibration (cached across experiments, or scored once pre-search).
        nonisolated static func heldOutReserve(for cases: [PromptSuiteCase]) -> Int {
            cases.count(where: { $0.split == .hiddenTest })
        }

        /// The separately approved baseline-calibration line: the seed's held-out pass when
        /// the cross-experiment cache misses. Zero spend on a cache hit.
        nonisolated static func calibrationEvaluations(cases: [PromptSuiteCase]) -> Int {
            cases.count(where: { $0.split == .hiddenTest })
        }

        /// Validation-pass size and the worst-case cost of one full reflective iteration
        /// (parent minibatch, child minibatch, accepted child's validation pass), mirroring
        /// the worker's `full_iteration_cost`.
        nonisolated static func searchShape(
            cases: [PromptSuiteCase],
            reflectionMinibatchSize: Int
        ) -> (validationPass: Int, iterationCost: Int) {
            let training = cases.count(where: { $0.split == .training })
            let validation = cases.count(where: { $0.split == .validation })
            // The worker promotes validation to training when no training examples exist,
            // and upstream GEPA validates on the training set when there is no valset.
            let train = training > 0 ? training : validation
            let validationPass = training > 0 && validation > 0 ? validation : train
            let minibatch = min(max(1, reflectionMinibatchSize), max(1, train))
            return (validationPass, 2 * minibatch + validationPass)
        }

        /// Smallest cap that admits the seed's full validation pass plus one complete
        /// mutation cycle and the held-out reserve. Smaller caps can only end before any
        /// mutation is validated, so they are rejected before approval.
        nonisolated static func minimumApprovableEvaluations(
            cases: [PromptSuiteCase],
            reflectionMinibatchSize: Int
        ) -> Int {
            let shape = searchShape(cases: cases, reflectionMinibatchSize: reflectionMinibatchSize)
            return shape.validationPass + shape.iterationCost + heldOutReserve(for: cases)
        }

        /// Proposals the worker's ledger-aware stopper can start under `cap`: every rejected
        /// proposal costs two minibatch passes and each iteration needs a full iteration's
        /// admissions available before it starts. `acceptedProposals` of them also pay the
        /// child's validation pass. An estimate for the approval card, not a guarantee
        /// (perfect-score skips and replays are free).
        nonisolated static func expectedProposals(
            cap: Int,
            cases: [PromptSuiteCase],
            reflectionMinibatchSize: Int,
            acceptedProposals: Int = 0
        ) -> Int {
            let shape = searchShape(cases: cases, reflectionMinibatchSize: reflectionMinibatchSize)
            var remaining = cap - heldOutReserve(for: cases) - shape.validationPass
            var proposals = 0
            var accepted = 0
            while remaining >= shape.iterationCost {
                let accept = accepted < acceptedProposals
                remaining -= accept ? shape.iterationCost : shape.iterationCost - shape.validationPass
                if accept { accepted += 1 }
                proposals += 1
            }
            return proposals
        }
    }
#endif
