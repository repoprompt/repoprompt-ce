#if DEBUG
    import Foundation

    struct PromptLabUsageComparison: Codable, Equatable {
        let caseCount: Int
        let pairedInputCases: Int
        let pairedOutputCases: Int
        let baselineInputTokens: Int?
        let candidateInputTokens: Int?
        let baselineOutputTokens: Int?
        let candidateOutputTokens: Int?
        let split: PromptSuiteSplit

        var inputReduction: Double? {
            guard pairedInputCases == caseCount, let baselineInputTokens, let candidateInputTokens, baselineInputTokens > 0 else { return nil }
            return 1 - Double(candidateInputTokens) / Double(baselineInputTokens)
        }

        var outputReduction: Double? {
            guard pairedOutputCases == caseCount, let baselineOutputTokens, let candidateOutputTokens, baselineOutputTokens > 0 else { return nil }
            return 1 - Double(candidateOutputTokens) / Double(baselineOutputTokens)
        }

        var summary: String {
            func describe(_ reduction: Double?, _ label: String, _ covered: Int) -> String {
                guard let reduction else { return "\(label) usage incomplete (\(covered)/\(caseCount) paired cases)" }
                return String(format: "%@ tokens %@ %.1f%%", label, reduction >= 0 ? "decreased" : "increased", abs(reduction) * 100)
            }
            return "\(split == .hiddenTest ? "Final" : "Validation") comparison on \(caseCount) matched cases: "
                + describe(inputReduction, "input", pairedInputCases) + "; " + describe(outputReduction, "output", pairedOutputCases) + "."
        }

        static func compute(_ result: PromptExperimentOptimizationResult) -> Self? {
            guard let baseline = result.candidates.first(where: \.isBaseline)?.index, let best = result.bestCandidateIndex else { return nil }
            let hidden = result.evaluations.contains { $0.candidateIndex == best && $0.split == .hiddenTest }
            let split: PromptSuiteSplit = hidden ? .hiddenTest : .validation
            // The last observation for each candidate/case is the canonical replay/search
            // pass; earlier calibration repeats must not change its weight in the corpus.
            var seed: [String: PromptExperimentEvaluationUsage] = [:]
            var winner: [String: PromptExperimentEvaluationUsage] = [:]
            var caseIDs: Set<String> = []
            for evaluation in result.evaluations where evaluation.split == split
                && (evaluation.candidateIndex == baseline || evaluation.candidateIndex == best)
            {
                caseIDs.insert(evaluation.exampleID)
                if evaluation.candidateIndex == baseline { seed.removeValue(forKey: evaluation.exampleID) }
                if evaluation.candidateIndex == best { winner.removeValue(forKey: evaluation.exampleID) }
                guard let usage = evaluation.usage, usage.measurementVersion == 1 else { continue }
                if evaluation.candidateIndex == baseline { seed[evaluation.exampleID] = usage }
                if evaluation.candidateIndex == best { winner[evaluation.exampleID] = usage }
            }
            guard !caseIDs.isEmpty else { return nil }
            var inputPairs: [(Int, Int)] = []
            var outputPairs: [(Int, Int)] = []
            for id in caseIDs {
                if let before = seed[id]?.promptTokens, let after = winner[id]?.promptTokens, before >= 0, after >= 0 { inputPairs.append((before, after)) }
                if let before = seed[id]?.completionTokens, let after = winner[id]?.completionTokens, before >= 0, after >= 0 { outputPairs.append((before, after)) }
            }
            return Self(
                caseCount: caseIDs.count, pairedInputCases: inputPairs.count, pairedOutputCases: outputPairs.count,
                baselineInputTokens: inputPairs.isEmpty ? nil : inputPairs.reduce(0) { $0 + $1.0 },
                candidateInputTokens: inputPairs.isEmpty ? nil : inputPairs.reduce(0) { $0 + $1.1 },
                baselineOutputTokens: outputPairs.isEmpty ? nil : outputPairs.reduce(0) { $0 + $1.0 },
                candidateOutputTokens: outputPairs.isEmpty ? nil : outputPairs.reduce(0) { $0 + $1.1 }, split: split
            )
        }
    }

    extension PromptExperimentOptimizationResult {
        var usageComparison: PromptLabUsageComparison? {
            PromptLabUsageComparison.compute(self)
        }
    }

    extension PromptExperimentRun {
        var usageComparison: PromptLabUsageComparison? {
            result?.usageComparison
        }
    }
#endif
