import Foundation

// MARK: - Cooperative Work Budgets

struct HistoryScanDiagnostic: Codable, Equatable {
    enum Kind: String, Codable, Hashable {
        case workspaceCount = "workspace_count"
        case workspaceDiscovery = "workspace_discovery"
        case workspaceMetadataFileBytes = "workspace_metadata_file_bytes"
        case workspaceMetadataReadFailure = "workspace_metadata_read_failure"
        case indexCount = "index_count"
        case indexBytes = "index_bytes"
        case indexFileBytes = "index_file_bytes"
        case indexReadFailure = "index_read_failure"
        case transcriptBytes = "transcript_bytes"
        case transcriptFileBytes = "transcript_file_bytes"
        case transcriptReadFailure = "transcript_read_failure"
        case turnCount = "turn_count"
        case elapsedTime = "elapsed_time"
        case diagnosticCount = "diagnostic_count"
    }

    enum Unit: String, Codable {
        case workspaces
        case indexes
        case sessions
        case bytes
        case turns
        case milliseconds
    }

    let kind: Kind
    let retryable: Bool
    let limit: Int64
    let consumed: Int64
    let unit: Unit
    let phase: String?
    let count: Int

    init(
        kind: Kind,
        limit: Int64,
        consumed: Int64,
        unit: Unit,
        retryable: Bool = true,
        phase: String? = nil,
        count: Int = 1
    ) {
        self.kind = kind
        self.retryable = retryable
        self.limit = limit
        self.consumed = consumed
        self.unit = unit
        self.phase = phase
        self.count = max(1, count)
    }

    var makesInventoryIncomplete: Bool {
        switch kind {
        case .workspaceMetadataFileBytes, .workspaceMetadataReadFailure:
            false
        case .workspaceCount, .workspaceDiscovery, .indexCount, .indexBytes,
             .indexFileBytes, .indexReadFailure, .transcriptBytes,
             .transcriptFileBytes, .transcriptReadFailure, .turnCount,
             .elapsedTime, .diagnosticCount:
            true
        }
    }
}

enum HistoryRemainingTimeDecision {
    case sufficient(remaining: Duration)
    case insufficient(HistoryScanDiagnostic)
}

final class HistoryRequestBudget: @unchecked Sendable {
    enum ReadKind {
        case index
        case transcript
    }

    let startedAt: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let maxTurns: Int
    let yieldEveryTurns: Int
    let maxIndexBytes: Int64
    let maxIndexFileBytes: Int64
    let maxTranscriptBytes: Int64
    let maxTranscriptFileBytes: Int64

    private let nowProvider: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var consumedIndexBytes: Int64 = 0
    private var consumedTranscriptBytes: Int64 = 0

    init(
        startedAt: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant,
        maxTurns: Int,
        yieldEveryTurns: Int,
        maxIndexBytes: Int64,
        maxIndexFileBytes: Int64,
        maxTranscriptBytes: Int64,
        maxTranscriptFileBytes: Int64,
        nowProvider: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.startedAt = startedAt
        self.deadline = deadline
        self.maxTurns = maxTurns
        self.yieldEveryTurns = yieldEveryTurns
        self.maxIndexBytes = maxIndexBytes
        self.maxIndexFileBytes = maxIndexFileBytes
        self.maxTranscriptBytes = maxTranscriptBytes
        self.maxTranscriptFileBytes = maxTranscriptFileBytes
        self.nowProvider = nowProvider
    }

    static func standalone(
        maxElapsed: Duration = .seconds(20),
        maxIndexBytes: Int64 = 128 * 1024 * 1024,
        maxIndexFileBytes: Int64 = 16 * 1024 * 1024,
        maxTranscriptBytes: Int64 = 256 * 1024 * 1024,
        maxTranscriptFileBytes: Int64 = 64 * 1024 * 1024
    ) -> HistoryRequestBudget {
        let clock = ContinuousClock()
        let startedAt = clock.now
        return HistoryRequestBudget(
            startedAt: startedAt,
            deadline: startedAt + maxElapsed,
            maxTurns: 250_000,
            yieldEveryTurns: 64,
            maxIndexBytes: maxIndexBytes,
            maxIndexFileBytes: maxIndexFileBytes,
            maxTranscriptBytes: maxTranscriptBytes,
            maxTranscriptFileBytes: maxTranscriptFileBytes,
            nowProvider: { ContinuousClock().now }
        )
    }

    var now: ContinuousClock.Instant {
        nowProvider()
    }

    func elapsedDiagnostic(phase: String) -> HistoryScanDiagnostic? {
        let current = now
        guard current >= deadline else { return nil }
        return HistoryScanDiagnostic(
            kind: .elapsedTime,
            limit: Self.durationMilliseconds(deadline - startedAt),
            consumed: Self.durationMilliseconds(current - startedAt),
            unit: .milliseconds,
            phase: phase
        )
    }

    func remainingTimeDecision(
        minimumRemaining: Duration,
        phase: String
    ) -> HistoryRemainingTimeDecision {
        let current = now
        let remaining = deadline - current
        guard current < deadline, remaining >= minimumRemaining else {
            return .insufficient(HistoryScanDiagnostic(
                kind: .elapsedTime,
                limit: Self.durationMilliseconds(deadline - startedAt),
                consumed: Self.durationMilliseconds(current - startedAt),
                unit: .milliseconds,
                phase: phase
            ))
        }
        return .sufficient(remaining: remaining)
    }

    func reserveRead(_ bytes: Int64, kind: ReadKind, phase: String) -> HistoryScanDiagnostic? {
        let normalizedBytes = max(0, bytes)
        let perFileLimit = kind == .index ? maxIndexFileBytes : maxTranscriptFileBytes
        let fileKind: HistoryScanDiagnostic.Kind = kind == .index ? .indexFileBytes : .transcriptFileBytes
        if normalizedBytes > perFileLimit {
            return HistoryScanDiagnostic(
                kind: fileKind,
                limit: perFileLimit,
                consumed: normalizedBytes,
                unit: .bytes,
                retryable: false,
                phase: phase
            )
        }

        return lock.withLock {
            let cumulativeLimit = kind == .index ? maxIndexBytes : maxTranscriptBytes
            let consumed = kind == .index ? consumedIndexBytes : consumedTranscriptBytes
            guard normalizedBytes <= cumulativeLimit - consumed else {
                return HistoryScanDiagnostic(
                    kind: kind == .index ? .indexBytes : .transcriptBytes,
                    limit: cumulativeLimit,
                    consumed: consumed + normalizedBytes,
                    unit: .bytes,
                    phase: phase
                )
            }
            if kind == .index {
                consumedIndexBytes += normalizedBytes
            } else {
                consumedTranscriptBytes += normalizedBytes
            }
            return nil
        }
    }

    private static func durationMilliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000
            + components.attoseconds / 1_000_000_000_000_000
    }
}

struct HistoryInventoryBudget: Equatable {
    let maxWorkspaces: Int
    let maxIndexDecodes: Int
    let maxIndexBytes: Int64
    let maxIndexFileBytes: Int64
    let maxWorkspaceMetadataFileBytes: Int64
    let maxIndexCacheEntries: Int
    let maxIndexCacheBytes: Int64
    let maxTranscriptFileBytes: Int64
    let maxTranscriptCacheBytes: Int64

    static let `default` = HistoryInventoryBudget(
        maxWorkspaces: 5000,
        maxIndexDecodes: 2000,
        maxIndexBytes: 128 * 1024 * 1024,
        maxIndexFileBytes: 16 * 1024 * 1024,
        maxWorkspaceMetadataFileBytes: 1024 * 1024,
        maxIndexCacheEntries: 4096,
        maxIndexCacheBytes: 128 * 1024 * 1024,
        maxTranscriptFileBytes: 64 * 1024 * 1024,
        maxTranscriptCacheBytes: 128 * 1024 * 1024
    )

    init(
        maxWorkspaces: Int,
        maxIndexDecodes: Int,
        maxIndexBytes: Int64,
        maxIndexFileBytes: Int64 = 16 * 1024 * 1024,
        maxWorkspaceMetadataFileBytes: Int64 = 1024 * 1024,
        maxIndexCacheEntries: Int = 4096,
        maxIndexCacheBytes: Int64 = 128 * 1024 * 1024,
        maxTranscriptFileBytes: Int64 = 64 * 1024 * 1024,
        maxTranscriptCacheBytes: Int64 = 128 * 1024 * 1024,
        maxElapsed _: Duration? = nil
    ) {
        self.maxWorkspaces = maxWorkspaces
        self.maxIndexDecodes = maxIndexDecodes
        self.maxIndexBytes = maxIndexBytes
        self.maxIndexFileBytes = maxIndexFileBytes
        self.maxWorkspaceMetadataFileBytes = maxWorkspaceMetadataFileBytes
        self.maxIndexCacheEntries = max(1, maxIndexCacheEntries)
        self.maxIndexCacheBytes = max(1, maxIndexCacheBytes)
        self.maxTranscriptFileBytes = maxTranscriptFileBytes
        self.maxTranscriptCacheBytes = maxTranscriptCacheBytes
    }
}
