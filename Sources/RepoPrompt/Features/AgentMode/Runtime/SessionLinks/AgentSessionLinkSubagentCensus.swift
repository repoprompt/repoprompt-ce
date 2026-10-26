import Foundation

/// Current child counts for passive lane-board observation. Source precedence matches
/// `agent_manage.list_sessions`: live session > active-workspace index > persisted metadata.
/// Each source is walked once; target snapshots only perform a parent-ID lookup.
struct AgentSessionLinkSubagentCensus: Equatable {
    struct Record {
        let sessionID: UUID
        let parentSessionID: UUID?
        /// Only a live child with in-flight run state contributes to `running`.
        let isLiveInFlight: Bool
    }

    struct Counts: Equatable {
        var running = 0
        var finished = 0
    }

    private(set) var countsByParent: [UUID: Counts] = [:]

    init(persisted: [Record], index: [Record], live: [Record]) {
        var childrenByID: [UUID: Record] = [:]
        childrenByID.reserveCapacity(persisted.count + index.count + live.count)
        for record in persisted {
            childrenByID[record.sessionID] = record
        }
        for record in index {
            childrenByID[record.sessionID] = record
        }
        for record in live {
            childrenByID[record.sessionID] = record
        }

        for record in childrenByID.values {
            guard let parentID = record.parentSessionID else { continue }
            var counts = countsByParent[parentID, default: Counts()]
            if record.isLiveInFlight {
                counts.running += 1
            } else {
                counts.finished += 1
            }
            countsByParent[parentID] = counts
        }
    }

    func counts(for parentSessionID: UUID) -> Counts {
        countsByParent[parentSessionID] ?? Counts()
    }

    func changedParents(comparedTo prior: Self) -> Set<UUID> {
        Set(countsByParent.keys).union(prior.countsByParent.keys).filter {
            counts(for: $0) != prior.counts(for: $0)
        }
    }
}
