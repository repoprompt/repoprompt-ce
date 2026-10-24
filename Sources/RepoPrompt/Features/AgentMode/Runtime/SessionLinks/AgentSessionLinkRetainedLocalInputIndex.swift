import Foundation

/// Target-local retained-data projection, not a queue or an oversight publication source.
/// Fresh ordinals can only be allocated by exact composer settlement. Historical typed copies seed
/// an epoch; deletion/edit reconciliation is bounded by the sixteen retained records.
struct AgentSessionLinkRetainedLocalInputIndex {
    static let capacity = 16
    static let maximumCharacters = 600

    struct Content: Hashable {
        let text: String?
        let excerptStart: String
        let excerptEnd: String
        let keptCharacterCount: Int
        let fullSanitizedCharacterCount: Int
        let truncated: Bool
        /// Derived only from the Read-bounded, sanitized representation. Keep escaping on the
        /// existing bounded settlement path, rather than repeating it for every claim candidate.
        let escapedBody: String

        static func project(_ item: AgentChatItem) -> Content? {
            guard item.kind == .user, item.userInputOrigin == .localComposer,
                  item.crossSessionAttribution == nil else { return nil }
            let narrative = AgentSessionLinkTranscriptSanitizer.sanitizedNarrative(item.text)
            let safe = AgentSessionLinkMessageEnvelope.sanitizedBody(narrative.boundedText)
            let fullCount = narrative.fullCharacterCount
            let truncated = narrative.wasByteCapped || fullCount > maximumCharacters
            if !truncated {
                return Content(
                    text: AgentDisplayableText.hasDisplayableBody(safe) ? safe : nil,
                    excerptStart: "",
                    excerptEnd: "",
                    keptCharacterCount: safe.count,
                    fullSanitizedCharacterCount: fullCount,
                    truncated: false,
                    escapedBody: AgentSessionLinkMessageEnvelope.escaped(safe)
                )
            }
            // Read exposes a byte-bounded prefix. Never recover tail text outside that prefix.
            // Keep the first min(400, available) Characters and the intersection of the final
            // min(200, N - min(400, N)) Characters with that same prefix. If Read removed the
            // entire tail, <end> is empty and K honestly counts only the retained head.
            let start = String(safe.prefix(400))
            let tailOffset = max(min(400, fullCount), fullCount - 200)
            let end = String(safe.dropFirst(tailOffset))
            let displayable = AgentDisplayableText.hasDisplayableBody(start) || AgentDisplayableText.hasDisplayableBody(end)
            return Content(
                text: displayable ? start + end : nil,
                excerptStart: start,
                excerptEnd: end,
                keptCharacterCount: start.count + end.count,
                fullSanitizedCharacterCount: fullCount,
                truncated: true,
                escapedBody: "<start>\(AgentSessionLinkMessageEnvelope.escaped(start))</start><end>\(AgentSessionLinkMessageEnvelope.escaped(end))</end>"
            )
        }
    }

    struct Record: Hashable {
        let ordinal: UInt64
        let itemID: UUID
        var sourcePosition: Int?
        var contentVersion: UUID
        let messageTimestamp: Date
        var content: Content?
        var isDeleted = false
    }

    struct Snapshot: Hashable {
        let epoch: UUID
        let revision: UInt64
        let producedThrough: UInt64
        let droppedThrough: UInt64
        let records: [Record]
    }

    struct Seed {
        struct Row {
            let itemID: UUID
            let timestamp: Date
            let content: Content
        }

        var trackedIDs: Set<UUID> = []
        var trackedRows: [UUID: Content] = [:]
        var totalCount: UInt64 = 0
        var rows: [Row] = []

        mutating func append(_ item: AgentChatItem) {
            guard let content = Content.project(item) else { return }
            if trackedIDs.contains(item.id) { trackedRows[item.id] = content }
            totalCount += 1
            rows.append(Row(itemID: item.id, timestamp: item.timestamp, content: content))
            if rows.count > capacity { rows.removeFirst() }
        }
    }

    private(set) var epoch = UUID()
    private(set) var revision: UInt64 = 0
    private(set) var producedThrough: UInt64 = 0
    private(set) var droppedThrough: UInt64 = 0
    private(set) var records: [Record] = []
    private(set) var needsStructuralSeed = false

    var snapshot: Snapshot? {
        guard !needsStructuralSeed else { return nil }
        return Snapshot(
            epoch: epoch,
            revision: revision,
            producedThrough: producedThrough,
            droppedThrough: droppedThrough,
            records: records
        )
    }

    mutating func invalidateStructure() {
        epoch = UUID()
        revision &+= 1
        records.removeAll()
        producedThrough = 0
        droppedThrough = 0
        needsStructuralSeed = true
    }

    /// A structural seed is baseline-only. Reconciliation never allocates a fresh producer event.
    mutating func install(_ seed: Seed) {
        if needsStructuralSeed {
            producedThrough = seed.totalCount
            droppedThrough = seed.totalCount - UInt64(seed.rows.count)
            records = seed.rows.enumerated().map { offset, row in
                Record(
                    ordinal: droppedThrough + UInt64(offset) + 1,
                    itemID: row.itemID,
                    sourcePosition: nil,
                    contentVersion: UUID(),
                    messageTimestamp: row.timestamp,
                    content: row.content
                )
            }
            needsStructuralSeed = false
            revision &+= 1
            return
        }
        // The canonical transcript can change without a source revision. Compare identities, not
        // order: settlement order need not equal append/timestamp order. A seed's bounded suffix can
        // exclude older records; only absence from a complete seed proves deletion.
        let byID = Dictionary(uniqueKeysWithValues: seed.rows.map { ($0.itemID, $0) })
        for index in records.indices {
            let record = records[index]
            guard !record.isDeleted else { continue }
            if let row = byID[record.itemID] {
                updateContent(row.content, at: index)
            } else if seed.trackedIDs.contains(record.itemID) || seed.totalCount <= UInt64(Self.capacity) {
                updateContent(seed.trackedRows[record.itemID], at: index)
            }
        }
    }

    /// Nil identifies an exact producer settlement retained only in the canonical transcript.
    mutating func settle(_ item: AgentChatItem, at sourcePosition: Int?) {
        guard !needsStructuralSeed, let content = Content.project(item) else { return }
        if let index = records.firstIndex(where: { $0.itemID == item.id }) {
            guard !records[index].isDeleted else { return }
            records[index].sourcePosition = sourcePosition
            updateContent(content, at: index)
            return
        }
        guard producedThrough < UInt64.max else {
            invalidateStructure()
            return
        }
        producedThrough += 1
        records.append(Record(
            ordinal: producedThrough,
            itemID: item.id,
            sourcePosition: sourcePosition,
            contentVersion: UUID(),
            messageTimestamp: item.timestamp,
            content: content
        ))
        if records.count > Self.capacity { droppedThrough = records.removeFirst().ordinal }
        revision &+= 1
    }

    /// Mutable working-suffix pruning is not deletion from the canonical retained transcript.
    /// Its seed already owns content/deletion reconciliation; only source positions change here.
    mutating func reconcileWorkingPositions(_ positions: [UUID: Int]) {
        for index in records.indices {
            records[index].sourcePosition = records[index].isDeleted ? nil : positions[records[index].itemID]
        }
    }

    mutating func replace(_ item: AgentChatItem, at position: Int) {
        for index in records.indices where records[index].sourcePosition == position || records[index].itemID == item.id {
            guard !records[index].isDeleted else { continue }
            let sameID = records[index].itemID == item.id
            if !sameID { records[index].isDeleted = true }
            records[index].sourcePosition = sameID ? position : nil
            updateContent(sameID ? Content.project(item) : nil, at: index)
        }
    }

    mutating func remove(at position: Int, itemID: UUID) {
        for index in records.indices {
            if records[index].sourcePosition == position || records[index].itemID == itemID {
                records[index].sourcePosition = nil
                records[index].isDeleted = true
                updateContent(nil, at: index)
            } else if let old = records[index].sourcePosition, old > position {
                records[index].sourcePosition = old - 1
            }
        }
    }

    /// Tombstone tracked items a committed batch dropped, matched by identity only. Unlike
    /// `remove(at:itemID:)`, no positions shift here — the batch reconciler recomputes every
    /// surviving record's position immediately afterwards, so positional matching would only
    /// risk deleting a survivor whose position had already moved.
    mutating func markDeleted(_ itemIDs: Set<UUID>) {
        for index in records.indices where !records[index].isDeleted && itemIDs.contains(records[index].itemID) {
            records[index].sourcePosition = nil
            records[index].isDeleted = true
            updateContent(nil, at: index)
        }
    }

    private mutating func updateContent(_ content: Content?, at index: Int) {
        guard records[index].content != content else { return }
        records[index].content = content
        records[index].contentVersion = UUID()
        revision &+= 1
    }
}
