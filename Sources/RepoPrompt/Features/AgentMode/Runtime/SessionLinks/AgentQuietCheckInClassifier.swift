import Foundation

/// Finished source rows only: no streamed-prefix memory, transcript lookup, or UI policy.
enum AgentQuietCheckInClassifier {
    enum Result: Equatable {
        case ordinary
        case quiet(hiddenSourceIDs: Set<UUID>)
    }

    /// The caller supplies only the current attempt's allocated range, not canonical history.
    /// `rangeIsComplete` is mutation-owned proof: contiguous keys alone cannot prove that a bulk
    /// replacement/rekey did not discard activity. Empty ranges use endKey == startKey - 1.
    static func classify(
        rows: some Collection<AgentChatItem>,
        startKey: Int,
        endKey: Int,
        rangeIsComplete: Bool,
        routineWakeID: UUID,
        hostMarkerIDs: Set<UUID>
    ) -> Result {
        guard rangeIsComplete, startKey >= 0, endKey >= startKey - 1 else { return .ordinary }
        var expectedKey = startKey
        var sawEnd = false
        var sourceIDs: Set<UUID> = []
        var hiddenIDs: Set<UUID> = [routineWakeID]
        var replyBytes: [UInt8] = []
        var hasReply = false
        for row in rows {
            guard !sawEnd, row.sequenceIndex == expectedKey, row.sequenceIndex <= endKey,
                  !row.isStreaming, sourceIDs.insert(row.id).inserted
            else { return .ordinary }
            sawEnd = row.sequenceIndex == endKey
            if !sawEnd {
                let (next, overflow) = expectedKey.addingReportingOverflow(1)
                guard !overflow else { return .ordinary }
                expectedKey = next
            }
            switch row.kind {
            case .thinking:
                hiddenIDs.insert(row.id)
            case .assistant, .assistantInline:
                // Include blank message boundaries and count separators before trimming. Iterate
                // bounded bytes rather than copying an arbitrarily large final reply.
                if hasReply { replyBytes.append(0x0A) }
                hasReply = true
                for byte in row.text.utf8 {
                    guard replyBytes.count < 256 else { return .ordinary }
                    replyBytes.append(byte)
                }
                guard replyBytes.count <= 256 else { return .ordinary }
                hiddenIDs.insert(row.id)
            case .system:
                guard hostMarkerIDs.contains(row.id),
                      row.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText
                else { return .ordinary }
            // A positively registered foreign marker is semantically exempt, but its own
            // producer's immutable verdict alone can hide it.
            case .user, .toolCall, .toolResult, .error:
                return .ordinary
            }
        }
        guard sawEnd || (rows.isEmpty && endKey == startKey - 1), permitsReply(replyBytes) else {
            return .ordinary
        }
        return .quiet(hiddenSourceIDs: hiddenIDs)
    }

    private static func permitsReply(_ bytes: [UInt8]) -> Bool {
        var reply = bytes[...]
        while let first = reply.first, isPadding(first) {
            reply = reply.dropFirst()
        }
        while let last = reply.last, isPadding(last) {
            reply = reply.dropLast()
        }
        if reply.isEmpty { return true }
        if reply.last == 0x2E { reply = reply.dropLast() }
        // Deliberately no second trim: "[ack] ." is not the sentinel.
        return reply.map { (0x41 ... 0x5A).contains($0) ? $0 + 0x20 : $0 } == Array("[ack]".utf8)
    }

    private static func isPadding(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09 ... 0x0D).contains(byte)
    }
}
