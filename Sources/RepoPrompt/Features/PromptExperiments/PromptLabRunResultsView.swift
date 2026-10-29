#if DEBUG
    import AppKit
    import SwiftUI
    import UniformTypeIdentifiers

    struct PromptLabRunResultsView: View {
        @ObservedObject var service: PromptExperimentService
        let experiment: PromptExperiment
        let run: PromptExperimentRun
        let result: PromptExperimentOptimizationResult
        let onProposal: (UUID) -> Void
        @State private var comparedCandidate: PromptExperimentCandidateEvidence?
        @State private var message: String?
        @State private var errorMessage: String?
        @State private var isWorking = false

        private var canProposePatch: Bool {
            experiment.authority.definition?.source.kind != .pasted
        }

        private var runFinished: Bool {
            run.state == .completed || run.state == .stoppedBudget
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let noise = result.noiseFloor, !noise.bestIsBaseline { PromptExperimentNoiseVerdict(noise: noise) }
                Text(result.assessment).font(.caption)
                if let comparison = result.usageComparison {
                    PromptLabUsageComparisonView(comparison: comparison)
                } else {
                    Text("A paired token comparison is unavailable. Character counts and averages over different examples do not establish token savings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(result.candidates) { candidate in candidateRow(candidate) }
                Button("Export experiment and evidence…") { exportResult() }.font(.caption).disabled(isWorking)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .sheet(item: $comparedCandidate) { candidate in
                PromptLabCandidateEvidenceView(service: service, experiment: experiment, result: result, candidate: candidate)
            }
        }

        private func candidateRow(_ candidate: PromptExperimentCandidateEvidence) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Candidate #\(candidate.index)\(candidate.isBaseline ? " · starting prompt" : "")\(candidate.isBest ? " · selected best" : "")")
                    .font(.caption.bold())
                Text("Comparison score: \(candidate.aggregateScore.map { String(format: "%.3f", $0) } ?? "unavailable")")
                    .font(.caption)
                if let usage = candidate.usage {
                    Text(usage.summary).font(.caption).foregroundStyle(.secondary)
                }
                Text(candidate.candidatePreview).font(.caption).lineLimit(5).textSelection(.enabled)
                HStack {
                    Button("Compare outputs") { comparedCandidate = candidate }
                    Button("Copy prompt") { copy(candidate) }
                    Button("Save prompt…") { save(candidate) }
                    if runFinished, canProposePatch, !candidate.isBaseline {
                        Button("Review source change") {
                            perform {
                                let proposal = try await service.proposePatch(experimentID: experiment.id, runID: run.id, candidateIndex: candidate.index)
                                onProposal(proposal.id)
                            }
                        }
                    }
                }
                .font(.caption).disabled(isWorking)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(candidate.isBest ? Color.green.opacity(0.08) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }

        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            errorMessage = nil
            message = nil
            isWorking = true
            Task { @MainActor in
                defer { isWorking = false }
                do { try await action() } catch { errorMessage = error.localizedDescription }
            }
        }

        private func candidateText(_ candidate: PromptExperimentCandidateEvidence) async throws -> String {
            guard let text = await service.readArtifactText(candidate.candidateEvidence) else {
                throw PromptExperimentAuthorityError.invalidRequest("The retained prompt artifact could not be read or verified.")
            }
            return text
        }

        private func copy(_ candidate: PromptExperimentCandidateEvidence) {
            perform {
                let text = try await candidateText(candidate)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                message = "Copied candidate #\(candidate.index)."
            }
        }

        private func save(_ candidate: PromptExperimentCandidateEvidence) {
            let panel = NSSavePanel()
            panel.title = "Save candidate prompt"
            panel.nameFieldStringValue = experiment.authority.definition?.runner == .dspy ? "optimized-instructions.json" : "optimized-prompt.md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if let sourcePath = experiment.authority.definition?.source.filePath,
               url.standardizedFileURL.path == URL(fileURLWithPath: sourcePath).standardizedFileURL.path
            {
                errorMessage = "Use Review source change to update the original file with its conflict check. Choose another destination to export the prompt."
                return
            }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                errorMessage = "Choose a new file name to save the prompt. Use Review source change to update the original file with its conflict check."
                return
            }
            perform {
                let text = try await candidateText(candidate)
                do { try Data(text.utf8).write(to: url, options: .withoutOverwriting) }
                catch let error as CocoaError where error.code == .fileWriteFileExists {
                    throw PromptExperimentAuthorityError.invalidRequest("That file already exists. Choose a new file name to save the prompt.")
                }
                message = "Saved candidate #\(candidate.index) to \(url.path)."
            }
        }

        private func exportResult() {
            let panel = NSSavePanel()
            panel.title = "Export experiment evidence"
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "prompt-experiment-\(experiment.id.uuidString.prefix(8).lowercased()).json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                errorMessage = "Choose a new file name for the evidence export. Existing files are preserved."
                return
            }
            perform {
                try await service.exportResult(experimentID: experiment.id, runID: run.id, to: url)
                message = "Exported the definition, result and evidence to \(url.path)."
            }
        }
    }

    struct PromptLabUsageComparisonView: View {
        let comparison: PromptLabUsageComparison

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paired token comparison · \(comparison.split == .hiddenTest ? "final checks" : "comparison examples")").font(.caption.bold())
                Text(comparison.summary).font(.caption)
                Text("Input coverage: \(comparison.pairedInputCases)/\(comparison.caseCount) examples · output coverage: \(comparison.pairedOutputCases)/\(comparison.caseCount). One retained sample per matching example; missing usage is not treated as zero.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private struct PromptLabOutputPair: Identifiable {
        let exampleID: String
        let split: PromptExperimentDatasetSplit
        let baseline: PromptExperimentEvaluationEvidence?
        let candidate: PromptExperimentEvaluationEvidence?
        var id: String {
            "\(exampleID)|\(split.rawValue)"
        }
    }

    struct PromptLabCandidateEvidenceView: View {
        @ObservedObject var service: PromptExperimentService
        let experiment: PromptExperiment
        let result: PromptExperimentOptimizationResult
        let candidate: PromptExperimentCandidateEvidence
        @Environment(\.dismiss) private var dismiss
        @State private var selectedExampleID = ""
        @State private var baselineOutput = ""
        @State private var candidateOutput = ""
        @State private var promptText = ""

        private var pairs: [PromptLabOutputPair] {
            let baselineIndex = result.candidates.first(where: \.isBaseline)?.index ?? 0
            let relevant = result.evaluations.filter { $0.candidateIndex == baselineIndex || $0.candidateIndex == candidate.index }
            let groups = Dictionary(grouping: relevant) { "\($0.exampleID)|\($0.split.rawValue)" }
            return groups.values.compactMap { evaluations in
                guard let first = evaluations.first else { return nil }
                return PromptLabOutputPair(
                    exampleID: first.exampleID, split: first.split,
                    baseline: evaluations.last { $0.candidateIndex == baselineIndex },
                    candidate: evaluations.last { $0.candidateIndex == candidate.index }
                )
            }.sorted {
                let rank: [PromptExperimentDatasetSplit: Int] = [.hiddenTest: 0, .validation: 1, .training: 2]
                let lhs = rank[$0.split, default: 3], rhs = rank[$1.split, default: 3]
                return lhs == rhs ? $0.exampleID < $1.exampleID : lhs < rhs
            }
        }

        private var selection: PromptLabOutputPair? {
            pairs.first { $0.id == selectedExampleID } ?? pairs.first
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Candidate #\(candidate.index) · evidence").font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                DisclosureGroup("Full candidate prompt") {
                    ScrollView { Text(promptText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 160)
                }
                if pairs.isEmpty {
                    ContentUnavailableView("No retained per-example output", systemImage: "doc.text.magnifyingglass", description: Text("The full export includes all available run evidence."))
                } else {
                    Picker("Example", selection: $selectedExampleID) {
                        ForEach(pairs) { Text("\($0.exampleID) · \($0.split.labDisplayName)").tag($0.id) }
                    }
                    if let selection {
                        if let example = experiment.authority.definition?.examples.first(where: { $0.id == selection.exampleID }) {
                            DisclosureGroup("Actual example input and private reference") {
                                Text(example.input).font(.caption).textSelection(.enabled)
                                if let reference = example.expectedOutput {
                                    Text("Private reference: \(reference)").font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                        HStack(alignment: .top, spacing: 14) {
                            outputColumn(title: "Starting prompt", evaluation: selection.baseline, text: baselineOutput)
                            outputColumn(title: "Candidate #\(candidate.index)", evaluation: selection.candidate, text: candidateOutput)
                        }
                    }
                    Text("The last retained sample for each example and candidate is shown. Earlier samples and additional artifacts remain in the evidence export.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(20).frame(minWidth: 960, minHeight: 650)
            .task {
                promptText = await service.readArtifactText(candidate.candidateEvidence) ?? "The prompt artifact could not be read or verified."
                selectedExampleID = pairs.first?.id ?? ""
            }
            .task(id: selectedExampleID) { await loadOutputs() }
        }

        private func outputColumn(title: String, evaluation: PromptExperimentEvaluationEvidence?, text: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text("Score: \(evaluation?.score.map { String(format: "%.3f", $0) } ?? "unavailable")").font(.caption)
                Text("Input tokens: \(evaluation?.usage?.promptTokens.map(String.init) ?? "unreported") · output: \(evaluation?.usage?.completionTokens.map(String.init) ?? "unreported")")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                if let evaluation {
                    DisclosureGroup("Evaluation feedback") {
                        Text(evaluation.feedback).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        private func loadOutputs() async {
            guard let selection else { return }
            baselineOutput = "Loading…"
            candidateOutput = "Loading…"
            let baseline = await readOutput(selection.baseline)
            let proposed = await readOutput(selection.candidate)
            guard !Task.isCancelled else { return }
            baselineOutput = baseline
            candidateOutput = proposed
        }

        private func readOutput(_ evaluation: PromptExperimentEvaluationEvidence?) async -> String {
            guard let reference = evaluation?.outputEvidence else { return "No retained output is available for this example and candidate." }
            return await service.readArtifactText(reference) ?? "The output artifact could not be read or verified."
        }
    }
#endif
