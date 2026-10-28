#if DEBUG
    import SwiftUI

    /// Identifiable wrapper so review sheets can use `sheet(item:)`.
    struct PromptExperimentProposalSelection: Identifiable, Equatable {
        let id: UUID
    }

    /// Native-only decision surface. MCP can create a proposal, not approve its source write.
    struct PromptExperimentProposalReviewView: View {
        @ObservedObject var service: PromptExperimentService
        let experimentID: UUID
        let proposalID: UUID
        @Environment(\.dismiss) private var dismiss
        @State private var diffText: String?
        @State private var errorText: String?
        @State private var isDeciding = false

        private var experiment: PromptExperiment? {
            service.experiment(id: experimentID)
        }

        private var proposal: PromptExperimentProposal? {
            experiment?.proposals.first { $0.id == proposalID }
        }

        private var run: PromptExperimentRun? {
            guard let proposal else { return nil }
            return experiment?.runs.first { $0.id == proposal.runID }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review source prompt patch").font(.title2.bold())
                if let experiment, let proposal {
                    Text("\(experiment.authority.promptID.rawValue) · run \(run?.ordinal ?? 0) · candidate #\(proposal.candidateIndex)")
                        .font(.subheadline)
                    Text("Baseline SHA-256: \(proposal.baselineResourceSHA256)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if let run {
                        Text("Run: \(run.state.rawValue)")
                            .font(.caption)
                        Text("GEPA \(run.result?.upstreamRevision ?? "—") · \(run.result?.totalEvaluations ?? 0) evaluations · run's best: candidate #\(run.result?.bestCandidateIndex.map(String.init) ?? "—"), score \(run.result?.bestScore.map { String(format: "%.3f", $0) } ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                        if run.result?.bestCandidateIndex == proposal.candidateIndex {
                            if let heldOut = run.result?.heldOut {
                                // Held-out cases never reach the proposer. This comparison is
                                // measured only for the run's selected best, not every candidate.
                                Text(heldOut.summary)
                                    .font(.caption.bold())
                            }
                            if let noise = run.result?.noiseFloor {
                                PromptExperimentNoiseVerdict(noise: noise)
                            }
                        } else {
                            Text("Held-out improvement and baseline-spread comparison are unavailable for this proposal. The run measured that comparison for candidate #\(run.result?.bestCandidateIndex.map(String.init) ?? "—") only.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let result = run.result {
                            let proposedScore = result.candidates.first { $0.index == proposal.candidateIndex }?.aggregateScore
                            Text("Proposed candidate validation score: \(proposedScore.map { String(format: "%.3f", $0) } ?? "unavailable")")
                                .font(.caption.bold())
                            let usage = { (index: Int?) in result.candidates.first { $0.index == index }?.usage?.summary ?? "—" }
                            Text("Size: baseline \(usage(0)) → proposed \(usage(proposal.candidateIndex))")
                                .font(.caption).foregroundStyle(.secondary)
                            // Capped so per-case evidence never squeezes the diff out of view.
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(result.evaluations.filter { $0.candidateIndex == proposal.candidateIndex }) { evaluation in
                                        Text("\(evaluation.exampleID) [\(evaluation.split.rawValue)] · \(evaluation.score.map { String(format: "%.3f", $0) } ?? "—"): \(evaluation.feedback)")
                                            .font(.caption).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .frame(maxHeight: 160)
                        }
                    }
                    Text("One-file unified diff").font(.headline)
                    ScrollView([.vertical, .horizontal]) {
                        Text(diffText ?? "Loading diff…")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .frame(minHeight: 320, maxHeight: .infinity)
                    .layoutPriority(1)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                    }
                    Text("Apply updates the source checkout. Rebuild the app to use or evaluate the new built-in default.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Close") { dismiss() }
                        Spacer()
                        if proposal.state == .proposed {
                            Button("Reject") { decide(apply: false) }
                                .disabled(isDeciding)
                            Button("Apply to Source") { decide(apply: true) }
                                .disabled(isDeciding || diffText == nil)
                        } else {
                            Text(proposal.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView("Proposal unavailable", systemImage: "doc.badge.questionmark")
                }
            }
            .padding(20)
            .frame(minWidth: 900, idealWidth: 1100, minHeight: 760, idealHeight: 900)
            .task(id: proposalID) {
                guard let reference = proposal?.diffEvidence else {
                    errorText = "The proposal has no diff artifact."
                    return
                }
                diffText = await service.readArtifactText(reference)
                if diffText == nil { errorText = "The diff artifact could not be read or verified." }
            }
        }

        private func decide(apply: Bool) {
            isDeciding = true
            Task {
                do {
                    if apply {
                        try await service.applyProposal(experimentID: experimentID, proposalID: proposalID)
                    } else {
                        try await service.rejectProposal(experimentID: experimentID, proposalID: proposalID)
                    }
                    dismiss()
                } catch {
                    errorText = error.localizedDescription
                }
                isDeciding = false
            }
        }
    }
#endif
