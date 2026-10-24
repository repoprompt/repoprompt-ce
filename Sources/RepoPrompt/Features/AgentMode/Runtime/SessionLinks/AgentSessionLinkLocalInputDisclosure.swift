import Foundation
import RepoPromptDomainRuntime

extension AgentSessionLinkPassiveStatusNotices {
    struct LocalInputSource {
        let reference: DomainAgentSessionLinkReference
        let target: DomainAgentSessionLinkEndpointIdentity
        let snapshot: AgentSessionLinkRetainedLocalInputIndex.Snapshot?
    }

    struct LocalInputFrontier {
        let target: DomainAgentSessionLinkEndpointIdentity
        let indexEpoch: UUID?
        var consumedThrough: UInt64
    }

    /// Paired with the existing authoritative lifecycle reconciliation, with metadata only.
    /// A nil snapshot is unknown, not absent: it never moves a same-target frontier. Only a
    /// missing or rebound frontier gets the unresolved baseline — a nil epoch never catches up.
    mutating func reconcileLocalInputSources(_ sources: [LocalInputSource]) {
        guard isDeliverable else { localInputFrontiers.removeAll()
            return
        }
        let references = Set(sources.map(\.reference))
        localInputFrontiers = localInputFrontiers.filter { references.contains($0.key) }
        for source in sources {
            let existing = localInputFrontiers[source.reference]
            guard let snapshot = source.snapshot else {
                // A nil snapshot is unknown, not absent: it never moves a frontier that still
                // names this target. Only a missing or rebound frontier gets the baseline.
                if existing?.target != source.target {
                    localInputFrontiers[source.reference] = LocalInputFrontier(
                        target: source.target, indexEpoch: nil, consumedThrough: 0
                    )
                }
                continue
            }
            if existing?.target != source.target || existing?.indexEpoch != snapshot.epoch || existing == nil {
                localInputFrontiers[source.reference] = LocalInputFrontier(
                    target: source.target, indexEpoch: snapshot.epoch,
                    consumedThrough: snapshot.producedThrough
                )
            }
        }
    }

    mutating func localInputOffer(for source: LocalInputSource) -> LocalInputOffer? {
        guard isDeliverable else { return nil }
        guard let snapshot = source.snapshot else {
            if localInputFrontiers[source.reference]?.target != source.target {
                localInputFrontiers[source.reference] = LocalInputFrontier(target: source.target, indexEpoch: nil, consumedThrough: 0)
            }
            return nil
        }
        guard let frontier = localInputFrontiers[source.reference],
              frontier.target == source.target, frontier.indexEpoch == snapshot.epoch
        else {
            // A missed regrant/epoch replacement is baseline-only, even without a lifecycle pass.
            localInputFrontiers[source.reference] = LocalInputFrontier(
                target: source.target, indexEpoch: snapshot.epoch, consumedThrough: snapshot.producedThrough
            )
            return nil
        }
        guard snapshot.producedThrough > frontier.consumedThrough else { return nil }
        let candidates = snapshot.records.filter {
            $0.ordinal > frontier.consumedThrough && $0.content?.text != nil
        }.suffix(4)
        return LocalInputOffer(
            range: LocalInputRange(
                queueEpoch: queueEpoch,
                reference: source.reference,
                target: source.target,
                indexEpoch: snapshot.epoch,
                capturedFrontier: frontier.consumedThrough,
                throughOrdinal: snapshot.producedThrough
            ),
            totalCount: snapshot.producedThrough - frontier.consumedThrough,
            candidates: Array(candidates)
        )
    }

    func canConsumeLocalInputs(_ ranges: [LocalInputRange]) -> Bool {
        isDeliverable && ranges.allSatisfy { range in
            guard range.queueEpoch == queueEpoch, let frontier = localInputFrontiers[range.reference] else { return false }
            return frontier.target == range.target && frontier.indexEpoch == range.indexEpoch
                && frontier.consumedThrough == range.capturedFrontier
                && range.throughOrdinal > range.capturedFrontier
        }
    }

    /// At-most-once exposure, not provider acceptance. No queue publication follows this mutation.
    mutating func consumeLocalInputs(_ ranges: [LocalInputRange]) -> Bool {
        guard canConsumeLocalInputs(ranges) else { return false }
        for range in ranges {
            localInputFrontiers[range.reference]?.consumedThrough = range.throughOrdinal
        }
        return true
    }
}
