#if DEBUG
    import Foundation

    /// Seed-only measurements taken before GEPA searches: the seed's held-out baseline (so the
    /// held-out reserve pays only for the incumbent). They depend only on the seed text, the
    /// prompt's rendering, the suite and rubric, and the execution and judge models, so they
    /// are cached across experiments under that key and spent at most once per configuration.
    struct PromptExperimentBaselineCalibration: Codable, Equatable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let key: String
        let seedSHA256: String
        /// Seed score per held-out case; nil when the suite has no held-out cases.
        var heldOutScores: [String: Double]?
        let createdAt: Date

        var heldOutAverage: Double? {
            guard let heldOutScores, !heldOutScores.isEmpty else { return nil }
            return heldOutScores.values.reduce(0, +) / Double(heldOutScores.count)
        }

        /// Complete for `cases` when every held-out case has a seed score.
        func isComplete(for cases: [PromptSuiteCase]) -> Bool {
            let hidden = Set(cases.filter { $0.split == .hiddenTest }.map(\.id))
            return hidden.isEmpty || Set((heldOutScores ?? [:]).keys) == hidden
        }
    }

    /// File-backed cross-experiment cache under the Prompt Experiment store root. Entries are
    /// whole-file atomic writes named by their key; an unreadable or mismatched entry is a miss.
    enum PromptExperimentCalibrationCache {
        static let directoryName = "calibration"

        private struct KeyMaterial: Encodable {
            let namespace = "baseline-calibration-v1"
            let promptID: String
            let seedSHA256: String
            let suiteSHA256: String
            let rubricSHA256: String?
            let execution: String
            let judge: String?
        }

        static func key(
            promptID: BuiltInPromptID,
            seedSHA256: String,
            suiteSHA256: String,
            rubricSHA256: String?,
            targets: PromptExperimentTargets
        ) -> String {
            let material = KeyMaterial(
                promptID: promptID.rawValue,
                seedSHA256: seedSHA256,
                suiteSHA256: suiteSHA256,
                rubricSHA256: rubricSHA256,
                execution: targets.execution.canonicalSelectionID,
                judge: targets.judge?.canonicalSelectionID
            )
            return (try? PromptExperimentDigest.canonicalSHA256(material))
                ?? PromptExperimentDigest.sha256(Data("\(promptID.rawValue):\(seedSHA256):\(suiteSHA256)".utf8))
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
