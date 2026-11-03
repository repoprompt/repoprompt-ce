#if DEBUG
    import Foundation

    /// Seed-only measurements taken before GEPA searches: the seed's held-out baseline (so the
    /// held-out reserve pays only for the incumbent) and noise-floor replicates of the seed's
    /// validation pass. They depend only on the seed text, the
    /// prompt's rendering, the suite and rubric, and the execution and judge models, so they
    /// are cached across experiments under that key and spent at most once per configuration.
    struct PromptExperimentBaselineCalibration: Codable, Equatable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let key: String
        let seedSHA256: String
        /// Seed score per held-out case; nil when the suite has no held-out cases.
        var heldOutScores: [String: Double]?
        /// Noise-floor replicates 1...k of the seed's validation pass (GEPA's own pass is
        /// replicate 0), each keyed by case ID.
        var validationReplicates: [[String: Double]]?
        let createdAt: Date

        var heldOutAverage: Double? {
            guard let heldOutScores, !heldOutScores.isEmpty else { return nil }
            return heldOutScores.values.reduce(0, +) / Double(heldOutScores.count)
        }

        /// True when every held-out case has a seed score.
        func hasHeldOutBaseline(for cases: [PromptSuiteCase]) -> Bool {
            let hidden = Set(cases.filter { $0.split == .hiddenTest }.map(\.id))
            return hidden.isEmpty || Set((heldOutScores ?? [:]).keys) == hidden
        }

        /// Leading replicates that score every validation-pass case.
        func completeReplicates(for cases: [PromptSuiteCase]) -> [[String: Double]] {
            let wanted = Set(PromptExperimentBudgetLedger.validationPassCases(cases).map(\.id))
            return Array((validationReplicates ?? []).prefix { Set($0.keys) == wanted })
        }
    }

    /// Paired per-case comparison of the reported best against the seed, judged against the
    /// seed's own spread across replicate validation passes (same prompt, same case, same
    /// models). An improvement no larger than that spread is within noise.
    struct PromptExperimentNoiseFloor: Codable, Equatable {
        static let epsilon = 1e-9

        struct CaseComparison: Codable, Equatable {
            let exampleID: String
            let split: PromptExperimentDatasetSplit
            let baselineSamples: [Double]
            let best: Double?
            /// Max − min of the seed's samples (validation); the mean validation spread for
            /// held-out cases, which have one seed sample.
            let spread: Double

            var baselineMean: Double {
                baselineSamples.isEmpty ? 0 : baselineSamples.reduce(0, +) / Double(baselineSamples.count)
            }

            var delta: Double? {
                best.map { $0 - baselineMean }
            }

            var improvedBeyondNoise: Bool {
                (delta ?? 0) > spread + PromptExperimentNoiseFloor.epsilon
            }

            var regressedBeyondNoise: Bool {
                (delta ?? 0) < -spread - PromptExperimentNoiseFloor.epsilon
            }
        }

        /// Fewest seed samples any validation case has (GEPA's pass plus replicates).
        let samplesPerCase: Int
        let meanSpread: Double
        let validation: [CaseComparison]
        let heldOut: [CaseComparison]
        let bestIsBaseline: Bool

        var measured: Bool {
            samplesPerCase >= 2
        }

        var meanDelta: Double? {
            Self.mean(validation.compactMap(\.delta))
        }

        var heldOutMeanDelta: Double? {
            Self.mean(heldOut.compactMap(\.delta))
        }

        var improvedBeyondNoise: Int {
            validation.count(where: \.improvedBeyondNoise)
        }

        var regressedBeyondNoise: Int {
            validation.count(where: \.regressedBeyondNoise)
        }

        /// The mean paired improvement does not exceed the seed's mean replicate spread.
        var withinNoise: Bool {
            guard !bestIsBaseline, measured, let meanDelta else { return true }
            return meanDelta <= meanSpread + Self.epsilon
        }

        var summary: String {
            func signed(_ value: Double) -> String {
                String(format: "%+.3f", value)
            }
            let spread = String(format: "%.3f", meanSpread)
            if bestIsBaseline {
                return "Noise floor: the seed stayed best, so there is no improvement to test (seed spread \(spread) over \(samplesPerCase) samples per case)."
            }
            guard let meanDelta else { return "Noise floor: the best candidate has no paired validation scores." }
            guard measured else {
                return "Noise floor not measured (one seed sample per case); the validation Δ \(signed(meanDelta)) is unqualified."
            }
            var text = "Validation vs seed: Δ \(signed(meanDelta)) mean over \(validation.count) case\(validation.count == 1 ? "" : "s"); observed seed spread \(spread) (\(samplesPerCase) samples per case); \(improvedBeyondNoise) better and \(regressedBeyondNoise) worse beyond that spread → "
            text += withinNoise ? "within observed spread: not a demonstrated improvement." : "exceeds observed baseline spread."
            text += " This is an exploratory range comparison, not a statistical confidence test."
            if let heldOutMeanDelta {
                let beyond = heldOut.count(where: \.improvedBeyondNoise)
                text += " Held-out Δ \(signed(heldOutMeanDelta)) (\(beyond) of \(heldOut.count) case\(heldOut.count == 1 ? "" : "s") beyond the spread)."
            }
            return text
        }

        /// `seedSamples` holds each validation-pass case's seed scores (GEPA's pass first, then
        /// replicates). Nil when there is no seed validation evidence at all.
        static func compute(
            validationCases: [PromptSuiteCase],
            seedSamples: [String: [Double]],
            bestValidation: [String: Double]?,
            seedHeldOut: [String: Double]?,
            bestHeldOut: [String: Double]?,
            bestIsBaseline: Bool
        ) -> Self? {
            let validation = validationCases.compactMap { example -> CaseComparison? in
                guard let samples = seedSamples[example.id], !samples.isEmpty else { return nil }
                return CaseComparison(
                    exampleID: example.id,
                    split: example.split,
                    baselineSamples: samples,
                    best: bestValidation?[example.id],
                    spread: (samples.max() ?? 0) - (samples.min() ?? 0)
                )
            }
            guard !validation.isEmpty else { return nil }
            let meanSpread = mean(validation.map(\.spread)) ?? 0
            let heldOutIDs = Set((seedHeldOut ?? [:]).keys).intersection((bestHeldOut ?? [:]).keys).sorted()
            let heldOut = bestIsBaseline ? [] : heldOutIDs.map { id in
                CaseComparison(
                    exampleID: id,
                    split: .hiddenTest,
                    baselineSamples: [seedHeldOut?[id] ?? 0],
                    best: bestHeldOut?[id],
                    spread: meanSpread
                )
            }
            return Self(
                samplesPerCase: validation.map(\.baselineSamples.count).min() ?? 0,
                meanSpread: meanSpread,
                validation: validation,
                heldOut: heldOut,
                bestIsBaseline: bestIsBaseline
            )
        }

        private static func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    /// File-backed cross-experiment cache under the Prompt Experiment store root. Entries are
    /// whole-file atomic writes named by their key; an unreadable or mismatched entry is a miss.
    enum PromptExperimentCalibrationCache {
        static let directoryName = "calibration"

        private struct KeyMaterial: Encodable {
            let namespace = "baseline-calibration-v2"
            let promptID: String
            /// SHA-256 of the fully rendered seed system prompt (resource plus code-owned suffixes).
            let renderedSeedSHA256: String
            let suiteSHA256: String
            let rubricSHA256: String?
            let execution: String
            let judge: String?
            /// Which transient failures complete as scores rather than unavailable evidence.
            let maxProviderRetries: Int
            /// SHA-256 of the code-owned judge prompt template (nil without a model judge).
            let judgeTemplateSHA256: String?
            /// Format repairs per judged evaluation.
            let judgeRepairs = 1
        }

        static func key(
            promptID: BuiltInPromptID,
            renderedSeedSHA256: String,
            suiteSHA256: String,
            rubricSHA256: String?,
            targets: PromptExperimentTargets,
            maxProviderRetries: Int,
            judgeTemplateSHA256: String?
        ) -> String {
            let material = KeyMaterial(
                promptID: promptID.rawValue,
                renderedSeedSHA256: renderedSeedSHA256,
                suiteSHA256: suiteSHA256,
                rubricSHA256: rubricSHA256,
                execution: targets.execution.canonicalSelectionID,
                judge: targets.judge?.canonicalSelectionID,
                maxProviderRetries: maxProviderRetries,
                judgeTemplateSHA256: judgeTemplateSHA256
            )
            return (try? PromptExperimentDigest.canonicalSHA256(material))
                ?? PromptExperimentDigest.sha256(Data("\(promptID.rawValue):\(renderedSeedSHA256):\(suiteSHA256):\(maxProviderRetries)".utf8))
        }

        static func url(storeRoot: URL, key: String) -> URL {
            storeRoot
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent("\(key).json", isDirectory: false)
        }

        static func load(storeRoot: URL, key: String) -> PromptExperimentBaselineCalibration? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let data = try? Data(contentsOf: url(storeRoot: storeRoot, key: key)),
                  let value = try? decoder.decode(PromptExperimentBaselineCalibration.self, from: data),
                  value.schemaVersion == PromptExperimentBaselineCalibration.schemaVersion,
                  value.key == key
            else { return nil }
            return value
        }

        static func save(_ value: PromptExperimentBaselineCalibration, storeRoot: URL) throws {
            let destination = url(storeRoot: storeRoot, key: value.key)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(value).write(to: destination, options: [.atomic])
        }
    }
#endif
